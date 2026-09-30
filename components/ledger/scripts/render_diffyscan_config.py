#!/usr/bin/env python3
"""Render Diffyscan configs from ledger.json without restating addresses.

Primary path (--from-ledger):
  Group every ledger deployment that has source.repositoryUrl + source.commit
  into Diffyscan cohorts (networkId, repositoryUrl, commit). Apply
  components/ledger/diffyscan/networks.json explorer settings and components/ledger/diffyscan/profiles/*
  MethodDescription extras. Blocked cohorts are skipped; healthy ones are
  written. Stale generated/*.json files are pruned.

Optional overlay path:
  Hand overlays under components/ledger/diffyscan/overlays/ may list deploymentIds plus
  Diffyscan-only extras (allowed_diffs, bytecode_comparison). Use when a
  cohort needs constructor args or scoped allowlists.

Addresses, contractName, and source url/commit always come from the ledger.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from _ledger import (
    DEFAULT_LEDGER,
    ROOT,
    SLUG_RE,
    index_deployments,
    load_json,
    parse_eip155_chain_id,
    require_network_slug,
    validate_json_schema,
)

DEFAULT_OVERLAY_SCHEMA = ROOT / "diffyscan" / "overlay.schema.json"
DEFAULT_OVERLAYS_DIR = ROOT / "diffyscan" / "overlays"
DEFAULT_PROFILE_SCHEMA = ROOT / "diffyscan" / "profile.schema.json"
DEFAULT_PROFILES_DIR = ROOT / "diffyscan" / "profiles"
DEFAULT_NETWORKS = ROOT / "diffyscan" / "networks.json"
DEFAULT_NETWORKS_SCHEMA = ROOT / "diffyscan" / "networks.schema.json"
DEFAULT_OUT_DIR = ROOT / "diffyscan" / "generated"

COMMIT_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")
# Filenames this script owns under --out-dir. Pruning is limited to these so a
# hand overlay rendered into the same directory is never deleted.
COHORT_FILE_RE = re.compile(
    r"^[a-z0-9-]+__[a-z0-9-]+__[0-9a-f]{7,64}\.json$"
)

# Exit codes. 3 means "configs were written correctly, but some deployments
# could not be projected" — distinct from 1, which means nothing usable ran.
EXIT_OK = 0
EXIT_USAGE = 2
EXIT_BLOCKED = 3

ADDRESS_KEYED_BYTECODE_FIELDS = (
    "constructor_calldata",
    "constructor_args",
)
ADDRESS_KEYED_ALLOWED_DIFF_FIELDS = (
    "bytecode",
    "source",
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--overlay-schema", type=Path, default=DEFAULT_OVERLAY_SCHEMA)
    parser.add_argument("--overlays-dir", type=Path, default=DEFAULT_OVERLAYS_DIR)
    parser.add_argument("--profile-schema", type=Path, default=DEFAULT_PROFILE_SCHEMA)
    parser.add_argument("--profiles-dir", type=Path, default=DEFAULT_PROFILES_DIR)
    parser.add_argument("--networks", type=Path, default=DEFAULT_NETWORKS)
    parser.add_argument("--networks-schema", type=Path, default=DEFAULT_NETWORKS_SCHEMA)
    parser.add_argument(
        "overlays",
        nargs="*",
        type=Path,
        help="Overlay JSON path(s). Omit with --from-ledger or --all.",
    )
    parser.add_argument(
        "--from-ledger",
        action="store_true",
        help="Render one Diffyscan config per ready ledger source cohort",
    )
    parser.add_argument(
        "--coverage",
        action="store_true",
        help="Print ledger→Diffyscan coverage (alone, or with --from-ledger)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Render every *.json overlay under --overlays-dir",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=DEFAULT_OUT_DIR,
        help="Directory for generated Diffyscan configs",
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Print a single overlay-rendered config to stdout",
    )
    return parser


def normalize_repo_url(url: str) -> str:
    parsed = urlparse(url.strip())
    path = parsed.path.rstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    if not parsed.scheme or not parsed.netloc or not path:
        raise SystemExit(f"Invalid repositoryUrl: {url!r}")
    return f"{parsed.scheme}://{parsed.netloc}{path}"


def cohort_id(profile_id: str, network_slug: str, commit: str) -> str:
    if not SLUG_RE.fullmatch(profile_id):
        raise SystemExit(f"profileId must be a slug; got {profile_id!r}")
    if not SLUG_RE.fullmatch(network_slug):
        raise SystemExit(f"network slug must be a slug; got {network_slug!r}")
    if not COMMIT_RE.fullmatch(commit):
        raise SystemExit(f"commit must be hex; got {commit!r}")
    # Full commit avoids 12-hex prefix collisions across repositories.
    return f"{network_slug}__{profile_id}__{commit.lower()}"


def rewrite_deployment_id_keys(
    mapping: dict[str, Any],
    address_by_deployment_id: dict[str, str],
    *,
    field_path: str,
) -> dict[str, Any]:
    rewritten: dict[str, Any] = {}
    for deployment_id, value in mapping.items():
        address = address_by_deployment_id.get(deployment_id)
        if address is None:
            raise SystemExit(
                f"{field_path} key {deployment_id!r} is not among this cohort's "
                f"deploymentIds"
            )
        if address in rewritten:
            raise SystemExit(
                f"{field_path} rewrites to duplicate address {address!r}"
            )
        rewritten[address] = value
    return rewritten


def rewrite_deployment_from(
    mapping: dict[str, Any],
    address_by_deployment_id: dict[str, str],
) -> dict[str, str]:
    rewritten: dict[str, str] = {}
    for deployable_id, deployer_id in mapping.items():
        if not isinstance(deployer_id, str):
            raise SystemExit(
                "bytecode_comparison.deployment_from values must be deploymentId "
                f"strings; got {deployer_id!r} for {deployable_id!r}"
            )
        deployable = address_by_deployment_id.get(deployable_id)
        deployer = address_by_deployment_id.get(deployer_id)
        if deployable is None:
            raise SystemExit(
                "bytecode_comparison.deployment_from key "
                f"{deployable_id!r} is not among this cohort's deploymentIds"
            )
        if deployer is None:
            raise SystemExit(
                "bytecode_comparison.deployment_from value "
                f"{deployer_id!r} is not among this cohort's deploymentIds"
            )
        rewritten[deployable] = deployer
    return rewritten


def render_from_spec(
    *,
    label: str,
    selected: list[dict[str, Any]],
    network_id: str,
    repository_url: str,
    commit: str,
    explorer_hostname: str,
    explorer_token_env_var: str | None,
    explorer_chain_id: int | None,
    relative_root: str,
    dependencies: dict[str, Any] | None,
    fail_on_bytecode_comparison_error: bool | None = None,
    bytecode_comparison: dict[str, Any] | None = None,
    allowed_diffs: dict[str, Any] | None = None,
) -> dict[str, Any]:
    # Populated by the validation loop below, so a malformed entry reports a
    # clean error instead of a bare KeyError from a comprehension.
    address_by_deployment_id: dict[str, str] = {}

    contracts: dict[str, str] = {}
    for entry in selected:
        if entry.get("networkId") != network_id:
            raise SystemExit(
                f"{label}: {entry['deploymentId']} networkId mismatch"
            )
        source = entry.get("source")
        if not isinstance(source, dict):
            raise SystemExit(f"{label}: {entry['deploymentId']} missing source")
        if normalize_repo_url(source["repositoryUrl"]) != repository_url:
            raise SystemExit(
                f"{label}: {entry['deploymentId']} repositoryUrl mismatch"
            )
        entry_commit = source.get("commit")
        if not isinstance(entry_commit, str) or entry_commit.lower() != commit.lower():
            raise SystemExit(f"{label}: {entry['deploymentId']} commit mismatch")
        address = entry.get("address")
        if not isinstance(address, str) or not address:
            raise SystemExit(f"{label}: {entry['deploymentId']} missing address")
        contract_name = entry.get("contractName")
        if not isinstance(contract_name, str) or not contract_name:
            raise SystemExit(f"{label}: {entry['deploymentId']} missing contractName")
        if address in contracts:
            raise SystemExit(
                f"{label}: duplicate address after projection: {address}"
            )
        contracts[address] = contract_name
        address_by_deployment_id[entry["deploymentId"]] = address

    config: dict[str, Any] = {
        "contracts": contracts,
        "explorer_hostname": explorer_hostname,
        "github_repo": {
            "url": repository_url,
            "commit": commit,
            "relative_root": relative_root,
        },
    }

    if explorer_token_env_var:
        config["explorer_token_env_var"] = explorer_token_env_var

    if explorer_chain_id is not None:
        config["explorer_chain_id"] = explorer_chain_id
    else:
        derived = parse_eip155_chain_id(network_id)
        if derived is not None:
            config["explorer_chain_id"] = derived

    if dependencies:
        config["dependencies"] = dependencies

    if fail_on_bytecode_comparison_error is not None:
        config["fail_on_bytecode_comparison_error"] = (
            fail_on_bytecode_comparison_error
        )

    if bytecode_comparison:
        rewritten_bytecode: dict[str, Any] = {}
        for key, value in bytecode_comparison.items():
            if key in ADDRESS_KEYED_BYTECODE_FIELDS:
                if not isinstance(value, dict):
                    raise SystemExit(
                        f"{label}: bytecode_comparison.{key} must be an object "
                        "keyed by deploymentId"
                    )
                rewritten_bytecode[key] = rewrite_deployment_id_keys(
                    value,
                    address_by_deployment_id,
                    field_path=f"bytecode_comparison.{key}",
                )
            elif key == "deployment_from":
                if not isinstance(value, dict):
                    raise SystemExit(
                        f"{label}: bytecode_comparison.deployment_from must be "
                        "an object"
                    )
                rewritten_bytecode[key] = rewrite_deployment_from(
                    value, address_by_deployment_id
                )
            else:
                rewritten_bytecode[key] = value
        config["bytecode_comparison"] = rewritten_bytecode

    if allowed_diffs:
        rewritten_allowed: dict[str, Any] = {}
        for key, value in allowed_diffs.items():
            if key in ADDRESS_KEYED_ALLOWED_DIFF_FIELDS:
                if not isinstance(value, dict):
                    raise SystemExit(
                        f"{label}: allowed_diffs.{key} must be an object keyed "
                        "by deploymentId"
                    )
                rewritten_allowed[key] = rewrite_deployment_id_keys(
                    value,
                    address_by_deployment_id,
                    field_path=f"allowed_diffs.{key}",
                )
            else:
                rewritten_allowed[key] = value
        config["allowed_diffs"] = rewritten_allowed

    return config


def render_overlay(
    overlay: dict[str, Any],
    deployments_by_id: dict[str, dict[str, Any]],
    overlay_path: Path,
) -> dict[str, Any]:
    selected: list[dict[str, Any]] = []
    for deployment_id in overlay["deploymentIds"]:
        entry = deployments_by_id.get(deployment_id)
        if entry is None:
            raise SystemExit(
                f"{overlay_path}: unknown deploymentId {deployment_id!r}"
            )
        selected.append(entry)

    network_ids = {entry["networkId"] for entry in selected}
    if len(network_ids) != 1:
        raise SystemExit(
            f"{overlay_path}: deployments span multiple networkIds: "
            + ", ".join(sorted(network_ids))
        )
    network_id = next(iter(network_ids))

    source_keys: set[tuple[str, str]] = set()
    for entry in selected:
        source = entry.get("source")
        if not isinstance(source, dict):
            raise SystemExit(
                f"{overlay_path}: {entry['deploymentId']} has no source object"
            )
        repository_url = source.get("repositoryUrl")
        commit = source.get("commit")
        if not isinstance(repository_url, str) or not repository_url:
            raise SystemExit(
                f"{overlay_path}: {entry['deploymentId']} missing repositoryUrl"
            )
        if not isinstance(commit, str) or not commit:
            raise SystemExit(
                f"{overlay_path}: {entry['deploymentId']} missing commit"
            )
        # Fold hex case here too, or two ledger entries that differ only in
        # case would look like two different revisions.
        source_keys.add((normalize_repo_url(repository_url), commit.lower()))
    if len(source_keys) != 1:
        raise SystemExit(
            f"{overlay_path}: deployments do not share one repositoryUrl+commit"
        )
    repository_url, commit = next(iter(source_keys))

    return render_from_spec(
        label=str(overlay_path),
        selected=selected,
        network_id=network_id,
        repository_url=repository_url,
        commit=commit,
        explorer_hostname=overlay["explorer_hostname"],
        explorer_token_env_var=overlay.get("explorer_token_env_var"),
        explorer_chain_id=overlay.get("explorer_chain_id"),
        relative_root=overlay.get("github_repo", {}).get("relative_root", ""),
        dependencies=overlay.get("dependencies"),
        fail_on_bytecode_comparison_error=overlay.get(
            "fail_on_bytecode_comparison_error"
        ),
        bytecode_comparison=overlay.get("bytecode_comparison"),
        allowed_diffs=overlay.get("allowed_diffs"),
    )


def load_profiles(
    profiles_dir: Path, profile_schema: dict[str, Any]
) -> dict[str, dict[str, Any]]:
    if not profiles_dir.is_dir():
        raise SystemExit(f"Profiles directory not found: {profiles_dir}")
    by_url: dict[str, dict[str, Any]] = {}
    seen_ids: dict[str, str] = {}
    for path in sorted(profiles_dir.glob("*.json")):
        profile = validate_json_schema(
            load_json(path), profile_schema, label=str(path)
        )
        profile_id = profile["profileId"]
        if profile_id in seen_ids:
            # profileId is half of every cohort filename, so duplicates would
            # make two repositories fight over one output path.
            raise SystemExit(
                f"Duplicate profileId {profile_id!r} in {path} and "
                f"{seen_ids[profile_id]}"
            )
        seen_ids[profile_id] = str(path)
        # Pins are matched case-insensitively, so two keys differing only in hex
        # case would silently collapse and drop one pin's settings.
        folded: dict[str, str] = {}
        for key in profile.get("commits") or {}:
            low = str(key).lower()
            if low in folded:
                raise SystemExit(
                    f"{path}: commits {folded[low]!r} and {key!r} differ only in "
                    "hex case and would collapse into one pin"
                )
            folded[low] = key
        url = normalize_repo_url(profile["repositoryUrl"])
        if url in by_url:
            raise SystemExit(f"Duplicate profile repositoryUrl {url!r}")
        profile = dict(profile)
        profile["repositoryUrl"] = url
        by_url[url] = profile
    return by_url


def resolve_profile_settings(
    profile: dict[str, Any], commit: str
) -> dict[str, Any] | None:
    """Return merged settings, or None when the commit is not explicitly pinned.

    Commit-scoped keys replace the matching default key outright; they are not
    deep-merged into it. Git hex is case-insensitive, so pins are matched that
    way too.
    """
    commits = {
        str(key).lower(): value for key, value in (profile.get("commits") or {}).items()
    }
    commit = commit.lower()
    if commit not in commits:
        return None
    merged: dict[str, Any] = dict(profile.get("default") or {})
    override = commits[commit]
    if isinstance(override, dict):
        for key, value in override.items():
            merged[key] = value
    return merged


def resolve_network_settings(
    networks_map: dict[str, Any], network_id: str
) -> dict[str, Any]:
    merged = dict(networks_map.get("default") or {})
    override = (networks_map.get("networks") or {}).get(network_id)
    if isinstance(override, dict):
        for key, value in override.items():
            if value is None:
                merged.pop(key, None)
            else:
                merged[key] = value
    hostname = merged.get("explorer_hostname")
    if not isinstance(hostname, str) or not hostname:
        raise SystemExit(
            f"No explorer_hostname resolved for networkId {network_id!r}"
        )
    return merged


def classify_deployments(
    deployments_by_id: dict[str, dict[str, Any]],
) -> tuple[
    dict[tuple[str, str, str], list[dict[str, Any]]],
    list[str],
    list[str],
    list[str],
]:
    cohorts: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    missing_commit: list[str] = []
    null_source: list[str] = []
    invalid_source: list[str] = []

    for deployment_id, entry in deployments_by_id.items():
        source = entry.get("source")
        if not isinstance(source, dict):
            null_source.append(deployment_id)
            continue
        repository_url = source.get("repositoryUrl")
        commit = source.get("commit")
        if not isinstance(repository_url, str) or not repository_url:
            null_source.append(deployment_id)
            continue
        if not isinstance(commit, str) or not commit:
            missing_commit.append(deployment_id)
            continue
        try:
            normalized_url = normalize_repo_url(repository_url)
        except SystemExit:
            # One unusable URL must not take the healthy cohorts down with it.
            invalid_source.append(deployment_id)
            continue
        # Commit hex is case-insensitive; fold it so one ledger cannot produce
        # two cohorts that collapse onto a single output filename.
        key = (entry["networkId"], normalized_url, commit.lower())
        cohorts[key].append(entry)

    return cohorts, missing_commit, null_source, invalid_source


def render_from_ledger(
    ledger: dict[str, Any],
    deployments_by_id: dict[str, dict[str, Any]],
    *,
    profiles_by_url: dict[str, dict[str, Any]],
    networks_map: dict[str, Any],
) -> tuple[list[tuple[str, dict[str, Any]]], dict[str, list[str]]]:
    cohorts, missing_commit, null_source, invalid_source = classify_deployments(
        deployments_by_id
    )

    rendered: list[tuple[str, dict[str, Any]]] = []
    blockers: dict[str, list[str]] = {
        "missing_network_meta": [],
        "missing_profile": [],
        "unpinned_commit": [],
        "missing_commit": missing_commit,
        "null_source": null_source,
        "invalid_source": invalid_source,
        "skipped": [],
    }
    seen_cids: set[str] = set()

    for (network_id, repository_url, commit), selected in sorted(
        cohorts.items(), key=lambda item: (item[0][0], item[0][1], item[0][2])
    ):
        try:
            network_slug = require_network_slug(ledger, network_id)
            network_cfg = resolve_network_settings(networks_map, network_id)
        except SystemExit as exc:
            for entry in selected:
                blockers["missing_network_meta"].append(entry["deploymentId"])
                blockers["skipped"].append(f"{entry['deploymentId']}: {exc}")
            continue

        profile = profiles_by_url.get(repository_url)
        if profile is None:
            for entry in selected:
                blockers["missing_profile"].append(entry["deploymentId"])
                blockers["skipped"].append(
                    f"{entry['deploymentId']}: no profile for {repository_url}"
                )
            continue

        settings = resolve_profile_settings(profile, commit)
        if settings is None:
            for entry in selected:
                blockers["unpinned_commit"].append(entry["deploymentId"])
                blockers["skipped"].append(
                    f"{entry['deploymentId']}: profile {profile['profileId']} "
                    f"has no commits[{commit}] pin"
                )
            continue

        cid = cohort_id(profile["profileId"], network_slug, commit)
        if cid in seen_cids:
            raise SystemExit(f"Duplicate cohort id after projection: {cid}")
        seen_cids.add(cid)

        config = render_from_spec(
            label=cid,
            selected=selected,
            network_id=network_id,
            repository_url=repository_url,
            commit=commit,
            explorer_hostname=network_cfg["explorer_hostname"],
            explorer_token_env_var=network_cfg.get("explorer_token_env_var"),
            explorer_chain_id=network_cfg.get("explorer_chain_id"),
            relative_root=(settings.get("github_repo") or {}).get(
                "relative_root", ""
            ),
            dependencies=settings.get("dependencies") or {},
            fail_on_bytecode_comparison_error=settings.get(
                "fail_on_bytecode_comparison_error"
            ),
        )
        rendered.append((cid, config))

    return rendered, blockers


def print_coverage(
    ledger: dict[str, Any],
    rendered: list[tuple[str, dict[str, Any]]],
    blockers: dict[str, list[str]],
) -> None:
    total = len(ledger.get("deployments") or [])
    projected = sum(len(cfg["contracts"]) for _, cfg in rendered)
    blocked = sum(
        len(blockers.get(key, []))
        for key in (
            "missing_network_meta",
            "missing_profile",
            "unpinned_commit",
            "missing_commit",
            "null_source",
            "invalid_source",
        )
    )
    # This counts projection into Diffyscan configs, not verification: a
    # projected deployment is one Diffyscan will be asked about, not one whose
    # source has been confirmed to match. Only a Diffyscan run settles that.
    print("Diffyscan projection (not verification)")
    print(f"  total deployments:           {total}")
    print(f"  projected into cohorts:      {projected} across {len(rendered)} cohorts")
    print(f"  not projected:               {blocked}")
    print(f"  missing source.commit:       {len(blockers.get('missing_commit', []))}")
    print(f"  null/missing repositoryUrl:  {len(blockers.get('null_source', []))}")
    print(f"  unusable repositoryUrl:      {len(blockers.get('invalid_source', []))}")
    print(
        f"  missing network metadata:    {len(blockers.get('missing_network_meta', []))}"
    )
    print(f"  missing repository profile:  {len(blockers.get('missing_profile', []))}")
    print(f"  unpinned profile commit:     {len(blockers.get('unpinned_commit', []))}")
    if rendered:
        print("  cohorts:")
        for cid, config in rendered:
            print(f"    - {cid} ({len(config['contracts'])})")
    skipped = blockers.get("skipped") or []
    if skipped:
        print("  skipped ready-candidate details:")
        for line in skipped:
            print(f"    - {line}")


def blocked_exit_code(blockers: dict[str, list[str]]) -> int:
    """EXIT_BLOCKED when a deployment that names a revision failed to project.

    A deployment is only a regression here if the ledger gives Diffyscan enough
    to work with — repositoryUrl AND commit — and the config set still does not
    cover it. The two reported-gap buckets are weaker than that: null_source has
    no repositoryUrl, and missing_commit names a repository but no revision, so
    there is nothing to diff against. Both are printed by print_coverage and are
    expected to be non-zero; neither changes the exit code.

    Note this means removing a commit from the ledger turns a regression into a
    reported gap. The control for that is review of the ledger diff, not this
    gate, which cannot distinguish a deliberate removal from a lost pin.
    """
    regressions = (
        "missing_network_meta",
        "missing_profile",
        "unpinned_commit",
        "invalid_source",
    )
    if any(blockers.get(key) for key in regressions):
        return EXIT_BLOCKED
    return EXIT_OK


def discover_overlays(overlays_dir: Path) -> list[Path]:
    if not overlays_dir.is_dir():
        raise SystemExit(f"Overlays directory not found: {overlays_dir}")
    return sorted(p for p in overlays_dir.glob("*.json") if p.is_file())


def write_config(config: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(config, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def prune_stale_generated(out_dir: Path, keep_names: set[str]) -> list[str]:
    """Delete cohort files this script no longer produces.

    Only files matching COHORT_FILE_RE are considered: anything else in the
    directory (a hand overlay rendered alongside, say) is not ours to remove.
    """
    if not out_dir.is_dir():
        return []
    removed: list[str] = []
    for path in sorted(out_dir.glob("*.json")):
        if path.name in keep_names or not COHORT_FILE_RE.fullmatch(path.name):
            continue
        path.unlink()
        removed.append(path.name)
    return removed


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.ledger.is_file():
        print(f"Ledger not found: {args.ledger}", file=sys.stderr)
        return EXIT_USAGE

    if args.from_ledger and (args.all or args.overlays):
        print(
            "Do not combine --from-ledger with overlay paths or --all",
            file=sys.stderr,
        )
        return EXIT_USAGE
    if args.coverage and (args.all or args.overlays):
        print(
            "Do not combine --coverage with overlay paths or --all "
            "(use --coverage alone or with --from-ledger)",
            file=sys.stderr,
        )
        return EXIT_USAGE
    if args.all and args.overlays:
        print("Do not combine overlay paths with --all", file=sys.stderr)
        return EXIT_USAGE
    if not args.from_ledger and not args.all and not args.overlays and not args.coverage:
        parser.error("provide --from-ledger, overlay path(s), --all, or --coverage")
    if args.stdout:
        if args.from_ledger or args.coverage or args.all or len(args.overlays) != 1:
            print(
                "--stdout requires exactly one overlay path and no --coverage/"
                "--from-ledger/--all",
                file=sys.stderr,
            )
            return EXIT_USAGE

    ledger = load_json(args.ledger)
    deployments_by_id = index_deployments(ledger)

    rendered: list[tuple[str, dict[str, Any]]] = []
    blockers: dict[str, list[str]] = {}

    if args.from_ledger or args.coverage:
        for path, label in (
            (args.networks, "networks map"),
            (args.networks_schema, "networks schema"),
            (args.profile_schema, "profile schema"),
        ):
            if not path.is_file():
                print(f"{label} not found: {path}", file=sys.stderr)
                return EXIT_USAGE
        networks_schema = load_json(args.networks_schema)
        profile_schema = load_json(args.profile_schema)
        if not isinstance(networks_schema, dict) or not isinstance(
            profile_schema, dict
        ):
            raise SystemExit("networks/profile schemas must be JSON objects")
        networks_map = validate_json_schema(
            load_json(args.networks), networks_schema, label=str(args.networks)
        )
        profiles_by_url = load_profiles(args.profiles_dir, profile_schema)
        rendered, blockers = render_from_ledger(
            ledger,
            deployments_by_id,
            profiles_by_url=profiles_by_url,
            networks_map=networks_map,
        )
        if not args.from_ledger:
            print_coverage(ledger, rendered, blockers)
            return blocked_exit_code(blockers)
    else:
        if not args.overlay_schema.is_file():
            print(
                f"Overlay schema not found: {args.overlay_schema}",
                file=sys.stderr,
            )
            return EXIT_USAGE
        overlay_schema = load_json(args.overlay_schema)
        if not isinstance(overlay_schema, dict):
            raise SystemExit("Overlay schema root must be a JSON object")
        overlay_paths = (
            discover_overlays(args.overlays_dir)
            if args.all
            else list(args.overlays)
        )
        if args.all and not overlay_paths:
            print(f"No overlay JSON files in {args.overlays_dir}")
            return 0
        for overlay_path in overlay_paths:
            if not overlay_path.is_file():
                raise SystemExit(f"Overlay not found: {overlay_path}")
            overlay = validate_json_schema(
                load_json(overlay_path),
                overlay_schema,
                label=str(overlay_path),
            )
            config = render_overlay(overlay, deployments_by_id, overlay_path)
            overlay_id = overlay["overlayId"]
            if any(overlay_id == seen for seen, _ in rendered):
                # Both would write <overlayId>.json; the second would win and
                # the first cohort would go unverified with nothing to show it.
                raise SystemExit(
                    f"{overlay_path}: duplicate overlayId {overlay_id!r}"
                )
            rendered.append((overlay_id, config))

    if args.stdout:
        _, config = rendered[0]
        json.dump(config, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    out_dir = args.out_dir
    keep_names: set[str] = set()
    for cid, config in rendered:
        # cid is built only from slug + hex commit — reject path separators.
        if "/" in cid or "\\" in cid or ".." in cid:
            raise SystemExit(f"Refusing unsafe cohort id: {cid!r}")
        filename = f"{cid}.json"
        keep_names.add(filename)
        write_config(config, out_dir / filename)
        print(f"Wrote {out_dir / filename} ({len(config['contracts'])} contracts)")

    if args.from_ledger:
        removed = prune_stale_generated(out_dir, keep_names)
        for name in removed:
            print(f"Pruned stale {out_dir / name}")
        print_coverage(ledger, rendered, blockers)
        # Every healthy cohort above was written; EXIT_BLOCKED reports the ones
        # that were not, without claiming the render itself failed.
        return blocked_exit_code(blockers)

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())

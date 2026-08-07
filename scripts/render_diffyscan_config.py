#!/usr/bin/env python3
"""Render Diffyscan configs from ledger.json + address-free overlays.

Overlays under diffyscan/overlays/ reference ledger deploymentIds. This script
projects them into Diffyscan config JSON (addresses, contractName, github_repo
url/commit come from the ledger; explorer settings, dependencies, and optional
Diffyscan-only sections come from the overlay).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError

from _ledger import DEFAULT_LEDGER, ROOT, load_json

DEFAULT_OVERLAY_SCHEMA = ROOT / "diffyscan" / "overlay.schema.json"
DEFAULT_OVERLAYS_DIR = ROOT / "diffyscan" / "overlays"
DEFAULT_OUT_DIR = ROOT / "diffyscan" / "generated"

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
    parser.add_argument(
        "--overlay-schema",
        type=Path,
        default=DEFAULT_OVERLAY_SCHEMA,
        help="JSON Schema for Diffyscan overlays",
    )
    parser.add_argument(
        "--overlays-dir",
        type=Path,
        default=DEFAULT_OVERLAYS_DIR,
        help="Directory of overlay JSON files (used with --all)",
    )
    parser.add_argument(
        "overlays",
        nargs="*",
        type=Path,
        help="Overlay JSON path(s). Omit and pass --all to render every overlay.",
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
        help="Print a single rendered config to stdout instead of writing files",
    )
    return parser


def index_deployments(ledger: Any) -> dict[str, dict[str, Any]]:
    if not isinstance(ledger, dict):
        raise SystemExit("Ledger root must be a JSON object")
    deployments = ledger.get("deployments")
    if not isinstance(deployments, list):
        raise SystemExit("Ledger deployments must be an array")

    by_id: dict[str, dict[str, Any]] = {}
    for index, entry in enumerate(deployments):
        if not isinstance(entry, dict):
            raise SystemExit(f"deployments[{index}] must be an object")
        deployment_id = entry.get("deploymentId")
        if not isinstance(deployment_id, str) or not deployment_id:
            raise SystemExit(f"deployments[{index}] missing deploymentId")
        if deployment_id in by_id:
            raise SystemExit(f"Duplicate deploymentId in ledger: {deployment_id}")
        by_id[deployment_id] = entry
    return by_id


def validate_overlay(overlay: Any, schema: dict[str, Any], path: Path) -> dict[str, Any]:
    if not isinstance(overlay, dict):
        raise SystemExit(f"Overlay root must be a JSON object: {path}")
    try:
        Draft202012Validator.check_schema(schema)
    except SchemaError as exc:
        raise SystemExit(f"Invalid overlay schema: {exc}") from exc
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(overlay), key=lambda e: list(e.path))
    if errors:
        lines = [f"Overlay schema validation failed for {path}:"]
        for error in errors:
            loc = ".".join(str(p) for p in error.path) or "<root>"
            lines.append(f"  - {loc}: {error.message}")
        raise SystemExit("\n".join(lines))
    return overlay


def parse_eip155_chain_id(network_id: str) -> int | None:
    namespace, _, reference = network_id.partition(":")
    if namespace != "eip155" or not reference.isdigit():
        return None
    return int(reference)


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
                f"{field_path} key {deployment_id!r} is not among this overlay's "
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
                f"{deployable_id!r} is not among this overlay's deploymentIds"
            )
        if deployer is None:
            raise SystemExit(
                "bytecode_comparison.deployment_from value "
                f"{deployer_id!r} is not among this overlay's deploymentIds"
            )
        rewritten[deployable] = deployer
    return rewritten


def resolve_cohort(
    overlay: dict[str, Any],
    deployments_by_id: dict[str, dict[str, Any]],
    overlay_path: Path,
) -> tuple[list[dict[str, Any]], str, str, str]:
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
            f"{overlay_path}: deploymentIds span multiple networkIds: "
            + ", ".join(sorted(network_ids))
        )
    network_id = next(iter(network_ids))

    source_keys: set[tuple[str, str]] = set()
    for entry in selected:
        source = entry.get("source")
        if not isinstance(source, dict):
            raise SystemExit(
                f"{overlay_path}: {entry['deploymentId']} has no source object; "
                "Diffyscan requires repositoryUrl and commit"
            )
        repository_url = source.get("repositoryUrl")
        commit = source.get("commit")
        if not isinstance(repository_url, str) or not repository_url:
            raise SystemExit(
                f"{overlay_path}: {entry['deploymentId']} source.repositoryUrl "
                "is missing"
            )
        if not isinstance(commit, str) or not commit:
            raise SystemExit(
                f"{overlay_path}: {entry['deploymentId']} source.commit is "
                "missing; establish a commit in the ledger before rendering"
            )
        source_keys.add((repository_url, commit))

    if len(source_keys) != 1:
        rendered = "; ".join(
            f"{url}@{commit}" for url, commit in sorted(source_keys)
        )
        raise SystemExit(
            f"{overlay_path}: deploymentIds do not share one source "
            f"repositoryUrl+commit ({rendered})"
        )
    repository_url, commit = next(iter(source_keys))
    return selected, network_id, repository_url, commit


def render_config(
    overlay: dict[str, Any],
    deployments_by_id: dict[str, dict[str, Any]],
    overlay_path: Path,
) -> dict[str, Any]:
    selected, network_id, repository_url, commit = resolve_cohort(
        overlay, deployments_by_id, overlay_path
    )
    address_by_deployment_id = {
        entry["deploymentId"]: entry["address"] for entry in selected
    }

    contracts: dict[str, str] = {}
    for entry in selected:
        address = entry["address"]
        contract_name = entry.get("contractName")
        if not isinstance(contract_name, str) or not contract_name:
            raise SystemExit(
                f"{overlay_path}: {entry['deploymentId']} missing contractName"
            )
        if address in contracts:
            raise SystemExit(
                f"{overlay_path}: duplicate address after projection: {address}"
            )
        contracts[address] = contract_name

    github_repo = {
        "url": repository_url,
        "commit": commit,
        "relative_root": overlay.get("github_repo", {}).get("relative_root", ""),
    }

    config: dict[str, Any] = {
        "contracts": contracts,
        "explorer_hostname": overlay["explorer_hostname"],
        "github_repo": github_repo,
    }

    if "explorer_token_env_var" in overlay:
        config["explorer_token_env_var"] = overlay["explorer_token_env_var"]

    if "explorer_chain_id" in overlay:
        config["explorer_chain_id"] = overlay["explorer_chain_id"]
    else:
        derived = parse_eip155_chain_id(network_id)
        if derived is not None:
            config["explorer_chain_id"] = derived

    if "dependencies" in overlay:
        config["dependencies"] = overlay["dependencies"]

    for flag in (
        "fail_on_bytecode_comparison_error",
        "fail_on_comparison_error",
    ):
        if flag in overlay:
            config[flag] = overlay[flag]

    if "bytecode_comparison" in overlay:
        bytecode_comparison: dict[str, Any] = {}
        for key, value in overlay["bytecode_comparison"].items():
            if key in ADDRESS_KEYED_BYTECODE_FIELDS:
                if not isinstance(value, dict):
                    raise SystemExit(
                        f"{overlay_path}: bytecode_comparison.{key} must be an "
                        "object keyed by deploymentId"
                    )
                bytecode_comparison[key] = rewrite_deployment_id_keys(
                    value,
                    address_by_deployment_id,
                    field_path=f"bytecode_comparison.{key}",
                )
            elif key == "deployment_from":
                if not isinstance(value, dict):
                    raise SystemExit(
                        f"{overlay_path}: bytecode_comparison.deployment_from "
                        "must be an object"
                    )
                bytecode_comparison[key] = rewrite_deployment_from(
                    value, address_by_deployment_id
                )
            else:
                bytecode_comparison[key] = value
        config["bytecode_comparison"] = bytecode_comparison

    if "allowed_diffs" in overlay:
        allowed_diffs: dict[str, Any] = {}
        for key, value in overlay["allowed_diffs"].items():
            if key in ADDRESS_KEYED_ALLOWED_DIFF_FIELDS:
                if not isinstance(value, dict):
                    raise SystemExit(
                        f"{overlay_path}: allowed_diffs.{key} must be an object "
                        "keyed by deploymentId"
                    )
                allowed_diffs[key] = rewrite_deployment_id_keys(
                    value,
                    address_by_deployment_id,
                    field_path=f"allowed_diffs.{key}",
                )
            else:
                allowed_diffs[key] = value
        config["allowed_diffs"] = allowed_diffs

    return config


def discover_overlays(overlays_dir: Path) -> list[Path]:
    if not overlays_dir.is_dir():
        raise SystemExit(f"Overlays directory not found: {overlays_dir}")
    paths = sorted(overlays_dir.glob("*.json"))
    if not paths:
        raise SystemExit(f"No overlay JSON files found in {overlays_dir}")
    return paths


def write_config(config: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(config, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.ledger.is_file():
        print(f"Ledger not found: {args.ledger}", file=sys.stderr)
        return 2
    if not args.overlay_schema.is_file():
        print(f"Overlay schema not found: {args.overlay_schema}", file=sys.stderr)
        return 2

    if args.stdout and (args.all or len(args.overlays) != 1):
        print("--stdout requires exactly one overlay path", file=sys.stderr)
        return 2
    if not args.all and not args.overlays:
        parser.error("provide overlay path(s) or --all")
    if args.all and args.overlays:
        print("Do not combine overlay paths with --all", file=sys.stderr)
        return 2

    overlay_paths = (
        discover_overlays(args.overlays_dir) if args.all else list(args.overlays)
    )

    overlay_schema = load_json(args.overlay_schema)
    if not isinstance(overlay_schema, dict):
        raise SystemExit("Overlay schema root must be a JSON object")
    ledger = load_json(args.ledger)
    deployments_by_id = index_deployments(ledger)

    rendered: list[tuple[str, dict[str, Any]]] = []
    for overlay_path in overlay_paths:
        if not overlay_path.is_file():
            raise SystemExit(f"Overlay not found: {overlay_path}")
        overlay = validate_overlay(
            load_json(overlay_path), overlay_schema, overlay_path
        )
        config = render_config(overlay, deployments_by_id, overlay_path)
        rendered.append((overlay["overlayId"], config))

    if args.stdout:
        _, config = rendered[0]
        json.dump(config, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    for overlay_id, config in rendered:
        out_path = args.out_dir / f"{overlay_id}.json"
        write_config(config, out_path)
        print(f"Wrote {out_path} ({len(config['contracts'])} contracts)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

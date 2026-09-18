"""Tests for Diffyscan config rendering from the ledger.

These cover the review findings around explorer routing, per-cohort gates,
commit pinning, and output-path safety — behaviours that a known-good ledger
alone would never exercise.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

import render_diffyscan_config as render


PROXY = "0x1111111111111111111111111111111111111111"
IMPL = "0x2222222222222222222222222222222222222222"


def deployment(
    address: str,
    *,
    network: str = "eip155:1",
    name: str = "Example",
    repo: str = "https://github.com/lidofinance/lido-l2",
    commit: str | None = "082e7eb59de63bd376b30886568813408d04f00b",
) -> dict[str, Any]:
    source: dict[str, Any] | None
    if repo is None:
        source = None
    elif commit is None:
        source = {"repositoryUrl": repo}
    else:
        source = {"repositoryUrl": repo, "commit": commit}
    return {
        "deploymentId": f"{network}:{address}",
        "contractId": "example-role",
        "deploymentKind": "standalone",
        "contractName": name,
        "address": address,
        "networkId": network,
        "source": source,
        "auditReportRefs": [],
    }


def mini_ledger(*deployments: dict[str, Any]) -> dict[str, Any]:
    return {
        "$schema": "./ledger.schema.json",
        "schemaVersion": "0.2.0",
        "updatedAt": "2026-08-07",
        "networks": {
            "eip155:1": {
                "networkName": "ethereum-mainnet",
                "chainFamily": "ethereum",
                "environment": "mainnet",
            },
            "eip155:324": {
                "networkName": "zksync-era",
                "chainFamily": "zksync",
                "environment": "mainnet",
            },
            "eip155:5000": {
                "networkName": "mantle-mainnet",
                "chainFamily": "mantle",
                "environment": "mainnet",
            },
        },
        "deployments": list(deployments),
    }


def mini_profile(
    *,
    profile_id: str = "lido-l2",
    repo: str = "https://github.com/lidofinance/lido-l2",
    commits: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "$schema": "./profile.schema.json",
        "profileId": profile_id,
        "repositoryUrl": repo,
        "default": {
            "github_repo": {"relative_root": ""},
            "dependencies": {
                "@openzeppelin/contracts": {
                    "url": "https://github.com/OpenZeppelin/openzeppelin-contracts",
                    "commit": "d4fb3a89f9d0a39c7ee6f2601d33ffbf30085322",
                    "relative_root": "contracts",
                }
            },
        },
        "commits": commits
        if commits is not None
        else {"082e7eb59de63bd376b30886568813408d04f00b": {}},
    }


def mini_networks() -> dict[str, Any]:
    return {
        "$schema": "./networks.schema.json",
        "default": {
            "explorer_hostname": "api.etherscan.io",
            "explorer_token_env_var": "ETHERSCAN_EXPLORER_TOKEN",
        },
        "networks": {
            "eip155:324": {
                "explorer_hostname": "zksync2-mainnet-explorer.zksync.io"
            },
            "eip155:5000": {"explorer_hostname": "explorer.mantle.xyz"},
        },
    }


def test_non_etherscan_hostnames_are_overrides_not_defaults() -> None:
    networks = mini_networks()
    assert (
        render.resolve_network_settings(networks, "eip155:1")["explorer_hostname"]
        == "api.etherscan.io"
    )
    assert (
        render.resolve_network_settings(networks, "eip155:324")["explorer_hostname"]
        == "zksync2-mainnet-explorer.zksync.io"
    )


# Chains the unified Etherscan API does not serve (api.etherscan.io/v2/chainlist).
# Each needs its own explorer_hostname or its cohorts silently fall back to
# Etherscan and fail at fetch time with no pre-flight signal.
NON_ETHERSCAN_CHAINS = {
    "eip155:324": "zksync-era",
    "eip155:1135": "lisk-mainnet",
    "eip155:1868": "soneium-mainnet",
    "eip155:1923": "swellchain-mainnet",
    "eip155:34443": "mode-mainnet",
    "eip155:534352": "scroll-mainnet",
}


def test_shipped_networks_override_every_non_etherscan_chain() -> None:
    networks = render.load_json(render.DEFAULT_NETWORKS)
    default_host = networks["default"]["explorer_hostname"]
    for network_id, slug in NON_ETHERSCAN_CHAINS.items():
        resolved = render.resolve_network_settings(networks, network_id)
        assert resolved["explorer_hostname"] != default_host, (
            f"{slug} ({network_id}) has no explorer override and would fall back "
            f"to {default_host}, which does not serve that chain"
        )


# Chains the unified Etherscan API does serve, so inheriting the default
# hostname is correct for them. Any in-use network in neither this set nor
# NON_ETHERSCAN_CHAINS is unclassified and must not silently inherit Etherscan.
ETHERSCAN_SERVED_CHAINS = {
    "eip155:1",
    "eip155:10",
    "eip155:56",
    "eip155:130",
    "eip155:137",
    "eip155:5000",
    "eip155:8453",
    "eip155:42161",
    "eip155:59144",
    "eip155:560048",
}


def test_every_in_use_network_is_classified_not_silently_defaulted() -> None:
    """A new chain must force a decision rather than inherit api.etherscan.io.

    resolve_network_settings always yields the default hostname, so asserting
    that it resolves proves nothing. What matters is whether the chain is one
    Etherscan actually serves.
    """
    ledger = render.load_json(render.DEFAULT_LEDGER)
    networks = render.load_json(render.DEFAULT_NETWORKS)
    in_use = {
        entry["networkId"]
        for entry in ledger["deployments"]
        if isinstance(entry.get("source"), dict)
        and entry["source"].get("repositoryUrl")
        and entry["source"].get("commit")
    }
    unclassified = sorted(
        in_use - ETHERSCAN_SERVED_CHAINS - set(NON_ETHERSCAN_CHAINS)
    )
    assert not unclassified, (
        f"networks {unclassified} are rendered into cohorts but are in neither "
        "ETHERSCAN_SERVED_CHAINS nor NON_ETHERSCAN_CHAINS; classify them (and "
        "add a networks.json override if Etherscan does not serve them) rather "
        "than letting them inherit the default hostname"
    )
    for network_id in sorted(in_use & set(NON_ETHERSCAN_CHAINS)):
        resolved = render.resolve_network_settings(networks, network_id)
        assert resolved["explorer_hostname"] != networks["default"]["explorer_hostname"]


def test_network_override_null_drops_inherited_key() -> None:
    networks = mini_networks()
    networks["networks"]["eip155:324"]["explorer_token_env_var"] = None
    resolved = render.resolve_network_settings(networks, "eip155:324")
    assert "explorer_token_env_var" not in resolved
    # Unrelated networks keep the inherited default.
    assert (
        render.resolve_network_settings(networks, "eip155:1")["explorer_token_env_var"]
        == "ETHERSCAN_EXPLORER_TOKEN"
    )


def test_blocked_cohort_does_not_suppress_healthy_writes(tmp_path: Path) -> None:
    ledger = mini_ledger(
        deployment(PROXY),
        deployment(
            IMPL,
            repo="https://github.com/example/missing-profile",
            commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ),
    )
    profiles = {
        render.normalize_repo_url("https://github.com/lidofinance/lido-l2"): mini_profile()
    }
    rendered, blockers = render.render_from_ledger(
        ledger,
        render.index_deployments(ledger),
        profiles_by_url=profiles,
        networks_map=mini_networks(),
    )
    assert len(rendered) == 1
    assert blockers["missing_profile"] == [f"eip155:1:{IMPL}"]

    out_dir = tmp_path / "generated"
    out_dir.mkdir()
    stale = out_dir / (
        "ethereum-mainnet__lido-l2__" + "b" * 40 + ".json"
    )
    stale.write_text("{}\n", encoding="utf-8")

    keep = {f"{cid}.json" for cid, _ in rendered}
    for cid, config in rendered:
        render.write_config(config, out_dir / f"{cid}.json")
    removed = render.prune_stale_generated(out_dir, keep)
    assert stale.name in removed
    assert not stale.exists()
    assert len(list(out_dir.glob("*.json"))) == 1


def test_prune_leaves_files_this_script_does_not_own(tmp_path: Path) -> None:
    """An overlay rendered into the same directory must survive --from-ledger."""
    out_dir = tmp_path / "generated"
    out_dir.mkdir()
    overlay_out = out_dir / "optimism-lido-l2-with-steth.json"
    overlay_out.write_text("{}\n", encoding="utf-8")
    stale_cohort = out_dir / ("optimism-mainnet__lido-l2__" + "c" * 40 + ".json")
    stale_cohort.write_text("{}\n", encoding="utf-8")

    removed = render.prune_stale_generated(out_dir, keep_names=set())

    assert removed == [stale_cohort.name]
    assert overlay_out.exists()


def test_commit_case_neither_blocks_nor_collides() -> None:
    """Git hex is case-insensitive; one ledger must not yield two cohorts."""
    lower = "082e7eb59de63bd376b30886568813408d04f00b"
    profile = mini_profile()  # pins the lowercase form
    assert render.resolve_profile_settings(profile, lower.upper()) is not None

    ledger = mini_ledger(
        deployment(PROXY, commit=lower),
        deployment(IMPL, commit=lower.upper()),
    )
    profiles = {
        render.normalize_repo_url("https://github.com/lidofinance/lido-l2"): profile
    }
    rendered, blockers = render.render_from_ledger(
        ledger,
        render.index_deployments(ledger),
        profiles_by_url=profiles,
        networks_map=mini_networks(),
    )
    assert len(rendered) == 1
    assert len(rendered[0][1]["contracts"]) == 2
    assert blockers["unpinned_commit"] == []


def test_unusable_repository_url_blocks_only_its_own_deployment() -> None:
    ledger = mini_ledger(
        deployment(PROXY),
        deployment(IMPL, repo="github.com/lidofinance/lido-l2"),  # no scheme
    )
    profiles = {
        render.normalize_repo_url("https://github.com/lidofinance/lido-l2"): mini_profile()
    }
    rendered, blockers = render.render_from_ledger(
        ledger,
        render.index_deployments(ledger),
        profiles_by_url=profiles,
        networks_map=mini_networks(),
    )
    assert len(rendered) == 1
    assert blockers["invalid_source"] == [f"eip155:1:{IMPL}"]


def test_exit_code_separates_reported_gaps_from_regressions() -> None:
    """A ledger with no source recorded is a gap; a config gap is a regression."""
    assert render.blocked_exit_code({"missing_commit": ["a"], "null_source": ["b"]}) == 0
    assert render.blocked_exit_code({"missing_profile": ["a"]}) == render.EXIT_BLOCKED
    assert render.blocked_exit_code({"unpinned_commit": ["a"]}) == render.EXIT_BLOCKED
    assert render.blocked_exit_code({"invalid_source": ["a"]}) == render.EXIT_BLOCKED
    assert render.blocked_exit_code({"missing_network_meta": ["a"]}) == render.EXIT_BLOCKED
    assert render.blocked_exit_code({}) == 0


def test_unpinned_commit_is_blocked_not_silent_default() -> None:
    profile = mini_profile(commits={})  # no pins
    assert render.resolve_profile_settings(profile, "082e7eb59de63bd376b30886568813408d04f00b") is None

    ledger = mini_ledger(deployment(PROXY))
    profiles = {
        render.normalize_repo_url("https://github.com/lidofinance/lido-l2"): profile
    }
    rendered, blockers = render.render_from_ledger(
        ledger,
        render.index_deployments(ledger),
        profiles_by_url=profiles,
        networks_map=mini_networks(),
    )
    assert rendered == []
    assert blockers["unpinned_commit"] == [f"eip155:1:{PROXY}"]


def test_duplicate_deployment_id_is_rejected() -> None:
    ledger = mini_ledger(deployment(PROXY), deployment(PROXY))
    with pytest.raises(SystemExit, match="Duplicate deploymentId"):
        render.index_deployments(ledger)


def test_unsafe_network_name_cannot_escape_out_dir() -> None:
    ledger = mini_ledger(deployment(PROXY))
    ledger["networks"]["eip155:1"]["networkName"] = "../../pwned"
    with pytest.raises(SystemExit, match="must be a slug"):
        render.require_network_slug(ledger, "eip155:1")


def test_repo_url_normalization_matches_profile_lookup() -> None:
    profile = mini_profile(repo="https://github.com/lidofinance/lido-l2/")
    profiles = {
        render.normalize_repo_url(profile["repositoryUrl"]): {
            **profile,
            "repositoryUrl": render.normalize_repo_url(profile["repositoryUrl"]),
        }
    }
    ledger = mini_ledger(
        deployment(
            PROXY,
            repo="https://github.com/lidofinance/lido-l2.git",
        )
    )
    rendered, blockers = render.render_from_ledger(
        ledger,
        render.index_deployments(ledger),
        profiles_by_url=profiles,
        networks_map=mini_networks(),
    )
    assert len(rendered) == 1
    assert blockers["missing_profile"] == []


def test_coverage_rejects_overlay_combo(capsys: pytest.CaptureFixture[str]) -> None:
    code = render.main(["--coverage", "--all"])
    assert code == 2
    err = capsys.readouterr().err
    assert "Do not combine --coverage" in err


def test_duplicate_profile_id_is_rejected(tmp_path: Path) -> None:
    profile_schema = render.load_json(render.DEFAULT_PROFILE_SCHEMA)
    for name, repo in (
        ("a.json", "https://github.com/example/one"),
        ("b.json", "https://github.com/example/two"),
    ):
        (tmp_path / name).write_text(
            json.dumps(
                {
                    "$schema": "./profile.schema.json",
                    "profileId": "same-id",
                    "repositoryUrl": repo,
                    "default": {"github_repo": {"relative_root": ""}},
                    "commits": {"0" * 40: {}},
                }
            ),
            encoding="utf-8",
        )
    with pytest.raises(SystemExit, match="Duplicate profileId"):
        render.load_profiles(tmp_path, profile_schema)


def _write_fixture_tree(tmp_path: Path, *, pin_commit: bool) -> tuple[Path, Path, Path]:
    """A ledger + profile + networks trio main() can be pointed at."""
    ledger_path = tmp_path / "ledger.json"
    ledger_path.write_text(json.dumps(mini_ledger(deployment(PROXY))), encoding="utf-8")
    profiles_dir = tmp_path / "profiles"
    profiles_dir.mkdir()
    profile = mini_profile()
    profile["$schema"] = "./profile.schema.json"
    if not pin_commit:
        profile["commits"] = {"f" * 40: {}}  # pins some other revision
    (profiles_dir / "lido-l2.json").write_text(json.dumps(profile), encoding="utf-8")
    networks_path = tmp_path / "networks.json"
    networks_path.write_text(json.dumps(mini_networks()), encoding="utf-8")
    return ledger_path, profiles_dir, networks_path


def _run_coverage(tmp_path: Path, *, pin_commit: bool) -> int:
    ledger_path, profiles_dir, networks_path = _write_fixture_tree(
        tmp_path, pin_commit=pin_commit
    )
    return render.main(
        [
            "--coverage",
            "--ledger", str(ledger_path),
            "--profiles-dir", str(profiles_dir),
            "--networks", str(networks_path),
        ]
    )


def test_main_returns_ok_when_everything_projects(tmp_path: Path) -> None:
    assert _run_coverage(tmp_path, pin_commit=True) == render.EXIT_OK


def test_main_returns_blocked_when_a_pinned_revision_is_missing(tmp_path: Path) -> None:
    """CI and the justfile both key off this; assert the wiring, not just the helper."""
    assert _run_coverage(tmp_path, pin_commit=False) == render.EXIT_BLOCKED


def test_case_colliding_commit_pins_are_rejected(tmp_path: Path) -> None:
    profile_schema = render.load_json(render.DEFAULT_PROFILE_SCHEMA)
    commit = "082e7eb59de63bd376b30886568813408d04f00b"
    profile = mini_profile()
    profile["commits"] = {commit: {}, commit.upper(): {}}
    (tmp_path / "p.json").write_text(json.dumps(profile), encoding="utf-8")
    with pytest.raises(SystemExit, match="differ only in"):
        render.load_profiles(tmp_path, profile_schema)


def test_repo_networks_and_profiles_validate_against_schemas() -> None:
    networks_schema = render.load_json(render.DEFAULT_NETWORKS_SCHEMA)
    profile_schema = render.load_json(render.DEFAULT_PROFILE_SCHEMA)
    render.validate_json_schema(
        render.load_json(render.DEFAULT_NETWORKS),
        networks_schema,
        label="networks.json",
    )
    for path in sorted(render.DEFAULT_PROFILES_DIR.glob("*.json")):
        render.validate_json_schema(
            render.load_json(path), profile_schema, label=str(path)
        )

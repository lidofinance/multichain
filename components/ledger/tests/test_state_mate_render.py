"""Tests for state-mate linkage config rendering from the ledger.

The rendered configs assert what the ledger already says, so a known-good
ledger exercises almost none of the ways this can go wrong: a stale
expectation that quietly stops asserting anything, a proxy kind whose storage
layout was guessed, an alias that never resolves. Those are what is covered
here.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import pytest

import render_state_mate_config as render


PROXY = "0x1111111111111111111111111111111111111111"
IMPL = "0x2222222222222222222222222222222222222222"
ADMIN = "0x3333333333333333333333333333333333333333"

IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"


def deployment(
    address: str,
    *,
    kind: str = "standalone",
    contract_id: str = "example-role",
    name: str = "Example",
    network: str = "eip155:34443",
    proxy: dict[str, Any] | None = None,
) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "deploymentId": f"{network}:{address}",
        "contractId": contract_id,
        "deploymentKind": kind,
        "contractName": name,
        "address": address,
        "networkId": network,
        "source": None,
        "auditReportRefs": [],
    }
    if proxy is not None:
        entry["proxy"] = proxy
    return entry


def proxy_trio(
    *,
    proxy_kind: str = "ossifiable",
    proxy_name: str = "OssifiableProxy",
    network: str = "eip155:34443",
    admin_in_ledger: bool = False,
) -> list[dict[str, Any]]:
    relation: dict[str, Any] = {
        "proxyKind": proxy_kind,
        "implementationDeploymentId": f"{network}:{IMPL}",
    }
    if admin_in_ledger:
        relation["adminDeploymentId"] = f"{network}:{ADMIN}"
    return [
        deployment(
            PROXY, kind="proxy", name=proxy_name, network=network, proxy=relation
        ),
        deployment(IMPL, kind="implementation", name="Token", network=network),
        deployment(
            ADMIN,
            kind="proxy-admin" if admin_in_ledger else "standalone",
            contract_id="example-role-admin" if admin_in_ledger else "example-admin",
            name="ProxyAdmin" if admin_in_ledger else "BridgeExecutor",
            network=network,
        ),
    ]


def mini_ledger(*deployments: dict[str, Any]) -> dict[str, Any]:
    return {
        "$schema": "./components/ledger/ledger.schema.json",
        "schemaVersion": "0.2.0",
        "updatedAt": "2026-08-14",
        "networks": {
            "eip155:34443": {
                "networkName": "mode-mainnet",
                "chainFamily": "op-stack",
                "environment": "mainnet",
            },
            "eip155:1": {
                "networkName": "ethereum-mainnet",
                "chainFamily": "ethereum",
                "environment": "mainnet",
            },
        },
        "deployments": list(deployments),
    }


def mini_proxy_kinds() -> dict[str, Any]:
    return {
        "$schema": "./proxy-kinds.schema.json",
        "proxyKinds": {
            "ossifiable": {
                "description": "test",
                "verifiedOn": "2026-08-18",
                "storageSlots": {"implementation": IMPL_SLOT, "admin": ADMIN_SLOT},
            },
            "erc1967": {
                "description": "test",
                "verifiedOn": "2026-08-18",
                "storageSlots": {"implementation": IMPL_SLOT},
            },
        },
        "proxyAbis": {
            "OssifiableProxy": {
                "description": "test",
                "views": {
                    "implementation": "proxy__getImplementation",
                    "admin": "proxy__getAdmin",
                    "ossified": "proxy__getIsOssified",
                },
                "abi": [
                    {
                        "inputs": [],
                        "name": "proxy__getImplementation",
                        "outputs": [],
                        "stateMutability": "view",
                        "type": "function",
                    },
                    {
                        "inputs": [],
                        "name": "proxy__getAdmin",
                        "outputs": [],
                        "stateMutability": "view",
                        "type": "function",
                    },
                    {
                        "inputs": [],
                        "name": "proxy__getIsOssified",
                        "outputs": [],
                        "stateMutability": "view",
                        "type": "function",
                    },
                    {
                        "inputs": [],
                        "name": "proxy__ossify",
                        "outputs": [],
                        "stateMutability": "nonpayable",
                        "type": "function",
                    },
                ],
            }
        },
    }


def mini_networks() -> dict[str, Any]:
    return {
        "$schema": "./networks.schema.json",
        "networks": {
            "eip155:34443": {
                "rpcUrlEnv": "MODE_MAINNET_RPC_URL",
                "publicRpcUrl": "https://mainnet.mode.network",
                "publicRpcCheckedOn": "2026-08-18",
            }
        },
    }


def render_ledger(
    ledger: dict[str, Any],
    *,
    expectations: dict[str, Any] | None = None,
    networks: dict[str, Any] | None = None,
    proxy_kinds: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, list[str]]]:
    deployments_by_id = render.index_deployments(ledger)
    resolved = render.resolve_expectations(
        {"expectations": expectations or {}}, deployments_by_id
    )
    return render.render_from_ledger(
        ledger,
        deployments_by_id,
        proxy_kinds_doc=proxy_kinds or mini_proxy_kinds(),
        networks_map=networks or mini_networks(),
        expectations=resolved,
    )


def only_contract(rendered: list[dict[str, Any]]) -> dict[str, Any]:
    assert len(rendered) == 1
    contracts = rendered[0]["contracts"]
    assert len(contracts) == 1
    return next(iter(contracts.values()))


# --------------------------------------------------------------------------
# expectations must never fail open
# --------------------------------------------------------------------------


def test_expectation_for_a_missing_deployment_is_fatal() -> None:
    ledger = mini_ledger(*proxy_trio())
    with pytest.raises(SystemExit, match="not in the ledger"):
        render_ledger(
            ledger,
            expectations={
                "eip155:34443:0x9999999999999999999999999999999999999999": {
                    "adminDeploymentId": f"eip155:34443:{ADMIN}",
                    "basis": "chain-baseline",
                    "observedOn": "2026-08-18",
                    "note": "stale",
                }
            },
        )


def test_expectation_on_a_non_proxy_is_fatal() -> None:
    ledger = mini_ledger(*proxy_trio())
    with pytest.raises(SystemExit, match="not a proxy"):
        render_ledger(
            ledger,
            expectations={
                f"eip155:34443:{IMPL}": {"note": "wrong entry kind"},
            },
        )


def test_expectation_contradicting_the_ledger_is_fatal() -> None:
    """Preferring one side silently would hide the disagreement in a green run."""
    ledger = mini_ledger(*proxy_trio(admin_in_ledger=True))
    ledger["deployments"].append(
        deployment(
            "0x4444444444444444444444444444444444444444",
            contract_id="other-admin",
            name="ProxyAdmin",
            kind="proxy-admin",
        )
    )
    with pytest.raises(SystemExit, match="while the ledger records"):
        render_ledger(
            ledger,
            expectations={
                f"eip155:34443:{PROXY}": {
                    "adminDeploymentId": (
                        "eip155:34443:0x4444444444444444444444444444444444444444"
                    ),
                    "basis": "chain-baseline",
                    "observedOn": "2026-08-18",
                    "note": "disagrees",
                }
            },
        )


def test_expected_admin_on_another_network_is_fatal() -> None:
    ledger = mini_ledger(*proxy_trio())
    ledger["deployments"].append(
        deployment(ADMIN, contract_id="l1-admin", network="eip155:1")
    )
    with pytest.raises(SystemExit, match="but the proxy is on"):
        render_ledger(
            ledger,
            expectations={
                f"eip155:34443:{PROXY}": {
                    "adminDeploymentId": f"eip155:1:{ADMIN}",
                    "basis": "chain-baseline",
                    "observedOn": "2026-08-18",
                    "note": "wrong chain",
                }
            },
        )


def test_admin_that_could_never_be_checked_is_fatal() -> None:
    """erc1967 has no admin slot and no admin view, so the assertion is inert."""
    ledger = mini_ledger(
        *proxy_trio(proxy_kind="erc1967", proxy_name="ERC1967Proxy")
    )
    with pytest.raises(SystemExit, match="could never run"):
        render_ledger(
            ledger,
            expectations={
                f"eip155:34443:{PROXY}": {
                    "adminDeploymentId": f"eip155:34443:{ADMIN}",
                    "basis": "chain-baseline",
                    "observedOn": "2026-08-18",
                    "note": "inert",
                }
            },
        )


# --------------------------------------------------------------------------
# projection
# --------------------------------------------------------------------------


def test_admin_is_not_asserted_when_nothing_names_one() -> None:
    """Absence must leave the check out, not invent a plausible address."""
    rendered, _ = render_ledger(mini_ledger(*proxy_trio()))
    entry = only_contract(rendered)
    assert entry["_facts"]["adminBasis"] is None
    assert [item["label"] for item in entry["storage"]] == ["implementation slot"]
    assert entry["proxyChecks"]["proxy__getAdmin"] is None
    # Ossification is derived from an asserted admin; with no admin there is
    # nothing to derive it from.
    assert entry["proxyChecks"]["proxy__getIsOssified"] is None


def test_ossification_is_derived_from_an_asserted_admin() -> None:
    rendered, _ = render_ledger(
        mini_ledger(*proxy_trio()),
        expectations={
            f"eip155:34443:{PROXY}": {
                "adminDeploymentId": f"eip155:34443:{ADMIN}",
                "basis": "chain-baseline",
                "observedOn": "2026-08-18",
                "note": "seeded",
            }
        },
    )
    entry = only_contract(rendered)
    assert entry["proxyChecks"]["proxy__getIsOssified"] is False
    assert entry["_facts"]["adminBasis"] == "expectations:chain-baseline"


def test_declared_ossification_wins_over_the_derived_value() -> None:
    rendered, _ = render_ledger(
        mini_ledger(*proxy_trio()),
        expectations={
            f"eip155:34443:{PROXY}": {
                "ossified": True,
                "basis": "governance-record",
                "note": "ossified by vote",
            }
        },
    )
    assert only_contract(rendered)["proxyChecks"]["proxy__getIsOssified"] is True


def test_every_non_mutable_in_the_shipped_abi_is_covered() -> None:
    """state-mate reports an uncovered non-mutable as an error, per section."""
    rendered, _ = render_ledger(mini_ledger(*proxy_trio()))
    entry = only_contract(rendered)
    abi_views = {
        fragment["name"]
        for fragment in mini_proxy_kinds()["proxyAbis"]["OssifiableProxy"]["abi"]
        if fragment["stateMutability"] == "view"
    }
    assert set(entry["checks"]) == abi_views
    assert set(entry["proxyChecks"]) == abi_views
    # The mutable function is not a check and must not appear as one.
    assert "proxy__ossify" not in entry["checks"]


def test_proxy_with_no_shipped_abi_falls_back_to_storage_only() -> None:
    rendered, _ = render_ledger(
        mini_ledger(*proxy_trio(proxy_kind="erc1967", proxy_name="ERC1967Proxy"))
    )
    entry = only_contract(rendered)
    assert "proxyChecks" not in entry
    assert entry["checks"] == {}
    assert entry["_facts"]["viewsAsserted"] == []
    assert [item["label"] for item in entry["storage"]] == ["implementation slot"]


def test_unmapped_proxy_kind_blocks_only_its_own_proxy() -> None:
    healthy = proxy_trio()
    exotic = deployment(
        "0x5555555555555555555555555555555555555555",
        kind="proxy",
        contract_id="aragon-role",
        name="AppProxyUpgradeable",
        proxy={
            "proxyKind": "custom",
            "implementationDeploymentId": f"eip155:34443:{IMPL}",
        },
    )
    rendered, blockers = render_ledger(mini_ledger(*healthy, exotic))
    assert len(rendered[0]["contracts"]) == 1
    assert blockers["unmapped_proxy_kind"] == [exotic["deploymentId"]]
    # A research gap in proxy-kinds.json, not a regression in the render.
    assert render.blocked_exit_code(blockers) == render.EXIT_OK


def test_missing_network_rpc_is_a_regression_not_a_reported_gap() -> None:
    rendered, blockers = render_ledger(
        mini_ledger(*proxy_trio()),
        networks={"$schema": "./networks.schema.json", "networks": {}},
    )
    assert rendered == []
    assert blockers["missing_network_rpc"] == [f"eip155:34443:{PROXY}"]
    assert render.blocked_exit_code(blockers) == render.EXIT_BLOCKED


# --------------------------------------------------------------------------
# emission
# --------------------------------------------------------------------------


def test_every_alias_resolves_to_an_anchor_declared_before_it() -> None:
    """A dangling alias is a YAML parse error at run time, not at render time."""
    rendered, _ = render_ledger(
        mini_ledger(*proxy_trio(admin_in_ledger=True)),
    )
    text = render.emit_config(
        rendered[0],
        ledger=mini_ledger(),
        use_public_rpc=False,
    )
    declared: set[str] = set()
    for line in text.splitlines():
        for anchor in re.findall(r"&([A-Za-z0-9_-]+)", line):
            assert anchor not in declared, f"duplicate anchor {anchor}"
            declared.add(anchor)
        for alias in re.findall(r"(?<![&\w])\*([A-Za-z0-9_-]+)", line):
            assert alias in declared, f"alias *{alias} used before its anchor"
    assert declared


def test_public_rpc_is_opt_in_and_named_in_the_header() -> None:
    rendered, _ = render_ledger(mini_ledger(*proxy_trio()))
    env = render.emit_config(
        rendered[0],
        ledger=mini_ledger(),
        use_public_rpc=False,
    )
    assert "rpcUrl: MODE_MAINNET_RPC_URL" in env
    assert "https://mainnet.mode.network" not in env

    public = render.emit_config(
        rendered[0],
        ledger=mini_ledger(),
        use_public_rpc=True,
    )
    assert "rpcUrl: https://mainnet.mode.network" in public
    assert "unauthenticated public endpoint" in public


def test_prune_leaves_directories_this_script_does_not_own(tmp_path: Path) -> None:
    ours = tmp_path / "mode-mainnet"
    (ours / "abi").mkdir(parents=True)
    (ours / render.CONFIG_NAME).write_text("---\n")
    theirs = tmp_path / "scratch-notes"
    theirs.mkdir()
    (theirs / "notes.md").write_text("keep me")

    removed = render.prune_stale_generated(tmp_path, keep=set())
    assert removed == ["mode-mainnet"]
    assert not ours.exists()
    assert (theirs / "notes.md").is_file()


# --------------------------------------------------------------------------
# the shipped files
# --------------------------------------------------------------------------


def test_repo_state_mate_files_validate_against_their_schemas() -> None:
    for instance_path, schema_path in (
        (render.DEFAULT_NETWORKS, render.DEFAULT_NETWORKS_SCHEMA),
        (render.DEFAULT_PROXY_KINDS, render.DEFAULT_PROXY_KINDS_SCHEMA),
        (render.DEFAULT_EXPECTATIONS, render.DEFAULT_EXPECTATIONS_SCHEMA),
    ):
        render.validate_json_schema(
            render.load_json(instance_path),
            render.load_json(schema_path),
            label=str(instance_path),
        )


def test_every_network_carrying_a_proxy_has_an_rpc_entry() -> None:
    """Otherwise its proxies are silently outside every run."""
    ledger = render.load_json(render.DEFAULT_LEDGER)
    networks = render.load_json(render.DEFAULT_NETWORKS)["networks"]
    with_proxies = {
        entry["networkId"]
        for entry in ledger["deployments"]
        if entry["deploymentKind"] == "proxy"
    }
    assert with_proxies - set(networks) == set()


def test_shipped_expectations_leave_no_silent_gap() -> None:
    """Every checkable proxy either asserts an admin or says why it cannot.

    Without this, dropping an expectation would just move a proxy into the
    "admin not asserted" column, where a passing run looks exactly the same.
    """
    ledger = render.load_json(render.DEFAULT_LEDGER)
    proxy_kinds_doc = render.load_json(render.DEFAULT_PROXY_KINDS)
    expectations = render.load_json(render.DEFAULT_EXPECTATIONS)["expectations"]

    unexplained = []
    for entry in ledger["deployments"]:
        if entry["deploymentKind"] != "proxy":
            continue
        kind = proxy_kinds_doc["proxyKinds"].get(entry["proxy"]["proxyKind"])
        if kind is None or "admin" not in kind["storageSlots"]:
            continue
        if entry["proxy"].get("adminDeploymentId"):
            continue
        if entry["deploymentId"] not in expectations:
            unexplained.append(entry["deploymentId"])
    assert unexplained == []


def test_shipped_proxy_kinds_record_what_they_were_verified_against() -> None:
    """A slot constant asserted from memory is the one bug nothing else catches."""
    proxy_kinds_doc = render.load_json(render.DEFAULT_PROXY_KINDS)
    ledger_ids = {
        entry["deploymentId"] for entry in render.load_json(render.DEFAULT_LEDGER)["deployments"]
    }
    for name, kind in proxy_kinds_doc["proxyKinds"].items():
        assert kind.get("verifiedAgainst"), f"{name} names no verified deployment"
        for deployment_id in kind["verifiedAgainst"]:
            assert deployment_id in ledger_ids, (
                f"{name} was verified against {deployment_id}, which is not in "
                "the ledger"
            )


# --------------------------------------------------------------------------
# declared administrators (addresses the ledger does not hold)
# --------------------------------------------------------------------------


AGENT = "0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c"


def declared_agent() -> dict[str, Any]:
    return {
        "adminAddress": AGENT,
        "adminLabel": "lido-dao-agent",
        "basis": "chain-baseline",
        "observedOn": "2026-08-18",
        "note": "not a ledger entry",
    }


def test_declared_admin_is_asserted_and_marked_as_declared() -> None:
    ledger = mini_ledger(*proxy_trio())
    rendered, _ = render_ledger(
        ledger, expectations={f"eip155:34443:{PROXY}": declared_agent()}
    )
    entry = only_contract(rendered)
    assert entry["_facts"]["adminBasis"] == "declared:chain-baseline"
    assert entry["_facts"]["adminAddress"] == AGENT
    assert entry["_facts"]["adminDeploymentId"] is None
    assert [item["label"] for item in entry["storage"]] == [
        "implementation slot",
        "admin slot",
    ]

    text = render.emit_config(rendered[0], ledger=ledger, use_public_rpc=False)
    assert f'&lido-dao-agent "{AGENT}"' in text
    # A reader must be able to tell this address apart from the ledger-derived
    # ones without opening another file.
    assert "DECLARED in" in text
    assert "*lido-dao-agent" in text


def test_declared_admin_the_ledger_already_lists_is_fatal() -> None:
    """Two names for one address drift; the ledger's is the maintained one."""
    ledger = mini_ledger(*proxy_trio())
    with pytest.raises(SystemExit, match="use adminDeploymentId instead"):
        render_ledger(
            ledger,
            expectations={
                f"eip155:34443:{PROXY}": {
                    "adminAddress": ADMIN,
                    "adminLabel": "bridge-executor",
                    "basis": "chain-baseline",
                    "observedOn": "2026-08-18",
                    "note": "already in the ledger",
                }
            },
        )


def test_one_label_cannot_name_two_addresses_on_a_network() -> None:
    second = deployment(
        "0x6666666666666666666666666666666666666666",
        kind="proxy",
        contract_id="other-role",
        name="OssifiableProxy",
        proxy={
            "proxyKind": "ossifiable",
            "implementationDeploymentId": f"eip155:34443:{IMPL}",
        },
    )
    ledger = mini_ledger(*proxy_trio(), second)
    other = declared_agent() | {
        "adminAddress": "0x7777777777777777777777777777777777777777"
    }
    with pytest.raises(SystemExit, match="adminLabel 'lido-dao-agent' names"):
        render_ledger(
            ledger,
            expectations={
                f"eip155:34443:{PROXY}": declared_agent(),
                second["deploymentId"]: other,
            },
        )


def test_schema_rejects_naming_the_admin_both_ways() -> None:
    schema = render.load_json(render.DEFAULT_EXPECTATIONS_SCHEMA)
    both = declared_agent() | {"adminDeploymentId": f"eip155:34443:{ADMIN}"}
    with pytest.raises(SystemExit, match="Schema validation failed"):
        render.validate_json_schema(
            {
                "$schema": "./expectations.schema.json",
                "expectations": {f"eip155:34443:{PROXY}": both},
            },
            schema,
            label="both forms",
        )


def test_shipped_declared_addresses_are_absent_from_the_ledger() -> None:
    """The point of the declared form is that the ledger has no entry to cite."""
    ledger = render.load_json(render.DEFAULT_LEDGER)
    expectations = render.load_json(render.DEFAULT_EXPECTATIONS)["expectations"]
    for deployment_id, expectation in expectations.items():
        declared = expectation.get("adminAddress")
        if declared is None:
            continue
        network_id = ledger_network_of(ledger, deployment_id)
        listed = {
            entry["address"].lower()
            for entry in ledger["deployments"]
            if entry["networkId"] == network_id
        }
        assert declared.lower() not in listed, (
            f"{deployment_id} declares {declared}, which the ledger already "
            "lists — reference it by deploymentId"
        )


def ledger_network_of(ledger: dict[str, Any], deployment_id: str) -> str:
    for entry in ledger["deployments"]:
        if entry["deploymentId"] == deployment_id:
            return entry["networkId"]
    raise AssertionError(f"{deployment_id} is not in the ledger")

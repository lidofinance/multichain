"""Tests that the ledger validators actually reject what they claim to reject.

Running the validators against the known-good ledger.json only proves they do
not produce false positives. Each test here mutates a well-formed ledger in one
way and asserts the corresponding rule fires, so a validator that silently stops
validating fails CI instead of passing it.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

import pytest

import format_ledger
from _ledger import DEFAULT_LEDGER, DEFAULT_SCHEMA, load_json
from validate_ledger import integrity_errors, schema_errors

PROXY_ADDR = "0x1111111111111111111111111111111111111111"
IMPL_ADDR = "0x2222222222222222222222222222222222222222"
OTHER_ADDR = "0x3333333333333333333333333333333333333333"
BEACON_ADDR = "0x4444444444444444444444444444444444444444"
SOLANA_NET = "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp"


@pytest.fixture(scope="session")
def schema() -> dict[str, Any]:
    return load_json(DEFAULT_SCHEMA)


def entry(
    address: str,
    *,
    network: str = "eip155:1",
    contract_id: str = "example-role",
    kind: str = "standalone",
    name: str = "Example",
    proxy: dict[str, Any] | None = None,
) -> dict[str, Any]:
    record: dict[str, Any] = {
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
        record["proxy"] = proxy
    return record


def ledger(*deployments: dict[str, Any]) -> dict[str, Any]:
    return {
        "$schema": "./components/ledger/ledger.schema.json",
        "schemaVersion": "0.2.0",
        "updatedAt": "2026-08-07",
        "networks": {
            "eip155:1": {
                "networkName": "ethereum-mainnet",
                "chainFamily": "ethereum",
                "environment": "mainnet",
            },
            "eip155:10": {
                "networkName": "optimism-mainnet",
                "chainFamily": "op-stack",
                "environment": "mainnet",
            },
            SOLANA_NET: {
                "networkName": "solana-mainnet",
                "chainFamily": "solana",
                "environment": "mainnet",
            },
        },
        "deployments": list(deployments) or [entry(PROXY_ADDR)],
    }


def check(instance: dict[str, Any], schema: dict[str, Any]) -> list[str]:
    """All errors, schema first. Integrity checks assume a schema-valid input."""
    errors = schema_errors(instance, schema)
    if errors:
        return errors
    return integrity_errors(instance, schema)


def assert_ok(instance: dict[str, Any], schema: dict[str, Any]) -> None:
    assert check(instance, schema) == []


def assert_rejects(instance: dict[str, Any], schema: dict[str, Any], needle: str) -> None:
    errors = check(instance, schema)
    assert errors, f"expected a rejection mentioning {needle!r}, got none"
    assert any(needle in e for e in errors), f"{needle!r} not in {errors}"


# --- the shipped ledger and the fixture baseline both pass -------------------


def test_real_ledger_is_valid(schema: dict[str, Any]) -> None:
    assert_ok(load_json(DEFAULT_LEDGER), schema)


def test_real_ledger_is_canonically_formatted() -> None:
    rendered = format_ledger.render(DEFAULT_LEDGER, DEFAULT_SCHEMA)
    assert rendered == DEFAULT_LEDGER.read_text(encoding="utf-8")


def test_baseline_fixture_is_valid(schema: dict[str, Any]) -> None:
    assert_ok(ledger(), schema)


# --- identity: deploymentId composition and uniqueness -----------------------


def test_rejects_deployment_id_not_composed_from_network_and_address(
    schema: dict[str, Any],
) -> None:
    doc = ledger()
    doc["deployments"][0]["deploymentId"] = "eip155:1:0xdeadbeef"
    assert_rejects(doc, schema, "networkId + ':' + address")


def test_rejects_duplicate_deployment_id(schema: dict[str, Any]) -> None:
    doc = ledger(entry(PROXY_ADDR), entry(PROXY_ADDR, contract_id="other-role"))
    assert_rejects(doc, schema, "duplicate deploymentId")


def test_rejects_same_evm_address_recorded_under_two_casings(
    schema: dict[str, Any],
) -> None:
    """17 of the shipped entries are all-lowercase and the rest are EIP-55.

    Re-adding a lowercase entry from a checksummed source would otherwise
    produce two valid records for one deployment.
    """
    mixed = "0xAbCdeF1234567890AbCdEf1234567890aBcDeF12"
    doc = ledger(
        entry(mixed, contract_id="role-a"),
        entry(mixed.lower(), contract_id="role-b"),
    )
    assert_rejects(doc, schema, "differing only in casing")


def test_case_folding_does_not_apply_to_non_evm_namespaces(
    schema: dict[str, Any],
) -> None:
    """base58 and bech32 addresses are case-sensitive; folding them would be wrong."""
    doc = ledger(
        entry("So11111111111111111111111111111111111111112",
              network=SOLANA_NET, contract_id="role-a"),
        entry("so11111111111111111111111111111111111111112",
              network=SOLANA_NET, contract_id="role-b"),
    )
    assert_ok(doc, schema)


# --- identity: one role instance per network ---------------------------------


def test_rejects_two_live_entries_for_one_role_on_one_network(
    schema: dict[str, Any],
) -> None:
    doc = ledger(entry(PROXY_ADDR), entry(OTHER_ADDR))
    assert_rejects(doc, schema, "-archive contractId suffix")


def test_archive_suffix_disambiguates_a_superseded_role_instance(
    schema: dict[str, Any],
) -> None:
    doc = ledger(entry(PROXY_ADDR), entry(OTHER_ADDR, contract_id="example-role-archive"))
    assert_ok(doc, schema)


def test_same_role_on_two_networks_is_the_normal_l1_l2_pair(
    schema: dict[str, Any],
) -> None:
    doc = ledger(entry(PROXY_ADDR), entry(PROXY_ADDR, network="eip155:10"))
    assert_ok(doc, schema)


def test_proxy_and_implementation_may_share_a_contract_id(
    schema: dict[str, Any],
) -> None:
    """README: a proxy and its implementation jointly fulfil one role."""
    doc = ledger(
        entry(PROXY_ADDR, kind="proxy", proxy={
            "proxyKind": "ossifiable",
            "implementationDeploymentId": f"eip155:1:{IMPL_ADDR}",
        }),
        entry(IMPL_ADDR, kind="implementation"),
    )
    assert_ok(doc, schema)


# --- proxy relations ---------------------------------------------------------


def test_rejects_proxy_referencing_an_implementation_on_another_network(
    schema: dict[str, Any],
) -> None:
    """The likeliest copy-paste error when adding a new L2: entries are added in
    L1/L2 pairs that share a contractId."""
    doc = ledger(
        entry(PROXY_ADDR, kind="proxy", proxy={
            "proxyKind": "ossifiable",
            "implementationDeploymentId": f"eip155:10:{IMPL_ADDR}",
        }),
        entry(IMPL_ADDR, network="eip155:10", kind="implementation"),
    )
    assert_rejects(doc, schema, "must stay within one network")


def test_rejects_proxy_reference_to_the_wrong_deployment_kind(
    schema: dict[str, Any],
) -> None:
    doc = ledger(
        entry(PROXY_ADDR, kind="proxy", proxy={
            "proxyKind": "ossifiable",
            "implementationDeploymentId": f"eip155:1:{IMPL_ADDR}",
        }),
        entry(IMPL_ADDR, kind="standalone", contract_id="other-role"),
    )
    assert_rejects(doc, schema, "expected 'implementation'")


def test_rejects_dangling_proxy_reference(schema: dict[str, Any]) -> None:
    doc = ledger(entry(PROXY_ADDR, kind="proxy", proxy={
        "proxyKind": "ossifiable",
        "implementationDeploymentId": f"eip155:1:{IMPL_ADDR}",
    }))
    assert_rejects(doc, schema, "dangling reference")


def test_rejects_network_id_absent_from_the_networks_map(
    schema: dict[str, Any],
) -> None:
    doc = ledger()
    doc["networks"].pop("eip155:1")
    assert_rejects(doc, schema, "is not a key in $.networks")


# --- proxy architecture: beacon and diamond ----------------------------------


def beacon_trio() -> list[dict[str, Any]]:
    return [
        entry(PROXY_ADDR, kind="proxy", proxy={
            "proxyKind": "beacon",
            "beaconDeploymentId": f"eip155:1:{BEACON_ADDR}",
        }),
        entry(BEACON_ADDR, kind="beacon", name="UpgradeableBeacon", proxy={
            "proxyKind": "beacon",
            "implementationDeploymentId": f"eip155:1:{IMPL_ADDR}",
        }),
        entry(IMPL_ADDR, kind="implementation"),
    ]


def test_beacon_proxy_chain_is_representable(schema: dict[str, Any]) -> None:
    assert_ok(ledger(*beacon_trio()), schema)


def test_beacon_proxy_must_name_its_beacon(schema: dict[str, Any]) -> None:
    trio = beacon_trio()
    del trio[0]["proxy"]["beaconDeploymentId"]
    assert_rejects(ledger(*trio), schema, "'beaconDeploymentId' is a required property")


def test_beacon_proxy_is_not_forced_to_inline_an_implementation(
    schema: dict[str, Any],
) -> None:
    """A beacon proxy resolves through the beacon; an inlined implementation
    address goes stale invisibly on the next beacon upgrade."""
    assert "implementationDeploymentId" not in beacon_trio()[0]["proxy"]
    assert_ok(ledger(*beacon_trio()), schema)


def test_beacon_entry_must_name_its_implementation_when_it_carries_a_link(
    schema: dict[str, Any],
) -> None:
    trio = beacon_trio()
    del trio[1]["proxy"]["implementationDeploymentId"]
    assert_rejects(
        ledger(*trio), schema, "'implementationDeploymentId' is a required property"
    )


def test_diamond_proxy_needs_no_single_implementation(schema: dict[str, Any]) -> None:
    """A diamond has N facets; requiring exactly one would record a false link."""
    doc = ledger(entry(PROXY_ADDR, kind="proxy", proxy={"proxyKind": "diamond"}))
    assert_ok(doc, schema)


def test_ordinary_proxy_still_requires_an_implementation(
    schema: dict[str, Any],
) -> None:
    doc = ledger(entry(PROXY_ADDR, kind="proxy", proxy={"proxyKind": "transparent"}))
    assert_rejects(doc, schema, "'implementationDeploymentId' is a required property")


def test_proxy_kind_entry_requires_a_proxy_object(schema: dict[str, Any]) -> None:
    doc = ledger(entry(PROXY_ADDR, kind="proxy"))
    assert_rejects(doc, schema, "'proxy' is a required property")


@pytest.mark.parametrize("kind", ["standalone", "implementation", "proxy-admin", "library"])
def test_non_proxy_non_beacon_entries_may_not_carry_a_proxy_object(
    schema: dict[str, Any], kind: str
) -> None:
    doc = ledger(entry(PROXY_ADDR, kind=kind, proxy={"proxyKind": "unknown"}))
    assert check(doc, schema), f"{kind} entry wrongly allowed a proxy object"


# --- document-level shape ----------------------------------------------------


def test_rejects_empty_deployments_array(schema: dict[str, Any]) -> None:
    doc = ledger()
    doc["deployments"] = []
    assert_rejects(doc, schema, "should be non-empty")


def test_rejects_schema_version_the_schema_was_not_written_for(
    schema: dict[str, Any],
) -> None:
    doc = ledger()
    doc["schemaVersion"] = "99.0.0"
    assert_rejects(doc, schema, "'0.2.0'")


def test_shipped_ledger_declares_the_pinned_schema_version(
    schema: dict[str, Any],
) -> None:
    pinned = schema["properties"]["schemaVersion"]["const"]
    assert load_json(DEFAULT_LEDGER)["schemaVersion"] == pinned


# --- evidence pointers -------------------------------------------------------


@pytest.mark.parametrize("field", ["auditReportRefs", "publicRefs"])
def test_rejects_a_malformed_evidence_pointer(
    schema: dict[str, Any], field: str
) -> None:
    doc = ledger()
    doc["deployments"][0][field] = ["not a url at all"]
    assert_rejects(doc, schema, "not a")


@pytest.mark.parametrize("field", ["auditReportRefs", "publicRefs"])
def test_accepts_a_percent_encoded_report_url(
    schema: dict[str, Any], field: str
) -> None:
    doc = ledger()
    doc["deployments"][0][field] = [
        "https://example.org/MixBytes%20Lido%20a.DI%20Audit%2007-2024.pdf"
    ]
    assert_ok(doc, schema)


# --- address well-formedness -------------------------------------------------


def test_rejects_a_blank_address_on_a_non_evm_network(schema: dict[str, Any]) -> None:
    """minLength: 1 alone admits ' ' outside the eip155 branch.

    Asserts the address field itself is flagged. The composed deploymentId is
    flagged too, so a weaker assertion would still pass with this guard removed.
    """
    errors = check(ledger(entry(" ", network=SOLANA_NET)), schema)
    assert any(e.startswith("$.deployments[0].address:") for e in errors), errors


def test_rejects_whitespace_in_a_deployment_id(schema: dict[str, Any]) -> None:
    """The '.+' tail of the deploymentId pattern otherwise admits a blank tail."""
    errors = check(ledger(entry(" ", network=SOLANA_NET)), schema)
    assert any(e.startswith("$.deployments[0].deploymentId:") for e in errors), errors


def test_rejects_a_non_hex_evm_address(schema: dict[str, Any]) -> None:
    doc = ledger(entry("0xnothex"))
    assert check(doc, schema), "malformed EVM address was accepted"


# --- carrier handling: duplicate JSON keys -----------------------------------


DUPLICATE_KEY_DOC = """{
  "contractId": "WRONG",
  "contractId": "right"
}
"""


def test_load_json_refuses_a_document_with_a_repeated_key(tmp_path: Path) -> None:
    path = tmp_path / "dup.json"
    path.write_text(DUPLICATE_KEY_DOC, encoding="utf-8")
    with pytest.raises(SystemExit) as excinfo:
        load_json(path)
    assert "duplicate object key" in str(excinfo.value)


def test_plain_json_loads_would_have_dropped_the_first_value() -> None:
    """Pins the reason the hook above exists, so removing it fails a test."""
    assert json.loads(DUPLICATE_KEY_DOC) == {"contractId": "right"}


def test_format_refuses_to_rewrite_a_ledger_with_a_repeated_key(
    tmp_path: Path,
) -> None:
    """README tells contributors to run `format` right after hand-editing, which
    is exactly when an accidentally duplicated key exists."""
    path = tmp_path / "ledger.json"
    original = json.dumps(ledger(), indent=2)
    injected = original.replace(
        '"contractId": "example-role"',
        '"contractId": "WRONG-SENTINEL",\n      "contractId": "example-role"',
        1,
    )
    path.write_text(injected, encoding="utf-8")
    with pytest.raises(SystemExit):
        format_ledger.render(path, DEFAULT_SCHEMA)
    assert "WRONG-SENTINEL" in path.read_text(encoding="utf-8")


# --- formatter ---------------------------------------------------------------


def test_format_is_idempotent(tmp_path: Path) -> None:
    path = tmp_path / "ledger.json"
    doc = ledger(*beacon_trio())
    path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    once = format_ledger.render(path, DEFAULT_SCHEMA)
    path.write_text(once, encoding="utf-8")
    assert format_ledger.render(path, DEFAULT_SCHEMA) == once


def test_format_orders_entry_keys_by_schema_properties(tmp_path: Path) -> None:
    path = tmp_path / "ledger.json"
    doc = ledger()
    doc["deployments"][0] = dict(reversed(list(doc["deployments"][0].items())))
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    rendered = json.loads(format_ledger.render(path, DEFAULT_SCHEMA))
    assert list(rendered["deployments"][0]) == [
        "deploymentId",
        "contractId",
        "deploymentKind",
        "contractName",
        "address",
        "networkId",
        "source",
        "auditReportRefs",
    ]


def test_format_preserves_the_document_it_reorders(tmp_path: Path) -> None:
    """Reordering must not add, drop, or change any value."""
    path = tmp_path / "ledger.json"
    doc = ledger(*beacon_trio())
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    assert json.loads(format_ledger.render(path, DEFAULT_SCHEMA)) == copy.deepcopy(doc)

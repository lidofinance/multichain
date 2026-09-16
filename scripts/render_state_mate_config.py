#!/usr/bin/env python3
"""Render state-mate configs from ledger.json without restating addresses.

One config per ledger network that carries at least one projectable proxy:

    state-mate/generated/<network-slug>/config.yaml
    state-mate/generated/<network-slug>/abi/*.json
    state-mate/generated/<network-slug>/manifest.json

What the rendered configs check is deliberately narrow — call it *linkage*:

  * the address in the proxy's implementation slot equals the address the
    ledger records as ``proxy.implementationDeploymentId``;
  * the address in the proxy's admin slot equals the address the ledger
    records as ``proxy.adminDeploymentId``, or the one state-mate/
    expectations.json declares when the ledger has no field for it;
  * for proxy kinds that expose admin views on the proxy itself, the same two
    facts read a second way, through a function call rather than a raw slot.

Nothing semantic is asserted: no token names, no roles, no cross-chain wiring.
That keeps every rendered value ledger-derived or expectations-derived, so this
tool cannot drift from the ledger the way a hand-written config would.

Storage reads need no block explorer, only an RPC endpoint. That is why the
shipped ABIs are first-party stubs from state-mate/proxy-kinds.json: it lets
linkage run on chains whose explorers Diffyscan cannot use at all. The cost is
that state-mate's "all non-mutable functions covered" guarantee is measured
against those stubs, so it says nothing about the deployed interface. The
generated config says so on its face.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

from _ledger import (
    DEFAULT_LEDGER,
    ROOT,
    SLUG_RE,
    index_deployments,
    load_json,
    require_network_slug,
    validate_json_schema,
)

DEFAULT_NETWORKS = ROOT / "state-mate" / "networks.json"
DEFAULT_NETWORKS_SCHEMA = ROOT / "state-mate" / "networks.schema.json"
DEFAULT_PROXY_KINDS = ROOT / "state-mate" / "proxy-kinds.json"
DEFAULT_PROXY_KINDS_SCHEMA = ROOT / "state-mate" / "proxy-kinds.schema.json"
DEFAULT_EXPECTATIONS = ROOT / "state-mate" / "expectations.json"
DEFAULT_EXPECTATIONS_SCHEMA = ROOT / "state-mate" / "expectations.schema.json"
DEFAULT_OUT_DIR = ROOT / "state-mate" / "generated"

# state-mate requires a section named `l1` and offers at most one more named
# `l2`. A config here covers exactly one network, so the network always lands
# in `l1` whatever layer it actually is; the header comment says so.
SECTION = "l1"

CONFIG_NAME = "config.yaml"
MANIFEST_NAME = "manifest.json"

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_BLOCKED = 3

# Buckets that mean "the ledger described a proxy fully and we still did not
# check it because of something on our side". Only these move the exit code:
# an unmapped proxy kind is a research gap in proxy-kinds.json, reported but
# not treated as a regression, exactly as an unpinned commit is on the
# Diffyscan side.
REGRESSION_BLOCKERS = ("missing_network_rpc",)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--networks", type=Path, default=DEFAULT_NETWORKS)
    parser.add_argument(
        "--networks-schema", type=Path, default=DEFAULT_NETWORKS_SCHEMA
    )
    parser.add_argument("--proxy-kinds", type=Path, default=DEFAULT_PROXY_KINDS)
    parser.add_argument(
        "--proxy-kinds-schema", type=Path, default=DEFAULT_PROXY_KINDS_SCHEMA
    )
    parser.add_argument("--expectations", type=Path, default=DEFAULT_EXPECTATIONS)
    parser.add_argument(
        "--expectations-schema", type=Path, default=DEFAULT_EXPECTATIONS_SCHEMA
    )
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument(
        "--from-ledger",
        action="store_true",
        help="Render one state-mate config per ledger network with proxies",
    )
    parser.add_argument(
        "--coverage",
        action="store_true",
        help="Print ledger→state-mate projection coverage (alone or with --from-ledger)",
    )
    parser.add_argument(
        "--public-rpc",
        action="store_true",
        help=(
            "Emit networks.json publicRpcUrl literally instead of the rpcUrlEnv "
            "name. Convenience for a first run; the endpoint is unauthenticated "
            "and unmonitored, and the config header records that it was used."
        ),
    )
    parser.add_argument(
        "--rpc-url",
        metavar="NETWORK",
        help=(
            "Print the resolved endpoint for one networkId or network slug and "
            "exit. Used by the just recipe to stamp block heights."
        ),
    )
    return parser


def address_of(entry: dict[str, Any]) -> str:
    address = entry.get("address")
    if not isinstance(address, str) or not address:
        raise SystemExit(f"{entry.get('deploymentId')!r} has no address")
    return address


def anchor_for(entry: dict[str, Any]) -> str:
    """Stable YAML anchor for one deployment.

    ``(contractId, networkId, deploymentKind)`` is unique per snapshot —
    validate_ledger.py enforces it, which is also what makes the ``-archive``
    contractId suffix rule enforceable — so within one network's config the
    pair is a collision-free name. contractId and deploymentKind are both
    lowercase-and-dash tokens, which YAML accepts as anchor characters.
    """
    if "_anchor" in entry:
        # A declared administrator has no deploymentId to build a name from.
        # Its anchor is a bare slug, and a ledger-derived anchor always carries
        # a "--<kind>" tail, so the two namespaces cannot collide.
        return entry["_anchor"]
    contract_id = entry["contractId"]
    kind = entry["deploymentKind"]
    if not SLUG_RE.fullmatch(contract_id):
        raise SystemExit(f"contractId is not a slug: {contract_id!r}")
    return f"{contract_id}--{kind}"


# --------------------------------------------------------------------------
# expectations
# --------------------------------------------------------------------------


def resolve_expectations(
    expectations_doc: dict[str, Any],
    deployments_by_id: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    """Check every declared expectation against the ledger before rendering.

    Every failure here is fatal rather than skipped. A key that no longer
    resolves is the dangerous case: the file would keep validating while
    quietly asserting nothing, and a run that asserts nothing still prints
    "checks passed".
    """
    resolved: dict[str, dict[str, Any]] = {}
    by_label: dict[str, dict[str, str]] = {}
    for deployment_id, expectation in (
        expectations_doc.get("expectations") or {}
    ).items():
        proxy_entry = deployments_by_id.get(deployment_id)
        if proxy_entry is None:
            raise SystemExit(
                f"expectations: {deployment_id} is not in the ledger"
            )
        if proxy_entry.get("deploymentKind") != "proxy":
            raise SystemExit(
                f"expectations: {deployment_id} is a "
                f"{proxy_entry.get('deploymentKind')!r}, not a proxy"
            )

        admin_address = expectation.get("adminAddress")
        if admin_address is not None:
            network_id = proxy_entry["networkId"]
            listed = {
                other["address"].lower(): other["deploymentId"]
                for other in deployments_by_id.values()
                if other["networkId"] == network_id
            }
            already = listed.get(admin_address.lower())
            if already is not None:
                # Two names for one address drift apart; the ledger's is the one
                # that gets maintained.
                raise SystemExit(
                    f"expectations: {deployment_id} declares adminAddress "
                    f"{admin_address}, which the ledger already lists as "
                    f"{already} — use adminDeploymentId instead"
                )
            by_label.setdefault(network_id, {})
            label = expectation["adminLabel"]
            seen = by_label[network_id].setdefault(label, admin_address)
            if seen.lower() != admin_address.lower():
                raise SystemExit(
                    f"expectations: adminLabel {label!r} names {seen} and "
                    f"{admin_address} on {network_id}"
                )

        admin_id = expectation.get("adminDeploymentId")
        if admin_id is not None:
            admin_entry = deployments_by_id.get(admin_id)
            if admin_entry is None:
                raise SystemExit(
                    f"expectations: {deployment_id} names adminDeploymentId "
                    f"{admin_id}, which is not in the ledger"
                )
            if admin_entry["networkId"] != proxy_entry["networkId"]:
                raise SystemExit(
                    f"expectations: {deployment_id} names an admin on "
                    f"{admin_entry['networkId']}, but the proxy is on "
                    f"{proxy_entry['networkId']}"
                )
            ledger_admin_id = (proxy_entry.get("proxy") or {}).get(
                "adminDeploymentId"
            )
            if ledger_admin_id is not None and ledger_admin_id != admin_id:
                # Silently preferring one side would make the disagreement
                # invisible in a passing run, which is when it matters most.
                raise SystemExit(
                    f"expectations: {deployment_id} declares admin {admin_id} "
                    f"while the ledger records {ledger_admin_id}"
                )
        resolved[deployment_id] = expectation
    return resolved


# --------------------------------------------------------------------------
# projection
# --------------------------------------------------------------------------


def project_proxy(
    proxy_entry: dict[str, Any],
    *,
    deployments_by_id: dict[str, dict[str, Any]],
    proxy_kinds: dict[str, Any],
    proxy_abis: dict[str, Any],
    expectation: dict[str, Any] | None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Build one state-mate contract entry plus the deployments it references."""
    proxy_kind = proxy_entry["proxy"]["proxyKind"]
    kind = proxy_kinds[proxy_kind]
    slots = kind["storageSlots"]

    implementation_id = proxy_entry["proxy"].get("implementationDeploymentId")
    if implementation_id is None:
        raise SystemExit(
            f"{proxy_entry['deploymentId']}: proxyKind {proxy_kind!r} was "
            "projected without an implementation link"
        )
    implementation = deployments_by_id.get(implementation_id)
    if implementation is None:
        raise SystemExit(
            f"{proxy_entry['deploymentId']}: implementationDeploymentId "
            f"{implementation_id} is not in the ledger"
        )

    admin_id = (proxy_entry.get("proxy") or {}).get("adminDeploymentId")
    admin_basis = "ledger" if admin_id else None
    admin: dict[str, Any] | None = None
    if admin_id is None and expectation is not None:
        admin_id = expectation.get("adminDeploymentId")
        if admin_id:
            admin_basis = f"expectations:{expectation.get('basis', 'unstated')}"
        elif expectation.get("adminAddress"):
            # Declared, not listed: the only address in this pipeline that does
            # not come from the ledger. It is carried as a synthetic entry so
            # everything downstream — anchors, comments, the manifest — can show
            # where it came from instead of it looking ledger-derived.
            admin = {
                "_anchor": expectation["adminLabel"],
                "_declared": True,
                "address": expectation["adminAddress"],
                "contractName": (
                    f"declared in expectations.json as {expectation['adminLabel']}"
                ),
                "networkId": proxy_entry["networkId"],
            }
            admin_basis = f"declared:{expectation.get('basis', 'unstated')}"
    if admin_id:
        admin = deployments_by_id.get(admin_id)
        if admin is None:
            raise SystemExit(
                f"{proxy_entry['deploymentId']}: admin {admin_id} is not in the "
                "ledger"
            )

    referenced = [proxy_entry, implementation]
    if admin is not None:
        referenced.append(admin)

    contract_name = proxy_entry["contractName"]
    abi_entry = proxy_abis.get(contract_name)
    views: dict[str, str] = (abi_entry or {}).get("views", {})

    if admin is not None and "admin" not in slots and "admin" not in views:
        raise SystemExit(
            f"{proxy_entry['deploymentId']}: an admin is declared but "
            f"proxyKind {proxy_kind!r} exposes neither an admin slot nor an "
            "admin view, so the assertion could never run. Record it as a "
            "note-only expectation instead."
        )

    entry: dict[str, Any] = {
        # `name` is the proxy's own contract name, not the implementation's:
        # these entries check the proxy as a proxy, and the ABI they resolve
        # is the proxy's. An implementation-level config is a different
        # artifact with a different evidence bound.
        "name": contract_name,
        "address": {"alias": anchor_for(proxy_entry)},
        "proxyName": contract_name,
        "implementation": {"alias": anchor_for(implementation)},
    }

    if views:
        proxy_checks: dict[str, Any] = {method: None for method in views.values()}
        if "implementation" in views:
            proxy_checks[views["implementation"]] = {
                "alias": anchor_for(implementation)
            }
        if "admin" in views and admin is not None:
            proxy_checks[views["admin"]] = {"alias": anchor_for(admin)}
        if "ossified" in views:
            declared = (expectation or {}).get("ossified")
            if declared is not None:
                proxy_checks[views["ossified"]] = declared
            elif admin is not None:
                # Derived, not restated: for these proxies ossification *is*
                # the admin slot holding the zero address, so an asserted
                # non-zero admin already fixes this value.
                proxy_checks[views["ossified"]] = False
        entry["proxyChecks"] = dict(sorted(proxy_checks.items()))

    # state-mate reports every non-mutable ABI function absent from `checks`
    # as an error, and it does that per section. Listing them as null keeps
    # the run clean while asserting nothing here: the assertions live in
    # proxyChecks and storage.
    abi = (abi_entry or {}).get("abi", [])
    entry["checks"] = {
        fragment["name"]: None
        for fragment in sorted(abi, key=lambda f: f.get("name", ""))
        if fragment.get("type") == "function"
        and fragment.get("stateMutability") in ("view", "pure")
    }

    storage: list[dict[str, Any]] = []
    if "implementation" in slots:
        storage.append(
            {
                "slot": slots["implementation"],
                "expected": {"alias": anchor_for(implementation)},
                "label": "implementation slot",
            }
        )
    if "admin" in slots and admin is not None:
        storage.append(
            {
                "slot": slots["admin"],
                "expected": {"alias": anchor_for(admin)},
                "label": "admin slot",
            }
        )
    if storage:
        entry["storage"] = storage

    facts = {
        "deploymentId": proxy_entry["deploymentId"],
        "contractId": proxy_entry["contractId"],
        "contractName": contract_name,
        "proxyKind": proxy_kind,
        "implementationDeploymentId": implementation_id,
        "implementationAsserted": "implementation" in slots or "implementation" in views,
        "adminDeploymentId": admin_id,
        "adminAddress": (expectation or {}).get("adminAddress"),
        "adminBasis": admin_basis,
        "viewsAsserted": sorted(views.values()) if views else [],
        "storageSlotsAsserted": [item["label"] for item in storage],
    }
    entry["_facts"] = facts
    return entry, referenced


def render_from_ledger(
    ledger: dict[str, Any],
    deployments_by_id: dict[str, dict[str, Any]],
    *,
    proxy_kinds_doc: dict[str, Any],
    networks_map: dict[str, Any],
    expectations: dict[str, dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, list[str]]]:
    proxy_kinds = proxy_kinds_doc["proxyKinds"]
    proxy_abis = proxy_kinds_doc["proxyAbis"]
    networks = networks_map["networks"]

    by_network: dict[str, list[dict[str, Any]]] = defaultdict(list)
    blockers: dict[str, list[str]] = {
        "unmapped_proxy_kind": [],
        "missing_network_rpc": [],
        "skipped": [],
    }

    for entry in deployments_by_id.values():
        if entry.get("deploymentKind") != "proxy":
            continue
        by_network[entry["networkId"]].append(entry)

    rendered: list[dict[str, Any]] = []
    slug_by_network = {
        network_id: require_network_slug(ledger, network_id)
        for network_id in by_network
    }
    for network_id in sorted(by_network, key=lambda n: slug_by_network[n]):
        proxies = by_network[network_id]
        network_slug = slug_by_network[network_id]
        network_cfg = networks.get(network_id)
        if network_cfg is None:
            for proxy in proxies:
                blockers["missing_network_rpc"].append(proxy["deploymentId"])
                blockers["skipped"].append(
                    f"{proxy['deploymentId']}: state-mate/networks.json has no "
                    f"entry for {network_id}"
                )
            continue

        contracts: dict[str, Any] = {}
        referenced: dict[str, dict[str, Any]] = {}
        for proxy in proxies:
            proxy_kind = proxy["proxy"]["proxyKind"]
            if proxy_kind not in proxy_kinds:
                blockers["unmapped_proxy_kind"].append(proxy["deploymentId"])
                blockers["skipped"].append(
                    f"{proxy['deploymentId']}: proxyKind {proxy_kind!r} has no "
                    "state-mate/proxy-kinds.json entry, so no storage layout "
                    "is known for it"
                )
                continue
            entry, refs = project_proxy(
                proxy,
                deployments_by_id=deployments_by_id,
                proxy_kinds=proxy_kinds,
                proxy_abis=proxy_abis,
                expectation=expectations.get(proxy["deploymentId"]),
            )
            contracts[proxy["contractId"]] = entry
            for ref in refs:
                referenced.setdefault(
                    ref.get("deploymentId") or f"declared:{ref['_anchor']}", ref
                )

        if not contracts:
            continue

        abis: dict[str, list[Any]] = {}
        for entry in contracts.values():
            name = entry["name"]
            abis[name] = (proxy_abis.get(name) or {}).get("abi", [])

        rendered.append(
            {
                "networkId": network_id,
                "networkSlug": network_slug,
                "networkConfig": network_cfg,
                "contracts": contracts,
                "referenced": list(referenced.values()),
                "abis": abis,
            }
        )

    return rendered, blockers


# --------------------------------------------------------------------------
# YAML emission
#
# Hand-written rather than via a YAML library: the anchors carry contractIds
# and the comments carry the evidence bounds, and neither survives a generic
# dump. Every value emitted here is an address, a hex slot, a bool or a null,
# so the quoting rules stay trivial.
# --------------------------------------------------------------------------


def yaml_scalar(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, dict) and "alias" in value:
        return f"*{value['alias']}"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    raise SystemExit(f"Cannot emit {value!r} as YAML")


def emit_config(
    config: dict[str, Any], *, ledger: dict[str, Any], use_public_rpc: bool
) -> str:
    network_cfg = config["networkConfig"]
    if use_public_rpc:
        rpc = network_cfg.get("publicRpcUrl")
        if not rpc:
            raise SystemExit(
                f"--public-rpc: no publicRpcUrl recorded for {config['networkId']}"
            )
    else:
        rpc = network_cfg["rpcUrlEnv"]

    lines: list[str] = ["---"]
    lines += [
        "# GENERATED — do not edit. Re-render with:",
        "#   uv run python scripts/render_state_mate_config.py --from-ledger",
        "#",
        f"# network:       {config['networkId']} ({config['networkSlug']})",
        f"# ledger:        schemaVersion {ledger['schemaVersion']}, "
        f"updatedAt {ledger['updatedAt']}",
        f"# proxies:       {len(config['contracts'])}",
        "#",
        "# WHAT A PASSING RUN HERE ESTABLISHES",
        "#   Only linkage: that the addresses in each proxy's upgrade slots, read",
        "#   through the RPC endpoint below at whatever block it served, equal the",
        "#   addresses ledger.json records for those roles. It does not establish",
        "#   that an address is the right contract for its role, that the",
        "#   implementation behaves as documented, or that anything was approved.",
        "#",
        "# WHAT THE ABI COVERAGE FIGURE IS WORTH",
        "#   The abi/ files beside this config are first-party stubs from",
        "#   state-mate/proxy-kinds.json, not explorer-verified ABIs. state-mate's",
        "#   'all non-mutable functions covered' check is therefore measured",
        "#   against those stubs and says nothing about the deployed interface.",
        "#   Do not run this config with --update-abi: it would overwrite them.",
        "#",
    ]
    if use_public_rpc:
        lines += [
            "# CARRIER",
            "#   rpcUrl is the unauthenticated public endpoint recorded in",
            f"#   state-mate/networks.json (checked "
            f"{network_cfg.get('publicRpcCheckedOn', 'unknown')}). It is one",
            "#   more untrusted party between you and the chain; re-render",
            "#   without --public-rpc to use your own endpoint.",
            "#",
        ]
    lines += [
        "# SECTION NAME",
        f"#   state-mate requires a section called '{SECTION}'. This config covers",
        "#   exactly one network and uses that section whatever layer the network",
        "#   actually is.",
        "",
        "deployed:",
        f"  {SECTION}:",
    ]

    for entry in config["referenced"]:
        anchor = anchor_for(entry)
        lines.append(
            f"    - &{anchor} {yaml_scalar(address_of(entry))}"
            f"  # {entry['contractName']}"
        )

    lines += ["", f"{SECTION}:", f"  rpcUrl: {rpc}", "  contracts:"]

    for alias, entry in sorted(config["contracts"].items()):
        facts = entry["_facts"]
        lines.append(f"    {alias}:")
        lines.append(f"      # {facts['deploymentId']}")
        if facts["adminBasis"] and facts["adminBasis"].startswith("declared:"):
            basis = facts["adminBasis"].split(":", 1)[1]
            lines.append(
                "      # admin asserted from an address DECLARED in "
                f"state-mate/expectations.json, not in the ledger (basis: {basis})"
            )
        elif facts["adminBasis"] and facts["adminBasis"].startswith("expectations:"):
            basis = facts["adminBasis"].split(":", 1)[1]
            lines.append(
                f"      # admin asserted from state-mate/expectations.json "
                f"(basis: {basis})"
            )
        elif facts["adminBasis"] == "ledger":
            lines.append("      # admin asserted from ledger proxy.adminDeploymentId")
        else:
            lines.append(
                "      # admin NOT asserted: neither the ledger nor "
                "expectations.json names one"
            )
        lines.append(f"      name: {entry['name']}")
        lines.append(f"      address: {yaml_scalar(entry['address'])}")
        lines.append(f"      proxyName: {entry['proxyName']}")
        lines.append(f"      implementation: {yaml_scalar(entry['implementation'])}")
        if "proxyChecks" in entry:
            lines.append("      proxyChecks:")
            for method, value in entry["proxyChecks"].items():
                lines.append(f"        {method}: {yaml_scalar(value)}")
        lines.append("      checks:" if entry["checks"] else "      checks: {}")
        for method, value in entry["checks"].items():
            lines.append(f"        {method}: {yaml_scalar(value)}")
        if "storage" in entry:
            lines.append("      storage:")
            for item in entry["storage"]:
                lines.append(f"        - slot: {yaml_scalar(item['slot'])}")
                lines.append(f"          expected: {yaml_scalar(item['expected'])}")
                lines.append(f"          label: {yaml_scalar(item['label'])}")

    return "\n".join(lines) + "\n"


def build_manifest(
    config: dict[str, Any], *, ledger: dict[str, Any], rpc_mode: str
) -> dict[str, Any]:
    """Machine-readable projection facts, so a report need not re-derive them."""
    return {
        "kind": "state-mate-linkage-manifest",
        "networkId": config["networkId"],
        "networkSlug": config["networkSlug"],
        "ledgerSchemaVersion": ledger["schemaVersion"],
        "ledgerUpdatedAt": ledger["updatedAt"],
        "rpcMode": rpc_mode,
        "proxies": [
            entry["_facts"] for _, entry in sorted(config["contracts"].items())
        ],
    }


# --------------------------------------------------------------------------
# writing
# --------------------------------------------------------------------------


def write_network(
    config: dict[str, Any],
    out_dir: Path,
    *,
    ledger: dict[str, Any],
    use_public_rpc: bool,
) -> Path:
    slug = config["networkSlug"]
    if not SLUG_RE.fullmatch(slug):
        raise SystemExit(f"Refusing unsafe network slug: {slug!r}")
    target = out_dir / slug
    (target / "abi").mkdir(parents=True, exist_ok=True)

    (target / CONFIG_NAME).write_text(
        emit_config(config, ledger=ledger, use_public_rpc=use_public_rpc),
        encoding="utf-8",
    )
    (target / MANIFEST_NAME).write_text(
        json.dumps(
            build_manifest(
                config,
                ledger=ledger,
                rpc_mode="public" if use_public_rpc else "env",
            ),
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    keep_abis = {f"{name}.json" for name in config["abis"]}
    for name, abi in sorted(config["abis"].items()):
        (target / "abi" / f"{name}.json").write_text(
            json.dumps(abi, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
    for stale in target.glob("abi/*.json"):
        if stale.name not in keep_abis:
            stale.unlink()
    return target


def prune_stale_generated(out_dir: Path, keep: set[str]) -> list[str]:
    """Remove network directories this script no longer produces.

    Only directories that hold a config.yaml this script would have written are
    touched, so anything else left in the output directory is not ours to
    delete.
    """
    if not out_dir.is_dir():
        return []
    removed: list[str] = []
    for path in sorted(out_dir.iterdir()):
        if not path.is_dir() or path.name in keep:
            continue
        if not SLUG_RE.fullmatch(path.name):
            continue
        if not (path / CONFIG_NAME).is_file():
            continue
        shutil.rmtree(path)
        removed.append(path.name)
    return removed


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------


def print_coverage(
    ledger: dict[str, Any],
    rendered: list[dict[str, Any]],
    blockers: dict[str, list[str]],
    expectations: dict[str, dict[str, Any]],
) -> None:
    proxies = [
        entry
        for entry in ledger["deployments"]
        if entry.get("deploymentKind") == "proxy"
    ]
    facts = [
        entry["_facts"]
        for config in rendered
        for _, entry in sorted(config["contracts"].items())
    ]
    blocked = len(blockers.get("unmapped_proxy_kind", [])) + len(
        blockers.get("missing_network_rpc", [])
    )

    admin_ledger = sum(1 for f in facts if f["adminBasis"] == "ledger")
    admin_expected: defaultdict[str, int] = defaultdict(int)
    admin_declared: defaultdict[str, int] = defaultdict(int)
    for fact in facts:
        basis = fact["adminBasis"] or ""
        if basis.startswith("expectations:"):
            admin_expected[basis.split(":", 1)[1]] += 1
        elif basis.startswith("declared:"):
            admin_declared[basis.split(":", 1)[1]] += 1
    admin_none = sum(1 for f in facts if f["adminBasis"] is None)
    with_views = sum(1 for f in facts if f["viewsAsserted"])

    # Projection, not verification: a projected proxy is one state-mate will be
    # asked about. Only a run against a live endpoint settles anything.
    print("state-mate linkage projection (not verification)")
    print(f"  ledger proxies:              {len(proxies)}")
    print(
        f"  projected:                   {len(facts)} across "
        f"{len(rendered)} networks"
    )
    print(f"  not projected:               {blocked}")
    print(
        f"    unmapped proxyKind:        "
        f"{len(blockers.get('unmapped_proxy_kind', []))}"
    )
    print(
        f"    no networks.json RPC:      "
        f"{len(blockers.get('missing_network_rpc', []))}"
    )
    print("  implementation link asserted for every projected proxy")
    print("  admin link:")
    print(f"    from ledger:               {admin_ledger}")
    for basis, count in sorted(admin_expected.items()):
        suffix = (
            "  (seeded from the chain: detects change, does not corroborate)"
            if basis == "chain-baseline"
            else ""
        )
        print(f"    from expectations, by id:  {count}  [{basis}]{suffix}")
    for basis, count in sorted(admin_declared.items()):
        # These are the only addresses in the pipeline the ledger does not hold,
        # so they are counted apart from everything else rather than folded in.
        print(
            f"    from a declared address:   {count}  [{basis}] "
            "(not in ledger.json)"
        )
    print(f"    not asserted:              {admin_none}")
    print(
        f"  read twice (slot and view):  {with_views} "
        f"({len(facts) - with_views} via storage only)"
    )
    note_only = sum(
        1
        for e in expectations.values()
        if not {"adminDeploymentId", "adminAddress", "ossified"} & set(e)
    )
    if note_only:
        print(
            f"  expectations recording why nothing can be asserted: {note_only}"
        )
    if rendered:
        print("  networks:")
        for config in rendered:
            print(
                f"    - {config['networkSlug']} ({len(config['contracts'])})"
            )
    skipped = blockers.get("skipped") or []
    if skipped:
        print("  skipped:")
        for line in skipped:
            print(f"    - {line}")


def blocked_exit_code(blockers: dict[str, list[str]]) -> int:
    if any(blockers.get(key) for key in REGRESSION_BLOCKERS):
        return EXIT_BLOCKED
    return EXIT_OK


# --------------------------------------------------------------------------


def resolve_rpc_for(
    ledger: dict[str, Any],
    networks_map: dict[str, Any],
    selector: str,
    *,
    use_public_rpc: bool,
) -> str:
    network_id = selector
    if selector not in networks_map["networks"]:
        matches = [
            nid
            for nid, meta in ledger["networks"].items()
            if meta.get("networkName") == selector
        ]
        if len(matches) != 1:
            raise SystemExit(f"Unknown network selector: {selector!r}")
        network_id = matches[0]
    cfg = networks_map["networks"].get(network_id)
    if cfg is None:
        raise SystemExit(f"state-mate/networks.json has no entry for {network_id}")
    if use_public_rpc:
        url = cfg.get("publicRpcUrl")
        if not url:
            raise SystemExit(f"No publicRpcUrl recorded for {network_id}")
        return url
    return cfg["rpcUrlEnv"]


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    for path, label in (
        (args.ledger, "ledger"),
        (args.networks, "networks map"),
        (args.networks_schema, "networks schema"),
        (args.proxy_kinds, "proxy kinds map"),
        (args.proxy_kinds_schema, "proxy kinds schema"),
        (args.expectations, "expectations"),
        (args.expectations_schema, "expectations schema"),
    ):
        if not path.is_file():
            print(f"{label} not found: {path}", file=sys.stderr)
            return EXIT_USAGE

    if not args.from_ledger and not args.coverage and not args.rpc_url:
        parser.error("provide --from-ledger, --coverage or --rpc-url")

    ledger = load_json(args.ledger)
    networks_map = validate_json_schema(
        load_json(args.networks), load_json(args.networks_schema), label=str(args.networks)
    )

    if args.rpc_url:
        print(
            resolve_rpc_for(
                ledger, networks_map, args.rpc_url, use_public_rpc=args.public_rpc
            )
        )
        return EXIT_OK

    deployments_by_id = index_deployments(ledger)
    proxy_kinds_doc = validate_json_schema(
        load_json(args.proxy_kinds),
        load_json(args.proxy_kinds_schema),
        label=str(args.proxy_kinds),
    )
    expectations_doc = validate_json_schema(
        load_json(args.expectations),
        load_json(args.expectations_schema),
        label=str(args.expectations),
    )
    expectations = resolve_expectations(expectations_doc, deployments_by_id)

    rendered, blockers = render_from_ledger(
        ledger,
        deployments_by_id,
        proxy_kinds_doc=proxy_kinds_doc,
        networks_map=networks_map,
        expectations=expectations,
    )

    if not args.from_ledger:
        print_coverage(ledger, rendered, blockers, expectations)
        return blocked_exit_code(blockers)

    keep: set[str] = set()
    for config in rendered:
        target = write_network(
            config,
            args.out_dir,
            ledger=ledger,
            use_public_rpc=args.public_rpc,
        )
        keep.add(config["networkSlug"])
        print(f"Wrote {target / CONFIG_NAME} ({len(config['contracts'])} proxies)")
    for name in prune_stale_generated(args.out_dir, keep):
        print(f"Pruned stale {args.out_dir / name}")

    print_coverage(ledger, rendered, blockers, expectations)
    return blocked_exit_code(blockers)


if __name__ == "__main__":
    raise SystemExit(main())

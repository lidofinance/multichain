"""Shared paths, CLI prologue, JSON loading and ledger indexing for ledger tooling."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LEDGER = ROOT / "ledger.json"
DEFAULT_SCHEMA = ROOT / "ledger.schema.json"

SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Build an object, refusing repeated keys instead of keeping the last one.

    ``json.loads`` silently discards all but the final value for a repeated key.
    A hand-edited ledger that accidentally repeats ``address`` or ``contractId``
    would then validate, and ``format_ledger.py format`` would rewrite the file
    with the discarded value gone.
    """
    obj: dict[str, Any] = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError(f"duplicate object key {key!r}")
        obj[key] = value
    return obj


def load_json(path: Path) -> Any:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise SystemExit(f"{path} is not valid UTF-8: {exc}") from exc
    except OSError as exc:
        raise SystemExit(f"Cannot read {path}: {exc}") from exc
    try:
        # JSONDecodeError and the duplicate-key ValueError are both ValueError.
        return json.loads(text, object_pairs_hook=reject_duplicate_keys)
    except ValueError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc


def build_parser(description: str | None) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    return parser


def require_input_files(args: argparse.Namespace) -> None:
    if not args.schema.is_file():
        print(f"Schema not found: {args.schema}", file=sys.stderr)
        raise SystemExit(2)
    if not args.ledger.is_file():
        print(f"Ledger not found: {args.ledger}", file=sys.stderr)
        raise SystemExit(2)


def load_schema_and_instance(
    schema_path: Path, ledger_path: Path
) -> tuple[dict[str, Any], Any]:
    schema = load_json(schema_path)
    if not isinstance(schema, dict):
        raise SystemExit(f"Schema root must be a JSON object: {schema_path}")
    return schema, load_json(ledger_path)


def validate_json_schema(
    instance: Any, schema: dict[str, Any], *, label: str
) -> dict[str, Any]:
    if not isinstance(instance, dict):
        raise SystemExit(f"{label} root must be a JSON object")
    try:
        Draft202012Validator.check_schema(schema)
    except SchemaError as exc:
        raise SystemExit(f"Invalid schema for {label}: {exc}") from exc
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.path))
    if errors:
        lines = [f"Schema validation failed for {label}:"]
        for error in errors:
            loc = ".".join(str(p) for p in error.path) or "<root>"
            lines.append(f"  - {loc}: {error.message}")
        raise SystemExit("\n".join(lines))
    return instance


def parse_eip155_chain_id(network_id: str) -> int | None:
    namespace, _, reference = network_id.partition(":")
    if namespace != "eip155" or not reference.isdigit():
        return None
    return int(reference)


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
        network_id = entry.get("networkId")
        if not isinstance(network_id, str) or not network_id:
            raise SystemExit(f"deployments[{index}] missing networkId")
        by_id[deployment_id] = entry
    return by_id


def require_network_slug(ledger: dict[str, Any], network_id: str) -> str:
    networks = ledger.get("networks")
    if not isinstance(networks, dict):
        raise SystemExit("Ledger networks must be an object")
    meta = networks.get(network_id)
    if not isinstance(meta, dict):
        raise SystemExit(f"Ledger networks missing entry for {network_id!r}")
    name = meta.get("networkName")
    if not isinstance(name, str) or not SLUG_RE.fullmatch(name):
        raise SystemExit(
            f"networkName for {network_id!r} must be a slug matching "
            f"{SLUG_RE.pattern}; got {name!r}"
        )
    return name

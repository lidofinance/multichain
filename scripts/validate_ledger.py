#!/usr/bin/env python3
"""Validate ledger.json against ledger.schema.json plus cross-field integrity rules.

JSON Schema covers per-field shape. Integrity checks cover relations the schema
cannot express cleanly (for example deploymentId composition).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LEDGER = ROOT / "ledger.json"
DEFAULT_SCHEMA = ROOT / "ledger.schema.json"


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc


def json_pointer(path: list[Any]) -> str:
    pointer = "$"
    for part in path:
        pointer += f"[{part}]" if isinstance(part, int) else f".{part}"
    return pointer


def schema_errors(instance: Any, schema: dict[str, Any]) -> list[str]:
    try:
        Draft202012Validator.check_schema(schema)
    except SchemaError as exc:
        raise SystemExit(f"Invalid schema: {exc}") from exc

    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors: list[str] = []
    for error in sorted(validator.iter_errors(instance), key=lambda e: list(e.path)):
        errors.append(f"{json_pointer(list(error.absolute_path))}: {error.message}")
    return errors


def integrity_errors(instance: Any) -> list[str]:
    """Cross-field checks beyond JSON Schema."""
    errors: list[str] = []
    if not isinstance(instance, dict):
        return errors

    deployments = instance.get("deployments")
    if not isinstance(deployments, list):
        return errors

    for index, entry in enumerate(deployments):
        if not isinstance(entry, dict):
            continue
        path = f"$.deployments[{index}]"
        deployment_id = entry.get("deploymentId")
        network_id = entry.get("networkId")
        address = entry.get("address")
        if not (
            isinstance(deployment_id, str)
            and isinstance(network_id, str)
            and isinstance(address, str)
        ):
            # Missing/typed fields are reported by JSON Schema when present.
            continue

        expected = f"{network_id}:{address}"
        if deployment_id != expected:
            errors.append(
                f"{path}.deploymentId: expected {expected!r} "
                f"(networkId + ':' + address), got {deployment_id!r}"
            )

    return errors


def validate(ledger_path: Path, schema_path: Path) -> tuple[list[str], list[str]]:
    schema = load_json(schema_path)
    instance = load_json(ledger_path)
    if not isinstance(schema, dict):
        raise SystemExit(f"Schema root must be a JSON object: {schema_path}")
    return schema_errors(instance, schema), integrity_errors(instance)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    args = parser.parse_args(argv)

    if not args.schema.is_file():
        print(f"Schema not found: {args.schema}", file=sys.stderr)
        return 2
    if not args.ledger.is_file():
        print(f"Ledger not found: {args.ledger}", file=sys.stderr)
        return 2

    schema_errs, integrity_errs = validate(args.ledger, args.schema)
    failed = False

    if schema_errs:
        failed = True
        print(
            f"{args.ledger} failed JSON Schema validation against {args.schema}:",
            file=sys.stderr,
        )
        for message in schema_errs:
            print(f"  - {message}", file=sys.stderr)

    if integrity_errs:
        failed = True
        print(f"{args.ledger} failed integrity checks:", file=sys.stderr)
        for message in integrity_errs:
            print(f"  - {message}", file=sys.stderr)

    if failed:
        return 1

    print(
        f"{args.ledger} is valid against {args.schema} "
        "and passed integrity checks."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

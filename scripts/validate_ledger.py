#!/usr/bin/env python3
"""Validate ledger.json against ledger.schema.json plus cross-field integrity rules.

JSON Schema covers per-field shape. Integrity checks run only on schema-valid
input and cover relations the schema cannot express cleanly (deploymentId
composition, uniqueness, proxy refs, network membership).
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError

from _ledger import build_parser, load_schema_and_instance, require_input_files


def error_sort_key(path: list[Any]) -> list[tuple[int, int | str]]:
    """Order error paths without comparing int indices to str keys."""
    return [(0, p) if isinstance(p, int) else (1, p) for p in path]


def collect_format_names(node: Any, found: set[str]) -> None:
    if isinstance(node, dict):
        fmt = node.get("format")
        if isinstance(fmt, str):
            found.add(fmt)
        for value in node.values():
            collect_format_names(value, found)
    elif isinstance(node, list):
        for item in node:
            collect_format_names(item, found)


def require_format_backends(schema: dict[str, Any], checker: FormatChecker) -> None:
    required: set[str] = set()
    collect_format_names(schema, required)
    missing = sorted(required - frozenset(checker.checkers))
    if missing:
        raise SystemExit(
            "jsonschema FormatChecker is missing required format backends: "
            + ", ".join(missing)
            + ". Install the project with `uv sync` "
            "(jsonschema[format-nongpl] or equivalent uri backend)."
        )


def proxy_ref_kinds(schema: dict[str, Any]) -> dict[str, str]:
    """Map proxy relation fields to expected target deploymentKind from the schema."""
    try:
        properties = schema["$defs"]["proxy"]["properties"]
    except KeyError as exc:
        raise SystemExit(
            "Schema is missing $defs.proxy.properties needed for proxy ref checks"
        ) from exc
    if not isinstance(properties, dict):
        raise SystemExit("$defs.proxy.properties must be an object")

    kinds: dict[str, str] = {}
    for field, prop_schema in properties.items():
        if not isinstance(prop_schema, dict):
            continue
        if prop_schema.get("$ref") != "#/$defs/deploymentId":
            continue
        kind = prop_schema.get("x-refDeploymentKind")
        if not isinstance(kind, str) or not kind:
            raise SystemExit(
                f"$defs.proxy.properties.{field} must declare "
                f"x-refDeploymentKind for integrity checks"
            )
        kinds[field] = kind
    if not kinds:
        raise SystemExit(
            "$defs.proxy.properties must declare at least one "
            "deploymentId $ref with x-refDeploymentKind"
        )
    return kinds


def schema_errors(instance: Any, schema: dict[str, Any]) -> list[str]:
    try:
        Draft202012Validator.check_schema(schema)
    except SchemaError as exc:
        raise SystemExit(f"Invalid schema: {exc}") from exc

    checker = FormatChecker()
    require_format_backends(schema, checker)
    validator = Draft202012Validator(schema, format_checker=checker)
    errors: list[str] = []
    for error in sorted(
        validator.iter_errors(instance), key=lambda e: error_sort_key(list(e.path))
    ):
        errors.append(f"{error.json_path}: {error.message}")
    return errors


def integrity_errors(instance: dict[str, Any], schema: dict[str, Any]) -> list[str]:
    """Cross-field checks beyond JSON Schema.

    Contract: ``instance`` has already passed JSON Schema validation against
    ``schema``. Shape and required fields are therefore assumed.
    """
    errors: list[str] = []
    ref_kinds = proxy_ref_kinds(schema)
    network_ids = set(instance["networks"])
    deployments: list[dict[str, Any]] = instance["deployments"]

    by_id: dict[str, tuple[int, dict[str, Any]]] = {}

    for index, entry in enumerate(deployments):
        path = f"$.deployments[{index}]"
        deployment_id = entry["deploymentId"]
        network_id = entry["networkId"]
        address = entry["address"]

        if deployment_id in by_id:
            errors.append(
                f"{path}.deploymentId: duplicate deploymentId {deployment_id!r} "
                f"(also at $.deployments[{by_id[deployment_id][0]}])"
            )
        else:
            by_id[deployment_id] = (index, entry)

        expected = f"{network_id}:{address}"
        if deployment_id != expected:
            errors.append(
                f"{path}.deploymentId: expected {expected!r} "
                f"(networkId + ':' + address), got {deployment_id!r}"
            )

        if network_id not in network_ids:
            errors.append(
                f"{path}.networkId: {network_id!r} is not a key in $.networks"
            )

    for index, entry in enumerate(deployments):
        path = f"$.deployments[{index}]"
        proxy = entry.get("proxy")
        if not isinstance(proxy, dict):
            continue
        for field, expected_kind in ref_kinds.items():
            ref = proxy.get(field)
            if not isinstance(ref, str):
                continue
            target_meta = by_id.get(ref)
            if target_meta is None:
                errors.append(
                    f"{path}.proxy.{field}: dangling reference {ref!r} "
                    "(no matching deploymentId)"
                )
                continue
            _, target = target_meta
            kind = target.get("deploymentKind")
            if kind != expected_kind:
                errors.append(
                    f"{path}.proxy.{field}: target {ref!r} has deploymentKind "
                    f"{kind!r}, expected {expected_kind!r}"
                )

    return errors


def validate(ledger_path: Path, schema_path: Path) -> tuple[list[str], list[str]]:
    schema, instance = load_schema_and_instance(schema_path, ledger_path)
    schema_errs = schema_errors(instance, schema)
    if schema_errs:
        return schema_errs, []
    assert isinstance(instance, dict)  # root schema type: object
    return schema_errs, integrity_errors(instance, schema)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser(__doc__)
    args = parser.parse_args(argv)
    require_input_files(args)

    schema_errs, integrity_errs = validate(args.ledger, args.schema)

    for header, errs in (
        (f"failed JSON Schema validation against {args.schema}", schema_errs),
        ("failed integrity checks", integrity_errs),
    ):
        if errs:
            print(f"{args.ledger} {header}:", file=sys.stderr)
            for message in errs:
                print(f"  - {message}", file=sys.stderr)

    if schema_errs or integrity_errs:
        return 1

    print(
        f"{args.ledger} is valid against {args.schema} "
        "and passed integrity checks."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

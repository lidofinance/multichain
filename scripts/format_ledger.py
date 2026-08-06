#!/usr/bin/env python3
"""Reorder ledger.json object keys to match ledger.schema.json ``properties`` order.

Canonical key order is the order of keys under each schema ``properties`` object
(top level, deploymentEntry, source, proxy, and any future nested objects).
Optional keys are omitted when absent. Unknown keys are preserved after known
ones in their existing relative order. Array element order is unchanged.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LEDGER = ROOT / "ledger.json"
DEFAULT_SCHEMA = ROOT / "ledger.schema.json"


def resolve_ref(root_schema: dict[str, Any], ref: str) -> dict[str, Any]:
    if not ref.startswith("#/"):
        raise ValueError(f"Only local JSON Schema refs are supported: {ref}")
    node: Any = root_schema
    for part in ref[2:].split("/"):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(f"Unresolved schema ref {ref!r} at {part!r}")
        node = node[part]
    if not isinstance(node, dict):
        raise TypeError(f"Schema ref {ref!r} did not resolve to an object")
    return node


def deref(root_schema: dict[str, Any], schema: dict[str, Any]) -> dict[str, Any]:
    """Follow ``$ref``, merging sibling keywords onto the target."""
    current = schema
    seen: set[str] = set()
    while "$ref" in current:
        ref = current["$ref"]
        if not isinstance(ref, str):
            raise TypeError("$ref must be a string")
        if ref in seen:
            raise ValueError(f"Circular $ref involving {ref}")
        seen.add(ref)
        target = resolve_ref(root_schema, ref)
        siblings = {k: v for k, v in current.items() if k != "$ref"}
        current = {**target, **siblings}
    return current


def object_schema_with_properties(
    root_schema: dict[str, Any], schema: dict[str, Any]
) -> dict[str, Any] | None:
    """Return a schema that defines ``properties``, following $ref / oneOf / anyOf."""
    current = deref(root_schema, schema)
    if "properties" in current and isinstance(current["properties"], dict):
        return current

    for combiner in ("oneOf", "anyOf"):
        options = current.get(combiner)
        if not isinstance(options, list):
            continue
        for option in options:
            if not isinstance(option, dict):
                continue
            # Prefer object branches over null/scalar ones.
            if option.get("type") == "null":
                continue
            found = object_schema_with_properties(root_schema, option)
            if found is not None:
                return found
    return None


def reorder(
    value: Any,
    root_schema: dict[str, Any],
    schema: dict[str, Any] | None,
) -> Any:
    if schema is None:
        if isinstance(value, dict):
            return {k: reorder(v, root_schema, None) for k, v in value.items()}
        if isinstance(value, list):
            return [reorder(item, root_schema, None) for item in value]
        return value

    current = deref(root_schema, schema)

    if isinstance(value, dict):
        obj_schema = object_schema_with_properties(root_schema, current)
        if obj_schema is None:
            return {k: reorder(v, root_schema, None) for k, v in value.items()}

        properties = obj_schema["properties"]
        ordered: dict[str, Any] = {}
        for key, prop_schema in properties.items():
            if key not in value:
                continue
            child_schema = prop_schema if isinstance(prop_schema, dict) else None
            ordered[key] = reorder(value[key], root_schema, child_schema)
        for key, item in value.items():
            if key in ordered:
                continue
            ordered[key] = reorder(item, root_schema, None)
        return ordered

    if isinstance(value, list):
        items_schema = current.get("items")
        child_schema = items_schema if isinstance(items_schema, dict) else None
        return [reorder(item, root_schema, child_schema) for item in value]

    return value


def dumps(data: Any) -> str:
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def render(ledger_path: Path, schema_path: Path) -> str:
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    data = json.loads(ledger_path.read_text(encoding="utf-8"))
    if not isinstance(schema, dict):
        raise TypeError("Schema root must be a JSON object")
    return dumps(reorder(data, schema, schema))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("format", "check"),
        help="format rewrites the ledger; check fails if key order differs",
    )
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    args = parser.parse_args(argv)

    if not args.schema.is_file():
        print(f"Schema not found: {args.schema}", file=sys.stderr)
        return 2
    if not args.ledger.is_file():
        print(f"Ledger not found: {args.ledger}", file=sys.stderr)
        return 2

    formatted = render(args.ledger, args.schema)
    current = args.ledger.read_text(encoding="utf-8")

    if args.command == "format":
        if current != formatted:
            args.ledger.write_text(formatted, encoding="utf-8")
            print(f"Rewrote {args.ledger} to match schema property order.")
        else:
            print(f"{args.ledger} already matches schema property order.")
        return 0

    if current != formatted:
        print(
            f"{args.ledger} key order does not match {args.schema} properties order.",
            file=sys.stderr,
        )
        print(
            "Fix with: uv run python scripts/format_ledger.py format",
            file=sys.stderr,
        )
        return 1

    print(f"{args.ledger} key order OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

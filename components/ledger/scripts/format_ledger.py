#!/usr/bin/env python3
"""Reorder ledger.json object keys to match ledger.schema.json ``properties`` order.

Canonical key order is the order of keys under each schema ``properties`` object
(including keys collected through ``allOf`` / ``if``-``then`` / ``else``). Optional
keys are omitted when absent. Unknown keys are preserved after known ones in their
existing relative order. Array element order is unchanged. Map objects that use
``additionalProperties`` as a schema (``networks``) keep instance key order and
only reorder nested values.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from _ledger import build_parser, load_schema_and_instance, require_input_files


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


def _collect_properties(
    root_schema: dict[str, Any], schema: dict[str, Any], ordered: dict[str, Any]
) -> None:
    """Append property schemas into ``ordered`` without replacing earlier keys."""
    current = deref(root_schema, schema)
    props = current.get("properties")
    if isinstance(props, dict):
        for key, prop_schema in props.items():
            if key not in ordered:
                ordered[key] = prop_schema

    for combiner in ("allOf", "anyOf", "oneOf"):
        options = current.get(combiner)
        if not isinstance(options, list):
            continue
        for option in options:
            if isinstance(option, dict):
                _collect_properties(root_schema, option, ordered)

    for branch in ("then", "else", "if"):
        option = current.get(branch)
        if isinstance(option, dict):
            _collect_properties(root_schema, option, ordered)


def object_schema_with_properties(
    root_schema: dict[str, Any],
    schema: dict[str, Any],
) -> dict[str, Any] | None:
    """Return a schema that defines ``properties``, following combinators."""
    current = deref(root_schema, schema)
    ordered: dict[str, Any] = {}
    _collect_properties(root_schema, current, ordered)
    if ordered:
        return {**current, "properties": ordered}
    return None


def reorder(
    value: Any,
    root_schema: dict[str, Any],
    schema: dict[str, Any] | None,
) -> Any:
    if schema is None:
        return value

    current = deref(root_schema, schema)

    if isinstance(value, dict):
        # Map schemas (additionalProperties as schema, propertyNames) keep
        # instance key order; only reorder nested values.
        additional = current.get("additionalProperties")
        if (
            "properties" not in current
            and isinstance(additional, dict)
            and current.get("type") == "object"
        ):
            return {
                k: reorder(v, root_schema, additional) for k, v in value.items()
            }

        obj_schema = object_schema_with_properties(root_schema, current)
        if obj_schema is None:
            return value

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
            ordered[key] = item
        return ordered

    if isinstance(value, list):
        items_schema = current.get("items")
        child_schema = items_schema if isinstance(items_schema, dict) else None
        return [reorder(item, root_schema, child_schema) for item in value]

    return value


def dumps(data: Any) -> str:
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def render(ledger_path: Path, schema_path: Path) -> str:
    schema, data = load_schema_and_instance(schema_path, ledger_path)
    return dumps(reorder(data, schema, schema))


def main(argv: list[str] | None = None) -> int:
    parser = build_parser(__doc__)
    parser.add_argument(
        "command",
        choices=("format", "check"),
        help="format rewrites the ledger; check fails if key order differs",
    )
    args = parser.parse_args(argv)
    require_input_files(args)

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
            f"{args.ledger} does not match its canonical rendering "
            f"(schema {args.schema} property order, 2-space indent, "
            "trailing newline).",
            file=sys.stderr,
        )
        print(
            "Fix with: uv run python components/ledger/scripts/format_ledger.py format",
            file=sys.stderr,
        )
        return 1

    print(f"{args.ledger} formatting OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

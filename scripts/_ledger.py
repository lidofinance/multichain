"""Shared paths, CLI prologue, and JSON loading for ledger tooling."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LEDGER = ROOT / "ledger.json"
DEFAULT_SCHEMA = ROOT / "ledger.schema.json"


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
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

#!/usr/bin/env python3
"""Validate chain record structure; lint-config also checks operation-specific intent."""
import argparse
import json
from pathlib import Path

from jsonschema import Draft202012Validator


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    schema = json.loads(Path(__file__).with_name('chain.schema.json').read_text())
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    paths = sorted(p for p in args.directory.glob('*.json') if p.name != 'chain.schema.json')
    if not paths:
        parser.error(f'no chain records in {args.directory}')
    failed = False
    for path in paths:
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError) as error:
            print(f'{path}: {error}')
            failed = True
            continue
        for error in validator.iter_errors(data):
            location = '.'.join(map(str, error.absolute_path)) or '<root>'
            print(f'{path}: {location}: {error.message}')
            failed = True
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())

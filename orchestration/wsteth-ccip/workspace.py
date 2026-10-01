#!/usr/bin/env python3
"""Prepare and select local wstETH run workspaces; never deploy on preparation."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OPERATIONS = ROOT / 'orchestration/wsteth-ccip'
RUNS = ROOT / 'runs/wsteth-2.0'
ALIASES = ('config', 'state', 'broadcast', 'deployments')
SAFE_RECIPES = {'build', 'build-l2-artifacts', 'build-ccip', 'fmt', 'fmt-check',
                'slither', 'lint-config', 'init', 'init-thirdparty',
                'patch-submodules', 'patch-submodules-check', 'patch-submodules-revert'}


def identifier(value):
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', value):
        raise ValueError('Use a simple name containing letters, digits, dots, underscores or hyphens')
    return value


def read_json(path):
    return json.loads(path.read_text())


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


GENERATED = {'out', 'cache', '__pycache__'}


def hashes(directory, *, owned=False):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(directory.rglob('*')) if p.is_file()
            and not (owned and GENERATED.intersection(p.relative_to(directory).parts))}


def git(*args, cwd=ROOT):
    return subprocess.check_output(['git', '-C', str(cwd), *args], text=True,
                                   env=dict(os.environ, GIT_OPTIONAL_LOCKS='0')).strip()


@contextmanager
def exclusive():
    RUNS.mkdir(parents=True, exist_ok=True)
    with (RUNS / '.operation.lock').open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another wstETH operation is using the orchestration workspace') from None
        yield


def target(name):
    directory = ROOT / 'targets' / identifier(name)
    data = read_json(directory / 'target.json')
    if (data.get('schemaVersion') != 1 or data.get('id') != name or
            data.get('orchestration') != 'wsteth-ccip' or
            data.get('operation') != 'scratch-deployment' or
            data.get('configDirectory') != 'config'):
        raise ValueError('Unsupported target: this adapter implements wstETH CCIP scratch deployment only')
    if data.get('status') != 'ready':
        raise ValueError('Target is incomplete: configuration and applicable operations must be established first')
    chains = data['networks']
    if chains['l1']['slug'] != 'sepolia' or chains['l1']['chainId'] != 11155111:
        raise ValueError('This recipe currently supports Sepolia as its L1')
    identifier(chains['l2']['slug'])
    for network in chains.values():
        cfg = read_json(directory / 'config/chains' / (network['slug'] + '.json'))
        if cfg['chain']['chain_id'] != network['chainId']:
            raise ValueError('Target network does not match its chain configuration')
        if cfg.get('deployed') or cfg.get('ccv') or cfg['addresses']['token']:
            raise ValueError('Target chain input contains deployment outputs')
    return directory, data


def checked_run(name):
    directory = RUNS / 'workspaces' / identifier(name)
    if directory.is_symlink() or directory.resolve().parent != (RUNS / 'workspaces').resolve():
        raise ValueError('Run must be stored in this repository, not an external directory')
    data = read_json(directory / 'run.json')
    if data['id'] != name or data['environment'] not in ('fork', 'testnet'):
        raise ValueError('Invalid run identity or environment')
    if hashes(directory / 'inputs') != data['inputHashes']:
        raise ValueError('Run input snapshot changed; prepare a new run instead of editing history')
    return directory, data


def activation_preconditions():
    for alias in (*ALIASES, '.active-run'):
        link = OPERATIONS / alias
        if link.exists() and not link.is_symlink():
            raise ValueError(f'Refusing to replace a real orchestration directory: {alias}')
        temporary = OPERATIONS / (alias + '.next')
        if temporary.exists() or temporary.is_symlink():
            raise ValueError(f'Unfinished workspace switch: {temporary.name}')


def activate(name):
    directory, _ = checked_run(name)
    activation_preconditions()
    destinations = {alias: directory / alias for alias in ALIASES}
    destinations['.active-run'] = directory
    for alias, dest in destinations.items():
        if not dest.is_dir():
            raise ValueError(f'Missing run directory: {alias}')
    previous = {alias: os.readlink(OPERATIONS / alias) if (OPERATIONS / alias).is_symlink()
                else None for alias in destinations}
    changed = []
    try:
        for alias, dest in destinations.items():
            (OPERATIONS / (alias + '.next')).symlink_to(
                os.path.relpath(dest, OPERATIONS), target_is_directory=True)
        for alias in destinations:
            (OPERATIONS / (alias + '.next')).replace(OPERATIONS / alias)
            changed.append(alias)
    except OSError:
        for alias in reversed(changed):
            link = OPERATIONS / alias
            link.unlink()
            if previous[alias] is not None:
                link.symlink_to(previous[alias], target_is_directory=True)
        raise
    finally:
        for alias in destinations:
            (OPERATIONS / (alias + '.next')).unlink(missing_ok=True)


def owned_sources(source, data):
    yield source, Path('target')
    for entry in ('src', 'script', 'patches', 'foundry.toml', 'remappings.txt',
                  'migration-source.json', 'dependencies.json'):
        yield OPERATIONS / entry, Path('orchestration') / entry
    for entry in ('justfile', 'workspace.py'):
        yield OPERATIONS / entry, Path(entry)
    if 'wsteth-token' in data.get('components', []):
        yield ROOT / 'components/wsteth-token', Path('components/wsteth-token')


def check_live_sources(directory, data):
    snapshot = directory / 'inputs'
    target_data = read_json(snapshot / 'target/target.json')
    for live, relative in owned_sources(ROOT / 'targets' / identifier(data['target']), target_data):
        saved = snapshot / relative
        if live.is_dir() and saved.is_dir():
            matches = hashes(live, owned=True) == hashes(saved, owned=True)
        else:
            matches = live.is_file() and saved.is_file() and live.read_bytes() == saved.read_bytes()
        if not matches:
            raise ValueError(f'Live source differs from run snapshot: {relative}; prepare a new run')


def dependency_checkout(path):
    checkout = (OPERATIONS / path).resolve()
    if not checkout.is_dir() or Path(git('rev-parse', '--show-toplevel', cwd=checkout)).resolve() != checkout:
        raise ValueError(f'Dependency is not an initialized checkout: {path}; run just wsteth init-thirdparty')
    return checkout


def active():
    link = OPERATIONS / '.active-run'
    if not link.is_symlink():
        raise ValueError('No run selected. Use just wsteth-prepare <target> <run-id> <fork|testnet>')
    directory = link.resolve()
    if directory.parent != (RUNS / 'workspaces').resolve():
        raise ValueError('Active run points outside this repository')
    directory, data = checked_run(directory.name)
    for name in ALIASES:
        alias = OPERATIONS / name
        if not alias.is_symlink() or alias.resolve() != (directory / name).resolve():
            raise ValueError('Workspace links do not agree; select the run again')
    check_live_sources(directory, data)
    return directory, data


def prepare(name, run_id, environment, record=None):
    source, data = target(name)
    if environment not in data['environments']:
        raise ValueError('Environment is not supported by this target')
    directory = RUNS / 'workspaces' / identifier(run_id)
    if directory.exists() or directory.is_symlink():
        raise ValueError('Run already exists; select it to resume, or use a new run ID')
    # Validate an optional existing record before creating any workspace.
    record_path = None
    if record:
        record_path = (ROOT / record).resolve()
        if not record_path.is_relative_to(RUNS.resolve()):
            raise ValueError('Existing record must be under runs/wsteth-2.0')
        for network in data['networks'].values():
            cfg = read_json(record_path / (network['slug'] + '.json'))
            if cfg['chain']['chain_id'] != network['chainId']:
                raise ValueError('Existing record belongs to a different network')
    activation_preconditions()
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f'.{run_id}.', dir=directory.parent) as temporary:
        staging = Path(temporary) / 'run'
        staging.mkdir()
        populate_run(source, data, staging, run_id, environment, record_path)
        staging.rename(directory)
        try:
            activate(run_id)
        except Exception:
            shutil.rmtree(directory)
            raise
    print(f'Prepared {run_id} ({environment}); no deployment or network operation performed.')


def populate_run(source, data, directory, run_id, environment, record_path):
    for live, relative in owned_sources(source, data):
        saved = directory / 'inputs' / relative
        saved.parent.mkdir(parents=True, exist_ok=True)
        if live.is_dir():
            shutil.copytree(live, saved, ignore=shutil.ignore_patterns(*GENERATED))
        else:
            shutil.copy2(live, saved)
    shutil.copytree(directory / 'inputs/target/config', directory / 'config')
    for name in ('state', 'broadcast', 'deployments'):
        (directory / name).mkdir()
    if record_path:
        shutil.copytree(record_path, directory / 'inputs/record')
        for network in data['networks'].values():
            filename = network['slug'] + '.json'
            shutil.copy2(record_path / filename, directory / 'config/chains' / filename)
        if (record_path / 'state').is_dir():
            shutil.copytree(record_path / 'state', directory / 'state', dirs_exist_ok=True)
    dependencies = []
    for path in read_json(OPERATIONS / 'dependencies.json'):
        dep = {'path': path}
        checkout = dependency_checkout(path)
        dependencies.append({'path': dep['path'], 'commit': git('rev-parse', 'HEAD', cwd=checkout),
                             'dirty': bool(git('status', '--porcelain', cwd=checkout))})
        # Keep local tracked changes with the run, not just a dirty flag.
        patch = directory / 'inputs/dependency-diffs' / (dep['path'].replace('/', '__') + '.patch')
        patch.parent.mkdir(parents=True, exist_ok=True)
        patch.write_text(git('diff', '--binary', 'HEAD', cwd=checkout) + '\n')
    write_json(directory / 'run.json', {
        'schemaVersion': 1, 'id': run_id, 'target': data['id'],
        'environment': environment, 'l2Chain': data['networks']['l2']['slug'],
        'status': 'prepared', 'preparedAt': datetime.now(timezone.utc).isoformat(),
        'repositoryCommit': git('rev-parse', 'HEAD'),
        'sourceImportCommit': read_json(OPERATIONS / 'migration-source.json')['sourceCommit'],
        'dependencies': dependencies,
        'recordSource': str(record_path.relative_to(ROOT)) if record_path else None,
        'inputHashes': hashes(directory / 'inputs'),
    })


def execute(arguments):
    arguments = arguments or ['--list']
    # Passing arbitrary just flags can change cwd or select another justfile.
    # Only introspection flags are supported through this adapter.
    if arguments[0].startswith('-') and arguments not in [['--list'], ['--summary']]:
        raise ValueError('Use a recipe name, --list, or --summary')
    if arguments[0] in SAFE_RECIPES and len(arguments) != 1:
        raise ValueError('Run one build/setup recipe at a time')
    env = dict(os.environ)
    if arguments[0] == 'lint-config' and (OPERATIONS / '.active-run').is_symlink():
        directory, _ = active()
        env['WSTETH_TARGET_DIR'] = str(directory / 'inputs/target')
    if arguments[0] not in SAFE_RECIPES and arguments[0] not in ('--list', '--summary'):
        directory, data = active()
        if env.get('L2_CHAIN', data['l2Chain']) != data['l2Chain']:
            raise ValueError('L2_CHAIN differs from the selected target')
        env['L2_CHAIN'] = data['l2Chain']
        env['WSTETH_RUN_ENVIRONMENT'] = data['environment']
        env['WSTETH_TARGET_DIR'] = str(directory / 'inputs/target')
        env['WSTETH_TEST_DIR'] = str(ROOT / 'targets' / data['target'] / 'test')
    result = subprocess.run(['just', '--justfile', str(ROOT / 'orchestration/wsteth-ccip/justfile'),
                             *([] if arguments[0].startswith('-') else ['--']),
                             *arguments], cwd=OPERATIONS, env=env)
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('prepare')
    p.add_argument('target'); p.add_argument('run_id'); p.add_argument('environment', nargs='?', default='fork', choices=['fork', 'testnet'])
    p.add_argument('--record', help='Repository-relative existing record to copy into this run')
    p = commands.add_parser('use'); p.add_argument('run_id')
    commands.add_parser('require-active')
    commands.add_parser('restore-templates')
    p = commands.add_parser('run'); p.add_argument('arguments', nargs=argparse.REMAINDER)
    args = (argparse.Namespace(command='run', arguments=sys.argv[2:])
            if sys.argv[1:2] == ['run'] else parser.parse_args())
    try:
        # Helpers called from within a recipe inherit the outer operation lock.
        if args.command == 'require-active':
            active()
            return 0
        if args.command == 'restore-templates':
            directory, _ = active()
            for p in (directory / 'inputs/target/config/chains').glob('*.json'):
                shutil.copy2(p, directory / 'config/chains' / p.name)
            return 0
        with exclusive():
            if args.command == 'prepare': prepare(args.target, args.run_id, args.environment, args.record)
            elif args.command == 'use': activate(args.run_id)
            elif args.command == 'run': return execute(args.arguments)
        return 0
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f'wsteth: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

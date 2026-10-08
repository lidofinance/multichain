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

# Execute each phase across all spokes before advancing to the next phase.
# In particular, ALL pools must exist before any cross-chain configuration.
PIPELINES = {
    'all': ['patch-submodules', 'preflight', 'build-l2-artifacts', 'build', 'build-ccip',
            'forks-check', 'l1-core-dg', 'l2-gov', 'l2-token', 'ccip-deploy',
            'ccip-configure', 'set-pool-gov', 'test-scenarios', 'verify-state', 'verify-contracts'],
    'test-leaf': ['verify-state', 'test-scenarios'],
}
PER_SPOKE = {'preflight', 'forks-check', 'l2-gov', 'l2-token', 'ccip-deploy',
             'ccip-configure', 'set-pool-gov', 'test-scenarios', 'test-ccv',
             'verify-state', 'verify-contracts'}
HUB_ONCE = {'ccip-deploy', 'ccip-configure', 'set-pool-gov', 'verify-contracts'}


def spokes(data):
    networks = data['networks']
    result = networks.get('l2s', [networks['l2']] if 'l2' in networks else [])
    if not isinstance(result, list) or not result:
        raise ValueError('Specify at least one spoke in networks.l2s')
    names = [identifier(n['slug']) for n in [networks['l1'], *result]]
    ids = [n['chainId'] for n in [networks['l1'], *result]]
    if len(set(names)) != len(names) or len(set(ids)) != len(ids):
        raise ValueError('Duplicate network slug or chain ID')
    return result


def networks(data):
    return [data['networks']['l1'], *spokes(data)]


def identifier(value):
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', value):
        raise ValueError('Use a simple name containing letters, digits, dots, underscores or hyphens')
    return value


def read_json(path):
    return json.loads(path.read_text())


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


GENERATED = {'out', 'cache', '__pycache__'}
# Pinned submodules inside an owned component (components/wsteth-token/lib) are dependencies: the run
# records their commit, dirty flag and diff via dependencies.json instead of copying the checkout.
def excluded_owned_path(relative, source):
    return bool(GENERATED.intersection(relative.parts) or
                (source == Path('components/wsteth-token') and relative.parts[0] == 'lib'))


def owned_copy_ignore(root, source):
    return lambda directory, names: [name for name in names
                                    if excluded_owned_path((Path(directory) / name).relative_to(root), source)]


def hashes(directory, *, owned=False, source=None):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(directory.rglob('*')) if p.is_file()
            and not (owned and excluded_owned_path(p.relative_to(directory), source))}


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
    for network in networks(data):
        cfg = read_json(directory / 'config/chains' / (network['slug'] + '.json'))
        if cfg['chain']['chain_id'] != network['chainId']:
            raise ValueError('Target network does not match its chain configuration')
        if cfg.get('deployed') or cfg.get('ccv') or cfg['addresses']['token']:
            raise ValueError('Target chain input contains deployment outputs')
    if 'l2s' in chains:
        leaf_names = [n['slug'] for n in spokes(data)]
        for network in networks(data):
            cfg = read_json(directory / 'config/chains' / (network['slug'] + '.json'))
            hub = network == chains['l1']
            expected = leaf_names if hub else [chains['l1']['slug']]
            lanes = cfg.get('remote_lanes', [])
            if ([lane['remote_chain_name'] for lane in lanes] != expected or
                    any(lane['is_siloed'] != hub for lane in lanes) or
                    cfg['chain']['pool_type'] != ('SiloedLockRelease' if hub else 'BurnMint')):
                raise ValueError('Target must declare a siloed hub and reciprocal spoke lanes')
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
            matches = hashes(live, owned=True, source=relative) == hashes(saved, owned=True, source=relative)
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


def prepare(name, run_id, environment, record=None, selected_spokes=None):
    source, data = target(name)
    leaves = [n['slug'] for n in spokes(data)]
    if selected_spokes is not None:
        if not selected_spokes or len(set(selected_spokes)) != len(selected_spokes) or any(s not in leaves for s in selected_spokes):
            raise ValueError('Selected spokes must be a nonempty unique subset of the target')
        leaves = [s for s in leaves if s in selected_spokes]
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
        for network in networks(data):
            if network['slug'] != 'sepolia' and network['slug'] not in leaves:
                continue
            cfg = read_json(record_path / (network['slug'] + '.json'))
            if cfg['chain']['chain_id'] != network['chainId']:
                raise ValueError('Existing record belongs to a different network')
    activation_preconditions()
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f'.{run_id}.', dir=directory.parent) as temporary:
        staging = Path(temporary) / 'run'
        staging.mkdir()
        populate_run(source, data, staging, run_id, environment, record_path, leaves)
        staging.rename(directory)
        try:
            activate(run_id)
        except Exception:
            shutil.rmtree(directory)
            raise
    print(f'Prepared {run_id} ({environment}); no deployment or network operation performed.')


def populate_run(source, data, directory, run_id, environment, record_path, leaves):
    for live, relative in owned_sources(source, data):
        saved = directory / 'inputs' / relative
        saved.parent.mkdir(parents=True, exist_ok=True)
        if live.is_dir():
            shutil.copytree(live, saved, ignore=owned_copy_ignore(live, relative))
        else:
            shutil.copy2(live, saved)
    shutil.copytree(directory / 'inputs/target/config', directory / 'config')
    for name in ('state', 'broadcast', 'deployments'):
        (directory / name).mkdir()
    if record_path:
        shutil.copytree(record_path, directory / 'inputs/record')
        for network in networks(data):
            if network['slug'] != 'sepolia' and network['slug'] not in leaves:
                continue
            filename = network['slug'] + '.json'
            shutil.copy2(record_path / filename, directory / 'config/chains' / filename)
        record_state = record_path / 'state'
        if not record_state.is_dir() and record_path.name == 'chains':
            record_state = record_path.parent / 'state'
        if record_state.is_dir():
            shutil.copytree(record_state, directory / 'state', dirs_exist_ok=True)
            if record_state != record_path / 'state':
                shutil.copytree(record_state, directory / 'inputs/record/state')
            legacy = directory / 'state/l2.json'
            if legacy.exists():
                state = read_json(legacy)
                leaf = state.get('l2Chain', 'mantle_sepolia')
                if leaf in leaves:
                    shutil.copy2(legacy, directory / 'state' / f'{leaf}.json')
    # Subset selection changes run intent only; the source snapshot remains immutable.
    selected = {'sepolia', *leaves}
    for network in networks(data):
        filename = directory / 'config/chains' / (network['slug'] + '.json')
        if network['slug'] not in selected:
            filename.unlink()
            continue
        config = read_json(filename)
        if 'remote_lanes' in config:
            if record_path and any(l['remote_chain_name'] not in selected for l in config['remote_lanes']):
                raise ValueError('Cannot hide existing lanes by importing a record into a smaller topology')
            config['remote_lanes'] = [l for l in config['remote_lanes'] if l['remote_chain_name'] in selected]
            write_json(filename, config)
    policy_path = directory / 'config/ccv-policy.json'
    if record_path:
        policy_path.unlink(missing_ok=True)
        if (record_path / 'ccv-policy.json').exists():
            shutil.copy2(record_path / 'ccv-policy.json', policy_path)
        # Missing policy remains missing: verify-state applies only its guarded historical
        # single-lane fallback, and rejects modern/multi-lane records without explicit intent.
    if policy_path.exists():
        policy = read_json(policy_path)
        policy['chains'] = {c: v for c, v in policy['chains'].items() if c in selected}
        for spec in policy['chains'].values():
            spec['lanes'] = {c: v for c, v in spec['lanes'].items() if c in selected}
            spec['localResolver']['outbound'] = {c: v for c, v in spec['localResolver']['outbound'].items() if c in selected}
            for external in spec.get('externalResolvers', {}).values():
                external['outbound'] = {c: v for c, v in external['outbound'].items() if c in selected}
        write_json(policy_path, policy)
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
        'environment': environment, 'l2Chain': leaves[0],
        'l2Chains': leaves,
        'chainStateFiles': True,
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
        leaves = data.get('l2Chains', [data['l2Chain']])
        if env.get('L2_CHAIN', leaves[0]) not in leaves:
            raise ValueError('L2_CHAIN differs from the selected target')
        selected = [env['L2_CHAIN']] if env.get('L2_CHAIN') else leaves
        if arguments[0] == 'all' and selected != leaves:
            raise ValueError('all operates on the complete target; unset L2_CHAIN')
        env['L2_CHAIN'] = selected[0]
        env['WSTETH_RUN_ENVIRONMENT'] = data['environment']
        env['WSTETH_TARGET_DIR'] = str(directory / 'inputs/target')
        env['WSTETH_TEST_DIR'] = str(ROOT / 'targets' / data['target'] / 'test')
        env['WSTETH_L2_CHAINS'] = ' '.join(leaves)
        if arguments[0] in PIPELINES and len(arguments) != 1:
            raise ValueError('Pipeline recipes take no arguments')
        skip_hub = env.get('WSTETH_SKIP_L1', '0')
        if skip_hub not in ('0', '1'):
            raise ValueError('WSTETH_SKIP_L1 must be 0 or 1')
        for recipe in PIPELINES.get(arguments[0], [arguments[0]]):
            for index, leaf in enumerate(selected if recipe in PER_SPOKE else selected[:1]):
                child = dict(env, L2_CHAIN=leaf,
                             WSTETH_SKIP_L1=('1' if index or skip_hub == '1' else '0') if recipe in HUB_ONCE else '0')
                if data.get('chainStateFiles'):
                    child['L2_STATE_FILE'] = f'state/{leaf}.json'
                result = subprocess.run(['just', '--justfile', str(OPERATIONS / 'justfile'), '--',
                                         recipe, *(arguments[1:] if recipe == arguments[0] else [])],
                                        cwd=OPERATIONS, env=child)
                if result.returncode:
                    return result.returncode
        return 0
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
    p.add_argument('--spokes', nargs='+', help='Deploy a subset of the target spokes (default: all)')
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
            directory, data = active()
            if 'l2Chains' in data:
                raise ValueError('Prepare a new run to reset deployment inputs; restoring templates would erase selected topology and deployed records')
            for p in (directory / 'inputs/target/config/chains').glob('*.json'):
                shutil.copy2(p, directory / 'config/chains' / p.name)
            return 0
        with exclusive():
            if args.command == 'prepare':
                if args.spokes is None:
                    prepare(args.target, args.run_id, args.environment, args.record)
                else:
                    prepare(args.target, args.run_id, args.environment, args.record, args.spokes)
            elif args.command == 'use': activate(args.run_id)
            elif args.command == 'run': return execute(args.arguments)
        return 0
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f'wsteth: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

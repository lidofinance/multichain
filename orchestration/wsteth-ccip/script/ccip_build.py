#!/usr/bin/env python3
"""Guard pinned executable CCIP sources and bind release artifacts to their actual inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import tarfile

ROOT = Path(__file__).resolve().parents[3]
CCIP = ROOT / 'components/ccip'
EVM = CCIP / 'chains/evm'
OUT = EVM / 'foundry-artifacts'
STAMP = OUT / 'wsteth-build.json'
SOURCE_ARCHIVE = OUT / 'wsteth-inputs.tar.gz'
DEPLOYED_ARTIFACTS = ('ERC20LockBox', 'SiloedLockReleaseTokenPool', 'BurnMintTokenPool',
    'PausableAdvancedPoolHooks', 'DummyMessageIdVerifier', 'VersionedVerifierResolver',
    'LidoTimelock', 'CallProxy', 'ERC20BridgedPermit', 'TransparentUpgradeableProxy', 'ProxyAdmin')

# forge config also resolves RPC URLs, explorer credentials and wallet options.
# Build provenance contains compiler settings only, never the entire tool environment.
COMPILER_SETTINGS = frozenset({
    'solc', 'auto_detect_solc', 'offline', 'evm_version', 'optimizer', 'optimizer_runs',
    'optimizer_details', 'via_ir', 'bytecode_hash', 'cbor_metadata', 'use_literal_content',
    'revert_strings', 'sparse_mode', 'compilation_restrictions', 'additional_compiler_profiles',
})


def compiler_settings(settings):
    return {name: value for name, value in settings.items() if name in COMPILER_SETTINGS}


def git(*args, cwd=CCIP):
    return subprocess.check_output(['git', *args], cwd=cwd).decode().strip()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def executable(path):
    """Only *.t.sol tests are skipped by build; helpers remain compiler inputs."""
    p = Path(path)
    if p.name.endswith('.t.sol') or p.suffix == '.md':
        return False
    if len(p.parts) > 6 and p.parts[:6] == ('chains', 'evm', 'contracts', 'lido-hvmv', 'config', 'chains'):
        if p.parts[6].startswith('.wsteth-run.'):
            return False
    return (path.startswith('chains/evm/contracts/') or path.startswith('chains/evm/scripts/')
            or path in ('chains/evm/foundry.toml', 'chains/evm/remappings.txt',
                        'chains/evm/package.json', 'chains/evm/pnpm-lock.yaml',
                        'package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml'))


def guard():
    entries = git('ls-files', '--stage', '--', 'components/ccip', cwd=ROOT).splitlines()
    pins = [line.split()[1] for line in entries if line.startswith('160000 ') and line.split()[2] == '0']
    if len(pins) != 1 or git('rev-parse', 'HEAD') != pins[0]:
        raise ValueError('CCIP HEAD differs from the parent gitlink')
    changes = git('diff', '--name-only', 'HEAD').splitlines()
    # --others without --exclude-standard deliberately includes ignored sources.
    additions = git('ls-files', '--others', '--', 'chains/evm/contracts', 'chains/evm/scripts').splitlines()
    bad = sorted({p for p in changes + additions if executable(p)})
    if bad:
        raise ValueError('Modified/unrecorded executable CCIP inputs: ' + ', '.join(bad))
    return pins[0]


def input_hashes():
    inputs = {}
    for name in git('ls-files').splitlines():
        if executable(name):
            inputs[name] = sha(CCIP / name)
    # Hash the actual files reached by remappings, including materialized local token sources.
    roots = set()
    for line in (EVM / 'remappings.txt').read_text().splitlines():
        if '=' in line and 'node_modules/' in line.split('=', 1)[1]:
            roots.add(line.split('=', 1)[1].strip().rstrip('/'))
    for root in sorted(roots):
        path = EVM / root
        if not path.is_dir():
            raise ValueError('Missing compiler package: ' + root)
        for folder, dirs, files in os.walk(path, followlinks=True):
            dirs[:] = sorted(d for d in dirs if d not in ('.git', 'node_modules', 'out', 'cache'))
            for name in sorted(files):
                file = Path(folder) / name
                if file.suffix == '.sol' or name == 'package.json':
                    inputs['chains/evm/' + file.relative_to(EVM).as_posix()] = sha(file)
    return inputs


def artifact_hashes():
    return {str(p.relative_to(OUT)): sha(p) for p in sorted(OUT.rglob('*.json')) if p != STAMP}


def verify():
    revision = guard()
    if not STAMP.is_file():
        raise ValueError('Missing CCIP build provenance; run build-ccip')
    stamp = json.loads(STAMP.read_text())
    if stamp['revision'] != revision or stamp['inputs'] != input_hashes():
        raise ValueError('CCIP source/package inputs changed since build; rebuild required')
    if stamp['artifacts'] != artifact_hashes():
        raise ValueError('CCIP artifacts changed since build; rebuild required')
    if stamp['sourceArchiveSha256'] != sha(SOURCE_ARCHIVE):
        raise ValueError('CCIP build source archive changed; rebuild required')
    return stamp


def build():
    revision = guard()
    inputs = input_hashes()
    STAMP.unlink(missing_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('FOUNDRY_')}
    env['FOUNDRY_PROFILE'] = 'ccip-compile'
    settings = compiler_settings(json.loads(subprocess.check_output(['forge', 'config', '--json'], cwd=EVM, env=env)))
    # --force clears stale outputs; test changes never enter this build.
    subprocess.run(['forge', 'build', '--force', '--no-lint', '--skip', '*.t.sol'], cwd=EVM, env=env, check=True)
    if revision != guard() or inputs != input_hashes():
        raise ValueError('Compiler inputs changed during the build')
    with tarfile.open(SOURCE_ARCHIVE, 'w:gz') as archive:
        for name in sorted(inputs):
            archive.add(CCIP / name, arcname=name, recursive=False)
    STAMP.write_text(json.dumps({'schemaVersion': 1, 'revision': revision, 'profile': 'ccip-compile',
                                'settings': settings, 'inputs': inputs, 'artifacts': artifact_hashes(),
                                'sourceArchiveSha256': sha(SOURCE_ARCHIVE)}, indent=2) + '\n')


def archive_build(destination):
    verify()
    destination.mkdir(parents=True, exist_ok=True)
    for file in (STAMP, SOURCE_ARCHIVE):
        target = destination / file.name
        if target.exists() and sha(target) != sha(file):
            raise ValueError('Run already contains another CCIP build; prepare a new run')
        shutil.copy2(file, target)
    for name in DEPLOYED_ARTIFACTS:
        shutil.copy2(OUT / f'{name}.sol/{name}.json', destination / (name + '.json'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['guard', 'build', 'verify', 'archive'])
    parser.add_argument('destination', nargs='?', type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'archive':
            if not args.destination:
                parser.error('archive requires a destination')
            archive_build(args.destination)
        else:
            globals()[args.action]()
        print('CCIP ' + args.action + ': passed')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')

#!/usr/bin/env python3
"""Run owned hub scripts against this run's fork, retaining failed/partial execution evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import ccip_build
from bootstrap.rpc import Fork, cast, read, write

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))
import workspace

SCRIPTS = {
    'deploy': 'DeployHubForMigration', 'configure': 'ConfigureHubForMigration',
    'prepare-lane': 'PrepareHubLane', 'proposal': 'BuildHubLaneProposal',
}


def inputs_hash(run, chain):
    files = [run / 'state/hub-migration/manifest.json',
             ccip_build.EVM / 'contracts/lido-hvmv/config/default_config.json']
    files += sorted((run / 'config/chains').glob('*.json'))
    # Names and exact bytes are bound, not absolute checkout paths.
    return hashlib.sha256(json.dumps([(p.name, ccip_build.sha(p)) for p in files]).encode()).hexdigest()


def validate_manifest(run, cfg):
    manifest = read(run / 'state/hub-migration/manifest.json')
    if manifest['readAt']['chainId'] != cfg['chain']['chain_id']:
        raise ValueError('Manifest chain mismatch')
    lanes = {lane['slug']: lane for lane in manifest['lanes']}
    if len(lanes) != len(manifest['lanes']) or set(lanes) != set(cfg['imported_lanes']):
        raise ValueError('Manifest imported lane set mismatch')
    grouped = [name for group in manifest['lockBoxGroups'].values() for name in group['lanes']]
    if sorted(grouped) != sorted(lanes):
        raise ValueError('Manifest custody groups must partition imported lanes')
    for name, lane in lanes.items():
        group = next(group for group in manifest['lockBoxGroups'].values() if name in group['lanes'])
        if lane['siloed'] and group['lanes'] != [name]:
            raise ValueError('Siloed lane must have its own custody group')
        if not lane['siloed'] and set(group['lanes']) != {n for n, l in lanes.items() if not l['siloed']}:
            raise ValueError('Unsiloed lanes must share one custody group')
    return manifest


def runtime_matches(artifact, actual):
    expected = artifact['deployedBytecode']
    if expected.get('linkReferences'):
        raise ValueError('Linked artifacts need explicit library verification')
    code = bytearray.fromhex(actual.removeprefix('0x'))
    template = bytearray.fromhex(expected['object'].removeprefix('0x'))
    if len(code) != len(template) or not code:
        return False
    for refs in expected.get('immutableReferences', {}).values():
        for ref in refs:
            start, length = ref['start'], ref['length']
            code[start:start + length] = template[start:start + length] = bytes(length)
    return code == template


def verify_deployments(fork, run, script, audit, cfg):
    journal = read(audit / 'deployments.json')
    broadcast_path = run / f'broadcast/hub-migration/{script}.s.sol/{cfg["chain"]["chain_id"]}/run-latest.json'
    broadcast = read(broadcast_path)
    receipts = {r['transactionHash'].lower(): r for r in broadcast['receipts']}
    evidence = []
    for entry in journal['deployments']:
        name, address = entry['contract'], entry['address']
        path = ccip_build.OUT / f'{name}.sol/{name}.json'
        artifact = read(path)
        meta = artifact['metadata']
        source = next(k for k, v in meta['settings']['compilationTarget'].items() if v == name)
        code = artifact['bytecode']['object']
        if cast('keccak', code).lower() != entry['creationCodeHash'].lower():
            raise ValueError('Creation code differs from CCIP artifact: ' + name)
        creation = code + entry['constructorArgs'][2:]
        tx = next((t for t in broadcast['transactions'] if t['transactionType'] == 'CREATE'
                   and t['contractAddress'].lower() == address.lower()), None)
        if not tx or tx['transaction']['input'].lower() != creation.lower():
            raise ValueError('Missing matching CREATE transaction: ' + name)
        receipt = receipts.get(tx['hash'].lower(), {})
        if int(receipt.get('status', '0x0'), 16) != 1:
            raise ValueError('Missing successful CREATE receipt: ' + name)
        if not runtime_matches(artifact, fork.rpc('eth_getCode', address, 'latest')):
            raise ValueError('Runtime differs from CCIP artifact: ' + name)
        observed = {}
        checks = []
        if name in ('ERC20LockBox', 'SiloedLockReleaseTokenPool'):
            checks.append(('getToken()(address)', cfg['addresses']['token']))
        if name == 'SiloedLockReleaseTokenPool':
            checks += [('getDynamicConfig()(address,address,address)', cfg['ccip']['router']),
                       ('getRmnProxy()(address)', cfg['ccip']['rmn_proxy'])]
        if name == 'CallProxy':
            # No public getter: bind every immutable reference to the intended forwarding target.
            runtime = bytes.fromhex(fork.rpc('eth_getCode', address, 'latest')[2:])
            for refs in artifact['deployedBytecode']['immutableReferences'].values():
                for ref in refs:
                    value = int.from_bytes(runtime[ref['start']:ref['start'] + ref['length']], 'big')
                    if value != int(cfg['deployed']['timelock'], 16):
                        raise ValueError('CallProxy target immutable mismatch')
            observed['targetImmutable'] = cfg['deployed']['timelock']
        for signature, expected in checks:
            value = fork.call(address, signature)
            if str(value).lower() != expected.lower():
                raise ValueError(name + ': constructor readback mismatch: ' + signature)
            observed[signature] = value
        evidence.append({**entry, 'sourceContract': source + ':' + name, 'compiler': meta['compiler'],
                         'settings': meta['settings'], 'artifactSha256': ccip_build.sha(path),
                         'transactionHash': tx['hash'], 'runtimeChecked': True, 'constructorReadback': observed})
    write(audit / 'verified-deployments.json', evidence)


def run(action, chain, url, dry_run=False):
    if 'HUB_MIGRATION_ONLY' in os.environ:
        raise ValueError('Obsolete HUB_MIGRATION_ONLY is forbidden')
    directory, info = workspace.active()
    if info['environment'] != 'fork' or info['operation'] != 'in-place-upgrade':
        raise ValueError('Hub migration runner is restricted to in-place fork rehearsals')
    if chain != info['l1Chain']:
        raise ValueError('Hub runner requires this run\'s L1 chain')
    config_path = directory / 'config/chains' / (chain + '.json')
    cfg = read(config_path)
    validate_manifest(directory, cfg)
    fork = Fork(chain, url, cfg['chain']['chain_id'])
    stamp = ccip_build.verify()
    ccip_build.archive_build(directory / 'state/ccip-build')
    if action in ('prepare-lane', 'proposal'):
        checkpoint = read(directory / 'state/hub-checkpoint.json')
        if checkpoint.get('status') != 'passed':
            raise ValueError('Hub checkpoint must pass before Base preparation')
        # A file alone is not evidence that this fork still binds the same hub.
        current = fork.call(cfg['ccip']['token_admin_registry'], 'getPool(address)(address)', cfg['addresses']['token'])
        if current.lower() != cfg['deployed']['token_pool'].lower():
            raise ValueError('Current TAR does not bind the recorded migrated hub')
    script = SCRIPTS[action]
    audit = directory / 'state/hub-scripts' / (action + ('-dry-run' if dry_run else ''))
    audit.mkdir(parents=True, exist_ok=False)
    records = {p.name: p.read_bytes() for p in (directory / 'config/chains').glob('*.json')}
    before_block = fork.rpc('eth_blockNumber')
    env = {k: v for k, v in os.environ.items() if not k.startswith('FOUNDRY_')}
    env.update(FOUNDRY_PROFILE='hub-migration', FOUNDRY_BROADCAST=str(directory / 'broadcast/hub-migration'),
               CHAIN_CONFIG=str(config_path), DEFAULT_CONFIG=str(ccip_build.EVM / 'contracts/lido-hvmv/config/default_config.json'),
               HUB_MANIFEST=str(directory / 'state/hub-migration/manifest.json'), CCIP_ARTIFACTS=str(ccip_build.OUT),
               ARTIFACT_DEPLOYMENTS_OUT=str(audit / 'deployments.json'), WSTETH_RUN_ID=info['id'],
               HUB_INPUTS_HASH=inputs_hash(directory, chain))
    command = ['forge', 'script', f'script/hub-migration/{script}.s.sol:{script}', '--rpc-url', url,
               '--skip', '*.t.sol', '-vv']
    if action != 'proposal' and not dry_run:
        command.append('--broadcast')
    write(audit / 'inputs.json', {'runId': info['id'], 'chainId': cfg['chain']['chain_id'],
          'inputsHash': env['HUB_INPUTS_HASH'], 'sourceRevision': stamp['revision'],
          'buildProvenanceSha256': ccip_build.sha(ccip_build.STAMP), 'action': action, 'dryRun': dry_run})
    shutil.copy2(ccip_build.STAMP, audit / 'build-provenance.json')
    result = {'status': 'failed', 'action': action}
    try:
        # Verify again immediately before handing control to the broadcaster.
        ccip_build.verify()
        rc = subprocess.call(command, cwd=OPS, env=env)
        result['exitCode'] = rc
        if rc:
            return rc
        if dry_run or action == 'proposal':
            after = {p.name: p.read_bytes() for p in (directory / 'config/chains').glob('*.json')}
            if records != after or fork.rpc('eth_blockNumber') != before_block:
                raise ValueError('Non-broadcast runner changed records or chain state')
        elif action in ('deploy', 'prepare-lane'):
            verify_deployments(fork, directory, script, audit, read(config_path))
        result['status'] = 'passed'
        return 0
    finally:
        # Never discard partial records or receipts. A failed fork is recreated, not silently resumed.
        write(audit / 'result.json', result)
        shutil.copytree(directory / 'config/chains', audit / 'records-after', dirs_exist_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=SCRIPTS)
    parser.add_argument('chain')
    parser.add_argument('rpc')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    try:
        sys.exit(run(args.action, args.chain, args.rpc, args.dry_run))
    except (ValueError, RuntimeError, KeyError, OSError) as error:
        parser.exit(1, str(error) + '\n')

#!/usr/bin/env python3
"""Copy a complete run's public records; leave active configuration intact."""
import json
from pathlib import Path
import re
import shutil
import sys

name = sys.argv[1]
if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', name):
    raise ValueError('Use a simple snapshot name')
destination = Path('config') / ('chains.live-' + name)
if destination.exists():
    raise ValueError('Snapshot already exists')
records = Path('config/chains')
run = json.loads(Path('.active-run/run.json').read_text())
chains = ['sepolia', *run.get('l2Chains', [run['l2Chain']])]
files = [records / (c + '.json') for c in chains]
for chain, file in zip(chains, files):
    record = json.loads(file.read_text())
    if not record.get('deployed', {}).get('pool_operation_manager'):
        raise ValueError(f'Incomplete deployment: {file}')
    state_name = 'l1' if chain == 'sepolia' else chain if run.get('chainStateFiles') else 'l2'
    state = json.loads((Path('state') / (state_name + '.json')).read_text())
    for key, expected in [('poolOperationManager', record['deployed']['pool_operation_manager']),
                          ('wstETH', record['addresses']['token'])]:
        if str(state.get(key, '')).lower() != expected.lower():
            raise ValueError(f'State does not match {file}: {key}')
policy = Path('config/ccv-policy.json')
if policy.exists():
    json.loads(policy.read_text())
destination.mkdir()
for file in files:
    shutil.copy2(file, destination / file.name)
if policy.exists():
    shutil.copy2(policy, destination / policy.name)
shutil.copytree('state', destination / 'state')
print(f'Snapshotted all chains to {destination}; active records preserved')

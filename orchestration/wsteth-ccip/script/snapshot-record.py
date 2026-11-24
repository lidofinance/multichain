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
hub = run.get('l1Chain', 'sepolia')
chains = [hub, *run.get('l2Chains', [run['l2Chain']])]
files = [records / (c + '.json') for c in chains]
# Lanes the hub took over from an existing pool: their records (written by the inventory step) travel
# with the snapshot, since the hub's lane tables are verified against them.
imported = list((json.loads(files[0].read_text()).get('imported_lanes') or {}).keys())
imported_files = [records / (c + '.json') for c in imported if (records / (c + '.json')).is_file()]
for chain, file in zip(chains, files):
    record = json.loads(file.read_text())
    deployed = record.get('deployed', {})
    if not deployed.get('timelock') or not deployed.get('call_proxy') or not deployed.get('token_pool'):
        raise ValueError(f'Incomplete deployment: {file}')
    state_name = 'l1' if chain == hub else chain if run.get('chainStateFiles') else 'l2'
    state = json.loads((Path('state') / (state_name + '.json')).read_text())
    # The state pins the identities step 04 took from the CREATE records; they must name this record.
    for key, expected in [('timelock', deployed['timelock']), ('callProxy', deployed['call_proxy']),
                          ('wstETH', deployed.get('token') or record['addresses']['token'])]:
        if str(state.get(key, '')).lower() != expected.lower():
            raise ValueError(f'State does not match {file}: {key}')
policy = Path('config/ccv-policy.json')
if policy.exists():
    json.loads(policy.read_text())
destination.mkdir()
for file in [*files, *imported_files]:
    shutil.copy2(file, destination / file.name)
if policy.exists():
    shutil.copy2(policy, destination / policy.name)
shutil.copytree('state', destination / 'state')
print(f'Snapshotted all chains to {destination}; active records preserved')

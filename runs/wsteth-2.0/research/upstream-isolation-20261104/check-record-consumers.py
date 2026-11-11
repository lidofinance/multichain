"""Offline acceptance of actual new/historical archives; no RPC or transactions."""
import json, os, shutil, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
ops = root / 'orchestration/wsteth-ccip'
evidence = root / 'runs/wsteth-2.0/research/upstream-isolation-20261104/record-consumers'
evidence.mkdir(parents=True, exist_ok=True)
specs = json.loads(Path(sys.argv[2]).read_text())
results = {}
def read(path): return json.loads(path.read_text())
def call(args, **kwargs): subprocess.run(args, check=True, **kwargs)
for label, spec in specs.items():
    source = Path(spec['source']).resolve()
    dest = evidence / label / 'chains'
    dest.mkdir(parents=True)
    for p in source.glob('*.json'): shutil.copy2(p, dest / p.name)
    state = source / 'state' if (source / 'state').is_dir() else source.parent / 'state'
    shutil.copytree(state, dest.parent / 'state')
    run_id = 'isolation-record-' + label
    call(['python3', str(ops / 'workspace.py'), 'prepare', spec['target'], run_id, 'fork', '--record', str(dest.relative_to(root))], cwd=root)
    workspace = root / 'runs/wsteth-2.0/workspaces' / run_id
    imported = workspace / 'config/chains'
    for p in dest.glob('*.json'):
        target = workspace / 'config/ccv-policy.json' if p.name == 'ccv-policy.json' else imported / p.name
        assert read(p) == read(target), (label, p.name, 'changed on import')
    info = read(workspace / 'run.json')
    for leaf in info['l2Chains']:
        output = evidence / label / (leaf + '.yaml')
        call(['node', str(ops / 'script/render-multichain-state.cjs'), str(workspace / 'config/state-mate/wsteth.yaml'), str(imported), str(workspace / 'config/ccv-policy.json'), leaf, str(output), str(workspace / 'state' / (leaf + '.json'))], cwd=ops, env=dict(os.environ, L1_CHAIN=info['l1Chain']))
        assert output.is_file() and Path(str(output) + '.tables.json').is_file()
    call(['python3', 'script/snapshot-record.py', label], cwd=ops)
    snapshot = workspace / 'config' / ('chains.live-' + label)
    for p in dest.glob('*.json'): assert read(p) == read(snapshot / p.name), (label, p.name, 'changed on snapshot')
    call(['python3', str(ops / 'workspace.py'), 'prepare', spec['target'], run_id + '-roundtrip', 'fork', '--record', str(snapshot.relative_to(root))], cwd=root)
    again = root / 'runs/wsteth-2.0/workspaces' / (run_id + '-roundtrip')
    for p in dest.glob('*.json'):
        target = again / ('config/ccv-policy.json' if p.name == 'ccv-policy.json' else 'config/chains/' + p.name)
        assert read(p) == read(target), (label, p.name, 'changed on roundtrip')
    hub = read(dest / (info['l1Chain'] + '.json'))
    results[label] = {'status': 'passed', 'source': str(source), 'importedLanes': sorted(hub.get('imported_lanes', {})), 'deferredLanes': hub.get('deferred_lanes'), 'checks': ['archive import', 'complete records and policy equality', 'state-mate projection', 'snapshot-record', 'snapshot re-import']}
(evidence / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps({name: r['status'] for name, r in results.items()}, indent=2))

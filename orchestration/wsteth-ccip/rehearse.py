#!/usr/bin/env python3
"""Run either migration line on fresh owned Anvil forks; archive evidence, then stop nodes."""
import argparse
from datetime import datetime, timezone
import json
import os
import re
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
OPS = ROOT / 'orchestration/wsteth-ccip'
sys.path.insert(0, str(OPS / 'script'))
import ccip_api
from rehearsal_checks import check_full
from scratch_checks import check_scratch
import workspace as workspace_module


def rpc(url, method, params=None):
    req = urllib.request.Request(url, json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params or []}).encode(),
                                 {'Content-Type':'application/json', 'User-Agent':'curl/8.7.1'})
    with urllib.request.urlopen(req, timeout=60) as response:
        data = json.load(response)
    if 'error' in data:
        raise RuntimeError(f'RPC {method} failed')
    return data['result']


def pinned_block(remote, chain_id, pin=None):
    if int(rpc(remote, 'eth_chainId'), 16) != chain_id:
        raise ValueError('Upstream chain ID mismatch')
    if pin is not None and pin['chainId'] != chain_id:
        raise ValueError('Saved pin chain ID mismatch')
    tag = hex(pin['block']) if pin is not None else 'latest'
    block = rpc(remote, 'eth_getBlockByNumber', [tag, False])
    if not block or (pin is not None and (block['hash'].lower() != pin['blockHash'].lower()
                                          or int(block['number'], 16) != pin['block'])):
        raise ValueError('Pinned block unavailable or block hash changed; no latest fallback')
    return block


def verify_ccip_addresses(url, chain_id, api):
    for environment in ('testnet', 'mainnet'):
        entry = json.loads((api / f'{environment}-chainId.json').read_text())['data']['evm'].get(str(chain_id))
        if entry:
            addresses = {key: entry[key] for key in ('router', 'rmn', 'tokenAdminRegistry', 'registryModule')}
            for key, address in addresses.items():
                if rpc(url, 'eth_getCode', [address, 'latest']) in ('0x', '0x0'):
                    raise ValueError(f'Captured CCIP {key} has no code on chain {chain_id} at the selected block')
            return addresses
    raise ValueError(f'Chain {chain_id} is missing from captured CCIP discovery')


def run_line(line, run_id, inputs=None, capture_only=False, through=None):
    env = dict(os.environ)
    # Use the public deployment entry gate before starting forks or capturing inputs.
    workspace_module.check_pipeline_environment(env, OPS / '.env')
    env.pop('L2_CHAIN', None)
    for key in ['L1_RPC','L2_RPC','RECORD_DIR','WSTETH_SKIP_L1','HUB_CHECKPOINT','FOUNDRY_PROFILE']:
        env.pop(key, None)
    target = 'wsteth-ccip-sepolia-mantle-dev' if line == 'scratch' else 'wsteth-base-migration-' + line
    definition = json.loads((ROOT / 'targets' / target / 'target.json').read_text())
    chains = [(n['slug'], n['chainId'], 'RPC_'+n['slug'].upper())
              for n in [definition['networks']['l1'], *definition['networks']['l2s']]]
    for lane in definition.get('bootstrap', {}).get('lanes', []):
        chains.append((lane['slug'], lane['chain']['chainId'], lane['rpcEnv']))
    evidence = ROOT / 'runs/wsteth-2.0/rehearsals' / run_id
    evidence.mkdir(parents=True, exist_ok=False)
    saved = json.loads((inputs / line / 'forks.json').read_text()) if inputs else None
    if saved is not None and set(saved) != {slug for slug, _, _ in chains}:
        raise ValueError('Saved pins must cover exactly the target networks')
    nodes, handles, pins = [], [], {}
    result = {'line':line, 'runId':run_id, 'status':'running', 'startedAt':datetime.now(timezone.utc).isoformat()}
    try:
        api = evidence / 'api'
        if inputs:
            ccip_api.verify(inputs / 'api')
            shutil.copytree(inputs / 'api', api)
        else:
            ccip_api.capture(api)
        adapter = evidence / 'bin'
        adapter.mkdir()
        shutil.copy2(OPS / 'script/ccip_api.py', adapter / 'curl')
        (adapter / 'curl').chmod(0o755)
        env['WSTETH_REAL_CURL'] = shutil.which('curl')
        env['WSTETH_CCIP_API_DIR'] = str(api)
        env['PATH'] = str(adapter) + os.pathsep + env['PATH']
        for slug, chain_id, rpc_name in chains:
            remote = env.get(rpc_name+'_REMOTE')
            if not remote and slug == 'monad':
                remote = 'https://testnet-rpc.monad.xyz'
            if not remote:
                raise ValueError('Set '+rpc_name+'_REMOTE')
            block = pinned_block(remote, chain_id, saved[slug] if saved else None)
            if capture_only:
                pins[slug] = {'chainId': chain_id, 'block': int(block['number'], 16),
                              'blockHash': block['hash'], 'rpcEnv': rpc_name}
                continue
            with socket.socket() as sock:
                sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
            handle=(evidence/(slug+'-anvil.log')).open('w');handles.append(handle)
            node=subprocess.Popen(['anvil','--host','127.0.0.1','--port',str(port),'--fork-url',remote,
                '--fork-block-number',str(int(block['number'],16)), '--gas-limit','120000000',
                '--disable-code-size-limit','--silent'],stdout=handle,stderr=subprocess.STDOUT)
            nodes.append(node);local='http://127.0.0.1:'+str(port)
            for _ in range(120):
                if node.poll() is not None:
                    raise RuntimeError(slug+': Anvil exited; inspect its local log')
                try:
                    if int(rpc(local,'eth_chainId'),16)==chain_id:break
                except (OSError, RuntimeError):pass
                time.sleep(.25)
            else:raise RuntimeError(slug+': fork startup timed out')
            env[rpc_name]=local
            pins[slug]={'chainId':chain_id,'block':int(block['number'],16),'blockHash':block['hash'],
                        'rpcEnv':rpc_name,'localRpc':local}
            pins[slug]['ccipAddressesChecked'] = verify_ccip_addresses(local, chain_id, api)
            print(f'{line}: {slug} fork at {pins[slug]["block"]}',flush=True)
        (evidence/'forks.json').write_text(json.dumps(pins,indent=2)+'\n')
        if capture_only:
            result.update(status='captured', exitCode=0)
            return
        subprocess.run(['python3',str(OPS/'workspace.py'),'prepare',target,run_id,'fork'],cwd=ROOT,env=env,check=True)
        workspace=ROOT/'runs/wsteth-2.0/workspaces'/run_id
        shutil.copytree(api, workspace / 'inputs/ccip-api')
        # Bind the external input snapshot before executing the first workspace step.
        run_data = workspace_module.read_json(workspace / 'run.json')
        run_data['inputHashes'] = workspace_module.hashes(workspace / 'inputs')
        workspace_module.write_json(workspace / 'run.json', run_data)
        env['WSTETH_CCIP_API_DIR'] = str(workspace / 'inputs/ccip-api')
        (workspace/'state/forks.json').write_text(json.dumps(pins,indent=2)+'\n')
        log_path=evidence/'pipeline.log'
        print(f'{line}: running full pipeline; log {log_path.relative_to(ROOT)}',flush=True)
        with log_path.open('w') as output:
            recipes = ['all']
            if through:
                pipeline = (workspace_module.PIPELINES['all'] if line == 'scratch' else
                            workspace_module.SEPOLIA_MIGRATION_PIPELINE if line == 'sepolia' else
                            workspace_module.HUB_MIGRATION_PIPELINE)
                if through not in pipeline:
                    raise ValueError('Unknown checkpoint: ' + through)
                recipes = pipeline[:pipeline.index(through) + 1]
                result['through'] = through
            for recipe in recipes:
                proc=subprocess.run(['python3',str(OPS/'workspace.py'),'run',recipe],cwd=ROOT,env=env,
                                    stdout=output,stderr=subprocess.STDOUT)
                if proc.returncode:
                    break
        result.update(status='passed' if proc.returncode==0 else 'failed',exitCode=proc.returncode)
        if proc.returncode:
            raise RuntimeError(f'{line} pipeline failed; inspect {log_path}')
        if not through and line != 'scratch':
            result['checks'] = check_full(workspace, line)
        if line == 'scratch' and through in (None, 'set-pool-gov'):
            # The readback helper receives only this run's local endpoints.
            original = dict(os.environ)
            try:
                os.environ.update({k: v for k, v in env.items() if k.startswith('RPC_') and not k.endswith('_REMOTE')})
                result['checks'] = check_scratch(workspace, definition)
            finally:
                os.environ.clear()
                os.environ.update(original)
        result['scope'] = 'through ' + through if through else 'full pipeline'
        print(f'{line}: {result["scope"]} passed',flush=True)
    except BaseException:
        result['status']='failed'
        raise
    finally:
        result['finishedAt']=datetime.now(timezone.utc).isoformat()
        (evidence/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        for node in nodes:
            node.terminate()
        for node in nodes:
            try:node.wait(timeout=10)
            except subprocess.TimeoutExpired:node.kill();node.wait()
        for handle in handles:handle.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('line',choices=['mainnet','sepolia','both','scratch'])
    parser.add_argument('run_id',nargs='?',default=datetime.now(timezone.utc).strftime('rehearsal-%Y%m%d-%H%M%S'))
    parser.add_argument('--inputs', type=Path, help='Replay DIR/{mainnet,sepolia}/forks.json and DIR/api')
    parser.add_argument('--capture-only', action='store_true', help='Save pins/API without deploying')
    parser.add_argument('--through', help='Development probe: stop after the named pipeline recipe')
    args=parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', args.run_id):
        parser.error('Use a simple run ID')
    for line in (['mainnet','sepolia'] if args.line=='both' else [args.line]):
        run_line(line,args.run_id+'-'+line if args.line=='both' else args.run_id,
                 args.inputs.resolve() if args.inputs else None, args.capture_only, args.through)


if __name__=='__main__':
    main()

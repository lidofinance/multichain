#!/usr/bin/env python3
"""Run either migration line on fresh owned Anvil forks; archive evidence, then stop nodes."""
import argparse
from datetime import datetime, timezone
import json
import os
import re
from pathlib import Path
import socket
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
OPS = ROOT / 'orchestration/wsteth-ccip'


def rpc(url, method, params=None):
    req = urllib.request.Request(url, json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params or []}).encode(),
                                 {'Content-Type':'application/json', 'User-Agent':'curl/8.7.1'})
    with urllib.request.urlopen(req, timeout=60) as response:
        data = json.load(response)
    if 'error' in data:
        raise RuntimeError(f'RPC {method} failed')
    return data['result']


def run_line(line, run_id):
    env = dict(os.environ)
    env.pop('L2_CHAIN', None)
    for key in ['L1_RPC','L2_RPC','RECORD_DIR','WSTETH_SKIP_L1','HUB_CHECKPOINT','FOUNDRY_PROFILE']:
        env.pop(key, None)
    target = 'wsteth-base-migration-' + line
    definition = json.loads((ROOT / 'targets' / target / 'target.json').read_text())
    chains = [(n['slug'], n['chainId'], 'RPC_'+n['slug'].upper())
              for n in [definition['networks']['l1'], *definition['networks']['l2s']]]
    for lane in definition.get('bootstrap', {}).get('lanes', []):
        chains.append((lane['slug'], lane['chain']['chainId'], lane['rpcEnv']))
    evidence = ROOT / 'runs/wsteth-2.0/rehearsals' / run_id
    evidence.mkdir(parents=True, exist_ok=False)
    nodes, handles, pins = [], [], {}
    result = {'line':line, 'runId':run_id, 'status':'running', 'startedAt':datetime.now(timezone.utc).isoformat()}
    try:
        for slug, chain_id, rpc_name in chains:
            remote = env.get(rpc_name+'_REMOTE')
            if not remote and slug == 'monad':
                remote = 'https://testnet-rpc.monad.xyz'
            if not remote:
                raise ValueError('Set '+rpc_name+'_REMOTE')
            if int(rpc(remote, 'eth_chainId'),16) != chain_id:
                raise ValueError(slug + ': upstream chain ID mismatch')
            block = rpc(remote,'eth_getBlockByNumber',['latest',False])
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
            print(f'{line}: {slug} fork at {pins[slug]["block"]}',flush=True)
        (evidence/'forks.json').write_text(json.dumps(pins,indent=2)+'\n')
        subprocess.run(['python3',str(OPS/'workspace.py'),'prepare',target,run_id,'fork'],cwd=ROOT,env=env,check=True)
        workspace=ROOT/'runs/wsteth-2.0/workspaces'/run_id
        (workspace/'state/forks.json').write_text(json.dumps(pins,indent=2)+'\n')
        log_path=evidence/'pipeline.log'
        print(f'{line}: running full pipeline; log {log_path.relative_to(ROOT)}',flush=True)
        with log_path.open('w') as output:
            proc=subprocess.run(['python3',str(OPS/'workspace.py'),'run','all'],cwd=ROOT,env=env,
                                stdout=output,stderr=subprocess.STDOUT)
        result.update(status='passed' if proc.returncode==0 else 'failed',exitCode=proc.returncode)
        if proc.returncode:
            raise RuntimeError(f'{line} pipeline failed; inspect {log_path}')
        print(f'{line}: full migration pipeline passed',flush=True)
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
    parser.add_argument('line',choices=['mainnet','sepolia','both'])
    parser.add_argument('run_id',nargs='?',default=datetime.now(timezone.utc).strftime('rehearsal-%Y%m%d-%H%M%S'))
    args=parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', args.run_id):
        parser.error('Use a simple run ID')
    for line in (['mainnet','sepolia'] if args.line=='both' else [args.line]):
        run_line(line,args.run_id+'-'+line if args.line=='both' else args.run_id)


if __name__=='__main__':
    main()

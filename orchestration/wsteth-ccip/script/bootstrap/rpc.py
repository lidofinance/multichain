"""Local fork operations for the Sepolia baseline. Never signs public transactions."""
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[4]
OPS = ROOT / 'orchestration/wsteth-ccip'
ZERO = '0x' + '0' * 40
TXS = []


class RpcError(RuntimeError):
    def __init__(self, slug, method, error):
        self.error = error
        super().__init__(f'{slug} {method}: RPC error {error.get("code")}')


def read(path):
    return json.loads(Path(path).read_text())


def write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(data, indent=2) + '\n')
    tmp.replace(path)


def cast(*args):
    result = subprocess.run(['cast', *map(str, args)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('cast ' + str(args[0]) + ' failed: ' + result.stderr[-1500:])
    return result.stdout.strip()


def encode(signature, *args):
    return cast('calldata', signature, *args)


def decoded(signature, data):
    result = json.loads(cast('decode-abi', '--json', signature, data))
    return result['data'] if isinstance(result, dict) else result


class Fork:
    def __init__(self, slug, url, chain_id):
        if urlparse(url).hostname not in ('127.0.0.1', 'localhost', '::1'):
            raise ValueError(f'{slug}: bootstrap only accepts loopback fork RPCs')
        self.slug, self.url = slug, url
        if 'anvil' not in self.rpc('web3_clientVersion').lower():
            raise ValueError(f'{slug}: bootstrap requires Anvil')
        if int(self.rpc('eth_chainId'), 16) != chain_id:
            raise ValueError(f'{slug}: wrong chain ID')
        self.block = self.rpc('eth_getBlockByNumber', 'latest', False)

    def rpc(self, method, *params):
        body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
        request = urllib.request.Request(self.url, body, {'Content-Type': 'application/json', 'User-Agent': 'curl/8.7.1'})
        with urllib.request.urlopen(request, timeout=180) as response:
            result = json.load(response)
        if 'error' in result:
            raise RpcError(self.slug, method, result['error'])
        return result['result']

    def call(self, address, signature, *args):
        # cast's combined signature separates inputs from returned values.
        start = signature.index('(')
        depth = 0
        end = start
        for end in range(start, len(signature)):
            depth += (signature[end] == '(') - (signature[end] == ')')
            if depth == 0:
                break
        data = self.rpc('eth_call', {'to': address, 'data': encode(signature[:end+1], *args)}, 'latest')
        return decoded('x()' + signature[end+1:], data)[0]

    def send(self, sender, address=None, signature=None, *args, data=None, value=0):
        self.rpc('anvil_setBalance', sender, hex(10**25))
        self.rpc('anvil_impersonateAccount', sender)
        try:
            tx = {'from': sender, 'data': data if data is not None else encode(signature, *args),
                  'value': hex(value), 'gas': hex(30_000_000)}
            if address:
                tx['to'] = address
            tx_hash = self.rpc('eth_sendTransaction', tx)
            for _ in range(120):
                receipt = self.rpc('eth_getTransactionReceipt', tx_hash)
                if receipt:
                    break
                time.sleep(.1)
            if not receipt or int(receipt['status'], 16) != 1:
                raise RuntimeError(f'{self.slug}: transaction failed {tx_hash} ({signature or "CREATE"})')
            TXS.append({'chain': self.slug, 'hash': tx_hash, 'sender': sender,
                        'target': address, 'action': signature or 'CREATE', 'block': int(receipt['blockNumber'], 16)})
            return receipt
        finally:
            self.rpc('anvil_stopImpersonatingAccount', sender)

    def deploy(self, sender, artifact, signature='constructor()', *args):
        artifact = read(artifact)
        code = artifact['bytecode']
        if isinstance(code, dict):
            code = code['object']
        data = '0x' + code.removeprefix('0x') + cast('abi-encode', signature, *args)[2:]
        return self.send(sender, data=data)['contractAddress']


def inputs():
    if os.environ.get('WSTETH_BOOTSTRAP') != 'sepolia-migration' or os.environ.get('WSTETH_RUN_ENVIRONMENT') != 'fork':
        raise ValueError('Use the Sepolia migration fork target through workspace.py')
    target = read(Path(os.environ['WSTETH_TARGET_DIR']) / 'target.json')
    forks = {}
    for n in [target['networks']['l1'], *target['networks']['l2s']]:
        forks[n['slug']] = Fork(n['slug'], os.environ['RPC_' + n['slug'].upper()], n['chainId'])
    for lane in target['bootstrap']['lanes']:
        forks[lane['slug']] = Fork(lane['slug'], os.environ[lane['rpcEnv']], lane['chain']['chainId'])
    return target, forks

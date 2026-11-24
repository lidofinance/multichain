#!/usr/bin/env python3
"""Legacy wstETH bridge transfers in flight between Ethereum and an OP-stack chain (Base).

A transfer is in flight when the source chain recorded its message and the destination chain
has not recorded a successful relay. The script finds every message the two bridge proxies sent
each other through the canonical messengers, then reads the destination contracts for each one
that is not delivered and reports which step it is waiting for.

    just legacy-inflight                      # RPC_ETHEREUM / RPC_BASE
    just legacy-inflight --json               # machine-readable, with replay calldata
    just legacy-inflight --expect-empty       # exit 2 when anything is in flight

Read-only: it sends no transactions and needs no key. Standard library only.
README.md in this directory says what each status is established by and what it leaves open.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TARGET = ROOT / 'targets/wsteth-base-migration-mainnet/target.json'
DEFAULT_CACHE_DIR = ROOT / '.workspace/legacy-bridge-inflight'
CACHE_VERSION = 1

# ── keccak-256 ────────────────────────────────────────────────────────────────────────────────
# hashlib has SHA3-256, whose padding differs from Ethereum's keccak-256.
_MASK = (1 << 64) - 1
_ROUND_CONSTANTS = (
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
)
_ROTATIONS = ((0, 36, 3, 41, 18), (1, 44, 10, 45, 2), (62, 6, 43, 15, 61),
              (28, 55, 25, 21, 56), (27, 20, 39, 8, 14))  # [x][y]


def _keccak_f(a):
    for constant in _ROUND_CONSTANTS:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[x - 1] ^ (((c[(x + 1) % 5] << 1) | (c[(x + 1) % 5] >> 63)) & _MASK) for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                value, shift = a[x][y] ^ d[x], _ROTATIONS[x][y]
                b[y][(2 * x + 3 * y) % 5] = ((value << shift) | (value >> (64 - shift))) & _MASK
        a = [[b[x][y] ^ (~b[(x + 1) % 5][y] & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= constant
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    padded = bytearray(data)
    padded.append(0x01)
    padded.extend(bytes(-len(padded) % rate))
    padded[-1] |= 0x80
    state = [[0] * 5 for _ in range(5)]
    for offset in range(0, len(padded), rate):
        for i in range(rate // 8):
            state[i % 5][i // 5] ^= int.from_bytes(padded[offset + 8 * i:offset + 8 * i + 8], 'little')
        state = _keccak_f(state)
    return b''.join(state[i % 5][i // 5].to_bytes(8, 'little') for i in range(4))


# ── ABI and RLP, only the shapes these contracts use ──────────────────────────────────────────
def unhex(value: str) -> bytes:
    return bytes.fromhex(value[2:] if value.startswith('0x') else value)


def tohex(value: bytes) -> str:
    return '0x' + value.hex()


def word(value: int) -> bytes:
    return value.to_bytes(32, 'big')


def word_at(data: bytes, index: int) -> int:
    return int.from_bytes(data[32 * index:32 * index + 32], 'big')


def bytes_at(data: bytes, offset: int) -> bytes:
    length = int.from_bytes(data[offset:offset + 32], 'big')
    if offset + 32 + length > len(data):
        raise ValueError('ABI bytes value runs past the end of the data')
    return data[offset + 32:offset + 32 + length]


def encode_static_then_bytes(static: list[int], tail: bytes) -> bytes:
    """abi.encode(static..., bytes): the argument shape of relayMessage and of a withdrawal."""
    head = b''.join(word(v) for v in static) + word(32 * (len(static) + 1))
    return head + word(len(tail)) + tail + bytes(-len(tail) % 32)


def selector(signature: str) -> bytes:
    return keccak256(signature.encode())[:4]


def topic(signature: str) -> str:
    return tohex(keccak256(signature.encode()))


def address(value) -> str:
    """EIP-55 form of an address given as an integer, a 20-byte hex string or a 32-byte word."""
    if isinstance(value, str):
        value = int(value, 16)
    lower = f'{value & ((1 << 160) - 1):040x}'
    digest = keccak256(lower.encode()).hex()
    return '0x' + ''.join(ch.upper() if int(digest[i], 16) >= 8 else ch for i, ch in enumerate(lower))


def rlp(item) -> bytes:
    if isinstance(item, list):
        payload = b''.join(rlp(x) for x in item)
        base = 0xC0
    else:
        payload, base = item, 0x80
        if len(payload) == 1 and payload[0] < 0x80:
            return payload
    if len(payload) < 56:
        return bytes([base + len(payload)]) + payload
    size = len(payload).to_bytes((len(payload).bit_length() + 7) // 8, 'big')
    return bytes([base + 55 + len(size)]) + size + payload


def rlp_uint(value: int) -> bytes:
    return value.to_bytes((value.bit_length() + 7) // 8, 'big')


RELAY_MESSAGE = selector('relayMessage(uint256,address,address,uint256,uint256,bytes)')
SENT_MESSAGE = topic('SentMessage(address,address,bytes,uint256,uint256)')
MESSAGE_PASSED = topic('MessagePassed(uint256,address,address,uint256,uint256,bytes,bytes32)')
TRANSACTION_DEPOSITED = topic('TransactionDeposited(address,address,uint256,bytes)')
FINALIZE_DEPOSIT = selector('finalizeDeposit(address,address,address,address,uint256,bytes)')
FINALIZE_WITHDRAWAL = selector('finalizeERC20Withdrawal(address,address,address,address,uint256,bytes)')
MESSAGE_PASSER = '0x4200000000000000000000000000000000000016'
ERROR_STRING = selector('Error(string)')
PORTAL_ERRORS = {tohex(selector(name + '()')): name for name in (
    'OptimismPortal_AlreadyFinalized', 'OptimismPortal_BadTarget', 'OptimismPortal_CallPaused',
    'OptimismPortal_GasEstimation', 'OptimismPortal_ImproperDisputeGame',
    'OptimismPortal_InvalidDisputeGame', 'OptimismPortal_InvalidProofTimestamp',
    'OptimismPortal_InvalidRootClaim', 'OptimismPortal_NoReentrancy',
    'OptimismPortal_ProofNotOldEnough', 'OptimismPortal_Unproven')}
BRIDGE_MODES = ('LEGACY', 'MIGRATING', 'CCIP_ONLY')
GAME_STATUSES = ('IN_PROGRESS', 'CHALLENGER_WINS', 'DEFENDER_WINS')
# AnchorStateRegistry views; a retired, blacklisted or unregistered game never validates a proof.
GAME_VERDICTS = {'registered': 'isGameRegistered(address)', 'retired': 'isGameRetired(address)',
                 'blacklisted': 'isGameBlacklisted(address)', 'resolved': 'isGameResolved(address)',
                 'finalized': 'isGameFinalized(address)', 'claimValid': 'isGameClaimValid(address)'}


def relay_calldata(nonce: int, sender: str, target: str, gas_limit: int, message: bytes) -> bytes:
    """Calldata of CrossDomainMessenger.relayMessage for a message sent with no ETH value.

    Its keccak-256 is the key of successfulMessages / failedMessages on the destination messenger,
    whatever the nonce version, and the same bytes replay a failed message.
    """
    return RELAY_MESSAGE + encode_static_then_bytes(
        [nonce, int(sender, 16), int(target, 16), 0, gas_limit], message)


def deposit_transaction_hash(log: dict) -> str:
    """Hash of the Base transaction the sequencer derives from a TransactionDeposited log."""
    opaque = bytes_at(unhex(log['data']), 32)
    mint, value, gas = (int.from_bytes(opaque[0:32], 'big'), int.from_bytes(opaque[32:64], 'big'),
                        int.from_bytes(opaque[64:72], 'big'))
    is_creation, data = opaque[72] != 0, opaque[73:]
    inner = keccak256(unhex(log['blockHash']) + word(int(log['logIndex'], 16)))
    source_hash = keccak256(word(0) + inner)
    fields = [source_hash, unhex(log['topics'][1])[12:], b'' if is_creation else unhex(log['topics'][2])[12:],
              rlp_uint(mint), rlp_uint(value), rlp_uint(gas), b'', data]
    return tohex(keccak256(b'\x7e' + rlp(fields)))


# ── JSON-RPC ──────────────────────────────────────────────────────────────────────────────────
class RpcError(RuntimeError):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class Reverted:
    """An eth_call that the contract rejected; the rejection is an observation, not a failure."""

    def __init__(self, error: dict):
        data = error.get('data')
        self.data = data if isinstance(data, str) and data.startswith('0x') else '0x'
        self.message = str(error.get('message', ''))

    def reason(self) -> str:
        raw = unhex(self.data)
        if raw[:4] == ERROR_STRING and len(raw) >= 68:
            return bytes_at(raw[4:], 32).decode('utf-8', 'replace')
        if len(raw) >= 4:
            return PORTAL_ERRORS.get(tohex(raw[:4]), 'error ' + tohex(raw[:4]))
        return self.message or 'reverted without data'


def is_revert(error: dict) -> bool:
    return error.get('code') == 3 or 'revert' in str(error.get('message', '')).lower()


class Rpc:
    def __init__(self, name: str, url: str, batch_size: int = 50, attempts: int = 5):
        self.name, self.url, self.batch_size, self.attempts = name, url, batch_size, attempts
        self.requests = 0

    def _post(self, payload):
        body = json.dumps(payload).encode()
        last, status = None, None
        for attempt in range(self.attempts):
            if attempt:
                time.sleep(min(8.0, 0.5 * 2 ** attempt))
            request = urllib.request.Request(self.url, body, {
                'Content-Type': 'application/json', 'User-Agent': 'curl/8.7.1'})
            try:
                self.requests += 1
                with urllib.request.urlopen(request, timeout=120) as response:
                    return json.load(response)
            except urllib.error.HTTPError as error:
                last, status = f'HTTP {error.code}', error.code
                if error.code not in (408, 429) and error.code < 500:
                    break
            except (urllib.error.URLError, TimeoutError, ConnectionError, json.JSONDecodeError) as error:
                last, status = type(error).__name__, None
        # The endpoint URL can carry an access key, so it never appears in a message.
        raise RpcError(f'{self.name}: request failed ({last})', status)

    def batch(self, calls: list[tuple[str, list]]) -> list:
        """Results in call order. A reverted eth_call yields Reverted; other errors are retried."""
        results: list = [None] * len(calls)
        pending = list(range(len(calls)))
        for attempt in range(self.attempts):
            if attempt:
                time.sleep(min(8.0, 0.5 * 2 ** attempt))
            failed = []
            for start in range(0, len(pending), self.batch_size):
                chunk = pending[start:start + self.batch_size]
                payload = [{'jsonrpc': '2.0', 'id': i, 'method': calls[i][0], 'params': calls[i][1]}
                           for i in chunk]
                reply = self._post(payload if len(payload) > 1 else payload[0])
                if isinstance(reply, dict):
                    if len(chunk) > 1:  # the endpoint refused the batch as a whole
                        self.batch_size = 1
                        failed.extend(chunk)
                        continue
                    reply = [reply]
                seen = set()
                for item in reply:
                    i = item.get('id')
                    if i not in chunk:
                        continue
                    seen.add(i)
                    if 'error' in item:
                        if calls[i][0] == 'eth_call' and is_revert(item['error']):
                            results[i] = Reverted(item['error'])
                        else:
                            results[i] = RpcError(f'{self.name} {calls[i][0]}: {json.dumps(item["error"])[:300]}')
                            failed.append(i)
                    else:
                        results[i] = item.get('result')
                failed.extend(i for i in chunk if i not in seen)
            pending = failed
            if not pending:
                return results
        error = results[pending[0]]
        raise error if isinstance(error, RpcError) else RpcError(f'{self.name}: no reply to {calls[pending[0]][0]}')

    def request(self, method: str, *params):
        return self.batch([(method, list(params))])[0]

    def calls(self, items: list[tuple[str, bytes]], block: int) -> list:
        """eth_call each (address, calldata) at one block; values are bytes or Reverted."""
        replies = self.batch([('eth_call', [{'to': to, 'data': tohex(data)}, hex(block)]) for to, data in items])
        return [r if isinstance(r, Reverted) else unhex(r) for r in replies]

    def call(self, to: str, data: bytes, block: int):
        return self.calls([(to, data)], block)[0]

    def views(self, items: list[tuple[str, bytes]], block: int) -> list[bytes]:
        """Like calls, for views that must answer: a rejection stops the run."""
        replies = self.calls(items, block)
        for (to, data), reply in zip(items, replies):
            if isinstance(reply, Reverted) or len(reply) < 32:
                raise RpcError(f'{self.name}: {to} did not answer the view {tohex(data[:4])}')
        return replies

    def logs(self, contract: str, topics: list, start: int, end: int, label: str = '') -> list[dict]:
        """eth_getLogs over [start, end], narrowing the block span until the endpoint accepts it."""
        found, cursor, span, minimum, streak = [], start, end - start + 1, 500, 0
        while cursor <= end:
            stop = min(end, cursor + span - 1)
            query = {'address': contract, 'topics': topics, 'fromBlock': hex(cursor), 'toBlock': hex(stop)}
            try:
                reply = self._post({'jsonrpc': '2.0', 'id': 1, 'method': 'eth_getLogs', 'params': [query]})
            except RpcError as error:  # some endpoints refuse a wide range with HTTP 400 or 413
                if error.status not in (400, 413):
                    raise
                reply = {'error': {'message': str(error)}}
            if 'error' in reply:
                if span <= minimum:
                    raise RpcError(f'{self.name} eth_getLogs: {json.dumps(reply["error"])[:300]}')
                span, streak = max(minimum, span // 2), 0
                continue
            found.extend(log for log in reply['result'] if not log.get('removed'))
            cursor, streak = stop + 1, streak + 1
            if streak >= 20:
                span, streak = span * 2, 0
            if label and stop < end and sys.stderr.isatty():
                done = (cursor - start) / (end - start + 1)
                print(f'\r  {label}: {done:6.1%} of the block range', end='', file=sys.stderr)
        if label and sys.stderr.isatty():
            print('\r' + ' ' * 70 + '\r', end='', file=sys.stderr)
        return found


class Chain:
    """One chain read at a pinned head, so every answer in a run describes the same state."""

    def __init__(self, name: str, url: str, chain_id: int):
        self.name, self.rpc = name, Rpc(name, url)
        actual = int(self.rpc.request('eth_chainId'), 16)
        if actual != chain_id:
            raise SystemExit(f'✗ {name}: the endpoint serves chain {actual}, expected {chain_id}')
        self.chain_id = chain_id
        try:
            client = str(self.rpc.request('web3_clientVersion'))
        except RpcError:
            client = ''
        self.fork = any(tag in client.lower() for tag in ('anvil', 'hardhat', 'ganache', 'tenderly'))
        head = self.rpc.request('eth_getBlockByNumber', 'latest', False)
        self.block, self.timestamp = int(head['number'], 16), int(head['timestamp'], 16)
        try:
            final = self.rpc.request('eth_getBlockByNumber', 'finalized', False)
            self.final = min(self.block, int(final['number'], 16)) if final else None
        except RpcError:
            self.final = None

    def read(self, to: str, signature: str, *args: int, block: int | None = None):
        return self.rpc.call(to, selector(signature) + b''.join(word(a) for a in args),
                             self.block if block is None else block)

    def creation_block(self, contract: str) -> int:
        """First block at which the contract has code; 0 when the endpoint keeps no history."""
        low, high = 0, self.block
        try:
            while low < high:
                middle = (low + high) // 2
                if self.rpc.request('eth_getCode', contract, hex(middle)) in ('0x', None):
                    low = middle + 1
                else:
                    high = middle
        except RpcError:
            return 0
        return low

    def timestamps(self, blocks: set[int]) -> dict[int, int]:
        ordered = sorted(blocks)
        replies = self.rpc.batch([('eth_getBlockByNumber', [hex(b), False]) for b in ordered])
        return {b: int(r['timestamp'], 16) for b, r in zip(ordered, replies) if r}


# ── configuration ─────────────────────────────────────────────────────────────────────────────
def load_config(args) -> dict:
    target = json.loads(Path(args.target).read_text())
    migration, networks = target['migration'], target['networks']
    slug = args.l2 or networks['l2s'][0]['slug']
    l2_net = next((n for n in networks['l2s'] if n['slug'] == slug), None)
    l2 = next((n for n in migration['l2s'] if n['slug'] == slug), None)
    if not l2_net or not l2:
        raise SystemExit(f'✗ {args.target} has no L2 "{slug}"')
    l1_slug = networks['l1']['slug']

    def endpoint(flag, network):
        variable = 'RPC_' + network.upper().replace('-', '_')
        url = flag or os.environ.get(variable)
        if not url:
            raise SystemExit(f'✗ no endpoint for {network}: pass --{"l1" if network == l1_slug else "l2"}-rpc or set {variable}')
        return url

    return {
        'l1': {'name': l1_slug, 'chainId': networks['l1']['chainId'], 'url': endpoint(args.l1_rpc, l1_slug),
               'token': address(migration['l1']['token']), 'bridge': address(migration['l1']['bridgeProxy']),
               'messenger': address(migration['l1']['messenger'])},
        'l2': {'name': slug, 'chainId': l2_net['chainId'], 'url': endpoint(args.l2_rpc, slug),
               'token': address(l2['token']), 'bridge': address(l2['bridgeProxy']),
               'messenger': address(l2['messenger'])},
    }


# ── finding the messages ──────────────────────────────────────────────────────────────────────
def decode_sent_message(log: dict) -> dict:
    data = unhex(log['data'])
    return {'tx': log['transactionHash'], 'block': int(log['blockNumber'], 16),
            'logIndex': int(log['logIndex'], 16), 'sender': address(word_at(data, 0)),
            'message': tohex(bytes_at(data, word_at(data, 1))),
            'nonce': str(word_at(data, 2)), 'gasLimit': word_at(data, 3)}


def collect(source: Chain, messenger: str, sender: str, recipient: str, cached: dict | None,
            start: int | None, label: str) -> dict:
    """Every message `sender` sent to `recipient` through `messenger`, up to the pinned head.

    Messages in source-final blocks are kept for the next run; later ones are read again.
    """
    state = cached or {'from': source.creation_block(sender) if start is None else start,
                       'scannedTo': None, 'foreign': 0, 'messages': []}
    first = state['from'] if state['scannedTo'] is None else state['scannedTo'] + 1
    keep_to = source.final if source.final is not None else -1
    fresh, foreign_recent = [], 0
    if first <= source.block:
        target_topic = tohex(word(int(recipient, 16)))
        for log in source.rpc.logs(messenger, [SENT_MESSAGE, target_topic], first, source.block, label):
            record = decode_sent_message(log)
            if record['sender'] != sender:  # the bridge accepts messages from its counterpart only
                if record['block'] <= keep_to:
                    state['foreign'] += 1
                else:
                    foreign_recent += 1
                continue
            del record['sender']
            calldata = relay_calldata(int(record['nonce']), sender, recipient, record['gasLimit'],
                                      unhex(record['message']))
            record['hash'] = tohex(keccak256(calldata))
            fresh.append(record)
    state['messages'].extend(m for m in fresh if m['block'] <= keep_to)
    if keep_to >= first:
        state['scannedTo'] = keep_to
    recent = [dict(m, sourceFinal=False) for m in fresh if m['block'] > keep_to]
    return {'state': state, 'messages': state['messages'] + recent,
            'foreign': state['foreign'] + foreign_recent, 'range': (state['from'], source.block)}


def settle(messages: list[dict], destination: Chain, messenger: str) -> list[dict]:
    """Mark delivered messages; return the undelivered ones with their failedMessages flag.

    A delivery in a destination-final block is permanent and is remembered on the record
    (`delivered`); a delivery seen only at the head is reported and read again next time.
    """
    successful, failed = selector('successfulMessages(bytes32)'), selector('failedMessages(bytes32)')
    open_ = [m for m in messages if not m.get('delivered')]
    if destination.final is not None and open_:
        replies = destination.rpc.calls([(messenger, successful + unhex(m['hash'])) for m in open_],
                                        destination.final)
        for message, reply in zip(open_, replies):
            if not isinstance(reply, Reverted) and word_at(reply, 0):
                message['delivered'] = True
        open_ = [m for m in open_ if not m.get('delivered')]
    replies = destination.rpc.calls(
        [(messenger, fn + unhex(m['hash'])) for m in open_ for fn in (successful, failed)], destination.block)
    undelivered = []
    for i, message in enumerate(open_):
        done, broken = replies[2 * i], replies[2 * i + 1]
        if not isinstance(done, Reverted) and word_at(done, 0):
            message['deliveredAtHead'] = True
            continue
        undelivered.append(dict(message, relayFailed=not isinstance(broken, Reverted) and bool(word_at(broken, 0))))
    return undelivered


def describe(message: dict, direction: str) -> dict:
    """The transfer a bridge message carries; a message with another selector is a control message."""
    raw = unhex(message['message'])
    expected = FINALIZE_DEPOSIT if direction == 'deposit' else FINALIZE_WITHDRAWAL
    item = {'direction': direction, 'sourceTx': message['tx'], 'sourceBlock': message['block'],
            'sourceFinal': message.get('sourceFinal', True), 'nonce': message['nonce'],
            'gasLimit': message['gasLimit'], 'messageHash': message['hash'], 'message': message['message']}
    if raw[:4] == expected and len(raw) >= 4 + 32 * 6:
        body = raw[4:]
        item.update(kind='transfer', **{'from': address(word_at(body, 2)), 'to': address(word_at(body, 3)),
                                        'amount': str(word_at(body, 4))})
    else:
        item.update(kind='control', selector=tohex(raw[:4]))
    return item


# ── what each undelivered message is waiting for ──────────────────────────────────────────────
def resolve_deposits(items: list[dict], cfg: dict, l1: Chain, l2: Chain, portal: str) -> None:
    calldata = {id(i): relay_calldata(int(i['nonce']), cfg['l1']['bridge'], cfg['l2']['bridge'],
                                      i['gasLimit'], unhex(i['message'])) for i in items}
    waiting = [i for i in items if not i['relayFailed']]
    # The portal log that carries this message names the Base transaction the sequencer must include.
    receipts = l1.rpc.batch([('eth_getTransactionReceipt', [i['sourceTx']]) for i in waiting])
    derived = []
    for item, receipt in zip(waiting, receipts):
        for log in (receipt or {}).get('logs', []):
            if int(log['address'], 16) != int(portal, 16) or log['topics'][0] != TRANSACTION_DEPOSITED:
                continue
            if bytes_at(unhex(log['data']), 32)[73:] == calldata[id(item)]:
                item['l2Tx'] = deposit_transaction_hash(log)
                derived.append(item)
                break
    l2_receipts = l2.rpc.batch([('eth_getTransactionReceipt', [i['l2Tx']]) for i in derived])
    outcome = {id(i): r for i, r in zip(derived, l2_receipts)}
    for item in items:
        if item.pop('relayFailed'):
            item.update(status='RELAY_FAILED', relay={'chain': cfg['l2']['name'], 'to': cfg['l2']['messenger'],
                                                      'calldata': tohex(calldata[id(item)])},
                        next=f'anyone, {cfg["l2"]["name"]}: L2CrossDomainMessenger({cfg["l2"]["messenger"]})'
                             '.relayMessage(nonce, sender, target, 0, gasLimit, message)')
        elif 'l2Tx' not in item:
            item.update(status='UNKNOWN', note='no TransactionDeposited log for this message in the source '
                                               'transaction; the destination transaction could not be derived')
        elif outcome[id(item)] is None:
            item.update(status='AWAITING_L2_INCLUSION',
                        next=f'none: the sequencer includes transaction {item["l2Tx"]} on {cfg["l2"]["name"]}')
        elif int(outcome[id(item)]['status'], 16) == 0:
            item.update(status='L2_TX_FAILED', note='the derived destination transaction reverted before the '
                        'messenger recorded the message; relayMessage cannot replay it')
        else:
            item.update(status='UNKNOWN', note='the derived destination transaction succeeded but the '
                        'messenger records neither success nor failure for this message')


def latest_game(l1: Chain, portal: str) -> dict:
    """The newest dispute game of the type the portal respects, and the L2 block it claims."""
    try:
        factory = address(word_at(l1.read(portal, 'disputeGameFactory()'), 0))
        kind = word_at(l1.read(portal, 'respectedGameType()'), 0)
        count = word_at(l1.read(factory, 'gameCount()'), 0)
        indexes = list(range(count - 1, max(-1, count - 65), -1))
        entries = l1.rpc.calls([(factory, selector('gameAtIndex(uint256)') + word(i)) for i in indexes], l1.block)
        for index, entry in zip(indexes, entries):
            if isinstance(entry, Reverted) or word_at(entry, 0) != kind:
                continue
            game = address(word_at(entry, 2))
            for getter in ('l2SequenceNumber()', 'l2BlockNumber()'):
                number = l1.read(game, getter)
                if not isinstance(number, Reverted) and len(number) >= 32:
                    return {'index': index, 'game': game, 'gameType': kind, 'l2Block': word_at(number, 0),
                            'createdAt': word_at(entry, 1)}
            return {'error': f'game {game} exposes neither l2SequenceNumber() nor l2BlockNumber()'}
        return {'error': f'none of the last {len(indexes)} games has the respected type {kind}'}
    except (RpcError, AttributeError, TypeError, ValueError) as error:
        return {'error': f'dispute game lookup failed: {error}'}


def resolve_withdrawals(items: list[dict], cfg: dict, l1: Chain, l2: Chain, portal: str, maturity: int) -> dict | None:
    l1_name, messenger = cfg['l1']['name'], cfg['l1']['messenger']
    waiting = []
    for item in items:
        if item.pop('relayFailed'):
            item.update(status='RELAY_FAILED',
                        relay={'chain': l1_name, 'to': messenger, 'calldata': tohex(relay_calldata(
                            int(item['nonce']), cfg['l2']['bridge'], cfg['l1']['bridge'], item['gasLimit'],
                            unhex(item['message'])))},
                        next=f'anyone, {l1_name}: L1CrossDomainMessenger({messenger})'
                             '.relayMessage(nonce, sender, target, 0, gasLimit, message)')
        else:
            waiting.append(item)
    # The withdrawal the portal knows is the MessagePassed entry of the same Base transaction.
    receipts = l2.rpc.batch([('eth_getTransactionReceipt', [i['sourceTx']]) for i in waiting])
    known = []
    for item, receipt in zip(waiting, receipts):
        for log in (receipt or {}).get('logs', []):
            if int(log['address'], 16) != int(MESSAGE_PASSER, 16) or log['topics'][0] != MESSAGE_PASSED:
                continue
            data = unhex(log['data'])
            payload = bytes_at(data, word_at(data, 2))
            if tohex(keccak256(payload)) != item['messageHash']:
                continue
            tx = {'nonce': str(int(log['topics'][1], 16)), 'sender': address(log['topics'][2]),
                  'target': address(log['topics'][3]), 'value': str(word_at(data, 0)),
                  'gasLimit': str(word_at(data, 1)), 'data': tohex(payload)}
            computed = tohex(keccak256(encode_static_then_bytes(
                [int(tx['nonce']), int(tx['sender'], 16), int(tx['target'], 16), int(tx['value']),
                 int(tx['gasLimit'])], payload)))
            if computed == tohex(word(word_at(data, 3))):
                item.update(withdrawalHash=computed, withdrawalTx=tx)
                known.append(item)
            break
        if 'withdrawalHash' not in item:
            item.update(status='UNKNOWN', note='no matching MessagePassed log in the source transaction; '
                                               'the portal state of this withdrawal could not be read')
    if not known:
        return None
    flags = l1.rpc.views([(portal, selector(fn) + unhex(i['withdrawalHash'])) for i in known
                          for fn in ('finalizedWithdrawals(bytes32)', 'numProofSubmitters(bytes32)')], l1.block)
    unproven, proven = [], []
    for n, item in enumerate(known):
        if word_at(flags[2 * n], 0):
            item.update(status='FINALIZED_NOT_RELAYED', note='the portal finalized this withdrawal but the '
                        'L1 messenger records neither success nor failure; relayMessage cannot replay it')
        elif word_at(flags[2 * n + 1], 0) == 0:
            unproven.append(item)
        else:
            proven.append((item, min(word_at(flags[2 * n + 1], 0), 16)))
    game = latest_game(l1, portal) if unproven else None
    prove = (f'anyone, {l1_name}: OptimismPortal({portal}).proveWithdrawalTransaction('
             'tx, disputeGameIndex, outputRootProof, withdrawalProof)')
    for item in unproven:
        if 'error' in game:
            item.update(status='NOT_PROVEN', next=prove, note=game['error'])
        elif item['sourceBlock'] <= game['l2Block']:
            item.update(status='READY_TO_PROVE', next=prove)
        else:
            item.update(status='WAITING_FOR_PROPOSAL',
                        next=f'none: wait for a dispute game that claims {cfg["l2"]["name"]} block '
                             f'{item["sourceBlock"]} or later (the newest claims {game["l2Block"]})')
    # A withdrawal can be proven by several accounts; any one valid proof finalizes it.
    submitters = l1.rpc.views([(portal, selector('proofSubmitters(bytes32,uint256)') + unhex(i['withdrawalHash']) + word(k))
                               for i, count in proven for k in range(count)], l1.block)
    pairs, cursor = [], 0
    for item, count in proven:
        for k in range(count):
            pairs.append((item, word_at(submitters[cursor + k], 0)))
        cursor += count
    reads = l1.rpc.calls([(portal, selector(fn) + unhex(i['withdrawalHash']) + word(who)) for i, who in pairs
                          for fn in ('provenWithdrawals(bytes32,address)', 'checkWithdrawal(bytes32,address)')], l1.block)
    proofs: dict[int, list] = {}
    for n, (item, who) in enumerate(pairs):
        record, check = reads[2 * n], reads[2 * n + 1]
        if isinstance(record, Reverted):
            raise RpcError(f'{l1.name}: OptimismPortal {portal} did not answer provenWithdrawals(bytes32,address)')
        proofs.setdefault(id(item), []).append({
            'submitter': address(who), 'game': address(word_at(record, 0)), 'provenAt': word_at(record, 1),
            'maturesAt': word_at(record, 1) + maturity,
            'check': check.reason() if isinstance(check, Reverted) else 'ok'})
    # Whether an unfinalizable proof can still become finalizable depends on its dispute game.
    games = sorted({p['game'] for ps in proofs.values() for p in ps})
    statuses = dict(zip(games, l1.rpc.calls([(g, selector('status()')) for g in games], l1.block)))
    registry = flag(l1, portal, 'anchorStateRegistry()')
    verdicts = {}
    if registry and games:
        answers = l1.rpc.calls([(address(registry), selector(fn) + word(int(g, 16))) for g in games
                                for fn in GAME_VERDICTS.values()], l1.block)
        for n, game_ in enumerate(games):
            row = answers[len(GAME_VERDICTS) * n:len(GAME_VERDICTS) * (n + 1)]
            verdicts[game_] = {name: None if isinstance(r, Reverted) or len(r) < 32 else bool(word_at(r, 0))
                               for name, r in zip(GAME_VERDICTS, row)}
    for item, _ in proven:
        for proof in proofs[id(item)]:
            status = statuses[proof['game']]
            proof['gameStatus'] = ('unreadable' if isinstance(status, Reverted) or len(status) < 32
                                   else GAME_STATUSES[word_at(status, 0)] if word_at(status, 0) < 3 else str(word_at(status, 0)))
            verdict = verdicts.get(proof['game'], {})
            proof['gameRegistry'] = verdict
            dead = [reason for reason, hit in (
                ('lost to the challenger', proof['gameStatus'] == 'CHALLENGER_WINS'),
                ('retired', verdict.get('retired')), ('blacklisted', verdict.get('blacklisted')),
                ('not registered in the dispute game factory', verdict.get('registered') is False)) if hit]
            proof['invalid'] = ', '.join(dead) or None
        candidates = proofs[id(item)]
        ready = [p for p in candidates if p['check'] == 'ok']
        alive = [p for p in candidates if not p['invalid']]
        best = ready[0] if ready else max(alive or candidates, key=lambda p: p['provenAt'])
        item['proof'] = best
        finalize = f'OptimismPortal({portal}).finalizeWithdrawalTransactionExternalProof(tx, {best["submitter"]})'
        if ready:
            item.update(status='READY_TO_FINALIZE', next=f'anyone, {l1_name}: {finalize}')
        elif best['invalid']:
            item.update(status='PROOF_INVALIDATED', next='prove again: ' + prove,
                        note=f'this proof can no longer finalize: dispute game {best["game"]} is {best["invalid"]}')
        elif l1.timestamp <= best['maturesAt']:
            item.update(status='PROVEN_WAITING', next=f'after {stamp(best["maturesAt"])}, and once dispute game '
                                                      f'{best["game"]} is resolved for the defender and final, '
                                                      f'anyone, {l1_name}: {finalize}')
        else:
            item.update(status='PROVEN_WAITING', next=f'once dispute game {best["game"]} is resolved for the '
                                                      f'defender and final, anyone, {l1_name}: {finalize}')
    return game


# ── state that decides whether a relay would succeed now ──────────────────────────────────────
def flag(chain: Chain, contract: str, signature: str):
    reply = chain.read(contract, signature)
    return None if isinstance(reply, Reverted) or len(reply) < 32 else word_at(reply, 0)


def bridge_state(chain: Chain, bridge: str) -> dict:
    mode = flag(chain, bridge, 'getBridgeMode()')
    return {'depositsEnabled': bool(flag(chain, bridge, 'isDepositsEnabled()')),
            'withdrawalsEnabled': bool(flag(chain, bridge, 'isWithdrawalsEnabled()')),
            'mode': 'pre-migration implementation' if mode is None else BRIDGE_MODES[mode] if mode < 3 else str(mode)}


def blockers(state: dict, cfg: dict) -> dict:
    l1, l2, portal = state['l1Bridge'], state['l2Bridge'], state['portal']
    deposits, withdrawals = [], []
    if not l2['depositsEnabled']:
        deposits.append(f'deposits are disabled on the {cfg["l2"]["name"]} bridge: finalizeDeposit reverts')
    if l2['mode'] == 'CCIP_ONLY':
        deposits.append(f'the {cfg["l2"]["name"]} bridge is in CCIP_ONLY: finalizeDeposit reverts until a vote '
                        'returns it to MIGRATING')
    if not l1['withdrawalsEnabled']:
        withdrawals.append(f'withdrawals are disabled on the {cfg["l1"]["name"]} bridge: finalizeERC20Withdrawal reverts')
    if l1['mode'] == 'CCIP_ONLY':
        withdrawals.append(f'the {cfg["l1"]["name"]} bridge is in CCIP_ONLY: finalizeERC20Withdrawal reverts until '
                           'a vote returns it to MIGRATING')
    if portal['paused']:
        withdrawals.append('the OptimismPortal is paused: withdrawals can be neither proven nor finalized')
    return {'deposits': deposits, 'withdrawals': withdrawals}


def reconcile(cfg: dict, l1: Chain, l2: Chain, in_flight: int) -> dict:
    balance_of = selector('balanceOf(address)')
    escrow = word_at(l1.rpc.call(cfg['l1']['token'], balance_of + word(int(cfg['l1']['bridge'], 16)), l1.block), 0)
    result = {'escrow': str(escrow), 'lockBox': None, 'lockBoxBalance': '0'}
    box = flag(l1, cfg['l1']['bridge'], 'ccipLockBox()')
    held = 0
    if box:
        held = word_at(l1.rpc.call(cfg['l1']['token'], balance_of + word(box), l1.block), 0)
        result.update(lockBox=address(box), lockBoxBalance=str(held))
    supply = word_at(l2.read(cfg['l2']['token'], 'totalSupply()'), 0)
    result.update(l2Supply=str(supply), inFlight=str(in_flight),
                  unexplained=str(escrow + held - supply - in_flight))
    return result


# ── report ────────────────────────────────────────────────────────────────────────────────────
def stamp(seconds: int) -> str:
    return datetime.fromtimestamp(seconds, timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')


def age(seconds: int) -> str:
    seconds = max(0, seconds)
    days, rest = divmod(seconds, 86400)
    if days:
        return f'{days}d {rest // 3600}h'
    return f'{rest // 3600}h {rest % 3600 // 60}m' if rest >= 3600 else f'{rest // 60}m {rest % 60}s'


def amount(wei) -> str:
    whole, fraction = divmod(abs(int(wei)), 10 ** 18)
    text = f'{whole}.{fraction:018d}'.rstrip('0').rstrip('.')
    return ('-' if int(wei) < 0 else '') + text


STATUS_ORDER = ('RELAY_FAILED', 'L2_TX_FAILED', 'FINALIZED_NOT_RELAYED', 'PROOF_INVALIDATED', 'UNKNOWN',
                'READY_TO_FINALIZE', 'PROVEN_WAITING', 'READY_TO_PROVE', 'NOT_PROVEN', 'WAITING_FOR_PROPOSAL',
                'AWAITING_L2_INCLUSION')


def summarize(side: dict) -> None:
    by_status: dict[str, dict] = {}
    for item in side['inFlight']:
        entry = by_status.setdefault(item['status'], {'count': 0, 'amount': 0})
        entry['count'] += 1
        entry['amount'] += int(item.get('amount', 0))
    side['byStatus'] = {s: {'count': v['count'], 'amount': str(v['amount'])}
                        for s, v in sorted(by_status.items(), key=lambda kv: STATUS_ORDER.index(kv[0]))}
    side['inFlightAmount'] = str(sum(int(i.get('amount', 0)) for i in side['inFlight']))
    side['inFlight'].sort(key=lambda i: (STATUS_ORDER.index(i['status']), i['sourceBlock']))


def render(report: dict, limit: int | None) -> str:
    l1, l2, state = report['l1'], report['l2'], report['state']
    out = [f'Legacy wstETH bridge transfers in flight: {l1["name"]} ↔ {l2["name"]}', '']
    for chain in (l1, l2):
        final = 'no finality tag' if chain['finalBlock'] is None else f'final through {chain["finalBlock"]}'
        fork = ', LOCAL FORK' if chain['fork'] else ''
        out.append(f'  {chain["name"]}: chain {chain["chainId"]}, block {chain["block"]} at '
                   f'{stamp(chain["timestamp"])} ({final}{fork})')
        out.append(f'    bridge {chain["bridge"]}: mode {state[chain["key"] + "Bridge"]["mode"]}, deposits '
                   f'{"enabled" if state[chain["key"] + "Bridge"]["depositsEnabled"] else "DISABLED"}, withdrawals '
                   f'{"enabled" if state[chain["key"] + "Bridge"]["withdrawalsEnabled"] else "DISABLED"}')
        out.append(f'    messenger {chain["messenger"]}')
    portal = state['portal']
    out.append(f'  OptimismPortal {portal["address"]} {portal["version"]}: '
               f'{"PAUSED" if portal["paused"] else "not paused"}, proof maturity {age(portal["proofMaturityDelaySeconds"])}')
    game = report['latestDisputeGame']
    if game and 'error' not in game:
        out.append(f'    newest dispute game of the respected type {game["gameType"]}: {game["game"]}, '
                   f'claims {l2["name"]} block {game["l2Block"]}')
    for title, key, source, destination in (
            (f'Deposits {l1["name"]} → {l2["name"]}', 'deposits', l1, l2),
            (f'Withdrawals {l2["name"]} → {l1["name"]}', 'withdrawals', l2, l1)):
        side = report[key]
        out += ['', title, '  ' + '─' * (len(title))]
        out.append(f'  messages from the bridge: {side["sent"]} in {source["name"]} blocks '
                   f'{side["fromBlock"]}..{side["toBlock"]}; delivered: {side["delivered"]}'
                   + (f' ({side["deliveredAtHeadOnly"]} of them in a {destination["name"]} block that is not final yet)'
                      if side['deliveredAtHeadOnly'] else ''))
        if side['foreignMessages']:
            out.append(f'  ignored: {side["foreignMessages"]} messages to the bridge from other senders')
        for line in report['blockers'][key]:
            out.append(f'  ⚠ {line}')
        if not side['inFlight']:
            out.append('  in flight: none')
            continue
        out.append(f'  in flight: {len(side["inFlight"])}, {amount(side["inFlightAmount"])} wstETH')
        for status, entry in side['byStatus'].items():
            out.append(f'    {status:<22}{entry["count"]:>5}  {amount(entry["amount"])} wstETH')
        shown = side['inFlight'] if limit is None else side['inFlight'][:limit]
        for item in shown:
            what = f'{amount(item["amount"])} wstETH' if item['kind'] == 'transfer' else f'control message {item["selector"]}'
            sent = (f'sent {stamp(item["sourceTimestamp"])} ({age(report["generatedAt"] - item["sourceTimestamp"])} ago)'
                    if item.get('sourceTimestamp') else 'sent at an unknown time')
            out += ['', f'  {item["status"]}  {what}  {sent}']
            if item['kind'] == 'transfer':
                out.append(f'    from {item["from"]} to {item["to"]}')
            out.append(f'    {source["name"]} tx {item["sourceTx"]} (block {item["sourceBlock"]}'
                       f'{"" if item["sourceFinal"] else ", not final yet"})')
            out.append(f'    message {item["messageHash"]} (messenger nonce {int(item["nonce"]) & ((1 << 240) - 1)})')
            if 'withdrawalHash' in item:
                out.append(f'    withdrawal {item["withdrawalHash"]}')
            if 'proof' in item:
                proof = item['proof']
                out.append(f'    proven {stamp(proof["provenAt"])} by {proof["submitter"]}')
                out.append(f'    against dispute game {proof["game"]} ({proof["gameStatus"]}); '
                           f'portal check: {proof["check"]}')
            if 'note' in item:
                out.append(f'    note: {item["note"]}')
            if 'next' in item:
                out.append(f'    next: {item["next"]}')
        if len(shown) < len(side['inFlight']):
            out += ['', f'  … {len(side["inFlight"]) - len(shown)} more; raise --limit or use --json']
    books = report['reconciliation']
    out += ['', 'Backing', '  ───────',
            f'  {amount(books["escrow"]):>28}  wstETH held by the {l1["name"]} bridge (block {l1["block"]})']
    if books['lockBox']:
        out.append(f'  {"+ " + amount(books["lockBoxBalance"]):>28}  wstETH held by the lockbox {books["lockBox"]}')
    out += [f'  {"− " + amount(books["l2Supply"]):>28}  wstETH supply on {l2["name"]} (block {l2["block"]})',
            f'  {"− " + amount(books["inFlight"]):>28}  transfers in flight listed above',
            f'  {"= " + amount(books["unexplained"]):>28}  not explained by this list',
            '  The two chains are read at different moments, and the list covers the legacy bridge only:',
            '  tokens sent to the bridge address directly, CCIP transfers and a transfer that lands',
            '  between the two reads all show up in the last line. It names no cause by itself.']
    return '\n'.join(out) + '\n'


# ── run ───────────────────────────────────────────────────────────────────────────────────────
def load_cache(path: Path | None, key: dict) -> dict:
    if path and path.is_file():
        try:
            data = json.loads(path.read_text())
            if data.get('version') == CACHE_VERSION and data.get('key') == key:
                return data
        except (ValueError, OSError):
            pass
    return {'version': CACHE_VERSION, 'key': key, 'deposits': None, 'withdrawals': None}


def save_cache(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, separators=(',', ':')))
    temporary.replace(path)


def build_report(cfg: dict, args) -> dict:
    l1 = Chain(cfg['l1']['name'], cfg['l1']['url'], cfg['l1']['chainId'])
    l2 = Chain(cfg['l2']['name'], cfg['l2']['url'], cfg['l2']['chainId'])
    for chain, side, getter, other in ((l1, 'l1', 'l2TokenBridge()', 'l2'), (l2, 'l2', 'l1TokenBridge()', 'l1')):
        paired = flag(chain, cfg[side]['bridge'], getter)
        uses = flag(chain, cfg[side]['bridge'], 'messenger()')
        if paired != int(cfg[other]['bridge'], 16) or uses != int(cfg[side]['messenger'], 16):
            raise SystemExit(f'✗ {chain.name}: bridge {cfg[side]["bridge"]} is not paired with the configured '
                             'counterpart bridge and messenger')
    portal = flag(l1, cfg['l1']['messenger'], 'portal()') or flag(l1, cfg['l1']['messenger'], 'PORTAL()')
    if not portal:
        raise SystemExit(f'✗ {l1.name}: messenger {cfg["l1"]["messenger"]} names no OptimismPortal')
    portal = address(portal)
    version = l1.read(portal, 'version()')
    maturity = flag(l1, portal, 'proofMaturityDelaySeconds()')
    if maturity is None:
        raise SystemExit(f'✗ {l1.name}: OptimismPortal {portal} has no proofMaturityDelaySeconds(); this script '
                         'reads the dispute-game portal only')
    state = {'l1Bridge': bridge_state(l1, cfg['l1']['bridge']), 'l2Bridge': bridge_state(l2, cfg['l2']['bridge']),
             'portal': {'address': portal, 'paused': bool(flag(l1, portal, 'paused()')),
                        'version': 'unversioned' if isinstance(version, Reverted) else bytes_at(version, 32).decode(),
                        'proofMaturityDelaySeconds': maturity}}

    # A fork's history is its own, a partial scan is not the bridge's history, and without a
    # finality tag nothing is safe to keep.
    partial = args.l1_from_block is not None or args.l2_from_block is not None
    cache_path = None
    if not (args.no_cache or partial or l1.fork or l2.fork or l1.final is None or l2.final is None):
        cache_path = Path(args.cache_dir) / f'{l1.chain_id}-{l2.chain_id}-{cfg["l1"]["bridge"].lower()}.json'
    key = {side: {k: cfg[side][k] for k in ('chainId', 'bridge', 'messenger')} for side in ('l1', 'l2')}
    cache = load_cache(cache_path, key)

    sent_deposits = collect(l1, cfg['l1']['messenger'], cfg['l1']['bridge'], cfg['l2']['bridge'],
                            cache['deposits'], args.l1_from_block, f'{l1.name} messages')
    sent_withdrawals = collect(l2, cfg['l2']['messenger'], cfg['l2']['bridge'], cfg['l1']['bridge'],
                               cache['withdrawals'], args.l2_from_block, f'{l2.name} messages')
    open_deposits = [describe(m, 'deposit') | {'relayFailed': m['relayFailed']}
                     for m in settle(sent_deposits['messages'], l2, cfg['l2']['messenger'])]
    open_withdrawals = [describe(m, 'withdrawal') | {'relayFailed': m['relayFailed']}
                        for m in settle(sent_withdrawals['messages'], l1, cfg['l1']['messenger'])]
    resolve_deposits(open_deposits, cfg, l1, l2, portal)
    game = resolve_withdrawals(open_withdrawals, cfg, l1, l2, portal, maturity)
    for chain, items in ((l1, open_deposits), (l2, open_withdrawals)):
        times = chain.timestamps({i['sourceBlock'] for i in items})
        for item in items:
            item['sourceTimestamp'] = times.get(item['sourceBlock'])

    def side(sent: dict, items: list[dict]) -> dict:
        at_head = sum(1 for m in sent['messages'] if m.pop('deliveredAtHead', False))
        return {'sent': len(sent['messages']), 'delivered': len(sent['messages']) - len(items),
                'deliveredAtHeadOnly': at_head, 'foreignMessages': sent['foreign'],
                'fromBlock': sent['range'][0], 'toBlock': sent['range'][1], 'inFlight': items}

    now = int(time.time())
    report = {
        'generatedAt': now, 'generatedAtUtc': stamp(now),
        'l1': {'key': 'l1', 'name': l1.name, 'chainId': l1.chain_id, 'block': l1.block, 'timestamp': l1.timestamp,
               'finalBlock': l1.final, 'fork': l1.fork, 'bridge': cfg['l1']['bridge'],
               'messenger': cfg['l1']['messenger'], 'token': cfg['l1']['token']},
        'l2': {'key': 'l2', 'name': l2.name, 'chainId': l2.chain_id, 'block': l2.block, 'timestamp': l2.timestamp,
               'finalBlock': l2.final, 'fork': l2.fork, 'bridge': cfg['l2']['bridge'],
               'messenger': cfg['l2']['messenger'], 'token': cfg['l2']['token']},
        'state': state, 'blockers': blockers(state, cfg),
        'deposits': side(sent_deposits, open_deposits), 'withdrawals': side(sent_withdrawals, open_withdrawals),
        'latestDisputeGame': game,
    }
    for key_ in ('deposits', 'withdrawals'):
        summarize(report[key_])
    report['reconciliation'] = reconcile(cfg, l1, l2, int(report['deposits']['inFlightAmount'])
                                         + int(report['withdrawals']['inFlightAmount']))
    report['rpcRequests'] = {l1.name: l1.rpc.requests, l2.name: l2.rpc.requests}
    if cache_path:
        cache.update(deposits=sent_deposits['state'], withdrawals=sent_withdrawals['state'])
        save_cache(cache_path, cache)
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--target', default=str(DEFAULT_TARGET),
                        help='target.json whose .migration names the tokens, bridge proxies and messengers')
    parser.add_argument('--l2', help='L2 slug in the target (default: its first L2)')
    parser.add_argument('--l1-rpc', help='L1 endpoint (default: RPC_<L1 SLUG>, e.g. RPC_ETHEREUM)')
    parser.add_argument('--l2-rpc', help='L2 endpoint (default: RPC_<L2 SLUG>, e.g. RPC_BASE)')
    parser.add_argument('--l1-from-block', type=int, help='first L1 block to scan (default: the L1 bridge creation block)')
    parser.add_argument('--l2-from-block', type=int, help='first L2 block to scan (default: the L2 bridge creation block)')
    parser.add_argument('--json', action='store_true', help='print the full report as JSON')
    parser.add_argument('--limit', type=int, default=20,
                        help='transfers listed per direction in the text report; 0 lists all (default: 20)')
    parser.add_argument('--expect-empty', action='store_true', help='exit 2 when any transfer is in flight')
    parser.add_argument('--no-cache', action='store_true', help='rescan the whole history and keep nothing')
    parser.add_argument('--cache-dir', default=str(DEFAULT_CACHE_DIR), help='where scanned messages are kept')
    args = parser.parse_args(argv)
    try:
        report = build_report(load_config(args), args)
    except RpcError as error:
        print(f'✗ {error}\n  endpoints come from --l1-rpc / --l2-rpc or the RPC_<SLUG> variables', file=sys.stderr)
        return 1
    if args.json:
        json.dump(report, sys.stdout, indent=2)
        print()
    else:
        sys.stdout.write(render(report, args.limit or None))
    in_flight = len(report['deposits']['inFlight']) + len(report['withdrawals']['inFlight'])
    return 2 if args.expect_empty and in_flight else 0


if __name__ == '__main__':
    sys.exit(main())

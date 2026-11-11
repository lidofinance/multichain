#!/usr/bin/env python3
"""Prove each old-pool outbound pause with an exact revert and transient call overrides."""
import json
import os
import sys
from pathlib import Path

from bootstrap.rpc import Fork, RpcError, cast, encode, read

AMOUNT = 10**18
ZERO = '0x' + '0' * 40
MESSAGE = '(bytes,bytes,(address,uint256)[],address,bytes)'


def require_capacity_revert(error, expected):
    # Anvil returns execution-reverted data as a hex string. Missing data, transport
    # errors, and unrelated EVM errors must never become evidence of a pause.
    data = error.get('data')
    if error.get('code') != 3 or not isinstance(data, str) or data.lower() != expected.lower():
        raise ValueError('Pause was not proved: expected the exact TokenMaxCapacityExceeded revert')


def check_lane(fork, token, router, sender, selector):
    msg = f'({cast("abi-encode", "f(address)", sender)},0x,[({token},{AMOUNT})],{ZERO},0x)'
    fee = int(fork.call(router, f'getFee(uint64,{MESSAGE})(uint256)', selector, msg))
    # Upstream wstETH (OZ ERC20 0.6.12): balances at slot 0, allowances at slot 1.
    balance_slot = cast('index', 'address', sender, 0)
    allowance_root = cast('index', 'address', sender, 1)
    allowance_slot = cast('index', 'address', router, allowance_root)
    value = '0x' + f'{AMOUNT:064x}'
    overrides = {sender: {'balance': hex(fee + 10**18)},
                 token: {'stateDiff': {balance_slot: value, allowance_slot: value}}}
    tx = {'from': sender, 'to': router, 'value': hex(fee),
          'data': encode(f'ccipSend(uint64,{MESSAGE})', selector, msg)}
    expected = encode('TokenMaxCapacityExceeded(uint256,uint256,address)', 2, AMOUNT, token)
    try:
        fork.rpc('eth_call', tx, 'latest', overrides)
    except RpcError as error:
        require_capacity_revert(error.error, expected)
        return 'TokenMaxCapacityExceeded'
    raise ValueError('Outbound transfer succeeded after the pause')


def main():
    manifest = read(Path(sys.argv[1]))
    fork = Fork(os.environ['L1_CHAIN'], os.environ['L1_RPC'], manifest['readAt']['chainId'])
    sender = '0x' + cast('keccak', 'lido-hub-migration:sender')[-40:]
    results = {lane['slug']: check_lane(fork, manifest['token'], manifest['router'], sender, lane['selector'])
               for lane in manifest['lanes']}
    print(json.dumps(results))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError):
        sys.exit('Hub pause verification failed; no cutover is authorized by this check')

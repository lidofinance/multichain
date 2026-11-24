#!/usr/bin/env python3
"""Independently encode the intended Base connection from records and pinned defaults."""
import sys
from pathlib import Path
from bootstrap.rpc import cast, read
from hub_runner import OPS, inputs_hash, workspace
import ccip_build


def expected_calls(cfg, remote, lane, defaults):
    selector = remote['ccip']['chain_selector']
    pool = cfg['deployed']['token_pool']
    resolver, verifier = cfg['ccv']['verifier_resolver'], cfg['ccv']['message_id_verifier']
    box = next(b['lock_box'] for b in cfg['deployed']['lock_boxes'] if b['remote_chain_name'] == lane)
    token = remote['deployed'].get('token') or remote['addresses']['token']
    word = lambda addr: '0x' + addr[2:].lower().zfill(64)
    limiter = lambda c: f'({str(c["enabled"]).lower()},{c["capacity"]},{c["rate"]})'
    limits = defaults['rate_limiter_defaults']
    specifications = [
        (pool, 'applyChainUpdates(uint64[],(uint64,bytes[],bytes,(bool,uint128,uint128),(bool,uint128,uint128))[])',
         ['[]', f'[({selector},[{word(remote["deployed"]["token_pool"])}],{word(token)},'
          f'{limiter(limits["outbound"])},{limiter(limits["inbound"])})]']),
        (pool, 'applyTokenTransferFeeConfigUpdates((uint64,(uint32,uint32,uint32,uint32,uint16,uint16,bool))[],uint64[])',
         [f'[({selector},({defaults["token_transfer_fee_defaults"]["dest_gas_overhead"]},32,0,0,0,0,true))]', '[]']),
        (pool, 'configureLockBoxes((uint64,address)[])', [f'[({selector},{box})]']),
        (cfg['deployed']['advanced_pool_hooks'], 'applyCCVConfigUpdates((uint64,address[],address[],address[],address[])[])',
         [f'[({selector},[{resolver}],[],[{resolver}],[])]']),
        (verifier, 'applyRemoteChainConfigUpdates((address,uint64,bool,uint16,uint32,uint16)[])',
         [f'[({cfg["ccip"]["router"]},{selector},false,0,1,36)]']),
        (resolver, 'applyOutboundImplementationUpdates((uint64,address)[])', [f'[({selector},{verifier})]']),
    ]
    return [{'target': target.lower(), 'value': '0', 'data': cast('calldata', signature, *args).lower()}
            for target, signature, args in specifications]


def verify(path):
    run, info = workspace.active()
    proposal = read(path)
    cfg = read(run / 'config/chains' / (info['l1Chain'] + '.json'))
    lane = proposal['lane']
    if lane not in cfg['deferred_lanes'] or lane not in info['l2Chains']:
        raise ValueError('Proposal lane is not a deferred spoke in this run')
    if (proposal['runId'] != info['id'] or proposal['chainId'] != cfg['chain']['chain_id']
            or proposal['hub'].lower() != cfg['deployed']['token_pool'].lower()
            or proposal['timelock'].lower() != cfg['deployed']['timelock'].lower()
            or proposal['inputsHash'] != inputs_hash(run, info['l1Chain'])):
        raise ValueError('Proposal belongs to different inputs/run/chain/hub/timelock')
    remote = read(run / 'config/chains' / (lane + '.json'))
    defaults = read(ccip_build.EVM / 'contracts/lido-hvmv/config/default_config.json')
    calls = [{'target': c['target'].lower(), 'value': str(c['value']), 'data': c['data'].lower()}
             for c in proposal['calls']]
    if calls != expected_calls(cfg, remote, lane, defaults):
        raise ValueError('Proposal calldata/order/targets differ from independent record/default inputs')
    print('Proposal: run binding and all six calls verified independently')


if __name__ == '__main__':
    verify(Path(sys.argv[1]))

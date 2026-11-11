#!/usr/bin/env python3
"""Read imported-lane invariants independently of the deployment/proposal generator."""
import argparse
import os
from bootstrap.rpc import Fork, read, write, encode, decoded
from hub_runner import workspace


def snapshot(run, cfg, fork):
    manifest = read(run / 'state/hub-migration/manifest.json')
    pool, token = cfg['deployed']['token_pool'], cfg['addresses']['token']
    boxes, lanes = {}, {}
    for lane in manifest['lanes']:
        selector = lane['selector']
        box = fork.call(pool, 'getLockBox(uint64)(address)', selector)
        pools = fork.call(pool, 'getRemotePools(uint64)(bytes[])', selector)
        remote_token = fork.call(pool, 'getRemoteToken(uint64)(bytes)', selector)
        pools = sorted('0x' + p[-40:].lower() for p in pools)
        raw = fork.rpc('eth_call', {'to': pool, 'data': encode(
            'getCurrentRateLimiterState(uint64,bool)', selector, 'false')}, 'latest')
        out, inbound = decoded('x()((uint128,uint32,bool,uint128,uint128),(uint128,uint32,bool,uint128,uint128))', raw)
        config = lambda b: {'enabled': b[2], 'capacity': str(b[3]), 'rate': str(b[4])}
        if pools != sorted(p.lower() for p in lane['remotePools']) or ('0x' + remote_token[-40:]).lower() != lane['remoteToken'].lower():
            raise ValueError('Imported remote pools/token changed: ' + lane['slug'])
        if config(out) != lane['outbound'] or config(inbound) != lane['inbound']:
            raise ValueError('Imported rate limits changed: ' + lane['slug'])
        expected_box = next(b['lock_box'] for b in cfg['deployed']['lock_boxes'] if b['remote_chain_name'] == lane['slug'])
        if box.lower() != expected_box.lower():
            raise ValueError('Imported custody binding changed: ' + lane['slug'])
        owner = fork.call(box, 'owner()(address)')
        if owner.lower() != cfg['deployed']['timelock'].lower():
            raise ValueError('Imported lockbox owner mismatch')
        boxes[box.lower()] = str(fork.call(token, 'balanceOf(address)(uint256)', box))
        lanes[lane['slug']] = {'pools': pools, 'token': remote_token.lower(), 'box': box.lower(),
                                'outbound': config(out), 'inbound': config(inbound), 'owner': owner.lower()}
    return {'lanes': lanes, 'balances': boxes,
            'registry': fork.call(cfg['ccip']['token_admin_registry'], 'getTokenConfig(address)((address,address,address))', token)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['before', 'after'])
    args = parser.parse_args()
    run, info = workspace.active()
    cfg = read(run / 'config/chains' / (info['l1Chain'] + '.json'))
    fork = Fork(info['l1Chain'], os.environ['L1_RPC'], cfg['chain']['chain_id'])
    state = snapshot(run, cfg, fork)
    if args.phase == 'after' and state != read(run / 'state/hub-preserved-before.json'):
        raise ValueError('Base connection changed imported lane configuration, custody, balances or TAR')
    write(run / ('state/hub-preserved-' + args.phase + '.json'), state)
    print('Imported lanes, custody, balances and TAR: ' + args.phase + ' verified')


if __name__ == '__main__':
    main()

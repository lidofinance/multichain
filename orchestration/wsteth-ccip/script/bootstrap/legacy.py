"""Create the legacy migration baseline on disposable Sepolia-family forks."""
import copy
import os
from pathlib import Path
import subprocess
import sys
from rpc import OPS, ROOT, ZERO, TXS, cast, decoded, encode, inputs, read, write

BOOT = ROOT / 'targets/wsteth-base-migration-sepolia/bootstrap'
CCIP_OUT = ROOT / 'components/ccip/chains/evm/foundry-artifacts'
CHAINS = OPS / 'config/chains'
STATE = OPS / 'state'
CHAIN_UPDATE = 'applyChainUpdates(uint64[],(uint64,bytes[],bytes,(bool,uint128,uint128),(bool,uint128,uint128))[])'
LIMIT = '(true,10000000000000000000000,1000000000000000000)'


def artifact(directory, name):
    return directory / (name + '.sol') / (name + '.json')


def word(address):
    return cast('abi-encode', 'x(address)', address)


def register(fork, registry, token, admin, pool):
    owner = fork.call(registry, 'owner()(address)')
    assert fork.call(registry, 'getPool(address)(address)', token).lower() == ZERO
    fork.send(owner, registry, 'proposeAdministrator(address,address)', token, admin)
    fork.send(admin, registry, 'acceptAdminRole(address)', token)
    fork.send(admin, registry, 'setPool(address,address)', token, pool)
    assert fork.call(registry, 'getPool(address)(address)', token).lower() == pool.lower()
    config = fork.call(registry, 'getTokenConfig(address)((address,address,address))', token)
    assert config[0].lower() == admin.lower() and config[1].lower() == ZERO
    return owner


def configure_lane(fork, sender, pool, selector, remote_pool, remote_token):
    row = f'({selector},[{word(remote_pool)}],{word(remote_token)},{LIMIT},{LIMIT})'
    fork.send(sender, pool, CHAIN_UPDATE, '[]', '[' + row + ']')


def transfer_pool(fork, sender, pool, owner):
    fork.send(sender, pool, 'transferOwnership(address)', owner)
    fork.send(owner, pool, 'acceptOwnership()')


def init_bridge(fork, deployer, proxy, implementation, governor, brakes):
    fork.send(deployer, proxy, 'proxy__upgradeToAndCall(address,bytes,bool)', implementation,
              encode('initialize(address)', deployer), 'false')
    for role in ['DEPOSITS_ENABLER_ROLE', 'WITHDRAWALS_ENABLER_ROLE']:
        fork.send(deployer, proxy, 'grantRole(bytes32,address)', cast('keccak', 'BridgingManager.' + role), governor)
    for role in ['DEPOSITS_DISABLER_ROLE', 'WITHDRAWALS_DISABLER_ROLE']:
        fork.send(deployer, proxy, 'grantRole(bytes32,address)', cast('keccak', 'BridgingManager.' + role), brakes)
    fork.send(governor, proxy, 'enableDeposits()')
    fork.send(governor, proxy, 'enableWithdrawals()')
    fork.send(deployer, proxy, 'grantRole(bytes32,address)', '0x' + '0'*64, governor)
    fork.send(deployer, proxy, 'renounceRole(bytes32,address)', '0x' + '0'*64, deployer)
    fork.send(deployer, proxy, 'proxy__changeAdmin(address)', governor)


def deploy():
    target, forks = inputs()
    if (STATE / 'bootstrap.json').exists():
        raise ValueError('Baseline already exists; use a new run and fresh forks')
    for profile in ['default', 'pools']:
        subprocess.run(['forge', 'build', '--root', str(BOOT), '--silent'],
                       env=dict(os.environ, FOUNDRY_PROFILE=profile), check=True)
    l1, l2 = forks['sepolia'], forks['base_sepolia']
    c1, c2 = read(CHAINS / 'sepolia.json'), read(CHAINS / 'base_sepolia.json')
    s1, s2 = read(STATE / 'l1.json'), read(STATE / 'base_sepolia.json')
    deployer = os.environ['DEPLOYER_ADDRESS']
    actor = c1['governance_addresses']['chainlink_mcms']
    brakes = c1['governance_addresses']['emergency_brakes']
    token, agent, executor = s1['wstETH'], s1['agent'], s2['opExec']
    # Real OP messengers supply their pairing; no hardcoded Sepolia L1 messenger.
    l2_messenger = '0x4200000000000000000000000000000000000007'
    l1_messenger = l2.call(l2_messenger, 'OTHER_MESSENGER()(address)')
    assert l1.rpc('eth_getCode', l1_messenger, 'latest') != '0x'

    print('Bootstrap: legacy Chainlink timelock and hub', flush=True)
    timelock = l1.deploy(deployer, artifact(CCIP_OUT, 'RBACTimelock'),
                        'constructor(uint256,address,address[],address[],address[],address[])',
                        target['bootstrap']['legacyTimelockDelay'], actor, f'[{actor}]', '[]', f'[{actor}]', '[]')
    call_proxy = l1.deploy(deployer, artifact(CCIP_OUT, 'CallProxy'), 'constructor(address)', timelock)
    l1.send(actor, timelock, 'grantRole(bytes32,address)', l1.call(timelock, 'EXECUTOR_ROLE()(bytes32)'), call_proxy)
    pool = l1.deploy(deployer, artifact(BOOT / 'out-pools', 'SiloedLockReleaseTokenPool'),
                     'constructor(address,uint8,address[],address,address)', token, 18, '[]',
                     c1['ccip']['rmn_proxy'], c1['ccip']['router'])
    assert l1.call(pool, 'typeAndVersion()(string)') == 'SiloedLockReleaseTokenPool 1.6.0'

    # Stake and wrap via full Lido: the new balances remain backed by stETH.
    l1.send(deployer, token, data='0x', value=int(target['bootstrap']['stakeWei']))
    total = sum(int(l['amount']) for l in target['bootstrap']['lanes'])
    assert int(l1.call(token, 'balanceOf(address)(uint256)', deployer)) >= total + int(target['bootstrap']['baseSeedWei']) + 40*10**18
    lanes = []
    for lane in target['bootstrap']['lanes']:
        f, info = forks[lane['slug']], lane['chain']
        print('Bootstrap: existing lane ' + lane['slug'], flush=True)
        remote_token = f.deploy(deployer, artifact(BOOT / 'out-pools', 'BurnMintERC20'),
                                'constructor(string,string,uint8,uint256,uint256)',
                                'Rehearsal wstETH', 'rwstETH', 18, 0, 0)
        remote_pool = f.deploy(deployer, artifact(BOOT / 'out-pools', 'BurnMintTokenPool'),
                               'constructor(address,uint8,address[],address,address)',
                               remote_token, 18, '[]', info['rmn'], info['router'])
        f.send(deployer, remote_token, 'grantMintAndBurnRoles(address)', remote_pool)
        f.send(deployer, remote_token, 'grantMintAndBurnRoles(address)', deployer)
        f.send(deployer, remote_token, 'mint(address,uint256)', deployer, lane['amount'])
        configure_lane(f, deployer, remote_pool, c1['ccip']['chain_selector'], pool, token)
        configure_lane(l1, deployer, pool, info['selector'], remote_pool, remote_token)
        remote_registry_owner = register(f, info['tokenAdminRegistry'], remote_token, actor, remote_pool)
        transfer_pool(f, deployer, remote_pool, actor)
        if lane['siloed']:
            l1.send(deployer, pool, 'updateSiloDesignations(uint64[],(uint64,address)[])', '[]',
                    f'[({info["selector"]},{deployer})]')
            l1.send(deployer, token, 'approve(address,uint256)', pool, lane['amount'])
            l1.send(deployer, pool, 'provideSiloedLiquidity(uint64,uint256)', info['selector'], lane['amount'])
        else:
            l1.send(deployer, pool, 'setRebalancer(address)', deployer)
            l1.send(deployer, token, 'approve(address,uint256)', pool, lane['amount'])
            l1.send(deployer, pool, 'provideLiquidity(uint256)', lane['amount'])
        lanes.append(dict(lane, token=remote_token, pool=remote_pool, owner=actor,
                          registryOwner=remote_registry_owner))
    l1.send(deployer, pool, 'setRebalancer(address)', timelock)
    transfer_pool(l1, deployer, pool, timelock)
    registry_owner = register(l1, c1['ccip']['token_admin_registry'], token, timelock, pool)

    print('Bootstrap: original Base bridge proxies and token', flush=True)
    proxy_artifact = artifact(BOOT / 'out', 'OssifiableProxy')
    # Temporary implementations are replaced before any bridge is enabled. Their proxies resolve
    # the circular immutable references without etching code or changing deployed source.
    l1_bridge = l1.deploy(deployer, proxy_artifact, 'constructor(address,address,bytes)', token, deployer, '0x')
    placeholder = l2.deploy(deployer, artifact(BOOT / 'out', 'ERC20Bridged'),
                            'constructor(string,string,uint8,address)', 'Placeholder', 'PH', 18, deployer)
    l2_bridge = l2.deploy(deployer, proxy_artifact, 'constructor(address,address,bytes)', placeholder, deployer, '0x')
    token_impl = l2.deploy(deployer, artifact(BOOT / 'out', 'ERC20Bridged'),
                           'constructor(string,string,uint8,address)',
                           'Wrapped liquid staked Ether 2.0', 'wstETH', 18, l2_bridge)
    l2_token = l2.deploy(deployer, proxy_artifact, 'constructor(address,address,bytes)', token_impl, executor,
                         encode('initialize(string,string)', 'Wrapped liquid staked Ether 2.0', 'wstETH'))
    l1_impl = l1.deploy(deployer, artifact(BOOT / 'out', 'L1ERC20TokenBridge'),
                        'constructor(address,address,address,address)', l1_messenger, l2_bridge, token, l2_token)
    l2_impl = l2.deploy(deployer, artifact(BOOT / 'out', 'L2ERC20TokenBridge'),
                        'constructor(address,address,address,address)', l2_messenger, l1_bridge, token, l2_token)
    init_bridge(l1, deployer, l1_bridge, l1_impl, agent, brakes)
    init_bridge(l2, deployer, l2_bridge, l2_impl, executor, brakes)
    amount = target['bootstrap']['baseSeedWei']
    l1.send(deployer, token, 'approve(address,uint256)', l1_bridge, amount)
    receipt = l1.send(deployer, l1_bridge, 'depositERC20(address,address,uint256,uint32,bytes)',
                      token, l2_token, amount, 200000, '0x')
    topic = cast('keccak', 'SentMessage(address,address,bytes,uint256,uint256)')
    log = next(l for l in receipt['logs'] if l['address'].lower() == l1_messenger.lower() and l['topics'][0] == topic)
    sender, message, nonce, gas = decoded('x()(address,bytes,uint256,uint256)', log['data'])
    alias = '0x%040x' % ((int(l1_messenger, 16) + int('1111000000000000000000000000000000001111', 16)) % 2**160)
    relay = encode('relayMessage(uint256,address,address,uint256,uint256,bytes)', nonce, sender, l2_bridge, 0, gas, message)
    l2.send(alias, l2_messenger, data=relay)
    assert l2.call(l2_messenger, 'successfulMessages(bytes32)(bool)', cast('keccak', relay))
    assert int(l2.call(l2_token, 'totalSupply()(uint256)')) == int(amount)
    assert int(l1.call(token, 'balanceOf(address)(uint256)', l1_bridge)) == int(amount)
    for cfg, tok, gov in [(c1, token, agent), (c2, l2_token, executor)]:
        cfg['addresses']['token'] = tok
        cfg['governance_addresses']['lido_dao_agent'] = gov
    write(CHAINS / 'sepolia.json', c1)
    write(CHAINS / 'base_sepolia.json', c2)
    generated = copy.deepcopy(target)
    generated['migration']['l1'] = dict(agent=agent, token=token, bridgeProxy=l1_bridge,
        messenger=l1_messenger, registryAdministrator=timelock, emergencyBrakes=brakes)
    generated['migration']['l2s'] = [dict(slug='base_sepolia', token=l2_token, executor=executor,
        bridgeProxy=l2_bridge, messenger=l2_messenger, emergencyBrakes=brakes)]
    generated['migration']['hub'].update(pool=pool, timelock=timelock)
    write(STATE / 'migration-target.json', generated)
    write(STATE / 'bootstrap.json', dict(schemaVersion=1, token=token, oldPool=pool,
        registry=c1['ccip']['token_admin_registry'], registryOwner=registry_owner, timelock=timelock,
        callProxy=call_proxy, agent=agent, executor=executor, deployer=deployer, lanes=lanes,
        baseToken=l2_token, baseBridge=l2_bridge, l1Bridge=l1_bridge, baseSeedWei=amount,
        forks={s: {'chainId': int(f.rpc('eth_chainId'),16), 'block': int(f.block['number'],16),
                   'blockHash': f.block['hash']} for s,f in forks.items()}, transactions=TXS))
    print('Bootstrap complete: full Lido, pristine wstETH, official registries, two existing lanes and legacy Base', flush=True)


def connect():
    target, forks = inputs()
    baseline = read(STATE / 'bootstrap.json')
    c1 = read(CHAINS / 'sepolia.json')
    new_hub = c1['deployed']['token_pool']
    for lane in baseline['lanes']:
        f = forks[lane['slug']]
        f.send(lane['owner'], lane['pool'], 'addRemotePool(uint64,bytes)', c1['ccip']['chain_selector'], word(new_hub))
        f.send(lane['owner'], lane['pool'], 'removeRemotePool(uint64,bytes)', c1['ccip']['chain_selector'], word(baseline['oldPool']))
        assert f.call(lane['pool'], 'getRemotePools(uint64)(bytes[])', c1['ccip']['chain_selector']) == [word(new_hub)]
    write(STATE / 'bootstrap-remotes.json', {'hub':new_hub, 'transactions':TXS, 'pendingMessages':0,
          'scope':'Fresh bootstrap has no in-flight CCIP messages; real queue drain is outside this simulation.'})


def verify_baseline():
    _, forks = inputs()
    baseline = read(STATE / 'bootstrap.json')
    selector = read(CHAINS / 'sepolia.json')['ccip']['chain_selector']
    for lane in baseline['lanes']:
        f = forks[lane['slug']]
        assert int(f.call(lane['token'], 'totalSupply()(uint256)')) == int(lane['amount'])
        assert f.call(lane['pool'], 'getToken()(address)').lower() == lane['token'].lower()
        assert f.call(lane['pool'], 'getRemotePools(uint64)(bytes[])', selector) == [word(baseline['oldPool'])]
        assert f.call(lane['pool'], 'getRemoteToken(uint64)(bytes)', selector) == word(baseline['token'])
        admin, pending, pool = f.call(lane['chain']['tokenAdminRegistry'],
            'getTokenConfig(address)((address,address,address))', lane['token'])
        assert admin.lower() == lane['owner'].lower() and pending == ZERO and pool.lower() == lane['pool'].lower()
        assert f.call(lane['pool'], 'owner()(address)').lower() == admin.lower()
        print('PASS reciprocal baseline: ' + lane['slug'], flush=True)


def test_transfers():
    _, forks = inputs()
    baseline, c1 = read(STATE / 'bootstrap.json'), read(CHAINS / 'sepolia.json')
    l1 = forks['sepolia']
    token, hub = baseline['token'], c1['deployed']['token_pool']
    holder, l1_selector = baseline['deployer'], c1['ccip']['chain_selector']
    amount = 10**18
    boxes = {x['lock_box'] for x in c1['deployed']['lock_boxes']}
    def balance(f, t, a): return int(f.call(t, 'balanceOf(address)(uint256)', a))
    def supply(f, t): return int(f.call(t, 'totalSupply()(uint256)'))
    def offramp(f, router, selector):
        ramps = f.call(router, 'getOffRamps()((uint64,address)[])')
        return next(a for s,a in ramps if int(s) == int(selector))
    def lock(f, t, pool, router, selector):
        f.send(holder, t, 'transfer(address,uint256)', pool, amount)
        ramp = f.call(router, 'getOnRamp(uint64)(address)', selector)
        sig = 'lockOrBurn((bytes,uint64,address,uint256,address))'
        args = f'({word(holder)},{selector},{holder},{amount},{t})'
        data = encode(sig, args)
        # OP's eth_call also checks the caller's gas balance, before send() funds it.
        f.rpc('anvil_setBalance', ramp, hex(10**25))
        # LockOrBurnOutV1 is one dynamic tuple, not two top-level bytes outputs.
        output = decoded('x()((bytes,bytes))', f.rpc('eth_call', {'from':ramp,'to':pool,'data':data}, 'latest'))[0]
        f.send(ramp, pool, data=data)
        return output[1]
    def release(f, t, pool, router, selector, source, data):
        f.send(offramp(f,router,selector), pool,
               'releaseOrMint((bytes,uint64,address,uint256,address,bytes,bytes,bytes))',
               f'({word(holder)},{selector},{holder},{amount},{t},{word(source)},{data},0x)')
    checks = []
    for lane in baseline['lanes']:
        remote, info = forks[lane['slug']], lane['chain']
        snapshots = [(f, f.rpc('evm_snapshot')) for f in [l1, remote]]
        try:
            selected = l1.call(hub, 'getLockBox(uint64)(address)', info['selector'])
            balances = {b:balance(l1,token,b) for b in boxes}
            initial_holder = balance(l1,token,holder)
            initial_remote_holder = balance(remote,lane['token'],holder)
            initial_supply = supply(remote,lane['token'])
            assert remote.call(lane['pool'],'getRemotePools(uint64)(bytes[])',l1_selector) == [word(hub)]
            data = lock(l1,token,hub,c1['ccip']['router'],info['selector'])
            for b,before in balances.items():
                assert balance(l1,token,b) == before + (amount if b.lower()==selected.lower() else 0)
            release(remote,lane['token'],lane['pool'],info['router'],l1_selector,hub,data)
            assert supply(remote,lane['token']) == initial_supply+amount
            assert balance(remote,lane['token'],holder) == initial_remote_holder+amount
            data = lock(remote,lane['token'],lane['pool'],info['router'],l1_selector)
            assert supply(remote,lane['token']) == initial_supply
            assert balance(remote,lane['token'],holder) == initial_remote_holder
            release(l1,token,hub,c1['ccip']['router'],info['selector'],lane['pool'],data)
            assert balance(l1,token,holder) == initial_holder
            assert {b:balance(l1,token,b) for b in boxes} == balances
            checks.append({'lane':lane['slug'],'result':'passed','amount':str(amount)})
            print('PASS post-migration pool round trip: '+lane['slug'],flush=True)
        finally:
            for f,snapshot in snapshots:
                if not f.rpc('evm_revert',snapshot):
                    raise RuntimeError(f.slug+': failed to restore test snapshot')
    write(STATE/'existing-lane-tests.json', {'checks':checks,'transactions':TXS,
        'scope':'Real pool calls on separate local forks; registered ramps impersonated; transactions reverted after checks; no DON.'})


if __name__ == '__main__':
    {'deploy': deploy, 'connect': connect, 'verify': verify_baseline, 'test-transfers': test_transfers}[sys.argv[1]]()

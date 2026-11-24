"""Check stock upstream deployment/configuration/handover on every scratch network."""
import os
from bootstrap.rpc import Fork, read, write


def check_scratch(run, definition):
    result = {}
    for network in [definition['networks']['l1'], *definition['networks']['l2s']]:
        name = network['slug']
        cfg = read(run / 'config/chains' / (name + '.json'))
        fork = Fork(name, os.environ['RPC_' + name.upper()], network['chainId'])
        deployed, governance = cfg['deployed'], cfg['governance_addresses']
        token = deployed.get('token') or cfg['addresses']['token']
        timelock, pool = deployed['timelock'], deployed['token_pool']
        owned = [pool, deployed['advanced_pool_hooks'], *cfg['ccv'].values(),
                 *{b['lock_box'] for b in deployed['lock_boxes']}]
        owners = {address: fork.call(address, 'owner()(address)') for address in owned}
        if any(owner.lower() != timelock.lower() for owner in owners.values()):
            raise ValueError(name + ': stock ownership handover incomplete')
        registry = fork.call(cfg['ccip']['token_admin_registry'], 'getTokenConfig(address)((address,address,address))', token)
        if [a.lower() for a in registry] != [timelock.lower(), '0x' + '0' * 40, pool.lower()]:
            raise ValueError(name + ': stock TAR registration/handover mismatch')
        roles = {}
        expected = {
            'ADMIN_ROLE': {governance['lido_dao_agent']},
            'PROPOSER_ROLE': {governance['chainlink_mcms']},
            'EXECUTOR_ROLE': {deployed['call_proxy']},
            'CANCELLER_ROLE': {governance['emergency_brakes'], governance['chainlink_mcms']},
            'BYPASSER_ROLE': set(),
            'PROPOSAL_QUEUE_HALT_ROLE': {governance['emergency_brakes']},
        }
        for role, members in expected.items():
            role_id = fork.call(timelock, role + '()(bytes32)')
            count = int(fork.call(timelock, 'getRoleMemberCount(bytes32)(uint256)', role_id))
            actual = [fork.call(timelock, 'getRoleMember(bytes32,uint256)(address)', role_id, i) for i in range(count)]
            if {a.lower() for a in actual} != {a.lower() for a in members}:
                raise ValueError(name + ': unexpected ' + role + ' members: ' + str(actual))
            roles[role] = actual
        token_roles = {}
        if deployed.get('token'):
            for role in ('MINTER_ROLE', 'BURNER_ROLE'):
                role_id = fork.call(token, role + '()(bytes32)')
                if not fork.call(token, 'hasRole(bytes32,address)(bool)', role_id, pool):
                    raise ValueError(name + ': pool token role missing: ' + role)
                token_roles[role] = pool
            admin = '0x' + '0' * 64
            if not fork.call(token, 'hasRole(bytes32,address)(bool)', admin, governance['lido_dao_agent']):
                raise ValueError(name + ': DAO token admin missing')
            if fork.call(token, 'hasRole(bytes32,address)(bool)', admin, governance['deployer']):
                raise ValueError(name + ': deployer token admin retained')
            if fork.call(deployed['token_proxy_admin'], 'owner()(address)').lower() != governance['lido_dao_agent'].lower():
                raise ValueError(name + ': token ProxyAdmin owner mismatch')
        result[name] = {'status': 'passed', 'owners': owners, 'registry': registry, 'roles': roles, 'tokenRoles': token_roles}
    write(run / 'state/scratch-stock-checks.json', result)
    return result

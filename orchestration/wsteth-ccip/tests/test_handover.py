"""Exercise what step 07 keeps around the component's 3_SetPoolAndTransferOwnership, at its RPC
boundary with faked tools: accepting a registry administration another administrator left pending
for the LidoTimelock (in-place targets), and not replaying the component's hand-over on a chain it
already finished. Also the explorer-verification guards of step 10 on the token proxy."""
import json
import os
from pathlib import Path
import subprocess

import pytest


SCRIPT = Path(__file__).parents[1] / 'script/07_set_pool_gov.sh'
PROXY_HELPERS = Path(__file__).parents[1] / 'script/_proxy.sh'
PROXY_ADMIN_CONTRACT = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'  # the ProxyAdmin of a transparent proxy


def functions(*names):
    source = SCRIPT.read_text()
    out = ''
    for name in names:
        start = source.index(f'{name}() {{')
        out += source[start:source.index('\n}\n', start) + 3]
    return out


HARNESS = r'''
set -euo pipefail
DEPLOYER=deployer
DEPLOYER_PRIVATE_KEY=key
eq() { [ "$1" = "$2" ]; }
read_tar_config() { TAR_ADMIN="$ADMIN"; TAR_PENDING="$PENDING"; TAR_POOL="$BOUND"; }
cast() {
    case "$1" in
      calldata) echo "calldata:$2:${3:-}:${4:-}" ;;
      call)
        case "$3" in
          'ADMIN_ROLE()(bytes32)') echo admin-role ;;
          'hasRole(bytes32,address)(bool)')
            if [ "$5" = deployer ]; then echo "${DEPLOYER_IS_ADMIN:-true}"; else echo "${DAO_IS_ADMIN:-false}"; fi ;;
          *) echo "unexpected call $3" >&2; return 99 ;;
        esac ;;
      send)
        echo "$2 $3 $4" >> sends
        # The batch leaves the registry in the end state the function re-reads.
        ADMIN=timelock; BOUND=pool ;;
      *) return 99 ;;
    esac
}
'''


def run_accept(tmp_path, env):
    return subprocess.run(['bash', '-c', HARNESS + functions('accept_pending_tar_admin') +
                           '\naccept_pending_tar_admin chain tar token pool timelock rpc'],
                          cwd=tmp_path, env=dict(os.environ, **env), text=True, capture_output=True)


def sends(tmp_path):
    path = tmp_path / 'sends'
    return path.read_text() if path.exists() else ''


def test_pending_for_timelock_is_accepted_and_pool_bound_in_one_bypass_batch(tmp_path):
    result = run_accept(tmp_path, {'ADMIN': 'other', 'PENDING': 'timelock', 'BOUND': 'none'})
    assert result.returncode == 0, result.stdout + result.stderr
    batch = sends(tmp_path)
    assert batch.count('\n') == 1
    assert batch.startswith('timelock bypasserExecuteBatch')
    assert 'acceptAdminRole(address):token' in batch and 'setPool(address,address):token:pool' in batch
    assert 'timelock timelock administers token; pool pool bound' in result.stdout


def test_timelock_already_administering_only_binds_the_pool(tmp_path):
    result = run_accept(tmp_path, {'ADMIN': 'timelock', 'PENDING': 'none', 'BOUND': 'old-pool'})
    assert result.returncode == 0, result.stdout + result.stderr
    batch = sends(tmp_path)
    assert 'setPool(address,address):token:pool' in batch and 'acceptAdminRole' not in batch


def test_finished_registration_sends_nothing(tmp_path):
    result = run_accept(tmp_path, {'ADMIN': 'timelock', 'PENDING': 'none', 'BOUND': 'pool'})
    assert result.returncode == 0, result.stdout + result.stderr
    assert sends(tmp_path) == ''
    assert 'already administers' in result.stdout


def test_nothing_pending_for_the_timelock_is_left_to_the_component(tmp_path):
    result = run_accept(tmp_path, {'ADMIN': 'none', 'PENDING': 'deployer', 'BOUND': 'none'})
    assert result.returncode == 0, result.stdout + result.stderr
    assert sends(tmp_path) == ''
    assert 'nothing to accept' in result.stdout


def test_deployer_without_timelock_admin_cannot_accept(tmp_path):
    result = run_accept(tmp_path, {'ADMIN': 'other', 'PENDING': 'timelock', 'BOUND': 'none', 'DEPLOYER_IS_ADMIN': 'false'})
    assert result.returncode != 0
    assert sends(tmp_path) == ''
    assert 'no longer holds the timelock ADMIN_ROLE' in result.stdout


@pytest.mark.parametrize('dao_admin,deployer_admin,expected', [
    ('true', 'false', 'skipped'),   # the component already handed the timelock over
    ('false', 'true', 'ran'),       # fresh deployment
    ('true', 'true', 'ran'),        # mid-hand-over: let the component's preflight decide
])
def test_component_handover_is_not_replayed_on_a_finished_chain(tmp_path, dao_admin, deployer_admin, expected):
    harness = HARNESS + 'run_ccip_script() { echo "RAN $1 $3"; }\n'
    result = subprocess.run(['bash', '-c', harness + functions('timelock_handed_over', 'run_set_pool') +
                             '\nrun_set_pool chain rpc timelock dao'],
                            cwd=tmp_path, env=dict(os.environ, DAO_IS_ADMIN=dao_admin, DEPLOYER_IS_ADMIN=deployer_admin),
                            text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert ('RAN chain 3_SetPoolAndTransferOwnership.s.sol:SetPoolAndTransferOwnershipScript' in result.stdout) == (expected == 'ran')
    assert ('already handed to dao' in result.stdout) == (expected == 'skipped')


# ── step 10: the token proxy must be readable and match the record before anything is verified ──

def prepare_verify(tmp_path, *, proxy_admin=PROXY_ADMIN_CONTRACT, proxy_admin_owner='l2-dao'):
    scripts = tmp_path / 'script'
    scripts.mkdir()
    (tmp_path / 'config/chains').mkdir(parents=True)
    for chain in ('sepolia', 'mantle_sepolia'):
        (tmp_path / f'config/chains/{chain}.json').write_text(json.dumps(
            {'addresses': {'token': 'token'}, 'deployed': {'token_pool': 'pool'}, 'ccip': {}}))
    source = SCRIPT.parent / '10_verify_contracts.sh'
    (scripts / source.name).write_text(source.read_text())
    (scripts / '_common.sh').write_text(r'''
L1_RPC=l1
DEPLOYER_ADDRESS=deployer
L2_RPC=l2
L2_CHAIN=mantle_sepolia
L2_CHAIN_ID=5003
L2_RPC_VAR=RPC_MANTLE_SEPOLIA
L2_STATE_FILE=state/mantle_sepolia.json
L2_CFG_CANON=config/chains/mantle_sepolia.json
CFG_DIR="${ROOT}/config/chains"
CCIP_EVM=unused
CORE_DIR=unused
RECORD_DIR=config/chains
eq() { [ "$1" = "$2" ]; }
is_anvil() { return 1; }
curl() { echo '{"status":"1"}'; }
sleep() { :; }
has_code() { case "$1" in 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|l2-dao) return 0 ;; *) return 1 ;; esac; }
cast() {
    local operation="$1" target="$2" selector="${3:-}"
    if [ "$operation" = admin ]; then
        cat proxy-admin
    elif [ "$operation" = code ]; then
        case "$target" in 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|l2-dao) echo 0x1234 ;; *) echo 0x ;; esac
    elif [ "$operation" = call ]; then
        case "$selector" in
          'proxy__getAdmin()(address)')
            [ ! -f proxy-owner ] || { echo 'VM execution error' >&2; return 3; }
            cat proxy-admin ;;
          'owner()(address)')
            # owner probe
            [ "$target" = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] && [ -f proxy-owner ] || { echo 'execution reverted' >&2; return 3; }
            cat proxy-owner ;;
          *) echo "Unexpected call: $selector" >&2; return 99 ;;
        esac
    else return 99; fi
}
''' + f'\n. "{PROXY_HELPERS}"\n')
    (tmp_path / 'state').mkdir()
    (tmp_path / 'state/mantle_sepolia.json').write_text(json.dumps(
        {'wstETH': 'l2-token', 'opExec': 'l2-dao', 'wstETHProxyAdmin': proxy_admin}))
    (tmp_path / 'proxy-admin').write_text(proxy_admin + '\n')
    if proxy_admin_owner is not None:
        (tmp_path / 'proxy-owner').write_text(proxy_admin_owner + '\n')
    env = dict(os.environ, DEPLOYER_PRIVATE_KEY='dummy-test-key', WSTETH_SKIP_L1='1', ETHERSCAN_API_KEY='fake')
    return ['bash', str(scripts / source.name)], env


@pytest.mark.parametrize('failure', ['rpc', 'empty', 'code', 'owner', 'revert', 'pin'])
def test_explorer_verification_fails_instead_of_skipping_unreadable_proxy(tmp_path, failure):
    command, env = prepare_verify(tmp_path)
    if failure == 'pin':
        (tmp_path / 'state/mantle_sepolia.json').write_text(json.dumps(
            {'wstETH': 'l2-token', 'opExec': 'l2-dao', 'wstETHProxyAdmin': 'wrong-admin'}))
    elif failure == 'rpc':
        (tmp_path / 'proxy-admin').unlink()  # cast admin fails
    elif failure == 'empty':
        (tmp_path / 'proxy-admin').write_text('0x' + '0' * 40)
    elif failure in ('code', 'owner'):
        common = tmp_path / 'script/_common.sh'
        content = common.read_text()
        trigger = 'case "$target" in 0xaaaa' if failure == 'code' else '# owner probe'
        content = content.replace(trigger, 'echo "RPC timeout" >&2; return 1\n' + trigger, 1)
        common.write_text(content)
    elif failure == 'revert':
        (tmp_path / 'proxy-owner').unlink()
    result = subprocess.run(command, env=env, cwd=tmp_path, text=True, capture_output=True)
    assert result.returncode != 0
    assert 'legacy OssifiableProxy deployment' not in result.stdout
    assert ('Cannot read proxy admin' if failure in ('rpc', 'code', 'owner') else 'EIP-1967 admin slot is empty' if failure == 'empty' else 'recorded') in result.stdout + result.stderr


def test_legacy_verification_summary_does_not_claim_skipped_sources_verified():
    source = (SCRIPT.parent / '10_verify_contracts.sh').read_text()
    branch = source.split('        legacy)\n', 1)[1].split('            ;;', 1)[0]
    summary = next(line for line in source.splitlines() if line.startswith('echo "verification:'))
    result = subprocess.run(['bash', '-euc', '''
SUBMITTED=0 SKIPPED=0 NOT_ATTEMPTED=0 FAILED=0
L2_TOKEN_PROXY_KIND=legacy
''' + branch + '\n' + summary], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert '0 already verified, 2 not attempted, 0 failed' in result.stdout

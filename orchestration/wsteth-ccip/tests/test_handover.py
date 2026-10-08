"""Exercise step 07 record selection, interrupted-run recovery and the L2 proxy-admin end state at
its RPC boundary. All signing and RPC tools are faked; the real step 07 ordering, record reads and
the real proxy-admin helpers (script/_proxy.sh) run."""
import json
import os
from pathlib import Path
import subprocess

import pytest


SCRIPT = Path(__file__).parents[1] / 'script/07_set_pool_gov.sh'
PROXY_HELPERS = Path(__file__).parents[1] / 'script/_proxy.sh'

PROXY_ADMIN_CONTRACT = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'  # the ProxyAdmin of a transparent proxy


def prepare(tmp_path, absolute_record, *, proxy_admin=PROXY_ADMIN_CONTRACT, proxy_admin_owner='l2-dao'):
    """Lay out records, the faked tool layer and the chain-state files; return (command, env)."""
    scripts = tmp_path / 'script'
    scripts.mkdir()
    canonical = tmp_path / 'config/chains'
    canonical.mkdir(parents=True)
    alternate = tmp_path / 'other-record'
    alternate.mkdir()
    for chain, token, dao in [('sepolia', 'l1-token', 'l1-dao'),
                              ('mantle_sepolia', 'l2-token', 'l2-dao')]:
        record = {'addresses': {'token': token}, 'deployed': {'token_pool': 'pool'},
                  'ccip': {'token_admin_registry': 'tar', 'registry_module_owner': 'module'},
                  'governance_addresses': {'lido_dao_agent': dao}}
        (canonical / f'{chain}.json').write_text(json.dumps(record))
        record['governance_addresses']['lido_dao_agent'] = 'wrong-dao'
        (alternate / f'{chain}.json').write_text(json.dumps(record))
    (scripts / SCRIPT.name).write_text(SCRIPT.read_text())
    # Persistent files model chain state between invocations:
    #   ccip-admin     the TAR/token CCIP admin         proxy-admin  what the EIP-1967 admin slot holds
    #   token-dao      OpExec holds DEFAULT_ADMIN_ROLE  proxy-owner  ProxyAdmin.owner(); absent = the
    #   token-revoked  deployer's role revoked                       admin answers no owner() (legacy)
    (scripts / '_common.sh').write_text(r'''
L1_RPC=l1
DEPLOYER_ADDRESS=deployer
L2_RPC=l2
L2_CHAIN=mantle_sepolia
L2_STATE_FILE=state/mantle_sepolia.json
L2_CFG_CANON=config/chains/mantle_sepolia.json
CFG_DIR="${ROOT}/config/chains"
eq() { [ "$1" = "$2" ]; }
assert_l2_state_chain() { :; }
# Only contract-shaped admins have code: the fake ProxyAdmin and the L2 DAO executor.
has_code() { case "$1" in 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|l2-dao) return 0 ;; *) return 1 ;; esac; }
cast() {
    if [ "$1" = wallet ]; then echo deployer; return; fi
    local operation="$1" target="$2" selector="$3"
    if [ "$operation" = admin ]; then
        cat proxy-admin
    elif [ "$operation" = code ]; then
        case "$target" in 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|l2-dao) echo 0x1234 ;; *) echo 0x ;; esac
    elif [ "$operation" = call ]; then
        case "$selector" in
          'proxy__getAdmin()(address)')
            [ ! -f proxy-owner ] || { echo 'VM execution error' >&2; return 3; }
            cat proxy-admin ;;
          'MINTER_ROLE()(bytes32)') echo minter ;;
          'BURNER_ROLE()(bytes32)') echo burner ;;
          'getTokenConfig(address)((address,address,address))')
            echo '0x1111111111111111111111111111111111111111 0x0000000000000000000000000000000000000000 0x2222222222222222222222222222222222222222' ;;
          'getCCIPAdmin()(address)') cat ccip-admin ;;
          'hasRole(bytes32,address)(bool)')
            if [ "$5" = l2-dao ]; then [ -f token-dao ] && echo true || echo false
            elif [ "$5" = deployer ]; then [ -f token-revoked ] && echo false || echo true
            else echo true; fi ;;
          'owner()(address)')
            # Only a ProxyAdmin answers owner(); a legacy admin (OpExec or an EOA) reverts.
            [ "$target" = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] && [ -f proxy-owner ] || { echo 'execution reverted' >&2; return 3; }
            cat proxy-owner ;;
          *) echo "Unexpected call: $selector" >&2; return 99 ;;
        esac
    elif [ "$operation" = send ]; then
        echo "$target $selector $4" >> sends
        case "$selector" in
          'setCCIPAdmin(address)') [ "$4" = l1-dao ] || return 90; echo "$4" > ccip-admin ;;
          'grantRole(bytes32,address)') touch token-dao ;;
          'revokeRole(bytes32,address)') touch token-revoked ;;
          'proxy__changeAdmin(address)') echo "$4" > proxy-admin ;;
          *) echo "Unexpected send: $selector" >&2; return 99 ;;
        esac
    else return 99; fi
}
run_ccip_script() {
    # Both POM handovers must follow the explicit L1 custom-token handover.
    [ "$(cat ccip-admin)" = l1-dao ] || return 91
    if [ "$1" = mantle_sepolia ] && [ ! -f interrupted ]; then
        touch interrupted
        return 42
    fi
    touch "pom-$1"
}
''' + f'\n. "{PROXY_HELPERS}"\n')
    (tmp_path / 'state').mkdir()
    (tmp_path / 'state/mantle_sepolia.json').write_text(json.dumps(
        {'wstETHProxyAdmin': PROXY_ADMIN_CONTRACT} if proxy_admin_owner is not None else {}))
    (tmp_path / 'ccip-admin').write_text('deployer\n')
    (tmp_path / 'proxy-admin').write_text(proxy_admin + '\n')
    if proxy_admin_owner is not None:
        (tmp_path / 'proxy-owner').write_text(proxy_admin_owner + '\n')
    env = dict(os.environ, DEPLOYER_PRIVATE_KEY='dummy-test-key',
               RECORD_DIR=str(alternate) if absolute_record else 'other-record')
    return ['bash', str(scripts / SCRIPT.name)], env


def run(command, env):
    return subprocess.run(command, env=env, text=True, capture_output=True)


@pytest.mark.parametrize('absolute_record', [False, True])
def test_canonical_recipient_and_retry_after_l2_failure(tmp_path, absolute_record):
    command, env = prepare(tmp_path, absolute_record)
    first = run(command, env)
    assert first.returncode == 42, first.stdout + first.stderr
    assert (tmp_path / 'ccip-admin').read_text().strip() == 'l1-dao'
    assert (tmp_path / 'pom-sepolia').exists()
    second = run(command, env)
    assert second.returncode == 0, second.stdout + second.stderr
    assert (tmp_path / 'pom-mantle_sepolia').exists()
    assert 'ProxyAdmin 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa owned by l2-dao' in second.stdout
    sends = (tmp_path / 'sends').read_text()
    third = run(command, env)
    assert third.returncode == 0, third.stdout + third.stderr
    assert (tmp_path / 'sends').read_text() == sends
    assert sends.count('setCCIPAdmin(address)') == 1
    assert 'proxy__changeAdmin' not in sends
    assert 'wrong-dao' not in sends


def test_proxy_admin_owned_by_someone_else_aborts_before_revoking_deployer(tmp_path):
    command, env = prepare(tmp_path, False, proxy_admin_owner='0x5e1f000000000000000000000000000000000000')
    run(command, env)  # interrupted L2 POM handover, as above
    result = run(command, env)
    assert result.returncode == 1, result.stdout + result.stderr
    assert 'is owned by 0x5e1f000000000000000000000000000000000000, expected l2-dao' in result.stdout
    # The deployer must keep DEFAULT_ADMIN_ROLE while the upgrade right is in the wrong hands.
    assert 'revokeRole' not in (tmp_path / 'sends').read_text()
    assert not (tmp_path / 'token-revoked').exists()


def test_legacy_ossifiable_proxy_admin_is_handed_to_opexec(tmp_path):
    # A run from before 2026-10-08: the admin slot holds the deployer EOA, which answers no owner().
    command, env = prepare(tmp_path, False, proxy_admin='deployer', proxy_admin_owner=None)
    run(command, env)
    result = run(command, env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'legacy OssifiableProxy admin -> OpExec' in result.stdout
    assert (tmp_path / 'proxy-admin').read_text().strip() == 'l2-dao'
    sends = (tmp_path / 'sends').read_text()
    assert sends.count('proxy__changeAdmin(address)') == 1
    assert sends.index('proxy__changeAdmin(address)') < sends.index('revokeRole(bytes32,address)')
    # Re-run: the admin is OpExec now (a legacy admin that has code but no owner()), so no second handover.
    again = run(command, env)
    assert again.returncode == 0, again.stdout + again.stderr
    assert 'legacy OssifiableProxy administered directly by l2-dao' in again.stdout
    assert (tmp_path / 'sends').read_text().count('proxy__changeAdmin(address)') == 1


def test_legacy_proxy_held_by_a_stranger_aborts(tmp_path):
    command, env = prepare(tmp_path, False, proxy_admin='0x57ra00000000000000000000000000000000ffff', proxy_admin_owner=None)
    run(command, env)
    result = run(command, env)
    assert result.returncode == 1, result.stdout + result.stderr
    assert 'legacy OssifiableProxy admin is 0x57ra00000000000000000000000000000000ffff, expected l2-dao' in result.stdout
    assert 'revokeRole' not in (tmp_path / 'sends').read_text()


@pytest.mark.parametrize('pin', ['', '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'])
def test_ownable_admin_with_unrecorded_identity_cannot_revoke_deployer(tmp_path, pin):
    command, env = prepare(tmp_path, False)
    (tmp_path / 'state/mantle_sepolia.json').write_text(json.dumps({'wstETHProxyAdmin': pin}))
    run(command, env)
    result = run(command, env)
    assert result.returncode != 0
    assert ('differs from recorded wstETHProxyAdmin' if pin else 'restore its recorded wstETHProxyAdmin') in result.stdout + result.stderr
    assert not (tmp_path / 'token-revoked').exists()


def test_later_spoke_does_not_repeat_hub_handover(tmp_path):
    command, env = prepare(tmp_path, False)
    (tmp_path / 'ccip-admin').write_text('l1-dao\n')
    (tmp_path / 'interrupted').touch()
    result = run(command, dict(env, WSTETH_SKIP_L1='1'))
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (tmp_path / 'pom-sepolia').exists()
    assert (tmp_path / 'pom-mantle_sepolia').exists()
    assert 'setCCIPAdmin' not in (tmp_path / 'sends').read_text()


def test_fresh_token_records_proxy_admin_before_checking_it(tmp_path):
    _, env = prepare(tmp_path, False)
    state = tmp_path / 'state/mantle_sepolia.json'
    state.write_text('{"opExec":"l2-dao"}')
    source = (SCRIPT.parent / '03_l2_token.sh').read_text()
    assertion = 'assert_proxy_admin() {' + source.split('assert_proxy_admin() {', 1)[1].split('\n}', 1)[0] + '\n}\n'
    # Run the actual fresh-deployment tail and proxy assertion, faking only deployment/RPC tools
    # and unrelated token-shape checks. This catches checking a pin before CREATE outputs are saved.
    fresh_tail = source[source.index('echo "▸ deploying L2 wstETH'):]
    harness = '''
set -euo pipefail
ROOT="$1"
cd "$ROOT"
. script/_common.sh
jq_inplace() { local file="$1"; shift; jq "$@" "$file" > "$file.next"; mv "$file.next" "$file"; }
forge() { if [ "$1" = script ]; then echo 'l2-token implementation 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$TOKEN_OUT"; fi; }
assert_token_shape() { assert_proxy_admin "$1"; }
'''
    result = run(['bash', '-c', harness + assertion + fresh_tail, 'test', str(tmp_path)], env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(state.read_text())['wstETHProxyAdmin'] == PROXY_ADMIN_CONTRACT


@pytest.mark.parametrize('failure', ['rpc', 'empty', 'code', 'owner', 'revert', 'pin'])
def test_explorer_verification_fails_instead_of_skipping_unreadable_proxy(tmp_path, failure):
    command, env = prepare(tmp_path, False)
    source = SCRIPT.parent / '10_verify_contracts.sh'
    target = tmp_path / 'script' / source.name
    target.write_text(source.read_text())
    (tmp_path / 'state/mantle_sepolia.json').write_text(json.dumps({'wstETH': 'l2-token', 'opExec': 'l2-dao', 'wstETHProxyAdmin': PROXY_ADMIN_CONTRACT if failure != 'pin' else 'wrong-admin'}))
    if failure == 'rpc':
        (tmp_path / 'proxy-admin').unlink()  # cast admin fails
    elif failure == 'empty':
        (tmp_path / 'proxy-admin').write_text('0x' + '0' * 40)
    elif failure in ('code', 'owner'):
        common = tmp_path / 'script/_common.sh'
        content = common.read_text()
        trigger = 'case "$target" in' if failure == 'code' else '# Only a ProxyAdmin answers owner();'
        content = content.replace(trigger, 'echo "RPC timeout" >&2; return 1\n' + trigger)
        common.write_text(content)
    elif failure == 'revert':
        (tmp_path / 'proxy-owner').unlink()
    with (tmp_path / 'script/_common.sh').open('a') as f:
        f.write('''
L2_CHAIN_ID=5003
L2_RPC_VAR=RPC_MANTLE_SEPOLIA
CCIP_EVM=unused
CORE_DIR=unused
is_anvil() { return 1; }
curl() { echo '{"status":"1"}'; }
sleep() { :; }
''')
    result = run(['bash', str(target)], dict(env, WSTETH_SKIP_L1='1', ETHERSCAN_API_KEY='fake'))
    assert result.returncode != 0
    assert 'legacy OssifiableProxy deployment' not in result.stdout
    assert ('Cannot read proxy admin' if failure in ('rpc', 'code', 'owner') else 'EIP-1967 admin slot is empty' if failure == 'empty' else 'recorded') in result.stdout + result.stderr


def test_legacy_verification_summary_does_not_claim_skipped_sources_verified(tmp_path):
    source = (SCRIPT.parent / '10_verify_contracts.sh').read_text()
    branch = source.split('        legacy)\n', 1)[1].split('            ;;', 1)[0]
    summary = next(line for line in source.splitlines() if line.startswith('echo "verification:'))
    result = subprocess.run(['bash', '-euc', '''
SUBMITTED=0 SKIPPED=0 NOT_ATTEMPTED=0 FAILED=0
L2_TOKEN_PROXY_KIND=legacy
''' + branch + '\n' + summary], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert '0 already verified, 2 not attempted, 0 failed' in result.stdout

"""Exercise step 07 record selection and interrupted-run recovery at its RPC boundary."""
import json
import os
from pathlib import Path
import subprocess

import pytest


SCRIPT = Path(__file__).parents[1] / 'script/07_set_pool_gov.sh'


@pytest.mark.parametrize('absolute_record', [False, True])
def test_canonical_recipient_and_retry_after_l2_failure(tmp_path, absolute_record):
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
    # Persistent files model chain state between invocations. All signing and RPC
    # tools are replaced; real script ordering and record reads remain intact.
    (scripts / '_common.sh').write_text(r'''
L1_RPC=l1
L2_RPC=l2
L2_CHAIN=mantle_sepolia
L2_CFG_CANON=config/chains/mantle_sepolia.json
CFG_DIR="${ROOT}/config/chains"
eq() { [ "$1" = "$2" ]; }
assert_l2_state_chain() { :; }
cast() {
    if [ "$1" = wallet ]; then echo deployer; return; fi
    local operation="$1" target="$2" selector="$3"
    if [ "$operation" = call ]; then
        case "$selector" in
          'MINTER_ROLE()(bytes32)') echo minter ;;
          'BURNER_ROLE()(bytes32)') echo burner ;;
          'getTokenConfig(address)((address,address,address))')
            echo '0x1111111111111111111111111111111111111111 0x0000000000000000000000000000000000000000 0x2222222222222222222222222222222222222222' ;;
          'getCCIPAdmin()(address)') cat ccip-admin ;;
          'hasRole(bytes32,address)(bool)')
            if [ "$5" = l2-dao ]; then [ -f token-dao ] && echo true || echo false
            elif [ "$5" = deployer ]; then [ -f token-revoked ] && echo false || echo true
            else echo true; fi ;;
          'proxy__getAdmin()(address)') [ -f proxy-dao ] && echo l2-dao || echo deployer ;;
          *) echo "Unexpected call: $selector" >&2; return 99 ;;
        esac
    elif [ "$operation" = send ]; then
        echo "$target $selector $4" >> sends
        case "$selector" in
          'setCCIPAdmin(address)') [ "$4" = l1-dao ] || return 90; echo "$4" > ccip-admin ;;
          'grantRole(bytes32,address)') touch token-dao ;;
          'revokeRole(bytes32,address)') touch token-revoked ;;
          'proxy__changeAdmin(address)') touch proxy-dao ;;
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
''')
    (tmp_path / 'ccip-admin').write_text('deployer\n')
    env = dict(os.environ, DEPLOYER_PRIVATE_KEY='dummy-test-key',
               RECORD_DIR=str(alternate) if absolute_record else 'other-record')
    command = ['bash', str(scripts / SCRIPT.name)]
    first = subprocess.run(command, env=env, text=True, capture_output=True)
    assert first.returncode == 42, first.stdout + first.stderr
    assert (tmp_path / 'ccip-admin').read_text().strip() == 'l1-dao'
    assert (tmp_path / 'pom-sepolia').exists()
    second = subprocess.run(command, env=env, text=True, capture_output=True)
    assert second.returncode == 0, second.stdout + second.stderr
    assert (tmp_path / 'pom-mantle_sepolia').exists()
    sends = (tmp_path / 'sends').read_text()
    third = subprocess.run(command, env=env, text=True, capture_output=True)
    assert third.returncode == 0, third.stdout + third.stderr
    assert (tmp_path / 'sends').read_text() == sends
    assert sends.count('setCCIPAdmin(address)') == 1
    assert 'wrong-dao' not in sends

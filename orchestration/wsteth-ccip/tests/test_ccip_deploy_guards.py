"""Exercise what step 04 keeps around the component's 1_Deploy, with the real jq and a stubbed
adapter: the token side of a record follows the record's shape (token_deployment or an environment
token), and a chain whose record already carries this run's deployment is skipped on a re-run
while a deployment this run never broadcast is refused."""
import json
import os
from pathlib import Path
import subprocess

import pytest

SCRIPT = Path(__file__).parents[1] / 'script/04_ccip_deploy.sh'
ZERO = '0x0000000000000000000000000000000000000000'
AGENT = '0xa9e0000000000000000000000000000000000001'
POOL = '0x9001000000000000000000000000000000000001'
TOKEN = '0x70ce000000000000000000000000000000000001'


def functions():
    source = SCRIPT.read_text()
    return source[source.index('ZERO_ADDRESS='):source.index('\nif [ "${WSTETH_SKIP_L1:-0}" != 1 ]')]


HARNESS = r'''
set -euo pipefail
jq_inplace() { local f="$1"; shift; local tmp; tmp="$(mktemp)"; jq "$@" "${f}" > "${tmp}" && mv "${tmp}" "${f}"; }
run_ccip_script() { echo "deploy $1" >> deploys; }
'''


def layout(tmp_path, record, state):
    (tmp_path / 'config/chains').mkdir(parents=True)
    (tmp_path / 'state').mkdir()
    (tmp_path / 'config/chains/spoke.json').write_text(json.dumps(record))
    (tmp_path / 'state/spoke.json').write_text(json.dumps(state))
    return dict(os.environ, CFG_DIR=str(tmp_path / 'config/chains'))


def deploy(tmp_path, env):
    return subprocess.run(['bash', '-c', HARNESS + functions() + '\ndeploy_chain spoke state/spoke.json rpc'],
                          cwd=tmp_path, env=env, text=True, capture_output=True)


def record_of(tmp_path):
    return json.loads((tmp_path / 'config/chains/spoke.json').read_text())


def deploys(tmp_path):
    path = tmp_path / 'deploys'
    return path.read_text().split() if path.exists() else []


def test_scratch_spoke_keeps_the_zero_token_and_lets_the_component_deploy_it(tmp_path):
    env = layout(tmp_path, {'chain': {'chain_id': 5003}, 'addresses': {'token': ZERO}, 'token_deployment': {'name': 'x'},
                            'governance_addresses': {}}, {'opExec': AGENT})
    result = deploy(tmp_path, env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert record_of(tmp_path)['addresses']['token'] == ZERO
    assert record_of(tmp_path)['governance_addresses']['lido_dao_agent'] == AGENT
    assert deploys(tmp_path) == ['deploy', 'spoke']


def test_state_naming_a_token_for_a_record_that_deploys_one_is_refused(tmp_path):
    env = layout(tmp_path, {'chain': {'chain_id': 5003}, 'addresses': {'token': ZERO}, 'token_deployment': {'name': 'x'},
                            'governance_addresses': {}}, {'opExec': AGENT, 'wstETH': TOKEN})
    result = deploy(tmp_path, env)
    assert result.returncode == 1
    assert 'already names token' in result.stdout
    assert deploys(tmp_path) == []
    assert record_of(tmp_path)['addresses']['token'] == ZERO


def test_environment_token_is_seeded_when_the_record_deploys_none(tmp_path):
    env = layout(tmp_path, {'chain': {'chain_id': 11155111}, 'addresses': {'token': ZERO}, 'governance_addresses': {}},
                 {'agent': AGENT, 'wstETH': TOKEN})
    result = deploy(tmp_path, env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert record_of(tmp_path)['addresses']['token'] == TOKEN
    assert deploys(tmp_path) == ['deploy', 'spoke']


def test_no_token_anywhere_is_refused(tmp_path):
    env = layout(tmp_path, {'chain': {'chain_id': 11155111}, 'addresses': {'token': ZERO}, 'governance_addresses': {}},
                 {'agent': AGENT})
    result = deploy(tmp_path, env)
    assert result.returncode == 1
    assert 'nothing for 1_Deploy to bridge' in result.stdout
    assert deploys(tmp_path) == []


def test_chain_deployed_in_this_run_is_skipped_on_a_rerun(tmp_path):
    env = layout(tmp_path, {'chain': {'chain_id': 5003}, 'addresses': {'token': ZERO}, 'token_deployment': {'name': 'x'},
                            'governance_addresses': {}, 'deployed': {'token_pool': POOL, 'token': TOKEN}},
                 {'opExec': AGENT, 'wstETH': TOKEN})
    receipts = tmp_path / 'broadcast/ccip/1_Deploy.s.sol/5003'
    receipts.mkdir(parents=True)
    (receipts / 'run-latest.json').write_text('{}')
    result = deploy(tmp_path, env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'already done in this run' in result.stdout
    assert deploys(tmp_path) == []


def test_deployment_this_run_did_not_broadcast_is_refused(tmp_path):
    env = layout(tmp_path, {'chain': {'chain_id': 5003}, 'addresses': {'token': ZERO}, 'token_deployment': {'name': 'x'},
                            'governance_addresses': {}, 'deployed': {'token_pool': POOL, 'token': TOKEN}},
                 {'opExec': AGENT, 'wstETH': TOKEN})
    result = deploy(tmp_path, env)
    assert result.returncode == 1
    assert 'did not broadcast' in result.stdout
    assert deploys(tmp_path) == []


@pytest.mark.parametrize('pool', [ZERO, None])
def test_zero_or_absent_pool_counts_as_not_deployed(tmp_path, pool):
    deployed = {'token_pool': pool} if pool else {}
    env = layout(tmp_path, {'chain': {'chain_id': 5003}, 'addresses': {'token': ZERO}, 'token_deployment': {'name': 'x'},
                            'governance_addresses': {}, 'deployed': deployed}, {'opExec': AGENT})
    result = deploy(tmp_path, env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert deploys(tmp_path) == ['deploy', 'spoke']

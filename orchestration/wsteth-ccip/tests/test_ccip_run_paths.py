"""Check the upstream Foundry adapter (run_ccip_script in script/_common.sh) without signing or RPC
access: the component's scripts run from its own project root under its release profile, read and
write this run's records only through the staging directory its fs_permissions admit, leave the
component tree as they found it, and never lose a record the stage alone holds."""
import json
import os
from pathlib import Path
import subprocess

SCRIPTS = Path(__file__).parents[1] / 'script'
STAGE_PARENT = 'contracts/lido-hvmv/config/chains'
STAGE = STAGE_PARENT + '/.wsteth-run.run'  # named after the run directory (`run` in these layouts)


def function_source():
    source = (SCRIPTS / '_common.sh').read_text()
    return source[source.index('CCIP_RUN_STAGE_PARENT_REL='):source.index('# assert_l2_state_chain:')]


def layout(tmp_path, forge_body):
    evm = tmp_path / 'upstream'
    (evm / STAGE_PARENT).mkdir(parents=True)
    (evm / STAGE_PARENT / 'sepolia.json').write_text('component template')
    (evm / 'leftover.json').write_text('other run')
    run = tmp_path / 'run'
    (run / 'config/chains').mkdir(parents=True)
    (run / 'config/chains/sepolia.json').write_text('{"chain": "sepolia"}')
    (run / 'config/chains/mantle_sepolia.json').write_text('{"chain": "mantle_sepolia"}')
    (run / 'config/chains/chain.schema.json').write_text('{"schema": true}')
    operations = tmp_path / 'ops'
    operations.mkdir()
    (operations / 'script').mkdir()
    # The provenance guard has its own real-repository tests; here exercise staging/unwind.
    (operations / 'script/ccip_build.py').write_text('')
    (operations / '.active-run').symlink_to(run)
    harness = 'set -euo pipefail\nforge() {\n' + forge_body + '\n}\n'
    env = dict(os.environ, ROOT=str(operations), RUN=str(run), CCIP_EVM=str(evm),
               CFG_DIR=str(run / 'config/chains'), DEPLOYER_PRIVATE_KEY='unused')
    env.pop('DEFAULT_CONFIG', None)
    return evm, run, harness, env


def invoke(harness, env, chain='sepolia'):
    return subprocess.run(['bash', '-c', harness + function_source() + f'\nrun_ccip_script {chain} rpc-url 1_Deploy.s.sol:DeployScript'],
                          env=env, text=True, capture_output=True)


def stages(evm):
    return sorted(p.name for p in (evm / STAGE_PARENT).iterdir() if p.name.startswith('.wsteth-run'))


def test_ccip_script_runs_in_the_component_with_its_release_profile_on_staged_records(tmp_path):
    evm, run, harness, env = layout(tmp_path, r'''
    [ "$PWD" = "$CCIP_EVM" ]
    [ "$FOUNDRY_PROFILE" = ccip-compile ]
    [ -z "${DEFAULT_CONFIG:-}" ]
    [ "$FOUNDRY_BROADCAST" = "$RUN/broadcast/ccip" ]
    [ "$CHAIN_CONFIG" = ./''' + STAGE + r'''/sepolia.json ]
    [ "$1" = script ] && [ "$2" = contracts/lido-hvmv/script/deployment/1_Deploy.s.sol:DeployScript ]
    [ "$(cat ''' + STAGE + r'''/mantle_sepolia.json)" = '{"chain": "mantle_sepolia"}' ]
    [ ! -e ''' + STAGE + r'''/chain.schema.json ]
    printf '{"deployed":true}' > "$CHAIN_CONFIG"
    ''')
    result = invoke(harness, env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((run / 'config/chains/sepolia.json').read_text()) == {'deployed': True}
    assert (run / 'config/chains/mantle_sepolia.json').read_text() == '{"chain": "mantle_sepolia"}'
    assert (evm / STAGE_PARENT / 'sepolia.json').read_text() == 'component template'
    assert (evm / 'leftover.json').read_text() == 'other run'
    assert stages(evm) == []


def test_failed_script_returns_its_status_and_still_moves_records_back(tmp_path):
    evm, run, harness, env = layout(tmp_path, r'''
    printf '{"partial":true}' > "$CHAIN_CONFIG"
    return 7
    ''')
    result = invoke(harness, env)
    assert result.returncode == 7, result.stdout + result.stderr
    assert json.loads((run / 'config/chains/sepolia.json').read_text()) == {'partial': True}
    assert stages(evm) == []


def test_controlled_profile_is_staged_and_archived_without_changing_upstream(tmp_path):
    evm, run, harness, env = layout(tmp_path, r'''
    [ "$DEFAULT_CONFIG" = ./''' + STAGE + r'''/profile/default_config.json ]
    [ "$(cat "$DEFAULT_CONFIG")" = '{"controlled":true}' ]
    ''')
    source = evm / 'contracts/lido-hvmv/config/default_config.json'
    source.write_text('{"upstream":true}')
    (run / 'state').mkdir()
    env['WSTETH_ACCESS_PROFILE'] = str(tmp_path / 'profile.json')
    # Parameter transformation has node tests; this tests the real shell adapter's isolation.
    harness += 'node() { printf \'{"controlled":true}\' > "$4"; }\n'
    result = invoke(harness, env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert source.read_text() == '{"upstream":true}'
    assert json.loads((run / 'state/ccip-default-config.json').read_text()) == {'controlled': True}
    assert not (run / 'config/chains/default_config.json').exists()
    assert stages(evm) == []


def test_interrupted_call_moves_the_written_record_back_before_dying(tmp_path):
    # The script has written the record (1_Deploy does so after its broadcast) when the operator's
    # Ctrl-C reaches the shell: the record must still land in the run.
    evm, run, harness, env = layout(tmp_path, r'''
    printf '{"written":true}' > "$CHAIN_CONFIG"
    kill -INT $$
    ''')
    result = invoke(harness, env)
    assert result.returncode == 130, result.stdout + result.stderr
    assert json.loads((run / 'config/chains/sepolia.json').read_text()) == {'written': True}
    assert stages(evm) == []


def test_stage_left_by_a_dead_call_is_reported_and_kept(tmp_path):
    evm, run, harness, env = layout(tmp_path, r'''
    echo "forge must not run" >&2; exit 99
    ''')
    stage = evm / STAGE_PARENT / '.wsteth-run.older'
    stage.mkdir()
    (stage / 'sepolia.json').write_text('{"deployed": "elsewhere"}')
    result = invoke(harness, env)
    assert result.returncode == 1, result.stdout + result.stderr
    assert 'did not finish' in result.stdout
    assert (stage / 'sepolia.json').read_text() == '{"deployed": "elsewhere"}'
    assert (run / 'config/chains/sepolia.json').read_text() == '{"chain": "sepolia"}'

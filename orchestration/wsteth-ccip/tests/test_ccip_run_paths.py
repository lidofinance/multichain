"""Check the upstream Foundry adapter without signing or RPC access."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

SCRIPTS = Path(__file__).parents[1] / 'script'
SPEC = importlib.util.spec_from_file_location('ccip_config', SCRIPTS / 'ccip-run-config.py')
config = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(config)


def test_foundry_resolves_run_profile(tmp_path):
    if not shutil.which('forge'):
        pytest.skip('forge not installed')
    evm = tmp_path / 'upstream'
    evm.mkdir()
    original = '[profile.default]\nsrc = "contracts"\noptimizer = true\n'
    (evm / 'foundry.toml').write_text(original)
    run = tmp_path / 'run'
    path = config.write_config(evm, run)
    result = subprocess.run(['forge', 'config', '--root', str(evm), '--config-path', str(path), '--json'],
                            env=dict(os.environ, FOUNDRY_PROFILE='wsteth_run'), capture_output=True, text=True, check=True)
    resolved = json.loads(result.stdout)
    assert Path(resolved['src']) == evm / 'contracts'
    assert resolved['optimizer'] is True
    assert Path(resolved['broadcast']) == run / 'broadcast/ccip'
    assert Path(resolved['cache_path']) == run / 'state/ccip/cache'
    assert resolved['fs_permissions'] == [{'access': True, 'path': str(run / 'config')}]
    assert (evm / 'foundry.toml').read_text() == original


def test_ccip_script_consumes_only_current_run_records(tmp_path):
    if not shutil.which('forge'):
        pytest.skip('forge not installed')
    evm = tmp_path / 'upstream'
    evm.mkdir()
    (evm / 'foundry.toml').write_text('[profile.default]\n')
    (evm / 'leftover.json').write_text('other run')
    run = tmp_path / 'run'
    (run / 'config/chains').mkdir(parents=True)
    (run / 'config/chains/sepolia.json').write_text('{}')
    (run / 'config/default_config.json').write_text('{}')
    operations = tmp_path / 'ops'
    operations.mkdir()
    (operations / '.active-run').symlink_to(run)
    (operations / 'config').symlink_to(run / 'config')
    (operations / 'script').symlink_to(SCRIPTS)
    source = (SCRIPTS / '_common.sh').read_text()
    function = source[source.index('run_ccip_script() {'):source.index('# assert_l2_state_chain:')]
    harness = r'''
set -euo pipefail
is_l1_chain() { return 0; }
forge() {
    [ "$CHAIN_CONFIG" = "$RUN/config/chains/sepolia.json" ]
    [ "$DEFAULT_CONFIG" = "$RUN/config/default_config.json" ]
    [ "$FOUNDRY_PROFILE" = wsteth_run ]
    [ "$PWD" = "$CCIP_EVM" ]
    printf '{"deployed":true}' > "$CHAIN_CONFIG"
}
'''
    result = subprocess.run(['bash', '-c', harness + function + '\nrun_ccip_script sepolia unused 1_Deploy.s.sol:DeployScript'],
                            env=dict(os.environ, ROOT=str(operations), RUN=str(run), CCIP_EVM=str(evm),
                                     CFG_DIR=str(run / 'config/chains'), DEPLOYER_PRIVATE_KEY='unused'),
                            text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((run / 'config/chains/sepolia.json').read_text()) == {'deployed': True}
    assert (evm / 'leftover.json').read_text() == 'other run'
    assert sorted(p.name for p in evm.iterdir()) == ['foundry.toml', 'leftover.json']


def test_run_profile_compiles_upstream_imports(tmp_path):
    if not shutil.which('forge'):
        pytest.skip('forge not installed')
    evm, run = tmp_path / 'upstream', tmp_path / 'run'
    (evm / 'contracts').mkdir(parents=True)
    (evm / 'lib/dependency').mkdir(parents=True)
    (evm / 'foundry.toml').write_text('[profile.default]\nsrc="contracts"\nsolc="0.8.26"\n')
    (evm / 'remappings.txt').write_text('dependency/=lib/dependency/\n')
    (evm / 'lib/dependency/Base.sol').write_text('pragma solidity ^0.8.0; contract Base {}')
    (evm / 'contracts/Example.sol').write_text('pragma solidity ^0.8.0; import "dependency/Base.sol"; contract Example is Base {}')
    path = config.write_config(evm, run)
    result = subprocess.run(['forge', 'build', '--offline', '--root', str(evm), '--config-path', str(path)],
                            env=dict(os.environ, FOUNDRY_PROFILE='wsteth_run'), capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (evm / 'out/Example.sol/Example.json').is_file()

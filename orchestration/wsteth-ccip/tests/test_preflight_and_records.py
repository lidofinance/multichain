"""Regression checks for tool prerequisites, chain records and migration address books."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import pytest


SCRIPTS = Path(__file__).resolve().parents[1] / 'script'
ROOT = SCRIPTS.parents[2]


@pytest.mark.parametrize('chains,missing', [
    ({'L1_CHAIN': 'sepolia', 'L2_CHAIN': 'base_sepolia'}, 'RPC_BASE_SEPOLIA'),
    ({'L1_CHAIN': 'ethereum', 'L2_CHAIN': 'base'}, 'RPC_ETHEREUM'),
])
def test_ccv_inspection_reports_missing_rpc_on_stderr(chains, missing):
    # Stop before reading records or making RPC calls. In particular, the diagnostic
    # must escape rpc_of's command substitution while stdout remains machine data.
    result = subprocess.run(['/bin/bash', str(SCRIPTS / 'verify-ccv.sh')],
                            env={'PATH': os.environ['PATH'], **chains}, capture_output=True, text=True)
    assert result.returncode == 1
    assert result.stdout == ''
    assert result.stderr.strip() == f'✗ {missing} unset'


@pytest.mark.parametrize('missing', ['uv', 'node', 'rsync', 'git'])
def test_preflight_reports_missing_tool_before_setup_or_rpc(tmp_path, missing):
    scripts = tmp_path / 'script'
    scripts.mkdir()
    shutil.copy2(SCRIPTS / '00_preflight.sh', scripts)
    (scripts / '_common.sh').write_text('echo UNEXPECTED_SETUP; exit 99\n')
    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()
    (bin_dir / 'dirname').symlink_to(shutil.which('dirname'))
    for name in ['cast', 'forge', 'jq', 'bc', 'uv', 'node', 'rsync', 'git', 'python3']:
        if name != missing:
            path = bin_dir / name
            path.write_text('#!/bin/sh\nexit 0\n')
            path.chmod(0o755)
    result = subprocess.run(['/bin/bash', str(scripts / '00_preflight.sh')],
                            env={'PATH': str(bin_dir)}, capture_output=True, text=True)
    assert result.returncode == 1
    assert f'{missing} not found in PATH' in result.stdout
    assert 'UNEXPECTED_SETUP' not in result.stdout


@pytest.mark.parametrize('in_place', [False, True])
def test_generated_bridge_anchors_belong_to_their_chain(tmp_path, in_place):
    script = (SCRIPTS / '08_verify_state.sh').read_text()
    # Execute the real address-book emission, without RPC/setup/verification side effects.
    start = script.index('{\ncat <<EOF\n# GENERATED')
    end = script.index('} > "${DEPLOYED}"', start) + len('} > "${DEPLOYED}"')
    emission = script[start:end]
    env = os.environ.copy()
    for index, name in enumerate(sorted(set(re.findall(r'\$\{(\w+)\}', emission))), 1):
        env[name] = f'0x{index:040x}'
    env.update(IN_PLACE=str(int(in_place)), DEPLOYED=str(tmp_path / 'deployed.yaml'))
    subprocess.run(['/bin/bash', '-eu', '-c', emission], env=env, check=True)
    text = Path(env['DEPLOYED']).read_text()
    l1, l2 = text.split('  l2:\n')
    assert '    - &l1WstETH ' in l1
    assert '    - &l2WstETH ' in l2
    for chain, section, other in [('l1', l1, l2), ('l2', l2, l1)]:
        for suffix in ['LegacyBridge', 'MigrationBridgeImpl']:
            anchor = f'&{chain}{suffix} '
            assert section.count(anchor) == int(in_place)
            assert anchor not in other


@pytest.mark.parametrize('target', ['wsteth-base-migration-mainnet', 'wsteth-ccip-sepolia-mantle-dev'])
def test_both_target_formats_share_the_chain_schema(target):
    subprocess.run([sys.executable, '-I', str(SCRIPTS / 'validate-chain-records.py'),
                    str(ROOT / 'targets' / target / 'config/chains')], check=True)


def test_chain_schema_rejects_bad_registry_and_unknown_governance_parameter(tmp_path):
    record = json.loads((ROOT / 'targets/wsteth-base-migration-mainnet/config/chains/base.json').read_text())
    record['ccip']['token_admin_registry'] = 'not-an-address'
    record['governance_addresses']['guardian'] = record['governance_addresses']['emergency_brakes']
    (tmp_path / 'base.json').write_text(json.dumps(record))
    result = subprocess.run([sys.executable, '-I', str(SCRIPTS / 'validate-chain-records.py'), str(tmp_path)],
                            capture_output=True, text=True)
    assert result.returncode == 1
    assert 'token_admin_registry' in result.stdout
    assert 'guardian' in result.stdout

"""The ledger wrapper supports direct invocation and both checkout overrides."""
import os
from pathlib import Path
import subprocess

import pytest

SCRIPT = Path(__file__).parents[2] / 'ledger/state-mate.sh'


@pytest.mark.parametrize('overrides,missing', [
    ({}, 'libs/state-mate'),
    ({'STATE_MATE_DIR': 'custom-checkout'}, 'custom-checkout'),
    ({'STATE_MATE_DIR': 'custom-checkout', 'STATE_MATE_CHECKOUT': 'explicit-checkout'}, 'explicit-checkout'),
])
def test_direct_runner_reports_selected_missing_checkout(tmp_path, overrides, missing):
    script = tmp_path / 'orchestration/ledger/state-mate.sh'
    script.parent.mkdir(parents=True)
    script.write_text(SCRIPT.read_text())
    env = {k: v for k, v in os.environ.items() if k not in ('STATE_MATE_DIR', 'STATE_MATE_CHECKOUT')}
    result = subprocess.run(['bash', str(script), 'base'], env=dict(env, **overrides), capture_output=True, text=True)
    assert result.returncode == 127
    assert f'checkout not found at {missing}' in result.stderr
    assert 'unbound variable' not in result.stderr
    assert 'STATE_MATE_DIR' in result.stderr

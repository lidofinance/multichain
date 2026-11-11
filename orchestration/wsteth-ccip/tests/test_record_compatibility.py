"""Legacy records must carry their own state and fixed historical expectations."""
import json
import os
from pathlib import Path
import subprocess

import pytest

SCRIPTS = Path(__file__).parents[1] / 'script'


@pytest.mark.parametrize('layout', ['nested', 'siblings', 'named'])
def test_archive_state_lookup_uses_record_not_active_run(tmp_path, layout):
    record = tmp_path / 'archive/chains'
    record.mkdir(parents=True)
    state = record.parent / 'state' if layout == 'siblings' else record / 'state'
    state.mkdir()
    filename = 'mantle_sepolia.json' if layout == 'named' else 'l2.json'
    (state / filename).write_text(json.dumps({'l2Chain': 'mantle_sepolia'}))
    result = resolve_state(tmp_path, record)
    assert result.returncode == 0, result.stderr
    assert Path(result.stdout.strip()).resolve() == state / filename


def resolve_state(root, record, leaf='mantle_sepolia'):
    return subprocess.run(['bash', '-euc', '. "$1"; resolve_record_state; echo "$L2_STATE"',
                           'test', str(SCRIPTS / '_record.sh')], text=True, capture_output=True,
                          env=dict(os.environ, ROOT=str(root), RECORD_PATH=str(record),
                                   RECORD_DIR=str(record), L2_CHAIN=leaf, L2_STATE_FILE=f'state/{leaf}.json'))


def test_missing_or_wrong_leaf_state_does_not_borrow_active_state(tmp_path):
    record = tmp_path / 'record'
    (record / 'state').mkdir(parents=True)
    (tmp_path / 'state').mkdir()
    (tmp_path / 'state/base_sepolia.json').write_text('{}')
    (record / 'state/l2.json').write_text('{"l2Chain":"mantle_sepolia"}')
    result = resolve_state(tmp_path, record, 'base_sepolia')
    assert result.returncode != 0
    assert 'Missing base_sepolia state' in result.stderr


@pytest.mark.parametrize('spelling', ['absolute', 'relative', 'dot', 'symlink'])
def test_active_record_state_and_policy_follow_canonical_path(tmp_path, spelling):
    record = tmp_path / 'config/chains'
    record.mkdir(parents=True)
    (tmp_path / 'state').mkdir()
    (tmp_path / 'state/mantle_sepolia.json').write_text('{}')
    if spelling == 'symlink':
        (tmp_path / 'record-link').symlink_to(record, target_is_directory=True)
    value = {'absolute': str(record), 'relative': 'config/chains', 'dot': './config/chains',
             'symlink': 'record-link'}[spelling]
    result = subprocess.run(['bash', '-euc',
                             '. "$1"; resolve_record_state; resolve_record_policy; echo "$L2_STATE"; echo "$POLICY"',
                             'test', str(SCRIPTS / '_record.sh')], cwd=tmp_path, text=True, capture_output=True,
                            env=dict(os.environ, ROOT=str(tmp_path), RECORD_PATH=value,
                                     RECORD_DIR=value, L2_CHAIN='mantle_sepolia', L2_STATE_FILE='state/mantle_sepolia.json'))
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == [str(tmp_path / 'state/mantle_sepolia.json'),
                                          str(tmp_path / 'config/ccv-policy.json')]

"""Fork commands must work without auto-impersonation and release their sender on failure."""
import os
from pathlib import Path
import subprocess

import pytest


COMMON = Path(__file__).parents[1] / 'script/_common.sh'


def run_scope(tmp_path, command, **overrides):
    source = COMMON.read_text()
    start = source.index('with_fork_account() (')
    helper = source[start:source.index('\n)\n', start) + 3]
    is_anvil = next(line for line in source.splitlines() if line.startswith('is_anvil()'))
    harness = r'''
set -euo pipefail
cast() {
    [ "$1" = rpc ] || return 99
    case "$2" in
      anvil_nodeInfo) [ "${LIVE:-0}" != 1 ] ;;
      anvil_impersonateAccount)
        echo "start $3" >> calls
        [ "${START_FAIL:-0}" != 1 ] || return 17
        touch "active-$3" ;;
      anvil_stopImpersonatingAccount)
        echo "stop $3" >> calls
        [ "${STOP_FAIL:-0}" != 1 ] || return 19
        rm "active-$3" ;;
      *) return 99 ;;
    esac
}
send_probe() {
    for account in "$@"; do
        [ -f "active-${account}" ] || { echo 'No Signer available' >&2; return 21; }
    done
    echo 'send' >> calls
    [ "${SEND_FAIL:-0}" != 1 ] || return 23
    echo '{"status":"0x1"}'
}
'''
    return subprocess.run(['bash', '-c', harness + is_anvil + '\n' + helper + '\n' + command],
                          cwd=tmp_path, env=dict(os.environ, **overrides), capture_output=True, text=True)


@pytest.mark.parametrize('capture', [False, True])
def test_impersonation_is_scoped_and_stdout_keeps_the_receipt(tmp_path, capture):
    command = 'with_fork_account rpc alice send_probe alice'
    if capture:
        command = 'receipt="$(' + command + ')"; printf "%s\\n" "$receipt"'
    result = run_scope(tmp_path, command)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == '{"status":"0x1"}'
    assert (tmp_path / 'calls').read_text().splitlines() == ['start alice', 'send', 'stop alice']
    assert not (tmp_path / 'active-alice').exists()


def test_non_anvil_endpoint_never_impersonates_or_sends(tmp_path):
    result = run_scope(tmp_path, 'with_fork_account rpc alice send_probe alice', LIVE='1')
    assert result.returncode != 0
    assert 'requires an Anvil fork' in result.stderr
    assert not (tmp_path / 'calls').exists()


def test_failed_impersonation_never_runs_command(tmp_path):
    result = run_scope(tmp_path, 'with_fork_account rpc alice send_probe alice', START_FAIL='1')
    assert result.returncode == 17
    assert (tmp_path / 'calls').read_text().splitlines() == ['start alice']


@pytest.mark.parametrize('stop_fail', ['0', '1'])
def test_failed_send_is_visible_and_retains_status_even_if_cleanup_fails(tmp_path, stop_fail):
    result = run_scope(tmp_path, 'receipt="$(with_fork_account rpc alice send_probe alice)"',
                       SEND_FAIL='1', STOP_FAIL=stop_fail)
    assert result.returncode == 23
    assert 'fork command failed for alice (exit 23)' in result.stderr
    assert (tmp_path / 'calls').read_text().splitlines() == ['start alice', 'send', 'stop alice']
    assert (tmp_path / 'active-alice').exists() == (stop_fail == '1')


def test_cleanup_failure_is_not_reported_as_success(tmp_path):
    result = run_scope(tmp_path, 'with_fork_account rpc alice send_probe alice', STOP_FAIL='1')
    assert result.returncode != 0
    assert 'could not stop impersonating alice' in result.stderr


@pytest.mark.parametrize('send_fail', ['0', '1'])
def test_multiple_forge_senders_have_independent_cleanup(tmp_path, send_fail):
    result = run_scope(tmp_path,
                       'with_fork_account rpc deployer with_fork_account rpc agent send_probe deployer agent',
                       SEND_FAIL=send_fail)
    assert result.returncode == (23 if send_fail == '1' else 0)
    assert (tmp_path / 'calls').read_text().splitlines() == [
        'start deployer', 'start agent', 'send', 'stop agent', 'stop deployer']
    assert not list(tmp_path.glob('active-*'))

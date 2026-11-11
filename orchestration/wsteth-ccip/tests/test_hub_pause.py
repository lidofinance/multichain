import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1] / 'script'))
import check_hub_pause as pause
from bootstrap.rpc import RpcError


@pytest.mark.parametrize('error', [
    {'code': -32000, 'message': 'RPC timeout'},
    {'code': 3, 'data': '0xdeadbeef'},
    {'code': 3},
    {'code': -32603, 'data': '0x1234'},
])
def test_unrelated_errors_never_prove_a_pause(error):
    with pytest.raises(ValueError, match='exact TokenMaxCapacityExceeded'):
        pause.require_capacity_revert(error, '0x1234')


def test_capacity_revert_must_match_all_arguments():
    pause.require_capacity_revert({'code': 3, 'data': '0xABCD'}, '0xabcd')
    with pytest.raises(ValueError):
        pause.require_capacity_revert({'code': 3, 'data': '0xabce'}, '0xabcd')


def test_probe_only_uses_eth_call_overrides(monkeypatch):
    token, router, sender = ('0x' + digit * 40 for digit in ('1', '2', '3'))
    monkeypatch.setattr(pause, 'cast', lambda *args: str(args))
    monkeypatch.setattr(pause, 'encode', lambda *args: '0xabcd')
    class Fork:
        def call(self, *args): return 7
        def rpc(self, method, tx, block, overrides):
            assert method == 'eth_call' and block == 'latest'
            assert tx['value'] == '0x7'
            assert len(overrides[token]['stateDiff']) == 2
            assert overrides[sender]['balance'] == hex(7 + 10**18)
            raise RpcError('test', method, {'code': 3, 'data': '0xabcd'})
    assert pause.check_lane(Fork(), token, router, sender, 1) == 'TokenMaxCapacityExceeded'


def test_successful_send_fails_pause_check(monkeypatch):
    monkeypatch.setattr(pause, 'cast', lambda *args: str(args))
    monkeypatch.setattr(pause, 'encode', lambda *args: '0x1234')
    class Fork:
        def call(self, *args): return 1
        def rpc(self, *args): return '0x00'
    with pytest.raises(ValueError, match='succeeded'):
        pause.check_lane(Fork(), 'token', 'router', 'sender', 1)

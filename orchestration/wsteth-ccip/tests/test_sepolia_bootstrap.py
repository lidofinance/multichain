"""The new baseline remains local-only and feeds the same migration gates as mainnet."""
import importlib.util
import json
from pathlib import Path
import pytest

OPS = Path(__file__).parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


workspace = module('bootstrap_workspace', OPS / 'workspace.py')
rpc = module('bootstrap_rpc', OPS / 'script/bootstrap/rpc.py')


def test_both_targets_are_executable_with_different_preparation():
    _, main = workspace.target('wsteth-base-migration-mainnet')
    _, sep = workspace.target('wsteth-base-migration-sepolia')
    assert 'bootstrap' not in main
    assert sep['bootstrap']['coreToken'] == 'pristine'
    assert sep['environments'] == ['fork']
    order = workspace.SEPOLIA_MIGRATION_PIPELINE
    assert order.index('test-bootstrap') < order.index('migration-inputs')
    assert order.index('hub-accept-admin') < order.index('bootstrap-connect-remotes') < order.index('base-prepare')
    assert [r for r in order[order.index('base-prepare'):] if r != 'test-existing-lanes'] == workspace.HUB_MIGRATION_PIPELINE[workspace.HUB_MIGRATION_PIPELINE.index('base-prepare'):]


def test_bootstrap_cannot_be_enabled_on_public_network(tmp_path, monkeypatch):
    data = workspace.read_json(workspace.ROOT / 'targets/wsteth-base-migration-sepolia/target.json')
    data['environments'] = ['fork', 'testnet']
    target = tmp_path / 'targets' / data['id']
    target.mkdir(parents=True)
    (target / 'target.json').write_text(json.dumps(data))
    monkeypatch.setattr(workspace, 'ROOT', tmp_path)
    with pytest.raises(ValueError, match='restricted to forks'):
        workspace.target(data['id'])


def test_public_endpoint_rejected_before_any_rpc(monkeypatch):
    monkeypatch.setattr(rpc.Fork, 'rpc', lambda *args: pytest.fail('RPC contacted before endpoint guard'))
    with pytest.raises(ValueError, match='loopback'):
        rpc.Fork('sepolia', 'https://public.example', 11155111)


def test_live_node_behind_local_proxy_rejected(monkeypatch):
    monkeypatch.setattr(rpc.Fork, 'rpc', lambda *args: 'Geth/v1')
    with pytest.raises(ValueError, match='Anvil'):
        rpc.Fork('sepolia', 'http://127.0.0.1:9999', 11155111)


def test_failed_transaction_always_releases_impersonation(monkeypatch):
    f = object.__new__(rpc.Fork)
    f.slug = 'sepolia'
    calls = []
    def fake(method, *args):
        calls.append(method)
        if method == 'eth_sendTransaction':
            return '0xdead'
        if method == 'eth_getTransactionReceipt':
            return {'status':'0x0'}
        return True
    f.rpc = fake
    with pytest.raises(RuntimeError, match='transaction failed'):
        f.send('0x'+'1'*40, data='0x')
    assert calls[-1] == 'anvil_stopImpersonatingAccount'

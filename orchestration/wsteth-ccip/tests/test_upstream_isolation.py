"""Behavioral checks for reproducible inputs, source guards and owned runner failure boundaries."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

OPS = Path(__file__).parents[1]
sys.path.insert(0, str(OPS / 'script'))
sys.path.insert(0, str(OPS))
import ccip_api
import ccip_build
import hub_runner
import rehearse
import rehearsal_checks


def test_build_provenance_excludes_credentials_and_unrecognized_settings():
    settings = {'solc': '0.8.26', 'optimizer': True, 'optimizer_runs': 80000,
                'evm_version': 'paris', 'bytecode_hash': 'none',
                'etherscan_api_key': 'private-explorer-key',
                'rpc_endpoints': {'mainnet': 'https://rpc.invalid/private-token'},
                'wallet': {'private_key': 'secret'}, 'future_credential_option': 'secret'}
    assert ccip_build.compiler_settings(settings) == {
        'solc': '0.8.26', 'optimizer': True, 'optimizer_runs': 80000,
        'evm_version': 'paris', 'bytecode_hash': 'none'}


@pytest.mark.parametrize('source', ['environment', 'dotenv'])
def test_rehearsal_rejects_overrides_before_network_or_workspace_creation(tmp_path, monkeypatch, source):
    monkeypatch.setattr(rehearse, 'OPS', tmp_path)
    monkeypatch.setattr(rehearse, 'ROOT', tmp_path)
    if source == 'environment':
        monkeypatch.setenv('WSTETH_DEPLOY_SCOPE', 'hub')
    else:
        monkeypatch.delenv('WSTETH_DEPLOY_SCOPE', raising=False)
        (tmp_path / '.env').write_text('WSTETH_DEPLOY_SCOPE=hub\n')
    monkeypatch.setattr(rehearse.ccip_api, 'capture', lambda *a: pytest.fail('network reached'))
    monkeypatch.setattr(rehearse.subprocess, 'Popen', lambda *a, **k: pytest.fail('fork started'))
    with pytest.raises(ValueError, match='WSTETH_DEPLOY_SCOPE'):
        rehearse.run_line('scratch', 'rejected')
    assert not (tmp_path / 'runs').exists()


def test_replay_pins_verify_chain_block_and_hash_without_latest(monkeypatch):
    calls = []
    def rpc(url, method, params=None):
        calls.append((method, params))
        return '0x1' if method == 'eth_chainId' else {'number': '0x10', 'hash': '0xabc'}
    monkeypatch.setattr(rehearse, 'rpc', rpc)
    pin = {'chainId': 1, 'block': 16, 'blockHash': '0xabc'}
    assert rehearse.pinned_block('unused', 1, pin)['number'] == '0x10'
    assert calls[-1][1] == ['0x10', False]
    with pytest.raises(ValueError, match='hash changed'):
        rehearse.pinned_block('unused', 1, dict(pin, blockHash='0xdef'))
    with pytest.raises(ValueError, match='chain ID'):
        rehearse.pinned_block('unused', 1, dict(pin, chainId=2))


def api_snapshot(path):
    path.mkdir()
    manifest = {}
    for url, name in ccip_api.URLS.items():
        data = json.dumps({'data': {'evm': {'1': {'router': 'fixture'}}}}).encode()
        (path / name).write_bytes(data)
        manifest[url] = {'file': name, 'sha256': ccip_api.digest(data)}
    (path / 'manifest.json').write_text(json.dumps(manifest))


def test_api_replay_writes_identical_bytes_and_rejects_missing_or_tampered_inputs(tmp_path, monkeypatch):
    directory = tmp_path / 'api'
    api_snapshot(directory)
    monkeypatch.setenv('WSTETH_CCIP_API_DIR', str(directory))
    url, name = next(iter(ccip_api.URLS.items()))
    output = tmp_path / 'response.json'
    assert ccip_api.replay(['-fsS', url, '-o', str(output)]) == 0
    assert output.read_bytes() == (directory / name).read_bytes()
    with pytest.raises(ValueError, match='live fallback'):
        ccip_api.replay(['-s', url + '&new=1'])
    (directory / name).write_text('{}')
    with pytest.raises(ValueError, match='changed'):
        ccip_api.replay(['-s', url])


def git_at(path, *args):
    return subprocess.check_output(['git', '-C', str(path), *args], text=True).strip()


def source_repo(tmp_path, monkeypatch):
    root = tmp_path / 'repo'
    ccip = root / 'components/ccip'
    evm = ccip / 'chains/evm'
    contracts = evm / 'contracts/lido-hvmv'
    contracts.mkdir(parents=True)
    (contracts / 'Pool.sol').write_text('contract Pool {}')
    (ccip / '.gitignore').write_text('Ignored.sol\n')
    (evm / 'foundry.toml').write_text('[profile.default]\n')
    git_at(ccip, 'init', '-q')
    git_at(ccip, 'add', '.')
    git_at(ccip, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture')
    revision = git_at(ccip, 'rev-parse', 'HEAD')
    git_at(root, 'init', '-q')
    git_at(root, 'update-index', '--add', '--cacheinfo', '160000', revision, 'components/ccip')
    monkeypatch.setattr(ccip_build, 'ROOT', root)
    monkeypatch.setattr(ccip_build, 'CCIP', ccip)
    monkeypatch.setattr(ccip_build, 'EVM', evm)
    # git()'s original default directory is fixed at definition time.
    monkeypatch.setattr(ccip_build, 'git', lambda *args, cwd=None: git_at(cwd or ccip, *args))
    return ccip, contracts, evm


@pytest.mark.parametrize('kind', ['tracked', 'untracked', 'ignored', 'settings', 'test-helper'])
def test_guard_rejects_all_executable_source_changes(tmp_path, monkeypatch, kind):
    ccip, contracts, evm = source_repo(tmp_path, monkeypatch)
    assert ccip_build.guard() == git_at(ccip, 'rev-parse', 'HEAD')
    target = {'tracked': contracts / 'Pool.sol', 'untracked': contracts / 'New.sol',
              'ignored': contracts / 'Ignored.sol', 'settings': evm / 'foundry.toml',
              'test-helper': contracts / 'test' / 'Ignored.sol'}[kind]
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('modified')
    with pytest.raises(ValueError, match='executable CCIP'):
        ccip_build.guard()


def test_runtime_comparison_masks_only_declared_immutables():
    artifact = {'deployedBytecode': {'object': '0x01000004', 'immutableReferences': {'1': [{'start': 1, 'length': 2}]}}}
    assert hub_runner.runtime_matches(artifact, '0x01abcd04')
    assert not hub_runner.runtime_matches(artifact, '0x02abcd04')
    assert not hub_runner.runtime_matches(artifact, '0x01abcd0400')


def runner_fixture(tmp_path, monkeypatch):
    run = tmp_path / 'run'
    (run / 'config/chains').mkdir(parents=True)
    (run / 'state/hub-migration').mkdir(parents=True)
    fixtures = OPS / 'tests/fixtures/hub-migration'
    cfg = json.loads((fixtures / 'hub.json').read_text())
    (run / 'config/chains/ethereum.json').write_text(json.dumps(cfg))
    (run / 'state/hub-migration/manifest.json').write_bytes((fixtures / 'manifest.json').read_bytes())
    info = {'id': 'run', 'environment': 'fork', 'operation': 'in-place-upgrade', 'l1Chain': 'ethereum'}
    monkeypatch.setattr(hub_runner.workspace, 'active', lambda: (run, info))
    monkeypatch.setattr(hub_runner.ccip_build, 'verify', lambda: {'revision': 'fixture'})
    monkeypatch.setattr(hub_runner.ccip_build, 'archive_build', lambda *args: None)
    stamp = tmp_path / 'build.json'; stamp.write_text('{}')
    monkeypatch.setattr(hub_runner.ccip_build, 'STAMP', stamp)
    class Fork:
        def __init__(self, *args): pass
        def rpc(self, *args): return '0x1'
    monkeypatch.setattr(hub_runner, 'Fork', Fork)
    monkeypatch.delenv('HUB_MIGRATION_ONLY', raising=False)
    return run


def test_failed_owned_runner_keeps_partial_records_and_nonzero_status(tmp_path, monkeypatch):
    run = runner_fixture(tmp_path, monkeypatch)
    path = run / 'config/chains/ethereum.json'
    def fail(command, **kwargs):
        assert '--broadcast' in command
        path.write_text('{"partial":true}')
        return 7
    monkeypatch.setattr(hub_runner.subprocess, 'call', fail)
    assert hub_runner.run('deploy', 'ethereum', 'unused') == 7
    assert json.loads(path.read_text()) == {'partial': True}
    audit = run / 'state/hub-scripts/deploy'
    assert json.loads((audit / 'result.json').read_text())['status'] == 'failed'
    assert json.loads((audit / 'records-after/ethereum.json').read_text()) == {'partial': True}


def test_dry_run_omits_broadcast_and_forbids_false_deployment_records(tmp_path, monkeypatch):
    run = runner_fixture(tmp_path, monkeypatch)
    def simulate(command, **kwargs):
        assert '--broadcast' not in command
        (run / 'config/chains/ethereum.json').write_text('{"deployed":"simulated"}')
        return 0
    monkeypatch.setattr(hub_runner.subprocess, 'call', simulate)
    with pytest.raises(ValueError, match='changed records'):
        hub_runner.run('deploy', 'ethereum', 'unused', dry_run=True)


def test_base_preparation_requires_checkpoint_before_broadcast(tmp_path, monkeypatch):
    runner_fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(hub_runner.subprocess, 'call', lambda *a, **k: pytest.fail('Premature broadcast'))
    with pytest.raises(FileNotFoundError, match='hub-checkpoint'):
        hub_runner.run('prepare-lane', 'ethereum', 'unused')


def test_manifest_custody_must_partition_lanes(tmp_path, monkeypatch):
    run = runner_fixture(tmp_path, monkeypatch)
    path = run / 'state/hub-migration/manifest.json'
    manifest = json.loads(path.read_text())
    manifest['lockBoxGroups']['shared']['lanes'].append('isolated')
    path.write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match='partition'):
        hub_runner.validate_manifest(run, json.loads((run / 'config/chains/ethereum.json').read_text()))


@pytest.mark.parametrize('content', ['', '[PASS] test_one() (gas: 1)\n',
    '[PASS] test_one() (gas: 1)\n[SKIP] test_two() (gas: 1)\n'])
def test_empty_reduced_or_skipped_required_tests_do_not_pass(tmp_path, content):
    log = tmp_path / 'forge.log'
    log.write_text(content)
    with pytest.raises(ValueError):
        rehearsal_checks.forge_checks(log, {'test_one', 'test_two'})


def test_delegated_checkpoint_skips_are_explicit(tmp_path):
    log = tmp_path / 'forge.log'
    log.write_text('[PASS] test_one() (gas: 1)\n[SKIP] test_two() (gas: 1)\n')
    assert rehearsal_checks.forge_checks(log, {'test_one', 'test_two'}, {'test_two'}) == {
        'passed': 1, 'skipped': ['test_two']}

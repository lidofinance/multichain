"""Offline checks for run isolation and migration-specific failure modes."""
import importlib.util
import json
from pathlib import Path

import pytest

SPEC = importlib.util.spec_from_file_location('wsteth_workspace', Path(__file__).parents[1] / 'workspace.py')
workspace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(workspace)


@pytest.fixture
def layout(tmp_path, monkeypatch):
    operations = tmp_path / 'orchestration/wsteth-ccip'
    runs = tmp_path / 'runs/wsteth-2.0'
    target = tmp_path / 'targets/example'
    for directory in ('src', 'script', 'patches'):
        (operations / directory).mkdir(parents=True)
        (operations / directory / 'input.txt').write_text('original\n')
    for name in ('foundry.toml', 'remappings.txt', 'justfile', 'workspace.py'):
        (operations / name).write_text('fixture\n')
    (operations / 'dependencies.json').write_text('[]')
    (operations / 'migration-source.json').write_text(json.dumps({'sourceCommit': 'source', 'dependencies': []}))
    config = target / 'config/chains'
    config.mkdir(parents=True)
    for slug, chain_id in [('sepolia', 11155111), ('example', 5003)]:
        (config / (slug + '.json')).write_text(json.dumps({'chain': {'chain_id': chain_id}, 'addresses': {'token': ''}}))
    data = {'schemaVersion': 1, 'id': 'example', 'status': 'ready', 'orchestration': 'wsteth-ccip',
            'operation': 'scratch-deployment', 'configDirectory': 'config',
            'networks': {'l1': {'slug': 'sepolia', 'chainId': 11155111}, 'l2': {'slug': 'example', 'chainId': 5003}},
            'environments': ['fork', 'testnet']}
    (target / 'target.json').write_text(json.dumps(data))
    monkeypatch.setattr(workspace, 'ROOT', tmp_path)
    monkeypatch.setattr(workspace, 'OPERATIONS', operations)
    monkeypatch.setattr(workspace, 'RUNS', runs)
    monkeypatch.setattr(workspace, 'git', lambda *args, **kwargs: 'repository')
    return operations, runs, target


def test_outputs_cannot_overwrite_target_and_runs_remain_separate(layout):
    operations, runs, target = layout
    original = workspace.hashes(target)
    workspace.prepare('example', 'first', 'fork')
    (operations / 'config/chains/example.json').write_text('{"deployed": true}')
    (operations / 'state/receipt.json').write_text('first run evidence')
    workspace.prepare('example', 'second', 'testnet')
    assert workspace.hashes(target) == original
    assert not (operations / 'state/receipt.json').exists()
    assert (runs / 'workspaces/first/state/receipt.json').read_text() == 'first run evidence'
    assert workspace.active()[1]['environment'] == 'testnet'
    workspace.activate('first')
    assert workspace.active()[1]['environment'] == 'fork'
    assert (operations / 'state/receipt.json').read_text() == 'first run evidence'


def test_existing_run_never_overwritten(layout):
    workspace.prepare('example', 'first', 'fork')
    with pytest.raises(ValueError, match='already exists'):
        workspace.prepare('example', 'first', 'fork')


def test_edited_snapshot_cannot_be_resumed(layout):
    _, runs, _ = layout
    workspace.prepare('example', 'first', 'fork')
    (runs / 'workspaces/first/inputs/target/target.json').write_text('{}')
    with pytest.raises(ValueError, match='snapshot changed'):
        workspace.active()


def test_incomplete_target_stops_before_run_creation(layout):
    _, runs, target = layout
    data = workspace.read_json(target / 'target.json')
    data.update(status='incomplete', networks={'l1': None, 'l2': None})
    workspace.write_json(target / 'target.json', data)
    with pytest.raises(ValueError, match='incomplete'):
        workspace.prepare('example', 'first', 'testnet')
    assert not (runs / 'workspaces/first').exists()


def test_record_network_checked_before_copy(layout):
    _, runs, _ = layout
    record = runs / 'history/record'
    record.mkdir(parents=True)
    (record / 'sepolia.json').write_text('{"chain":{"chain_id":1}}')
    with pytest.raises(ValueError, match='different network'):
        workspace.prepare('example', 'first', 'testnet', 'runs/wsteth-2.0/history/record')
    assert not (runs / 'workspaces/first').exists()


def test_real_directory_is_not_replaced(layout):
    operations, _, _ = layout
    (operations / 'state').mkdir()
    (operations / 'state/receipt').write_text('preserve me')
    with pytest.raises(ValueError, match='real orchestration directory'):
        workspace.prepare('example', 'first', 'fork')
    assert (operations / 'state/receipt').read_text() == 'preserve me'


def test_recipe_cannot_bypass_selected_run(layout):
    with pytest.raises(ValueError, match='No run selected'):
        workspace.execute(['all'])
    with pytest.raises(ValueError, match='one build/setup'):
        workspace.execute(['build', 'all'])
    with pytest.raises(ValueError, match='recipe name'):
        workspace.execute(['--justfile', '/unselected/justfile'])


def test_run_identifier_cannot_escape_workspace(layout):
    with pytest.raises(ValueError, match='simple name'):
        workspace.prepare('example', '../../other', 'fork')


def test_owned_token_sources_are_snapshotted_and_protected(layout):
    _, runs, target = layout
    component = workspace.ROOT / 'components/wsteth-token'
    (component / 'contracts').mkdir(parents=True)
    (component / 'contracts/Token.sol').write_text('original token')
    (component / 'contracts/lib').mkdir()
    (component / 'contracts/lib/Storage.sol').write_text('owned storage')
    (component / 'out').mkdir()
    (component / 'out/generated.json').write_text('{}')
    # A pinned submodule inside the component is a dependency, recorded via dependencies.json.
    (component / 'lib/openzeppelin').mkdir(parents=True)
    (component / 'lib/openzeppelin/Proxy.sol').write_text('upstream')
    data = workspace.read_json(target / 'target.json')
    data['components'] = ['wsteth-token']
    workspace.write_json(target / 'target.json', data)
    workspace.prepare('example', 'token', 'fork')
    snapshot = runs / 'workspaces/token/inputs/components/wsteth-token'
    assert (snapshot / 'contracts/Token.sol').read_text() == 'original token'
    assert (snapshot / 'contracts/lib/Storage.sol').read_text() == 'owned storage'
    assert not (snapshot / 'out').exists()
    assert not (snapshot / 'lib').exists()
    (component / 'lib/openzeppelin/Proxy.sol').write_text('upstream bumped')
    workspace.active()
    (component / 'contracts/lib/Storage.sol').write_text('changed storage')
    with pytest.raises(ValueError, match='Live source differs'):
        workspace.active()
    (snapshot / 'contracts/Token.sol').write_text('tampered')
    with pytest.raises(ValueError, match='snapshot changed'):
        workspace.active()


@pytest.mark.parametrize('entry', ['script/new.sh', 'src/input.txt', 'justfile', 'foundry.toml'])
def test_live_orchestration_drift_blocks_execution(layout, entry):
    operations, _, _ = layout
    workspace.prepare('example', 'first', 'fork')
    (operations / entry).write_text('changed')
    with pytest.raises(ValueError, match='Live source differs'):
        workspace.execute(['all'])


def test_live_scenario_drift_blocks_execution(layout):
    _, _, target = layout
    (target / 'test').mkdir()
    (target / 'test/Scenario.sol').write_text('original')
    workspace.prepare('example', 'first', 'fork')
    (target / 'test/Scenario.sol').unlink()
    with pytest.raises(ValueError, match='Live source differs'):
        workspace.execute(['test-scenarios'])


@pytest.mark.parametrize('failure', ['copy', 'git', 'activate'])
def test_failed_prepare_cleans_up_and_keeps_previous_run(layout, monkeypatch, failure):
    operations, runs, _ = layout
    workspace.prepare('example', 'first', 'fork')
    original_links = {name: (operations / name).readlink() for name in (*workspace.ALIASES, '.active-run')}
    with monkeypatch.context() as patch:
        def fail(*args, **kwargs):
            raise OSError('injected failure')
        if failure == 'copy':
            patch.setattr(workspace.shutil, 'copytree', fail)
        elif failure == 'git':
            patch.setattr(workspace, 'git', fail)
        else:
            replace = Path.replace
            def replace_fail(path, target):
                if path.name == 'state.next':
                    raise OSError('injected failure')
                return replace(path, target)
            patch.setattr(Path, 'replace', replace_fail)
        with pytest.raises(OSError, match='injected failure'):
            workspace.prepare('example', 'second', 'fork')
    assert {name: (operations / name).readlink() for name in original_links} == original_links
    assert sorted(p.name for p in (runs / 'workspaces').iterdir()) == ['first']
    assert not list(operations.glob('*.next'))
    workspace.prepare('example', 'second', 'fork')
    assert workspace.active()[1]['id'] == 'second'


@pytest.mark.parametrize('exists', [False, True])
def test_uninitialized_dependency_is_not_parent_checkout(layout, monkeypatch, exists):
    import subprocess
    operations, runs, _ = layout
    parent = workspace.ROOT / 'components/parent'
    parent.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(parent)], check=True)
    dependency = parent / 'empty-submodule'
    if exists:
        dependency.mkdir()
    (operations / 'dependencies.json').write_text('["../../components/parent/empty-submodule"]')
    def real_git(*args, cwd=workspace.ROOT):
        return subprocess.check_output(['git', '-C', str(cwd), *args], text=True).strip()
    monkeypatch.setattr(workspace, 'git', real_git)
    with pytest.raises(ValueError, match='not an initialized checkout'):
        workspace.prepare('example', 'first', 'fork')
    assert not (runs / 'workspaces/first').exists()


def test_switch_preconditions_checked_before_any_alias_changes(layout):
    operations, runs, _ = layout
    workspace.prepare('example', 'first', 'fork')
    (operations / 'state.next').symlink_to('/missing')
    with pytest.raises(ValueError, match='Unfinished workspace switch'):
        workspace.prepare('example', 'second', 'fork')
    assert workspace.active()[1]['id'] == 'first'
    assert not (runs / 'workspaces/second').exists()


def test_prepare_cli_defaults_environment_with_record(layout, monkeypatch):
    called = []
    monkeypatch.setattr(workspace, 'prepare', lambda *args: called.append(args))
    monkeypatch.setattr(workspace.sys, 'argv', ['workspace.py', 'prepare', 'example', 'r1', '--record', 'runs/example'])
    assert workspace.main() == 0
    assert called == [('example', 'r1', 'fork', 'runs/example')]


def test_selected_target_reaches_lint_and_scenarios(layout, monkeypatch):
    from types import SimpleNamespace
    _, runs, target = layout
    workspace.prepare('example', 'first', 'fork')
    calls = []
    monkeypatch.setattr(workspace.subprocess, 'run', lambda *args, **kwargs: calls.append(kwargs) or SimpleNamespace(returncode=0))
    workspace.execute(['lint-config'])
    assert calls[-1]['env']['WSTETH_TARGET_DIR'] == str(runs / 'workspaces/first/inputs/target')
    workspace.execute(['test-scenarios'])
    assert calls[-1]['env']['WSTETH_TEST_DIR'] == str(target / 'test')


def multi_target(target, count):
    data = workspace.read_json(target / 'target.json')
    leaves = [{'slug': f'leaf{i}', 'chainId': 5000 + i} for i in range(count)]
    data['networks'].pop('l2')
    data['networks']['l2s'] = leaves
    workspace.write_json(target / 'target.json', data)
    for network in [data['networks']['l1'], *leaves]:
        hub = network['slug'] == 'sepolia'
        workspace.write_json(target / 'config/chains' / (network['slug'] + '.json'), {
            'chain': {'chain_id': network['chainId'], 'pool_type': 'SiloedLockRelease' if hub else 'BurnMint'},
            'addresses': {'token': ''},
            'remote_lanes': [{'remote_chain_name': n['slug'], 'is_siloed': hub}
                             for n in (leaves if hub else [data['networks']['l1']])],
        })
    return leaves


@pytest.mark.parametrize('count', [1, 2, 3])
def test_pipeline_finishes_deployment_everywhere_before_configuration(layout, monkeypatch, count):
    from types import SimpleNamespace
    _, _, target = layout
    leaves = multi_target(target, count)
    workspace.prepare('example', 'multi', 'fork')
    calls = []
    def run(command, **kwargs):
        calls.append((command[-1], kwargs['env']))
        return SimpleNamespace(returncode=0)
    monkeypatch.delenv('L2_CHAIN', raising=False)
    monkeypatch.setattr(workspace.subprocess, 'run', run)
    assert workspace.execute(['all']) == 0
    deployed = [i for i, (r, _) in enumerate(calls) if r == 'ccip-deploy']
    configured = [i for i, (r, _) in enumerate(calls) if r == 'ccip-configure']
    assert len(deployed) == len(configured) == count
    assert max(deployed) < min(configured)
    assert sum(r == 'l1-core-dg' for r, _ in calls) == 1
    for recipe in ['ccip-deploy', 'ccip-configure', 'set-pool-gov', 'verify-contracts']:
        assert [env['WSTETH_SKIP_L1'] for r, env in calls if r == recipe] == ['0'] + ['1'] * (count - 1)
    assert all(env['WSTETH_SKIP_L1'] == '0' for r, env in calls if r == 'verify-state')
    assert [calls[i][1]['L2_STATE_FILE'] for i in deployed] == [f"state/{n['slug']}.json" for n in leaves]


def test_subset_prunes_run_topology_without_changing_target(layout):
    operations, _, target = layout
    multi_target(target, 3)
    policy = {'schemaVersion': 1, 'chains': {}}
    for chain in ['sepolia', 'leaf0', 'leaf1', 'leaf2']:
        remotes = ['leaf0', 'leaf1', 'leaf2'] if chain == 'sepolia' else ['sepolia']
        policy['chains'][chain] = {'lanes': {r: {} for r in remotes},
            'localResolver': {'outbound': {r: 'dummy' for r in remotes}},
            'externalResolvers': {'provider': {'outbound': {r: 'impl' for r in remotes}}}}
    workspace.write_json(target / 'config/ccv-policy.json', policy)
    original = workspace.hashes(target)
    workspace.prepare('example', 'one', 'fork', selected_spokes=['leaf1'])
    assert workspace.active()[1]['l2Chains'] == ['leaf1']
    assert workspace.hashes(target) == original
    assert workspace.read_json(operations / 'config/chains/sepolia.json')['remote_lanes'] == [
        {'remote_chain_name': 'leaf1', 'is_siloed': True}]
    assert not (operations / 'config/chains/leaf0.json').exists()
    policy = workspace.read_json(operations / 'config/ccv-policy.json')
    assert set(policy['chains']) == {'sepolia', 'leaf1'}
    assert policy['chains']['sepolia']['externalResolvers']['provider']['outbound'] == {'leaf1': 'impl'}
    assert policy['chains']['leaf1']['externalResolvers']['provider']['outbound'] == {'sepolia': 'impl'}


def test_failure_stops_before_later_chains_or_phases(layout, monkeypatch):
    from types import SimpleNamespace
    _, _, target = layout
    multi_target(target, 2)
    workspace.prepare('example', 'multi', 'fork')
    calls = []
    def run(command, **kwargs):
        calls.append(command[-1])
        return SimpleNamespace(returncode=7 if command[-1] == 'ccip-deploy' else 0)
    monkeypatch.delenv('L2_CHAIN', raising=False)
    monkeypatch.setattr(workspace.subprocess, 'run', run)
    assert workspace.execute(['all']) == 7
    assert calls[-1] == 'ccip-deploy'
    assert 'ccip-configure' not in calls


@pytest.mark.parametrize('recipe', sorted(workspace.HUB_ONCE))
def test_retry_selected_spoke_preserves_explicit_hub_skip(layout, monkeypatch, recipe):
    from types import SimpleNamespace
    _, _, target = layout
    multi_target(target, 2)
    workspace.prepare('example', 'retry', 'fork')
    monkeypatch.setenv('L2_CHAIN', 'leaf1')
    monkeypatch.setenv('WSTETH_SKIP_L1', '1')
    calls = []
    monkeypatch.setattr(workspace.subprocess, 'run', lambda *args, **kwargs:
                        calls.append(kwargs['env']) or SimpleNamespace(returncode=0))
    assert workspace.execute([recipe]) == 0
    assert len(calls) == 1
    assert calls[0]['L2_CHAIN'] == 'leaf1'
    assert calls[0]['WSTETH_SKIP_L1'] == '1'
    monkeypatch.setenv('WSTETH_SKIP_L1', 'yes')
    with pytest.raises(ValueError, match='must be 0 or 1'):
        workspace.execute([recipe])
    assert len(calls) == 1


@pytest.mark.parametrize('location', ['target', 'src', 'script', 'patches'])
def test_owned_top_level_library_is_snapshotted_and_checked(layout, location):
    operations, runs, target = layout
    live = target if location == 'target' else operations / location
    (live / 'lib').mkdir()
    (live / 'lib/helper').write_text('owned source')
    workspace.prepare('example', 'library', 'fork')
    relative = 'target' if location == 'target' else 'orchestration/' + location
    assert (runs / 'workspaces/library/inputs' / relative / 'lib/helper').read_text() == 'owned source'
    (live / 'lib/helper').write_text('modified')
    with pytest.raises(ValueError, match='Live source differs'):
        workspace.active()


@pytest.mark.parametrize('record_has_policy', [False, True])
@pytest.mark.parametrize('state_layout', ['nested', 'siblings'])
def test_import_does_not_inherit_target_policy(layout, record_has_policy, state_layout):
    import shutil
    operations, runs, target = layout
    # Deliberately different intent: never apply this target policy to an old record.
    (target / 'config/ccv-policy.json').write_text('{"chains":{"wrong":{}}}')
    record = runs / 'history/old/chains'
    record.mkdir(parents=True)
    for chain in ['sepolia', 'example']:
        shutil.copy2(target / f'config/chains/{chain}.json', record / f'{chain}.json')
    state = record / 'state' if state_layout == 'nested' else record.parent / 'state'
    state.mkdir()
    (state / 'l2.json').write_text('{"l2Chain":"example"}')
    expected = {'chains': {}}
    if record_has_policy:
        workspace.write_json(record / 'ccv-policy.json', expected)
    workspace.prepare('example', 'import', 'fork', str(record.relative_to(workspace.ROOT)))
    policy = operations / 'config/ccv-policy.json'
    if record_has_policy:
        assert workspace.read_json(policy) == expected
    else:
        assert not policy.exists()
    assert workspace.read_json(operations / 'state/example.json') == {'l2Chain': 'example'}
    assert (runs / 'workspaces/import/inputs/record/state/l2.json').exists()


def test_configure_retry_runs_only_failed_spoke(layout, monkeypatch):
    import subprocess
    operations, _, target = layout
    multi_target(target, 2)
    script = Path(__file__).parents[1] / 'script/05_ccip_configure.sh'
    (operations / 'script/05_ccip_configure.sh').write_text(script.read_text())
    (operations / 'script/_common.sh').write_text('''
L1_RPC=l1
L2_RPC=l2
run_ccip_script() {
    echo "$1" >> configured-attempts
    if [ "$1" = leaf1 ] && [ ! -f interrupted ]; then touch interrupted; return 42; fi
    [ ! -f "configured-$1" ] || return 43
    touch "configured-$1"
}
''')
    workspace.prepare('example', 'configure-retry', 'fork')
    real_run = subprocess.run
    def run_worker(command, **kwargs):
        return real_run(['bash', str(operations / 'script/05_ccip_configure.sh')], **kwargs)
    monkeypatch.setattr(workspace.subprocess, 'run', run_worker)
    monkeypatch.delenv('L2_CHAIN', raising=False)
    monkeypatch.delenv('WSTETH_SKIP_L1', raising=False)
    monkeypatch.setenv('DEPLOYER_PRIVATE_KEY', 'fake')
    assert workspace.execute(['ccip-configure']) == 42
    monkeypatch.setenv('L2_CHAIN', 'leaf1')
    monkeypatch.setenv('WSTETH_SKIP_L1', '1')
    assert workspace.execute(['ccip-configure']) == 0
    assert (operations / 'configured-attempts').read_text().splitlines() == ['sepolia', 'leaf0', 'leaf1', 'leaf1']

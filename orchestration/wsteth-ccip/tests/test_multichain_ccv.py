"""Exercise complete hub expectations and governance migration calldata offline."""
import json
from pathlib import Path
import re
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / 'orchestration/wsteth-ccip/script'
TARGET = ROOT / 'targets/wsteth-ccip-sepolia-mantle-dev/config'
ZERO = '0x' + '0' * 40


def addr(i):
    return '0x' + f'{i:040x}'


@pytest.fixture
def records(tmp_path):
    data = {}
    for index, chain in enumerate(['sepolia', 'mantle_sepolia', 'base_sepolia']):
        record = json.loads((TARGET / f'chains/{chain}.json').read_text())
        record.update(ccv={'message_id_verifier': addr(index * 10 + 1), 'verifier_resolver': addr(index * 10 + 2)},
                      deployed={'pool_operation_manager': addr(index * 10 + 3), 'advanced_pool_hooks': addr(index * 10 + 4), 'token_pool': addr(index * 10 + 6)})
        record['governance_addresses']['lido_dao_agent'] = addr(index * 10 + 5)
        data[chain] = record
    data['sepolia']['deployed']['lock_boxes'] = [
        {'remote_chain_name': 'mantle_sepolia', 'lock_box': addr(100)},
        {'remote_chain_name': 'base_sepolia', 'lock_box': addr(101)},
    ]
    for chain, record in data.items():
        (tmp_path / f'{chain}.json').write_text(json.dumps(record))
    (tmp_path / 'before.json').write_text((TARGET / 'ccv-policy.json').read_text())
    (tmp_path / 'l2-state.json').write_text(json.dumps({'wstETHProxyAdmin': addr(400)}))
    return tmp_path, data


def node(script, *args, check=True):
    if script == 'render-multichain-state.cjs':
        args = (*args, Path(args[1]) / 'l2-state.json')
    return subprocess.run(['node', str(SCRIPTS / script), *map(str, args)], text=True, capture_output=True, check=check)


def compose_projection(output, leaf):
    # Exercise state-mate's actual sibling loader, including its no-unused-anchor rule.
    shell = (SCRIPTS / '08_verify_state.sh').read_text()
    book = shell.split('cat > "${DEPLOYED}" <<EOF\n', 1)[1].split('\nEOF', 1)[0]
    book = re.sub(r'\$\{[^}]+\}', addr(999), book)
    deployed = output.parent / 'deployed.yaml'
    deployed.write_text(book)
    inputs = TARGET / 'state-mate' / ('wsteth.inputs.yaml' if leaf == 'mantle_sepolia' else f'wsteth.inputs.{leaf}.yaml')
    subprocess.run(['node', '--require', 'ts-node/register', '--require', 'tsconfig-paths/register', '-e', '''
const fs = require('node:fs');
const { composeWithSiblings } = require('./src/sibling-delegation');
const { DEPLOYED_SPEC } = require('./src/deployed-addresses');
const { INPUTS_SPEC } = require('./src/inputs');
const [main, deployed, inputs] = process.argv.slice(1).map(p => fs.readFileSync(p, 'utf8'));
composeWithSiblings(main, [{text: deployed, spec: DEPLOYED_SPEC}, {text: inputs, spec: INPUTS_SPEC}]);
''', str(output), str(deployed), str(inputs)], cwd=ROOT / 'libs/state-mate',
                   text=True, capture_output=True, check=True)


def test_state_projection_keeps_complete_hub_for_each_leaf(records):
    directory, data = records
    for leaf in ['mantle_sepolia', 'base_sepolia']:
        out = directory / f'{leaf}.yaml'
        node('render-multichain-state.cjs', TARGET / 'state-mate/wsteth.yaml', directory, directory / 'before.json', leaf, out)
        text = out.read_text()
        assert '8236463271206331221' in text
        assert '10344971235874465080' in text
        assert addr(100) in (Path(str(out) + '.tables.json')).read_text() and addr(101) in (Path(str(out) + '.tables.json')).read_text()
        assert '*l1PoolOperationManager' in text  # existing ownership checks survive
        assert '*l2WstETHImpl' in text  # existing implementation checks survive
        compose_projection(out, leaf)
        # A stale mapping for the local selector or unknown version must still be probed.
        probes = json.loads(subprocess.check_output(['node', '-e', '''
const YAML = require('yaml'), fs = require('fs');
const doc = YAML.parseDocument(fs.readFileSync(process.argv[1], 'utf8'));
console.log(JSON.stringify(['l1', 'l2'].map(side =>
  ['getOutboundImplementation', 'getInboundImplementation'].map(getter =>
    doc.getIn([side, 'contracts', side + 'VerifierResolver', 'checks', getter]).toJSON()))));
''', str(out)], cwd=ROOT / 'libs/state-mate', text=True))
        for chain, (outbound, inbound) in zip(['sepolia', leaf], probes):
            assert {'args': [str(data[chain]['ccip']['chain_selector']), '0x'], 'result': ZERO} in outbound
            assert {'args': ['0x00000000'], 'result': ZERO} in inbound


def test_shared_lockbox_is_rejected(records):
    directory, data = records
    data['sepolia']['deployed']['lock_boxes'][1]['lock_box'] = addr(100)
    (directory / 'sepolia.json').write_text(json.dumps(data['sepolia']))
    result = node('render-multichain-state.cjs', TARGET / 'state-mate/wsteth.yaml', directory,
                  directory / 'before.json', 'base_sepolia', directory / 'out.yaml', check=False)
    assert result.returncode != 0
    assert 'distinct lockbox' in result.stderr


def test_legacy_policy_requires_single_lane_and_legacy_token(records):
    directory, data = records
    state = directory / 'l2.json'
    state.write_text('{}')
    policy = directory / 'legacy.json'
    args = [directory, 'mantle_sepolia', state, policy]
    result = node('legacy-ccv-policy.cjs', *args, check=False)
    assert result.returncode != 0  # two hub lanes cannot acquire implicit expectations
    assert 'single-lane' in result.stderr
    data['sepolia']['remote_lanes'] = data['sepolia']['remote_lanes'][:1]
    data['sepolia']['deployed']['lock_boxes'] = data['sepolia']['deployed']['lock_boxes'][:1]
    (directory / 'sepolia.json').write_text(json.dumps(data['sepolia']))
    node('legacy-ccv-policy.cjs', *args)
    (directory / 'l2-state.json').write_text('{}')
    output = directory / 'legacy.yaml'
    node('render-multichain-state.cjs', TARGET / 'state-mate/wsteth.yaml', directory,
         policy, 'mantle_sepolia', output)
    compose_projection(output, 'mantle_sepolia')
    assert '0xdecafbad' in output.read_text()
    state.write_text(json.dumps({'wstETHProxyAdmin': addr(200)}))
    result = node('legacy-ccv-policy.cjs', *args, check=False)
    assert result.returncode != 0
    assert 'explicit ccv-policy' in result.stderr


def test_replace_verifier_orders_inbound_then_outbound_then_retirement(records):
    directory, data = records
    policy = json.loads((directory / 'before.json').read_text())
    for spec in policy['chains'].values():
        spec['localResolver']['inbound'] = {'0x12345678': addr(150)}
        spec['localResolver']['outbound'] = {r: addr(150) for r in spec['lanes']}
    (directory / 'after.json').write_text(json.dumps(policy))
    out = directory / 'plan.json'
    node('plan-ccv-update.cjs', directory, directory / 'before.json', directory / 'after.json', out)
    actions = json.loads(out.read_text())['actions']
    assert len(actions) == 9
    assert [a['phase'][0] for a in actions] == list('111222444')
    assert all(a['arguments'] == [['0xdecafbad', ZERO]] for a in actions[-3:])
    for action in actions:
        assert action['to'] == data[action['chain']]['deployed']['pool_operation_manager']
        decoded = subprocess.check_output(['cast', 'decode-calldata', 'directCall(address,uint256,bytes)', action['data']], text=True)
        assert action['target'].lower() in decoded.lower()


def test_external_provider_requires_explicit_verification_expectations(records):
    directory, _ = records
    policy = json.loads((directory / 'before.json').read_text())
    policy['chains']['sepolia']['lanes']['base_sepolia']['outbound'].append(addr(160))
    (directory / 'after.json').write_text(json.dumps(policy))
    result = node('plan-ccv-update.cjs', directory, directory / 'before.json', directory / 'after.json', directory / 'plan.json', check=False)
    assert result.returncode != 0 and 'needs verification expectations' in result.stderr


def test_unchanged_policy_has_no_transactions(records):
    directory, _ = records
    node('plan-ccv-update.cjs', directory, directory / 'before.json', directory / 'before.json', directory / 'plan.json')
    assert json.loads((directory / 'plan.json').read_text())['actions'] == []


def test_provider_onboarding_covers_both_directions_and_all_spokes(records):
    directory, data = records
    policy = json.loads((directory / 'before.json').read_text())
    for index, spec in enumerate(policy['chains'].values()):
        resolver, impl = addr(200 + index), addr(210 + index)
        for lane in spec['lanes'].values():
            lane['inbound'].append(resolver)
            lane['outbound'].append(resolver)
        spec['externalResolvers'] = {resolver: {
            'outbound': {r: impl for r in spec['lanes']},
            'inbound': {'0x12345678': impl},
        }}
    (directory / 'after.json').write_text(json.dumps(policy))
    node('plan-ccv-update.cjs', directory, directory / 'before.json', directory / 'after.json', directory / 'plan.json')
    actions = json.loads((directory / 'plan.json').read_text())['actions']
    assert len(actions) == 3
    assert sum(len(a['arguments']) for a in actions) == 4
    assert all(len(lane[1]) == len(lane[3]) == 2 for a in actions for lane in a['arguments'])
    node('render-multichain-state.cjs', TARGET / 'state-mate/wsteth.yaml', directory,
         directory / 'after.json', 'base_sepolia', directory / 'out.yaml')
    text = (directory / 'out.yaml').read_text()
    assert addr(200) in text and addr(202) in text
    assert addr(210) in text and addr(212) in text
    compose_projection(directory / 'out.yaml', 'base_sepolia')
    # Run the actual ABI completeness guard that previously rejected provider entries.
    result = subprocess.run(['node', '--require', 'ts-node/register', '--require', 'tsconfig-paths/register', '-e', """
const fs = require('fs'), YAML = require('yaml'), assert = require('assert');
const {SectionValidatorBase} = require('./src/section-validators/base');
const {stats} = require('./src/context');
const doc = YAML.parseDocument(fs.readFileSync(process.argv[1], 'utf8'));
const abi = JSON.parse(fs.readFileSync(process.argv[2])).VersionedVerifierResolver;
for (const side of ['l1', 'l2']) {
  const checks = doc.getIn([side, 'contracts', 'externalResolver0', 'checks']).toJSON();
  SectionValidatorBase.prototype._reportNonCoveredNonMutableChecks.call(
    {sectionName: side}, 'externalResolver0', abi, Object.keys(checks));
}
assert.equal(stats.errors, 0);
// Confirm the guard catches the original two-getter-only entry.
SectionValidatorBase.prototype._reportNonCoveredNonMutableChecks.call(
  {sectionName: 'l1'}, 'original', abi, ['getOutboundImplementation', 'getInboundImplementation']);
assert(stats.errors > 0);
""", str(directory / 'out.yaml'), str(TARGET / 'state-mate/abis.json')],
        cwd=ROOT / 'libs/state-mate', text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr



@pytest.mark.parametrize('missing_state', [False, True])
@pytest.mark.parametrize('has_policy', [False, True])
def test_snapshot_keeps_all_records_and_requires_matching_state(records, missing_state, has_policy):
    directory, data = records
    chain_dir = directory / 'config/chains'
    chain_dir.mkdir(parents=True)
    (directory / 'state').mkdir()
    (directory / '.active-run').mkdir()
    (directory / '.active-run/run.json').write_text(json.dumps({
        'l2Chain': 'mantle_sepolia', 'l2Chains': ['mantle_sepolia', 'base_sepolia'], 'chainStateFiles': True,
    }))
    for index, (chain, record) in enumerate(data.items()):
        record['addresses']['token'] = addr(300 + index)
        (chain_dir / f'{chain}.json').write_text(json.dumps(record))
        state_name = 'l1' if chain == 'sepolia' else chain
        if not (missing_state and chain == 'base_sepolia'):
            (directory / f'state/{state_name}.json').write_text(json.dumps({
                'wstETH': record['addresses']['token'],
                'poolOperationManager': record['deployed']['pool_operation_manager'],
            }))
    if has_policy:
        (directory / 'config/ccv-policy.json').write_text((directory / 'before.json').read_text())
    original = {p.name: p.read_bytes() for p in chain_dir.iterdir()}
    result = subprocess.run([sys.executable, str(SCRIPTS / 'snapshot-record.py'), 'test'],
                            cwd=directory, capture_output=True, text=True)
    snapshot = directory / 'config/chains.live-test'
    assert {p.name: p.read_bytes() for p in chain_dir.iterdir()} == original
    if missing_state:
        assert result.returncode != 0 and not snapshot.exists()
    else:
        assert result.returncode == 0, result.stderr
        assert (snapshot / 'state/base_sepolia.json').is_file()
        assert (snapshot / 'ccv-policy.json').is_file() == has_policy
        assert all((snapshot / name).read_bytes() == content for name, content in original.items())


@pytest.mark.parametrize('change', ['reorder', 'missing', 'extra', 'duplicate', 'wrong_binding'])
def test_complete_tables_ignore_only_enumeration_order(records, change):
    directory, _ = records
    output = directory / 'tables.yaml'
    node('render-multichain-state.cjs', TARGET / 'state-mate/wsteth.yaml', directory,
         directory / 'before.json', 'base_sepolia', output)
    result = subprocess.run(['node', '-e', '''
const {verifyTables} = require(process.argv[1]);
const tables = require(process.argv[2]);
const change = process.argv[3];
verifyTables(tables, async entry => {
  const rows = structuredClone(entry.result).reverse();
  if (entry.getter === 'getAllLockBoxConfigs') {
    if (change === 'missing') rows.pop();
    if (change === 'extra') rows.push(['999', rows[0][1]]);
    if (change === 'duplicate') rows[1] = rows[0];
    if (change === 'wrong_binding') [rows[0][1], rows[1][1]] = [rows[1][1], rows[0][1]];
  }
  return rows;
}).catch(error => {console.error(error); process.exitCode = 1;});
''', str(SCRIPTS / 'verify-state-tables.cjs'), str(output) + '.tables.json', change],
                            text=True, capture_output=True)
    assert (result.returncode == 0) == (change == 'reorder'), result.stdout + result.stderr


def test_selected_leaf_does_not_require_other_spokes_deployment(records):
    directory, data = records
    del data['base_sepolia']['ccv']
    (directory / 'base_sepolia.json').write_text(json.dumps(data['base_sepolia']))
    output = directory / 'partial.yaml'
    node('render-multichain-state.cjs', TARGET / 'state-mate/wsteth.yaml', directory,
         directory / 'before.json', 'mantle_sepolia', output)
    tables = json.loads(Path(str(output) + '.tables.json').read_text())
    hub = next(t for t in tables if t['getter'] == 'getAllCCVConfigs' and t['chain'] == 'sepolia')
    assert len(hub['result']) == 2  # selecting a leaf must not hide hub configuration
    result = node('render-multichain-state.cjs', TARGET / 'state-mate/wsteth.yaml', directory,
                  directory / 'before.json', 'base_sepolia', output, check=False)
    assert result.returncode != 0 and 'base_sepolia: incomplete CCV deployment' in result.stderr
    result = node('plan-ccv-update.cjs', directory, directory / 'before.json',
                  directory / 'before.json', directory / 'plan.json', check=False)
    assert result.returncode != 0 and 'base_sepolia: incomplete CCV deployment' in result.stderr


@pytest.mark.parametrize('transparent', [False, True])
def test_rendered_proxy_owner_check_runs_in_state_mate(records, transparent):
    directory, _ = records
    (directory / 'l2-state.json').write_text(json.dumps({'wstETHProxyAdmin': addr(400)} if transparent else {}))
    output = directory / 'owner.yaml'
    node('render-multichain-state.cjs', TARGET / 'state-mate/wsteth.yaml', directory,
         directory / 'before.json', 'base_sepolia', output)
    compose_projection(output, 'base_sepolia')
    result = subprocess.run(['node', '--require', 'ts-node/register', '--require', 'tsconfig-paths/register', '-e', '''
const fs = require('fs'), YAML = require('yaml'), assert = require('assert');
const {checkProxyAdmin} = require('./src/section-validators/implementation');
const {stats} = require('./src/context');
const [main, book, inputs] = process.argv.slice(1, 4).map(p => fs.readFileSync(p, 'utf8'));
const doc = YAML.parse([inputs, book, main].join('\\n'), {maxAliasCount: -1});
const entry = doc.l2.contracts.l2WstETH;
const transparent = process.argv[4] === 'true';
assert.equal(Boolean(entry.proxyAdminOwner), transparent);
const word = a => '0x' + a.slice(2).padStart(64, '0');
const provider = {getStorage: async () => word(entry.proxyAdmin), call: async () => word(entry.proxyAdminOwner)};
(async () => {
  await checkProxyAdmin(provider, entry);
  assert.equal(stats.errors, 0);
  assert.equal(stats.totalChecks, transparent ? 2 : 1);
  if (transparent) {
    provider.call = async () => word('0x' + '1'.repeat(40));
    await checkProxyAdmin(provider, entry);
    assert.equal(stats.errors, 1);
  }
})().catch(e => {console.error(e); process.exitCode = 1;});
''', str(output), str(directory / 'deployed.yaml'), str(TARGET / 'state-mate/wsteth.inputs.base_sepolia.yaml'), str(transparent).lower()],
        cwd=ROOT / 'libs/state-mate', text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    if transparent:
        assert 'proxyAdminOwner' in result.stdout

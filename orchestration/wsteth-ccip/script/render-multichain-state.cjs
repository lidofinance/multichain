#!/usr/bin/env node
// Expand the maintained per-pair matrix without weakening whole-table assertions.
const fs = require('node:fs');
const path = require('node:path');
const { load, ZERO, address } = require('./ccv-policy.cjs');
const smDir = path.resolve(process.env.STATE_MATE_DIR || path.join(__dirname, '../../../libs/state-mate'));
const YAML = require(require.resolve('yaml', { paths: [smDir] }));
const [source, recordDir, policyPath, leaf, destination, statePath] = process.argv.slice(2);
if (!statePath) throw new Error('L2 state file is required to select the token proxy ownership checks');
const state = JSON.parse(fs.readFileSync(statePath));
const { records, resolved } = load(recordDir, policyPath, ['sepolia', leaf]);
const hub = records.sepolia;
const remotes = hub.remote_lanes.map(l => l.remote_chain_name);
if (!remotes.includes(leaf)) throw new Error('Selected leaf absent from hub');
const boxes = hub.deployed.lock_boxes;
for (const box of boxes) address(box.lock_box);
if (hub.remote_lanes.some(l => l.is_siloed !== true) ||
    boxes.length !== remotes.length || new Set(boxes.map(b => b.remote_chain_name)).size !== boxes.length ||
    new Set(boxes.map(b => b.lock_box.toLowerCase())).size !== boxes.length ||
    boxes.some(b => !remotes.includes(b.remote_chain_name)))
  throw new Error('Every siloed lane must have its own distinct lockbox');
const doc = YAML.parseDocument(fs.readFileSync(source, 'utf8'));
if (doc.errors.length) throw doc.errors[0];
if (state.wstETHProxyAdmin) {
  address(state.wstETHProxyAdmin);
  doc.setIn(['l2', 'contracts', 'l2WstETH', 'proxyAdminOwner'], new YAML.Alias('l2OptimismBridgeExecutor'));
} else {
  doc.deleteIn(['l2', 'contracts', 'l2WstETH', 'proxyAdminOwner']);
}
const set = (side, contract, getter, value) => doc.setIn([side, 'contracts', contract, 'checks', getter], value);
// EnumerableSet/Map order is not a configuration invariant. The companion checker compares
// complete tables as multisets, including cardinality; all per-key checks stay in state-mate.
const tables = [];
const table = (side, chain, contract, target, getter, result) => {
  // State-mate requires every view in its ABI to be accounted for. Explicit null marks
  // delegation; the mandatory companion check runs first and fails the whole step on mismatch.
  set(side, contract, getter, null);
  doc.getIn([side, 'contracts', contract, 'checks'], true).items
    .find(item => item.key.value === getter).comment = ' checked by verify-state-tables.cjs';
  tables.push({side, chain, target: address(target), getter, result});
};
table('l1', 'sepolia', 'l1TokenPool', hub.deployed.token_pool, 'getAllLockBoxConfigs',
  remotes.map(r => [String(records[r].ccip.chain_selector), boxes.find(b => b.remote_chain_name === r).lock_box]));
for (const [side, chain] of [['l1', 'sepolia'], ['l2', leaf]]) {
  const spec = resolved[chain];
  const selectedSelector = String(records[side === 'l1' ? leaf : 'sepolia'].ccip.chain_selector);
  const selected = spec.lanes.find(l => l[0] === selectedSelector);
  const hooks = side + 'AdvancedPoolHooks', resolver = side + 'VerifierResolver';
  table(side, chain, side + 'TokenPool', records[chain].deployed.token_pool, 'getSupportedChains',
    records[chain].remote_lanes.map(l => String(records[l.remote_chain_name].ccip.chain_selector)));
  table(side, chain, hooks, records[chain].deployed.advanced_pool_hooks, 'getAllCCVConfigs', spec.lanes);
  set(side, hooks, 'getCCVConfig', [
    {args: [selectedSelector], result: selected.slice(1)},
    {args: [String(records[chain].ccip.chain_selector)], result: [[], [], [], []]},
  ]);
  set(side, hooks, 'getRequiredCCVs', ['0', '1000000000000000000000000'].flatMap(amount =>
    [0, 1].map(direction => ({args: [ZERO, selectedSelector, amount, '0x00000000', '0x', direction], result: selected[direction === 0 ? 1 : 3]}))));
  table(side, chain, resolver, records[chain].ccv.verifier_resolver, 'getAllOutboundImplementations', spec.outbound.filter(v => v[1] !== ZERO));
  table(side, chain, resolver, records[chain].ccv.verifier_resolver, 'getAllInboundImplementations', spec.inbound.filter(v => v[1] !== ZERO));
  set(side, resolver, 'getOutboundImplementation', [...spec.outbound.map(([selector, impl]) => ({args: [selector, '0x'], result: impl})),
    {args: [String(records[chain].ccip.chain_selector), '0x'], result: ZERO}]);
  set(side, resolver, 'getInboundImplementation', [...spec.inbound.map(([tag, impl]) => ({args: [tag], result: impl})),
    {args: ['0x00000000'], result: ZERO}]);
  for (const [i, external] of spec.external.entries()) {
    doc.setIn([side, 'contracts', `externalResolver${i}`], {
      name: 'VersionedVerifierResolver', address: external.address,
      checks: {
        // Provider governance and global tables can include other customers' lanes/versions.
        // This policy verifies only the declared lane/version bindings, not provider-wide state.
        owner: null,
        typeAndVersion: null,
        getFeeAggregator: null,
        getAllOutboundImplementations: null,
        getAllInboundImplementations: null,
        getOutboundImplementation: external.outbound.map(([s, impl]) => ({args: [s, '0x'], result: impl})),
        getInboundImplementation: external.inbound.map(([tag, impl]) => ({args: [tag], result: impl})),
      },
    });
  }
}
fs.writeFileSync(destination, doc.toString({verifyAliasOrder: false}));
fs.writeFileSync(destination + '.tables.json', JSON.stringify(tables, null, 2) + '\n');

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
// The hub chain follows the run (L1_CHAIN, exported by workspace.py); the scratch target keeps sepolia.
const l1 = process.env.L1_CHAIN || 'sepolia';
const { records, resolved } = load(recordDir, policyPath, [l1, leaf]);
const hub = records[l1];
const remotes = hub.remote_lanes.map(l => l.remote_chain_name);
if (!remotes.includes(leaf)) throw new Error('Selected leaf absent from hub');
const boxes = hub.deployed.lock_boxes;
for (const box of boxes) address(box.lock_box);
// Lockbox topology, as 1_Deploy builds it from remote_lanes: every siloed lane has a lockbox of its
// own that no other lane shares; the lanes that are not siloed share exactly one lockbox; one entry
// per lane and nothing else.
const boxOf = Object.fromEntries(boxes.map(b => [b.remote_chain_name, b.lock_box.toLowerCase()]));
if (boxes.length !== remotes.length || Object.keys(boxOf).length !== remotes.length || remotes.some(r => !boxOf[r]))
  throw new Error('Every lane must have exactly one lockbox entry');
const siloed = hub.remote_lanes.filter(l => l.is_siloed === true).map(l => l.remote_chain_name);
const unsiloed = remotes.filter(r => !siloed.includes(r));
for (const lane of siloed) {
  if (remotes.some(r => r !== lane && boxOf[r] === boxOf[lane])) throw new Error(`Every siloed lane must have its own distinct lockbox: ${lane} shares one`);
}
if (new Set(unsiloed.map(r => boxOf[r])).size > 1) throw new Error('Lanes that are not siloed must share exactly one lockbox');
const doc = YAML.parseDocument(fs.readFileSync(source, 'utf8'));
if (doc.errors.length) throw doc.errors[0];
if (state.wstETHProxyAdmin) {
  address(state.wstETHProxyAdmin);
  doc.setIn(['l2', 'contracts', 'l2WstETH', 'proxyAdminOwner'], new YAML.Alias('l2OptimismBridgeExecutor'));
} else {
  doc.deleteIn(['l2', 'contracts', 'l2WstETH', 'proxyAdminOwner']);
}
const set = (side, contract, getter, value) => doc.setIn([side, 'contracts', contract, 'checks', getter], value);
// Append argument sets to a getter the wiring already declares (its own entries, aliases included, stay).
const append = (side, contract, getter, entries) => {
  const key = [side, 'contracts', contract, 'checks', getter];
  if (!doc.hasIn(key)) throw new Error(`${side}/${contract}: the wiring declares no ${getter} check to extend`);
  for (const entry of entries) doc.addIn(key, entry);
};
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
const selectorOf = chain => String(records[chain].ccip.chain_selector);
table('l1', l1, 'l1TokenPool', hub.deployed.token_pool, 'getAllLockBoxConfigs',
  remotes.map(r => [selectorOf(r), boxes.find(b => b.remote_chain_name === r).lock_box]));
// Lanes other than the selected leaf: their lockbox map, and for the lanes the hub took over from an
// existing pool (imported_lanes), the remote pools, remote token and limits the inventory recorded.
const others = remotes.filter(r => r !== leaf);
if (others.length) {
  append('l1', 'l1TokenPool', 'getLockBox', others.map(r => ({args: [selectorOf(r)], result: boxes.find(b => b.remote_chain_name === r).lock_box})));
  append('l1', 'l1TokenPool', 'isSupportedChain', others.map(r => ({args: [selectorOf(r)], result: true})));
}
const imported = Object.entries(hub.imported_lanes || {});
for (const [lane, spec] of imported) {
  if (!remotes.includes(lane)) throw new Error(`imported lane ${lane} is not a remote lane of the hub`);
  const sel = selectorOf(lane);
  const limit = l => [null, null, l.enabled, String(l.capacity), String(l.rate)];
  append('l1', 'l1TokenPool', 'getRemotePools', [{args: [sel], result: spec.remote_pools.map(p => address(p))}]);
  append('l1', 'l1TokenPool', 'getRemoteToken', [{args: [sel], result: address(records[lane].addresses.token)}]);
  append('l1', 'l1TokenPool', 'getCurrentRateLimiterState', [{args: [sel, false], result: [limit(spec.rate_limits.outbound), limit(spec.rate_limits.inbound)]}]);
}
// Every lockbox except the selected leaf's (the wiring declares that one as l1LockBox, with the
// callers the migration adds): owned by the timelock, holding the hub token, callable by the hub only.
const declared = boxOf[leaf];
const otherBoxes = [...new Set(remotes.filter(r => boxOf[r] !== declared).map(r => boxOf[r]))];
for (const [i, box] of otherBoxes.entries()) {
  const lanes = remotes.filter(r => boxOf[r] === box);
  const entry = boxes.find(b => b.lock_box.toLowerCase() === box);
  // A YAML node (not a plain object), so the comment stays a comment and does not serialize as a key.
  // The version check follows the wiring's own l1LockBox entry (alias or literal), so a wiring without
  // that anchor still renders.
  const declaredVersion = doc.getIn(['l1', 'contracts', 'l1LockBox', 'checks', 'typeAndVersion'], true);
  const typeAndVersion = declaredVersion && declaredVersion.source ? new YAML.Alias(declaredVersion.source)
    : declaredVersion && declaredVersion.value !== undefined ? declaredVersion.value : 'ERC20LockBox 2.0.0';
  const node = doc.createNode({
    name: 'ERC20LockBox', address: entry.lock_box,
    checks: {
      owner: new YAML.Alias('l1LidoTimelock'),
      typeAndVersion,
      getToken: new YAML.Alias('l1WstETH'),
      getAllAuthorizedCallers: [new YAML.Alias('l1TokenPool')],
    },
  });
  node.commentBefore = ` lockbox of lane(s) ${lanes.join(', ')} (rendered from the hub record)`;
  doc.setIn(['l1', 'contracts', `l1LockBox${i + 1}`], node);
}
for (const [side, chain] of [['l1', l1], ['l2', leaf]]) {
  const spec = resolved[chain];
  const selectedSelector = String(records[side === 'l1' ? leaf : l1].ccip.chain_selector);
  const selected = spec.lanes.find(l => l[0] === selectedSelector);
  if (!selected) throw new Error(`${chain}: the selected lane must declare required CCVs`);
  const hooks = side + 'AdvancedPoolHooks', resolver = side + 'VerifierResolver';
  table(side, chain, side + 'TokenPool', records[chain].deployed.token_pool, 'getSupportedChains',
    records[chain].remote_lanes.map(l => String(records[l.remote_chain_name].ccip.chain_selector)));
  table(side, chain, hooks, records[chain].deployed.advanced_pool_hooks, 'getAllCCVConfigs', spec.lanes);
  // Lanes without required CCVs (imported from an existing pool) have no entry: empty config,
  // nothing required in either direction, at any amount.
  set(side, hooks, 'getCCVConfig', [
    {args: [selectedSelector], result: selected.slice(1)},
    {args: [String(records[chain].ccip.chain_selector)], result: [[], [], [], []]},
    ...spec.unconfigured.map(sel => ({args: [sel], result: [[], [], [], []]})),
  ]);
  set(side, hooks, 'getRequiredCCVs', ['0', '1000000000000000000000000'].flatMap(amount =>
    [0, 1].flatMap(direction => [
      {args: [ZERO, selectedSelector, amount, '0x00000000', '0x', direction], result: selected[direction === 0 ? 1 : 3]},
      ...spec.unconfigured.map(sel => ({args: [ZERO, sel, amount, '0x00000000', '0x', direction], result: []})),
    ])));
  table(side, chain, resolver, records[chain].ccv.verifier_resolver, 'getAllOutboundImplementations', spec.outbound.filter(v => v[1] !== ZERO));
  table(side, chain, resolver, records[chain].ccv.verifier_resolver, 'getAllInboundImplementations', spec.inbound.filter(v => v[1] !== ZERO));
  set(side, resolver, 'getOutboundImplementation', [...spec.outbound.map(([selector, impl]) => ({args: [selector, '0x'], result: impl})),
    ...spec.unconfigured.map(sel => ({args: [sel, '0x'], result: ZERO})),
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

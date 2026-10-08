#!/usr/bin/env node
// Generate reviewable governance calldata; never sign or broadcast.
const fs = require('node:fs');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { load, ZERO, address } = require('./ccv-policy.cjs');
const [recordDir, beforePath, afterPath, output] = process.argv.slice(2);
if (!output) throw new Error('Usage: plan-ccv-update.cjs <records> <before-policy> <after-policy> <output.json>');
const before = load(recordDir, beforePath), after = load(recordDir, afterPath);
if (Object.keys(before.records).sort().join() !== Object.keys(after.records).sort().join())
  throw new Error('CCV update requires the same deployed networks; add lanes separately first');
const encode = (sig, ...args) => execFileSync('cast', ['calldata', sig, ...args], {encoding: 'utf8'}).trim();
const tupleList = values => '[' + values.map(v => '(' + v.map(x => Array.isArray(x) ? '[' + x.join(',') + ']' : x).join(',') + ')').join(',') + ']';
const actions = [];
function action(chain, phase, target, signature, values) {
  const record = after.records[chain];
  const calldata = encode(signature, tupleList(values));
  actions.push({chain, chainId: record.chain.chain_id, phase,
    requiredCaller: address(record.governance_addresses.lido_dao_agent),
    to: address(record.deployed.pool_operation_manager), value: '0',
    target, signature, arguments: values,
    data: encode('directCall(address,uint256,bytes)', target, '0', calldata)});
}
const changes = (oldEntries, entries) => {
  const old = new Map(oldEntries.map(([k, v]) => [k.toLowerCase(), v.toLowerCase()]));
  const desired = new Map(entries.map(([k, v]) => [k.toLowerCase(), v.toLowerCase()]));
  return [...entries.filter(([k, v]) => old.get(k.toLowerCase()) !== v.toLowerCase()),
    ...oldEntries.filter(([k, v]) => !desired.has(k.toLowerCase()) && v !== ZERO).map(([k]) => [k, ZERO])];
};
for (const [chain, spec] of Object.entries(after.resolved)) {
  const old = before.resolved[chain], record = after.records[chain];
  const inbound = changes(old.inbound, spec.inbound);
  const additions = inbound.filter(v => v[1] !== ZERO), removals = inbound.filter(v => v[1] === ZERO);
  if (additions.length) action(chain, '1-prepare-inbound', record.ccv.verifier_resolver,
    'applyInboundImplementationUpdates((bytes4,address)[])', additions);
  const outbound = changes(old.outbound, spec.outbound);
  if (outbound.length) action(chain, '2-switch-outbound', record.ccv.verifier_resolver,
    'applyOutboundImplementationUpdates((uint64,address)[])', outbound);
  const lanes = spec.lanes.filter(l => JSON.stringify(l) !== JSON.stringify(old.lanes.find(o => o[0] === l[0])));
  if (lanes.length) action(chain, '3-set-required-ccvs', record.deployed.advanced_pool_hooks,
    'applyCCVConfigUpdates((uint64,address[],address[],address[],address[])[])', lanes);
  if (removals.length) action(chain, '4-retire-inbound-after-drain', record.ccv.verifier_resolver,
    'applyInboundImplementationUpdates((bytes4,address)[])', removals);
}
actions.sort((a, b) => a.phase.localeCompare(b.phase));
const digest = p => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
fs.writeFileSync(output, JSON.stringify({schemaVersion: 1,
  beforePolicySha256: digest(beforePath), afterPolicySha256: digest(afterPath),
  notice: 'UNEXECUTED. Verify current ownership, policy and deployed code before governance submission. Prepare provider contracts/services first. Coordinate all chains with paused outbound transfers and an explicit in-flight-message policy. A retained dummy inbound version remains an unauthenticated path; retiring it can strand old messages. These calls target POM and must originate from its DAO admin; L2 requires the L1-to-L2 governance route. External provider contracts are NOT configured by this plan.',
  providerExpectations: Object.fromEntries(Object.entries(after.resolved).map(([c, s]) => [c, s.external])),
  actions}, null, 2) + '\n');
console.log(`Wrote ${actions.length} unexecuted governance calls to ${output}`);

// Desired CCV state, shared by the governance planner and state-mate projection.
// No RPC reads: expected values must not be learned from the state being verified.
const fs = require('node:fs');
const path = require('node:path');
const ZERO = '0x' + '0'.repeat(40);
function address(value, allowZero = false) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(value) || (!allowZero && value.toLowerCase() === ZERO))
    throw new Error(`Invalid address: ${value}`);
  return value;
}
function load(recordDir, policyPath, selectedChains) {
  const policy = JSON.parse(fs.readFileSync(policyPath));
  if (policy.schemaVersion !== 1) throw new Error('Unsupported CCV policy version');
  const records = {};
  for (const chain of Object.keys(policy.chains)) {
    if (!/^[a-z0-9_]+$/.test(chain)) throw new Error('Invalid chain name');
    records[chain] = JSON.parse(fs.readFileSync(path.join(recordDir, `${chain}.json`)));
  }
  const selected = selectedChains || Object.keys(policy.chains);
  for (const chain of selected) {
    if (!policy.chains[chain]) throw new Error(`Missing selected policy: ${chain}`);
  }
  const resolved = {};
  for (const [chain, spec] of Object.entries(policy.chains)) {
    if (!selected.includes(chain)) continue;
    const record = records[chain];
    if (!record.ccv?.verifier_resolver || !record.ccv?.message_id_verifier)
      throw new Error(`${chain}: incomplete CCV deployment; missing resolver/verifier record`);
    const remotes = record.remote_lanes.map(l => l.remote_chain_name);
    const sameKeys = (obj, keys) => Object.keys(obj).sort().join() === [...keys].sort().join();
    if (!sameKeys(spec.lanes, remotes) || !sameKeys(spec.localResolver.outbound, remotes))
      throw new Error(`${chain}: CCV policy must cover exactly the configured lanes`);
    const verifier = v => address(v === 'dummy' ? record.ccv.message_id_verifier : v, true);
    const resolver = v => address(v === 'local' ? record.ccv.verifier_resolver : v, true);
    const laneConfigs = remotes.map(remote => {
      if (!records[remote]) throw new Error(`Missing remote policy: ${remote}`);
      const lane = spec.lanes[remote];
      const lists = ['outbound', 'inbound'].map(direction => {
        if (!Array.isArray(lane[direction]) || !lane[direction].length)
          throw new Error(`${chain}/${remote}: explicitly specify required ${direction} CCVs`);
        const values = lane[direction].map(resolver);
        if (new Set(values.map(v => v.toLowerCase())).size !== values.length)
          throw new Error('Duplicate required CCV');
        for (const v of values) {
          if (v !== ZERO && v.toLowerCase() !== record.ccv.verifier_resolver.toLowerCase() &&
              !Object.keys(spec.externalResolvers || {}).some(k => k.toLowerCase() === v.toLowerCase()))
            throw new Error(`${chain}: external resolver ${v} needs verification expectations`);
        }
        return values;
      });
      return [String(records[remote].ccip.chain_selector), lists[0], [], lists[1], []];
    });
    const inbound = Object.entries(spec.localResolver.inbound).map(([tag, impl]) => {
      if (!/^0x[0-9a-fA-F]{8}$/.test(tag) || tag === '0x00000000') throw new Error('Invalid version tag');
      return [tag, verifier(impl)];
    });
    const outbound = remotes.map(r => [String(records[r].ccip.chain_selector), verifier(spec.localResolver.outbound[r])]);
    const external = Object.entries(spec.externalResolvers || {}).map(([resolverAddress, config]) => {
      address(resolverAddress);
      if (!config.outbound || !config.inbound || !Object.keys(config.inbound).length)
        throw new Error('External resolver needs outbound and inbound implementation expectations');
      const out = Object.entries(config.outbound).map(([remote, impl]) => {
        if (!records[remote] || !remotes.includes(remote)) throw new Error('Unknown external resolver lane');
        return [String(records[remote].ccip.chain_selector), address(impl)];
      });
      const incoming = Object.entries(config.inbound).map(([tag, impl]) => {
        if (!/^0x[0-9a-fA-F]{8}$/.test(tag) || tag === '0x00000000') throw new Error('Invalid external version');
        return [tag, address(impl)];
      });
      for (const lane of laneConfigs) {
        if (lane[1].some(v => v.toLowerCase() === resolverAddress.toLowerCase()) && !out.some(v => v[0] === lane[0]))
          throw new Error('Missing external outbound implementation expectation');
      }
      return { address: resolverAddress, outbound: out, inbound: incoming };
    });
    resolved[chain] = { lanes: laneConfigs, inbound, outbound, external };
  }
  return { records, resolved, policy };
}
module.exports = { load, ZERO, address };

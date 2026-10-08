#!/usr/bin/env node
// Historical single-lane expectation, not a reconstruction from observed RPC state.
const fs = require('node:fs');
const path = require('node:path');
const [recordDir, leaf, statePath, destination] = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(statePath));
if (state.wstETHProxyAdmin) throw new Error('Modern records require an explicit ccv-policy.json');
const chains = {};
for (const [chain, remote] of [['sepolia', leaf], [leaf, 'sepolia']]) {
  const record = JSON.parse(fs.readFileSync(path.join(recordDir, `${chain}.json`)));
  if (record.remote_lanes.length !== 1 || record.remote_lanes[0].remote_chain_name !== remote)
    throw new Error('Only a reciprocal single-lane legacy record can use the historical dummy policy');
  chains[chain] = {
    lanes: {[remote]: {outbound: ['local'], inbound: ['local']}},
    localResolver: {outbound: {[remote]: 'dummy'}, inbound: {'0xdecafbad': 'dummy'}},
  };
}
fs.writeFileSync(destination, JSON.stringify({schemaVersion: 1, chains}, null, 2) + '\n');

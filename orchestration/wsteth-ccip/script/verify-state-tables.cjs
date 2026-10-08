#!/usr/bin/env node
// Full-table equality without assuming EnumerableSet/Map enumeration order.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const signatures = {
  getSupportedChains: 'uint64[]',
  getAllLockBoxConfigs: '(uint64,address)[]',
  getAllCCVConfigs: '(uint64,address[],address[],address[],address[])[]',
  getAllOutboundImplementations: '(uint64,address)[]',
  getAllInboundImplementations: '(bytes4,address)[]',
};
function normalized(value) {
  if (Array.isArray(value)) return value.map(normalized);
  return String(value).toLowerCase();
}
function rows(value) {
  // Sort only the outer enumeration. Tuple fields and per-lane arrays keep their meaning.
  return Array.from(value, row => JSON.stringify(normalized(row))).sort();
}
async function verifyTables(tables, read, log = console.log) {
  assert.equal(tables.length, 9, 'Expected the complete hub/spoke table manifest');
  for (const entry of tables) {
    assert.ok(signatures[entry.getter], `Unknown table getter ${entry.getter}`);
    const actual = await read(entry);
    assert.deepEqual(rows(actual), rows(entry.result), `${entry.chain}: ${entry.getter} differs from declared intent`);
    log(`  ✓ ${entry.chain}: ${entry.getter} (${actual.length} rows; enumeration order ignored)`);
  }
}
async function main() {
  const [manifest, l1, l2] = process.argv.slice(2);
  const smDir = path.resolve(process.env.STATE_MATE_DIR || path.join(__dirname, '../../../libs/state-mate'));
  const { Contract, JsonRpcProvider } = require(require.resolve('ethers', {paths: [smDir]}));
  const providers = {l1: new JsonRpcProvider(l1), l2: new JsonRpcProvider(l2)};
  try {
    const blocks = {};
    for (const [side, provider] of Object.entries(providers)) {
      blocks[side] = await provider.getBlockNumber();
      console.log(`# ${side} table checks at block ${blocks[side]}`);
    }
    await verifyTables(JSON.parse(fs.readFileSync(manifest)), async entry => {
      const contract = new Contract(entry.target,
        [`function ${entry.getter}() view returns (${signatures[entry.getter]})`], providers[entry.side]);
      return contract[entry.getter]({blockTag: blocks[entry.side]});
    });
  } finally {
    for (const provider of Object.values(providers)) provider.destroy();
  }
}
module.exports = {verifyTables};
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });

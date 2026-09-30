#!/usr/bin/env node
// Adapt our maintained, name-keyed check ABIs to state-mate's per-deployment chain:address store.
// No explorer fetch: fork-only contracts are not published there.
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const smDir = path.resolve(process.env.STATE_MATE_DIR || path.join(__dirname, '../../../libs/state-mate'));
const YAML = require(require.resolve('yaml', { paths: [smDir] }));

const [configPath, deployedPath, inputsPath] = process.argv.slice(2);
if (!configPath || !deployedPath || !inputsPath) {
  throw new Error('Usage: build-state-mate-abis.cjs <config> <deployed> <inputs>');
}
const directory = path.dirname(configPath);
const abis = JSON.parse(fs.readFileSync(path.join(directory, 'abis.json'), 'utf8'));
// These trusted repository files form one YAML document with shared anchors, as in state-mate.
const source = [inputsPath, deployedPath, configPath].map(p => fs.readFileSync(p, 'utf8')).join('\n');
const document = YAML.parse(source, { maxAliasCount: -1 });
const store = {};
for (const section of Object.values(document)) {
  if (!section || typeof section !== 'object' || !section.rpcUrl) continue;
  if (!/^\d+$/.test(String(section.chainId)) || BigInt(section.chainId) <= 0n) {
    throw new Error(`Invalid chainId: ${section.chainId}`);
  }
  for (const { name, address, implementation, proxyName } of Object.values(section.contracts || {})) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(address)) throw new Error(`Invalid address for ${name}`);
    if (!Array.isArray(abis[name])) throw new Error(`Missing maintained ABI for ${name}`);
    const abiAddress = implementation || address;
    if (!/^0x[0-9a-fA-F]{40}$/.test(abiAddress)) throw new Error(`Invalid implementation for ${name}`);
    const key = `${BigInt(section.chainId)}:${abiAddress.toLowerCase()}`;
    if (store[key] && store[key].name !== name) throw new Error(`Conflicting ABI names for ${key}`);
    store[key] = { name, abi: abis[name] };
    if (implementation) {
      if (!Array.isArray(abis[proxyName])) throw new Error(`Missing maintained proxy ABI for ${proxyName}`);
      const proxyKey = `${BigInt(section.chainId)}:${address.toLowerCase()}`;
      if (store[proxyKey] && store[proxyKey].name !== proxyName) throw new Error(`Conflicting ABI names for ${proxyKey}`);
      store[proxyKey] = { name: proxyName, abi: abis[proxyName] };
    }
  }
}
if (Object.keys(store).length === 0) throw new Error('No contract ABIs were bound');
fs.writeFileSync(path.join(directory, 'abis.json.gz'), zlib.gzipSync(JSON.stringify(store)));
console.log(`Bound ${Object.keys(store).length} maintained ABIs to deployment chain IDs and addresses`);

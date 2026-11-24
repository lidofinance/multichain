'use strict';
// Uses the installed, pinned core dependencies. Never print wallet/provider objects or raw errors.
const fs = require('node:fs');
const path = require('node:path');
const {createRequire} = require('node:module');
const ROOT = path.resolve(__dirname, '../../../..');
const OPS = path.join(ROOT, 'orchestration/wsteth-ccip');
const dep = createRequire(path.join(ROOT, 'components/core/package.json'));
const ethers = dep('ethers');
const toml = dep('@iarna/toml');
const ACTORS = path.join(OPS, 'docs/SEPOLIA-FRESH-DEPLOY-ACTORS.json');
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const write = (file, data) => {
  fs.mkdirSync(path.dirname(file), {recursive: true});
  fs.writeFileSync(file + '.tmp', JSON.stringify(data, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2) + '\n');
  fs.renameSync(file + '.tmp', file);
};
function environment() {
  const file = path.join(OPS, '.env');
  return {...(fs.existsSync(file) ? dep('dotenv').parse(fs.readFileSync(file)) : {}), ...process.env};
}
function profile(file = process.env.WSTETH_ACCESS_PROFILE) {
  if (!file) throw new Error('Select the controlled Sepolia scratch target');
  const p = read(file);
  if (p.kind !== 'controlled-sepolia-rehearsal' || p.schemaVersion !== 1 ||
      JSON.stringify(p.chainIds) !== '[11155111,84532,5003]') throw new Error('Invalid testnet access profile');
  const t = p.timing;
  if(p.oracleQuorum!==2 || p.dsmQuorum!==2 || BigInt(p.initialTldoSupply)<=0n || t.maximumConfigurableDelay!==600)
    throw new Error('Controlled profile requires 2-of-3 committees, positive TLDO supply and a 600-second delay ceiling');
  // Mainnet Optimism/Mantle executors add no wait after message delivery.
  if (t.l2Executor !== 0) throw new Error('L2 executor delay must remain 0, matching the mainnet baseline');
  for (const name of ['voting','objection','dgAfterSubmit','dgAfterSchedule','ccip','maximumConfigurableDelay']) {
    if (!Number.isInteger(t[name]) || t[name] <= 0 || t[name] > 600) throw new Error('Delay must be in 1..600 seconds: ' + name);
  }
  if (t.objection >= t.voting || t.voting + t.dgAfterSubmit + t.dgAfterSchedule + t.l2Executor > 600 ||
      t.proposalExpiry <= t.ccip || t.executionGrace <= t.l2Executor) throw new Error('Invalid combined timing budget');
  return p;
}
function actors(file = process.env.WSTETH_ACTORS_FILE || ACTORS) { return read(file); }
function wallets(manifest = actors(), env = environment()) {
  if (!env.ACTORS_MNEMONIC || !env.DEPLOYER_PRIVATE_KEY) throw new Error('Local actor mnemonic and deployer key are required');
  const result = {};
  const banned = new Set([1,2].map(n => new ethers.Wallet(ethers.toBeHex(n,32)).address.toLowerCase()));
  for (const phrase of ['test test test test test test test test test test test junk',
    'myth like bonus scare over problem client lizard pioneer submit female collect',
    'candy maple cake sugar pudding cream honey rich smooth crumble sweet treat']) {
    for(let i=0;i<20;i++) banned.add(ethers.HDNodeWallet.fromPhrase(phrase,'',`m/44'/60'/0'/0/${i}`).address.toLowerCase());
  }
  const seen = new Set();
  for (const a of manifest.actors) {
    const w = a.index === null ? new ethers.Wallet(env.DEPLOYER_PRIVATE_KEY) :
      ethers.HDNodeWallet.fromPhrase(env.ACTORS_MNEMONIC, '', `m/44'/60'/0'/0/${a.index}`);
    if (w.address.toLowerCase() !== a.address.toLowerCase() || banned.has(w.address.toLowerCase()) || seen.has(w.address)) {
      throw new Error('Actor address/key mismatch, duplicate or public test key: ' + a.id);
    }
    seen.add(w.address); result[a.id] = w;
  }
  return result;
}
const address = (record, key) => {
  const v = record[key];
  const a = typeof v === 'string' ? v : v?.proxy?.address || v?.address;
  if (!ethers.isAddress(a) || a === ethers.ZeroAddress) throw new Error('Missing contract address: ' + key);
  return ethers.getAddress(a);
};
const call = (to, signature, args = [], value = 0n) => ({to: ethers.getAddress(to), value: value.toString(),
  data: new ethers.Interface(['function ' + signature]).encodeFunctionData(signature.split('(')[0], args)});
function callsScript(calls) {
  return calls.reduce((out,c) => {
    if (BigInt(c.value || 0)) throw new Error('Aragon CallsScript cannot carry ETH; use Agent.execute');
    return out + ethers.getAddress(c.to).slice(2).toLowerCase() +
      ethers.toBeHex(ethers.dataLength(c.data),4).slice(2) + c.data.slice(2);
  }, '0x00000001');
}
module.exports = {ROOT, OPS, dep, ethers, toml, ACTORS, read, write, environment, profile, actors, wallets, address, call, callsScript};

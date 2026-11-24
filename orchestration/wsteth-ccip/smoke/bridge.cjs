#!/usr/bin/env node
'use strict';
// Public testnet operations, separate from the immutable deployment pipeline.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const C = require('../script/testnet/context.cjs');
const E = C.ethers;
const ABI = E.AbiCoder.defaultAbiCoder();
const CHAINS = {sepolia: 11155111, base_sepolia: 84532, mantle_sepolia: 5003};
const SPOKES = ['base_sepolia', 'mantle_sepolia'];
const DEFAULT_BUNDLE = path.join(C.OPS, 'docs/SEPOLIA-FRESH-DEPLOY-2026-11-04.json');
const AMOUNT = E.parseEther('0.001');
const API = 'https://api.ccip.chain.link/v2/messages/';
const TOKEN_ABI = ['function balanceOf(address) view returns(uint256)', 'function totalSupply() view returns(uint256)',
  'function decimals() view returns(uint8)', 'function allowance(address,address) view returns(uint256)',
  'function approve(address,uint256) returns(bool)', 'function getStETHByWstETH(uint256) view returns(uint256)',
  'event Transfer(address indexed from,address indexed to,uint256 value)'];
const MESSAGE = '(bytes receiver,bytes data,(address token,uint256 amount)[] tokenAmounts,address feeToken,bytes extraArgs)';
const ROUTER_ABI = ['function getOnRamp(uint64) view returns(address)',
  'function getOffRamps() view returns((uint64 sourceChainSelector,address offRamp)[])',
  `function getFee(uint64,${MESSAGE}) view returns(uint256)`, `function ccipSend(uint64,${MESSAGE}) payable returns(bytes32)`];
const OFFRAMP_ABI = ['function getExecutionState(bytes32) view returns(uint8)',
  'function getCCVsForMessage(bytes) view returns(address[],address[],uint8)',
  'function execute(bytes,address[],bytes[],uint32)',
  'event ExecutionStateChanged(uint64 indexed sourceChainSelector,uint64 indexed messageNumber,bytes32 indexed messageId,uint8 state,bytes returnData)'];
const SENT_ABI = ['event CCIPMessageSent(uint64 indexed destChainSelector,address indexed sender,bytes32 indexed messageId,address feeToken,uint256 tokenAmountBeforeTokenPoolFees,bytes encodedMessage,(address issuer,uint32 destGasLimit,uint32 destBytesOverhead,uint256 feeTokenAmount,bytes extraArgs)[] receipts,bytes[] verifierBlobs)'];
const RESOLVER_ABI = ['function getOutboundImplementation(uint64,bytes) view returns(address)',
  'function getInboundImplementation(bytes) view returns(address)'];
class SmokeError extends Error {}
function check(ok, message) { if (!ok) throw new SmokeError(message); }
const eq = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const serial = value => JSON.parse(JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v));
const sameSet = (a, b) => a.length === b.length && new Set(a.map(x => x.toLowerCase())).size === a.length &&
  a.every(x => b.some(y => eq(x, y)));

function deploymentBinding(bundle) {
  check(bundle.environment === 'public-testnet', 'A public-testnet deployment bundle is required');
  const chains = {};
  for (const [name, id] of Object.entries(CHAINS)) {
    const c = bundle.chains[name];
    check(c?.chainId === id, 'Incorrect deployment chain: ' + name);
    chains[name] = {};
    for (const key of ['chainId', 'chainSelector', 'token', 'tokenPool', 'router', 'tokenAdminRegistry',
      'hooks', 'localResolver', 'dummyVerifier', 'chainlinkResolver', 'chainlinkImplementations', 'lockboxes']) {
      if (c[key] !== undefined) chains[name][key] = c[key];
    }
    for (const key of ['token', 'tokenPool', 'router', 'tokenAdminRegistry', 'hooks', 'localResolver', 'dummyVerifier', 'chainlinkResolver']) {
      check(E.isAddress(c[key]) && !eq(c[key], E.ZeroAddress), 'Missing deployment address: ' + name + '/' + key);
    }
  }
  return {runId: bundle.runId, chains};
}

// Decode the source-emitted wire format independently of the Indexer response.
function decodeMessage(encoded) {
  const b = Buffer.from(E.getBytes(encoded)); let p = 0;
  const take = n => { check(p + n <= b.length, 'Truncated CCIP message'); const v = b.subarray(p, p + n); p += n; return v; };
  const num = n => BigInt('0x' + take(n).toString('hex'));
  const bytes = n => '0x' + take(n).toString('hex');
  const variable = n => bytes(Number(num(n)));
  check(num(1) === 1n, 'Unsupported CCIP message version');
  const result = {source: num(8).toString(), destination: num(8).toString(), number: num(8).toString()};
  result.executionGasLimit = num(4).toString(); result.callbackGasLimit = num(4).toString();
  result.finality = bytes(4); bytes(32);
  for (const key of ['onRamp', 'offRamp', 'sender', 'receiver']) result[key] = variable(1);
  result.destBlob = variable(2); const token = variable(2); result.data = variable(2);
  check(p === b.length, 'Trailing CCIP message bytes');
  const t = Buffer.from(E.getBytes(token)); let i = 0;
  const tt = n => { check(i + n <= t.length, 'Truncated CCIP token transfer'); const x = t.subarray(i, i + n); i += n; return x; };
  const tn = n => BigInt('0x' + tt(n).toString('hex'));
  const tv = n => '0x' + tt(Number(tn(n))).toString('hex');
  check(tn(1) === 1n, 'Unsupported CCIP token version'); result.amount = tn(32).toString();
  for (const key of ['sourcePool', 'sourceToken', 'destinationToken', 'tokenReceiver']) result[key] = tv(1);
  result.tokenExtraData = tv(2); check(i === t.length, 'Trailing token bytes');
  return result;
}

function validateMessage(encoded, id, expected) {
  check(eq(E.keccak256(encoded), id), 'Message ID does not match encoded message');
  const m = decodeMessage(encoded);
  for (const key of ['source', 'destination', 'amount']) check(m[key] === String(expected[key]), 'Unexpected message ' + key);
  for (const key of ['onRamp', 'offRamp', 'sender', 'receiver', 'sourcePool', 'sourceToken', 'destinationToken', 'tokenReceiver']) {
    check(eq(E.getAddress('0x' + m[key].slice(-40)), expected[key]), 'Unexpected message ' + key);
  }
  check(m.data === '0x' && m.finality === '0x00000000', 'Expected token-only, fully finalized message');
  return m;
}

function assembleProofs(input, leg, destination) {
  check(input && eq(input.encodedMessage, leg.encodedMessage), 'Indexer returned different encoded message');
  check(Array.isArray(input.verifierAddresses) && Array.isArray(input.ccvData) &&
    input.verifierAddresses.length === input.ccvData.length, 'Malformed execution inputs');
  const proofs = new Map();
  input.verifierAddresses.forEach((address, index) => {
    check(E.isAddress(address) && !proofs.has(address.toLowerCase()), 'Invalid/duplicate API verifier');
    const data = input.ccvData[index];
    if (typeof data === 'string' && E.isHexString(data) && E.dataLength(data) >= 4) proofs.set(address.toLowerCase(), data);
  });
  const chainlink = proofs.get(destination.chainlinkResolver.toLowerCase());
  if (!chainlink) return null;
  // This is the deployed Dummy's documented envelope; it is not a Chainlink signature.
  const dummy = E.concat(['0xdecafbad', leg.messageId]);
  return {ccvs: [destination.chainlinkResolver, destination.localResolver], proofs: [chainlink, dummy]};
}

class BridgeSmoke {
  constructor(file, bundleFile = DEFAULT_BUNDLE) {
    this.file = path.resolve(file); this.bundle = C.read(bundleFile); this.binding = deploymentBinding(this.bundle);
    this.env = C.environment(); this.providers = {}; this.wallet = C.wallets(C.actors(), this.env).deployer;
    this.j = fs.existsSync(this.file) ? C.read(this.file) : {schemaVersion: 1, createdAt: new Date().toISOString(),
      binding: this.binding, actor: this.wallet.address, amountPerLane: AMOUNT.toString(), transactions: {}, legs: {}, codeVersions: []};
    check(this.j.schemaVersion === 1 && JSON.stringify(this.j.binding) === JSON.stringify(this.binding), 'Journal deployment binding changed');
    check(eq(this.j.actor, this.wallet.address) && this.j.amountPerLane === AMOUNT.toString(), 'Journal actor/amount changed');
    const version = hash(fs.readFileSync(__filename));
    if (!this.j.codeVersions.some(x => x.sha256 === version)) this.j.codeVersions.push({sha256: version, seenAt: new Date().toISOString()});
    const savedSource = path.join(path.dirname(this.file), 'source-' + version + '.cjs');
    if (!fs.existsSync(savedSource)) fs.copyFileSync(__filename, savedSource);
  }
  save() { this.j.updatedAt = new Date().toISOString(); C.write(this.file, this.j); }
  contract(chain, address, abi) { return new E.Contract(address, abi, this.providers[chain]); }
  token(chain) { return this.contract(chain, this.binding.chains[chain].token, TOKEN_ABI); }
  router(chain) { return this.contract(chain, this.binding.chains[chain].router, ROUTER_ABI); }
  lockbox(spoke) {
    const matches = this.binding.chains.sepolia.lockboxes.filter(x => x.remote_chain_name === spoke);
    check(matches.length === 1, 'Expected exactly one lockbox for ' + spoke); return matches[0].lock_box;
  }
  async connect() {
    for (const [name, chainId] of Object.entries(CHAINS)) {
      const endpoint = this.env['RPC_' + name.toUpperCase() + '_REMOTE'];
      check(endpoint && new URL(endpoint).protocol === 'https:', 'Public HTTPS remote RPC required: ' + name);
      const p = new E.JsonRpcProvider(endpoint, undefined, {batchMaxCount: 1, cacheTimeout: -1});
      p.pollingInterval = 3000; this.providers[name] = p;
      check(Number((await p.getNetwork()).chainId) === chainId, 'Wrong RPC chain: ' + name);
      check(!/anvil|hardhat|ganache/i.test(await p.send('web3_clientVersion', [])), 'Fork RPC is not allowed');
      const deployment = this.bundle.chains[name].tokenDeployment;
      const block = await p.getBlock(deployment.block);
      check(eq(block?.hash, deployment.blockHash), 'Public deployment history mismatch: ' + name);
    }
  }
  async close() { for (const p of Object.values(this.providers)) p.destroy(); }
  async snapshot() {
    const state = {};
    for (const name of Object.keys(CHAINS)) {
      const block = await this.providers[name].getBlock('latest'), t = this.token(name), at = {blockTag: block.number};
      state[name] = {block: block.number, blockHash: block.hash, balance: String(await t.balanceOf(this.wallet.address, at)),
        totalSupply: String(await t.totalSupply(at)), nativeBalance: String(await this.providers[name].getBalance(this.wallet.address, block.number))};
      if (name === 'sepolia') {
        state[name].lockboxes = {};
        for (const spoke of SPOKES) state[name].lockboxes[spoke] = String(await t.balanceOf(this.lockbox(spoke), at));
      }
    }
    return state;
  }
  async preflight() {
    const readback = {};
    for (const name of Object.keys(CHAINS)) {
      const c = this.binding.chains[name], p = this.providers[name], remotes = name === 'sepolia' ? SPOKES : ['sepolia'];
      for (const key of ['token','tokenPool','router','tokenAdminRegistry','hooks','localResolver','dummyVerifier','chainlinkResolver'])
        check(await p.getCode(c[key]) !== '0x', 'Missing code: ' + name + '/' + key);
      check(await this.token(name).decimals() === 18n, 'Expected 18 token decimals');
      const registry = this.contract(name, c.tokenAdminRegistry, ['function getPool(address) view returns(address)']);
      check(eq(await registry.getPool(c.token), c.tokenPool), 'Registry pool mismatch: ' + name);
      const offramps = await this.router(name).getOffRamps(); readback[name] = {};
      for (const remote of remotes) {
        const selector = this.binding.chains[remote].chainSelector;
        const onRamp = await this.router(name).getOnRamp(selector);
        check(await this.contract(name, onRamp, ['function typeAndVersion() view returns(string)']).typeAndVersion() === 'OnRamp 2.0.0', 'Expected OnRamp 2.0.0');
        const candidates = [];
        for (const entry of offramps) if (entry.sourceChainSelector.toString() === selector &&
          await this.contract(name, entry.offRamp, ['function typeAndVersion() view returns(string)']).typeAndVersion() === 'OffRamp 2.0.0') candidates.push(entry.offRamp);
        check(candidates.length === 1, 'Expected exactly one OffRamp 2.0.0: ' + name + '/' + remote);
        const hooks = this.contract(name, c.hooks, ['function getCCVConfig(uint64) view returns((address[],address[],address[],address[]))']);
        const cfg = await hooks.getCCVConfig(selector), expected = [c.localResolver, c.chainlinkResolver];
        check(sameSet(cfg[0], expected) && sameSet(cfg[2], expected) && !cfg[1].length && !cfg[3].length, 'CCV policy changed: ' + name + '/' + remote);
        const resolver = this.contract(name, c.localResolver, RESOLVER_ABI);
        check(eq(await resolver.getOutboundImplementation(selector, '0x'), c.dummyVerifier) &&
          eq(await resolver.getInboundImplementation('0xdecafbad'), c.dummyVerifier), 'Local resolver no longer uses recorded Dummy');
        check(await this.contract(name, c.dummyVerifier, ['function typeAndVersion() view returns(string)']).typeAndVersion() === 'DummyMessageIdVerifier 1.0.0', 'Unexpected local verifier');
        const chainlink = this.contract(name, c.chainlinkResolver, RESOLVER_ABI);
        const expectedOutbound = c.chainlinkImplementations.outbound.find(x => x[0] === selector)?.[1];
        check(expectedOutbound && eq(await chainlink.getOutboundImplementation(selector, '0x'), expectedOutbound), 'Chainlink outbound changed');
        for (const [tag, implementation] of c.chainlinkImplementations.inbound)
          check(eq(await chainlink.getInboundImplementation(tag), implementation), 'Chainlink inbound changed');
        const quote = await this.router(name).getFee(selector, this.message(name));
        this.checkFee(name, quote);
        readback[name][remote] = {onRamp, offRamp: candidates[0], quote: quote.toString()};
      }
    }
    this.j.preflight = {checkedAt: new Date().toISOString(), lanes: readback, balances: await this.snapshot()};
    this.save(); console.log('Preflight passed: public history, registry, four CCV policies, 2.0 ramps and fee quotes.');
  }
  checkFee(chain, fee) {
    check(fee <= E.parseEther(chain === 'mantle_sepolia' ? '5' : '0.02'), 'CCIP fee exceeds smoke cap: ' + chain);
  }
  message(chain) {
    return {receiver: ABI.encode(['address'], [this.wallet.address]), data: '0x',
      tokenAmounts: [{token: this.binding.chains[chain].token, amount: AMOUNT}], feeToken: E.ZeroAddress,
      extraArgs: E.concat(['0x181dcf10', ABI.encode(['uint256','bool'], [0, true])])};
  }
  async receipt(chain, entry) {
    const p = this.providers[chain]; let receipt = await p.getTransactionReceipt(entry.hash);
    if (!receipt) {
      const raw = await this.wallet.signTransaction(entry.request);
      check(eq(E.keccak256(raw), entry.hash), 'Saved transaction hash mismatch');
      const found = await p.getTransaction(entry.hash);
      if (!found) {
        check(await p.getTransactionCount(this.wallet.address, 'latest') <= entry.request.nonce, 'Saved nonce consumed by another transaction');
        await p.broadcastTransaction(raw);
      }
      receipt = await p.waitForTransaction(entry.hash, 1, 45000);
    }
    check(receipt, 'Transaction pending; resume the same journal: ' + entry.hash);
    entry.receipt = serial(receipt); entry.status = receipt.status === 1 ? 'confirmed' : 'reverted'; this.save();
    check(receipt.status === 1, 'Transaction reverted: ' + entry.hash); return receipt;
  }
  async send(key, chain, build) {
    let entry = this.j.transactions[key];
    if (!entry) {
      const p = this.providers[chain], wallet = this.wallet.connect(p), request = await build();
      const latest = await p.getTransactionCount(wallet.address, 'latest'), pending = await p.getTransactionCount(wallet.address, 'pending');
      check(latest === pending, 'Actor has another pending transaction on ' + chain);
      const estimate = await p.estimateGas({...request, from: wallet.address});
      // OffRamp can swallow inner out-of-gas and return a status-1 FAILURE receipt.
      // Consequently eth_estimateGas alone is not a reliable execution gas floor.
      const estimatedLimit = estimate * 5n / 2n + 100000n;
      const gasLimit = estimatedLimit > (request.gasLimit ?? 0n) ? estimatedLimit : request.gasLimit;
      check(gasLimit <= 5000000n, 'Unexpected smoke transaction gas estimate');
      const tx = await wallet.populateTransaction({...request, gasLimit, nonce: pending});
      const upperCost = gasLimit * (tx.maxFeePerGas ?? tx.gasPrice) + (tx.value ?? 0n);
      const budget = E.parseEther(chain === 'mantle_sepolia' ? '20' : '0.1');
      const spent = Object.values(this.j.transactions).filter(x => x.chain === chain).reduce((n, x) => n + BigInt(x.maximumCost), 0n);
      check(upperCost + spent <= budget, 'Smoke native budget exceeded on ' + chain);
      check(await p.getBalance(wallet.address) >= upperCost, 'Insufficient gas balance on ' + chain);
      const raw = await wallet.signTransaction(tx);
      entry = {chain, hash: E.keccak256(raw), request: serial(tx), maximumCost: upperCost.toString(), status: 'prepared'};
      this.j.transactions[key] = entry; this.save(); // durable BEFORE broadcast; raw signature is not persisted
      console.log(key + ': ' + entry.hash);
    }
    check(entry.chain === chain, 'Saved transaction chain mismatch');
    return this.receipt(chain, entry);
  }
  async approve(key, chain) {
    const c = this.binding.chains[chain], token = this.token(chain);
    if (this.j.transactions[key]) return this.receipt(chain, this.j.transactions[key]);
    const allowance = await token.allowance(this.wallet.address, c.router);
    check(allowance === 0n || allowance === AMOUNT, 'Unexpected existing Router allowance');
    if (allowance === 0n) await this.send(key, chain, () => token.approve.populateTransaction(c.router, AMOUNT));
  }
  async fundTokens() {
    if (this.j.funded) return;
    if (!this.j.beforeFunding) { this.j.beforeFunding = await this.snapshot(); this.save(); }
    const balance = await this.token('sepolia').balanceOf(this.wallet.address);
    if (this.j.transactions.stake || balance < 2n * AMOUNT) {
      await this.send('stake', 'sepolia', async () => {
        const missing = 2n * AMOUNT - balance;
        const value = await this.token('sepolia').getStETHByWstETH(missing) + 1000n;
        check(value > 0n && value <= E.parseEther('0.05'), 'Unexpected staking amount');
        return {to: this.binding.chains.sepolia.token, value, data: '0x'};
      });
    }
    check(await this.token('sepolia').balanceOf(this.wallet.address) >= 2n * AMOUNT, 'Staking did not produce enough wstETH');
    this.j.baseline = await this.snapshot(); this.j.funded = true; this.save();
  }
  expectedMessage(source, destination) {
    const s = this.binding.chains[source], d = this.binding.chains[destination];
    return {source: s.chainSelector, destination: d.chainSelector, amount: AMOUNT.toString(),
      onRamp: this.j.preflight.lanes[source][destination].onRamp, offRamp: this.j.preflight.lanes[destination][source].offRamp,
      sender: this.wallet.address, receiver: this.wallet.address, tokenReceiver: this.wallet.address,
      sourcePool: s.tokenPool, sourceToken: s.token, destinationToken: d.token};
  }
  async originate(key, source, destination) {
    if (this.j.legs[key]) return;
    const txKey = key + '-send';
    // A previously broadcast send already consumed its allowance: reconcile before approving again.
    if (!this.j.transactions[txKey]) await this.approve(key + '-approve', source);
    const r = await this.send(txKey, source, async () => {
      const message = this.message(source), selector = this.binding.chains[destination].chainSelector;
      const fee = await this.router(source).getFee(selector, message); this.checkFee(source, fee);
      return this.router(source).ccipSend.populateTransaction(selector, message, {value: fee});
    });
    const iface = new E.Interface(SENT_ABI), expected = this.expectedMessage(source, destination);
    const events = r.logs.filter(x => eq(x.address, expected.onRamp)).map(x => { try { return iface.parseLog(x); } catch { return null; } }).filter(Boolean);
    check(events.length === 1, 'Expected exactly one CCIPMessageSent'); const event = events[0];
    const decoded = validateMessage(event.args.encodedMessage, event.args.messageId, expected);
    this.j.legs[key] = {source, destination, sourceTransaction: r.hash, sourceBlock: r.blockNumber,
      messageId: event.args.messageId, encodedMessage: event.args.encodedMessage, decoded,
      // The baseline predates every send. A new preflight after an interruption
      // can be later than delivery and would hide the transfer we must reconcile.
      offRamp: expected.offRamp, destinationStartBlock: this.j.baseline[destination].block, status: 'sent'};
    this.save(); console.log(key + ' message: ' + event.args.messageId);
  }
  async deposits() {
    await this.fundTokens();
    for (const spoke of SPOKES) await this.originate('deposit-' + spoke, 'sepolia', spoke);
  }
  async apiInputs(id) {
    const response = await fetch(API + id + '/execution-inputs', {signal: AbortSignal.timeout(20000)});
    if ([404, 409, 422, 429, 503].includes(response.status)) return {pending: 'API HTTP ' + response.status};
    check(response.ok, 'CCIP API HTTP ' + response.status); return {input: await response.json()};
  }
  async delivery(key, leg) {
    // Reconcile source receipt on every advance, including already completed legs.
    const sourceReceipt = await this.providers[leg.source].getTransactionReceipt(leg.sourceTransaction);
    check(sourceReceipt?.status === 1 && eq(sourceReceipt.blockHash, this.j.transactions[key + '-send'].receipt.blockHash), 'Source receipt missing or reorganized');
    validateMessage(leg.encodedMessage, leg.messageId, this.expectedMessage(leg.source, leg.destination));
    const dest = this.binding.chains[leg.destination], off = this.contract(leg.destination, leg.offRamp, OFFRAMP_ABI);
    let state = Number(await off.getExecutionState(leg.messageId));
    if (state !== 2 && this.j.transactions[key + '-execute']) {
      await this.receipt(leg.destination, this.j.transactions[key + '-execute']); state = Number(await off.getExecutionState(leg.messageId));
      check(state === 2, 'OffRamp execution did not succeed: ' + key);
    }
    if (state !== 2) {
      const [required, optional, threshold] = await off.getCCVsForMessage(leg.encodedMessage);
      check(sameSet(required, [dest.chainlinkResolver, dest.localResolver]) && !optional.length && threshold === 0n, 'Unexpected destination CCV quorum');
      const api = await this.apiInputs(leg.messageId);
      if (api.pending) { leg.pending = api.pending; this.save(); console.log(key + ': ' + leg.pending); return; }
      const assembled = assembleProofs(api.input, leg, dest);
      if (!assembled) { leg.pending = 'Awaiting genuine Chainlink attestation'; this.save(); console.log(key + ': ' + leg.pending); return; }
      const resolved = await this.contract(leg.destination, dest.chainlinkResolver, RESOLVER_ABI).getInboundImplementation(assembled.proofs[0]);
      check(dest.chainlinkImplementations.inbound.some(x => eq(x[1], resolved)), 'Attestation resolves to an unrecorded Chainlink implementation');
      leg.executionInputs = assembled; leg.attestationFetchedAt = new Date().toISOString(); this.save();
      const messageFloor = BigInt(leg.decoded.executionGasLimit) * 2n + 250000n;
      const gasLimit = messageFloor > 2000000n ? messageFloor : 2000000n;
      await this.send(key + '-execute', leg.destination, () => off.execute.populateTransaction(
        leg.encodedMessage, assembled.ccvs, assembled.proofs, 0, {gasLimit}));
      state = Number(await off.getExecutionState(leg.messageId));
      check(state === 2, 'Receipt succeeded but OffRamp did not record SUCCESS: ' + key);
    }
    const token = this.token(leg.destination), from = leg.destination === 'sepolia' ? this.lockbox(leg.source) : E.ZeroAddress;
    const end = await this.providers[leg.destination].getBlockNumber(); const transfers = [];
    // Small ranges work on public RPCs with bounded eth_getLogs support.
    for (let start = leg.destinationStartBlock; start <= end; start += 1000)
      transfers.push(...await token.queryFilter(token.filters.Transfer(from, this.wallet.address), start, Math.min(end, start + 999)));
    const ownTx = this.j.transactions[key + '-execute']?.hash;
    const matching = transfers.filter(x => x.args.value === AMOUNT && (!ownTx || eq(x.transactionHash, ownTx)));
    check(matching.length === 1, 'Destination token transfer is missing or ambiguous: ' + key);
    const receipt = await this.providers[leg.destination].getTransactionReceipt(matching[0].transactionHash);
    check(receipt?.status === 1 && eq(receipt.blockHash, matching[0].blockHash), 'Destination receipt missing or reorganized');
    const executionEvents = receipt.logs.filter(x => eq(x.address, leg.offRamp)).map(x => {
      try { return off.interface.parseLog(x); } catch { return null; }
    }).filter(x => x && eq(x.args.messageId, leg.messageId) && x.args.state === 2n);
    check(executionEvents.length === 1, 'Destination token transfer lacks this message SUCCESS event');
    leg.status = 'delivered'; leg.destinationTransaction = matching[0].transactionHash;
    leg.destinationBlock = matching[0].blockNumber; leg.destinationReceipt = serial(receipt);
    leg.executionState = state; delete leg.pending; this.save();
    console.log(key + ': SUCCESS; destination transaction ' + leg.destinationTransaction);
  }
  async advance() {
    // A source transaction can mine before originate() persists its message leg.
    // Recover these receipts before comparing balances or initiating another send.
    await this.reconcileSends();
    for (const [key, leg] of Object.entries(this.j.legs)) await this.delivery(key, leg);
    await this.checkBalances();
  }
  async reconcileSends() {
    for (const spoke of SPOKES) {
      for (const [key, source, destination] of [
        ['deposit-' + spoke, 'sepolia', spoke], ['withdraw-' + spoke, spoke, 'sepolia']
      ]) {
        if (this.j.transactions[key + '-send'] && !this.j.legs[key])
          await this.originate(key, source, destination);
      }
    }
  }
  async run() {
    await this.deposits();
    const deadline = Date.now() + 60 * 60 * 1000;
    while (Date.now() < deadline) {
      await this.advance();
      if (this.j.status === 'roundtrips-passed') return;
      if (SPOKES.every(s => this.j.legs['deposit-' + s]?.status === 'delivered') &&
          SPOKES.some(s => !this.j.legs['withdraw-' + s])) {
        await this.preflight(); // Recheck provider configuration before starting the reverse direction.
        await this.withdrawals();
      }
      console.log('Waiting 30 seconds for public finality/attestation; journal is resumable.');
      await new Promise(resolve => setTimeout(resolve, 30000));
    }
    throw new SmokeError('One-hour observation window ended; messages remain pending. Resume with run and the same journal.');
  }
  async withdrawals() {
    check(SPOKES.every(s => this.j.legs['deposit-' + s]?.status === 'delivered'), 'Both deposits must be delivered before withdrawals');
    await this.reconcileSends();
    await this.checkBalances();
    for (const spoke of SPOKES) await this.originate('withdraw-' + spoke, spoke, 'sepolia');
  }
  async checkBalances() {
    if (!this.j.baseline) return;
    const now = await this.snapshot(), base = this.j.baseline; let l1Delta = 0n;
    for (const spoke of SPOKES) {
      const deposit = this.j.legs['deposit-' + spoke], withdrawal = this.j.legs['withdraw-' + spoke];
      const locked = (deposit ? AMOUNT : 0n) - (withdrawal?.status === 'delivered' ? AMOUNT : 0n);
      const minted = (deposit?.status === 'delivered' ? AMOUNT : 0n) - (withdrawal ? AMOUNT : 0n);
      check(BigInt(now.sepolia.lockboxes[spoke]) - BigInt(base.sepolia.lockboxes[spoke]) === locked, 'Lockbox delta mismatch: ' + spoke);
      check(BigInt(now[spoke].balance) - BigInt(base[spoke].balance) === minted, 'L2 balance delta mismatch: ' + spoke);
      check(BigInt(now[spoke].totalSupply) - BigInt(base[spoke].totalSupply) === minted, 'L2 supply delta mismatch: ' + spoke);
      l1Delta -= locked;
    }
    check(BigInt(now.sepolia.balance) - BigInt(base.sepolia.balance) === l1Delta, 'L1 balance delta mismatch');
    check(now.sepolia.totalSupply === base.sepolia.totalSupply, 'L1 token supply changed during bridge smoke');
    this.j.latestBalances = now;
    this.j.status = SPOKES.every(s => this.j.legs['withdraw-' + s]?.status === 'delivered') ? 'roundtrips-passed' : 'in-progress';
    this.save(); console.log('Balance, supply and both lockbox deltas match; ' + this.j.status);
  }
}

async function main(argv) {
  const [command, file, bundleFile] = argv;
  check(['preflight','deposits','advance','withdrawals','status','run'].includes(command) && file && argv.length <= 3,
    'Usage: node smoke/bridge.cjs <preflight|deposits|advance|withdrawals|status|run> <journal.json> [deployment.json]');
  const journal = path.resolve(file); fs.mkdirSync(path.dirname(journal), {recursive: true});
  const lock = journal + '.lock';
  let fd;
  try { fd = fs.openSync(lock, 'wx', 0o600); } catch { throw new SmokeError('Journal is locked; check the recorded process before removing ' + lock); }
  fs.writeFileSync(fd, String(process.pid)); let smoke;
  try {
    smoke = new BridgeSmoke(journal, bundleFile); await smoke.connect();
    await smoke.preflight();
    if (command === 'deposits') await smoke.deposits();
    if (command === 'withdrawals') await smoke.withdrawals();
    if (command === 'advance') await smoke.advance();
    if (command === 'run') await smoke.run();
    if (command === 'status') console.log(JSON.stringify({status: smoke.j.status, legs: Object.fromEntries(Object.entries(smoke.j.legs).map(([k,v]) => [k, {status:v.status, messageId:v.messageId, pending:v.pending}]))}, null, 2));
  } finally { if (smoke) await smoke.close(); fs.closeSync(fd); fs.unlinkSync(lock); }
}
if (require.main === module) main(process.argv.slice(2)).catch(error => {
  // Provider errors can contain credential-bearing URLs. Print only own errors or safe codes/data.
  const code = /^[A-Z_]+$/.test(error.code || '') ? error.code : 'EXTERNAL_ERROR';
  console.error(error instanceof SmokeError ? error.message : code);
  if (!(error instanceof SmokeError)) console.error(JSON.stringify({
    action: ['call','estimateGas','sendTransaction','getBlock','getBalance'].includes(error.action) ? error.action : undefined,
    to: E.isAddress(error.transaction?.to) ? error.transaction.to : undefined,
    selector: E.isHexString(error.transaction?.data) ? error.transaction.data.slice(0, 10) : undefined,
    rpcCode: typeof error.info?.error?.code === 'number' ? error.info.error.code : undefined,
    missingRevertData: error.shortMessage === 'missing revert data'
  }));
  if (typeof error.data === 'string' && E.isHexString(error.data)) console.error('Revert data: ' + error.data);
  process.exitCode = 1;
});
module.exports = {BridgeSmoke, deploymentBinding, decodeMessage, validateMessage, assembleProofs, sameSet, AMOUNT, ABI, E, main};

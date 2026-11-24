'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {BridgeSmoke, decodeMessage, validateMessage, assembleProofs, sameSet, AMOUNT, E} = require('./bridge.cjs');
const addresses = Array.from({length: 8}, (_, i) => E.getAddress(E.toBeHex(i + 10, 20)));
const [onRamp, offRamp, sender, receiver, sourcePool, sourceToken, destinationToken, chainlink] = addresses;
const sized = (value, size) => E.concat([E.toBeHex(E.dataLength(value), size), value]);
function message(overrides = {}) {
  const m = {source: '16015286601757825753', destination: '10344971235874465080', amount: AMOUNT,
    onRamp, offRamp, sender, receiver, sourcePool, sourceToken, destinationToken, tokenReceiver: receiver, ...overrides};
  const token = E.concat(['0x01', E.toBeHex(m.amount, 32),
    sized(E.zeroPadValue(m.sourcePool, 32), 1), sized(E.zeroPadValue(m.sourceToken, 32), 1),
    sized(m.destinationToken, 1), sized(m.tokenReceiver, 1), sized('0x12', 2)]);
  return {expected: m, encoded: E.concat(['0x01', E.toBeHex(m.source, 8), E.toBeHex(m.destination, 8), E.toBeHex(7, 8),
    E.toBeHex(500000, 4), E.toBeHex(0, 4), '0x00000000', E.ZeroHash,
    sized(E.zeroPadValue(m.onRamp, 32), 1), sized(m.offRamp, 1), sized(E.zeroPadValue(m.sender, 32), 1),
    sized(m.receiver, 1), sized('0x', 2), sized(token, 2), sized('0x', 2)])};
}
test('source message binds the token, amount, sender, recipient, chains and ramps', () => {
  const {encoded, expected} = message(), id = E.keccak256(encoded);
  assert.equal(validateMessage(encoded, id, expected).amount, AMOUNT.toString());
  for (const key of ['source', 'destination', 'amount'])
    assert.throws(() => validateMessage(encoded, id, {...expected, [key]: '1'}), /Unexpected message/);
  for (const key of ['onRamp', 'offRamp', 'sender', 'receiver', 'sourcePool', 'sourceToken', 'destinationToken', 'tokenReceiver'])
    assert.throws(() => validateMessage(encoded, id, {...expected, [key]: E.ZeroAddress}), /Unexpected message/);
  assert.throws(() => validateMessage(encoded, E.ZeroHash, expected), /Message ID/);
  assert.throws(() => decodeMessage(encoded.slice(0, -2)), /Truncated/);
  assert.throws(() => decodeMessage(encoded + '00'), /Trailing/);
});
test('Dummy proof cannot substitute for a missing Chainlink attestation', () => {
  const {encoded} = message(), leg = {encodedMessage: encoded, messageId: E.keccak256(encoded)};
  const destination = {chainlinkResolver: chainlink, localResolver: receiver};
  const base = {encodedMessage: encoded, verifierAddresses: [receiver], ccvData: ['0xdecafbad' + leg.messageId.slice(2)]};
  assert.equal(assembleProofs(base, leg, destination), null);
  const withChainlink = {...base, verifierAddresses: [receiver, chainlink], ccvData: [base.ccvData[0], '0xe9a05a20abcdef']};
  const result = assembleProofs(withChainlink, leg, destination);
  assert.deepEqual(result.ccvs, [chainlink, receiver]);
  assert.deepEqual(result.proofs, [withChainlink.ccvData[1], base.ccvData[0]]);
  assert.throws(() => assembleProofs({...withChainlink, encodedMessage: '0x'}, leg, destination), /different encoded/);
  assert.throws(() => assembleProofs({...withChainlink, verifierAddresses: [chainlink, chainlink]}, leg, destination), /duplicate/);
});
test('CCV set comparison rejects duplicates and weakened policies', () => {
  assert(sameSet([sender, receiver], [receiver, sender]));
  assert(!sameSet([sender, sender], [sender, receiver]));
  assert(!sameSet([sender], [sender, receiver]));
});
test('a resumed send reconciles its saved transaction without rebuilding or approving', async () => {
  const entry = {chain: 'sepolia', hash: E.ZeroHash};
  const fake = {j: {transactions: {deposit: entry}}, receipt: async (chain, value) => { assert.equal(chain, 'sepolia'); assert.equal(value, entry); return 'receipt'; }};
  assert.equal(await BridgeSmoke.prototype.send.call(fake, 'deposit', 'sepolia', () => assert.fail('must not rebuild')), 'receipt');
});
test('run reconciles a mined withdrawal missing its leg before checking burned balances', async () => {
  const key = 'withdraw-base_sepolia';
  const calls = [];
  const fake = {
    j: {transactions: {[key + '-send']: {chain:'base_sepolia'}}, legs: {}},
    deposits: async () => {},
    reconcileSends: BridgeSmoke.prototype.reconcileSends,
    advance: BridgeSmoke.prototype.advance,
    originate: async (recovered, source, destination) => {
      assert.equal(recovered, key); assert.equal(source, 'base_sepolia'); assert.equal(destination, 'sepolia');
      calls.push('recover'); fake.j.legs[key] = {status:'sent'};
    },
    delivery: async () => { calls.push('delivery'); },
    checkBalances: async () => {
      assert(fake.j.legs[key], 'burn already happened; this leg must exist before balance checks');
      calls.push('balances'); fake.j.status = 'roundtrips-passed';
    }
  };
  await BridgeSmoke.prototype.run.call(fake);
  assert.deepEqual(calls, ['recover', 'delivery', 'balances']);
});
test('recovering a send uses the durable baseline even after a newer preflight', async () => {
  const {encoded, expected} = message(), id = E.keccak256(encoded);
  const iface = new E.Interface(['event CCIPMessageSent(uint64 indexed destChainSelector,address indexed sender,bytes32 indexed messageId,address feeToken,uint256 tokenAmountBeforeTokenPoolFees,bytes encodedMessage,(address issuer,uint32 destGasLimit,uint32 destBytesOverhead,uint256 feeTokenAmount,bytes extraArgs)[] receipts,bytes[] verifierBlobs)']);
  const event = iface.encodeEventLog(iface.getEvent('CCIPMessageSent'),
    [expected.destination, sender, id, E.ZeroAddress, AMOUNT, encoded, [], []]);
  const saved = {chain:'sepolia', hash:E.ZeroHash};
  const fake = {
    j:{transactions:{'deposit-base_sepolia-send':saved},legs:{},
      baseline:{base_sepolia:{block:100}},preflight:{balances:{base_sepolia:{block:300}}}},
    approve:async()=>assert.fail('must not approve a saved send'),
    send:BridgeSmoke.prototype.send,
    receipt:async(chain,entry)=>{
      assert.equal(entry,saved); assert.equal(chain,'sepolia');
      return {hash:E.ZeroHash,blockNumber:200,logs:[{address:onRamp,...event}]};
    },
    expectedMessage:()=>expected,
    save:()=>{}
  };
  await BridgeSmoke.prototype.originate.call(fake,'deposit-base_sepolia','sepolia','base_sepolia');
  assert.equal(fake.j.legs['deposit-base_sepolia'].destinationStartBlock,100);
  assert.equal(fake.j.legs['deposit-base_sepolia'].messageId,id);
});
test('both successful deposits are required before any withdrawal transaction', async () => {
  await assert.rejects(BridgeSmoke.prototype.withdrawals.call({j: {legs: {'deposit-base_sepolia': {status: 'delivered'}}}}), /Both deposits/);
});
test('receipt status 1 is insufficient when OffRamp records FAILURE', async () => {
  const {encoded, expected} = message(); const leg = {source: 'sepolia', destination: 'base_sepolia', sourceTransaction: E.ZeroHash,
    encodedMessage: encoded, messageId: E.keccak256(encoded), offRamp};
  const fake = {j: {transactions: {'leg-send': {receipt: {blockHash: E.ZeroHash}}, 'leg-execute': {}}},
    binding: {chains: {base_sepolia: {}}}, providers: {sepolia: {getTransactionReceipt: async () => ({status: 1, blockHash: E.ZeroHash})}},
    expectedMessage: () => expected, contract: () => ({getExecutionState: async () => 3n}), receipt: async () => ({status: 1})};
  await assert.rejects(BridgeSmoke.prototype.delivery.call(fake, 'leg', leg), /OffRamp execution did not succeed/);
});
test('conservation checks detect wrong supply even when the user balance looks correct', async () => {
  const baseline = {sepolia: {balance:'10', totalSupply:'10', lockboxes:{base_sepolia:'0',mantle_sepolia:'0'}},
    base_sepolia:{balance:'0',totalSupply:'0'},mantle_sepolia:{balance:'0',totalSupply:'0'}};
  const current = structuredClone(baseline); current.base_sepolia.totalSupply = '1';
  await assert.rejects(BridgeSmoke.prototype.checkBalances.call({j:{baseline,legs:{}}, snapshot:async()=>current}), /supply delta/);
});
test('a matching token transfer without the message SUCCESS event cannot pass', async () => {
  const {encoded, expected} = message();
  const leg = {source:'sepolia',destination:'base_sepolia',sourceTransaction:E.ZeroHash,
    encodedMessage:encoded,messageId:E.keccak256(encoded),offRamp,destinationStartBlock:10};
  const receipt = {status:1,blockHash:E.ZeroHash,logs:[]};
  const transfer = {args:{value:AMOUNT},transactionHash:E.ZeroHash,blockHash:E.ZeroHash};
  const fake = {j:{transactions:{'leg-send':{receipt}}}, binding:{chains:{base_sepolia:{}}},
    wallet:{address:receiver},expectedMessage:()=>expected,
    providers:{sepolia:{getTransactionReceipt:async()=>receipt},base_sepolia:{getBlockNumber:async()=>10,getTransactionReceipt:async()=>receipt}},
    contract:()=>({getExecutionState:async()=>2n}),
    token:()=>({filters:{Transfer:()=>null},queryFilter:async()=>[transfer]})};
  await assert.rejects(BridgeSmoke.prototype.delivery.call(fake,'leg',leg), /lacks this message SUCCESS event/);
});

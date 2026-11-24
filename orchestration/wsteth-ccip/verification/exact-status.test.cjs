'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const {classify, requireExact} = require('./exact-status.cjs');
const {portable} = require('./explorer.cjs');
const base = {SourceCode:'contract C {}', SimilarMatch:'', ConstructorArguments:'abcd'};

test('published source and an Already Verified response cannot hide Similar Match', () => {
  const source = {...base, SimilarMatch:'0x1111111111111111111111111111111111111111'};
  assert.equal(classify(source, 'abcd').sourceAvailable, true);
  assert.equal(classify(source, 'abcd').exactVerified, false);
  assert.throws(() => requireExact(source, 'abcd'), /similar-match/);
});
test('cross-chain similar-match markers are also rejected', () => {
  assert.equal(classify({...base, SimilarMatch:'M_1111111111111111111111111111111111111111'}, 'abcd').exactVerified, false);
});
test('missing or incorrect constructor arguments fail even without a similar marker', () => {
  assert.throws(() => requireExact({...base, ConstructorArguments:''}, 'abcd'), /constructor-mismatch/);
  assert.throws(() => requireExact(base, 'abce'), /constructor-mismatch/);
});
test('constructorless contracts pass only when empty arguments were explicitly expected', () => {
  assert.equal(requireExact({...base, ConstructorArguments:''}, '').exactVerified, true);
  assert.equal(classify({...base, ConstructorArguments:''}).exactVerified, false);
});
test('comparison is byte-exact but ignores hex case and optional 0x prefix', () => {
  assert.equal(requireExact(base, '0xABCD').exactVerified, true);
  assert.throws(() => requireExact(base, 'abc'), /Invalid constructor/);
  assert.equal(classify({...base, SourceCode:''}, 'abcd').exactVerified, false);
});
test('publication rejects absolute paths and unspecified constructor payloads', () => {
  const job={chainId:5003,address:'0x1111111111111111111111111111111111111111',compilerVersion:'v0.8.26+commit.8a97fa7a',
    contractName:'contracts/C.sol:C',constructorArguments:'',input:{sources:{'contracts/C.sol':{content:'contract C {}'}},settings:{}}};
  assert.doesNotThrow(()=>portable(job));
  assert.throws(()=>portable({...job,constructorArguments:undefined}),/Explicit ABI-encoded/);
  assert.throws(()=>portable({...job,input:{sources:{'/tmp/C.sol':{content:'contract C {}'}}}}),/absolute paths/);
  assert.throws(()=>portable({...job,input:{...job.input,settings:{remappings:['lib/=/tmp/lib/']}}}),/absolute paths/);
});

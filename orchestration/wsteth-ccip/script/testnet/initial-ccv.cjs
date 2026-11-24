'use strict';
// Owned post-configuration step: use the deployer's temporary timelock admin before handover.
const path=require('node:path');
const assert=require('node:assert/strict');
const C=require('./context.cjs'),G=require('./governance.cjs');
const {load}=require('../ccv-policy.cjs');
const CONFIGS='getAllCCVConfigs() view returns((uint64,address[],address[],address[],address[])[])';
const canonical=rows=>JSON.stringify(rows.map(row=>Array.from(row,v=>Array.isArray(v)?Array.from(v,x=>String(x).toLowerCase()):String(v).toLowerCase()))
  .sort((a,b)=>a[0].localeCompare(b[0])));
async function applyInitialCcv(rt,chain,spec) {
  const cfg=rt.records[chain];assert(cfg,'Unknown CCV chain');
  const d=cfg.deployed;
  assert(G.equal(await rt.read(chain,d.advanced_pool_hooks,'owner() view returns(address)'),d.timelock),'Hooks ownership handover incomplete');
  const local=cfg.ccv.verifier_resolver;
  assert.equal(canonical(await rt.read(chain,local,'getAllInboundImplementations() view returns((bytes4,address)[])')),canonical(spec.inbound),'Local inbound policy differs from upstream bootstrap');
  assert.equal(canonical(await rt.read(chain,local,'getAllOutboundImplementations() view returns((uint64,address)[])')),canonical(spec.outbound),'Local outbound policy differs from upstream bootstrap');
  // Provider expectations are authored in the target; never infer desired mappings from these reads.
  for(const provider of spec.external) {
    for(const address of new Set([provider.address,...provider.outbound.map(x=>x[1]),...provider.inbound.map(x=>x[1])]))
      assert.notEqual(await rt.providers[chain].getCode(address),'0x','External CCV has no code');
    for(const [selector,impl] of provider.outbound)
      assert(G.equal(await rt.read(chain,provider.address,'getOutboundImplementation(uint64,bytes) view returns(address)',[selector,'0x']),impl),'External outbound CCV changed; review target expectations');
    for(const [tag,impl] of provider.inbound)
      assert(G.equal(await rt.read(chain,provider.address,'getInboundImplementation(bytes) view returns(address)',[tag]),impl),'External inbound CCV changed; review target expectations');
  }
  const current=await rt.read(chain,d.advanced_pool_hooks,CONFIGS);
  assert(current.every(row=>spec.lanes.some(l=>l[0]===String(row[0]))),'Unexpected existing CCV lane');
  let transaction=null;
  if(canonical(current)!==canonical(spec.lanes)) {
    assert(await rt.read(chain,d.timelock,'hasRole(bytes32,address) view returns(bool)',[C.ethers.id('ADMIN_ROLE'),rt.wallets.deployer.address]),
      'Initial CCV configuration requires temporary deployer admin; use DAO governance after handover');
    const update=C.call(d.advanced_pool_hooks,'applyCCVConfigUpdates((uint64,address[],address[],address[],address[])[])',[spec.lanes]);
    const receipt=await rt.send(chain,'deployer',C.call(d.timelock,G.TL[2].slice(9),[[[update.to,0,update.data]]]));
    transaction=receipt.hash;
  }
  assert.equal(canonical(await rt.read(chain,d.advanced_pool_hooks,CONFIGS)),canonical(spec.lanes),'Initial CCV policy readback mismatch');
  C.write(path.join(rt.run,'state/initial-ccv.'+chain+'.json'),{chain,status:'passed',transaction,required:spec.lanes,providerExpectations:spec.external});
}
async function configureInitialCcv(rt,chain) {
  const {resolved}=load(path.join(rt.run,'config/chains'),path.join(rt.run,'config/ccv-policy.json'),[chain]);
  await applyInitialCcv(rt,chain,resolved[chain]);
  console.log('Initial CCV policy configured and verified: '+chain);
}
module.exports={applyInitialCcv,configureInitialCcv};

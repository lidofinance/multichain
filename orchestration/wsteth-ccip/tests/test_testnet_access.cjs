'use strict';
const test=require('node:test'), assert=require('node:assert/strict');
const fs=require('node:fs'), os=require('node:os'), path=require('node:path');
const C=require('../script/testnet/context.cjs'), P=require('../script/testnet/prepare.cjs'), G=require('../script/testnet/governance.cjs');
const R=require('../script/redact-output.cjs');
const {applyInitialCcv}=require('../script/testnet/initial-ccv.cjs');
const profile=path.join(C.ROOT,'targets/wsteth-ccip-sepolia-mantle-dev/config/access-profile.json');
const actors=Object.fromEntries(C.actors().actors.map(a=>[a.id,{address:a.address}]));
test('initial CCV policy adds Chainlink through temporary timelock admin and is idempotent',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'initial-ccv-'));
  const local=actors.reserve_0.address,external=actors.ccip_proposer.address,impl=actors.dao_voter.address;
  const cfg={ccv:{verifier_resolver:local},deployed:{advanced_pool_hooks:actors.dg_reseal.address,timelock:actors.deployer.address}};
  const spec={inbound:[['0xdecafbad',impl]],outbound:[['123',impl]],
    lanes:[['123',[local,external],[],[local,external],[]]],
    external:[{address:external,inbound:[['0x12345678',impl]],outbound:[['123',impl]]}]};
  let current=[['123',[local],[],[local],[]]],sends=0,badProvider=false,admin=true;
  const rt={run:dir,records:{sepolia:cfg},wallets:{deployer:actors.deployer},providers:{sepolia:{getCode:async()=> '0x6000'}},
    read:async(chain,address,sig)=>{
      if(sig.startsWith('owner('))return cfg.deployed.timelock;
      if(sig.startsWith('getAllInbound'))return spec.inbound;
      if(sig.startsWith('getAllOutbound'))return spec.outbound;
      if(sig.startsWith('getInbound')||sig.startsWith('getOutbound'))return badProvider?local:impl;
      if(sig.startsWith('getAllCCV'))return current;
      if(sig.startsWith('hasRole'))return admin;
      assert.fail('Unexpected read '+sig);
    },
    send:async(chain,actor,call)=>{
      assert.equal(actor,'deployer');assert.equal(call.to,cfg.deployed.timelock);
      const batch=new C.ethers.Interface(G.TL).decodeFunctionData('bypasserExecuteBatch',call.data)[0];
      assert.equal(batch.length,1);assert.equal(batch[0].target,cfg.deployed.advanced_pool_hooks);
      const hook=new C.ethers.Interface(['function applyCCVConfigUpdates((uint64,address[],address[],address[],address[])[])']);
      const rows=hook.decodeFunctionData('applyCCVConfigUpdates',batch[0].data)[0];
      assert.deepEqual([...rows[0][1]],[local,external]);assert.deepEqual([...rows[0][3]],[local,external]);
      current=spec.lanes;sends++;return {hash:C.ethers.id('initial CCV')};
    }};
  try {
    badProvider=true;
    await assert.rejects(applyInitialCcv(rt,'sepolia',spec),/External outbound CCV changed/);
    assert.equal(sends,0);badProvider=false;admin=false;
    await assert.rejects(applyInitialCcv(rt,'sepolia',spec),/temporary deployer admin/);
    assert.equal(sends,0);admin=true;
    await applyInitialCcv(rt,'sepolia',spec);assert.equal(sends,1);
    admin=false;await applyInitialCcv(rt,'sepolia',spec);assert.equal(sends,1);
    assert.equal(C.read(path.join(dir,'state/initial-ccv.sepolia.json')).status,'passed');
  } finally {fs.rmSync(dir,{recursive:true});}
});
test('controlled core retains selected testnet timing defaults and uses only controlled actors',()=>{
  const source=fs.readFileSync(path.join(C.ROOT,'components/core/scripts/scratch/deploy-params-testnet.toml'),'utf8');
  const defaults=C.toml.parse(source);
  const dgDefaults=C.toml.parse(fs.readFileSync(path.join(C.ROOT,'components/core/foundry/lib/dual-governance/deploy-config/deploy-config-hoodi.toml'),'utf8'));
  const p=C.profile(profile), d=P.parameters(source,p,actors);
  assert.deepEqual(d.vesting.holders,{[actors.dao_voter.address]:p.initialTldoSupply});
  assert.equal(d.vesting.unvestedTokensAmount,'0');
  const dg=d.dualGovernance;
  assert.equal(dg.timelock.emergencyProtection.emergencyGovernanceProposer,actors.dg_emergency_proposer.address);
  assert.deepEqual(dg.tiebreaker.committees.map(c=>c.members[0]),[1,2,3].map(i=>actors['dg_tiebreaker_'+i].address));
  assert.equal(d.dao.initialSettings.voting.voteDuration,defaults.dao.initialSettings.voting.voteDuration);
  assert.equal(d.dao.initialSettings.voting.objectionPhaseDuration,defaults.dao.initialSettings.voting.objectionPhaseDuration);
  assert.equal(dg.timelock.afterSubmitDelay,dgDefaults.timelock.after_submit_delay);
  assert.equal(dg.timelock.afterScheduleDelay,dgDefaults.timelock.after_schedule_delay);
  assert.equal(dg.timelock.afterSubmitDelay+dg.timelock.afterScheduleDelay+d.dao.initialSettings.voting.voteDuration+p.timing.l2Executor,540);
  for(const [key,sourceKey] of [
    ['vetoSignallingMinActiveDuration','veto_signalling_min_active_duration'],
    ['vetoCooldownDuration','veto_cooldown_duration'],
    ['rageQuitExtensionPeriodDuration','rage_quit_extension_period_duration'],
  ]) assert.equal(dg.configProvider[key],dgDefaults.dual_governance_config_provider[sourceKey]);
  assert.equal(d.consolidationBus.initialExecutionDelay,defaults.consolidationBus.initialExecutionDelay);
  assert.equal(d.hashConsensusForAccountingOracle.epochsPerFrame,1);
  assert.equal(d.circuitBreaker.initialPauseDuration,300);
});
test('profile rejects a composed wait over ten minutes even when each delay is below ten',()=>{
  const p=C.read(profile);p.timing.dgAfterSubmit=400;
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'access-test-'));
  try {C.write(path.join(dir,'p.json'),p);assert.throws(()=>C.profile(path.join(dir,'p.json')),/combined/);} finally {fs.rmSync(dir,{recursive:true});}
});
test('controlled profile keeps the mainnet zero executor delay and rejects added waits',()=>{
  assert.equal(C.profile(profile).timing.l2Executor,0);
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'access-delay-'));
  try {
    for(const delay of [-1,1,120,'0']) {
      const p=C.read(profile);p.timing.l2Executor=delay;
      C.write(path.join(dir,'p.json'),p);
      assert.throws(()=>C.profile(path.join(dir,'p.json')),/must remain 0/);
    }
  } finally {fs.rmSync(dir,{recursive:true});}
});
test('delivered L2 action executes at its ready timestamp without adding a delay',async()=>{
  const E=C.ethers,dir=fs.mkdtempSync(path.join(os.tmpdir(),'access-zero-delay-'));
  const file=path.join(dir,'state.json');
  const plan={runId:'unit',route:'l2',chain:'base_sepolia',relay:{executor:actors.deployer.address}};
  C.write(file,{planHash:E.keccak256(E.toUtf8Bytes(JSON.stringify(plan))),phase:'l2-queued',
    readyAt:'1000',actionId:'0',receipts:[],transactions:{}});
  const rt={meta:{id:'unit'},wallets:{deployer:actors.deployer},providers:{base_sepolia:{}},
    l1:{voting:actors.dao_voter.address,dg:{}},contract:()=>({}),
    waitUntil:async(chain,timestamp)=>{assert.equal(chain,'base_sepolia');assert.equal(timestamp,1000n);return true;},
    send:async(chain,actor,c,broadcast,attempt)=>{
      assert.equal(actor,'deployer');assert.equal(c.to,plan.relay.executor);
      assert.equal(c.data,C.call(c.to,'execute(uint256)',[0]).data);
      attempt(0);broadcast(E.id('l2-execute'));
      return {hash:E.id('l2-execute'),status:1};
    }};
  try {assert.equal((await G.advance(rt,plan,file)).phase,'done');}
  finally {fs.rmSync(dir,{recursive:true});}
});
test('Aragon codec retains calls and rejects silent loss of ETH value',()=>{
  const c=C.call(actors.dao_voter.address,'foo(uint256)',[23]);
  assert.equal(C.callsScript([c]),'0x00000001'+c.to.slice(2).toLowerCase()+C.ethers.toBeHex(C.ethers.dataLength(c.data),4).slice(2)+c.data.slice(2));
  assert.throws(()=>C.callsScript([{...c,value:'1'}]),/cannot carry ETH/);
});
test('direct Voting and AdminExecutor use distinct authorization routes',async()=>{
  const l1={agent:actors.reserve_0.address,dg:{dualGovernance:actors.dg_reseal.address}};
  const rt={meta:{id:'unit'},l1,providers:{sepolia:{}}};
  const calls=[C.call(actors.deployer.address,'foo()')];
  const direct=await G.build(rt,'voting','sepolia',calls,'test');
  const dg=await G.build(rt,'admin-executor','sepolia',calls,'test');
  const agent=await G.build(rt,'agent','sepolia',calls,'test');
  assert.equal(direct.voteScript,C.callsScript(calls));
  const iface=new C.ethers.Interface(G.DG);
  const decode=p=>iface.decodeFunctionData('submitProposal','0x'+p.voteScript.slice(58));
  assert.equal(decode(dg)[0][0].target,calls[0].to);
  assert.equal(decode(agent)[0][0].target,l1.agent);
});
test('resume recovers scheduled transaction from journal instead of scheduling twice',async()=>{
  const E=C.ethers, dir=fs.mkdtempSync(path.join(os.tmpdir(),'access-journal-'));
  const file=path.join(dir,'state.json'), id=E.id('operation');
  const plan={runId:'unit',route:'ccip',chain:'sepolia',timelock:actors.dg_reseal.address,
    callProxy:actors.deployer.address,salt:E.ZeroHash,predecessor:E.ZeroHash,calls:[C.call(actors.reserve_0.address,'foo()')]};
  const digest=o=>E.keccak256(E.toUtf8Bytes(JSON.stringify(o)));
  const c=C.call(plan.timelock,G.TL[0].slice(9),[[[plan.calls[0].to,'0',plan.calls[0].data]],E.ZeroHash,E.ZeroHash,300n]);
  const tx=E.id('confirmed schedule'), receipt={hash:tx,from:actors.ccip_proposer.address,to:plan.timelock,blockNumber:1,status:1};
  C.write(file,{planHash:digest(plan),phase:'new',receipts:[],transactions:{
    ['new:'+digest({chain:'sepolia',actor:'ccip_proposer',c})]:{hash:tx}}});
  const sent=[];
  const rt={meta:{id:'unit'},wallets:{deployer:actors.deployer},providers:{sepolia:{getTransactionReceipt:async()=>receipt}},
    contract:()=>({hashOperationBatch:async()=>id,getMinDelay:async()=>300n,isOperationDone:async()=>false,
      getTimestamp:async()=>300n,isOperationReady:async()=>true}),waitUntil:async()=>true,
    send:async(chain,actor,call,broadcast,attempt)=>{
      assert.equal(actor,'deployer');sent.push(call);attempt(1);broadcast(E.id('execute'));
      return {...receipt,hash:E.id('execute')};
    }};
  try {
    const state=await G.advance(rt,plan,file);
    assert.equal(state.phase,'done');assert.equal(sent.length,1);assert.equal(state.receipts.length,2);
  } finally {fs.rmSync(dir,{recursive:true});}
});
test('Mantle relay includes MNT and ETH fields; Base uses the standard OP ABI',()=>{
  const E=C.ethers, event={messageNonce:1n<<240n,sender:actors.dao_voter.address,target:actors.deployer.address,gasLimit:5000000,message:'0xabcdef'};
  const base=G.relayData('base_sepolia',event), mantle=G.relayData('mantle_sepolia',event);
  assert.equal(base.slice(0,10),E.id('relayMessage(uint256,address,address,uint256,uint256,bytes)').slice(0,10));
  assert.equal(mantle.slice(0,10),E.id('relayMessage(uint256,address,address,uint256,uint256,uint256,bytes)').slice(0,10));
  const args=new E.Interface(['function relayMessage(uint256,address,address,uint256,uint256,uint256,bytes)']).decodeFunctionData('relayMessage',mantle);
  assert.equal(args[3],0n);assert.equal(args[4],0n);assert.equal(args[5],5000000n);assert.equal(args[6],event.message);
  assert.notEqual(E.keccak256(base),E.keccak256(mantle));
});
test('deployment output strips credentials across stream chunks and preserves receipts',async()=>{
  const {PassThrough}=require('node:stream');
  const key='0x'+'42'.repeat(32), other='0x'+'ab'.repeat(32), hash='0x'+'cd'.repeat(32);
  const input=new PassThrough(), output=new PassThrough();let text='';output.on('data',b=>text+=b);
  const done=R.filter(input,output,{DEPLOYER_PRIVATE_KEY:key,ACTORS_MNEMONIC:'private synthetic phrase'});
  input.write('key='+key.slice(0,31));input.write(key.slice(31)+'\nprivate synthetic phrase\n');
  input.end('--private-key='+other+'\nreceipt='+hash+'\n');await done;
  assert(!text.includes(key));assert(!text.includes(other));assert(!text.includes('private synthetic phrase'));
  assert(text.includes('receipt='+hash));assert.equal((text.match(/REDACTED/g)||[]).length,3);
});

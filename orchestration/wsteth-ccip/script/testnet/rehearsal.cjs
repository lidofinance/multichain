#!/usr/bin/env node
'use strict';
// All authority-bearing calls are signed with local actor keys. Only canonical
// message delivery (not Agent / executor authority) is simulated by Anvil.
const path=require('node:path');
const assert=require('node:assert/strict');
const {execFileSync}=require('node:child_process');
const C=require('./context.cjs'), G=require('./governance.cjs'), O=require('./operations.cjs');
const {ethers:E}=C;
async function rehearse(rt) {
  if(rt.meta.environment!=='fork' || Object.values(rt.forks).some(x=>!x)) throw new Error('Access rehearsal requires all three owned forks');
  const snapshots={};
  const report={scope:'signed operations on forks; canonical message delivery simulated; all changes reverted',checks:[],status:'running'};
  rt.journalRoot=path.join(rt.run,'state/access-rehearsal',Date.now().toString());
  const test=async(name,fn)=>{console.log('Access rehearsal: '+name);await fn();report.checks.push(name);};
  const execute=async(name,route,chain,calls)=>G.execute(rt,await G.build(rt,route,chain,calls,name),name);
  const read=(key,sig,args=[])=>rt.read('sepolia',C.address(rt.core,key),sig,args);
  try {
    for(const [chain,p] of Object.entries(rt.providers)) snapshots[chain]=await p.send('evm_snapshot',[]);
    await test('direct-voting',async()=>{
      const old=await rt.read('sepolia',rt.l1.voting,'supportRequiredPct() view returns(uint64)');
      await execute('direct-voting','voting','sepolia',[
        C.call(rt.l1.voting,'changeSupportRequiredPct(uint64)',[old+1n]),
        C.call(rt.l1.voting,'changeSupportRequiredPct(uint64)',[old])]);
      assert.equal(await rt.read('sepolia',rt.l1.voting,'supportRequiredPct() view returns(uint64)'),old);
    });
    await test('admin-executor',async()=>{
      const tl=rt.l1.dg.timelock;
      await execute('admin-executor','admin-executor','sepolia',[
        C.call(tl,'setAfterSubmitDelay(uint32)',[rt.p.timing.dgAfterSubmit+1]),
        C.call(tl,'setAfterSubmitDelay(uint32)',[rt.p.timing.dgAfterSubmit])]);
      assert.equal(await rt.read('sepolia',tl,'getAfterSubmitDelay() view returns(uint32)'),BigInt(rt.p.timing.dgAfterSubmit));
    });
    for(const [chain,cfg] of Object.entries(rt.records)) {
      const d=cfg.deployed;
      await test(chain+'-brakes-and-dao-recovery',async()=>{
        await rt.send(chain,'emergency_brakes',C.call(d.advanced_pool_hooks,'pauseCrossChainTransfers()'));
        await rt.send(chain,'emergency_brakes',C.call(d.timelock,'haltProposalQueue()'));
        assert.equal(await rt.read(chain,d.timelock,'isProposalQueueHalted() view returns(bool)'),true);
        const calls=[C.call(d.timelock,'restartProposalQueue()'),O.bypass(cfg,[C.call(d.advanced_pool_hooks,'unpauseCrossChainTransfers()')])];
        if(chain!=='sepolia') {
          const implementation=await rt.providers[chain].getStorage(d.token,'0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc');
          calls.push(C.call(d.token_proxy_admin,'upgradeAndCall(address,address,bytes)',[d.token,E.getAddress('0x'+implementation.slice(-40)),'0x']));
          calls.push(C.call(d.token,'grantRole(bytes32,address)',[E.ZeroHash,rt.wallets.reserve_0.address]));
          calls.push(C.call(d.token,'revokeRole(bytes32,address)',[E.ZeroHash,rt.wallets.reserve_0.address]));
        }
        await execute(chain+'-recovery',chain==='sepolia'?'agent':'l2',chain,calls);
        assert.equal(await rt.read(chain,d.timelock,'isProposalQueueHalted() view returns(bool)'),false);
        assert.equal(await rt.read(chain,d.advanced_pool_hooks,'paused() view returns(bool)'),false);
      });
      await test(chain+'-ccip-proposer',async()=>{
        const old=await rt.read(chain,d.advanced_pool_hooks,'getThresholdAmount() view returns(uint256)');
        await execute(chain+'-threshold','ccip',chain,[C.call(d.advanced_pool_hooks,'setThresholdAmount(uint256)',[old+42n])]);
        assert.equal(await rt.read(chain,d.advanced_pool_hooks,'getThresholdAmount() view returns(uint256)'),old+42n);
        await execute(chain+'-threshold-restore','ccip',chain,[C.call(d.advanced_pool_hooks,'setThresholdAmount(uint256)',[old])]);
      });
    }
    await test('ccv-replacement-all-networks',async()=>{
      // Exercise the real planner and signed DAO routes, not a Nethermind implementation.
      // MockCCV is only the replacement fixture; the required Chainlink resolver is retained.
      const snapshots={}, fixtures={}, beforeFile=path.join(rt.run,'config/ccv-policy.json');
      const after=C.read(beforeFile), tag='0x4e4d544e'; // Test tag, not a provider-assigned version.
      const artifact=C.read(path.join(C.OPS,'out/MockCCV.sol/MockCCV.json'));
      C.write(path.join(rt.journalRoot,'MockCCV.artifact.json'),artifact);
      const evidence={scope:'signed local verifier replacement retaining required Chainlink; replacement mock, no provider authentication',
        networks:{},status:'running'};
      const run=async(chain,name,calls)=>execute('ccv-'+name+'-'+chain,chain==='sepolia'?'agent':'l2',chain,calls);
      const lanes=cfg=>cfg.remote_lanes.map(l=>[rt.records[l.remote_chain_name].ccip.chain_selector,0]);
      try {
        for(const [chain,provider] of Object.entries(rt.providers)) snapshots[chain]=await provider.send('evm_snapshot',[]);
        for(const [chain,cfg] of Object.entries(rt.records)) {
          const signer=rt.wallets.deployer.connect(rt.providers[chain]);
          await rt.providers[chain].send('anvil_setBalance',[signer.address,E.toBeHex(E.parseEther('10000'))]);
          const factory=new E.ContractFactory(artifact.abi,artifact.bytecode.object,signer);
          const replacement=await factory.deploy();await replacement.waitForDeployment();
          fixtures[chain]={replacement:await replacement.getAddress()};
          const spec=after.chains[chain], f=fixtures[chain];
          spec.localResolver.inbound={[tag]:f.replacement};
          spec.localResolver.outbound=Object.fromEntries(cfg.remote_lanes.map(l=>[l.remote_chain_name,f.replacement]));
          await run(chain,'pause',[O.bypass(cfg,[C.call(cfg.deployed.advanced_pool_hooks,'pauseRemoteLanes((uint64,uint8)[])',[lanes(cfg)])])]);
        }
        const afterFile=path.join(rt.journalRoot,'ccv-after.json'),planFile=path.join(rt.journalRoot,'ccv-replacement-plan.json');
        C.write(afterFile,after);
        execFileSync(process.execPath,[path.join(C.OPS,'script/plan-ccv-update.cjs'),path.join(rt.run,'config/chains'),beforeFile,afterFile,planFile]);
        const plan=C.read(planFile);
        assert.equal(plan.actions.length,9); // Inbound, outbound, retirement; required CCVs already correct.
        assert(!plan.actions.some(a=>a.phase==='3-set-required-ccvs'));
        for(const a of plan.actions) {
          assert(G.equal(a.requiredCaller,rt.records[a.chain].governance_addresses.lido_dao_agent));
          await run(a.chain,a.phase,[{to:a.to,value:a.value,data:a.data}]);
        }
        for(const [chain,cfg] of Object.entries(rt.records)) {
          const f=fixtures[chain], resolver=cfg.ccv.verifier_resolver;
          assert(G.equal(await rt.read(chain,resolver,'owner() view returns(address)'),cfg.deployed.timelock));
          assert(G.equal(await rt.read(chain,resolver,'getInboundImplementation(bytes) view returns(address)',[tag]),f.replacement));
          assert.equal(await rt.read(chain,resolver,'getInboundImplementation(bytes) view returns(address)',['0xdecafbad']),E.ZeroAddress);
          for(const lane of cfg.remote_lanes) {
            const selector=rt.records[lane.remote_chain_name].ccip.chain_selector;
            assert(G.equal(await rt.read(chain,resolver,'getOutboundImplementation(uint64,bytes) view returns(address)',[selector,'0x']),f.replacement));
            for(const direction of [0,1]) {
              const required=await rt.read(chain,cfg.deployed.advanced_pool_hooks,
                'getRequiredCCVs(address,uint64,uint256,bytes4,bytes,uint8) view returns(address[])',
                [E.ZeroAddress,selector,0,'0x00000000','0x',direction]);
              const expected=after.chains[chain].lanes[lane.remote_chain_name][direction===0?'outbound':'inbound'];
              assert.equal(expected.length,2);
              assert.deepEqual(required.map(a=>a.toLowerCase()),expected.map(a=>(a==='local'?resolver:a).toLowerCase()));
            }
          }
          const token=cfg.deployed.token||cfg.addresses.token;
          assert(G.equal(await rt.read(chain,cfg.deployed.token_pool,'getToken() view returns(address)'),token));
          const tar=await rt.read(chain,cfg.ccip.token_admin_registry,'getTokenConfig(address) view returns((address,address,address))',[token]);
          assert(G.equal(tar[2],cfg.deployed.token_pool));
          await run(chain,'unpause',[O.bypass(cfg,[C.call(cfg.deployed.advanced_pool_hooks,'unpauseRemoteLanes((uint64,uint8)[])',[lanes(cfg)])])]);
          assert.equal((await rt.read(chain,cfg.deployed.advanced_pool_hooks,'getDisabledRemoteLanes() view returns((uint64,uint8)[])')).length,0);
          evidence.networks[chain]={...f,token,pool:cfg.deployed.token_pool,resolver,
            remoteLanes:cfg.remote_lanes.map(l=>l.remote_chain_name),dummyRetired:true};
        }
        evidence.status='passed';
      } catch(error) {
        evidence.status='failed';throw error;
      } finally {
        evidence.reverted={};
        for(const [chain,id] of Object.entries(snapshots)) evidence.reverted[chain]=await rt.providers[chain].send('evm_revert',[id]);
        C.write(path.join(rt.journalRoot,'ccv-replacement-evidence.json'),evidence);
        assert(Object.values(evidence.reverted).every(Boolean));
      }
    });
    await test('scoped-lockbox-withdrawal',async()=>{
      // Both deposits and withdrawals use public, signed entry points.
      if(await rt.read('sepolia',rt.l1.stETH,'isStopped() view returns(bool)'))
        await execute('resume-for-liquidity','agent','sepolia',[C.call(rt.l1.stETH,'resume()')]);
      const remote=Object.keys(rt.records).find(x=>x!=='sepolia');
      const box=rt.records.sepolia.deployed.lock_boxes.find(b=>b.remote_chain_name===remote).lock_box;
      await rt.send('sepolia','deployer',{to:rt.l1.wstETH,data:'0x',value:E.parseEther('0.01').toString()});
      await rt.send('sepolia','deployer',C.call(rt.l1.wstETH,'transfer(address,uint256)',[box,1000]));
      const callers=await rt.read('sepolia',box,'getAllAuthorizedCallers() view returns(address[])');
      const recipient=rt.wallets.reserve_0.address;
      const before=await rt.read('sepolia',rt.l1.wstETH,'balanceOf(address) view returns(uint256)',[recipient]);
      await G.execute(rt,await O.lockboxPlan(rt,remote,1000n,recipient),'scoped-lockbox-withdrawal');
      assert.equal(await rt.read('sepolia',rt.l1.wstETH,'balanceOf(address) view returns(uint256)',[recipient]),before+1000n);
      assert.deepEqual([...await rt.read('sepolia',box,'getAllAuthorizedCallers() view returns(address[])')],[...callers]);
    });
    await test('hooks-allowlist-replacement',async()=>{
      const chain=rt.records.base_sepolia?'base_sepolia':Object.keys(rt.records).find(x=>x!=='sepolia');
      const d=rt.records[chain].deployed;
      const plan=await O.replaceHooks(rt,chain,[rt.wallets.deployer.address]);
      await G.execute(rt,plan,'hooks-allowlist-replacement');
      const next=plan.calls[0].to;
      assert(G.equal(await rt.read(chain,d.token_pool,'getAdvancedPoolHooks() view returns(address)'),next));
      assert(G.equal(await rt.read(chain,next,'owner() view returns(address)'),d.timelock));
      assert.equal(await rt.read(chain,next,'getAllowListEnabled() view returns(bool)'),true);
      assert.deepEqual([...await rt.read(chain,next,'getAllowList() view returns(address[])')],[rt.wallets.deployer.address]);
      await execute('hooks-restore','ccip',chain,[C.call(d.token_pool,'updateAdvancedPoolHooks(address)',[d.advanced_pool_hooks])]);
    });
    await test('oracle-two-of-three',async()=>{
      for(const [key,processor] of [['hashConsensusForAccountingOracle','accountingOracle'],['hashConsensusForValidatorsExitBusOracle','validatorsExitBusOracle']]) {
        const addr=C.address(rt.core,key), hash=E.id('fork-only report '+key);
        // Start a complete frame to avoid crossing its boundary during submission.
        const chain=await read(key,'getChainConfig() view returns(uint256,uint256,uint256)');
        const latest=BigInt((await rt.providers.sepolia.getBlock('latest')).timestamp);
        const duration=chain[0]*chain[1];
        await rt.waitUntil('sepolia',((latest-chain[2])/duration+1n)*duration+chain[2]+1n);
        const frame=await read(key,'getCurrentFrame() view returns(uint256,uint256)');
        const version=await read(processor,'getConsensusVersion() view returns(uint256)');
        // With quorum 2, rotating fast-lane membership may exclude one signer.
        let signed=0;
        for(let i=1;i<=3;i++) if(await read(key,'getIsFastLaneMember(address) view returns(bool)',[rt.wallets['oracle_'+i].address])) {
          await rt.send('sepolia','oracle_'+i,C.call(addr,'submitReport(uint256,bytes32,uint256)',[frame[0],hash,version]));signed++;
        }
        assert.equal(signed,2);
        assert.equal((await read(key,'getConsensusState() view returns(uint256,bytes32,bool)'))[1],hash);
      }
    });
    await test('dsm-guardian-and-dao-unpause',async()=>{
      const addr=C.address(rt.core,'depositSecurityModule');
      await O.pauseDsm(rt,1);
      assert.equal(await read('depositSecurityModule','isDepositsPaused() view returns(bool)'),true);
      await execute('dsm-unpause','agent','sepolia',[C.call(addr,'unpauseDeposits()')]);
      assert.equal(await read('depositSecurityModule','isDepositsPaused() view returns(bool)'),false);
    });
    await test('brakes-reseal-tiebreaker',async()=>{
      // Isolate the deliberately entered veto state from other governance tests.
      const snapshot=await rt.providers.sepolia.send('evm_snapshot',[]);
      try {
        const dg=rt.l1.dg.dualGovernance, wq=C.address(rt.core,'withdrawalQueueERC721');
        const escrow=await rt.read('sepolia',dg,'getVetoSignallingEscrow() view returns(address)');
        const supply=await rt.read('sepolia',rt.l1.stETH,'totalSupply() view returns(uint256)');
        const amount=await rt.read('sepolia',rt.l1.wstETH,'getWstETHByStETH(uint256) view returns(uint256)',[supply/50n]);
        await rt.send('sepolia','deployer',C.call(rt.l1.wstETH,'approve(address,uint256)',[escrow,amount]));
        await rt.send('sepolia','deployer',C.call(escrow,'lockWstETH(uint256)',[amount]));
        assert.equal(await rt.read('sepolia',dg,'getEffectiveState() view returns(uint8)'),2n);
        await rt.send('sepolia','emergency_brakes',C.call(C.address(rt.core,'circuitBreaker'),'pause(address)',[wq]));
        await rt.send('sepolia','dg_reseal',C.call(dg,'resealSealable(address)',[wq]));
        assert.equal(await rt.read('sepolia',wq,'getResumeSinceTimestamp() view returns(uint256)'),E.MaxUint256);
        const sub=rt.core['dg:tiebreakerSubCommittees'].addresses;
        for(let i=0;i<2;i++) {
          await rt.send('sepolia','dg_tiebreaker_'+(i+1),C.call(sub[i],'sealableResume(address)',[wq]));
          await rt.send('sepolia','deployer',C.call(sub[i],'executeSealableResume(address)',[wq]));
        }
        const tb=C.address(rt.core,'dg:tiebreakerCoreCommittee');
        const nonce=await rt.read('sepolia',tb,'getSealableResumeNonce(address) view returns(uint256)',[wq]);
        const state=await rt.read('sepolia',tb,'getSealableResumeState(address,uint256) view returns(uint256,uint256,uint40,bool)',[wq,nonce]);
        assert.equal(state[0],2n);
        await rt.waitUntil('sepolia',state[2]+300n+1n);
        await rt.send('sepolia','deployer',C.call(tb,'executeSealableResume(address)',[wq]));
        assert.equal(await rt.read('sepolia',wq,'isPaused() view returns(bool)'),false);
      } finally {assert(await rt.providers.sepolia.send('evm_revert',[snapshot]));}
    });
    await test('emergency-committees',async()=>{
      const tl=rt.l1.dg.timelock;
      await rt.send('sepolia','dg_emergency_activation',C.call(tl,'activateEmergencyMode()'));
      assert.equal(await rt.read('sepolia',tl,'isEmergencyModeActive() view returns(bool)'),true);
      await rt.send('sepolia','dg_emergency_execution',C.call(tl,'emergencyReset()'));
      const emergency=await rt.read('sepolia',tl,'getEmergencyGovernance() view returns(address)');
      assert(G.equal(await rt.read('sepolia',tl,'getGovernance() view returns(address)'),emergency));
      const contract=rt.contract('sepolia',emergency,G.DG);
      const receipt=await rt.send('sepolia','dg_emergency_proposer',C.call(emergency,G.DG[0].slice(9),[
        [[tl,0,C.call(tl,'setGovernance(address)',[rt.l1.dg.dualGovernance]).data]],'Restore normal governance']));
      const id=G.events(receipt,contract,'ProposalSubmitted')[0].args.proposalId;
      const submitted=(await rt.read('sepolia',tl,'getProposalDetails(uint256) view returns((uint256,address,uint40,uint40,uint8))',[id]))[2];
      await rt.waitUntil('sepolia',submitted+BigInt(rt.p.timing.dgAfterSubmit)+1n);
      await rt.send('sepolia','deployer',C.call(emergency,'scheduleProposal(uint256)',[id]));
      const scheduled=(await rt.read('sepolia',tl,'getProposalDetails(uint256) view returns((uint256,address,uint40,uint40,uint8))',[id]))[3];
      await rt.waitUntil('sepolia',scheduled+BigInt(rt.p.timing.dgAfterSchedule)+1n);
      await rt.send('sepolia','deployer',C.call(tl,'execute(uint256)',[id]));
      assert(G.equal(await rt.read('sepolia',tl,'getGovernance() view returns(address)'),rt.l1.dg.dualGovernance));
    });
    report.status='passed';
  } catch(error) {
    report.status='failed';throw error;
  } finally {
    report.reverted={};
    for(const [chain,id] of Object.entries(snapshots)) report.reverted[chain]=await rt.providers[chain].send('evm_revert',[id]);
    C.write(path.join(rt.run,'state/access-rehearsal.json'),report);
  }
  assert(Object.values(report.reverted).every(Boolean));
  await O.verify(rt);
  console.log('Signed access rehearsal passed: '+report.checks.length+' checks.');
  return report;
}
if(require.main===module) G.runtime().then(async rt=>{try {await rehearse(rt);} finally {rt.close();}}).catch(e=>{
  console.error('Access rehearsal failed: '+(e.code||e.message));process.exitCode=1;
});
module.exports={rehearse};

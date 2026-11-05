#!/usr/bin/env node
'use strict';
const fs=require('node:fs');
const path=require('node:path');
const C=require('./context.cjs'), G=require('./governance.cjs');
const {ethers:E}=C;
const ADMIN=E.ZeroHash;
const OZ=['burner','hashConsensusForAccountingOracle','hashConsensusForValidatorsExitBusOracle','stakingRouter',
  'accountingOracle','validatorsExitBusOracle','withdrawalQueueERC721','oracleDaemonConfig','oracleReportSanityChecker',
  'triggerableWithdrawalsGateway','consolidationGateway','consolidationBus','consolidationMigrator','topUpGateway',
  'vaultHub','predepositGuarantee','operatorGrid','lazyOracle'];
const PROXIES=['lidoLocator','stakingRouter','accountingOracle','validatorsExitBusOracle','withdrawalQueueERC721',
  'accounting','vaultHub','predepositGuarantee','operatorGrid','lazyOracle','burner','consolidationBus',
  'consolidationMigrator','topUpGateway','sepoliaDepositAdapter'];
const RETAINED=[['consolidationBus','MANAGE_ROLE'],['consolidationGateway','ADD_CONSOLIDATION_REQUEST_ROLE'],['consolidationMigrator','ALLOW_PAIR_ROLE']];
const assert=(ok,reason)=>{if(!ok) throw new Error(reason);};
const role=name=>E.id(name);
const managedRoles=(target,name,holder,grant=true)=>C.call(target,(grant?'grantRole':'revokeRole')+'(bytes32,address)',[role(name),holder]);
async function dsmGuardians(rt) {
  const file=path.join(rt.run,'state/dsm-guardians.json');
  const result=fs.existsSync(file)?C.read(file):[];
  const artifact=C.read(path.join(C.OPS,'out/TestnetDsmGuardian.sol/TestnetDsmGuardian.json'));
  C.write(path.join(rt.run,'state/TestnetDsmGuardian.artifact.json'),artifact);
  const signer=rt.wallets.deployer.connect(rt.providers.sepolia);
  if(rt.forks.sepolia) await rt.providers.sepolia.send('anvil_setBalance',[signer.address,E.toBeHex(E.parseEther('10000'))]);
  for(let i=1;i<=3;i++) {
    if(!result[i-1]) {
      const contract=await new E.ContractFactory(artifact.abi,artifact.bytecode.object,signer).deploy(rt.wallets['dsm_guardian_'+i].address);
      await contract.waitForDeployment();
      result.push({address:await contract.getAddress(),signer:rt.wallets['dsm_guardian_'+i].address,tx:contract.deploymentTransaction().hash});
      C.write(file,result);
    }
    assert(G.equal(await rt.read('sepolia',result[i-1].address,'signer() view returns(address)'),rt.wallets['dsm_guardian_'+i].address),'DSM guardian signer mismatch');
  }
  return result;
}
async function pauseDsm(rt,index) {
  assert([1,2,3].includes(index),'Guardian index must be 1, 2 or 3');
  const guardian=C.read(path.join(rt.run,'state/dsm-guardians.json'))[index-1].address;
  const dsm=C.address(rt.core,'depositSecurityModule'), block=await rt.providers.sepolia.getBlockNumber();
  const prefix=await rt.read('sepolia',dsm,'PAUSE_MESSAGE_PREFIX() view returns(bytes32)');
  const hash=E.solidityPackedKeccak256(['bytes32','address','uint256'],[prefix,guardian,block]);
  const signature=rt.wallets['dsm_guardian_'+index].signingKey.sign(hash).serialized;
  return rt.send('sepolia','dsm_guardian_'+index,C.call(dsm,'pauseDeposits(uint256,(address guardian,bytes signature))',[block,[guardian,signature]]));
}
async function coreAccess(rt) {
  const agent=rt.l1.agent, deployer=rt.wallets.deployer.address;
  const beacon=C.address(rt.core,'stakingVaultBeacon');
  const owner=await rt.read('sepolia',beacon,'owner() view returns(address)');
  if(G.equal(owner,deployer)) await rt.send('sepolia','deployer',C.call(beacon,'transferOwnership(address)',[agent]));
  else assert(G.equal(owner,agent),'Unknown staking vault beacon owner');
  const guardians=await dsmGuardians(rt);
  const file=path.join(rt.run,'state/governance/core-access.plan.json');
  if(fs.existsSync(file)) return G.execute(rt,C.read(file),'core-access');
  const calls=[];
  for(const key of ['hashConsensusForAccountingOracle','hashConsensusForValidatorsExitBusOracle']) {
    const target=C.address(rt.core,key);
    calls.push(managedRoles(target,'MANAGE_MEMBERS_AND_QUORUM_ROLE',agent));
    for(let i=1;i<=3;i++) calls.push(C.call(target,'addMember(address,uint256)',[rt.wallets['oracle_'+i].address,rt.p.oracleQuorum]));
    const chain=await rt.read('sepolia',target,'getChainConfig() view returns(uint256,uint256,uint256)');
    const now=(await rt.providers.sepolia.getBlock('latest')).timestamp;
    const epoch=(BigInt(now)-chain[2])/(chain[0]*chain[1]);
    calls.push(C.call(target,'updateInitialEpoch(uint256)',[epoch]));
    calls.push(managedRoles(target,'MANAGE_MEMBERS_AND_QUORUM_ROLE',agent,false));
  }
  calls.push(C.call(C.address(rt.core,'depositSecurityModule'),'addGuardians(address[],uint256)',[
    guardians.map(g=>g.address),rt.p.dsmQuorum]));
  for(const key of ['withdrawalQueueERC721','validatorsExitBusOracle']) {
    calls.push(C.call(C.address(rt.core,'circuitBreaker'),'registerPauser(address,address)',[
      C.address(rt.core,key),rt.wallets.emergency_brakes.address]));
  }
  // Core pause authority uses the same privately controlled brakes, with DAO as permission manager.
  const acl=C.address(rt.core,'aragon-acl');
  for(const name of ['PAUSE_ROLE','STAKING_PAUSE_ROLE']) calls.push(C.call(acl,'grantPermission(address,address,bytes32)',[
    rt.wallets.emergency_brakes.address,rt.l1.stETH,role(name)]));
  for(const [key,name] of RETAINED) calls.push(managedRoles(C.address(rt.core,key),name,deployer,false));
  return G.execute(rt,await G.build(rt,'agent','sepolia',calls,'Configure controlled testnet core operators and remove temporary privileges'),'core-access');
}
function bypass(cfg,calls) {
  return C.call(cfg.deployed.timelock,G.TL[2].slice(9),[calls.map(c=>[c.to,c.value||0,c.data])]);
}
async function lockboxPlan(rt,remote,amount,recipient) {
  const cfg=rt.records.sepolia;
  const entry=cfg.deployed.lock_boxes.find(b=>b.remote_chain_name===remote);
  assert(entry,'No lockbox for '+remote);
  const tl=cfg.deployed.timelock, token=cfg.deployed.token||cfg.addresses.token;
  const current=await rt.read('sepolia',entry.lock_box,'getAllAuthorizedCallers() view returns(address[])');
  const temporary=!current.some(a=>G.equal(a,tl));
  const calls=[];
  if(temporary) calls.push(C.call(entry.lock_box,'applyAuthorizedCallerUpdates((address[] addedCallers,address[] removedCallers))',[[[tl],[]]]));
  calls.push(C.call(entry.lock_box,'withdraw(address,uint64,uint256,address)',[token,rt.records[remote].ccip.chain_selector,amount,recipient]));
  if(temporary) calls.push(C.call(entry.lock_box,'applyAuthorizedCallerUpdates((address[] addedCallers,address[] removedCallers))',[[[],[tl]]]));
  return G.build(rt,'agent','sepolia',[bypass(cfg,calls)],'Withdraw lockbox liquidity with scoped authorization');
}
async function replaceHooks(rt,chain,allowlist) {
  assert(allowlist.length>0 && allowlist.every(E.isAddress),'Nonempty address allowlist required');
  const cfg=rt.records[chain], old=cfg.deployed.advanced_pool_hooks;
  // Reuse the run's archived release artifact, never compile inside the upstream checkout.
  const artifactFile=path.join(rt.run,'state/ccip-build/PausableAdvancedPoolHooks.json');
  const artifact=C.read(artifactFile);
  const ccvAbi='getAllCCVConfigs() view returns((uint64 remoteChainSelector,address[] outboundCCVs,address[] thresholdOutboundCCVs,address[] inboundCCVs,address[] thresholdInboundCCVs)[])';
  const ccvs=await rt.read(chain,old,ccvAbi);
  const threshold=await rt.read(chain,old,'getThresholdAmount() view returns(uint256)');
  const policy=await rt.read(chain,old,'getPolicyEngine() view returns(address)');
  assert(!await rt.read(chain,old,'paused() view returns(bool)'),'Unpause global hooks before replacing them');
  const disabled=await rt.read(chain,old,'getDisabledRemoteLanes() view returns((uint64 remoteChainSelector,uint8 direction)[])');
  const provider=rt.providers[chain], signer=rt.wallets.deployer.connect(provider);
  if(rt.forks[chain]) await provider.send('anvil_setBalance',[signer.address,E.toBeHex(E.parseEther('10000'))]);
  const members=async name=>{
    const count=await rt.read(chain,old,'getRoleMemberCount(bytes32) view returns(uint256)',[role(name)]);
    const result=[];
    for(let i=0;i<Number(count);i++) result.push(await rt.read(chain,old,'getRoleMember(bytes32,uint256) view returns(address)',[role(name),i]));
    return result;
  };
  const pausers=await members('CROSS_CHAIN_TRANSFERS_PAUSE_ROLE'), unpausers=await members('CROSS_CHAIN_TRANSFERS_UNPAUSE_ROLE');
  const callers=await rt.read(chain,old,'getAllAuthorizedCallers() view returns(address[])');
  const factory=new E.ContractFactory(artifact.abi,artifact.bytecode.object||artifact.bytecode,signer);
  const hooks=await factory.deploy(allowlist,threshold,policy,[...callers],pausers,unpausers);
  await hooks.waitForDeployment(); const address=await hooks.getAddress();
  const record={chain,previous:old,replacement:address,deployTx:hooks.deploymentTransaction().hash,allowlist};
  // Fork rehearsals revert the deployment: keep their records with the reverted
  // operation journals, never among the run's current deployment addresses.
  C.write(path.join(rt.journalRoot || path.join(rt.run,'state'),'hooks-replacement.'+chain+'.json'),record);
  await rt.send(chain,'deployer',C.call(address,'applyCCVConfigUpdates((uint64,address[],address[],address[],address[])[])',[
    ccvs.map(c=>[c[0],[...c[1]],[...c[2]],[...c[3]],[...c[4]]])]));
  if(disabled.length) await rt.send(chain,'deployer',C.call(address,'pauseRemoteLanes((uint64,uint8)[])',[disabled.map(x=>[x[0],x[1]])]));
  await rt.send(chain,'deployer',C.call(address,'transferOwnership(address)',[cfg.deployed.timelock]));
  const calls=[C.call(address,'acceptOwnership()'),C.call(cfg.deployed.token_pool,'updateAdvancedPoolHooks(address)',[address])];
  return G.build(rt,'ccip',chain,calls,'Replace hooks to enable immutable sender allowlist');
}
async function verify(rt) {
  const checks={};
  const check=(name,ok)=>{assert(ok,'Access invariant failed: '+name);checks[name]=true;};
  const agent=rt.l1.agent,deployer=rt.wallets.deployer.address;
  const read=(key,sig,args=[])=>rt.read('sepolia',C.address(rt.core,key),sig,args);
  for(const key of OZ) {
    check(key+'.admin',G.equal(await read(key,'getRoleMember(bytes32,uint256) view returns(address)',[ADMIN,0]),agent));
    check(key+'.sole-admin',await read(key,'getRoleMemberCount(bytes32) view returns(uint256)',[ADMIN])===1n);
  }
  for(const key of PROXIES) if(rt.core[key]) check(key+'.proxy-admin',G.equal(await read(key,'proxy__getAdmin() view returns(address)'),agent));
  for(const [key,name] of RETAINED) check(key+'.no-deployer-'+name,!await read(key,'hasRole(bytes32,address) view returns(bool)',[role(name),deployer]));
  check('beacon.owner',G.equal(await read('stakingVaultBeacon','owner() view returns(address)'),agent));
  check('withdrawal-vault.admin',G.equal(await read('withdrawalVault','proxy_getAdmin() view returns(address)'),rt.l1.voting));
  check('dsm.owner',G.equal(await read('depositSecurityModule','getOwner() view returns(address)'),agent));
  check('dsm.quorum',await read('depositSecurityModule','getGuardianQuorum() view returns(uint256)')===BigInt(rt.p.dsmQuorum));
  const guardians=await read('depositSecurityModule','getGuardians() view returns(address[])');
  const guardianContracts=C.read(path.join(rt.run,'state/dsm-guardians.json'));
  check('dsm.members',guardians.length===3&&guardianContracts.every(g=>guardians.some(a=>G.equal(a,g.address))));
  for(let i=0;i<3;i++) check('dsm.signer-'+i,G.equal(await rt.read('sepolia',guardianContracts[i].address,'signer() view returns(address)'),rt.wallets['dsm_guardian_'+(i+1)].address));
  for(const key of ['hashConsensusForAccountingOracle','hashConsensusForValidatorsExitBusOracle']) {
    const members=await read(key,'getMembers() view returns(address[],uint256[])');
    check(key+'.members',members[0].length===3&&[1,2,3].every(i=>members[0].some(a=>G.equal(a,rt.wallets['oracle_'+i].address))));
    check(key+'.quorum',await read(key,'getQuorum() view returns(uint256)')===BigInt(rt.p.oracleQuorum));
    const config=await read(key,'getFrameConfig() view returns(uint256,uint256,uint256)');
    check(key+'.short-frame',config[1]===1n);
    check(key+'.active-frame',config[0]<1000000000n);
  }
  for(const key of ['withdrawalQueueERC721','validatorsExitBusOracle']) check(key+'.circuit-pauser',
    G.equal(await read('circuitBreaker','getPauser(address) view returns(address)',[C.address(rt.core,key)]),rt.wallets.emergency_brakes.address));
  check('circuit-breaker.admin',G.equal(await read('circuitBreaker','ADMIN() view returns(address)'),agent));
  const tldo=C.address(rt.core,'ldo');
  const supply=await rt.read('sepolia',tldo,'totalSupply() view returns(uint256)');
  check('dao.sole-voter',supply===BigInt(rt.p.initialTldoSupply)&&
    await rt.read('sepolia',tldo,'balanceOf(address) view returns(uint256)',[rt.wallets.dao_voter.address])===supply);
  const acl=C.address(rt.core,'aragon-acl');
  check('voting.duration',await rt.read('sepolia',rt.l1.voting,'voteTime() view returns(uint64)')===BigInt(rt.p.timing.voting));
  const aclRole=async(app,name,holder,manager)=>{
    check('acl.'+app+'.'+name+'.holder',await rt.read('sepolia',acl,'hasPermission(address,address,bytes32) view returns(bool)',[holder,app,role(name)]));
    check('acl.'+app+'.'+name+'.manager',G.equal(await rt.read('sepolia',acl,'getPermissionManager(address,bytes32) view returns(address)',[app,role(name)]),manager));
  };
  await aclRole(C.address(rt.core,'aragon-kernel'),'APP_MANAGER_ROLE',rt.l1.voting,rt.l1.voting);
  for(const name of ['CREATE_PAYMENTS_ROLE','EXECUTE_PAYMENTS_ROLE','MANAGE_PAYMENTS_ROLE'])
    await aclRole(C.address(rt.core,'app:aragon-finance'),name,rt.l1.voting,rt.l1.voting);
  const evmRegistry=await rt.read('sepolia',acl,'getEVMScriptRegistry() view returns(address)');
  for(const name of ['REGISTRY_MANAGER_ROLE','REGISTRY_ADD_EXECUTOR_ROLE']) await aclRole(evmRegistry,name,rt.l1.voting,rt.l1.voting);
  for(const name of ['MODIFY_SUPPORT_ROLE','MODIFY_QUORUM_ROLE']) await aclRole(rt.l1.voting,name,rt.l1.voting,rt.l1.voting);
  for(const name of ['PAUSE_ROLE','STAKING_PAUSE_ROLE']) await aclRole(rt.l1.stETH,name,rt.wallets.emergency_brakes.address,agent);
  if(rt.core.sepoliaDepositAdapter) check('deposit-adapter.owner',G.equal(await read('sepoliaDepositAdapter','owner() view returns(address)'),agent));
  check('template.owner',G.equal(await read('lidoTemplate','getConfig() view returns(address)'),agent));
  check('dg.reseal',G.equal(await rt.read('sepolia',rt.l1.dg.dualGovernance,'getResealCommittee() view returns(address)'),rt.wallets.dg_reseal.address));
  for(const [method,actor] of [['getEmergencyActivationCommittee','dg_emergency_activation'],['getEmergencyExecutionCommittee','dg_emergency_execution']])
    check('dg.'+method,G.equal(await rt.read('sepolia',rt.l1.dg.timelock,method+'() view returns(address)'),rt.wallets[actor].address));
  const emergency=await rt.read('sepolia',rt.l1.dg.timelock,'getEmergencyGovernance() view returns(address)');
  check('dg.emergency-proposer',G.equal(await rt.read('sepolia',emergency,'GOVERNANCE() view returns(address)'),rt.wallets.dg_emergency_proposer.address));
  for(const [method,name] of [['getAfterSubmitDelay','dgAfterSubmit'],['getAfterScheduleDelay','dgAfterSchedule']])
    check('dg.'+method,await rt.read('sepolia',rt.l1.dg.timelock,method+'() view returns(uint32)')===BigInt(rt.p.timing[name]));
  const subcommittees=rt.core['dg:tiebreakerSubCommittees'].addresses;
  check('dg.subcommittee-count',subcommittees.length===3);
  for(let i=0;i<subcommittees.length;i++) {
    const members=await rt.read('sepolia',subcommittees[i],'getMembers() view returns(address[])');
    check('dg.subcommittee-'+i,members.length===1&&G.equal(members[0],rt.wallets['dg_tiebreaker_'+(i+1)].address));
    check('dg.subcommittee-owner-'+i,G.equal(await rt.read('sepolia',subcommittees[i],'owner() view returns(address)'),rt.l1.dg.adminExecutor));
  }
  const tb=C.address(rt.core,'dg:tiebreakerCoreCommittee');
  check('dg.tiebreaker-quorum',await rt.read('sepolia',tb,'getQuorum() view returns(uint256)')===2n);
  for(const name of ['RUN_SCRIPT_ROLE','EXECUTE_ROLE']) {
    check('agent.'+name+'.executor',await rt.read('sepolia',acl,'hasPermission(address,address,bytes32) view returns(bool)',[rt.l1.dg.adminExecutor,agent,role(name)]));
    check('agent.'+name+'.manager',G.equal(await rt.read('sepolia',acl,'getPermissionManager(address,bytes32) view returns(address)',[agent,role(name)]),agent));
  }
  for(const [chain,cfg] of Object.entries(rt.records)) {
    if(!cfg.deployed) continue;
    const d=cfg.deployed,admin=cfg.governance_addresses.lido_dao_agent;
    const roles={ADMIN_ROLE:[admin],PROPOSER_ROLE:[rt.wallets.ccip_proposer.address],
      CANCELLER_ROLE:[rt.wallets.ccip_proposer.address,rt.wallets.emergency_brakes.address],
      PROPOSAL_QUEUE_HALT_ROLE:[rt.wallets.emergency_brakes.address],EXECUTOR_ROLE:[d.call_proxy],BYPASSER_ROLE:[]};
    for(const [name,expected] of Object.entries(roles)) {
      const count=await rt.read(chain,d.timelock,'getRoleMemberCount(bytes32) view returns(uint256)',[role(name)]);
      check(chain+'.'+name+'.count',count===BigInt(expected.length));
      for(const a of expected) check(chain+'.'+name+'.'+a,await rt.read(chain,d.timelock,'hasRole(bytes32,address) view returns(bool)',[role(name),a]));
    }
    for(const addr of [d.token_pool,d.advanced_pool_hooks,...Object.values(cfg.ccv),...d.lock_boxes.map(b=>b.lock_box)])
      check(chain+'.owner.'+addr,G.equal(await rt.read(chain,addr,'owner() view returns(address)'),d.timelock));
    check(chain+'.delay',await rt.read(chain,d.timelock,'getMinDelay() view returns(uint256)')===BigInt(rt.p.timing.ccip));
    check(chain+'.expiry',await rt.read(chain,d.timelock,'getExpiryPeriod() view returns(uint120)')===BigInt(rt.p.timing.proposalExpiry));
    const tar=await rt.read(chain,cfg.ccip.token_admin_registry,'getTokenConfig(address) view returns((address administrator,address pendingAdministrator,address tokenPool))',[d.token||cfg.addresses.token]);
    check(chain+'.tar',G.equal(tar.administrator,d.timelock)&&G.equal(tar.tokenPool,d.token_pool)&&tar.pendingAdministrator===E.ZeroAddress);
    if(chain!=='sepolia') {
      check(chain+'.executor-agent',G.equal(await rt.read(chain,admin,'getEthereumGovernanceExecutor() view returns(address)'),agent));
      check(chain+'.executor-delay',await rt.read(chain,admin,'getDelay() view returns(uint256)')===BigInt(rt.p.timing.l2Executor));
      check(chain+'.executor-max-delay',await rt.read(chain,admin,'getMaximumDelay() view returns(uint256)')===1n);
      check(chain+'.executor-min-delay',await rt.read(chain,admin,'getMinimumDelay() view returns(uint256)')===0n);
      check(chain+'.executor-grace',await rt.read(chain,admin,'getGracePeriod() view returns(uint256)')===BigInt(rt.p.timing.executionGrace));
      check(chain+'.guardian',G.equal(await rt.read(chain,admin,'getGuardian() view returns(address)'),deployer));
      check(chain+'.token-admin',await rt.read(chain,d.token,'hasRole(bytes32,address) view returns(bool)',[ADMIN,admin]));
      check(chain+'.token-no-deployer',!await rt.read(chain,d.token,'hasRole(bytes32,address) view returns(bool)',[ADMIN,deployer]));
      check(chain+'.upgrade-owner',G.equal(await rt.read(chain,d.token_proxy_admin,'owner() view returns(address)'),admin));
    }
  }
  C.write(path.join(rt.run,'state/access-invariants.json'),{scope:'readback; execution evidence is separate',checks});
  console.log('Verified '+Object.keys(checks).length+' access invariants.'); return checks;
}
async function main(args) {
  const rt=await G.runtime();
  try {
    if(args[0]==='core-access') {await coreAccess(rt);await verify(rt);}
    else if(args[0]==='initial-ccv') await require('./initial-ccv.cjs').configureInitialCcv(rt,args[1]);
    else if(args[0]==='verify') await verify(rt);
    else if(args[0]==='dsm-pause') await pauseDsm(rt,Number(args[1]));
    else if(args[0]==='lockbox-plan') C.write(args[4],await lockboxPlan(rt,args[1],BigInt(args[2]),args[3]));
    else if(args[0]==='replace-hooks') C.write(args[3],await replaceHooks(rt,args[1],C.read(args[2])));
    else if(args[0]==='resume-plan') C.write(args[1],await G.build(rt,'agent','sepolia',[C.call(rt.l1.stETH,'resume()')],'Resume Lido'));
    else throw new Error('Usage: core-access|verify|initial-ccv CHAIN|lockbox-plan REMOTE WEI RECIPIENT OUTPUT|replace-hooks CHAIN ALLOWLIST_JSON OUTPUT|resume-plan OUTPUT');
  } finally {rt.close();}
}
if(require.main===module) main(process.argv.slice(2)).catch(e=>{console.error('Access operation failed: '+(e.code||e.message));process.exitCode=1;});
module.exports={coreAccess,verify,lockboxPlan,replaceHooks,pauseDsm,bypass,OZ,PROXIES,RETAINED,role};

#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const C = require('./context.cjs');
function parameters(source, p, accounts) {
  const d = C.toml.parse(source), t = p.timing;
  d.vesting.holders = {[accounts.dao_voter.address]: p.initialTldoSupply};
  d.vesting.unvestedTokensAmount = '0';
  Object.assign(d.dao.initialSettings.voting, {voteDuration:t.voting, objectionPhaseDuration:t.objection});
  const g = d.dualGovernance;
  g.resealCommittee = accounts.dg_reseal.address;
  Object.assign(g.timelock, {afterSubmitDelay:t.dgAfterSubmit, afterScheduleDelay:t.dgAfterSchedule});
  Object.assign(g.timelock.sanityCheckParams, {minExecutionDelay: t.dgAfterSubmit + t.dgAfterSchedule,
    maxAfterSubmitDelay:600, maxAfterScheduleDelay:600, maxEmergencyModeDuration:600});
  Object.assign(g.timelock.emergencyProtection, {emergencyModeDuration:300,
    emergencyGovernanceProposer:accounts.dg_emergency_proposer.address,
    emergencyActivationCommittee:accounts.dg_emergency_activation.address,
    emergencyExecutionCommittee:accounts.dg_emergency_execution.address});
  g.tiebreakerActivationTimeout=300; g.tiebreaker.executionDelay=300;
  Object.assign(g.sanityCheckParams, {maxMinAssetsLockDuration:600,
    minTiebreakerActivationTimeout:300, maxTiebreakerActivationTimeout:600});
  g.tiebreaker.committees = [1,2,3].map(i => ({quorum:1,members:[accounts['dg_tiebreaker_'+i].address]}));
  for (const key of Object.keys(g.configProvider)) {
    if (/Duration|Delay|Growth/.test(key)) g.configProvider[key] = 300;
  }
  // Retain the shorter intervals from the DG Hoodi/Holesky deployment defaults.
  g.configProvider.vetoSignallingMinActiveDuration=180;
  g.configProvider.vetoCooldownDuration=180;
  g.configProvider.rageQuitExtensionPeriodDuration=180;
  g.configProvider.vetoSignallingMaxDuration=600;
  g.configProvider.rageQuitEthWithdrawalsMaxDelay=600;
  d.circuitBreaker.minPauseDuration=300; d.circuitBreaker.maxPauseDuration=600;
  d.circuitBreaker.initialPauseDuration=300;
  d.nodeOperatorsRegistry.stuckPenaltyDelay=300; d.simpleDvt.stuckPenaltyDelay=300;
  d.lazyOracle.quarantinePeriod=300;
  d.hashConsensusForAccountingOracle.epochsPerFrame=1;
  d.hashConsensusForValidatorsExitBusOracle.epochsPerFrame=1;
  d.depositSecurityModule.pauseIntentValidityPeriodBlocks=50;
  d.topUpGateway.minBlockDistance=25;
  d.consolidationBus.initialExecutionDelay=0;
  return d;
}
function exportActors() {
  const m = C.actors(), env=C.environment();
  for(const [prefix,start] of [['oracle',11],['dsm_guardian',14]]) for(let i=0;i<3;i++) {
    const id=prefix+'_'+(i+1);
    if(m.actors.some(a=>a.id===id)) continue;
    const index=start+i;
    const wallet=C.ethers.HDNodeWallet.fromPhrase(env.ACTORS_MNEMONIC,'',`m/44'/60'/0'/0/${index}`);
    m.actors.push({id,index,title:id,address:wallet.address,networks:['sepolia'],
      keyVariable:id.toUpperCase()+'_PRIVATE_KEY',derivationPath:`m/44'/60'/0'/0/${index}`,
      keySource:'ACTORS_MNEMONIC',wiring:'core-access',roles:[prefix==='oracle' ? 'AO and VEBO HashConsensus member; quorum 2 of 3' : 'DSM guardian; quorum 2 of 3'],
      controlChecked:'offline-sign-and-recover'});
  }
  const ws=C.wallets(m,env);
  const file=path.join(C.ROOT,m.privateKeyFile);
  execFileSync('git',['check-ignore','-q','--',file],{cwd:C.ROOT});
  fs.mkdirSync(path.dirname(file),{recursive:true,mode:0o700});
  const lines=['# Local private actor keys. Do not commit or paste into logs.'];
  for(const a of m.actors) {
    const digest=C.ethers.id('Local key-control check, no transaction: '+a.id);
    if(C.ethers.recoverAddress(digest,ws[a.id].signingKey.sign(digest))!==ws[a.id].address) throw new Error('Signature check failed');
    lines.push(a.keyVariable.replace('_PRIVATE_KEY','_ADDRESS')+'='+a.address,a.keyVariable+'='+ws[a.id].privateKey);
  }
  fs.writeFileSync(file,lines.join('\n')+'\n',{mode:0o600}); fs.chmodSync(file,0o600);
  m.checks.distinctAddresses=m.actors.length;
  m.plannedDaoVoting.status='wired-by-controlled-testnet-profile';
  m.actors.find(a=>a.id==='dao_voter').wiring='controlled-testnet-profile';
  C.write(C.ACTORS,m);
  console.log('Prepared '+m.actors.length+' actor keys; secrets written only to the ignored 0600 file.');
}
function main(args) {
  if(args[0]==='actors') return exportActors();
  const p=C.profile();
  if(args[0]==='core-params') {
    const d=parameters(fs.readFileSync(args[1],'utf8'),p,C.wallets());
    // ethers patches BigInt.toJSON; @iarna/toml needs native bigint handling.
    const saved=BigInt.prototype.toJSON; delete BigInt.prototype.toJSON;
    try {fs.writeFileSync(args[2],C.toml.stringify(d));} finally {if(saved) BigInt.prototype.toJSON=saved;}
  } else if(args[0]==='ccip-config') {
    const d=C.read(args[1]);
    d.governance.min_delay_seconds=p.timing.ccip; d.governance.expiry_period_seconds=p.timing.proposalExpiry;
    C.write(args[2],d);
  } else if(args[0]==='check') {
    C.wallets(); console.log('Controlled Sepolia actors and timing profile validated.');
  } else throw new Error('Usage: prepare.cjs actors|check|core-params SOURCE OUTPUT|ccip-config SOURCE OUTPUT');
}
if(require.main===module) {
  try {main(process.argv.slice(2));} catch(e) {console.error('Testnet preparation failed ('+(e.code || e.name)+'); no credentials printed.');process.exitCode=1;}
}
module.exports={parameters};

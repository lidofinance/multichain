#!/usr/bin/env node
'use strict';
const fs=require('node:fs');
const path=require('node:path');
const C=require('./context.cjs');
const {ethers:E}=C;
const ZERO=E.ZeroAddress;
const VOTING=[
  'function newVote(bytes,string,bool,bool) returns(uint256)', 'function vote(uint256,bool,bool)',
  'function canExecute(uint256) view returns(bool)', 'function executeVote(uint256)',
  'function voteTime() view returns(uint64)',
  'function getVote(uint256) view returns(bool,bool,uint64,uint64,uint64,uint64,uint256,uint256,uint256,bytes,uint8)',
  'event StartVote(uint256 indexed voteId,address indexed creator,string metadata)'];
const DG=['function submitProposal((address target,uint96 value,bytes payload)[],string) returns(uint256)',
  'function canScheduleProposal(uint256) view returns(bool)', 'function scheduleProposal(uint256)',
  'event ProposalSubmitted(address indexed proposerAccount,uint256 indexed proposalId,string metadata)'];
const DGTL=['function canExecute(uint256) view returns(bool)', 'function execute(uint256)',
  'function getProposalDetails(uint256) view returns((uint256 id,address executor,uint40 submittedAt,uint40 scheduledAt,uint8 status))',
  'function getAfterSubmitDelay() view returns(uint32)', 'function getAfterScheduleDelay() view returns(uint32)'];
const OP=['function queue(address[],uint256[],string[],bytes[],bool[])', 'function execute(uint256)',
  'function getDelay() view returns(uint256)', 'function getCurrentState(uint256) view returns(uint8)',
  'event ActionsSetQueued(uint256 indexed id,address[] targets,uint256[] values,string[] signatures,bytes[] calldatas,bool[] withDelegatecalls,uint256 executionTime)'];
const MESSENGER=['function OTHER_MESSENGER() view returns(address)',
  'function sendMessage(address,bytes,uint32)', 'function relayMessage(uint256,address,address,uint256,uint256,bytes)',
  'function successfulMessages(bytes32) view returns(bool)', 'function failedMessages(bytes32) view returns(bool)',
  'event SentMessage(address indexed target,address sender,bytes message,uint256 messageNonce,uint256 gasLimit)'];
const TL=['function scheduleBatch((address target,uint256 value,bytes data)[],bytes32,bytes32,uint256)',
  'function executeBatch((address target,uint256 value,bytes data)[],bytes32,bytes32)',
  'function bypasserExecuteBatch((address target,uint256 value,bytes data)[])',
  'function hashOperationBatch((address target,uint256 value,bytes data)[],bytes32,bytes32) view returns(bytes32)',
  'function getMinDelay() view returns(uint256)', 'function getTimestamp(bytes32) view returns(uint256)',
  'function isOperationDone(bytes32) view returns(bool)', 'function isOperationReady(bytes32) view returns(bool)'];
function relayData(chain,e) {
  // Mantle's native MNT requires a second value field; both values are zero for governance.
  // https://github.com/mantlenetworkio/mantle-v2/blob/main/packages/contracts-bedrock/src/libraries/Encoding.sol
  const signature=chain==='mantle_sepolia' ? 'relayMessage(uint256,address,address,uint256,uint256,uint256,bytes)' :
    'relayMessage(uint256,address,address,uint256,uint256,bytes)';
  const args=[e.messageNonce,e.sender,e.target,0,...(chain==='mantle_sepolia'?[0]:[]),e.gasLimit,e.message];
  return new E.Interface(['function '+signature]).encodeFunctionData('relayMessage',args);
}
async function receiptFor(provider,hash,timeout=120000) {
  const deadline=Date.now()+timeout;
  while(Date.now()<deadline) {
    const receipt=await provider.getTransactionReceipt(hash);
    if(receipt) return receipt;
    await new Promise(resolve=>setTimeout(resolve,250));
  }
  throw new Error('Receipt remains pending: '+hash);
}
const digest=o=>E.keccak256(E.toUtf8Bytes(JSON.stringify(o)));
const equal=(a,b)=>String(a).toLowerCase()===String(b).toLowerCase();
function events(receipt, contract, name) {
  return receipt.logs.filter(l=>equal(l.address,contract.target)).flatMap(l=>{
    try {const x=contract.interface.parseLog(l);return x?.name===name?[x]:[];} catch{return [];}
  });
}
async function runtime() {
  const p=C.profile(), actors=C.actors(), wallets=C.wallets(actors), env=C.environment();
  const run=fs.realpathSync(path.join(C.OPS,'.active-run'));
  const meta=C.read(path.join(run,'run.json'));
  if(meta.target!=='wsteth-ccip-sepolia-mantle-dev' || !['fork','testnet'].includes(meta.environment)) throw new Error('Wrong run');
  const records={}, providers={}, forks={};
  const def=C.read(path.join(run,'inputs/target/target.json'));
  for(const n of [def.networks.l1,...def.networks.l2s.filter(x=>meta.l2Chains.includes(x.slug))]) {
    const url=env['RPC_'+n.slug.toUpperCase()]; if(!url) throw new Error('Missing RPC for '+n.slug);
    const provider=new E.JsonRpcProvider(url,undefined,{cacheTimeout:-1,batchMaxCount:1});
    provider.pollingInterval=250;
    if(Number((await provider.getNetwork()).chainId)!==n.chainId || !p.chainIds.includes(n.chainId)) throw new Error('Wrong chain '+n.slug);
    const local=['127.0.0.1','localhost','[::1]'].includes(new URL(url).hostname);
    const anvil=(await provider.send('web3_clientVersion',[])).toLowerCase().includes('anvil');
    if(meta.environment==='fork' && !(local&&anvil)) throw new Error('Fork operations require owned loopback Anvil endpoints');
    if(meta.environment==='testnet' && anvil) throw new Error('Public run points at a fork');
    providers[n.slug]=provider; forks[n.slug]=local&&anvil;
    records[n.slug]=C.read(path.join(run,'config/chains',n.slug+'.json'));
  }
  const core=C.read(path.join(run,'state/l1.deployed.json'));
  const l1=C.read(path.join(run,'state/l1.json'));
  const rt={p,actors,wallets,run,meta,records,providers,forks,core,l1};
  rt.contract=(chain,addr,abi)=>new E.Contract(addr,abi,providers[chain]);
  rt.read=async(chain,addr,sig,args=[])=>{
    try {return await rt.contract(chain,addr,['function '+sig])[sig.split('(')[0]](...args);}
    catch(e) {throw new Error(chain+' read '+sig.split('(')[0]+' at '+addr+': '+(e.code||'RPC failure')+' '+(typeof e.data==='string'?e.data:''));}
  };
  rt.send=async(chain,actor,c,onBroadcast,onAttempt)=>{
    const provider=providers[chain], wallet=wallets[actor]?.connect(provider);
    if(!wallet) throw new Error('Unknown actor '+actor);
    if(forks[chain]) await provider.send('anvil_setBalance',[wallet.address,E.toBeHex(E.parseEther('10000'))]);
    const tx={to:c.to,data:c.data,value:BigInt(c.value||0),from:wallet.address};
    let gas;
    try {gas=await provider.estimateGas(tx);}
    catch(e) {throw new Error(chain+' estimate '+c.to+' '+c.data.slice(0,10)+': '+(e.code||'RPC failure')+' '+(typeof e.data==='string'?e.data:''));}
    const nonce=await provider.getTransactionCount(wallet.address,'pending');
    if(onAttempt) onAttempt(nonce);
    const sent=await wallet.sendTransaction({...tx,gasLimit:gas*130n/100n,nonce});
    if(onBroadcast) onBroadcast(sent.hash);
    const receipt=await sent.wait();
    if(receipt.status!==1) throw new Error('Transaction reverted: '+sent.hash);
    return receipt;
  };
  rt.waitUntil=async(chain,timestamp)=>{
    const provider=providers[chain], now=(await provider.getBlock('latest')).timestamp;
    if(now>=Number(timestamp)) return true;
    if(!forks[chain]) return false;
    await provider.send('evm_setNextBlockTimestamp',[Number(timestamp)]); await provider.send('evm_mine',[]); return true;
  };
  rt.close=()=>Object.values(providers).forEach(p=>p.destroy());
  return rt;
}
async function build(rt,route,chain,calls,description) {
  if(!['agent','voting','admin-executor','l2','ccip'].includes(route) || !rt.providers[chain]) throw new Error('Invalid governance route');
  if((['agent','voting','admin-executor'].includes(route) && chain!=='sepolia') || (route==='l2'&&chain==='sepolia')) throw new Error('Route/chain mismatch');
  if(!calls.length) throw new Error('Empty action list');
  const plan={schemaVersion:1,runId:rt.meta.id,route,chain,calls,description};
  if(route==='ccip') {
    const d=rt.records[chain].deployed;
    plan.timelock=d.timelock; plan.callProxy=d.call_proxy;
    plan.salt=E.hexlify(E.randomBytes(32)); plan.predecessor=E.ZeroHash;
  } else {
    let l1calls=calls;
    if(route==='l2') {
      const state=C.read(path.join(rt.run,'state',chain+'.json'));
      const messenger=await rt.read(chain,state.opExec,'OVM_L2_CROSS_DOMAIN_MESSENGER() view returns(address)');
      const l1messenger=await rt.read(chain,messenger,MESSENGER[0].slice(9));
      if(await rt.providers.sepolia.getCode(l1messenger)==='0x') throw new Error('L1 messenger has no code');
      if(!equal(await rt.read(chain,state.opExec,'getEthereumGovernanceExecutor() view returns(address)'),rt.l1.agent)) throw new Error('Executor does not trust current Agent');
      const queue=new E.Interface(OP).encodeFunctionData('queue',[calls.map(c=>c.to),calls.map(c=>c.value||0),calls.map(()=>''),calls.map(c=>c.data),calls.map(()=>false)]);
      plan.relay={l1Messenger:l1messenger,l2Messenger:messenger,executor:state.opExec,queue,
        fromBlock:await rt.providers[chain].getBlockNumber()};
      l1calls=[C.call(l1messenger,'sendMessage(address,bytes,uint32)',[state.opExec,queue,5000000])];
    }
    const externalCalls=route==='admin-executor' ? calls.map(c=>[c.to,c.value||0,c.data]) :
      [[rt.l1.agent,0,new E.Interface(['function forward(bytes)']).encodeFunctionData('forward',[C.callsScript(l1calls)])]];
    const voteCalls=route==='voting' ? calls : [C.call(rt.l1.dg.dualGovernance,DG[0].slice(9),[externalCalls,description])];
    plan.voteScript=C.callsScript(voteCalls);
  }
  return plan;
}
async function advance(rt,plan,file) {
  if(plan.runId!==rt.meta.id) throw new Error('Plan belongs to a different run');
  const hash=digest(plan), state=fs.existsSync(file)?C.read(file):{planHash:hash,phase:'new',receipts:[]};
  if(state.planHash!==hash) throw new Error('Plan changed after submission');
  const save=()=>C.write(file,state);
  const send=async(chain,actor,c)=>{
    // Reuse a confirmed transaction after interruption between receipt and phase updates.
    // If interruption occurred before its hash was journalled, stop for reconciliation.
    const key=state.phase+':'+digest({chain,actor,c});
    state.transactions ||= {};
    let r;
    if(state.transactions[key]) {
      const hash=state.transactions[key].hash;
      if(!hash) throw new Error('Interrupted broadcast; reconcile transaction nonce before retry: '+key);
      r=await rt.providers[chain].getTransactionReceipt(hash);
      if(!r) r=await receiptFor(rt.providers[chain],hash);
      if(!r || r.status!==1) throw new Error('Transaction pending or reverted: '+hash);
    } else {
      r=await rt.send(chain,actor,c,hash=>{state.transactions[key].hash=hash;save();},
        nonce=>{state.transactions[key]={chain,actor,nonce};save();});
    }
    if(!state.receipts.some(x=>x.hash===r.hash)) state.receipts.push({chain,hash:r.hash,from:r.from,to:r.to,block:r.blockNumber});
    save();return r;
  };
  if(state.phase==='done') return state;
  if(plan.route==='ccip') {
    const tl=rt.contract(plan.chain,plan.timelock,TL), calls=plan.calls.map(c=>[c.to,c.value||0,c.data]);
    if(state.phase==='new') {
      state.id=await tl.hashOperationBatch(calls,plan.predecessor,plan.salt);
      const delay=await tl.getMinDelay();
      await send(plan.chain,'ccip_proposer',C.call(plan.timelock,TL[0].slice(9),[calls,plan.predecessor,plan.salt,delay]));
      state.phase='scheduled';save();
    }
    if(await tl.isOperationDone(state.id)) {state.phase='done';save();return state;}
    const ready=await tl.getTimestamp(state.id);
    if(ready===0n) throw new Error('Proposal invalidated, expired or cancelled; build a new plan');
    if(!await rt.waitUntil(plan.chain,ready)) return state;
    if(!await tl.isOperationReady(state.id)) throw new Error('Proposal is not executable');
    await send(plan.chain,'deployer',C.call(plan.callProxy,TL[1].slice(9),[calls,plan.predecessor,plan.salt]));
    state.phase='done';save();return state;
  }
  const voting=rt.contract('sepolia',rt.l1.voting,VOTING);
  const dg=rt.contract('sepolia',rt.l1.dg.dualGovernance,DG);
  const tl=rt.contract('sepolia',rt.l1.dg.timelock,DGTL);
  if(state.phase==='new') {
    const newVote=C.call(rt.l1.voting,VOTING[0].slice(9),[plan.voteScript,plan.description,false,false]);
    const receipt=await send('sepolia','dao_voter',C.call(C.address(rt.core,'app:aragon-token-manager'),'forward(bytes)',[C.callsScript([newVote])]));
    const starts=events(receipt,voting,'StartVote'); if(starts.length!==1) throw new Error('Expected one new vote');
    state.voteId=starts[0].args.voteId.toString();state.phase='vote-created';save();
  }
  if(state.phase==='vote-created') {
    await send('sepolia','dao_voter',C.call(rt.l1.voting,VOTING[1].slice(9),[state.voteId,true,false]));
    state.phase='voting';save();
  }
  if(state.phase==='voting') {
    const v=await voting.getVote(state.voteId);
    if(!await rt.waitUntil('sepolia',v[2]+await voting.voteTime()+1n)) return state;
    if(!v[1] && !await voting.canExecute(state.voteId)) throw new Error('Vote cannot execute (quorum or rejection)');
    const receipt=await send('sepolia','deployer',C.call(rt.l1.voting,VOTING[3].slice(9),[state.voteId]));
    if(plan.route==='voting') {state.phase='done';save();return state;}
    const submissions=events(receipt,dg,'ProposalSubmitted');
    if(submissions.length!==1) throw new Error('Expected one DG proposal');
    state.proposalId=submissions[0].args.proposalId.toString();state.phase='dg-submitted';save();
  }
  if(state.phase==='dg-submitted') {
    const d=await tl.getProposalDetails(state.proposalId);
    if(!await rt.waitUntil('sepolia',d.submittedAt+await tl.getAfterSubmitDelay()+1n)) return state;
    if(d.status!==2n && !await dg.canScheduleProposal(state.proposalId)) throw new Error('DG scheduling blocked; inspect veto/emergency state');
    await send('sepolia','deployer',C.call(dg.target,'scheduleProposal(uint256)',[state.proposalId]));
    state.phase='dg-scheduled';save();
  }
  if(state.phase==='dg-scheduled') {
    const d=await tl.getProposalDetails(state.proposalId);
    if(!await rt.waitUntil('sepolia',d.scheduledAt+await tl.getAfterScheduleDelay()+1n)) return state;
    if(d.status!==3n && !await tl.canExecute(state.proposalId)) throw new Error('DG execution blocked; inspect emergency state');
    const receipt=await send('sepolia','deployer',C.call(tl.target,'execute(uint256)',[state.proposalId]));
    if(plan.route!=='l2') {state.phase='done';save();return state;}
    const messenger=rt.contract('sepolia',plan.relay.l1Messenger,MESSENGER);
    const matches=events(receipt,messenger,'SentMessage').filter(e=>equal(e.args.target,plan.relay.executor)&&equal(e.args.sender,rt.l1.agent)&&e.args.message===plan.relay.queue);
    if(matches.length!==1) throw new Error('Expected exact Agent governance message');
    const e=matches[0].args;
    state.relayData=relayData(plan.chain,e);
    state.messageHash=E.keccak256(state.relayData);state.phase='relay-pending';save();
  }
  if(state.phase==='relay-pending') {
    const messenger=rt.contract(plan.chain,plan.relay.l2Messenger,MESSENGER);
    if(!await messenger.successfulMessages(state.messageHash)) {
      if(!rt.forks[plan.chain]) return state; // Public relaying is performed by the network, never impersonated.
      const alias=E.getAddress(E.toBeHex((BigInt(plan.relay.l1Messenger)+0x1111000000000000000000000000000000001111n)%(1n<<160n),20));
      const provider=rt.providers[plan.chain];
      await provider.send('anvil_setBalance',[alias,E.toBeHex(E.parseEther('10'))]);
      await provider.send('anvil_impersonateAccount',[alias]);
      try {
        const tx=await provider.send('eth_sendTransaction',[{from:alias,to:plan.relay.l2Messenger,data:state.relayData,gas:E.toBeHex(10000000)}]);
        const receipt=await receiptFor(provider,tx);
        if(receipt.status!==1) throw new Error('Canonical messenger relay reverted');
        state.receipts.push({chain:plan.chain,hash:tx,from:alias,transportSimulation:true});save();
      } finally {await provider.send('anvil_stopImpersonatingAccount',[alias]);}
      if(!await messenger.successfulMessages(state.messageHash)) throw new Error('Messenger did not deliver governance message');
    }
    const op=rt.contract(plan.chain,plan.relay.executor,OP);
    const logs=await op.queryFilter(op.filters.ActionsSetQueued(),plan.relay.fromBlock,'latest');
    const matches=logs.filter(e=>new E.Interface(OP).encodeFunctionData('queue',[
      [...e.args[1]],[...e.args[2]],[...e.args[3]],[...e.args[4]],[...e.args[5]]])===plan.relay.queue);
    if(matches.length!==1) throw new Error('Expected one matching L2 action set');
    state.actionId=matches[0].args.id.toString();state.readyAt=matches[0].args.executionTime.toString();
    state.phase='l2-queued';save();
  }
  if(state.phase==='l2-queued') {
    // BridgeExecutorBase accepts execution at executionTime, including zero-delay queues.
    if(!await rt.waitUntil(plan.chain,BigInt(state.readyAt))) return state;
    await send(plan.chain,'deployer',C.call(plan.relay.executor,'execute(uint256)',[state.actionId]));
    state.phase='done';save();
  }
  return state;
}
async function execute(rt,plan,name) {
  if(!/^[a-zA-Z0-9._-]+$/.test(name)) throw new Error('Use a simple operation name');
  const dir=rt.journalRoot || path.join(rt.run,'state/governance');
  const planFile=path.join(dir,name+'.plan.json'), stateFile=path.join(dir,name+'.state.json');
  if(fs.existsSync(planFile)) {
    const saved=C.read(planFile);
    // Stable calls and route on retry; preserve the recorded salt and relay start block.
    for(const k of ['route','chain','calls','description','runId']) if(digest(saved[k])!==digest(plan[k])) throw new Error('Operation name already binds different calls: '+name);
    plan=saved;
  } else C.write(planFile,plan);
  const deadline=Date.now()+30*60*1000;
  while(true) {
    const state=await advance(rt,plan,stateFile);
    if(state.phase==='done') return state;
    if(Date.now()>deadline) throw new Error('Operation remains pending; use governance advance '+planFile);
    await new Promise(resolve=>setTimeout(resolve,3000));
  }
}
async function main(args) {
  const rt=await runtime();
  try {
    if(args[0]==='build') {
      const [_,route,chain,input,output]=args;
      C.write(output,await build(rt,route,chain,C.read(input),'Operator configuration'));
      console.log('Prepared '+output+'; no transaction sent.');
    } else if(['submit','advance'].includes(args[0])) {
      const file=args[1]; const result=await advance(rt,C.read(file),file+'.state.json');
      console.log(JSON.stringify(result));
    } else if(args[0]==='status') {
      console.log(JSON.stringify(C.read(args[1]+'.state.json'),null,2));
    } else throw new Error('Usage: governance build ROUTE CHAIN CALLS_JSON PLAN_JSON | submit/advance/status PLAN_JSON');
  } finally {rt.close();}
}
if(require.main===module) main(process.argv.slice(2)).catch(e=>{
  console.error('Governance failed: '+(e.code||e.message));process.exitCode=1;
});
module.exports={runtime,build,advance,execute,events,equal,relayData,TL,VOTING,DG,OP,MESSENGER};

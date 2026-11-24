#!/usr/bin/env node
'use strict';
// Move the deployed lanes from the run's current CCV policy to a desired one through the DAO:
// Voting -> Dual Governance -> Agent -> LidoTimelock bypass on Sepolia, and the same call on every L2
// through the canonical messenger and its governance executor. The desired policy is an explicit,
// reviewed file; nothing here learns the expected state from the chain it verifies.
//
// On owned forks the script signs with the same actor keys, warps time across the governance delays
// and simulates only canonical message delivery. On the public testnet it waits for both.
const fs=require('node:fs');
const path=require('node:path');
const {execFileSync}=require('node:child_process');
const C=require('./context.cjs'), G=require('./governance.cjs');
const {load}=require('../ccv-policy.cjs');
const {ethers:E}=C;

const USAGE=`Usage: ccv-switch <plan|precheck|run|verify> [options]
  plan       Print the governance caller, target and arguments for each policy change.
  precheck   Compare the chains with both policies, check provider dispatch and quote fees.
             If an update is pending, simulate each planned call from its required caller.
  run        Submit the vote, wait for governance and L2 delivery, execute and verify the update.
             Repeat with the same --name to resume an interrupted run.
  verify     Check the desired policy, quote each lane and compare invariants when a baseline exists.
Options:
  --name ID          Operation journal under <run>/state/ccv-switch (default: ccv-switch).
  --before FILE      Starting policy for a new journal (default: <run>/config/ccv-policy.json).
  --after FILE       Desired policy for a new journal (default: <run>/inputs/target/config/ccv-policy.nethermind.json).
  --votes one|per-chain
                     Submit one vote for all affected chains (default) or a separate vote for each.
                     A resumed run uses the journal's vote mode.
  --probe-send       Forks only: after the switch, send a small transfer out of every chain to prove
                     the source side accepts the new verifiers. L2 probe tokens are minted on the fork.
  --revert           Forks only: restore all forks to their state before the command.`;
const HOOKS_UPDATE='applyCCVConfigUpdates((uint64,address[],address[],address[],address[])[])';
const CONFIGS='getAllCCVConfigs() view returns((uint64,address[],address[],address[],address[])[])';
const INBOUND='getAllInboundImplementations() view returns((bytes4,address)[])';
const OUTBOUND='getAllOutboundImplementations() view returns((uint64,address)[])';
const MESSAGE='(bytes receiver,bytes data,(address token,uint256 amount)[] tokenAmounts,address feeToken,bytes extraArgs)';
const ROUTER=[`function getFee(uint64,${MESSAGE}) view returns(uint256)`,`function ccipSend(uint64,${MESSAGE}) payable returns(bytes32)`];
// The planner's first three phases only add or switch; retiring an inbound version can strand
// messages in flight and is a separate, deliberate operation.
const PHASES=['1-prepare-inbound','2-switch-outbound','3-set-required-ccvs'];
const PROBE_AMOUNT=10n**15n;

const fail=reason=>{throw new Error(reason);};
// The node's own words for a failed call, without provider objects or endpoints.
const reason=e=>[e.code||'RPC failure',typeof e.data==='string'?e.data:'',
  String(e.error?.message||e.info?.error?.message||'').replace(/https?:\/\/\S+/g,'[url]').slice(0,160)].filter(Boolean).join(' ');
const check=(ok,reason)=>{if(!ok) fail(reason);};
// Order-insensitive comparison of on-chain tables: the outer row order follows swap-and-pop removals.
const canonical=rows=>JSON.stringify(rows.map(row=>Array.from(row,v=>Array.isArray(v)||(v&&typeof v==='object'&&typeof v!=='bigint')
  ?Array.from(v,x=>String(x).toLowerCase()):String(v).toLowerCase())).sort((a,b)=>a[0].localeCompare(b[0])));
const plain=v=>JSON.parse(JSON.stringify(v,(_,x)=>typeof x==='bigint'?x.toString():x));

function parse(argv) {
  const [command,...rest]=argv, o={command,name:'ccv-switch',votes:null,probeSend:false,revert:false,before:null,after:null};
  check(['plan','precheck','run','verify'].includes(command),USAGE);
  while(rest.length) {
    const flag=rest.shift();
    if(flag==='--probe-send') o.probeSend=true;
    else if(flag==='--revert') o.revert=true;
    else if(['--before','--after','--name','--votes'].includes(flag)) {
      check(rest.length,'Missing value for '+flag); o[flag.slice(2)]=rest.shift();
    } else fail(USAGE);
  }
  check(/^[a-zA-Z0-9._-]+$/.test(o.name),'Use a simple operation name');
  check(o.votes===null||['one','per-chain'].includes(o.votes),'--votes takes one or per-chain');
  return o;
}

// The journal keeps the exact inputs of this operation: later commands with the same name must
// not silently run against a different policy.
function inputs(rt,o) {
  const dir=path.join(rt.run,'state/ccv-switch',o.name);
  const files={dir,before:path.join(dir,'before.json'),after:path.join(dir,'after.json'),plan:path.join(dir,'plan.json'),
    invariants:path.join(dir,'invariants.json'),report:path.join(dir,'report.json')};
  for(const [saved,override,fallback] of [
    [files.before,o.before,'config/ccv-policy.json'],
    [files.after,o.after,'inputs/target/config/ccv-policy.nethermind.json']
  ]) {
    if(!override && fs.existsSync(saved)) continue;
    const source=path.resolve(override||path.join(rt.run,fallback));
    check(fs.existsSync(source),'Missing policy: '+source);
    if(fs.existsSync(saved)) check(fs.readFileSync(saved,'utf8')===fs.readFileSync(source,'utf8'),
      'Operation '+o.name+' already binds a different policy; use a new --name');
    else {fs.mkdirSync(dir,{recursive:true});fs.copyFileSync(source,saved);}
  }
  return files;
}

// Older runs recorded the route in each governance plan before submitting its vote.
function bindVoteMode(dir,requested) {
  const file=path.join(dir,'vote-mode.json');
  if(!fs.existsSync(file)) {
    const routes=new Set(fs.readdirSync(dir).filter(f=>f.endsWith('.plan.json'))
      .map(f=>C.read(path.join(dir,f)).route));
    const omnibus=routes.delete('omnibus');
    check([...routes].every(route=>['agent','l2'].includes(route)) && !(omnibus&&routes.size),
      'Conflicting governance routes in the operation journal');
    const legacy=omnibus?'one':routes.size?'per-chain':null;
    const mode=legacy||requested||'one';
    try {fs.writeFileSync(file,JSON.stringify(mode),{flag:'wx'});}
    catch(error) {if(error.code!=='EEXIST') throw error;}
  }
  const mode=C.read(file);
  check(['one','per-chain'].includes(mode),'Invalid vote mode in operation journal');
  check(!requested||requested===mode,'Operation already binds --votes '+mode);
  return mode;
}

function plan(rt,files) {
  const records=path.join(rt.run,'config/chains');
  execFileSync(process.execPath,[path.join(C.OPS,'script/plan-ccv-update.cjs'),records,files.before,files.after,files.plan],{stdio:'ignore'});
  const planned=C.read(files.plan);
  check(planned.actions.length,'The two policies resolve to the same on-chain state: nothing to do');
  for(const a of planned.actions) {
    check(PHASES.includes(a.phase),'Phase '+a.phase+' is outside this operation; retire an inbound version separately, after messages drain');
    check(rt.providers[a.chain],'Planned chain is not part of this run: '+a.chain);
    const cfg=rt.records[a.chain];
    // The caller of the timelock bypass is fixed by the route: Agent on Sepolia, the governance executor on an L2.
    const caller=a.chain==='sepolia'?rt.l1.agent:C.read(path.join(rt.run,'state',a.chain+'.json')).opExec;
    check(G.equal(a.requiredCaller,caller) && G.equal(a.to,cfg.deployed.timelock),'Planned caller or timelock disagrees with the governance route: '+a.chain);
    check([cfg.deployed.advanced_pool_hooks,cfg.ccv.verifier_resolver].some(t=>G.equal(t,a.target)),'Planned target is not this deployment\'s hooks or resolver: '+a.chain);
  }
  return {planned,before:load(records,files.before).resolved,after:load(records,files.after).resolved};
}

function describe(rt,planned) {
  const chains=[...new Set(planned.actions.map(a=>a.chain))];
  for(const chain of chains) {
    console.log(`\n${chain} (chain id ${rt.records[chain].chain.chain_id})`);
    for(const a of planned.actions.filter(x=>x.chain===chain)) {
      console.log(`  caller   ${a.requiredCaller}`);
      console.log(`  call     LidoTimelock ${a.to} .bypasserExecuteBatch([(target, 0, data)])`);
      console.log(`  target   ${a.target} .${a.signature.split('(')[0]}`);
      for(const row of a.arguments) {
        if(a.signature===HOOKS_UPDATE) {
          const remote=Object.keys(rt.records).find(c=>String(rt.records[c].ccip.chain_selector)===String(row[0]));
          console.log(`    lane ${row[0]} (${remote||'unknown'})`);
          console.log(`      outboundCCVs          [${row[1].join(', ')}]`);
          console.log(`      thresholdOutboundCCVs [${row[2].join(', ')}]`);
          console.log(`      inboundCCVs           [${row[3].join(', ')}]`);
          console.log(`      thresholdInboundCCVs  [${row[4].join(', ')}]`);
        } else console.log(`    (${row.join(', ')})`);
      }
    }
  }
}

// Everything a CCV change must leave alone. Recorded before the vote and compared after it.
async function invariants(rt) {
  const out={};
  for(const [chain,cfg] of Object.entries(rt.records)) {
    const d=cfg.deployed, token=d.token||cfg.addresses.token, hooks=d.advanced_pool_hooks;
    const registry=await rt.read(chain,cfg.ccip.token_admin_registry,'getTokenConfig(address) view returns((address,address,address))',[token]);
    out[chain]=plain({
      hooksOwner:await rt.read(chain,hooks,'owner() view returns(address)'),
      resolverOwner:await rt.read(chain,cfg.ccv.verifier_resolver,'owner() view returns(address)'),
      poolHooks:await rt.read(chain,d.token_pool,'getAdvancedPoolHooks() view returns(address)'),
      poolToken:await rt.read(chain,d.token_pool,'getToken() view returns(address)'),
      registryPool:registry[2],
      hooksPaused:await rt.read(chain,hooks,'paused() view returns(bool)'),
      disabledLanes:[...await rt.read(chain,hooks,'getDisabledRemoteLanes() view returns((uint64,uint8)[])')].map(r=>[...r]),
      thresholdAmount:await rt.read(chain,hooks,'getThresholdAmount() view returns(uint256)')});
  }
  return out;
}

// Does every chain hold exactly this resolved policy? Returns the mismatches instead of throwing,
// so callers can tell "still the old policy" from "already the new one" from "neither".
async function compare(rt,resolved) {
  const mismatches=[];
  for(const [chain,spec] of Object.entries(resolved)) {
    const cfg=rt.records[chain], local=cfg.ccv.verifier_resolver;
    const table=async(address,signature,expected,label)=>{
      if(canonical(await rt.read(chain,address,signature))!==canonical(expected)) mismatches.push(chain+': '+label);
    };
    await table(cfg.deployed.advanced_pool_hooks,CONFIGS,spec.lanes,'required CCVs in hooks');
    await table(local,INBOUND,spec.inbound,'inbound implementations of our resolver');
    await table(local,OUTBOUND,spec.outbound,'outbound implementations of our resolver');
    for(const provider of spec.external) {
      for(const address of new Set([provider.address,...provider.outbound.map(x=>x[1]),...provider.inbound.map(x=>x[1])]))
        if(await rt.providers[chain].getCode(address)==='0x') mismatches.push(chain+': no code at provider contract '+address);
      for(const [selector,implementation] of provider.outbound) {
        const actual=await rt.read(chain,provider.address,'getOutboundImplementation(uint64,bytes) view returns(address)',[selector,'0x']).catch(()=>E.ZeroAddress);
        if(!G.equal(actual,implementation)) mismatches.push(`${chain}: resolver ${provider.address} sends lane ${selector} to ${actual}, expected ${implementation}`);
      }
      for(const [tag,implementation] of provider.inbound) {
        const actual=await rt.read(chain,provider.address,'getInboundImplementation(bytes) view returns(address)',[tag]).catch(()=>E.ZeroAddress);
        if(!G.equal(actual,implementation)) mismatches.push(`${chain}: resolver ${provider.address} maps version ${tag} to ${actual}, expected ${implementation}`);
      }
    }
  }
  return mismatches;
}

// The router quotes a 0.001 wstETH transfer on each lane. A quote walks the source
// side's required verifiers, so a verifier that rejects the lane or the token fails here.
async function quotes(rt) {
  const out={};
  for(const [chain,cfg] of Object.entries(rt.records)) {
    const token=cfg.deployed.token||cfg.addresses.token, router=rt.contract(chain,cfg.ccip.router,ROUTER);
    for(const lane of cfg.remote_lanes) {
      const selector=rt.records[lane.remote_chain_name].ccip.chain_selector;
      const message=probeMessage(token,rt.wallets.deployer.address);
      try {out[chain+'->'+lane.remote_chain_name]=(await router.getFee(selector,message)).toString();}
      catch(e) {fail(`Fee quote reverted on ${chain} -> ${lane.remote_chain_name}: ${reason(e)}`);}
    }
  }
  return out;
}
const probeMessage=(token,receiver)=>[E.AbiCoder.defaultAbiCoder().encode(['address'],[receiver]),'0x',[[token,PROBE_AMOUNT]],E.ZeroAddress,'0x'];

async function simulate(rt,planned) {
  for(const a of planned.actions) {
    // The callers are contracts with no ETH. An OP-stack Anvil fork charges eth_call for gas,
    // so on forks the call carries a balance override; public nodes simulate without one.
    const tx={from:a.requiredCaller,to:a.to,data:a.data};
    try {
      if(rt.forks[a.chain]) await rt.providers[a.chain].send('eth_call',[tx,'latest',{[a.requiredCaller]:{balance:E.toBeHex(E.parseEther('1'))}}]);
      else await rt.providers[a.chain].call(tx);
    } catch(e) {fail(`Governance call would revert on ${a.chain}: ${reason(e)}`);}
  }
}

// Which policy each chain holds. Between the Sepolia execution and the last L2 execution the
// chains legitimately disagree, so the answer is per chain, never one verdict for the deployment.
async function position(rt,p) {
  const prefixed=(list,chain)=>list.filter(m=>m.startsWith(chain+': '));
  const stale=await compare(rt,p.before), pending=await compare(rt,p.after), out={};
  for(const chain of Object.keys(p.after))
    out[chain]=!prefixed(stale,chain).length?'current':!prefixed(pending,chain).length?'desired':'neither';
  return {chains:out,stale,pending};
}
async function precheck(rt,files,p) {
  const {chains,stale,pending}=await position(rt,p), held=Object.values(chains);
  const lost=Object.keys(chains).filter(c=>chains[c]==='neither');
  check(!lost.length,'Chains match neither the current nor the desired policy:\n  '+
    [...stale,...pending].filter(m=>lost.some(c=>m.startsWith(c+': '))).join('\n  '));
  if(!pending.length) return {applied:true,chains};
  // A mix is expected only while this operation's own governance is under way.
  const resuming=fs.readdirSync(files.dir).some(f=>f.endsWith('.state.json'));
  check(held.every(h=>h==='current')||resuming,'Some chains already hold the desired policy and this operation has no journal: '+JSON.stringify(chains));
  // Provider contracts for the desired policy must already exist and dispatch as declared;
  // only the hooks/our-resolver rows are expected to differ before the vote.
  const provider=pending.filter(m=>/provider contract|resolver 0x/.test(m));
  check(!provider.length,'Provider contracts do not match the desired policy:\n  '+provider.join('\n  '));
  await simulate(rt,p.planned);
  return {applied:false,chains};
}

async function vote(rt,o,p) {
  const callsByChain={};
  for(const a of p.planned.actions) (callsByChain[a.chain]||(callsByChain[a.chain]=[])).push({to:a.to,value:a.value,data:a.data});
  const description='Replace required CCVs: '+o.name;
  if(o.votes==='one') return {[o.name]:await G.execute(rt,await G.build(rt,'omnibus','sepolia',callsByChain,description),o.name)};
  const states={};
  for(const [chain,calls] of Object.entries(callsByChain)) {
    const name=o.name+'-'+chain;
    states[name]=await G.execute(rt,await G.build(rt,chain==='sepolia'?'agent':'l2',chain,calls,description+' ('+chain+')'),name);
  }
  return states;
}

async function verify(rt,files,p) {
  const mismatches=await compare(rt,p.after);
  check(!mismatches.length,'Chains do not match the desired policy:\n  '+mismatches.join('\n  '));
  let unchanged=null;
  if(fs.existsSync(files.invariants)) {
    const before=C.read(files.invariants), now=await invariants(rt);
    const changed=Object.keys(before).flatMap(chain=>Object.keys(before[chain])
      .filter(k=>JSON.stringify(before[chain][k])!==JSON.stringify(now[chain][k])).map(k=>chain+'.'+k));
    check(!changed.length,'Unrelated state changed during the operation: '+changed.join(', '));
    unchanged=Object.keys(before.sepolia||Object.values(before)[0]);
  }
  return {unchanged,fees:await quotes(rt)};
}

// Fork-only: a real ccipSend out of every chain. The OnRamp forwards the message to each required
// verifier, so this exercises what a quote cannot: the verifier's caller and lane checks.
async function probeSend(rt) {
  const sent={};
  for(const [chain,cfg] of Object.entries(rt.records)) {
    const token=cfg.deployed.token||cfg.addresses.token, provider=rt.providers[chain], deployer=rt.wallets.deployer.address;
    const lanes=cfg.remote_lanes, need=PROBE_AMOUNT*BigInt(lanes.length);
    await provider.send('anvil_setBalance',[deployer,E.toBeHex(E.parseEther('10000'))]);
    if(await rt.read(chain,token,'balanceOf(address) view returns(uint256)',[deployer])<need) {
      if(chain==='sepolia') await rt.send(chain,'deployer',{to:token,data:'0x',value:E.parseEther('0.01').toString()});
      else {
        // The L2 token has no public entry point: mint as the pool, on the fork only.
        const pool=cfg.deployed.token_pool;
        await provider.send('anvil_setBalance',[pool,E.toBeHex(E.parseEther('1'))]);
        await provider.send('anvil_impersonateAccount',[pool]);
        try {
          const hash=await provider.send('eth_sendTransaction',[{from:pool,to:token,data:C.call(token,'mint(address,uint256)',[deployer,need]).data}]);
          for(let i=0;i<400 && !await provider.getTransactionReceipt(hash);i++) await new Promise(r=>setTimeout(r,50));
          check((await provider.getTransactionReceipt(hash))?.status===1,'Fork probe mint failed on '+chain);
        } finally {await provider.send('anvil_stopImpersonatingAccount',[pool]);}
      }
    }
    await rt.send(chain,'deployer',C.call(token,'approve(address,uint256)',[cfg.ccip.router,need]));
    for(const lane of lanes) {
      const selector=rt.records[lane.remote_chain_name].ccip.chain_selector, message=probeMessage(token,deployer);
      const fee=await rt.contract(chain,cfg.ccip.router,ROUTER).getFee(selector,message);
      const receipt=await rt.send(chain,'deployer',{...C.call(cfg.ccip.router,ROUTER[1].slice(9).split(' payable')[0],[selector,message]),value:fee.toString()});
      sent[chain+'->'+lane.remote_chain_name]={transaction:receipt.hash,fee:fee.toString()};
    }
  }
  return sent;
}

async function restoreForks(providers,snapshots) {
  const restored={};
  for(const [chain,id] of Object.entries(snapshots)) {
    try {restored[chain]=await providers[chain].send('evm_revert',[id])===true;}
    catch {restored[chain]=false;}
  }
  return restored;
}

async function main(argv) {
  const o=parse(argv), rt=await G.runtime();
  const snapshots={};
  try {
    const forked=Object.values(rt.forks).every(Boolean);
    check(!(o.probeSend||o.revert)||forked,'--probe-send and --revert require every chain to be an owned fork');
    check(!o.probeSend||o.command==='run','--probe-send belongs to run');
    // A reverted fork run leaves no on-chain trace, so its journal must not be resumed either.
    if(o.revert) o.name+='-reverted-'+Date.now();
    const files=inputs(rt,o);
    rt.journalRoot=files.dir;
    const p=plan(rt,files);
    console.log(`Operation ${o.name} on ${rt.meta.environment} run ${rt.meta.id}: ${p.planned.actions.length} governance call(s)`);
    describe(rt,p.planned);
    if(o.command==='plan') return;
    if(o.command==='run') o.votes=bindVoteMode(files.dir,o.votes);
    const report={schemaVersion:1,name:o.name,runId:rt.meta.id,environment:rt.meta.environment,command:o.command,votes:o.votes,
      startedAt:new Date().toISOString(),planSha256:{before:p.planned.beforePolicySha256,after:p.planned.afterPolicySha256},
      scope:'On-chain hooks and resolver configuration, plus source-side router fee quotes.',
      status:'running'};
    const save=()=>C.write(files.report,report);
    let failure;
    try {
      if(o.revert) for(const [chain,provider] of Object.entries(rt.providers)) snapshots[chain]=await provider.send('evm_snapshot',[]);
      if(o.command==='verify') {
        Object.assign(report,await verify(rt,files,p));
      } else {
        const state=await precheck(rt,files,p);
        report.alreadyApplied=state.applied;report.heldBefore=state.chains;
        if(o.command==='run') {
          if(!state.applied) {
            if(!fs.existsSync(files.invariants)) C.write(files.invariants,await invariants(rt));
            report.feesBefore=await quotes(rt);save();
            report.governance=plain(await vote(rt,o,p));
          }
          Object.assign(report,await verify(rt,files,p));
          if(o.probeSend) report.probeSends=await probeSend(rt);
        } else report.feesBefore=await quotes(rt);
      }
      report.status='passed';
    } catch(error) {failure=error;}
    if(o.revert) {
      report.reverted=await restoreForks(rt.providers,snapshots);
      const failed=Object.keys(report.reverted).filter(chain=>!report.reverted[chain]);
      if(failed.length) {
        const message='Failed to restore forks: '+failed.join(', ');
        failure=new Error(failure?failure.message+'; '+message:message);
      }
    }
    if(failure) {report.status='failed';report.failure=failure.message;}
    report.finishedAt=new Date().toISOString();save();
    if(failure) throw failure;
    const done={precheck:state=>state.alreadyApplied?'the desired policy is already on chain':'every pending update passed precheck and all planned governance calls simulated successfully',
      run:state=>state.unchanged?'the chains match the desired policy and the recorded invariants match their baseline':'the chains match the desired policy',verify:()=>'the chains hold the desired policy'}[o.command](report);
    console.log(`\n${o.command} passed: ${done}.${o.revert?' Forks restored.':''}\nReport: ${files.report}`);
  } finally {rt.close();}
}
if(require.main===module) main(process.argv.slice(2)).catch(e=>{
  // Library errors carry a code; print it with the short reason, never the raw error object.
  console.error('CCV switch failed: '+(e.code?reason(e)+' '+String(e.shortMessage||'').slice(0,160):e.message));process.exitCode=1;
});
module.exports={parse,inputs,bindVoteMode,restoreForks,plan,compare,precheck,verify,invariants,canonical,PHASES};

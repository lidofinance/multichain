#!/usr/bin/env node
'use strict';
const fs = require('node:fs'), path = require('node:path');
const C = require('../script/testnet/context.cjs');
const {classify} = require('./exact-status.cjs');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const supported = new Set([11155111, 5003, 84532]);
const key = row => row.chainId + ':' + row.address.toLowerCase();

function portable(job) {
  const input = job.input;
  if (!supported.has(job.chainId) || !C.ethers.isAddress(job.address) || !input?.sources || !job.compilerVersion || !job.contractName)
    throw Error('Invalid verification package');
  if (typeof job.constructorArguments !== 'string' || !/^(?:[0-9a-f]{2})*$/i.test(job.constructorArguments))
    throw Error('Explicit ABI-encoded constructor arguments are required (empty for no-argument constructors)');
  const absolute = value => path.posix.isAbsolute(value) || /^[A-Za-z]:[\\/]/.test(value);
  const names = [...Object.keys(input.sources), ...Object.keys(input.settings?.libraries || {}), job.contractName];
  const remappings = (input.settings?.remappings || []).flatMap(x => x.split('='));
  if ([...names, ...remappings].some(absolute) || /\/Users\/|\/home\/|\/private\/|\/var\/folders\//.test(JSON.stringify(input)))
    throw Error('New verification packages must not contain absolute paths');
}

function client(env = C.environment()) {
  if (!env.ETHERSCAN_API_KEY) throw Error('ETHERSCAN_API_KEY is required');
  let lastCall = 0;
  return async (chainId, fields, post = false) => {
    if (!supported.has(chainId)) throw Error('Unsupported chain');
    for (let attempt = 0; attempt < 4; attempt++) {
      await delay(Math.max(0, 1100 - (Date.now() - lastCall))); lastCall = Date.now();
      const url = new URL('https://api.etherscan.io/v2/api');
      url.searchParams.set('chainid', String(chainId)); url.searchParams.set('apikey', env.ETHERSCAN_API_KEY);
      const body = {module:'contract', ...fields};
      if (!post) for (const [k,v] of Object.entries(body)) url.searchParams.set(k, v);
      let response;
      try { response = await fetch(url, {signal:AbortSignal.timeout(45000), ...(post ? {method:'POST',
        headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams(body)} : {})}); }
      catch { throw Error('Explorer connection failed; credentials omitted'); }
      if (!response.ok) throw Error('Explorer HTTP ' + response.status);
      const data = await response.json();
      if (typeof data.result === 'string' && /rate limit|too many/i.test(data.result)) { await delay(2500); continue; }
      return data;
    }
    throw Error('Explorer rate limit persisted');
  };
}

async function status(api, row) {
  const result = await api(row.chainId, {action:'getsourcecode', address:row.address});
  if (result.status !== '1' || !Array.isArray(result.result) || result.result.length !== 1) throw Error('Explorer source lookup rejected');
  const source = result.result[0];
  return {chainId:row.chainId, address:row.address, contractName:source.ContractName,
    ...classify(source, row.constructorArguments), checkedAt:new Date().toISOString()};
}

function summarize(rows) {
  return {total:rows.length, sourceAvailable:rows.filter(x=>x.sourceAvailable).length,
    exactVerified:rows.filter(x=>x.exactVerified).length, similarMatch:rows.filter(x=>x.similarMatch).length,
    constructorNotAudited:rows.filter(x=>x.constructorArgumentsMatch === null).length,
    constructorMismatch:rows.filter(x=>x.constructorArgumentsMatch === false).length,
    errors:rows.filter(x=>x.error).length};
}

async function audit(inventoryFile, jobsFile, output) {
  const api = client(), inventory = C.read(inventoryFile), jobs = new Map(C.read(jobsFile).map(j=>[key(j), j]));
  const rows = [];
  for (const item of inventory) {
    const job = jobs.get(key(item));
    try { rows.push({...await status(api, {...item, constructorArguments:job?.constructorArguments}), kind:item.kind}); }
    catch { rows.push({chainId:item.chainId,address:item.address,error:'Explorer source lookup failed'}); }
    C.write(output, {checkedAt:new Date().toISOString(),summary:summarize(rows),contracts:rows});
    if (rows.length % 25 === 0) console.log(JSON.stringify(summarize(rows)));
  }
  console.log(JSON.stringify(summarize(rows)));
  if (rows.some(x=>x.error)) process.exitCode = 1;
}

async function submit(jobsFile, directory) {
  const jobs = C.read(jobsFile); jobs.forEach(portable); // Validate every package before publishing any.
  const api = client(), rows = [];
  if (fs.existsSync(directory) && fs.readdirSync(directory).length) throw Error('Use a new empty output directory; poll existing submissions instead');
  fs.mkdirSync(directory, {recursive:true});
  C.write(path.join(directory,'jobs.json'),jobs); C.write(path.join(directory,'submissions.json'),rows);
  for (const job of jobs) {
    const before = await status(api, job);
    if (before.exactVerified) { rows.push({...before, result:'already-exact'}); C.write(path.join(directory,'submissions.json'),rows); continue; }
    const response = await api(job.chainId, {action:'verifysourcecode',contractaddress:job.address,
      sourceCode:JSON.stringify(job.input),codeformat:'solidity-standard-json-input',contractname:job.contractName,
      compilerversion:job.compilerVersion,constructorArguments:job.constructorArguments,
      constructorArguements:job.constructorArguments}, true); // Legacy spelling retained for API compatibility.
    const row = {chainId:job.chainId,address:job.address,before,response,
      pending:response.status === '1', ...(response.status === '1' ? {guid:response.result} : {})};
    rows.push(row); C.write(path.join(directory,'submissions.json'),rows);
    console.log(JSON.stringify({chainId:job.chainId,address:job.address,pending:row.pending,response}));
  }
  C.write(path.join(directory,'jobs.json'),jobs); C.write(path.join(directory,'submissions.json'),rows);
  await poll(directory);
}

async function poll(directory) {
  const api = client(), jobs = new Map(C.read(path.join(directory,'jobs.json')).map(j=>[key(j),j]));
  const rows = C.read(path.join(directory,'submissions.json')), deadline = Date.now() + 20*60*1000;
  do {
    for (const row of rows.filter(x=>x.pending)) {
      const response = await api(row.chainId,{action:'checkverifystatus',guid:row.guid});
      if (response.status !== '1' && /pending|queue/i.test(response.result)) continue;
      const after = await status(api,jobs.get(key(row)));
      Object.assign(row,{after,pending:false,pollResponse:response,result:after.exactVerified ? 'exact-verified' : 'exact-verification-incomplete'});
      // "Already Verified" is a response to inspect, not proof of an Exact Match.
      C.write(path.join(directory,'submissions.json'),rows);
      console.log(JSON.stringify({chainId:row.chainId,address:row.address,result:row.result,after,response}));
    }
    if (!rows.some(x=>x.pending)) break;
    await delay(15000);
  } while (Date.now()<deadline);
  const results = [];
  for (const row of rows) results.push({...await status(api,jobs.get(key(row))),pending:row.pending});
  C.write(path.join(directory,'results.json'),{summary:summarize(results),contracts:results});
  if (results.some(x=>!x.exactVerified || x.pending)) process.exitCode=1;
}

async function main(args) {
  if (args[0]==='audit' && args.length===4) return audit(...args.slice(1));
  if (args[0]==='submit' && args.length===3) return submit(...args.slice(1));
  if (args[0]==='poll' && args.length===2) return poll(args[1]);
  throw Error('Usage: explorer.cjs audit <inventory.json> <jobs.json> <report.json> | submit <jobs.json> <new-output-directory> | poll <output-directory>');
}
if (require.main===module) main(process.argv.slice(2)).catch(error=>{
  // Do not print provider objects or raw HTTP errors (they can contain credentials).
  console.error(error instanceof SyntaxError ? 'Invalid verification JSON' : error.message); process.exitCode=1;
});
module.exports={portable, status, summarize};

#!/usr/bin/env node
'use strict';
const readline=require('node:readline');

function redactor(env) {
  const secrets=Object.entries(env).filter(([name,value])=>value && value.length>=8 &&
    /PRIVATE_KEY|MNEMONIC|PASSWORD|SECRET|API_KEY|LOCAL_DEVNET_PK/.test(name))
    .flatMap(([,value])=>/^0x[0-9a-f]{64}$/i.test(value)?[value,value.slice(2)]:[value])
    .sort((a,b)=>b.length-a.length);
  return line=>{
    for(const secret of secrets) line=line.split(secret).join('[REDACTED]');
    // Nested tools may derive a signer which is not exported in our environment.
    return line.replace(/(--private-key(?:=|\s+)["']?)(?:0x)?[0-9a-f]{64}/gi,'$1[REDACTED]');
  };
}
async function filter(input,output,env=process.env) {
  const redact=redactor(env);
  for await(const line of readline.createInterface({input,crlfDelay:Infinity})) output.write(redact(line)+'\n');
}
if(require.main===module) filter(process.stdin,process.stdout).catch(()=>{process.exitCode=1;});
module.exports={redactor,filter};

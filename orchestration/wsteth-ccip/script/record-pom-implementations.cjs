#!/usr/bin/env node
// Pin implementation identities from deployment transactions, never from the later verification read.
const fs = require('node:fs');
const skipped = new Set(process.argv.slice(2));
try {
  for (const [chain, statePath] of [['sepolia', 'state/l1.json'], [process.env.L2_CHAIN || 'mantle_sepolia', 'state/l2.json']]) {
    const config = JSON.parse(fs.readFileSync(`config/chains/${chain}.json`, 'utf8'));
    const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    const proxy = config.deployed.pool_operation_manager;
    if (state.poolOperationManager?.toLowerCase() === proxy.toLowerCase() && state.poolOperationManagerImplementation) continue;
    const broadcastPath = `broadcast/ccip/1_Deploy.s.sol/${config.chain.chain_id}/run-latest.json`;
    if (!fs.existsSync(broadcastPath) && skipped.has(chain)) {
      console.warn(`${chain}: deployment skipped; missing ${broadcastPath}. Restore this deployment's trusted POM CREATE records before step 08 verification.`);
      continue;
    }
    const broadcast = JSON.parse(fs.readFileSync(broadcastPath, 'utf8'));
    if (!broadcast.transactions.some(tx => tx.contractAddress?.toLowerCase() === proxy.toLowerCase() && tx.transactionType === 'CREATE')) {
      throw new Error(`The ${chain} broadcast does not contain the recorded POM proxy ${proxy}`);
    }
    const implementations = broadcast.transactions.filter(tx => tx.contractName === 'PoolOperationManager' && tx.transactionType === 'CREATE');
    if (implementations.length !== 1) throw new Error(`Expected one POM implementation deployment on ${chain}`);
    state.poolOperationManager = proxy;
    state.poolOperationManagerImplementation = implementations[0].contractAddress;
    fs.writeFileSync(statePath, JSON.stringify(state, null, 2) + '\n');
    console.log(`${chain}: recorded POM implementation ${state.poolOperationManagerImplementation}`);
  }

} catch (error) {
  console.error(`✗ Cannot record POM implementation: ${error.message}. Restore the matching deployment broadcast or complete state record before verification.`);
  process.exitCode = 1;
}

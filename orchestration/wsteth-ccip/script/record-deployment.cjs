#!/usr/bin/env node
// Pin this run's deployment identities from the deployment transactions (the CREATE records of
// 1_Deploy's broadcast), never from a later verification read, into the per-chain state files
// that step 08 verifies against:
//   • LidoTimelock and CallProxy — neither is a proxy, so the address is the whole identity;
//   • the token 1_Deploy deployed (scratch spokes): proxy and implementation CREATEs, plus the
//     ProxyAdmin the proxy constructor created (from the record; steps 07/08/10 read it back from
//     the proxy's EIP-1967 admin slot);
//   • the signer of those CREATEs, stamped into the record as governance_addresses.deployer, so
//     step 08's revocation checks bind to the key that deployed and not to the verifying environment.
// The broadcast check proves a recorded address is this run's deployment and not an unrelated
// contract that landed on a reused nonce after a fork reset.
const fs = require('node:fs');
const l1 = process.env.L1_CHAIN || 'sepolia';
const l2 = process.env.L2_CHAIN || 'mantle_sepolia';
const chains = [[l1, 'state/l1.json'], [l2, process.env.L2_STATE_FILE || 'state/l2.json']];
const same = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
try {
  for (const [chain, statePath] of chains) {
    if (chain === l1 && (process.env.WSTETH_SKIP_L1 === '1' || process.env.WSTETH_DEPLOY_SCOPE === 'spoke')) continue;
    if (chain === l2 && process.env.WSTETH_DEPLOY_SCOPE === 'hub') continue;
    const configPath = `config/chains/${chain}.json`;
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const state = fs.existsSync(statePath) ? JSON.parse(fs.readFileSync(statePath, 'utf8')) : {};
    const timelock = config.deployed?.timelock;
    const callProxy = config.deployed?.call_proxy;
    if (!timelock || !callProxy) throw new Error(`${chain}: record lacks .deployed.timelock / .deployed.call_proxy`);
    const ownHub = chain === l1 && process.env.WSTETH_HUB_DEPLOY_SCRIPT;
    const broadcastPath = ownHub
      ? `broadcast/hub-migration/${ownHub}/${config.chain.chain_id}/run-latest.json`
      : `broadcast/ccip/1_Deploy.s.sol/${config.chain.chain_id}/run-latest.json`;
    if (!fs.existsSync(broadcastPath)) throw new Error(`${chain}: missing ${broadcastPath} (1_Deploy did not broadcast in this run)`);
    const broadcast = JSON.parse(fs.readFileSync(broadcastPath, 'utf8'));
    // Foundry's 0.8.19 artifact path can omit contractName. In that case accept the
    // exact CREATE address as a fallback; a present but different name still fails.
    const create = (name, address) => broadcast.transactions.find(tx =>
      tx.transactionType === 'CREATE' && same(tx.contractAddress, address)
      && (tx.contractName == null || tx.contractName === name));
    const timelockCreate = create('LidoTimelock', timelock);
    if (!timelockCreate) throw new Error(`The ${chain} broadcast does not contain a LidoTimelock CREATE at ${timelock}`);
    if (!create('CallProxy', callProxy)) throw new Error(`The ${chain} broadcast does not contain a CallProxy CREATE at ${callProxy}`);
    state.timelock = timelock;
    state.callProxy = callProxy;
    console.log(`${chain}: recorded timelock ${timelock} and CallProxy ${callProxy} from the CREATE records`);

    const token = config.deployed?.token;
    if (token) {
      const impl = config.deployed.token_impl;
      const proxyAdmin = config.deployed.token_proxy_admin;
      if (!create('TransparentUpgradeableProxy', token)) throw new Error(`The ${chain} broadcast does not contain the token proxy CREATE at ${token}`);
      if (!create('ERC20BridgedPermit', impl)) throw new Error(`The ${chain} broadcast does not contain the token implementation CREATE at ${impl}`);
      if (!/^0x[0-9a-fA-F]{40}$/.test(proxyAdmin || '') || /^0x0{40}$/.test(proxyAdmin)) throw new Error(`${chain}: record lacks .deployed.token_proxy_admin`);
      if (state.wstETH && !same(state.wstETH, token)) throw new Error(`${chain}: ${statePath} already names token ${state.wstETH}, the record deployed ${token}`);
      state.wstETH = token;
      state.wstETHImpl = impl;
      state.wstETHProxyAdmin = proxyAdmin;
      console.log(`${chain}: recorded token ${token} (impl ${impl}, ProxyAdmin ${proxyAdmin}) from the CREATE records`);
    }
    fs.writeFileSync(statePath, JSON.stringify(state, null, 2) + '\n');

    const deployer = timelockCreate.transaction?.from;
    if (!/^0x[0-9a-fA-F]{40}$/.test(deployer || '')) throw new Error(`${chain}: the LidoTimelock CREATE record carries no sender`);
    config.governance_addresses.deployer = deployer;
    fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
    console.log(`${chain}: deployer ${deployer} (sender of the CREATEs) stamped into the record`);
  }
} catch (error) {
  console.error(`✗ ${error.message}`);
  process.exit(1);
}

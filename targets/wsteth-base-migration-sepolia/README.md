# Sepolia fork rehearsal for HubPool and Base migration

This target creates a fresh full Lido and Dual Governance deployment, an unmodified
upstream wstETH, two existing CCIP directions and the old Base bridge. It then runs
the same hub-first migration and Base lifecycle scenarios as
[the Mainnet target](../wsteth-base-migration-mainnet/README.md).

Run with Node 22.15+ (22.x) or Node 24 on PATH, the repository dependencies installed,
and the deployer / actor settings in `orchestration/wsteth-ccip/.env`:

```sh
just wsteth-rehearse sepolia
just wsteth-rehearse mainnet
just wsteth-rehearse both
```

Each command starts fresh local Anvil nodes at recorded upstream blocks, prepares a
new run, runs the full deployment and verification pipeline, and stops its own nodes.
Logs, upstream block hashes and outcome are under `runs/wsteth-2.0/rehearsals/<run-id>`;
configuration, transactions and verification archives are under
`runs/wsteth-2.0/workspaces/<run-id>`. Existing nodes and previous run records are preserved.
Runs execute sequentially because the orchestration selects one active workspace.

Required upstream variables: `RPC_SEPOLIA_REMOTE`, `RPC_BASE_SEPOLIA_REMOTE`,
`RPC_OPTIMISM_SEPOLIA_REMOTE`. `RPC_MONAD_TESTNET_REMOTE` optionally overrides Monad's
public testnet RPC. The Mainnet line uses `RPC_ETHEREUM_REMOTE` and `RPC_BASE_REMOTE`.
For separately managed local forks, use `just wsteth-prepare
wsteth-base-migration-sepolia <run-id> fork` followed by `just wsteth all`;
also set `RPC_MONAD_TESTNET` and `RPC_OPTIMISM_SEPOLIA` to their local forks.

## Preparation and migration order

1. Deploy Lido and Dual Governance with pristine wstETH. Preserve and restore the
   operator's existing core source and deployment record around this compilation.
2. Deploy the Base governance executor, original Lido bridge/token proxies, and
   Chainlink's old `SiloedLockReleaseTokenPool 1.6.0` with an RBACTimelock and CallProxy.
3. Create a Monad Testnet direction backed by 1000 wstETH in shared custody and an
   OP Sepolia direction backed by 10 wstETH in isolated custody. OP Sepolia represents
   the isolated-custody case, not the full behavior of a particular Mainnet network.
   Remote tokens use Chainlink's mintable test token and `BurnMintTokenPool 1.5.1`
   supplied by the pinned CCIP 1.6.0 package.
4. Register fresh tokens through the existing official TokenAdminRegistry on each
   fork, impersonating its observed owner. Complete administrator acceptance and
   pool binding. Fund the hub through Lido staking/wrapping and seed the legacy Base
   bridge with a real deposit and simulated messenger relay for 100 wstETH.
5. Verify the baseline, then inventory and migrate the hub. Switch the two remote
   pools to the new hub and complete the pre-Base hub checkpoint.
6. Deploy Base-specific CCIP contracts and migration implementations, connect Base,
   execute the migration action set, run lifecycle scenarios and verify/archive state.

All amounts and the two existing directions are explicit in `target.json.bootstrap`.
Generated addresses go to `state/migration-target.json`; the target template remains
unchanged. Mainnet starts directly from its observed contracts and has no bootstrap.

## Coverage and limits

`SepoliaBootstrapTest` checks full-core addresses, backing, absence of the testnet
registration hook, registry permissions, reciprocal pool configuration and legacy
Base supply. The Python baseline check verifies both remote pools and registries. The shared `RealHubMigrationTest` and `RealBaseMigrationTest` cover the
same migration gates on both lines. `test-existing-lanes` exercises both sides of Monad and OP Sepolia pool round trips
after migration, restoring snapshots afterwards. Separate RPC calls preserve each
chain’s VM: Foundry cannot mix Monad and Ethereum VMs in one test process.

Scenarios that advance time create their forks inside each test, so one scenario's
clock cannot affect the next. Scenario suites run sequentially to check that independence.
The Base sweep uses the configured interval between activation and close, including
the shorter Sepolia timers.

`RealEmulatedCcvTest` checks the 2-of-2 policy and rejection with only one verifier.
Both verifiers and its 2.0 ramp layer are emulated on test-local forks. This is not
evidence that Chainlink and Nethermind services are available or deliver on the
public network. Other transport checks impersonate registered ramps or messenger
entrypoints; no DON or OP proof system runs. The fresh baseline contains no pending
CCIP messages, so remote-pool replacement does not rehearse a real queue drain.

Public Sepolia deployment remains a separate operation: Chainlink must register the
new token there. This bootstrap accepts loopback Anvil RPCs and a fork-only target.
The [plan](../../orchestration/wsteth-ccip/docs/SEPOLIA-MIGRATION-REHEARSAL.md) describes
the public-network happy path and the current Nethermind emulation decision.

The legacy sources and source hashes are in `bootstrap/vendor/provenance.json`.
Lido sources retain the original compiler pragmas. CCIP adaptation changes only
OpenZeppelin import paths to the installed versioned packages. These are source-based
deployments for rehearsal, not a claim of byte-for-byte equality with Mainnet builds.

FPF Core C.39:4.1–4.3: the verified baseline supplies the preconditions consumed by
the shared migration; each checkpoint must pass before the following phase starts.

# wstETH Base migration, mainnet fork rehearsal target

In-place migration of the Base wstETH legacy bridge (lido-l2 `L1ERC20TokenBridge` /
`L2ERC20TokenBridge` behind `OssifiableProxy`) and the Base wstETH token to a CCIP lane governed by
the Lido timelock. Operation `in-place-upgrade`: the existing contracts are inputs, nothing from the
scratch pipeline (core, Dual Governance, governance executor, token) is deployed. Rehearsed on anvil
forks of Ethereum (chain 1) and Base (chain 8453); `environments` admits `fork` only.

Plan: the [one-vote upgrade path](docs/2026-10-26-upgrade-path.md) (the on-chain actions in order,
revised 2026-10-31 for the Chainlink hub cutover) and the [Chainlink hub migration fork plan](CHAINLINK_HUB_MIGRATION_FORK_PLAN.md);
`target.json` `.migration.plan` names the first. Facts in `target.json` `.migration` were read
from mainnet on 2026-10-21 (registry administrator, proxy admins, executor delay); bridge
Emergency Brakes were read on 2026-10-26; the hub block on 2026-10-30. `migration.factDates` records those distinct dates;
`placeholders` identifies the lane-role inputs that remain rehearsal-only.

The current pipeline separates preparation at the same boundaries as the HTML Explainer.
The first phase prepares and migrates the five connected lanes of the old Ethereum pool (four chains it lists with no remote pool stay behind; see "Status, 2026-11-11"). Only after registry
administration has been accepted by a Chainlink MCMS proposal and the hub checkpoint passes
does the second phase deploy contracts for Base. Historical runs below used the earlier order.

Hub preparation and Ethereum-side Base setup now use our `script/hub-migration/`
scripts and CCIP release artifacts. Base deploy/configure and scratch deploys use
unmodified upstream scripts. See the [implementation and verification report](../../orchestration/wsteth-ccip/docs/UPSTREAM-DEPLOY-ISOLATION-RESULTS-2026-11-04.md).
`--inputs DIR` replays recorded fork blocks/hashes and CCIP API responses.

`just wsteth-rehearse mainnet` starts fresh owned Ethereum and Base forks and runs this
pipeline. `just wsteth-rehearse both` also runs the
[Sepolia line](../wsteth-base-migration-sepolia/README.md), which first deploys the
baseline needed by the same migration tests. Use Node 22.15+ (22.x) or Node 24 and set
`RPC_ETHEREUM_REMOTE` / `RPC_BASE_REMOTE`; the launcher records upstream blocks and
stops its own forks after the run.

## Pipeline (`just wsteth all` after `just wsteth-prepare wsteth-base-migration-mainnet <run-id> fork`)

| Explainer | Recipe | What it does on the forks |
| --- | --- | --- |
| Before 1.1 | `patch-submodules`, `preflight`, `build`, `build-ccip`, `forks-check`, `migration-inputs`, `hub-inventory` | Check dependencies and forks; record live proxies and the old Ethereum pool at a pinned block; import its five connected lanes, limits and custody into the run configuration; the four chains with no remote pool are recorded and left in the old pool. |
| 1.1 | `hub-prepare` | Deploy the Ethereum hub, hooks, timelock, CallProxy and four lockboxes (shared, Bitlayer, 0G, Robinhood). Configure only the imported lanes. No Base lockbox or CCV pair yet. Accept ownership, grant Agent ADMIN_ROLE and revoke the deployer's ADMIN_ROLE. |
| 1a | `hub-cutover` | Through the existing Chainlink RBACTimelock: restrict outbound transfers; after its delay, move all custody to the four lockboxes, bind the new hub and nominate LidoTimelock as registry administrator. The hub must serve exactly the five imported lanes. |
| 1a | `hub-accept-admin` | Chainlink MCMS proposes `acceptAdminRole(wstETH)` in LidoTimelock; after its delay anyone executes through CallProxy. Verify the final administrator and empty pending administrator. No DAO transaction or deployer bypass. |
| Gate before 1.2 | `base-prepare` starts with `test-hub` | Run `RealHubMigrationTest` in checkpoint mode. Verify the five lanes, custody, isolation, completed governance operations, absence of deployer admin, and absence of Base deployments. A failure stops Base preparation. Record the checked Ethereum block. |
| 1.2 | remainder of `base-prepare` | Deploy Base's pool stack. Add the Base lockbox, verifier and resolver on Ethereum; MCMS proposes their ownership acceptance through LidoTimelock. Configure Base and transfer its admin role to the executor. Deploy all three token/bridge implementations, without upgrading proxies. |
| 1b | `hub-connect-lane` | MCMS proposes the six-call Base connection batch through LidoTimelock. After the delay, execute through CallProxy; verify that the five imported lanes and their balances are unchanged. |
| 2 | `migration-upgrade` | Start legacy transfers left in flight, then execute the one DAO vote using the prepared implementations: upgrade the L1 bridge, authorize it on the Base lockbox, arm timers, send and relay the 13-action Base set through the real messenger. |
| 3–7 and recovery branches | `test-scenarios` | Final hub tests and Base lifecycle scenarios: activation, legacy transfers in flight, CCIP pool-boundary transport, sweep, close, vetoes and rollback. The Base pool policy blocks direct Router withdrawals until authenticated L1 confirmation and Base activation; failed confirmations can be retried. Base conservation assertions also protect the four existing lockbox balances. |
| Verification | `verify-state` | Verify the post-vote state with state-mate; archive configuration, migration and proposal records, the hub checkpoint and test logs. Scenario mutations occur on test forks, so this matrix checks the post-vote checkpoint. |

The checkpoint proves the Ethereum side of the five imported lanes, including simulated calls
from registered ramps. This target has only Ethereum and Base forks: remote pool changes,
round trips through all five spoke networks, queue drain, DON delivery and MCMS signatures remain
outside its coverage. The configured MCMS and CCV identities are rehearsal placeholders.

Environment for a run: `RPC_ETHEREUM`, `RPC_BASE` (anvil endpoints), `DEPLOYER_PRIVATE_KEY` (a funded
fork account). The ccip branch needs `@chainlink/ccip-owner-contracts`, `@openzeppelin/contracts-4.9.2`,
`@openzeppelin/contracts-upgradeable-5.0.2` and `@lido/wsteth-token` under
`components/ccip/chains/evm/node_modules`; the last one must resolve to `components/wsteth-token` of
this checkout so the rehearsal runs the token sources under review.

## Inputs that are placeholders

`config/chains/*.json` name the DAO principals (Aragon Agent on Ethereum, the OptimismBridgeExecutor
on Base) and placeholder addresses for the Emergency Brakes multisig and the Chainlink MCMS
(`0xEB00000000000000000000000000000000000001` and `0x3C3C000000000000000000000000000000000001` on Ethereum,
`0xEB00000000000000000000000000000000008453` and `0x3C3C000000000000000000000000000000008453` on Base) on the lane's
timelocks and hooks. Replace them before any
use beyond the fork rehearsal. The real Emergency Brakes multisigs that hold the disabler roles on
the deployed legacy bridges are in `target.json` `.migration` (`emergencyBrakes`, read from mainnet
2026-10-26), checked and recorded by step 01m, and impersonated by the scenario for the veto.

## Status, 2026-10-28: the one-vote scheme

The migration is one Aragon vote at T_vote_L1 and three permissionless, time-gated steps per bridge
(`activate()` on L1 at T_activate_L1, `activate()` on Base at T_activate_L2, `close()` on both at T_close_L1L2), with the
lane `ERC20LockBox` as the single backing for CCIP and legacy withdrawals from the L1 activation on
(design: [one-vote design](docs/2026-10-26-upgrade-path.md); contracts: `components/l2-bridge-migration`). Run end to end on anvil
forks of Ethereum and Base (pinned at the heads of 2026-10-28):

| Layer | Result |
| --- | --- |
| Steps 01m, 04, 05, 07, 06 | all green on both forks; step 06 executed the vote (upgrade, lockbox authorization, both timers, governance message) and Base action set 0 (13 actions) through the real Base messenger |
| `test/scenario/RealBaseMigration.t.sol` | 2 tests green: `test_runbook_one_vote` and the timelock levers on both chains |
| Step 08 (`verify-state`) | 219 state-mate checks green, 13 delegated or skipped (run `one-vote-inspect-20261028-03`, seeded from the record of `one-vote-fork-20261028-02`); the bridge ABIs in `config/state-mate/abis.json` carry only the checked view functions, as state-mate requires full coverage |

The [preserved inspection archive](../../runs/wsteth-2.0/history/deployments/one-vote-inspect-20261028-03/README.md) contains the chain records, state, component policy, logs, generated verification inputs and copy-integrity hashes. These are the original 2026-10-28 results, not a rerun after later edits.

What the runbook drives, in order, with conservation (escrow + lockbox − Base supply − legacy
amounts in flight) asserted after every step: the pair started on the old implementations
finalizes; neither step runs before its timer; a legacy round trip inside the checkpoint; legacy
deposits and withdrawals started in LEGACY for every later stage (one deposit relayed gas-starved so
it lands in `failedMessages`); at T_activate_L1 the Emergency Brakes veto (`disableDeposits`) and a registry
that does not bind the hub pool both block `activate()`, then anyone activates L1: the whole escrow
moves to the lockbox, legacy deposits cannot be started, a CCIP deposit goes through the real
Router and OnRamp and is minted on Base while Base is still LEGACY, an in-flight legacy withdrawal
is paid from the lockbox, an in-flight legacy deposit finalizes on the LEGACY Base bridge; a
withdrawal started while Base is still LEGACY is relayed gas-starved on L1; at T_activate_L2 the veto
(`disableWithdrawals`, lifted by an executor action set) blocks `activate()`, then anyone activates
Base: legacy withdrawals cannot be started, a CCIP withdrawal burns through the pool and is released
from the lockbox, an in-flight legacy deposit finalizes on the MIGRATING Base bridge; the operators'
sweep replays both failed relays; `close()` is too early, and after the timer refuses a bridge
rolled back to LEGACY; at T_close_L1L2 the veto blocks `close()` on each chain, then anyone closes Base
(the bridge renounces MINTER_ROLE and BURNER_ROLE, the pool keeps them) and L1; CCIP works both ways;
a late legacy deposit and a late legacy withdrawal fail at the messengers and stay replayable; Base
rolls back (MIGRATING + roles, one action set), replays, goes forward again; L1 rolls back to
MIGRATING and the replay is paid from the lockbox without any transfer back; the DAO drops the
bridge's lockbox authorization, after which a rollback alone no longer funds a legacy withdrawal;
`activate()` / `close()` cannot be re-run after a rollback.

Boundaries of what this establishes: the Agent, Chainlink's registry administrator, the Emergency
Brakes multisigs, the aliased L1 messenger and the OptimismPortal are impersonated; CCIP delivery is
the destination OffRamp's `releaseOrMint` on our pool, impersonated; no DON and no OP proof system
run (a failed relay is produced by starving the messenger's gas, not by a real relayer); the lane's
Emergency Brakes and Chainlink MCMS are placeholders; the vote and the action set are built by the
scripts, not read from a vote artefact; the timers are rehearsal values (1 day, 1 day, 10 days) and
the clock is warped, so the mainnet margins (OP proving and finalization windows) are not observed.

## Status, 2026-10-30: the hub cutover before the vote

Run `hub-fork-20261030-04` on fresh anvil forks pinned at Ethereum block 26307713 (hash
`0x99b326e9a5a521a37d6750820ceeaf0d0532b432416bdde356f7548224054f3c`) and Base block 53299867, the
complete in-place pipeline with the hub migration steps:

| Layer | Result |
| --- | --- |
| Step 01h (`hub-inventory`) | nine lanes found on the old pool and equal to `expectedLanes`; its accounting closed exactly: balance 15 787,166937811415364701 wstETH = unsiloed 15 742,555255747602924054 + silos 44,611682063812440647 (Bitlayer 0,105063567385275758, 0G 0,013044622506851971, Robinhood 44,493573873920312918), unaccounted 0 |
| Steps 04, 05 | hub with ten lanes and five lockboxes; the imported lanes carry the old pool's remote pools and limits and no CCV entry (`getRequiredCCVs` empty), the Base lane the placeholder resolver |
| Step 05h (`hub-cutover`) | pause proposal `0xf3b1398405b20e7d79217a27ffc047dd9593921b2b9e30d4f704526e1680c85a` (1 call) and cutover proposal `0xed07d6d570026ce6c33b2050c35a204cdee64f6ed33ee7c72bbce828d449de9a` (12 calls, predecessor = the pause) scheduled by the impersonated proposer `0xE53289F32c8E690b7173aA33affE9B6B0CB0012F`, executed after the 10 800 s delay through the CallProxy `0xF3E54a1FDA3d4351C8BD5065678c0F5DDD0D7BCB`; a simulated `ccipSend` of 1 wstETH reverted on all nine lanes after the pause; every invariant held: old pool 0, Chainlink timelock's wstETH delta 0, each lockbox grew by its lane group's amount, Base lockbox and legacy escrow unchanged, registry pool = new hub with the administration pending for the Lido timelock, the Bitlayer silo's rebalancer restored to `0x2728df4D22253004C017675bd609962cD641D797` |
| Steps 07, 06 | the Lido timelock accepted the administration (part D skipped); the vote executed as before |
| `test/scenario/RealHubMigration.t.sol`, `RealBaseMigration.t.sol` | 8 + 2 tests green |
| Step 08 (`verify-state`) | 338 state-mate checks green, 13 delegated or skipped; archive `deployments/fork/ethereum-base/2026-10-30_20-40-48` in the run (chain records of all eleven chains, the policy, state, logs) |

Facts the fork established beyond the plan's reading: the 1.6.0 pool rejects the pause
`{enabled, capacity 1, rate 0}` quoted from Chainlink's guide (`InvalidRateLimitRate`: an enabled
limiter needs a nonzero rate below its capacity), so the pause is `{enabled, capacity 2 wei, rate
1 wei/s}`, the configuration Chainlink already runs on the outbound side of Ink, Plasma, Jovay and
Abstract; `withdrawLiquidity` and `withdrawSiloedLiquidity` pay the caller, so the custody passes
through the timelock's balance inside the batch and leaves it unchanged.

Boundaries of what the hub steps establish: the Chainlink proposer is impersonated and the executor
is called by the deployer key (no MCMS signatures); the spoke chains are not forked, so the spokes'
remote-pool additions and outbound pauses, the drain of the spoke → Ethereum queue and DON delivery
are not rehearsed (listed under `unverified` in `state/hub-migration.json`); the imported spoke
records hold only what `2_Configure` reads (selector, Chainlink infrastructure, token, pool) and
are not verified against the spokes; the pause check is an `eth_call` simulation against the Router.

## Status, 2026-10-30, run 07: the Base lane as a separate Chainlink action

Run `hub-fork-20261030-07` on fresh anvil forks pinned at Ethereum block 26308635 and Base block
53305477, the complete in-place pipeline with Chainlink's two actions apart:

| Layer | Result |
| --- | --- |
| Steps 01h, 04, 05 | nine lanes found and equal to `expectedLanes`, unaccounted 0; the hub record carries `deferred_lanes: ["base"]`; the hub was configured for the nine imported lanes only, with five lockboxes deployed, authorized and handed to the Lido timelock, the Base lockbox bound to no selector |
| Step 05h (`hub-cutover`) | preflight held: the hub served exactly the nine lanes, the Base selector `15971525489660198786` was not among them and had no lockbox bound; pause proposal `0x9c1435cc932cc23502be499980cf4445a2ba4014bc2299081dde11d3210ac569` (1 call) and cutover proposal `0xba931b4d017f78f227e7957bc06b78fba88985de7d5bb412767951612378a0cd` (12 calls) through the Chainlink timelock as before; every invariant held; `state/hub-migration.json` (schema 2) records the hub's lanes at the cutover under `hubAtCutover` |
| Step 05c (`hub-connect-lane`) | the component's `4_ConnectLane` wrote the six calls for the Base lane (`applyChainUpdates`, `applyTokenTransferFeeConfigUpdates`, `configureLockBoxes`, `applyCCVConfigUpdates`, `applyRemoteChainConfigUpdates`, `applyOutboundImplementationUpdates`), all targeting the hub `0x8456B26323214F263AB269B673fd2a110A0f4A98`, its hooks, verifier and resolver, none with a blocked selector; proposal `0xbd66e2a5f76e553c6a9b0ba2e92257b87906df7e9207800d374ebd7716f14445` scheduled on the Lido timelock `0xf946DDD606bD17C6Ff2DBFcAB573ee8806d86C7a` by the impersonated proposer `0x3C3C000000000000000000000000000000000001` at block 26308645, executed after the 259 200 s delay through the CallProxy `0xa8A337D3eB8FEFBcC14f17FA2D58D9288D6A6115` at block 26308647; read back: Base supported, remote pool `0x7Be6E341624D7f730f91CAa7867416D63DbEA219`, remote token `0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452`, lockbox `0x98E46E7A6Eb3608461294Ab396AD4A49Ffd83186`, the component's default limits, fee config enabled, the resolver required on both directions, the verifier behind the resolver, ten supported chains; the five lockbox balances, the hub balance and the registry entry unchanged |
| Steps 07, 06 | the Lido timelock accepted the administration (part D skipped); the vote executed as before |
| `test/scenario/RealHubMigration.t.sol`, `RealBaseMigration.t.sol` | 11 + 2 tests green, the three new ones included: the hub the cutover bound mirrored the old pool, the Base lane came by the Lido timelock proposal, that proposal cannot run twice |
| Step 08 (`verify-state`) | 338 state-mate checks green, 13 delegated or skipped; archive `deployments/fork/ethereum-base/2026-10-30_23-49-52` in the run, now with `hub-migration.json`, `hub-lane-connect.json` and the batch under `state/` |

Runs 05 and 06 of the same day stopped inside step 05c on two script errors found by the fork and
fixed since (a helper called without its argument; the four-argument `getTokenTransferFeeConfig` of
TokenPool 2.0.0 and `cast`'s number annotations in its output); the cutover and the proposal executed
correctly on both, so the fix changed only the read-back.

Facts this run established: `configureLockBoxes` binds a lockbox to a selector the pool does not yet
support, so the Base lockbox could equally be bound in step 05 — the rehearsal keeps every Base-specific
call in the owner's proposal so the hub the cutover binds carries nothing of Base; the Lido timelock
accepts a six-call batch from its proposer with the deployed blocked-selector list, and the CallProxy
executes it after the delay.

Boundaries: the Lido timelock's proposer is the placeholder MCMS address of the record (impersonated, no
MCMS signatures); the lane is connected with the component's default limits and the placeholder
resolver, both mainnet parameters; nothing changes on Base in step 05c; between this connection and
the Base action set (step 06) a hub → Base send would lock wstETH in the Base lockbox until Base can
mint, a window the mainnet schedule must keep short or close with a paused outbound limiter opened
afterwards (not rehearsed).

## Status, 2026-10-31: the plans brought in line, the scenarios rerun

The [upgrade path](docs/2026-10-26-upgrade-path.md) now describes the hub cutover of 2026-10-30
(sections 1.1, 1.2 and 4), and `RealBaseMigration.t.sol` asserts at every conservation check that
the hub's four other lockboxes keep their balances, as the [hub plan](CHAINLINK_HUB_MIGRATION_FORK_PLAN.md)
step 6 requires. Both scenario files were rerun against the forks run `hub-fork-20261030-07` left
after step 06 (Ethereum `http://127.0.0.1:8553`, Base `http://127.0.0.1:8554`, the run's records),
not through a new pipeline run:

| Layer | Result |
| --- | --- |
| `test/scenario/RealHubMigration.t.sol` | 11 tests green |
| `test/scenario/RealBaseMigration.t.sol` | 2 tests green; `test_runbook_one_vote` checked the shared lockbox and the Bitlayer, 0G and Robinhood lockboxes at each of its eleven conservation points |

The new check is not vacuous: with the shared lockbox's recorded balance raised by 1 wei, the
runbook fails at its first conservation point (`another lane's lockbox moved: after the pre-upgrade
pair`). Still not covered: a round trip on the nine lanes after the Base activations, the close and
the rollbacks (the hub test runs at T_vote_L1), and the LidoTimelock accepting the registry
administration by a proposal instead of the bypass.

Reproduce:

```sh
anvil --fork-url https://eth.drpc.org --fork-block-number <head> --port 8545 --auto-impersonate --compute-units-per-second 150
anvil --fork-url https://mainnet.base.org --fork-block-number <head> --port 8546 --auto-impersonate --compute-units-per-second 150
export RPC_ETHEREUM=http://127.0.0.1:8545 RPC_BASE=http://127.0.0.1:8546
# the scenario alone, against forks the pipeline already drove through step 06:
#   (cd orchestration/wsteth-ccip && FOUNDRY_TEST=../../targets/wsteth-base-migration-mainnet/test \
#    L1_CHAIN=ethereum L2_CHAIN=base L1_RPC=$RPC_ETHEREUM L2_RPC=$RPC_BASE forge test --match-path '*/test/scenario/Real*' -vv)
export DEPLOYER_PRIVATE_KEY=<a funded fork account> DEPLOYER_ADDRESS=<its address>
just wsteth-prepare wsteth-base-migration-mainnet <run-id> fork
just wsteth all
```

The upstream endpoints must serve state at the pinned block for the whole run (drpc and the official
Base endpoint do; the publicnode endpoints return 403 after a few hundred requests). A fresh pair of
forks is needed for every full run: step 06 cannot upgrade a token proxy twice.

Chain records share the orchestration's [chain schema](../../orchestration/wsteth-ccip/script/chain.schema.json).
`lint-config` validates that format and the operation-specific rules for pristine templates.

## Status, 2026-11-11: five connected lanes, four left in the old pool

Since 2026-11-10 the old pool lists Ink, Plasma, Jovay and Abstract with no remote pool (Ethereum
block 26 380 937, transaction `0x873b0eb6c23e3979f55f0eba0db8fd2828898d37046ff7ba255ec8e9226da6a3`,
four `RemotePoolRemoved`). Step 01h used to stop on such a lane. It now sorts the old pool's chains
in two and checks both sets against `target.json`: `.migration.hub.expectedLanes` (Bitlayer, 0G,
Monad, MegaETH, Robinhood) is taken over by the hub, `.migration.hub.disconnectedLanes` (Ink, Plasma,
Jovay, Abstract) stays in the old pool. The status sections above describe runs made while all nine
chains had a remote pool.

Run `disconnected-lanes-20261111-03` (`just wsteth-rehearse mainnet`) on fresh anvil forks pinned at
Ethereum block 26391724 and Base block 56051276, the complete pipeline:

| Layer | Result |
| --- | --- |
| Step 01h (`hub-inventory`) | five lanes with a remote pool and four without, both equal to the target's lists; accounting closed exactly: balance 18 306,365980370653147629 wstETH = unsiloed 18 261,754298306840706982 + silos 44,611682063812440647 (Bitlayer 0,105063567385275758, 0G 0,013044622506851971, Robinhood 44,493573873920312918), unaccounted 0; lockbox groups: shared (Monad, MegaETH), Bitlayer, 0G, Robinhood |
| Step 05h (`hub-cutover`) | preflight held: the hub served exactly the five lanes; pause proposal `0x1b5b4acc720b71bcdea606ec7d23667869283264ca067169acd6376961f92a0f` (1 call) and cutover proposal `0x343c121a8aa329e5e622f399be038be3ef8a2786664e2246b9646b901a19904f` (12 calls, predecessor = the pause) through the Chainlink timelock; every invariant held |
| Hub checkpoint (`test-hub`) | 9 scenarios passed, the 3 Base-lane scenarios skipped as designed |
| `RealHubMigration.t.sol`, `RealBaseMigration.t.sol` | 15 scenarios passed; the cutover scenario now also asserts that the hub does not serve the four disconnected chains |
| Step 08 (`verify-state`) | 299 state-mate checks passed, 9 delegated table checks passed |

Not rehearsed, as before: the spoke chains are not forked, so the five spokes' remote-pool additions
and outbound pauses, the queue drain, DON delivery and MCMS signatures stay outside the run. The
Sepolia line was not rerun: `just wsteth-rehearse sepolia` stopped before its first pipeline step on a
certificate error of the public Monad testnet endpoint; its target declares no disconnected lanes and
the unit tests of the orchestration (180) pass.

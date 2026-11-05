# Base migration, one DAO vote: on-chain actions, in order

> Designed 2026-10-26; brought in line on 2026-10-31 with the Chainlink hub cutover decided on 2026-10-30 ([hub migration plan](../CHAINLINK_HUB_MIGRATION_FORK_PLAN.md)). Sections 1.1, 1.2 and 4 and the timer recommendation changed; sections 1.3–1.8, 2 and 3 are the 2026-10-26 design, implemented on 2026-10-28. The 2026-11-03 revision separates hub and Base preparation and accepts hub administration through MCMS. The [target README](../README.md) records the rehearsals. This document does not establish mainnet readiness.

Date: 2026-10-26, revised 2026-11-03 (separate hub and Base preparation). Scheme: one Aragon vote, then two permissionless time-gated calls
per bridge (`activate()`, `close()`), the Base lane `ERC20LockBox` as the single backing for both
withdrawal paths, no reserve and no drain period. Before the vote, Chainlink moves the token's
Ethereum registry entry and the custody of its nine existing lanes to the Lido hub pool (section 1.2).
Interactive version: https://claude.ai/artifact/8oxJtiWkRQYxPvt1B2ekn9.
Sources: `orchestration/wsteth-ccip/script/{01_hub_inventory,04_ccip_deploy,05_ccip_configure,05_hub_cutover,05c_hub_connect_lane,06_migration_upgrade,07_set_pool_gov}.sh`,
`script/migration/MigrationBase.s.sol`, `components/ccip` `lido-hvmv/script/deployment/{1_Deploy,2_Configure,3_SetPoolAndTransferOwnership,4_ConnectLane}.s.sol`,
`components/l2-bridge-migration/contracts/optimism/{CCIPMigrationSender,L1MigrationBridge,L2MigrationBridge}.sol`.
Calls marked **new** are the ones section 3 added to the bridges (implemented 2026-10-28).
View calls omitted. Each group is one executor's consecutive actions; the vote is one group with the
Base part (the action set queued at `OptimismBridgeExecutor`, relayed by OP, executed by anyone,
delay 0) as its sub-item.

Timers, all set by the vote as absolute timestamps: T₀ = vote execution, T_L1 ≥ T₀ + 48 h (the
checkpoint, the action set's 24-hour grace period and the Emergency Brakes reaction), T_Base ≥ T_L1 +
1 day, T_close ≥ T_Base + 10 days (recommended values; the rehearsal uses 1 day, 1 day and 10 days).
The bridges only require `activateAt` in the future and `closeAt` after it; contract minimums of 48 h
and 10 days, so that a late vote reverts whole, are proposed and not implemented.

## 1. Upgrade path

### 1.1. Chainlink deployer, Ethereum: prepare the nine existing lanes

- Read the old pool at one pinned block: lanes, silo balances, rebalancers, remote pools/tokens and limits.
- Deploy the hub, hooks, LidoTimelock, CallProxy and four lockboxes: shared, Bitlayer, 0G, Robinhood.
- Configure exactly the nine imported lanes with their existing limits and verification policy; authorize the hub on their lockboxes. Base remains deferred. No Base lockbox, verifier/resolver or bridge/token implementation is deployed yet.
- Transfer ownership to LidoTimelock and accept via the deployer's temporary admin role; configure blocked selectors and MCMS proposer/canceller roles.
- Grant Agent ADMIN_ROLE and revoke the deployer's role. Further Ethereum operations use governance.

### 1a. Chainlink: migrate the existing directions and accept registry administration

The cutover uses Chainlink's RBACTimelock `0x44835bBBA9D40DEDa9b64858095EcFB2693c9449`.
Registry acceptance uses a Chainlink MCMS proposal through the new LidoTimelock.
Procedure, checks and recovery: [hub migration plan](../CHAINLINK_HUB_MIGRATION_FORK_PLAN.md).
- **2a. Spoke pool owners, nine chains**: `TokenPool.addRemotePool(5009297550715157269, abi.encode(SiloedLockReleaseTokenPool))`, the old pool kept; outbound pause on each spoke pool; the spoke → Ethereum queue drains
- **2b. RBACTimelock, proposal 1, 3 h delay**: `SiloedLockReleaseTokenPool(0xA586a732394A1AFfCF15b972cd47C936033C9FA7).setChainRateLimiterConfigs([nine selectors], outbound {isEnabled: true, capacity: 2, rate: 1}, inbound unchanged)` — the smallest limiter the 1.6.0 pool accepts
- **2c. RBACTimelock, proposal 2, one batch, predecessor = proposal 1, 3 h delay**; amounts are the pool's accounting at the pinned block:
  1. `SiloedLockReleaseTokenPool(0xA586a732394A1AFfCF15b972cd47C936033C9FA7).withdrawLiquidity(unsiloed)`
  2. `withdrawSiloedLiquidity(4426351306075016396, silo 0G)`
  3. `withdrawSiloedLiquidity(6180753054346818345, silo Robinhood)`
  4. `setSiloRebalancer(7937294810946806131, RBACTimelock)`
  5. `withdrawSiloedLiquidity(7937294810946806131, silo Bitlayer)`
  6. `setSiloRebalancer(7937294810946806131, 0x2728df4D22253004C017675bd609962cD641D797)`
  7. `wstETH.transfer(shared lockbox, unsiloed)`
  8. `wstETH.transfer(Bitlayer lockbox, silo Bitlayer)`
  9. `wstETH.transfer(0G lockbox, silo 0G)`
  10. `wstETH.transfer(Robinhood lockbox, silo Robinhood)`
  11. `TokenAdminRegistry.setPool(wstETH, SiloedLockReleaseTokenPool)` — displaces `0xA586a732394A1AFfCF15b972cd47C936033C9FA7`; the hub serves exactly its nine lanes at this moment
  12. `TokenAdminRegistry.transferAdminRole(wstETH, LidoTimelock)`
- **2d. Chainlink MCMS**: propose `TokenAdminRegistry.acceptAdminRole(wstETH)` in LidoTimelock; after its 3-day delay execute through CallProxy. Check administrator = LidoTimelock, pending administrator = zero, deployer ADMIN_ROLE absent. No DAO vote is needed for this acceptance.
- Restore agreed spoke limits and verify each direction before starting Base preparation. The current fork target verifies only the Ethereum pool boundary; nine spoke forks, message queue drain and DON delivery are not included.

### 1.2. Prepare Base after the hub checkpoint passes

- Run `test-hub`: verify nine lanes, custody, governance acceptance and the absence of Base contracts. Failure stops the next deployment.
- Deploy Base's BurnMintTokenPool, hooks, verifier/resolver, LidoTimelock and CallProxy.
- On Ethereum deploy only the Base lockbox and verifier/resolver. Authorize the existing hub on the new lockbox; initialize the resolver. Nominate the existing LidoTimelock as owner of all three contracts and accept ownership through an MCMS proposal with the 3-day delay.
- Configure Base's lane to Ethereum and its CCV settings; accept Base ownership through the temporary deployer admin, grant ADMIN_ROLE to OptimismBridgeExecutor and revoke the deployer's role.
- Deploy the L1MigrationBridge implementation on Ethereum and ERC20BridgedPermit/L2MigrationBridge implementations on Base. No proxy is upgraded yet. All three addresses exist before the Base connection proposal.

### 1b. Chainlink: connect Base to the existing hub

- **2e. Chainlink MCMS, `LidoTimelock` proposal, 3-day delay, executed through `CallProxy` by anyone**, the Base lane on the hub (the batch `4_ConnectLane` builds):
  1. `SiloedLockReleaseTokenPool.applyChainUpdates([], [Base: BurnMintTokenPool, wstETH on Base, rate limits])`
  2. `SiloedLockReleaseTokenPool.applyTokenTransferFeeConfigUpdates([Base], [])`
  3. `SiloedLockReleaseTokenPool.configureLockBoxes([(15971525489660198786, Base lockbox)])`
  4. `PausableAdvancedPoolHooks.applyCCVConfigUpdates([Base])`
  5. `DummyMessageIdVerifier.applyRemoteChainConfigUpdates([Base])`
  6. `VersionedVerifierResolver.applyOutboundImplementationUpdates([Base → DummyMessageIdVerifier])`
- The vote is created after 2c–2e and the nine-lane check. `activate()` on L1 still checks the registry (section 1.4); a registry that does not bind the hub by T_L1 is a deviation, not the working path. Between 2e and the Base action set (section 1.3) a hub → Base send locks wstETH in the Base lockbox and waits until Base can mint; the schedule keeps this window short, or the lane is connected with a paused outbound limiter and opened afterwards (open mainnet option)

### 3. DAO vote, Aragon Agent, Ethereum, T₀
- `OssifiableProxy(L1 bridge).proxy__upgradeTo(L1MigrationBridge)` — new implementation starts in LEGACY, behaves as the old one
- `LidoTimelock.bypasserExecuteBatch([ERC20LockBox.applyAuthorizedCallerUpdates(added: [L1 bridge])])`
- `L1MigrationBridge.scheduleActivation(T_L1)` **new**
- `L1MigrationBridge.scheduleClose(T_close)` **new**
- `L1CrossDomainMessenger.sendMessage(OptimismBridgeExecutor, queue(action set A′))`
  - **Base, `OptimismBridgeExecutor`, action set A′, atomic, T₀ + minutes (checkpoint)**:
    1. `OssifiableProxy(wstETH).proxy__upgradeToAndCall(ERC20BridgedPermit, finalizeUpgrade_v3("2", OptimismBridgeExecutor))`
    2. `ERC20BridgedPermit.grantRole(MINTER_ROLE, L2 bridge)`
    3. `ERC20BridgedPermit.grantRole(BURNER_ROLE, L2 bridge)`
    4. `ERC20BridgedPermit.grantRole(MINTER_ROLE, BurnMintTokenPool)`
    5. `ERC20BridgedPermit.grantRole(BURNER_ROLE, BurnMintTokenPool)`
    6. `OssifiableProxy(L2 bridge).proxy__upgradeTo(L2MigrationBridge)`
    7. `RegistryModuleOwnerCustom.registerAccessControlDefaultAdmin(wstETH)`
    8. `TokenAdminRegistry.acceptAdminRole(wstETH)`
    9. `TokenAdminRegistry.setPool(wstETH, BurnMintTokenPool)`
    10. `TokenAdminRegistry.transferAdminRole(wstETH, LidoTimelock)`
    11. `LidoTimelock.bypasserExecuteBatch([TokenAdminRegistry.acceptAdminRole(wstETH), hooks.setPolicyEngine(L2 bridge)])` — accepts administration and installs the outbound activation gate atomically
    12. `L2MigrationBridge.scheduleActivation(T_Base)` **new**
    13. `L2MigrationBridge.scheduleClose(T_close)` **new**
- Checkpoint T₀ + minutes → T_L1: both bridges on new code in LEGACY, legacy transfers work both ways, CCIP deposits already land on Base (pool holds MINTER_ROLE, registry bound). Mainnet verification: proxy storage, legacy round trips, state-mate.
- **Emergency Brakes, if verification fails**: the Safe `0x73b047fe6337183A454c5217241D780a932777bD` calls `L1ERC20TokenBridge.disableDeposits()` on Ethereum, or the Safe `0x0F9A0e7071B7B21bc7a8514DA2cd251bc1FF0725` calls `L2ERC20TokenBridge.disableWithdrawals()` on Base. Blocks the activation below; re-enabling is Agent / OptimismBridgeExecutor only, i.e. a vote.
- Not in the vote yet, open: Direct Staking's adapter calls `depositERC20To` on the L1 bridge with a zero fee and reverts after the L1 activation; replacing it is `LidoCustomReceiver.setAdapter(baseChainSelector, newAdapter)` by the Agent, with an adapter that pays the CCIP fee.

### 4. Anyone, Ethereum, T_L1
- `L1MigrationBridge.activate()` **new** — guards: `block.timestamp ≥ T_L1`; mode LEGACY; `TokenAdminRegistry.getPool(wstETH) == SiloedLockReleaseTokenPool`; `isDepositsEnabled()`. Effect: mode MIGRATING, `safeTransfer(ERC20LockBox, balanceOf(this))` (whole escrow), then canonical messenger `sendMessage(L2 bridge, confirmL1Activation(), 200000)`. Both actions are atomic
- From here `depositERC20` / `depositERC20To` go through `Router.ccipSend` only; legacy deposits cannot be started. Legacy withdrawals from Base keep finalizing: `finalizeERC20Withdrawal` pulls the shortfall from `ERC20LockBox.withdraw(wstETH, baseChainSelector, shortfall, address(this))` (section 3)

### 5. Anyone, Base, T_Base
- `L2MigrationBridge.activate()` **new** — guards: `block.timestamp ≥ T_Base`; mode LEGACY; `TokenAdminRegistry.getPool(wstETH) == BurnMintTokenPool`; `isWithdrawalsEnabled()`; `isL1ActivationConfirmed()`. Effect: mode MIGRATING, opening the outbound pool policy gate
- From here `withdraw` / `withdrawTo` go through `Router.ccipSend` only (burn by `BurnMintTokenPool`, release by the hub pool from the lockbox filled in step 4). No new legacy transfer can be started in either direction. `finalizeDeposit` for legacy deposits stays open
- Before Base activation, deliver the canonical L1 confirmation; if delivery fails, retry it through the messenger. Only that messenger with the immutable L1 bridge as cross-domain sender can confirm activation. Base rejects activation without confirmation, and its hooks policy rejects every outbound pool send (including direct Router calls) until Base activates. The interval does not matter for CCIP deposits: they are token-only messages to the user, minted by the pool, the L2 bridge is not on that path

### 6. Lido operators, both chains, T_Base + ~6 days → T_close
Finalize every legacy transfer still in flight, for the whole history of the bridge; all calls are permissionless.
- Off-chain: list of unfinished legacy withdrawals = `L2CrossDomainMessenger.SentMessage` from the L2 bridge, minus those with `OptimismPortal.finalizedWithdrawals(hash) == true` and `L1CrossDomainMessenger.successfulMessages(hash) == true`
- `OptimismPortal.proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)` for each unproven withdrawal, once its game is resolved (~5 days)
- `OptimismPortal.finalizeWithdrawalTransaction(tx)` after `proofMaturityDelaySeconds` (1 day) → `L1CrossDomainMessenger.relayMessage` → `L1MigrationBridge.finalizeERC20Withdrawal` (lockbox-backed)
- `L1CrossDomainMessenger.relayMessage(…)` for every entry of `failedMessages` (withdrawals whose relay on L1 failed)
- `L2CrossDomainMessenger.relayMessage(…)` for every entry of `failedMessages` on Base (deposits whose relay failed) → `L2MigrationBridge.finalizeDeposit`
- Check: both lists empty; `escrow + lockbox − Base supply = 0`
- **Emergency Brakes, if the sweep is not finished by T_close**: `disableDeposits()` on the L1 bridge and `disableWithdrawals()` on the Base bridge. Blocks `close()`; cost is a pause of CCIP deposits and withdrawals until a vote re-enables them

### 7. Anyone, both chains, T_close
- `L1MigrationBridge.close()` **new** — guards: `block.timestamp ≥ T_close`; mode MIGRATING; `isDepositsEnabled()`. Effect: mode CCIP_ONLY, `finalizeERC20Withdrawal` reverts
- `L2MigrationBridge.close()` **new** — guards: `block.timestamp ≥ T_close`; mode MIGRATING; `isWithdrawalsEnabled()`. Effect: mode CCIP_ONLY, `finalizeDeposit` reverts, then `ERC20BridgedPermit.renounceRole(MINTER_ROLE, address(this))`, `ERC20BridgedPermit.renounceRole(BURNER_ROLE, address(this))`
- End state: both bridges send and receive through CCIP only, the OP messenger is no longer trusted, wstETH on Base is minted and burned by `BurnMintTokenPool` only, the whole backing is in `ERC20LockBox`

### 8. DAO, any later vote, hygiene
- `LidoTimelock.bypasserExecuteBatch([ERC20LockBox.applyAuthorizedCallerUpdates(removed: [L1 bridge])])` — in CCIP_ONLY the bridge never calls the lockbox; only the lockbox owner can drop the authorization

## 2. Rollback

### A. Activation blocked (Emergency Brakes flag off, or, against section 1.2, the registry entry not bound to the hub by T_L1)
- No on-chain action is needed to stay safe: `activate()` reverts, both bridges remain on new code in LEGACY, legacy transfers keep working, the escrow stays in the bridge
- To resume after a flag was switched off: **DAO vote** `L1ERC20TokenBridge.enableDeposits()` (Agent) or, via `sendMessage` + `OptimismBridgeExecutor`, `L2ERC20TokenBridge.enableWithdrawals()`; then anyone calls `activate()` again
- To abandon: **DAO vote** `OssifiableProxy(L1 bridge).proxy__upgradeTo(old L1ERC20TokenBridge)` and action set with `OssifiableProxy(L2 bridge).proxy__upgradeTo(old L2ERC20TokenBridge)`; token upgrade and pool roles may stay

### B. Late legacy deposit L1→Base after `close()` (Base bridge in CCIP_ONLY, roles renounced)
1. **DAO vote, Aragon Agent, Ethereum**: `L1CrossDomainMessenger.sendMessage(OptimismBridgeExecutor, queue(action set R-Base))`
   - **Base, `OptimismBridgeExecutor`, action set R-Base**:
     1. `L2MigrationBridge.switchBridgeMode(MIGRATING)`
     2. `ERC20BridgedPermit.grantRole(MINTER_ROLE, L2 bridge)`
     3. `ERC20BridgedPermit.grantRole(BURNER_ROLE, L2 bridge)`
2. **Anyone, Base**: `L2CrossDomainMessenger.relayMessage(...)`, replay of the failed message; `finalizeDeposit` mints to the recipient
3. **DAO vote, Aragon Agent, Ethereum**: `sendMessage(OptimismBridgeExecutor, queue(action set C))`
   - **Base, `OptimismBridgeExecutor`, action set C**: `L2MigrationBridge.switchBridgeMode(CCIP_ONLY)`, `ERC20BridgedPermit.revokeRole(MINTER_ROLE, L2 bridge)`, `ERC20BridgedPermit.revokeRole(BURNER_ROLE, L2 bridge)`

### C. Late legacy withdrawal Base→L1 after `close()` (L1 bridge in CCIP_ONLY)
1. **DAO vote, Aragon Agent, Ethereum**: `L1MigrationBridge.switchBridgeMode(MIGRATING)` — enough on its own, the bridge is still an authorized caller of the lockbox and funds the withdrawal from it (step 8 not done); if step 8 was done, add `LidoTimelock.bypasserExecuteBatch([ERC20LockBox.applyAuthorizedCallerUpdates(added: [L1 bridge])])`
2. **Anyone, Ethereum**: `L1CrossDomainMessenger.relayMessage(...)`, replay of the failed message
3. **DAO vote, Aragon Agent, Ethereum**: `L1MigrationBridge.switchBridgeMode(CCIP_ONLY)`

Steps 1 and 3 of B and C can be one omnibus only if the replay between them is guaranteed; otherwise two votes. Step 6 exists so that B and C never happen.

## 3. Contract changes in `components/l2-bridge-migration` (implemented 2026-10-28)

- `CCIPMigrationSender` (shared): `scheduleActivation(uint256)` (admin, once, in LEGACY, future), `scheduleClose(uint256)` (admin, once, after the activation is scheduled, later than it); `activate()` and `close()` permissionless, one-shot (`isActivated()`, `isClosed()`), with the guards above: timer, mode, `ccipTokenAdminRegistry.getPool(token) == ccipTokenPool` (activate only), the chain's send switch on (`ErrorSendsDisabled`); both timestamps, both flags and the L1-confirmation flag packed in the ERC-7201 slot next to the mode; events `ActivationScheduled`, `CloseScheduled`, `Activated`, `Closed`. `switchBridgeMode` stays admin-only for rollbacks and never re-arms the two steps. Constructor gains `tokenAdminRegistry_`, `tokenPool_` (immutables).
- `L1MigrationBridge`: constructor gains `lockBox_` (immutable `ccipLockBox`); `activate()` moves the whole escrow to the lockbox by plain transfer (`EscrowMigrated`); `finalizeERC20Withdrawal` in MIGRATING draws `amount − balanceOf(this)` from `ERC20LockBox.withdraw(wstETH, baseChainSelector, shortfall, address(this))` before paying (`EscrowReplenished`), after repeating the legacy checks so nothing is drawn for a call the inherited function would reject; the send switch is `isDepositsEnabled()`; `migrateLiquidity` / `migrateLiquidityKeepReserve` removed.
- `L2MigrationBridge`: `close()` calls `renounceRole(MINTER_ROLE, this)` and `renounceRole(BURNER_ROLE, this)` on the token after the mode switch (`TokenRolesRenounced`); the send switch is `isWithdrawalsEnabled()`.
- No change to `ERC20LockBox`, pools or token: lockbox `withdraw` is balance-based, ignores the selector and checks only the authorized-caller list; `renounceRole` is standard AccessControl.
- Unit tests: 62 (`forge test --root components/l2-bridge-migration --offline`), with doubles for the lockbox and the registry. Fork smoke test (`FOUNDRY_PROFILE=fork`): both live proxies upgraded and driven through schedule → activate → close; records that Base's registry has no wstETH entry today, so the Base `activate()` guard cannot be met before the lane is registered.

## 4. Rehearsal (`targets/wsteth-base-migration-mainnet`)

For this hub target the order is `migration-inputs` → `hub-inventory` → `hub-prepare`
→ `hub-cutover` → `hub-accept-admin` → `base-prepare` (starts with `test-hub`)
→ `hub-connect-lane` → `migration-upgrade` → `test-scenarios` → `verify-state`.
The [target README](../README.md) maps every recipe to the Explainer. Non-hub in-place targets
retain their existing pipeline. Governance proposers and the OP messenger are impersonated;
delays are advanced on isolated Anvil forks. MCMS signatures, nine remote spoke pools, their
queues and DON transport are outside this rehearsal.

`RealHubMigration.t.sol` has 12 tests. At the hub-only checkpoint, three Base-dependent tests
are skipped because those contracts do not exist yet. It checks custody, nine lane mappings,
pool-boundary locking/releasing and isolation, paused old-pool limiters, unchanged imported
CCV policy, completed cutover and registry-acceptance proposals, replay rejection and revoked
deployer administration. After Base connection all 12 tests run, including Base isolation and
its proposal. The two Base scenario tests then exercise the lifecycle and governance levers.

`test/scenario/RealBaseMigration.t.sol`, `test_runbook_one_vote`, transfer kinds in flight and where each finalizes:

| Kind | Started | Finalized | Mode at finalization |
| --- | --- | --- | --- |
| D1, W1 | old implementations (step 06) | T₀ checkpoint | LEGACY / LEGACY |
| d0, w0 | checkpoint | checkpoint | LEGACY / LEGACY |
| d2 | checkpoint | after L1 `activate()` | Base LEGACY |
| w2 | checkpoint | after L1 `activate()` | L1 MIGRATING, paid from the lockbox |
| d4 | checkpoint | after Base `activate()` | Base MIGRATING |
| d3 | checkpoint; first relay gas-starved (failedMessages) | sweep replay | Base MIGRATING |
| w3 | after L1 `activate()` (Base LEGACY); first relay gas-starved | sweep replay | L1 MIGRATING, lockbox |
| dLate | checkpoint | after `close()`: fails, rollback B, replay, forward | Base CCIP_ONLY → MIGRATING → CCIP_ONLY |
| wLate | checkpoint | after `close()`: fails, rollback C, replay from the lockbox, forward | L1 CCIP_ONLY → MIGRATING → CCIP_ONLY |
| CCIP deposit | after L1 `activate()` (Base LEGACY) and after `close()` | pool mint on Base | — |
| CCIP withdrawal | after Base `activate()` and after `close()` | lockbox release on L1 | — |

At every gate: too-early revert, the Emergency Brakes veto (`disableDeposits` on L1 / `disableWithdrawals` on Base) and its lifting by the Agent / an executor action set, the registry-pool guard (mocked mismatch), one-shot re-entry reverts; after the close, the roles renounced on Base, the lockbox hygiene (authorization dropped, a rollback alone no longer funds a legacy withdrawal); conservation `escrow + lockbox − Base supply − in flight` asserted after every step, together with the unchanged balances of the hub's four other lockboxes (since 2026-10-31): no Base activation, replay, rollback or close draws on the nine lanes' custody.

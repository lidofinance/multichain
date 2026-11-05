# L2 bridge migration

Replacement implementations for the lido-l2 OP-stack bridges behind the Base and Ethereum proxies,
adding the CCIP migration mode switch of [original migration PRD](docs/2026-01-09-base-migration-prd.md). Contracts, unit tests and a
fork smoke test: no deployment script, governance batch or audit lives here yet. Nothing from this
component is deployed.

## Provenance

Upstream: `lidofinance/lido-l2` at `082e7eb59de63bd376b30886568813408d04f00b`, the source the ledger
records for the Base fleet (`base-base-l2-token-bridge`, `base-ethereum-l1-token-bridge`, Diffyscan
exact match). `provenance.json` lists the upstream sha256 of each copied file and its modifications;
[dated upstream diff](docs/2026-10-21-upstream.diff) records the initial edits to the eight imported files; new migration contracts are listed separately below.

| File | Status vs upstream |
| --- | --- |
| `BridgeableTokens.sol`, `optimism/CrossDomainEnabled.sol`, `optimism/interfaces/ICrossDomainMessenger.sol` | verbatim except the pragma |
| `BridgingManager.sol` | `_setupRole` → `_grantRole` (OpenZeppelin 5), plus `_lockInitialization()` for implementation constructors |
| `optimism/interfaces/IL1ERC20Bridge.sol`, `IL2ERC20Bridge.sol` | send functions declared `payable` (CCIP native fee) |
| `optimism/L1ERC20TokenBridge.sol` | send functions `payable`; `finalizeERC20Withdrawal` and `_initiateERC20Deposit` `virtual`; `Address.isContract` → `msg.sender.code.length > 0` |
| `optimism/L2ERC20TokenBridge.sol` | send functions `payable`; `finalizeDeposit` and `_initiateWithdrawal` `virtual`; token calls `bridgeMint`/`bridgeBurn` → `mint`/`burnFrom` (`IL2MintBurnToken`) |
| `optimism/CCIPMigrationSender.sol`, `L1MigrationBridge.sol`, `L2MigrationBridge.sol`, `interfaces/IL2MintBurnToken.sol` | new |

Compiler baseline is the repository's (OpenZeppelin 5.0.2, solc 0.8.26, `paris`), not upstream's
(OpenZeppelin 4.6.0, solc 0.8.10). The deployed proxies keep their storage: `AccessControl._roles`
at linear slot 0 has the same `RoleData` shape in both editions (`mapping(address => bool)`,
`bytes32 adminRole`), the `BridgingManager` state stays at `keccak256("BridgingManager.bridgingState")`,
and the new mode lives in the ERC-7201 namespace `lido.storage.CCIPMigrationSender`.
`forge inspect` shows `_roles` at slot 0 as the only linear variable of both implementations; the
unit tests assert that slots 0–63 stay empty through every mode.

## Behaviour of the upgraded proxies

| Mode | Sends (`deposit*` on L1, `withdraw*` on L2) | Legacy receives (`finalizeERC20Withdrawal`, `finalizeDeposit`) | L1 backing |
| --- | --- | --- | --- |
| `LEGACY` (zero, what an upgraded proxy starts in) | OP messenger, as deployed; `msg.value` rejected | allowed | the escrow held by the bridge |
| `MIGRATING` | CCIP Router, token-only message, `msg.value ≥ getCCIPFee(to, amount)`, excess refunded | allowed; on L1 paid from the escrow, drawing the shortfall from the lane `ERC20LockBox`; on L2 minted by the bridge | the lane lockbox (the escrow moved there by `activate()`) |
| `CCIP_ONLY` | CCIP Router | revert `ErrorBridgeModeNotAllowed` | the lane lockbox |

### One vote, two timers, two permissionless steps

The forward path LEGACY → MIGRATING → CCIP_ONLY is driven by a schedule the admin sets once, in
the same governance batch that upgrades the proxy:

| Call | Who | Guards | Effect |
| --- | --- | --- | --- |
| `scheduleActivation(T_activate)` | admin, once | LEGACY; `T_activate` in the future | arms `activate()` |
| `scheduleClose(T_close)` | admin, once | activation scheduled; `T_close > T_activate` | arms `close()` |
| `activate()` | anyone, once | `block.timestamp ≥ T_activate`; LEGACY; `ccipTokenAdminRegistry.getPool(token) == ccipTokenPool`; the send switch on; L2: authenticated L1 activation confirmation received | MIGRATING; L1: whole escrow → `ccipLockBox` (`EscrowMigrated`), then sends `confirmL1Activation()` through the canonical messenger |
| `close()` | anyone, once | `block.timestamp ≥ T_close`; MIGRATING; the send switch on | CCIP_ONLY; L2: `renounceRole(MINTER_ROLE / BURNER_ROLE, this)` on the token (`TokenRolesRenounced`) |

- The send switch is `isDepositsEnabled()` on L1 and `isWithdrawalsEnabled()` on L2: the Emergency
  Brakes hold the disabler roles on the deployed bridges, so they can veto either step without a
  vote (`ErrorSendsDisabled`); only the admin (Aragon Agent / OptimismBridgeExecutor, enabler roles)
  lifts the veto. The registry guard keeps the L1 activation from running until the token's
  Ethereum registry entry binds the hub pool; in the plan Chainlink's cutover does that before the
  vote is created, so the guard is a check, not the expected wait.
- Base pool hooks use the L2 bridge as their policy engine, installed atomically with pool
  registration and roles. Every outbound pool preflight, including a direct Router call, requires
  `isActivated()`. Activation requires the canonical messenger to deliver `confirmL1Activation()`
  from the immutable L1 bridge. A timer alone cannot bypass an L1 veto or a delayed/failed relay.
  Retry failed confirmation messages through the canonical messenger before activating Base.
  L1 escrow transfer and confirmation submission are atomic; inbound pool mints remain available.
  Future L2 bridge upgrades must retain this policy interface or replace the hooks policy in the
  same governance batch; removing an interface that the hooks call would stop pool transfers.
- `switchBridgeMode` stays admin-only for rollbacks: any transition between distinct modes, and it
  never re-arms `activate()` or `close()` (`isActivated()` / `isClosed()`), so a rollback cannot be
  undone by a stranger. `requireBridgeMode` is a view precondition for governance batches.
- L1 lockbox backing: `activate()` moves the escrow by plain transfer (the lockbox counts balance);
  `finalizeERC20Withdrawal` in MIGRATING draws `amount − balanceOf(this)` through
  `ERC20LockBox.withdraw(token, selector, shortfall, this)` (`EscrowReplenished`) after repeating
  the legacy checks, so nothing is drawn for a call the inherited function rejects. This needs the
  bridge on the lockbox's authorized-caller list (the lockbox owner adds it in the vote and may drop
  it after the close). In LEGACY the lockbox is never touched: a rollback to LEGACY after activation
  leaves legacy withdrawals unfunded until the admin returns liquidity or goes forward again.
- The admin role is the Aragon Agent on L1 and the OptimismBridgeExecutor on Base (both verified
  on-chain 2026-10-21); the registry, pool and lockbox addresses are constructor immutables.
- The deployed events `ERC20DepositInitiated` / `WithdrawalInitiated` are emitted on both transports,
  so indexers keep seeing sends; the CCIP transport adds `CCIPTransferInitiated(messageId, from, to,
  amount, fee)`.
- The CCIP message is token-only: `data_` and the gas argument keep their deployed meaning (emitted,
  never executed or forwarded), there is no `ccipReceive` on either side, and the bridge never relays a
  caller-chosen payload under its own address. Out-of-order execution is allowed.
- The CCIP path pulls the tokens from the caller (`safeTransferFrom`), so L2 withdrawals need an
  allowance to the bridge. The legacy burn path never did; with the roles-only token, LEGACY-mode
  withdrawals need the allowance too (`burnFrom`). Integrators must be told before the upgrade.
- The fee quote moves between blocks: pay a margin. The excess is refunded to the caller, so a
  contract caller that overpays has to accept ether, or the send reverts.
- The `BridgingManager` switches (`disableDeposits`, `disableWithdrawals`) still gate the CCIP sends.
- Implementation constructors call `_lockInitialization()`, so `initialize` cannot be used against
  the implementation address itself.

## Token side (Base wstETH proxy)

`components/wsteth-token/ERC20BridgedPermit` is the replacement token implementation. For this
migration it gained `burnFrom` (BURNER_ROLE, allowance based), the lido-l2 `increaseAllowance` /
`decreaseAllowance` pair for ABI parity, and `finalizeUpgrade_v3(version, admin)`, callable only by
the proxy admin from `proxy__upgradeToAndCall`. The fresh four-argument `initialize` refuses a proxy
whose metadata is already stored, so it cannot seat an administrator on a fleet proxy either. The L2
bridge mints in `finalizeDeposit` and burns through `burnFrom` in legacy withdrawals, so it needs
`MINTER_ROLE` and `BURNER_ROLE` during `LEGACY` and `MIGRATING`; the bridge renounces them itself in
`close()`, which makes "bridgeMint reverts in CCIP_ONLY" hold on the token as well as on the bridge.

## Sequencing constraints for the governance batches

- The Base action set is one atomic `OptimismBridgeExecutor` action set: token
  `proxy__upgradeToAndCall(impl, finalizeUpgrade_v3("2", executor))`, `grantRole(MINTER_ROLE, bridge)`,
  `grantRole(BURNER_ROLE, bridge)`, bridge `proxy__upgradeTo(L2MigrationBridge)`, then the registry
  work, `hooks.setPolicyEngine(L2 bridge)` through the timelock, and the two `schedule*` calls. Split, the old bridge calls `bridgeMint` the new token no longer
  has, or the new bridge calls `mint` without the role; relays fail (replayable on the OP messenger)
  and withdrawals revert in between.
- Legacy sends are possible only in LEGACY, so after `activate()` on both chains no new legacy
  transfer can start. `CCIP_ONLY` closes the receive side; the OP messengers record failed relays and
  allow replay, so a legacy transfer that is still in flight at `close()` is delayed, not lost, and
  needs a rollback vote (`switchBridgeMode(MIGRATING)`, on Base plus the roles) to finalize. Hence
  the order the timers must encode: `T_L1 < T_Base`, plus actual delivery of the L1 activation confirmation (the
  contract enforces funded L1 activation before Base can start CCIP withdrawals) and `T_close` far enough after `T_Base` for the operators to prove, finalize
  and replay every legacy transfer that users left behind (L2→L1 on Base: the dispute game's
  resolution plus the 1-day proof maturity delay, about 5 days in practice, not verified).
- The L1 bridge must be on the lane lockbox's authorized-caller list before `activate()`; otherwise
  the first lockbox-backed legacy withdrawal fails at the messenger (replayable) until it is added.

## Tests

`forge test --root components/l2-bridge-migration --offline` (62 tests, no network): each facade is
deployed behind an `OssifiableProxy` double that first ran the legacy implementation, then upgraded
in place. Doubles under `test/doubles/`: the proxy (OpenZeppelin 5 `ERC1967Proxy` with the `proxy__*`
admin entrypoints), the OP messenger (records sends), the CCIP Router (quotes a fee, pulls the
tokens, records the message field by field, keeps the whole `msg.value` like the real one), a
roles-based L2 token, the lane lockbox (authorized callers, balance-based `withdraw`), the token
admin registry (`getPool`). Covered: constructor and implementation locks, storage continuity and
the packed ERC-7201 slot, every mode's send and receive path, the exact legacy message calldata and
the exact CCIP message (receiver, token amount, fee token, `GenericExtraArgsV2`), fee checks and
refunds (including a contract caller that cannot receive ether), the `BridgingManager` gates, the
schedule rules, every `activate()` / `close()` guard and their one-shot nature, the escrow move,
the lockbox-backed withdrawals (shortfall only, caller checked before drawing, unfunded and
unauthorized lockbox), the roles renounced on close, rollbacks and the unfunded-rollback hazard. Regression tests also
cover authenticated confirmation, duplicate delivery, pool policy checks, and atomic rollback
when submitting the L1 confirmation fails.

`FOUNDRY_PROFILE=fork forge test --root components/l2-bridge-migration -vv` (`test-fork/`, needs
RPC access; `BASE_RPC` / `ETH_RPC` override the public endpoints): upgrades the live Base token and
bridge proxies and the live Ethereum escrow proxy on forks and drives them through schedule →
`activate()` → `close()` with the real Chainlink Router and TokenAdminRegistry (the L1 bridge is
built against the pool the registry binds today, so the activation guard can be met; the lane
lockbox is a double). Two live facts it records (2026-10-21): Base has no TokenAdminRegistry entry
for wstETH, so the Base `activate()` guard cannot be met before the lane is registered; and
Chainlink's wstETH L1 pool rejects Base with `ChainNotAllowed`, so the lane must be configured
before `MIGRATING` is usable. Test accounts use unique labels because Foundry's
`makeAddr("user")` carries an EIP-7702 delegation on mainnet and is not an EOA.

## Review (2026-10-21)

Independent read of the contracts after the first draft. Changed as a result: the token's fresh
`initialize` now refuses stored metadata (it could seat an administrator on a fleet proxy between a
plain upgrade and `finalizeUpgrade_v3`); the deployed events are emitted on the CCIP transport too;
the CCIP message is token-only (the first draft forwarded `data_` and the gas argument, which would
have made the bridge an open CCIP relay under its own address). Documented rather than changed: the
in-flight hazard of `CCIP_ONLY`, the refund-to-contract behaviour, the single-action-set requirement,
the unbound sweep receiver, and OpenZeppelin 5's custom-error reverts replacing 4.6's strings on the
admin functions.

## Open before any deployment

Pool-layer binding of the sweep receiver and the hub pool itself; Base TokenAdminRegistry entry
for wstETH (none today) and the L1 pool's Base remote-chain configuration (Chainlink's L1 pool
rejects Base with `ChainNotAllowed` today); the governance batches with the sequencing above; the
in-flight accounting that sizes the reserve; whether LEGACY-mode withdrawals may require an
allowance or the token should give the legacy bridge a privileged burn instead; an audit. (Fresh
token deployments report contract version 3 since 2026-10-25, the same as the upgraded fleet.)

## Build

```sh
forge build --root components/l2-bridge-migration --offline
forge test --root components/l2-bridge-migration --offline
forge inspect --root components/l2-bridge-migration --offline \
  contracts/optimism/L2MigrationBridge.sol:L2MigrationBridge storage-layout
```

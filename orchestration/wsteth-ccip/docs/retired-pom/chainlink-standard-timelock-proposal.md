# Proposal for Lido's Standard Timelock Using Chainlink's RBACTimelock

**A proposal from Chainlink to Lido.** The code is in [PR #45](https://github.com/smartcontractkit/ccip-contract-examples-internal/pull/45) (branch `lido-2.0-rbac`, commit `63edec4`; under review, not merged yet).

## A Preamble

Over the last months we have worked together to define in exact detail [Lido’s governance levers](https://github.com/smartcontractkit/ccip-contract-examples-internal/blob/a1a1fa6d1198b5f0c8d894b16eeac8ba637f602e/lido-levers.md) by thinking through the implementation and configuration of the Pausing Hook + the PoolOpsManager(POM).
Over the last weeks, Chainlink Operations Engineers have taken a look at the proposal, found merit in it.  It was decided that it would be easier to integrate for Lido, and perhaps beyond, if we moved from the POM to a Chainlink RBACTimelock extended to support all functionality described in the lido-levers md.

The document below describes this [PR](https://github.com/smartcontractkit/ccip-contract-examples-internal/pull/45), which swaps out the POM for an [extended RBACTimelock](https://github.com/smartcontractkit/ccip-contract-examples-internal/blob/63edec4b0be77349f3e4498af32b0925270df2e6/chains/evm/contracts/lido-hvmv/LidoTimelock.sol) and updates the [lido-levers](https://github.com/smartcontractkit/ccip-contract-examples-internal/blob/63edec4b0be77349f3e4498af32b0925270df2e6/lido-levers.md) to explain the change in the context of Lido’s governance decisions.

The suggested change is not intended to have any functional changes to the already agreed operational flows, it should only effect the interfaces used to operate.

## **In short**

On each chain, a timelock that Lido administers replaces the PoolOperationManager (POM). It's Chainlink's `RBACTimelock`, the timelock that already guards Chainlink's own CCIP contracts, used unchanged, plus a 102-line Lido extension that adds the POM's red button. Chainlink's multisig proposes. Lido's Emergency Brakes (EB) can cancel any single proposal, or halt the whole queue in one call; only the Lido DAO can restart it. Anyone can execute a ready proposal, through a CallProxy.

## **At a glance: the POM and the timelock**

|  | POM | Lido timelock |
| --- | --- | --- |
| **Code that guards the queue** | 628 lines of new, upgradeable code, reworked three times since September | Chainlink's `RBACTimelock`: in production for CCIP, not upgradeable, byte-for-byte unchanged |
| **New code to audit** | The whole POM (628 lines) | The extension (102 lines), and the hooks' new pause and unpause roles |
| **EB vetoes a single proposal** | No: only Chainlink's proposer can cancel | **Yes** |
| **Red button: kill everything pending and stop new proposals, in one call** | Yes (epoch) | Yes, with the same epoch mechanism |
| **Restart after the red button** | DAO only | DAO only |
| **A change with several steps (for example a new lane)** | One call per proposal, so it can end half-applied if one step is vetoed or fails | **One proposal can be a batch**, which executes completely or not at all |
| **How long a change waits** | Chainlink's own timelock, then the POM's delay | One wait: the minimum delay (3 days) |
| **What reviewers see** | The real call, wrapped inside `POM.propose(...)` | **Standard** `CallScheduled` **events**: every target and calldata in the clear, readable by existing timelock tools |
| **Who executes** | Anyone | Anyone, through the CallProxy |
| **Proposals that transfer ownership or upgrade** | Blocked | Blocked, and **role changes are blocked too** |
| **Instant pause** | EB and Chainlink, through the POM | EB, directly on the hooks contract |

## **1. What the contract is**

`LidoTimelock is RBACTimelock` ([LidoTimelock.sol](https://github.com/smartcontractkit/ccip-contract-examples-internal/blob/63edec4b0be77349f3e4498af32b0925270df2e6/chains/evm/contracts/lido-hvmv/LidoTimelock.sol)).

**The base: Chainlink's** `RBACTimelock` ([RBACTimelock.sol](https://github.com/smartcontractkit/ccip-contract-examples-internal/blob/63edec4b0be77349f3e4498af32b0925270df2e6/chains/evm/contracts/lido-hvmv/RBACTimelock.sol)). It's the contract from Chainlink's `ccip-owner-contracts` v0.2.1, the timelock that administers Chainlink's CCIP contracts. PR #45 copies it without changing a line. How it works:

- A proposer schedules a **batch** of calls (`scheduleBatch`) with a delay. The delay must be at least the minimum delay.
- When a batch is scheduled, every call in it is checked against a **list of blocked functions**. One blocked call rejects the whole batch.
- After the delay, an executor runs the batch (`executeBatch`). Every call succeeds, or the whole batch reverts. A batch can name a predecessor that must have executed first.
- A canceller can cancel any pending batch (`cancel`).
- The admin manages the roles, the minimum delay and the blocked list, and can execute calls immediately, without the queue (`bypasserExecuteBatch`). Nobody else can change any of these.

**The extension: the red button** (102 lines, written by Aphyla). It adds the POM's epoch:

- `haltProposalQueue()` (EB, or the DAO) moves the timelock to a new epoch and blocks new proposals.
- `scheduleBatch` is overridden: it reverts while the queue is halted, and records the epoch each proposal was scheduled in.
- `getTimestamp` is overridden: a pending proposal from an earlier epoch reads as never scheduled, so the timelock can't execute it. Nothing is looped over, so one call kills 2 pending proposals or 200,000 at the same cost. Executed proposals are unaffected.
- `restartProposalQueue()` (DAO only) allows new proposals again. Nothing from before the halt comes back.

#### **LidoTimelock.sol (excerpt)**

```solidity
function scheduleBatch(Call[] calldata calls, bytes32 predecessor, bytes32 salt, uint256 delay)
  public override onlyNotHalted
{
  super.scheduleBatch(calls, predecessor, salt, delay);
  s_epochOf[hashOperationBatch(calls, predecessor, salt)] = s_epoch;
}

/// Returns 0 for a pending operation from an earlier epoch, so the base timelock treats it as unscheduled.
function getTimestamp(bytes32 id) public view override returns (uint256) {
  uint256 timestamp = super.getTimestamp(id);
  return timestamp > _DONE_TIMESTAMP && s_epochOf[id] != getEpoch() ? 0 : timestamp;
}

function haltProposalQueue() external onlyRoleOrAdminRole(PROPOSAL_QUEUE_HALT_ROLE) onlyNotHalted {
  s_halted = true;
  uint248 newEpoch = ++s_epoch;
  emit ProposalQueueHaltedAtEpoch(newEpoch);
}

function restartProposalQueue() external onlyRole(ADMIN_ROLE) onlyHalted {
  s_halted = false;
  emit ProposalQueueRestarted(s_epoch);
}
```

**The hooks** ([PausableAdvancedPoolHooks.sol](https://github.com/smartcontractkit/ccip-contract-examples-internal/blob/63edec4b0be77349f3e4498af32b0925270df2e6/chains/evm/contracts/lido-hvmv/PausableAdvancedPoolHooks.sol)). The pause moves out of the governance contract and onto the hooks, which now have their own pause and unpause roles. EB holds the pause role; nobody holds the unpause role. The owner (the timelock) can also pause and unpause, so unpausing goes through a proposal or the DAO. Only the owner can grant or revoke these roles, and proposals can't call `grantRole` or `revokeRole`, so in practice only the DAO can change who may pause. Pausing works whatever state the queue is in.

## **2. What the CallProxy is**

`RBACTimelock` has no "anyone may execute" setting. (OpenZeppelin's timelock has one: the executor role granted to address 0.) The CallProxy is Chainlink's standard answer, the same contract Chainlink deploys next to its own timelocks ([CallProxy.sol](https://github.com/smartcontractkit/ccip-contract-examples-internal/blob/63edec4b0be77349f3e4498af32b0925270df2e6/chains/evm/contracts/lido-hvmv/CallProxy.sol); 38 lines, identical to `ccip-owner-contracts` v0.2.1).

- It is the timelock's **only executor**.
- It forwards any call, from anyone, to the timelock. The target is fixed when it's deployed.
- So anyone can call `executeBatch` through it once a proposal is ready. That's all it gives: it holds only the executor role, and the timelock still checks that the proposal is scheduled, in the current epoch, past its delay, and that its predecessor has executed.
- It refuses to forward `renounceRole`, so nobody can make it give up the executor role and leave the DAO as the only executor.

## **3. How it's set up**

One timelock per chain, as with the POM. The roles are set in [1_Deploy.s.sol](https://github.com/smartcontractkit/ccip-contract-examples-internal/blob/63edec4b0be77349f3e4498af32b0925270df2e6/chains/evm/contracts/lido-hvmv/script/deployment/1_Deploy.s.sol), and the settings in [default_config.json](https://github.com/smartcontractkit/ccip-contract-examples-internal/blob/63edec4b0be77349f3e4498af32b0925270df2e6/chains/evm/contracts/lido-hvmv/config/default_config.json).

| Role on the timelock | Holder | Can |
| --- | --- | --- |
| Admin | That chain's Lido DAO agent | Change roles, the minimum delay and the blocked list; restart after a halt; execute anything immediately |
| Proposer | Chainlink multisig | Schedule changes, with at least the minimum delay |
| Canceller | EB and the Chainlink multisig | Cancel any pending proposal |
| Queue halter | EB (the DAO can too, as admin) | The red button |
| Executor | The CallProxy, so anyone | Execute ready proposals |
| Bypasser | Nobody (the DAO can bypass as admin) | - |
- **Minimum delay:** 3 days.
- **Blocked for proposals:** `transferOwnership`, `upgradeToAndCall`, `grantRole`, `revokeRole`.
- **The timelock owns** the pool, the hooks, the lockboxes and the verifier resolver, and is the token's administrator in CCIP's TokenAdminRegistry.

**The deploy scripts:**

1. `1_Deploy` deploys the timelock (with the deployer as temporary admin) and the CallProxy, and makes the CallProxy the executor.
2. `2_Configure` configures the pool, blocks the four functions, then moves ownership of each contract to the timelock (two-step; the timelock accepts them all in one batch).
3. `3_SetPoolAndTransferOwnership` sets the pool in the TokenAdminRegistry and makes the timelock the token's administrator there. It then checks on-chain that ownership, every role holder, the CallProxy's target, the delay and the blocked list are as expected, and only then hands the admin role to the DAO. The deployer gives it up in the same step.

## **4. How it works**

```markdown
Chainlink multisig ──────────── propose, cancel ───┐
Lido Emergency Brakes (Safe) ── cancel, halt ──────┤
Anyone, via the CallProxy ───── execute ───────────┤
Lido DAO agent ──────────────── admin, restart ────┤
                                                   ▼
                     Lido timelock (minimum delay 3 days)
                                                   │ owns
                                                   ▼
      pool · hooks · lockboxes · verifier resolver · TokenAdminRegistry entry

Lido Emergency Brakes ── pause, instantly ──▶ hooks
```

- **A routine change** (say, a rate limit): Chainlink's signers approve it, and the multisig schedules it on Lido's timelock with a delay of at least 3 days. Every call is visible on-chain, in the clear, from that moment. EB reviews it. When the delay has passed, Chainlink executes it.
- **Lido disagrees with one change:** EB cancels that proposal. Everything else carries on.
- **Lido wants everything stopped** (for example, Chainlink's multisig is compromised and floods the queue): EB calls `haltProposalQueue()`. Every pending proposal is dead, and Chainlink can't propose anything more. To recover, a DAO vote restarts the queue. Chainlink re-proposes whatever is still wanted, and each proposal waits the full delay again.
- **An emergency on a lane or the whole bridge:** EB pauses instantly, on the hooks. Unpausing is a Chainlink proposal that waits 3 days (EB can veto it), or the DAO directly. EB should halt the queue at the same time: delays run from scheduling, so an unpause proposed more than 3 days earlier could otherwise be executed straight after the pause.
- **The DAO needs to act now:** as admin, it can execute anything immediately, as with the POM's `directCall`.

## **5. What Chainlink can and can't do**

**Chainlink can't, even by proposal** (the proposal is rejected when it's scheduled, or reverts):

- Transfer ownership of any contract, or upgrade one (blocked functions).
- Grant or revoke a role on any contract, for example who may pause the hooks (blocked functions).
- Change the timelock itself: unblock a function, lower the delay, change a role, restart after a halt. These need the admin role, which only the DAO holds; the timelock isn't its own admin.
- Touch the wstETH token: the DAO holds its admin and upgrade rights.
- Execute anything before the delay has passed, or anything from before a halt.

**Chainlink can, by a proposal that waits at least 3 days** (EB can cancel it or halt the queue). This is the day-to-day work, and the POM allowed the same:

| Contract | Changes |
| --- | --- |
| Pool | Rate limits; add or remove lanes and remote pools; transfer fee settings and fee withdrawal; finality settings; on Ethereum, which lockbox serves which lane |
| Hooks | Which verifiers (CCVs) are required, the threshold, the policy engine; pause and unpause |
| Verifier resolver | Which verifier each lane uses |

**Chainlink can also propose five changes that carry more weight.** The POM allowed them too, with a 14-day wait. Here they wait 3 days, like everything else:

- `TokenAdminRegistry.transferAdminRole` and `setPool`: hand the token's CCIP administration to another address, or point the token at another pool.
- The pool's `setDynamicConfig`: the router, which decides which ramps may lock, burn, release or mint; and a rate-limit admin and fee admin, who act without the timelock.
- The pool's `updateAdvancedPoolHooks`: replace the hooks, and the pause with them.
- The lockbox's `applyAuthorizedCallerUpdates`: add a caller, and a caller can withdraw the locked tokens.

The DAO can add any of these to the blocked list (one `blockFunctionSelector` call each). Only the DAO could then make those changes.

## **6. What changes compared with the POM**

| POM | Lido timelock | Notes |
| --- | --- | --- |
| Six sensitive functions wait 14 days | One minimum delay for everything: 3 days | Agreed with Lido |
| Proposals expire after 30 days | No expiry: a proposal stays executable until it's executed or cancelled | Chainlink executes as soon as a proposal is ready; EB or Chainlink can cancel anything stale, and the halt clears everything |
| Upgradeable (behind a proxy) | Not upgradeable | Nothing to secure on upgrades. A fix would mean a new timelock, with the DAO moving ownership to it |
| EB and Chainlink can pause and halt | EB pauses and halts; Chainlink can pause only through a proposal | In PR #45, the pause and halt roles are EB only |
| Only Chainlink's proposer can cancel | EB and Chainlink can cancel | In PR #45 |
| After a halt, a proposal needs a new salt to be proposed again | The same proposal can be scheduled again | In PR #45 |

**What stays the same:** the DAO as admin on each chain; the EB Safe; the red button, which kills every pending proposal in one call; only the DAO restarts; instant pause and slow unpause; ownership transfers and upgrades blocked for proposals; anyone can execute; the pool, lockbox and verifier setup.

## **7. Where it stands**

- **Lido and Aphyla:** PR #45 has the extension, the CallProxy, the hooks' roles and the deploy scripts. It has 77 tests: 33 for the timelock, 8 for the timelock with the hooks, and 36 for the hooks. It's under review, not merged yet. Still to do: put the extension into the audit in place of the POM.
- **Chainlink:** our day-to-day tooling already works with this kind of timelock. The deployment and handover tooling needs adapting.
- **Timing:** this only makes sense before the code and audit lock, so we're raising it now.

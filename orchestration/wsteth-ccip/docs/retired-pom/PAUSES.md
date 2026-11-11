# Pauses — what exists, who can pull each lever, and how it comes back

> **September 15 deployment:** use [Current deployment and POM permissions](CURRENT-DEPLOYMENT.md)
> and the [deployment report](deployment-2026-09-15.md). The detailed POM descriptions below
> are historical: proposal modes, guardian/veto/approval APIs and combined pause roles no longer apply.

Scope: the three pause flags this deployment actually owns, and, for every role and actor, which
pause and unpause actions it can reach — **directly** (its own role passes the gate) or
**indirectly** (through the `PoolOperationManager` proposal queue).

**The answer is chain-dependent.** One row of the selector filter differs between the L1 hub and
every non-L1 spoke: `unpause()` (`0x3f4ba83a`) is `Blocked` on L1 and **not** blocked on a spoke.
So `BRIDGE` restart is DAO-only on L1 and a 3-day MCMS proposal on a spoke. Every table below
carries that split; `config/README.md` § *The hub/spoke row* has the rationale.

Everything below was verified by execution against the Sepolia / Mantle-Sepolia forks on
2026-08-27, under `evm_snapshot`, on the deployment that `just fresh` produced (state-mate 392/392).

> **⚠ The spoke half of that record is stale as of 2026-09-01.** The `0x3f4ba83a` hub/spoke split
> post-dates the 2026-08-27 run, so the L2 rows below — the 3-day `BRIDGE` restart in particular —
> are read from the config and the contract source, **not** yet from an executed fork walk. The L1
> rows are unaffected. Re-running `just fresh && just verify-state` re-establishes the state-mate
> pins; the `BRIDGE`-restart walk in §5 still needs an `evm_snapshot` execution to become **E**.
Sources: `PoolOperationManager.sol:580-635`, `PausableAdvancedPoolHooks.sol:71-99`,
`config/state-mate/wsteth.yaml`. Companion docs: [`PERMISSIONS.md`](./PERMISSIONS.md) for the full
role matrix, [Roles & Levers](https://github.com/lidofinance/multichain/blob/main/docs/roles.html) for the reversibility finding.

---

## 1. The three pauses

Named here by **what each one stops**. `whenNotPaused` appears in exactly two contracts in this
stack; the pool, the token, the lockbox and the CCV carry no pause of their own.

| Name | Call | Flag lives on | What it stops |
|---|---|---|---|
| **`QUEUE`** | `POM.shutdownProposalQueue()` | `POM` | `propose` · `cancel` · `execute` — the proposal system itself |
| **`BRIDGE`** | `POM.pauseTokenPool()` | hooks | pre/post-flight checks on the pool — the whole bridge, both directions |
| **`LANE`** | `POM.pauseRemoteLanes([…])` | hooks | only the named `(chainSelector, direction)` pairs |

All three are set by `HALT_ROLE` (or the admin) and cleared by `RESUME_ROLE` (or the admin).
`admin` = `DEFAULT_ADMIN_ROLE` — the Lido DAO Agent on L1, the `OptimismBridgeExecutor` on L2; the
`onlyRoleOrAdmin` modifier means the admin satisfies every role gate.

**`QUEUE` is different in kind.** `_pause()` increments the epoch before setting the flag
(`PoolOperationManager.sol:587-591`). Proposals live at `proposals[epoch][id]`, so one write makes
the entire queue unreachable. Unpausing does **not** restore it — every proposal must be re-made and
re-serve its delay. `BRIDGE` and `LANE` do not touch the queue. `LANE` can always be undone through
it (`unpauseRemoteLanes`, 3 d). `BRIDGE` can be undone through it **on a spoke only** (`unpause()`,
3 d); on L1 that selector is `Blocked`. `QUEUE` cannot be undone through the queue on either chain.

Outside this stack: CCIP's own RMN curse on `rmn_proxy` halts a lane independently. Neither Lido nor
the POM can set or clear it.

## 2. The asymmetry that shapes everything

**Every pause is immediate. No unpause is, except the DAO's.**

`RESUME_ROLE` has **zero holders** on both POMs (`wsteth.yaml` `getRoleMemberCount[RESUME_ROLE] = 0`
on `l1PoolOperationManager` :608-609 / `l2PoolOperationManager` :1158-1159), and
`1_Deploy` seats it that way deliberately — `resumers: new address[](0)`. So the "resumer" gate is
not a slow path, it is a **closed** one. Undoing a pause has only two routes:

- **the DAO**, as `DEFAULT_ADMIN_ROLE`. Instant *at the contract* on both chains — but the admin is
  the Aragon **Agent** on L1 and the **OptimismBridgeExecutor** on a spoke, and reaching the latter
  costs an L1 vote plus the L1→L2 governance hop. "Instant" is a statement about the gate, never
  about the process behind it.
- **the proposal queue** — 3 days, `PROPOSER_ROLE` (= `chainlink_mcms`) originates, **anyone**
  executes. It reaches `LANE` (`unpauseRemoteLanes`, `0x1cb18dd9`) on both chains, and `BRIDGE`
  (`hooks.unpause()`, `0x3f4ba83a`) **on a spoke only** — on L1 that selector is `Blocked`. There is
  the DAO admin may veto it; Emergency independently stops it with `POM.shutdownProposalQueue()` (epoch++).

**Which makes the spoke asymmetry the one to hold in mind.** There, the cheapest pause (`BRIDGE`,
one `HALT_ROLE` call by Emergency *or* MCMS) is undone by a 3-day MCMS proposal unless the DAO admin
vetoes. Emergency cannot *hold* a `BRIDGE` pause against MCMS on its own — it has to escalate to
`POM.shutdownProposalQueue()`, which destroys every in-flight proposal and is itself admin-only to clear. That is
the deliberate price of not making a spoke restart wait on the governance hop.

### 2.1 The three days are pre-armable — read them as a *first-use* delay, not a reaction window

`propose` does **not** simulate the call it queues (`PoolOperationManager.sol:412-461`), and `execute`
checks only that the proposal is `Ready` (`:493`). `hooks.unpause()` is `whenPaused`, so a queued
un-pause simply reverts while the bridge runs — but it keeps ripening. A proposal is `Ready` from
`created + delay` until `created + expiryPeriod` (`_getProposalState`), i.e. a **27-day standing
window** at the 3-day delay, and `salt` lets identical calls be queued many times over.

So `chainlink_mcms` can keep a permanently-ripened `unpause()` sitting in the queue and execute it
**the instant** someone pauses. Against a standing proposal the effective delay is **zero**, not
three days.

- **This is not new, and not specific to `BRIDGE`.** `unpauseRemoteLanes` (`0x1cb18dd9`) has had
  exactly this property on both chains all along; the spoke grant extends it from `LANE` to the
  whole bridge. Every non-`Blocked` selector behaves this way — it is a property of the POM's
  timelock, not of this row.
- **The counter is procedural and decisive.** `POM.shutdownProposalQueue()` bumps the epoch, and proposals live at
  `proposals[epoch][id]`, so every pre-armed proposal dies with one write; `execute` is
  `whenNotPaused` besides. **On a spoke, an Emergency `pauseTokenPool()` that is not accompanied by
  `POM.shutdownProposalQueue()` should be assumed reversible immediately.** Pausing `QUEUE` first, or in the same
  batch, is what makes a spoke halt hold.
- **The DAO admin may veto** a ripened proposal, but Emergency does not hold that power. Its
  independent counter remains `shutdownProposalQueue()`, which invalidates the whole epoch.

## 3. Role matrix

✅ direct · **3 d** through the proposal queue · ❌ unreachable.

Only one cell differs between chains, and it is marked **L1 / spoke**.

| Role | Holders | stop `QUEUE` | start `QUEUE` | stop `BRIDGE` | start `BRIDGE` | stop `LANE` | start `LANE` |
|---|---|---|---|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | 1 — DAO Agent / OpExec | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `HALT_ROLE` | Emergency Multisig + Chainlink MCMS | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ |
| `RESUME_ROLE` | **0 holders** | ❌ | *(would be ✅)* | ❌ | *(would be ✅)* | ❌ | *(would be ✅)* |
| `PROPOSER_ROLE` | Chainlink MCMS | ❌ | ❌ | **3 d** | ❌ `Blocked` (L1) · **3 d** (spoke) | **3 d** | **3 d** |
| `EXECUTOR_ROLE` | **0 holders** ⇒ `execute` is open to **anyone** | ❌ | ❌ | — | — | — | — |

`propose(hooks, unpause())` reaches `BRIDGE` without `RESUME_ROLE` (`onlyOwner`, owner = POM).
**On a spoke that path is open by design** — `0x3f4ba83a` carries no `Blocked` mode there, so the
call ripens at the 3-day global. On L1 it is `Blocked` and reverts `BlockedSelector`, because the
Agent can restart the hub in one `directCall`. `LANE` `unpauseRemoteLanes` is 3 d on both. `QUEUE`
stays ❌ everywhere because `propose` and `execute` are `whenNotPaused`.

Unblocking `0x3f4ba83a` on the spoke also admits `propose(POM, unpause())`, since the filter is
target-blind. That does **not** turn the `QUEUE` cell green: §6's three reasons are independent of
the selector filter.

Emergency's negative power on the queue is `shutdownProposalQueue()` (epoch++), not veto;
`veto` belongs directly to `DEFAULT_ADMIN_ROLE`.

## 4. Actor matrix

The same table by **who**, folding in every role an actor holds. This is the operational view.

| Actor | Can stop | Can restart | How fast | What can block it |
|---|---|---|---|---|
| **Lido DAO** (Agent / OpExec) | `QUEUE` `BRIDGE` `LANE` | `QUEUE` `BRIDGE` `LANE` | immediate at the gate — but on a spoke the admin is the `OptimismBridgeExecutor`, so an L1 vote + the L1→L2 hop come first | nothing — it is `DEFAULT_ADMIN_ROLE`, and `directCall` bypasses the timelock entirely |
| **Emergency Multisig** | `QUEUE` `BRIDGE` `LANE` | `LANE` only (via MCMS proposing) | 3 d | a `QUEUE` pause (DAO must unpause) |
| **Chainlink MCMS** | `QUEUE` `BRIDGE` `LANE` | **L1:** `LANE` only · **spoke:** `BRIDGE` + `LANE` | 3 d | Emergency `shutdownProposalQueue()` (epoch++ voids the queue) |
| **Anyone** (no roles) | — | executes a ripened `LANE` un-pause, and on a spoke a ripened `BRIDGE` un-pause | — | — |

Read the third row as the risk statement, and note it now has two halves. **MCMS can stop the
bridge alone and immediately, on either chain.** On **L1** it cannot restart `BRIDGE` through the
queue (`unpause()` is `Blocked`) — only the DAO can. On a **spoke** it can, alone, in three days:
that is the grant this design makes deliberately, in exchange for not routing every spoke restart
through the L1→L2 governance hop. Neither MCMS nor Emergency can undo a **`QUEUE`** pause anywhere.

The mirror-image statement matters as much: on a spoke, **an Emergency `BRIDGE` pause no longer
holds by itself**. If Emergency wants a spoke halt to survive an MCMS restart it must pause
`QUEUE`, which discards every in-flight proposal — legitimate DAO work included — and needs the
admin (hop and all) to clear.

> **Rows 2 and 3 are distinct actors on a fresh fork deploy, and one key on the live record.**
> `config/chains/*.json` derive them from `ACTORS_MNEMONIC` (`.env`): the Emergency Multisig
> (`0x608056b8d596da5816146014E88DFfDECAF59DcD`) and Chainlink MCMS (`0x1D72FbCcfC86C88E23771d6D58a8F1Cb77186d1d`), both separate from
> the deployer. `guardian` in the record is a legacy field unused by current `1_Deploy`.
> `config/chains.live*/` still hold one address in all four fields, so there the
> matrix remains a design document (`L-SEP-01`, `README.md` §5).

## 5. The reversal path, step by step

**On the L1 hub**, `BRIDGE` restart through the queue is closed: `propose(hooks, unpause())` reverts
`BlockedSelector` (`0x3f4ba83a`).

```
PAUSER  → POM.pauseTokenPool()                     hooks.paused() = true      [immediate]
PAUSER  → POM.unpauseTokenPool()                   AccessControlUnauthorized
MCMS    → POM.propose(hooks, unpause(), 259200)    BlockedSelector
DAO     → POM.unpauseTokenPool()                   hooks.paused() = false     [or directCall(hooks, unpause())]
```

**On a non-L1 spoke** the third step succeeds and the walk is the 3-day one:

```
PAUSER  → POM.pauseTokenPool()                     hooks.paused() = true      [immediate]
PAUSER  → POM.unpauseTokenPool()                   AccessControlUnauthorized
MCMS    → POM.propose(hooks, unpause(), 259200)    id, state = Waiting
        … 3 days; DAO admin may veto …
ANYONE  → POM.execute(hooks, 0, unpause(), …)      hooks.paused() = false     [EXECUTOR_ROLE empty]
```

Emergency's only interruption of that walk is `POM.shutdownProposalQueue()` — epoch++, the proposal is gone, and
only the admin (via the L1→L2 hop) can clear it. The admin may alternatively veto the proposal.

`LANE` behaves the same on both chains: `unpauseRemoteLanes` (`0x1cb18dd9`) at 3 d, vetoable by the
DAO admin or stopped by `POM.shutdownProposalQueue()`.

| Selector | Function | Queue — L1 hub | Queue — non-L1 spoke |
|---|---|---|---|
| `0x8456cb59` | `pause()` | 3 d — `BRIDGE` (on hooks) | same |
| `0x3f4ba83a` | `unpause()` | **Blocked** — `BRIDGE` (on hooks) | **3 d** — reaches `BRIDGE` |
| `0x5b4d3830` | `shutdownProposalQueue()` | 3 d — `QUEUE` (on POM) | same |
| `0x0a57a857` | `restartProposalQueue()` | 3 d — `QUEUE`, but unreachable (§6) | same |
| `0x85f0f0e1` | `pauseRemoteLanes((uint64,uint8)[])` | 3 d — `LANE` | same |
| `0x1cb18dd9` | `unpauseRemoteLanes((uint64,uint8)[])` | 3 d — `LANE` | same |

The filter is target-blind, so one selector entry covers every contract the POM can call. Until
`lib/ccip` `2bb19f4` that made `0x3f4ba83a` do double duty — Blocked on L1 it closed both the POM's
own `unpause()` and `hooks.unpause()` in one pin, and unblocking it on a spoke admitted
`propose(POM, unpause())` as well as `propose(hooks, unpause())`. Renaming the POM's queue levers to
`shutdownProposalQueue()` (`0x5b4d3830`) / `restartProposalQueue()` (`0x0a57a857`) split the two, so
`0x3f4ba83a` now reaches the hooks alone and the L1 `Blocked` row no longer touches `QUEUE`. Nothing
changes in practice: the POM-targeted path is inert for the three reasons in §6, none of which
depended on the filter. The hooks are the only `unpause()`-bearing contract a POM owns (the L2
wstETH token is not pausable). `pauseTokenPool()` / `unpauseTokenPool()` are POM-side entry points,
not proposal targets.

## 6. Why no proposal can reach `POM.restartProposalQueue()` — i.e. restart `QUEUE`

Three independent reasons, any one sufficient:

1. `execute` is `whenNotPaused` — while `QUEUE` holds, nothing runs.
2. A proposal queued *before* the pause is orphaned by the epoch bump.
3. Executing a POM-targeted call makes the POM its own `msg.sender`, and `hasRole(*, POM) = false`
   for all five roles (`wsteth.yaml`, the `getRoleMemberCount` blocks of `l1PoolOperationManager`
   :596-606 / `l2PoolOperationManager` :1143-1153 — see `E-GAP-02` on what these do *not* pin).

Reason 3 is the one usually quoted and the weakest — it depends on role-count pins holding. Reasons
1 and 2 are structural.

None of the three mentions the selector filter, which is why unblocking `0x3f4ba83a` on a spoke
leaves this section unchanged there. The one caveat is reason 3's dependency: if a later `grantRole`
ever gave a POM `RESUME_ROLE` **on itself**, `propose(POM, restartProposalQueue())` would become
live. With the current UUPS-capable `lib/ccip` pin that is true of **both** chains equally — `0x0a57a857` carries no
override anywhere, so the L1 `Blocked` row no longer forecloses the combination the way it did while
the POM shared `0x3f4ba83a` with the hooks. Reasons 1 and 2 still hold it shut. `mcms-levers.md`
`E-GAP-02` tracks the unpinned self-role assumption.

## 7. Open points

- **`RESUME_ROLE` is empty, and nothing says whether that is final.** If restarting the bridge is
  meant to need a DAO vote, that is a decision worth recording; if a faster path is wanted, the role
  exists and is unseated. Today the answer is implicit in an empty array in `1_Deploy`. Note the
  spoke grant does **not** touch this: it opens a 3-day *queued* restart, not an instant role-gated
  one, so the "no instant unpause except the admin's" property still holds on every chain.
- **The 3-day spoke restart is a first-use delay, not a reaction window (§2.1).** A pre-armed,
  already-ripened proposal makes it effectively instant. Whether the operational rule "pause `QUEUE`
  whenever you pause `BRIDGE` on a spoke" is acceptable, or whether the `BRIDGE` restart wants a
  separate Emergency veto behind it, has not been decided — it is the open question this grant creates.
- **The reversal is not symmetric with the pause it undoes, and the asymmetry now differs by
  chain.** On L1, `BRIDGE` is set by Emergency or MCMS and cleared only by the DAO. On a spoke it is
  set by either and cleared by MCMS alone after 3 d. Both are now *stated* decisions rather than
  accidents of a selector list — the reasoning is in `config/README.md` § *The hub/spoke row* — but
  the spoke case deserves a second look before mainnet: it lets the actor that paused be the actor
  that un-pauses unless the DAO admin vetoes, and it makes an Emergency halt cost a
  `QUEUE` pause to sustain.
- **`L-SEP-01` now obtains on forks, not on the live record, and has no carrier either way.** The
  templates separate deployer / Emergency Multisig / MCMS, but nothing asserts *pairwise
  distinctness* — the property is visible only through per-address `hasRole` checks and the derived
  `haltRoleMemberCount`. Adding the assert is `FPF-REVIEW.md` R-06, still open: it would be green
  on a fork deploy and red on `config/chains.live-mantle`.
- **The actor keys are testnet-only.** `ACTORS_MNEMONIC` is a throwaway phrase in `.env`; a fresh
  clone gets the committed *addresses* but cannot sign for them. Nothing in the deploy needs to —
  only `DEPLOYER_PRIVATE_KEY` signs. The phrase matters only for driving pause / propose.

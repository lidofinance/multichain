# FAQ — wsteth-2.0

> **September 15 deployment:** use [Current deployment and POM permissions](CURRENT-DEPLOYMENT.md)
> and the [deployment report](deployment-2026-09-15.md). The detailed POM descriptions below
> are historical: proposal modes, guardian/veto/approval APIs and combined pause roles no longer apply.

Short answers to the questions that come up first. This is a **reading view** (`E.17`), not a claim
locus: every answer is a compression of something stated in full elsewhere, and each row says where.
Where this file and the cited section disagree, **the cited section wins** (`A.6.B:6.1`,
`CC-A.6.B.4`).

Scope: the end-state (production) authority model. What is actually deployed today differs on one
point that outranks every table below — see [§10](#10-the-caveat-that-outranks-every-table-above).

> **Naming.** There are **two** `PoolOperationManager` deployments, one per chain:
> **`L1-POM`** (`DEFAULT_ADMIN_ROLE` = Agent) and **`L2-POM`** (`DEFAULT_ADMIN_ROLE` = OpExec). They are
> independent contracts with independent state. A row written `L1-POM` / `L2-POM` holds on both; a row
> naming only one holds only there.

---

## 1. What is pausable, and what does pausing change?

Four independent stop surfaces per chain. Three are ours, reached through `L1-POM` / `L2-POM`; the
fourth is Chainlink's.

| Surface                       | Call — on `L1-POM` / `L2-POM`                | What it blocks                                                                                                   | What it does **not** block                                                  |
| ----------------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| **Manager**                   | `.pause()`                                   | `propose` / `cancel` / `execute` — and `epoch++` voids every in-flight proposal                                  | any token movement; `directCall`; the pause/unpause passthroughs themselves |
| **Pool** (the big red button) | `.pauseTokenPool()` → `hooks.pause()`        | every send **and** every receive on that chain, all lanes (`preflightCheck` + `postflightCheck`)                 | governance; the other chain                                                 |
| **Lane**                      | `.pauseRemoteLanes([(selector, direction)])` | exactly the named `(chain selector, direction)` pairs — batch-only, no single-lane variant                       | the other direction; every other lane                                       |
| **RMN curse**                 | `RMN.curse(subject)`                         | `OffRamp.execute` and the pool's own check for that source lane; a **global** curse subject trips the same check | nothing of ours — we neither hold it nor can lift it                        |

- **No cross-triggering.** Pausing the manager does not pause the pool, and vice versa
  ([`PERMISSIONS.md` §4.2](./PERMISSIONS.md#42-pause-design-decisions)).
- **The pause lives in the hooks, not the pool.** `TokenPool` has no pause of its own; `pauseTokenPool`
  is a passthrough to `PausableAdvancedPoolHooks.pause()`.
- **`epoch++` is not undone by `unpause`.** Proposals killed by a manager pause — including benign ones
  — must be re-proposed and re-serve their full delay.
- **Not pausable at all:** the pools, `ERC20LockBox`, L1 wstETH, L2 wstETH, the resolver, the verifier,
  the TAR. A Lido-core `stop()` freezes stETH transfers, hence `wrap`/`unwrap`, but **not** wstETH
  transfers — so it does not stop bridging.

Full design: [`PERMISSIONS.md` §4](./PERMISSIONS.md#4-the-opsmanager-pom-pause-design). Incident
walk-through with recovery paths: [`ARCHITECTURE.md` §1.3](./ARCHITECTURE.md#13-emergency-reaction-and-recovery--who-can-stop-it-and-who-can-start-it-again).

---

## 2. Who can pause what?

| Holder                              | L1                                            | L2         | May call                                                                                          |
| ----------------------------------- | --------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------- |
| `HALT_ROLE`                       | Emergency Brakes multisig + Chainlink MCMS    | same       | all three: `pause`, `pauseTokenPool`, `pauseRemoteLanes`                                          |
| `DEFAULT_ADMIN_ROLE`                | **Agent**                                     | **OpExec** | the same three, via `onlyRoleOrAdmin` — no explicit `HALT_ROLE` grant needed, and none is given |
| RMN `owner()` / seeded `curseAdmin` | Chainlink — **not pinned by any record here** | same       | `curse`                                                                                           |

- All three of ours are **immediate**: no proposal, no delay.
- Pausing L2 is **not** a cross-domain call. Brakes and MCMS hold `HALT_ROLE` on L2-POM directly, so
  an OP-messenger outage does not disarm the brakes.

Role table: [`PERMISSIONS.md` §3.1](./PERMISSIONS.md#31-pooloperationmanager-pom--the-operations-gate--timelock)
· holder table: [§4.1](./PERMISSIONS.md#41-role--holder).

---

## 3. Who can resume what?

| Surface | Who may resume | The path |
|---|---|---|
| `unpause` / `unpauseTokenPool` / `unpauseRemoteLanes` **on the POM** | `RESUME_ROLE` is **unassigned**, so only `DEFAULT_ADMIN_ROLE` | **L1:** Voting → DualGovernance → Timelock → AdminExecutor → Agent → `L1-POM`. **L2:** the same, then `L1CrossDomainMessenger.sendMessage` → `OpExec.queue` → `execute` → `L2-POM` |
| `unpause` / `unpauseRemoteLanes` **on the hooks** | `onlyOwner`, and the owner is the POM — so an *executed proposal* reaches them, no `RESUME_ROLE` needed | MCMS `propose` → 3 d; unless the DAO admin vetoes, **anyone** executes. `unpauseRemoteLanes` on both chains; `unpause` on a **non-L1 spoke** only (`0x3f4ba83a` is `Blocked` on L1) — [`PAUSES.md`](./PAUSES.md) |
| RMN `uncurse` | RMN `owner()` (`onlyOwner`) | Chainlink's, not ours |

- **A pauser cannot undo its own pause.** Every recovery is a full governance round-trip; a mistaken
  brake costs a DAO cycle to lift. That is a deliberate decision, not an oversight
  ([`PERMISSIONS.md` §4.4](./PERMISSIONS.md#44-open-points--how-theyre-resolved-here)).
- **Asymmetry across the messenger.** While the OP messenger is down, L2 can still be *stopped* and no
  **admin** action reaches it — the POM's `unpause*` and `directCall` both need the cross-domain leg
  (`D-EXT-06`). One resume lever survives it: MCMS can `propose(hooks, unpause())` on a spoke and
  restart the bridge after 3 d, because `0x3f4ba83a` is not `Blocked` there and `execute` is
  permissionless.
- **Resuming does not restore the queue.** `unpause` does not roll the epoch back.

Command path: [`ARCHITECTURE.md` §4](./ARCHITECTURE.md#4-governance-command-path--control-view-structurekind--controlstructure).

---

## 4. What contracts are upgradable?

| Contract                                                            | Upgradable?               | Mechanism / who                                                                                                                                                                                                                       |
| ------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **L2 wstETH** (`ERC20BridgedPermit`)                              | **Yes**                   | `OssifiableProxy.proxy__upgradeTo{,AndCall}`, `onlyAdmin` = **OpExec**. Same admin holds `proxy__changeAdmin` and the one-way `proxy__ossify`                                                                                         |
| **`L1-POM`** / **`L2-POM`**                                         | **Yes** | UUPS `upgradeToAndCall`, authorized only by the POM's `DEFAULT_ADMIN_ROLE`: Agent on L1, OpExec on L2. The proposal selector `0x4f1ef286` is `Blocked` on both chains, so upgrades use the direct governance path. `RealPomUpgrade` rehearses both proxies on forks |
| pools, hooks, `ERC20LockBox`, resolver, verifier, OpExec, L1 wstETH | **No**                    | plain non-proxied deployments                                                                                                                                                                                                         |
| CCIP system (Router, TAR, ramps, FeeQuoter, `RMNProxy`)             | not ours                  | Chainlink-owned. `RMNProxy` is a `fallback` forwarder, so the RMN behind it is re-pointable by *its* owner                                                                                                                            |

**Replacement is not upgrade.** Nothing above is stuck: every non-upgradable piece can be swapped for a
freshly deployed one by re-pointing whatever references it. The address changes; the storage does not
carry over.

| Piece | Re-point call | Gate |
|---|---|---|
| hooks | `pool.updateAdvancedPoolHooks(...)` | `L1-POM` / `L2-POM` queue — **14 days** |
| lockbox (**L1 only**) | `pool.configureLockBoxes(...)` | `L1-POM` queue — **14 days** |
| router / rate-limit admin / fee admin | `pool.setDynamicConfig(...)` | `L1-POM` / `L2-POM` queue — **14 days** |
| pool, as its manager sees it | `setTokenPool(...)` on `L1-POM` / `L2-POM` | admin — **immediate** |
| pool, as CCIP sees it | `TAR.setPool(token, pool)` | `L1-POM` / `L2-POM`, as the token administrator |
| verifier behind the resolver | resolver inbound/outbound implementation update | `onlyOwner` = `L1-POM` / `L2-POM` |
| `L1-POM` / `L2-POM` implementation | `upgradeToAndCall(newImplementation, data)` on the proxy | `DEFAULT_ADMIN_ROLE` — Agent / OpExec; direct governance path |

Per-contract detail: [`PERMISSIONS.md` §3](./PERMISSIONS.md#3-per-contract-permissions).

---

## 5. What operations are timelocked, and which have short direct paths?

### 5.1 The timelock

The `L1-POM` / `L2-POM` queue — `propose` → wait → `execute`, in **Veto** mode (a proposal ripens
unless the DAO admin vetoes, or Emergency `shutdownProposalQueue()` voids the queue).
Both chains carry the same parameters.

|  | Value |
|---|---|
| global minimum delay | **3 days** (`259200 s`) |
| `transferAdminRole` · `setPool` · `setDynamicConfig` (pool **and** CCV verifier) · `updateAdvancedPoolHooks` · `configureLockBoxes` | **14 days** (`1209600 s`) — six selectors, from **our** `config/default_config.json` injected via `DEFAULT_CONFIG` |
| `transferOwnership` | **Blocked** — cannot be proposed at all; the only route is `directCall` |
| POM `upgradeToAndCall` | **Blocked** for proposals; callable directly only by Agent / OpExec as `DEFAULT_ADMIN_ROLE` |
| veto / approval / timelock setters | **DAO admin only**; current upstream POM has no `GUARDIAN_ROLE`. Emergency instead voids the queue with `shutdownProposalQueue()` (epoch++) ([`PARAMETERS.md` §3](./PARAMETERS.md#3-governance-timelock-parameters--pom), [`PERMISSIONS.md` §4.3](./PERMISSIONS.md#43-guardian-and-pauser-holders)) |
| expiry | **30 days from creation**, so the usable execution window is `30 d − delay` — 27 days at the global delay, 16 at a 14-day one ([`PARAMETERS.md` §0.3](./PARAMETERS.md#03-the-second-repair--expiryperiod-is-not-validity_period)) |
| who may execute a ripened proposal | `EXECUTOR_ROLE` is **empty** ⇒ **anyone** |
| who may propose | `PROPOSER_ROLE` = Chainlink MCMS. The proposer picks the delay; the selector's minimum is only a floor |

### 5.2 The short direct paths

**Nearly every timelocked operation has one.** `directCall` reaches any target with any calldata, so
the queue binds Chainlink MCMS, not the DAO — the DAO's normal path bypasses it entirely.

| Path | Caller | Effect |
|---|---|---|
| `directCall(target, value, data)` | `DEFAULT_ADMIN_ROLE` — Agent / OpExec | arbitrary call on any target, **immediate**. This is the DAO's standard route, used by every config change in the scenarios |
| `setTokenPool(pool)` | admin | re-points that chain's manager at another pool |
| `grantRole` / `revokeRole` | admin — `L1-POM` / `L2-POM` never override `getRoleAdmin`, so the admin is role-admin of *every* role | including granting itself `PROPOSER_ROLE`, which is how it reaches `cancel` |
| `shutdownProposalQueue` · `pauseTokenPool` · `pauseRemoteLanes` (+ the three reversals) | halters / admin | §1–§3 above |
| `setGlobalMinDelay` · `setGlobalProposalMode` · `setGlobalExpiryPeriod` · `setSelectorMinDelay` · `setSelectorMode` | admin | **the timelock parameters are not themselves timelocked.** `setGlobalMinDelay(0)` disables the delay outright, and in Veto mode that removes the veto window with it |
| `veto(id)` / `approve(id)` | admin | immediate |
| `upgradeToAndCall(newImplementation, data)` | admin, directly on the POM proxy | UUPS implementation upgrade plus optional initialization; proposal route is Blocked |
| `cancel(id)` | `PROPOSER_ROLE` **only** — no admin bypass | immediate |
| `applyAllowlistUpdates(...)` | verifier `owner()` **or** `allowlistAdmin` | a mutable per-lane sender allowlist whose admin is still the **deployer** EOA ([`PERMISSIONS.md` §3.9](./PERMISSIONS.md#39-ccv-stack--dummymessageidverifier--versionedverifierresolver)) |

### 5.3 So what actually delays a DAO action?

Not `L1-POM` / `L2-POM`. The binding delay is the outer governance stack.

| Leg | Delay |
|---|---|
| **L1** — Voting → DualGovernance → EmergencyProtectedTimelock → AdminExecutor → Agent | Lido core's own timelock; upstream, not configured by this repo |
| **L2** — the L1 leg, then `OpExec.queue` → `execute` | `delay = 0`, grace period `1 day`. Effectively immediate on execution; the OpExec guardian's `cancel` is the only window. These are `DeployL2Gov` **disposable-testnet defaults** (`OPEXEC_DELAY`, `OPEXEC_GRACE_PERIOD`), env-overridable and **not** a production choice |

Parameter rows and which are still open: [`PARAMETERS.md` §3](./PARAMETERS.md#3-governance-timelock-parameters--pom).

---

## 6. What can the Chainlink-owned multisigs do?

Two very different things wear that name. One is a role **we granted and can revoke**; the other is
ownership of the CCIP system contracts, which we never held.

### 6.1 Chainlink MCMS — the role on our contracts

| Holds | May do | Delay | May **not** |
|---|---|---|---|
| `PROPOSER_ROLE` on `L1-POM` / `L2-POM` | `propose(target, value, data, …)` — **`target` and `data` are unconstrained**; the bound is that the call runs *as the POM*, so it bites only where the POM is the authority (pool · hooks · lockbox · CCV · our TAR entry). `cancel(id)` **any** queued proposal, not only its own | 3 days, 14 on the six sensitive selectors; the DAO admin may `veto` it first | `directCall`; `transferOwnership` and POM `upgradeToAndCall` (**Blocked** — not proposable at all); grant or revoke any role |
| `HALT_ROLE` on `L1-POM` / `L2-POM` | `shutdownProposalQueue()`, `pauseTokenPool()`, `pauseRemoteLanes([...])` | **none — immediate** | **unpause anything *at this gate*.** `RESUME_ROLE` is empty, so the POM's own reversals (`restartProposalQueue` / `unpauseTokenPool` / `unpauseRemoteLanes`) are admin-only. The hooks' are reachable by proposal (3 d): per-lane on both chains, global on a spoke |

So MCMS can halt the bridge unilaterally and instantly, and can propose any config change — but it
cannot land one inside 3 days, and cannot restart what it stopped. Revoking it is a `revokeRole` per role
from Agent / OpExec — immediate, and needing no proposal.

### 6.2 Chainlink as owner of the CCIP system contracts

Never granted by us and not revocable by us. **No record in this repository pins who holds these
keys** — that they are MCMS multisigs is expectation, not verified state (`D-EXT-02`).

| Owner of | What it can do to this system | Our counter-lever |
|---|---|---|
| `Router` | `applyRampUpdates` — decides which addresses satisfy our pool's `_onlyOnRamp` / `_onlyOffRamp`. Dropping our lane's ramps stops the lane; **see §6.3** | repoint the pool at another router (`setDynamicConfig`, 14 d, or `directCall`) |
| `OffRamp` | `applySourceChainConfigUpdates` — per-source `laneMandatedCCVs` and `defaultCCVs`. Can **add** verifiers to our inbound required set; one that never attests blocks every inbound message | none — but it cannot **remove** ours: the required set is a union with the pool's declaration |
| `OnRamp` | `setDynamicConfig` / `applyDestChainConfigUpdates` — fee quoter, router, send-side `laneMandatedCCVs` | none |
| `RMN` | `curse(subject)` — the owner **or** a seeded curse admin — reverts both `lockOrBurn` and `releaseOrMint` on that lane; a global curse subject trips the same check. `uncurse` is `onlyOwner` | none. `i_rmnProxy` is immutable in the pool — changing it means deploying a new pool |
| `RMNProxy` | `setARM` — swaps the entire risk network our pool consults | none, same reason |
| `TokenAdminRegistry` | `addRegistryModule` / `removeRegistryModule`, `proposeAdministrator` | **cannot touch our entry** — `proposeAdministrator` reverts `AlreadyRegistered` once `administrator != 0` |
| `FeeQuoter` | prices and gas parameters behind the fee quote | none; it moves cost, not admissibility |

### 6.3 The one that reaches custody

Everything above except the first row is a *stop*. The Router owner's is not.

`releaseOrMint` admits any caller for which `Router.isOffRamp(sourceSelector, msg.sender)` is true.
So registering an arbitrary address as an OffRamp for our lane lets it call `releaseOrMint` on our
pool directly — releasing from the L1 lockbox, or minting L2 wstETH. **The CCV quorum does not
contain this**, because `A-CCV-01` is enforced *inside* `OffRamp.execute`, i.e. inside the contract
being replaced. What is left holding the line is the inbound **rate limit** (`A-RL-01`, 330e18 with
~24 h refill), the hooks **pause**, and an RMN **curse** — which is why the rate limit is a
containment bound and not a UX knob ([§7](#7-which-deploy-parameters-need-settling-before-mainnet)).

Full external-authority list: [`PERMISSIONS.md` §2.2.2](./PERMISSIONS.md#222-authorities-outside-the-boundary--chainlink--op-none-of-which-we-hold) (`D-EXT-01`–`D-EXT-06`).

---

## 7. Which deploy parameters need settling before mainnet?

Fifteen rows, **grouped by what unblocks each — not ranked** (`G.5`: no score, no ordering).
Selection criterion: the row still bears a decision about a *value*, or that value is irreversible
once deployed. **Who holds which role is deliberately not on this list** — that is
[§2](#2-who-can-pause-what), [§3](#3-who-can-resume-what), [§6](#6-what-can-the-chainlink-owned-multisigs-do)
and [`PERMISSIONS.md`](./PERMISSIONS.md). Every ID resolves in [`PARAMETERS.md`](./PARAMETERS.md).

**A — a fix is required; the deployed value is outside the intended set**

| # | ID | What it is | Why it is open |
|---|---|---|---|
| ~~1~~ | ~~`P-POM-05`~~ | the 14-day per-selector delay overrides | **closed** — `lido-proposals` binds `0xddadfa8e` and `setPool`; our injected file still adds the CCV `setDynamicConfig` overload, and Blocks hooks `unpause()` **on the L1 hub only** (`config/default_config.non_l1.json` omits that row) |

**B — a number is needed, and first a stated basis to compare against (`C.18` before `C.11`)**

| # | ID         | What it is                                                                                      | Deployed today                                                                                    |
| - | ---------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| 2 | `P-RL-01`  | outbound bucket capacity — max wstETH in one send, and the burst ceiling                        | `500e18`                                                                                          |
| 3 | `P-RL-02`  | outbound refill rate                                                                            | full capacity per ~24 h                                                                           |
| 4 | `P-RL-03`  | inbound bucket capacity — **the containment bound of [§6.3](#63-the-one-that-reaches-custody)** | `330e18`                                                                                          |
| 5 | `P-RL-04`  | inbound refill rate                                                                             | full capacity per ~24 h                                                                           |
| 6 | `P-POM-02` | global minimum delay                                                                            | `3 days` — sized for which incident-response latency? Nothing states it                           |
| 7 | `P-OPX-01` | OpExec queue→execute delay                                                                      | **`0`** — a disposable-testnet default. The L2 governance timelock is currently nil               |
| 8 | `P-OPX-02` | OpExec grace period                                                                             | `1 day` — same provenance                                                                         |
| 9 | `P-OPX-03` | the bounds within which the OpExec delay may later be moved                                     | `0`–`86400`; they cap every future correction to rows 7–8, so they are settled *before* those are |

**C — inherited upstream defaults nobody here has examined**

| # | ID | What it is | Note |
|---|---|---|---|
| 10 | `P-POM-03` | `expiryPeriod` — the **right edge** of the execution window, not a validity period | `30 d`; the usable window is `expiryPeriod − delay`, so it is coupled to rows 1 and 6 |
| 11 | `P-CCV-08` | per-remote-chain verifier config | `gasForVerification = 1` — a dummy-verifier value that will not survive a real CCV |
| 12 | `P-FEE-01` | `dest_gas_overhead` reserved for destination-side pool execution | `150000`, inherited; under-reserving strands messages at the destination |

**D — deliberately "off", or fixed per lane; settle it as a decision rather than inherit a default**

| # | ID | What it is | Note |
|---|---|---|---|
| 13 | `P-CCV-01` | the verifier set our hooks **declare** required, per lane and direction | one entry — the resolver — in both directions. **A 2-of-2 quorum is deployed nowhere**; it exists only inside `RealCcvLane`, created by a test-local reconfiguration. Whether mainnet ships 1-of-1 is the largest open value here (`A-CCV-01`, [`README.md` §5](../README.md#5-claim-register--boundary-norms-a6b-lade)) |
| 14 | `P-CCV-02` / `P-CCV-03` | large-transfer escalation — the amount at which extra verifiers are also required, and the sets it pulls in | `0` and `[]`: escalation off. The `0` is a **sentinel that leaves the scale**, so "off" is a decision, not a small number |
| 15 | `P-TOP-02` | `is_siloed` — whether a lane gets its own `ERC20LockBox` | `true` on the L1 hub lane, so release draws only from that lane's box (`L-SILO-01`). It is set per remote lane, so it is a fresh custody decision every time a lane is added |

**Left out deliberately, so a clean fifteen is not read as full coverage:**

- **The permissions-side settlements**, which belong to the sections above rather than here:
  `P-POM-06` (the active POM principals' addresses), `P-OPX-04` (the OpExec cancel guardian, today the
  deployer EOA), `P-CCV-06` (verifier `allowlistAdmin`, likewise the deployer), `P-ALW-01` (whether
  an origination allowlist is enforced — `immutable`, deployed disabled), `P-POM-07` / `P-POM-08`
  (the empty unpauser and executor sets). See [`PERMISSIONS.md` §2.2](./PERMISSIONS.md#22-actor-capability-matrix--end-state)
  and [§4.3](./PERMISSIONS.md#43-guardian-and-pauser-holders). **`L-SEP-01` — the principals are distinct keys but single EOAs, and DG's committees sit on public
  anvil keys — outranks every row in this section**
  ([§10](#10-the-caveat-that-outranks-every-table-above)).
- `P-CCV-04` (a placeholder proof-location URI), `P-FEE-02` / `P-FEE-03` (the other inherited fee
  rows), `P-POM-01` (Veto vs ExplicitApproval), `P-POM-04` (the blocked-selector set), `P-POM-09`
  (the POM UUPS governance choice), and the remaining
  `P-TOP-*` rows, which record topology facts rather than choices.

The open set in full, with the same grouping, is
[`PARAMETERS.md` §8](./PARAMETERS.md#8-the-open-set--parameters-still-bearing-a-decision).

---

## 8. What are the main governance paths (non-emergency)?

Six, and only the first two are the DAO acting directly. Emergency stop-and-recover is [§1](#1-what-is-pausable-and-what-does-pausing-change)–[§3](#3-who-can-resume-what).

| # | Path                                 | Route                                                                                                                                                                                               | Delay                                                                                                    |
| - | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| 1 | **DAO → L1**                         | Voting → DualGovernance → EmergencyProtectedTimelock → AdminExecutor → Agent → `L1-POM.directCall` → L1 pool / hooks / lockbox / CCV                                                                | the DAO's own timelock only — `L1-POM` adds none                                                         |
| 2 | **DAO → L2**                         | the same spine, then `L1CrossDomainMessenger.sendMessage(opExec, …)` → OP relay (`xDomainMessageSender == Agent`) → `OpExec.queue` → `OpExec.execute` → `L2-POM.directCall` → L2 pool / hooks / CCV | the DAO's timelock, then `OPEXEC_DELAY` — **`0` today**                                                  |
| 3 | **Chainlink MCMS proposal**          | `propose(...)` on `L1-POM` / `L2-POM` → ripens → **anyone** calls `execute` → the target                                                                                                            | 3 d, or 14 d on the six sensitive selectors; vetoable throughout by the POM admin                        |
| 4 | **Guardian, on the timelock itself** | `setGlobalMinDelay` · `setGlobalProposalMode` · `setGlobalExpiryPeriod` · `setSelectorMinDelay` · `setSelectorMode`, plus `veto` / `approve`                                                        | **none.** The parameters that create the delay are not themselves delayed                                |
| 5 | **CCIP registration**                | `L1-POM` / `L2-POM` as the TAR per-token `administrator` → `setPool(token, pool)`, `transferAdminRole` (2-step) — reached through paths 1–3                                                         | whichever of 1–3 carried it                                                                              |
| 6 | **L2 token, bypassing `L2-POM`**     | OpExec → L2 wstETH `DEFAULT_ADMIN_ROLE` (grant/revoke `MINTER_ROLE` / `BURNER_ROLE`) and `OssifiableProxy.proxy__upgradeTo` / `proxy__changeAdmin` / `proxy__ossify`                                | path 2's delay. **Note this never touches `L2-POM`** — the token and its proxy answer to OpExec directly |

Two properties worth stating out loud:

- **Agent is the single root.** Both POMs, both token stacks and both TAR entries lead back to it —
  directly on L1, through the pinned `OpExec.ethereumGovernanceExecutor == Agent` on L2.
- **The queue binds Chainlink, not the DAO.** Path 1 and path 2 use `directCall`, which is exempt
  from the `L1-POM` / `L2-POM` timelock by construction; path 3 is the only one the 3/14-day delay actually gates.

Drawn: [`ARCHITECTURE.md` §1.2](./ARCHITECTURE.md#12-regular-governance--who-participates) and
[§4](./ARCHITECTURE.md#4-governance-command-path--control-view-structurekind--controlstructure).

---

## 9. Who holds what — every actor, every role, and what it unlocks

One row per **(actor, role)** pair: an actor holding three roles appears three times, because the
roles are separately grantable and separately revocable (`A.15`: Role ≠ Method ≠ Work). Capabilities
are the actual callable levers that role admits, one per line.

The end-state holders. What the deployed records actually say is [§10](#10-the-caveat-that-outranks-every-table-above).

| Actor                                                                               | Role it holds                                                    | Capabilities that role unlocks                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ----------------------------------------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Lido DAO** — Voting → DualGovernance → EmergencyProtectedTimelock → AdminExecutor | the authority above `Agent`; upstream, not a role in this system | make `Agent` enact any row below<br>gated by the DAO's own timelock, never by an `L1-POM` / `L2-POM` one                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **Aragon Agent** (L1)                                                               | `DEFAULT_ADMIN_ROLE` on `L1-POM`                                 | `upgradeToAndCall(newImplementation, data)` on the POM proxy<br>`directCall(target, value, data)` — any call on pool · hooks · lockbox · CCV · TAR entry, **no delay**<br>`setTokenPool(pool)`<br>`grantRole` / `revokeRole` on every role, its own included<br>`veto(id)` · `approve(id)`<br>`pause()` · `pauseTokenPool()` · `pauseRemoteLanes([...])`<br>`unpause()` · `unpauseTokenPool()` · `unpauseRemoteLanes([...])` — **sole holder**<br>`setGlobalMinDelay` · `setGlobalProposalMode` · `setGlobalExpiryPeriod` · `setSelectorMinDelay` · `setSelectorMode`<br>**not** `propose` / `cancel` — those are plain `onlyRole(PROPOSER_ROLE)` |
| **Aragon Agent** (L1)                                                               | the `xDomainMessageSender` pinned in `OpExec`                    | `L1CrossDomainMessenger.sendMessage(opExec, calldata, gasLimit)` — the only origin `OpExec.queue` accepts                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| **Aragon Agent** (L1)                                                               | CCV `feeAggregator` (L1)                                         | receives whatever a permissionless `withdrawFeeTokens` pushes out                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **OpExec** (L2)                                                                     | `DEFAULT_ADMIN_ROLE` on `L2-POM`                                 | the same lever set as `Agent` above, on the L2 stack<br>reachable only through `queue` → `execute`, so every use carries the cross-domain hop                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **OpExec** (L2)                                                                     | L2 wstETH `DEFAULT_ADMIN_ROLE`                                   | `grantRole` / `revokeRole` of `MINTER_ROLE` and `BURNER_ROLE` on the token<br>**never touches `L2-POM`** — the token answers to `OpExec` directly                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **OpExec** (L2)                                                                     | L2 wstETH `OssifiableProxy` admin                                | `proxy__upgradeTo` · `proxy__upgradeToAndCall`<br>`proxy__changeAdmin`<br>`proxy__ossify` — one-way                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **OpExec** (L2)                                                                     | CCV `feeAggregator` (L2)                                         | receives withdrawn CCV fees                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **Chainlink MCMS**                                                                  | `PROPOSER_ROLE` on `L1-POM` / `L2-POM`                           | `propose(target, value, data, predecessor, salt, delay)` — **no target allowlist**: any address, any calldata ≥ 4 bytes<br>it picks the delay, floored by the selector's minimum and capped by the expiry<br>`cancel(id)` — **any** queued proposal, not only its own<br>cannot propose `transferOwnership` — that selector is **Blocked**                                                                                                                                                                                                                                        |
| **Chainlink MCMS**                                                                  | `HALT_ROLE` on `L1-POM` / `L2-POM`                             | `shutdownProposalQueue()` — blocks `propose` / `cancel` / `execute` and runs `epoch++`<br>`pauseTokenPool()`<br>`pauseRemoteLanes([...])`<br>all immediate; **cannot unpause any of them**                                                                                                                                                                                                                                                                                                                                                                                                        |
| **Emergency Brakes multisig**                                                       | `HALT_ROLE` on `L1-POM` / `L2-POM`                             | the same three pauses, immediate<br>works on L2 **without crossing the messenger**<br>cannot unpause, propose or veto                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **anyone**                                                                          | `EXECUTOR_ROLE` = ∅ — the **empty set is itself the grant**      | `execute(...)` any ripened, unvetoed proposal on `L1-POM` or `L2-POM`<br>`OpExec.execute(actionsSetId)` once its delay has passed<br>`withdrawFeeTokens` on the CCV — the destination is fixed, so no discretion moves with it<br>`OffRamp.execute(...)` with the CCV proofs — permissionless by design                                                                                                                                                                                                                                                                           |
| **Deployer EOA**                                                                    | `OpExec.guardian` — interim residual                             | `cancel(actionsSetId)` — any queued L2 action set, **including the one that would rotate it**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **Deployer EOA**                                                                    | CCV `allowlistAdmin` — interim residual                          | `applyAllowlistUpdates(...)` — mutates the per-lane sender allowlist with no delay<br>inert while the lane runs 1.5 transport                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **`L1-POM` / `L2-POM`**                                                             | `owner` of pool · hooks · lockbox · resolver · verifier          | every `onlyOwner` lever on those five — `applyChainUpdates`, `setRateLimitConfig`, `setDynamicConfig`, `updateAdvancedPoolHooks`, `configureLockBoxes`, `applyCCVConfigUpdates`, `setThresholdAmount`, hooks `pause` / `unpause` / lane pauses, resolver implementation updates<br>**no autonomous path** — each is reached only through the admin, proposer or pauser rows above                                                                                                                                                                                                 |
| **`L1-POM` / `L2-POM`**                                                             | TAR per-token `administrator`                                    | `setPool(token, pool)` — rebinds which pool CCIP resolves for wstETH<br>`transferAdminRole(token, newAdmin)` — 2-step                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **L1 TokenPool**                                                                    | lockbox `authorizedCaller`                                       | `lockbox.deposit` on lock · `lockbox.withdraw` on release — the whole locked principal of that lane's box                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| **L1 / L2 TokenPool**                                                               | hooks `authorizedCaller`                                         | the only caller of `preflightCheck` / `postflightCheck`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| **L2 TokenPool**                                                                    | L2 wstETH `MINTER_ROLE`                                          | `mint(to, amount)` — unbounded at the token itself; the bound is the pool's inbound rate limit                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| **L2 TokenPool**                                                                    | L2 wstETH `BURNER_ROLE`                                          | `burn(amount)` from its own balance, on send                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| **Chainlink** *(external)*                                                          | `owner` of `Router`                                              | `applyRampUpdates` — decides who satisfies `_onlyOnRamp` / `_onlyOffRamp`<br>⇒ can authorize an address that calls `releaseOrMint` on our pool ([§6.3](#63-the-one-that-reaches-custody))                                                                                                                                                                                                                                                                                                                                                                                         |
| **Chainlink** *(external)*                                                          | `owner` of `OffRamp`                                             | `applySourceChainConfigUpdates` — per-source `laneMandatedCCVs` and `defaultCCVs`<br>can **add** required verifiers; cannot remove ours                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| **Chainlink** *(external)*                                                          | `owner` of `OnRamp`                                              | `setDynamicConfig` · `applyDestChainConfigUpdates` — fee quoter, router, send-side mandated CCVs                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **Chainlink** *(external)*                                                          | `owner` of `RMN`, plus any seeded `curseAdmin`                   | `curse(subject)` — owner **or** curse admin; reverts `lockOrBurn` and `releaseOrMint` on that lane, and a global subject trips the same check<br>`uncurse(subject)` — `onlyOwner`                                                                                                                                                                                                                                                                                                                                                                                                 |
| **Chainlink** *(external)*                                                          | `owner` of `RMNProxy`                                            | `setARM` — swaps the entire risk network the pool consults; `i_rmnProxy` is immutable in the pool                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **Chainlink** *(external)*                                                          | `owner` of `TokenAdminRegistry`                                  | `addRegistryModule` / `removeRegistryModule` · `proposeAdministrator`<br>**cannot touch our entry** — reverts `AlreadyRegistered` once `administrator != 0`                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **OP `L2CrossDomainMessenger`** + the OP sequencer *(external)*                     | the only `msg.sender` `OpExec.queue` accepts                     | delivers — or fails to deliver — every L1→L2 governance message<br>while it is down L2 can still be **paused**, but not unpaused or repaired                                                                                                                                                                                                                                                                                                                                                                                                                                      |

Two readings this table is **not**: it is not the address source of truth (that is
`state/*.json` and `config/chains*/`), and every "external" row is unpinned by any record here —
who actually holds those Chainlink keys is expectation, not verified state.

Per-contract detail: [`PERMISSIONS.md` §3](./PERMISSIONS.md#3-per-contract-permissions) · the same
content as a levers map: [§2.1](./PERMISSIONS.md#21-the-complete-levers-map--every-actor-role-and-lever) ·
end-state assertions: [§5](./PERMISSIONS.md#5-end-state-matrix).

---

## 10. The caveat that outranks every table above

The tables describe the **end state**. Two things about the deployed record still fall short of it,
and both outrank every row above.

**The holders are distinct keys, but they are not what the rows name.** On `config/chains/*.json` the
deployer, the Emergency Multisig (filling both the `guardian` and `emergency_brakes` slots, by design)
and Chainlink MCMS are three separate addresses, derived from a throwaway `ACTORS_MNEMONIC` in `.env`.
So "the brakes multisig halts while the DAO reviews" is no longer one key talking to itself — but it
is still a **single EOA**, not a multisig. Separation of holders obtains; the nature of the holder
does not. And `config/chains.live-mantle/*` — the older live record — still collapses all four onto
`0xE528…0597`.

**Dual Governance's committees are throwaway EOAs, not public anvil keys.**
`script/01_l1_core_dg.sh` substitutes `ACTORS_MNEMONIC[4..10]` into the generated scratch params
and does **not** export `DG_ALLOW_DEV_COMMITTEES`, so core's public-chain guard has to pass on
its own ([`plan-v3-dg-committees.md`](./plan-v3-dg-committees.md)). They are still single EOAs
we control, not multisigs. The older live record still seats the anvil keys — those addresses
were baked at DG deploy time and need a redeploy to change.

`L-SEP-01` ([`README.md` §5](../README.md#5-claim-register--boundary-norms-a6b-lade)) covers the
first point. Claim A still could not detect a *collapse* if one recurred: no pairwise-distinctness
assertion exists ([`PERMISSIONS.md` §4.3](./PERMISSIONS.md#43-guardian-and-pauser-holders),
[§2.2.4](./PERMISSIONS.md#224-what-claim-a-does-not-pin)).

---

## Where to go next

| Question | Document |
|---|---|
| what exists, what is claimed, what the evidence licenses | [`README.md`](../README.md) |
| every contract, actor, and how they are wired | [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| who may do what, per contract and end-to-end | [`PERMISSIONS.md`](./PERMISSIONS.md) |
| what a deployed value means and whether it is still open | [`PARAMETERS.md`](./PARAMETERS.md) |
| what the system is *for*, and what has no bearer yet | [`FUNCTION.md`](./FUNCTION.md) |
| what changes on a live network | [`LIVE_DEPLOY_CONCERNS.md`](./LIVE_DEPLOY_CONCERNS.md) |

**Adding a question here.** Answer it in ≤ 6 lines or one table, and link the section that carries the
claim. If no section carries it, the answer belongs *there* first and only then here.

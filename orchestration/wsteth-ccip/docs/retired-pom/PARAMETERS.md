# Deploy parameters — what each value means, and which ones are still a decision

> **September 15 deployment:** use [Current deployment and POM permissions](CURRENT-DEPLOYMENT.md)
> and the [deployment report](deployment-2026-09-15.md). The detailed POM descriptions below
> are historical: proposal modes, guardian/veto/approval APIs and combined pause roles no longer apply.

> Companion to [`ARCHITECTURE.md`](./ARCHITECTURE.md) (structure), [`PERMISSIONS.md`](./PERMISSIONS.md)
> (who may act), [`FUNCTION.md`](./FUNCTION.md) (what the system is for) and
> [`config/README.md`](../config/README.md) (which side *writes* each config field).
> This document covers the fourth question none of those answer: **what a deployed value
> means, what range it may lawfully take, and whether choosing it is still open.**

Governed by **`A.6.RSIR`** (Relation/Signature/Interface/Role/**Slot** Precision Restoration) for
the entry repair, **`A.18`** (CSLC — Characteristic ⟷ Scale ⟷ Level ⟷ Coordinate) for every row,
**`C.16.P`** where the source wording is a bare `threshold` / `rate` / `level`, **`C.11`** for the
disposition column, **`A.6.B`** for the L/A/D/E quadrant the repo already uses, and **`G.5`** for
the prohibition on ranking these rows into a score.

---

## 0. What this document is

### 0.1 "Deploy parameter" is five different things (`A.6.RSIR`)

`A.6.RSIR:0` names `parameter` and `argument` as trigger wording: words that hide *which* FPF
object is current. In this repo one phrase — say *"the 14-day delay parameter"* — spans five
separately governed objects:

| What the phrase can mean | Recovered object | Governing pattern | What it does **not** establish |
|---|---|---|---|
| the JSON field `custom_delay_selectors[i].delay_seconds` in `lib/ccip/.../config/default_config.json` | a **representation position** in a selected representation | `C.29` / the representation's owner | that any operation was declared, applied, or that a value reached the chain |
| `PoolOperationManager.initialize(address tokenPool, ProposalMode proposalMode, uint40 minDelay, uint40 expiryPeriod, InitialRoles initialRoles)` | an **`ArgumentDeclaration`**, declaration-local | `A.6.1` | that anything was bound |
| the one deploy tx that ran `setSelectorMinDelay(0xae39a257, 1209600)` | one **exact operation application + binding** | `A.6.1` | that the value survived — the POM admin may re-set it |
| `getSelectorMinDelay(0xae39a257) == 1209600` read from the live chain | a **Coordinate** on one Characteristic × Scale | `A.18` / `C.16` | that the value is *right* |
| "14 days, because replacing the hooks replaces all transfer policy" | a **choice** over an option set | `C.11` | any of the other four |

`A.6.RSIR:4.4` explicitly licenses keeping "parameter" as ordinary prose, and this document does
that — the word stays in the prose while each row separately names the Characteristic, the
deployed Coordinate, the change path, and the disposition.

### 0.2 Why the distinction pays for itself here — the `0xad0f7c64` case

`A.6.RSIR:4.2.1` closes with the rule that matters: *"Neither the declaration nor representation
syntax establishes the binding."* A value shown at a representation position establishes neither
actual participation nor that the relation obtains.

On `lido-2.0`, `default_config.json` violated exactly that. It carried a representation position
pairing a label with a selector:

```json
{ "function": "transferAdminRole(address,address)",
  "selector": "0xad0f7c64",
  "delay_seconds": 1209600,
  "reason": "Admin role transfer requires extended 2-week delay" }
```

The **`function` field is prose**; the **`selector` field is what the chain binds**. Nothing in the
pipeline relates the two, and they did not correspond:

```
$ cast sig 'transferAdminRole(address,address)'
0xddadfa8e
```

So `2_Configure` bound a 14-day minimum delay to `0xad0f7c64` — a selector matching **no function on
any `L1-POM` / `L2-POM` target** — while the real `transferAdminRole` fell through to the 3-day global default
(`getSelectorMinDelay` returns the global when the override is 0). The `reason` string read as if
the protection existed. It did not. The same file also omitted `setPool` entirely.

**`lido-proposals` absorbed both of those.** `cae743f` binds `0xddadfa8e`; `ad1c649` adds
`0x4e847fc7` `setPool` at 14 d. We still inject our own default config via
`vm.envOr("DEFAULT_CONFIG", …)` (`script/_common.sh` `run_ccip_script`) because two bindings are
ours alone: `0x3f4ba83a` `unpause()` Blocked, and `0x869b7f62` `setDynamicConfig((address,address))`
on the CCV verifier at 14 d. The submodule's own file stays pristine, so a further upstream fix
still shows up as a real diff. See [`config/README.md`](../config/README.md).

**There are two injected files, and the chain picks.** `config/default_config.json` is the **L1
hub**'s; `config/default_config.non_l1.json` is every **non-L1 spoke**'s. They differ in exactly one
row — `0x3f4ba83a` is Blocked on the hub and **not** blocked on a spoke, so `chainlink_mcms` can
queue `hooks.unpause()` there at the 3-day global — and `just lint-config` fails if anything else
diverges. The rationale (the spoke admin is the `OptimismBridgeExecutor`, reachable only through the
L1→L2 hop) and the cost (Emergency can no longer hold a spoke `BRIDGE` pause without escalating to
`POM.shutdownProposalQueue()`) are in [`config/README.md`](../config/README.md) § *The hub/spoke row*.

The phantom `0xad0f7c64` is **still pinned** in `config/state-mate/wsteth.yaml` at the **3-day
global**, but it is no longer an injection-failure detector — `lido-proposals` also leaves it at
the global. On **L1** the detectors are the two rows this pin does not carry:
`getSelectorProposalMode(0x3f4ba83a) = Blocked` and `getSelectorMinDelay(0x869b7f62) = 1209600`.
On a **spoke** only the second one detects: an injection failure there would leave `0x3f4ba83a`
unblocked, which is exactly the intended value. See the two POM blocks of
`config/state-mate/wsteth.yaml`.

This is not a typo caught by luck. It is the predicted failure mode of consuming a representation
position as if it were an operation binding, and it is why the rows below carry the *recovered
Characteristic*, never just the JSON path.

### 0.3 The second repair — `expiryPeriod` is not `validity_period`

The same class, benign so far. The JSON field is `governance.validity_period_seconds`; the
`ArgumentDeclaration` it feeds is `PoolOperationManager.initialize(address tokenPool, ProposalMode proposalMode, uint40 minDelay, uint40 expiryPeriod, InitialRoles initialRoles)`; and
the semantics are neither "validity" nor a period *of* validity:

```solidity
/// @dev The execution window is [timestamp + delay, timestamp + expiryPeriod].
/// This means the effective execution window duration is (expiryPeriod - delay).
```

So `2592000` is not "proposals are valid for 30 days" — it is the **right edge of the execution
window measured from proposal creation**, and the usable window is `expiryPeriod − delay`: 27 days
for a 3-day-delay proposal, 16 days for a 14-day one. The consequence of the naming drift is
recorded as a coupling in [§7](#7-where-the-scale-is-not-what-it-looks-like).

### 0.4 What this document is not

| Question | Not here — go to |
|---|---|
| who may change a parameter, and under which gate | [`PERMISSIONS.md`](./PERMISSIONS.md) §2.2, §3 |
| which structure a parameter sits in | [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1–§5 |
| what required effect a parameter serves, and whether it has a bearer | [`FUNCTION.md`](./FUNCTION.md) §1–§2, §7 |
| which side (deploy vs. checks) *writes* a config field | [`config/README.md`](../config/README.md) |
| whether the live testnet can enforce a gate at all | [`LIVE_DEPLOY_CONCERNS.md`](./LIVE_DEPLOY_CONCERNS.md) |

And per **`G.5`** / `ARCHITECTURE.md` §5.3: **these rows are not ranked and carry no score.** There
is no "risk level" column, no weighting, and no aggregate. [§8](#8-the-open-set--parameters-still-bearing-a-decision)
groups the open rows by *what unblocks them*, which is a set-valued grouping, not an ordering.

---

## 1. How to read a row

Every row states, per **`A.18:7.5`** (*no bare numbers*): what the value characterizes, on what
scale in what unit, the deployed coordinate, who can move it and at what cost, and its disposition.

**Polarity** (`A.18:7.2`) is stated only where an ordered scale genuinely has one. Several rows
here have a **targeted optimum** rather than a direction (a rate limit that is too tight breaks the
bridge; too loose it stops being a limit), and several have a **sentinel level** where `0` /
`address(0)` / `[]` leaves the ordered scale entirely — those are collected in [§7](#7-where-the-scale-is-not-what-it-looks-like).

**Disposition** is the `C.11` result, and most rows are honestly *not* a `C.11` case:

| Disposition | Meaning | `C.11` reading |
|---|---|---|
| **settled** | option set was frozen and a choice was made; no feasible probe would change it | `choose now`, closed |
| **open — needs a number** | the option set is a continuum and nobody has stated the comparison basis | *not yet `C.11`* — reroute to `C.18`; the placeholder is not a decision |
| **open — needs a fix** | the deployed coordinate is outside the intended admissible set | `reject current set`; repair, then re-decide |
| **not a choice (L)** | an external/definitional fact, not ours to set | outside `C.11` entirely |
| **inherited** | an upstream CCIP default that was never examined here | *not yet `C.11`* — no option set was ever opened |

A `C.11` pass requires a frozen `OptionSet` and an explicit comparison basis (`C.11:4.2.1`). Rows
marked *open* or *inherited* have neither, and calling them "decided" would be the exact
`C.11:1` failure indicator: *"a decision was made" without an explicit decision record.*

**Quadrant** is the `A.6.B` L/A/D/E classification already used in `README.md` §5 and
`config/README.md`: **L** external/definitional fact · **A** admissibility gate · **D** authored
design commitment · **E** generated work-effect.

**Source keys.** `dc` = `lib/ccip/chains/evm/contracts/lido-hvmv/config/default_config.json` ·
`1_D` / `2_C` = the vendored `1_Deploy.s.sol` / `2_Configure.s.sol` · `cc` = `config/chains/<slug>.json` ·
`env` = environment variable read at deploy time.

---

## 2. Transfer-admission parameters — the values that gate a bridge tx

Feed gates **`A-RL-01`** and **`A-CCV-01`** (`ARCHITECTURE.md` §5.3). Owner of all of these at end
state is **`L1-POM` / `L2-POM`**, so every change path is *either* Agent `directCall` (immediate) *or* MCMS
`propose` → wait ≥ 3 d → `execute` (the POM admin may veto). See `PERMISSIONS.md` §3.2–§3.3.

| ID           | Source                                                                                     | Characteristic · Scale · Unit                                                                                        | Deployed coordinate                                                                      | Change path                                                                                        | Quadrant | Disposition                                                                                                      |
| ------------ | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------- |
| **P-RL-01**  | `dc.rate_limiter_defaults.outbound.capacity`                                               | Max wstETH admissible in one outbound (send) tx, and burst ceiling of the lane · ratio · wei                         | `500e18` (500 wstETH)                                                                    | `L1-POM` / `L2-POM` → `setRateLimitConfig` / `applyChainUpdates`                                   | **A**    | **open — needs a number**                                                                                        |
| **P-RL-02**  | `dc.rate_limiter_defaults.outbound.rate`                                                   | Outbound bucket refill · ratio · wei · s⁻¹                                                                           | `5787037037037037` — refills the full 500e18 cap in ~24 h (`×86400 = 500e18 − 3200 wei`) | ditto                                                                                              | **A**    | **open — needs a number**                                                                                        |
| **P-RL-03**  | `dc.rate_limiter_defaults.inbound.capacity`                                                | Max wstETH admissible in one inbound (receive) tx · ratio · wei                                                      | `330e18`                                                                                 | ditto                                                                                              | **A**    | **open — needs a number**                                                                                        |
| **P-RL-04**  | `dc.rate_limiter_defaults.inbound.rate`                                                    | Inbound bucket refill · ratio · wei · s⁻¹                                                                            | `3819444444444444` — full 330e18 in ~24 h                                                | ditto                                                                                              | **A**    | **open — needs a number**                                                                                        |
| **P-RL-05**  | `dc.rate_limiter_defaults.outbound.enabled` + `dc.rate_limiter_defaults.inbound.enabled`   | Whether the bucket is consulted at all · nominal `{true,false}`                                                      | `true` both directions                                                                   | ditto                                                                                              | **A**    | settled                                                                                                          |
| **P-CCV-01** | `2_C._configureAdvancedPoolHooks`                                                          | Verifier set our hooks **declare** as required, per lane and direction · nominal (set of addresses)                  | `[verifier_resolver]` — one entry, both `outboundCCVs` and `inboundCCVs`                 | `L1-POM` / `L2-POM` → `applyCCVConfigUpdates`                                                      | **D**    | settled                                                                                                          |
| **P-CCV-02** | `env CCV_THRESHOLD_AMOUNT` → `hooks.setThresholdAmount`                                    | Transfer amount at/above which the *additional* verifier set is also required · ratio · wei, **with a `0` sentinel** | `0` — escalation **disabled** (§7)                                                       | `L1-POM` / `L2-POM` → `setThresholdAmount`                                                         | **A**    | settled (deliberately off)                                                                                       |
| **P-CCV-03** | `2_C`                                                                                      | The additional verifier sets themselves · nominal (set)                                                              | `thresholdOutboundCCVs = []`, `thresholdInboundCCVs = []`                                | `L1-POM` / `L2-POM` → `applyCCVConfigUpdates`                                                      | **D**    | settled (deliberately empty)                                                                                     |
| **P-ALW-01** | `1_D`: `new PausableAdvancedPoolHooks(new address[](0), 0, address(0), authorizedCallers)` | Whether an origination allowlist is enforced · nominal `{enabled,disabled}`                                          | **disabled** — `i_allowlistEnabled = allowlist.length > 0` is `immutable`                | **none on this contract** — needs a new hooks deploy + `updateAdvancedPoolHooks` (14-day selector) | **D**    | settled — **and irreversible** (§7)                                                                              |
| **P-POL-01** | `1_D`: 3rd ctor arg                                                                        | External policy-engine hook · nominal, `address(0)` sentinel = "no policy engine"                                    | `address(0)`                                                                             | `L1-POM` / `L2-POM` → `setPolicyEngine`                                                            | **D**    | settled                                                                                                          |
| **P-FEE-01** | `dc.token_transfer_fee_defaults.dest_gas_overhead`                                         | Gas the fee quote reserves for destination-side pool execution · ratio · gas                                         | `150000`                                                                                 | `L1-POM` / `L2-POM` → `applyTokenTransferFeeConfigUpdates`                                         | **D**    | **inherited**                                                                                                    |
| **P-FEE-02** | `2_C.STOCK_SOURCE_POOL_DATA_LENGTH`                                                        | Declared `sourcePoolData` size for fee quoting · ratio · bytes                                                       | `32` (hard-coded constant, not config)                                                   | ditto                                                                                              | **D**    | **inherited** — matches the live OffRamp's `CCIP_POOL_V1_RET_BYTES = 32` cap; see `LIVE_DEPLOY_CONCERNS.md` §5.4 |
| **P-FEE-03** | `2_C`                                                                                      | Per-token finality/fast-finality fees and bps · ratio · USD cents / bps                                              | all `0`; `isEnabled = true`                                                              | ditto                                                                                              | **D**    | **inherited**                                                                                                    |
| **P-DEC-01** | `1_D`: `IERC20Metadata(token).decimals()`                                                  | Local token decimals baked into the pool at construction · ratio · digits                                            | `18` both chains — **read, not chosen**                                                  | immutable on the pool                                                                              | **L**    | not a choice (L)                                                                                                 |

> **The rate-limit rows are the largest genuinely open decision in this repo.** `500e18` out /
> `330e18` in are testnet placeholders. `C.11:4.2.1` needs a `PreferenceOrder` or
> `EvaluativeMeasure` over the option set before "500" can be called a choice, and there is none:
> nothing in the repo states the loss being traded off (throughput denied to honest users vs.
> value at risk in a compromise window), so the numbers are not comparable to any alternative.
> The right next step is `C.18` (construct the option set: what daily volume must the lane carry,
> what is the tolerable single-window exposure), not a `C.11` pass over the current pair.
>
> Note also the **asymmetry is unexplained**: inbound is 66 % of outbound, and no row in this repo
> says why. Under `A.18:7.1` these are two Coordinates on two distinct Characteristics (send-side
> vs. receive-side admission), so the ratio is not a derived quantity — it is a second, separate
> open decision.

> **`P-CCV-01` declares one verifier, not two.** The gate's membership rule is `A-CCV-01`, stated
> once in [`README.md` §5](../README.md#5-claim-register--boundary-norms-a6b-lade) — this row carries
> only the deployed **coordinate** (`A.6.B:6.1`). What that coordinate does: our hooks contribute
> **one** entry, the `VersionedVerifierResolver`, to the set the OffRamp assembles; the other
> contributors are the lane's `laneMandatedCCVs`. (The OffRamp's `defaultCCVs` are *not* a
> contributor here — on a token-only transfer they enter only when some entry is `address(0)`, which
> a non-empty pool declaration prevents.) `FUNCTION.md` §2.2 records that *declaring* the set (our
> hooks, a `view`) and *enforcing* it (`OffRamp 2.0._ensureCCVQuorumIsReached`) are different
> bearers. Raising `P-CCV-01` to two of our own verifiers would still not make the quorum enforceable
> on a 1.5 lane — no parameter on our side can.

---

## 3. Governance timelock parameters — POM

Feed gate **`A-POM-01`**. All five setters are `onlyRole(DEFAULT_ADMIN_ROLE)` on current upstream
bytecode and therefore belong directly to the DAO's Agent / OpExec path. See the warning after the table.

| ID | Source | Characteristic · Scale · Unit | Deployed coordinate | Change path | Quadrant | Disposition |
|---|---|---|---|---|---|---|
| **P-POM-01** | `dc.governance.proposal_mode` | Default disposition of a proposed call · nominal `{None=0, Veto=1, ExplicitApproval=2, Blocked=3}` | `Veto` (1) — passes unless the DAO admin vetoes; Emergency voids the queue with `pause()` (epoch++) | `setGlobalProposalMode` | **D** | settled |
| **P-POM-02** | `dc.governance.min_delay_seconds` | Floor on the delay a proposer may request · ratio · s | `259200` (3 d) | `setGlobalMinDelay` | **A** | **open — needs a number** |
| **P-POM-03** | `dc.governance.validity_period_seconds` → `initialize(expiryPeriod)` | **Right edge** of the execution window from creation; usable window is `expiryPeriod − delay` (§0.3) · ratio · s | `2592000` (30 d) ⇒ 27 d window at the global delay, 16 d at a 14-day override | `setGlobalExpiryPeriod` | **A** | **inherited** — coupled to P-POM-02/05 (§7) |
| **P-POM-04** | `dc.blocked_selectors` (**chain-dependent** — `config/default_config.json` on the L1 hub, `config/default_config.non_l1.json` on every spoke) | Selectors the timelock refuses outright · nominal (set of `bytes4`) | **Both:** `{0xf2fde38b}` = `transferOwnership(address)`, `{0x4f1ef286}` = POM UUPS `upgradeToAndCall(address,bytes)`. **L1 additionally:** `{0x3f4ba83a}` = hooks `unpause()`. On a spoke `0x3f4ba83a` falls to the 3-day global so MCMS can queue it (`config/README.md` § *The hub/spoke row*) | `setSelectorMode` | **A** | settled |
| **P-POM-05** | `dc.custom_delay_selectors` (**ours** — `config/default_config.json`, injected via `DEFAULT_CONFIG`) | Per-selector delay floor overriding P-POM-02; `0` ⇒ fall back to the global · ratio · s, **`0` sentinel** | `1209600` (14 d) on `0xddadfa8e` `transferAdminRole`, `0x4e847fc7` `setPool`, `0xae39a257` `setDynamicConfig` (pool), `0x869b7f62` `setDynamicConfig` (CCV), `0xbfeffd3f` `updateAdvancedPoolHooks`, `0xefd07eec` `configureLockBoxes`. `lido-proposals` now carries the first two; the CCV overload is still ours. Phantom `0xad0f7c64` stays at the global (§0.2) | `setSelectorMinDelay` (`onlyRole(DEFAULT_ADMIN_ROLE)`) | **A** | settled (§0.2) |
| **P-POM-06** | `cc.governance_addresses.*` → `1_D.InitialRoles` | Initial holder of each `L1-POM` / `L2-POM` role · nominal (address sets) | `admin=deployer` (handed to Agent/OpExec in step 3/07, then revoked), `proposer=chainlink_mcms`, `halters=[emergency_brakes, chainlink_mcms]`; there is no guardian initializer seat. Emergency kills a bad MCMS queue with `shutdownProposalQueue()` (epoch++). The two non-deployer holders are **distinct addresses** derived from `ACTORS_MNEMONIC` (`.env`) | `grantRole`/`revokeRole` (admin) | **D** → **E** | see `PERMISSIONS.md` §2.2 |
| **P-POM-07** | `1_D`: `resumers: new address[](0)` | Who may unpause without being admin · nominal (set) | **empty** — only `DEFAULT_ADMIN_ROLE` (Agent, or OpExec on L2) can unpause | `grantRole(RESUME_ROLE, account)` | **D** | settled — deliberate asymmetry (`PERMISSIONS.md` §4) |
| **P-POM-08** | `cc.governance_addresses.chainlink_executors` | Who may call `execute` on a ripened proposal · nominal (set) | **`[]`** on both chains ⇒ `execute` is **permissionless** (`if (getRoleMemberCount(EXECUTOR_ROLE) != 0) _checkRole(...)`) | `grantRole(EXECUTOR_ROLE, account)` | **D** | settled — but the *empty ⇒ open* semantics is a sentinel (§7) |
| **P-POM-09** | `1_D` | `L1-POM` / `L2-POM` upgradeability · nominal | UUPS behind `ERC1967Proxy`; `_authorizeUpgrade` requires `DEFAULT_ADMIN_ROLE`; proposal selector `0x4f1ef286` is Blocked | Agent / OpExec calls proxy `upgradeToAndCall` directly | **D** | settled — rehearsed on both forks by `RealPomUpgrade` |

> **The timelock's own parameters are not behind the timelock, but they are DAO-only.**
> `setGlobalMinDelay`, `setGlobalProposalMode`, `setGlobalExpiryPeriod`, `setSelectorMinDelay` and
> `setSelectorMode` are `onlyRole(DEFAULT_ADMIN_ROLE)` on upstream bytecode. Only the Agent — or
> `OpExec` on L2 — may move P-POM-01–05, and it does so immediately, with no proposal, no delay
> and no veto window. So the 14-day protection on
> `updateAdvancedPoolHooks` is worth 14 days only for as long as the **DAO admin** leaves it there;
> the Agent — or `OpExec` on L2 — can set it to 0 and then the 3-day global applies. This is by
> design (`PERMISSIONS.md` §2.2, `D-ACT-01`), but it means P-POM-02/03/05 are *conventions the DAO
> admin upholds*, not constraints on it.

---

## 4. L2 governance and token parameters

| ID | Source | Characteristic · Scale · Unit | Deployed coordinate | Change path | Quadrant | Disposition |
|---|---|---|---|---|---|---|
| **P-OPX-01** | `env OPEXEC_DELAY` | Delay before a queued L1→L2 action set may execute · ratio · s | **`0`** | queued `updateDelay` (`onlyThis`) — needs an L1 Agent vote + cross-chain message | **D** | **open — needs a number** (testnet default) |
| **P-OPX-02** | `env OPEXEC_GRACE_PERIOD` | Window after ripening in which an action set stays executable · ratio · s | `86400` (1 d) | queued `updateGracePeriod` | **D** | **open — needs a number** |
| **P-OPX-03** | `env OPEXEC_MIN_DELAY` / `OPEXEC_MAX_DELAY` | Bounds within which P-OPX-01 may later be set · ratio · s | `0`–`86400` | queued `updateMinimumDelay` / `updateMaximumDelay` | **D** | **open — needs a number** |
| **P-OPX-04** | `env OPEXEC_GUARDIAN` | Who may `cancel` any queued action set · nominal (address) | **the deployer EOA** (script default; never rotated by the pipeline) | queued `updateGuardian` | **D** → **E** | **open — needs a fix before mainnet** |
| **P-OPX-05** | `env L1_AGENT` | `ethereumGovernanceExecutor` — the only L1 sender OpExec accepts · nominal (address) | the L1 Aragon Agent | queued `updateEthereumGovernanceExecutor` (`onlyThis`) — i.e. the current L1 root must vote to hand over its own reach | **D** | settled — pinned by Claim A |
| **P-TOK-01** | `DeployL2Token.s.sol` constants | L2 token metadata · nominal | `"Wrapped liquid staked Ether 2.0"` / `wstETH` / `18` | impl upgrade via `ProxyAdmin.upgradeAndCall` (ProxyAdmin owner = OpExec) | **D** | settled |
| **P-TOK-02** | *(retired 2026-08-27)* `DeployL2Token.s.sol`: `bridge_` | Legacy `ERC20Bridged` `onlyBridge` mint/burn path | **no longer a parameter** — the whole `bridge`/`bridgeMint`/`bridgeBurn` surface is removed from the base, so there is nothing to choose — by `patches/lido-l2-with-steth/0001` until 2026-09-02, and upstream in the pinned branch `feat/token-upgrade` since. It was `address(0)` while the oldest base allowed that sentinel; `main` rejects it (`ErrorZeroAddressBridge`), and every remaining value would have left a live `bridgeMint` selector guarded only by key custody | n/a | — | closed — a parameter deleted beats a parameter set safely. Asserted on-chain by step 03 (`bridge()` must not exist) |
| **P-TOK-03** | `DeployL2Token.s.sol`: `VERSION` | EIP-712 signing-domain version — enters every `permit` signature the token will ever accept · nominal | **`"2"`** — matches wstETH on OP Mainnet and the `Versioned` contract version `initialize` sets (upstream rule: the two agree) | impl upgrade only, and it invalidates outstanding signatures | **D** | settled — see `adr/l2-token-contract.md` §10.6 |

> **`P-OPX-04` is the L2 twin of the deployer-key problem.** The OpExec guardian holds
> `cancel` over *every* queued governance action set — including the one that would rotate the
> guardian. `config/state-mate/wsteth.yaml:1272` pins `getGuardian: *deployer` precisely so this
> cannot silently sit with an unexpected key, and labels it a live-testnet interim. Rotating it
> requires an L1 DAO action that the current guardian could cancel, so the ordering matters.

---

## 5. CCV stack parameters

The whole block is inert on 1.5-only lanes (`LIVE_DEPLOY_CONCERNS.md` §2) — only a 2.0 OffRamp
reads any of it.

| ID | Source | Characteristic · Scale · Unit | Deployed coordinate | Change path | Quadrant | Disposition |
|---|---|---|---|---|---|---|
| **P-CCV-04** | `env STORAGE_LOCATION` | Off-chain location the verifier advertises for its proofs · nominal (URI set) | `["dummy://message-id-verifier"]` | `L1-POM` / `L2-POM` → `updateStorageLocations` | **D** | **inherited** — a placeholder URI |
| **P-CCV-05** | `env FEE_AGGREGATOR`, default `cc.governance_addresses.lido_dao_agent` | Recipient of `withdrawFeeTokens` (permissionless call, fixed destination) · nominal | Agent (L1) / OpExec (L2) — pinned by Claim A on the resolver | `L1-POM` / `L2-POM` → `setDynamicConfig` / `setFeeAggregator` | **D** | settled |
| **P-CCV-06** | `env ALLOWLIST_ADMIN`, default `s_deployer` | Second party (besides the owner) who may call `applyAllowlistUpdates` on the verifier · nominal | **the deployer EOA** — never rotated by the pipeline; Claim A pins `getDynamicConfig: [agent‖opExec, deployer]` | `L1-POM` / `L2-POM` → `setDynamicConfig` | **D** → **E** | **open — needs a fix before mainnet** |
| **P-CCV-07** | `env RMN_REMOTE`, default `cc.ccip.rmn_proxy` | Risk-network the verifier consults · nominal | the real Chainlink ARMProxy | `L1-POM` / `L2-POM` (verifier is immutable in this field — redeploy) | **L** | not a choice (L) |
| **P-CCV-08** | `2_C` constants | Per-remote-chain verifier config: `gasForVerification`, `payloadSizeBytes`, `feeUSDCents`, `allowlistEnabled` · ratio (gas, bytes, USD cents) / nominal | `1`, `36`, `0`, `false` | `L1-POM` / `L2-POM` → `applyRemoteChainConfigUpdates` | **D** | **inherited** — `gasForVerification = 1` is a dummy-verifier value, not a real cost estimate |

---

## 6. Topology and identity — the rows that are not ours to choose

`A.6.B` **L** quadrant: external or definitional facts. They appear here because they are read as
inputs at deploy time and a wrong one is a deploy defect, but no `C.11` question attaches.

| ID | Source | What it fixes | Deployed coordinate |
|---|---|---|---|
| **P-TOP-01** | `cc.chain.pool_type` | Which pool contract is deployed · nominal `{SiloedLockRelease, BurnMint}` | L1 `SiloedLockRelease` (the hub), L2 `BurnMint` (the spoke) — definitional, ties to `L-SILO-01` |
| **P-TOP-02** | `cc.remote_lanes[].is_siloed` | Whether the lane gets a dedicated `ERC20LockBox` · nominal | `true` on sepolia's remote lane ⇒ a dedicated box. **`false` on the L2 record is inert** — L2 is BurnMint, so `_deployLockBoxes` never runs there |
| **P-TOP-03** | `cc.ccip.chain_selector` | CCIP lane identity · nominal | `16015286601757825753` (sepolia) / `8236463271206331221` (mantle_sepolia) |
| **P-TOP-04** | `cc.ccip.{router,rmn_proxy,token_admin_registry,registry_module_owner}` | The Chainlink contracts we reference, never deploy | the real 1.5/1.6 addresses; FFI-refreshable by `1_Deploy` |
| **P-TOP-05** | `env L2_CHAIN`, `env RECORD_DIR` | Which pair the pipeline drives; which record verification reads | `mantle_sepolia`; `config/chains` — **harness selectors, not deployed state**; they change what is checked, never what is on chain |

---

## 7. Where the scale is not what it looks like

`A.18:7.4` (*scale-appropriate operations only*) and `C.16.P:5` (`threshold` and `level` are
trigger words, not recovered kinds). Five rows here would be misread by treating the number as an
ordinary point on an ordered scale.

### 7.1 Sentinel levels — where `0` leaves the scale

| Row | Looks like | Actually |
|---|---|---|
| **P-CCV-02** `getThresholdAmount = 0` | "escalate to extra verifiers above 0 wei" — i.e. *always* | **escalation off.** `_resolveRequiredCCVs` guards `thresholdAmount != 0 && amount >= thresholdAmount`. `0` is a disable sentinel, so the polarity ("lower is stricter") **inverts at the endpoint** |
| **P-POM-05** per-selector delay `0` | "no delay for this selector" | **fall back to the global 3 d.** `getSelectorMinDelay` returns `getGlobalMinDelay()` when the override is 0 — so `0` is stricter than a small positive value |
| **P-POM-08** `EXECUTOR_ROLE = []` | "nobody may execute" | **anybody may execute.** The role is checked only when non-empty |
| **P-POL-01** `address(0)` | "unset, fill in later" | **permanently off.** No key can ever be `address(0)`, so the guarded path is unsatisfiable rather than pending. (`P-TOK-02` used to sit in this row on the same reasoning; it is retired — the surface it guarded no longer exists) |
| **P-ALW-01** `allowlist = []` | "empty allowlist, add entries later" | **allowlisting disabled forever on this contract.** `i_allowlistEnabled` is `immutable` and derived from `allowlist.length > 0` at construction; `applyAllowListUpdates` reverts `AllowListNotEnabled` |

`P-ALW-01` is the one irreversible parameter in the deployment. Turning allowlisting on later is not
a parameter change at all — it is a new `PausableAdvancedPoolHooks` deploy plus
`updateAdvancedPoolHooks`, which is a 14-day-delay selector and swaps every pause and CCV setting
in one move.

### 7.2 Coupled coordinates — two rows, one admissible region

**P-POM-02 / P-POM-05 / P-POM-03.** `propose` enforces
`minDelay > delay || delay > expiry ⇒ revert InvalidDelay`, where `expiry = getGlobalExpiryPeriod()`.
So for **every** selector the deployment must satisfy

```
getSelectorMinDelay(s)  ≤  getGlobalExpiryPeriod()
```

Today: `1209600 (14 d) ≤ 2592000 (30 d)` ✓, with a 16-day margin. But `_setGlobalExpiryPeriod` has
**no validation**, and the contract's own natspec says so: *"Setting a selector delay above the
expiry period will cause proposals for this selector to revert until corrected."* Either setter,
called alone by the POM admin, can brick a selector's proposal path — and `getGlobalExpiryPeriod` is
**not pinned** by Claim A ([§9](#9-pin-coverage--what-claim-a-would-catch)), so nothing would flag it.

Under `A.18:7.1` these are three Coordinates on three distinct Characteristics that share one
admissible region. They must not be tuned independently.

**P-CCV-02 / P-CCV-03.** Amount-based CCV escalation is off *twice over*: the threshold is `0` and
the threshold sets are empty (`thresholdCCVs.length > 0` is a second guard). Setting
`setThresholdAmount(x)` alone changes nothing. Enabling escalation is a two-call change, and only
the pair is meaningful.

---

## 8. The open set — parameters still bearing a decision

Grouped by **what unblocks the row**, not ranked (`G.5`). No ordering between groups is implied and
none should be read into the sequence.

**A — needs a fix; the deployed coordinate is outside the intended set**

- ~~**P-POM-05** — `0xad0f7c64` protects nothing~~ — **closed.** `lido-proposals` absorbed the
  selector fix and the `setPool` override; our injected file still adds the CCV
  `setDynamicConfig` overload and Blocks hooks `unpause()`. `0xad0f7c64` stays pinned at the
  global. (§0.2)
- **P-OPX-04** — OpExec guardian is the deployer EOA. Rotating it requires an L1 governance action
  the current holder can `cancel`, so sequencing matters. (§4)
- **P-CCV-06** — verifier `allowlistAdmin` is the deployer EOA. Rotate via `L1-POM` / `L2-POM` `setDynamicConfig`.
  Lower blast radius than P-OPX-04 (the verifier allowlist is disabled), but it is a live EOA grant
  that survived the handover. (§5)

**B — needs a number, and first needs a stated comparison basis (`C.18` before `C.11`)**

- **P-RL-01–04** — the four rate-limit coordinates. Nothing in the repo states the loss being
  traded off, so no alternative is comparable to the current pair. The inbound/outbound asymmetry
  is a second, separate open question. (§2)
- **P-POM-02** — 3-day global delay. What incident-response latency is it sized for?
- **P-OPX-01–03** — OpExec delay/grace/bounds are all disposable-testnet values (`delay = 0`).

**C — inherited upstream defaults nobody in this repo has examined**

- **P-POM-03** (`expiryPeriod`), **P-FEE-01–03**, **P-CCV-04**, **P-CCV-08**. Each is `inherited`
  in the tables above: no option set was ever opened, so there is no decision to review — only a
  decision not yet taken. `P-POM-03` is the one of these that is coupled to a gate (§7.2).

**D — settled, and recorded here so a later change is a deliberate reopening**

- **P-ALW-01** (irreversible), **P-POM-07** (empty resumers), **P-POM-08** (permissionless
  execute), **P-POM-09** (both POMs are admin-authorized UUPS proxies), **P-TOK-03** (`VERSION` — changing it invalidates
  every outstanding `permit` signature),
  **P-CCV-02/03** (escalation off).

---

## 9. Pin coverage — what Claim A would catch

`E-STATE-01` (`config/state-mate/wsteth.yaml`) is the canonical evidence carrier for parameter
drift; its getter rows, not a copied static list here, define current pin coverage. Relevant to the
POM upgrade boundary, it pins `typeAndVersion`, `UPGRADE_INTERFACE_VERSION`, global mode/delay/
expiry, all configured selector modes and delays (including Blocked `0x4f1ef286`), role membership
and cardinality, pool/hooks bindings, epoch, and pause state. Step 08 independently resolves the
ERC-1967 implementation slot and validates `proxiableUUID`; `RealPomUpgrade` then exercises the
state-changing admin path and compares those configured coordinates across the upgrade.

The main remaining config-only field is `registry_module_owner`: it is used during TAR registration
but is not a persistent coordinate exposed by one of our contracts after deployment.

Principal distinctness (`L-SEP-01`) remains outside state-mate's contract-call surface and is
tracked in `PERMISSIONS.md` §2.2.4 rather than restated here (`A.6.B:6.1`, `CC-A.6.B.4`).

---

## 10. FPF cross-reference

| Where | Pattern | What it does here |
|---|---|---|
| §0.1–§0.3 | **`A.6.RSIR`** | Separates representation position / `ArgumentDeclaration` / exact binding / Coordinate / choice behind the word "parameter"; `:4.2.1` is the rule the `0xad0f7c64` defect broke (§0.2, now closed); `:4.4` licenses keeping "parameter" as prose |
| §0.2 | `A.6.1` | `ArgumentDeclaration` vs. one exact operation application and its actual bound value |
| every row | **`A.18`** | Characteristic ⟷ Scale ⟷ Level ⟷ Coordinate; `:7.5` *no bare numbers* is why no row shows a value without its scale and unit |
| §2, §7.1 | **`C.16.P`** | `threshold`, `rate`, `level` are trigger words — `:5` forces the predicate, cut value and non-use boundary into the open |
| §1, §8 | **`C.11`** | Disposition; `:4.2.1` well-formedness is why placeholder values are recorded as *not yet a decision* rather than as decisions |
| §8 group B | `C.18` | Where a row's option set has to be built before a choice is possible |
| quadrant column | **`A.6.B`** | L/A/D/E, consistent with `README.md` §5 and `config/README.md` |
| §0.4, §8 | **`G.5`** | No score, no ranking, no aggregate over these rows |
| §7.2 | `A.18:7.1`, `A.19` | Coupled coordinates share one admissible region and must not be tuned independently |
| §9 | `A.10`, `B.3` | Evidence is referred (`E-STATE-01` pins), not asserted; unpinned rows are named as unpinned |

# Function — wsteth-2.0 (functional description, end state)

> **September 15 deployment:** use [Current deployment and POM permissions](CURRENT-DEPLOYMENT.md)
> and the [deployment report](deployment-2026-09-15.md). The detailed POM descriptions below
> are historical: proposal modes, guardian/veto/approval APIs and combined pause roles no longer apply.

**What this system is *for*, decomposed into the behaviours that deliver it and the bearers those
behaviours are allocated to.** This is the **`FunctionalStructure` view** that
[`ARCHITECTURE.md`](./ARCHITECTURE.md) does not carry: that file holds the placement, control, flow,
custody and trust-boundary views; [`PERMISSIONS.md`](./PERMISSIONS.md) holds the authority model; this
file holds *what has to happen, who bears it, and what is still only a requirement*.

---

## 0. What this document is — `C.30.ASV` + `A.6.F`

Read this before the tables, so the rest is read with the right force.

Per FPF **`A.6.F`** (RPR-FUNCTION), function-like wording carries no FPF claim by itself. This document
therefore **does not mint a `U.Function` kind** (`CC-A6F-2`). Every row below is one of three things,
kept apart on purpose (`C.30.ASV` §4.6):

| Branch | What it is here | Where it lives |
|---|---|---|
| **required behaviour / effect** (`RB-*`) | claim content — "this shall happen, under these conditions" | [§1](#1-required-effects--what-the-system-is-for), this document |
| **functional element** (`FE-*`) | a required behaviour **plus a bearer or candidate bearer** in the deployed holon | [§2](#2-functional-elements--behaviour-allocated-to-a-bearer) |
| **actual transformation** (`U.Transformation`) | an independently grounded, dated change — recovered under `A.3.4`, never by requirement wording | [§4](#4-required-effect-vs-actual-transformation--the-a34-line), and only there |

Filled `FunctionalStructureViewUse` record (`C.30.ASV` §4.6):

| Field | Value |
|---|---|
| `structureKindRef` | **`FunctionalStructure`** |
| `describedHolonRef` | the `wsteth-2.0` deployments that **exist** — Lido core + DG on L1 with wstETH bridged via CCIP to an L2, on the anvil forks and the live testnet pair ([`README.md` §1.1](../README.md#11-substrates--the-canonical-status-claim)) |
| `boundedContextRef` | those substrates: Sepolia (L1) ↔ Mantle Sepolia (L2). The **live-network target** (Ethereum mainnet + an OP-stack L2) is *expected content of the architecture claim*, **not** this view's subject — `CC-C30-1`, `ARCHITECTURE.md` §0 |
| `selectedStructureRef` | the transfer-and-governance behaviour organisation of that holon: the `RB-*` set of [§1](#1-required-effects--what-the-system-is-for) and its allocation to the `FE-*` bearers of [§2](#2-functional-elements--behaviour-allocated-to-a-bearer) |
| `viewConstruction` | `directDescription` — authored from the deployed sources and `config/state-mate/wsteth.yaml`, not projected from a model |
| `structureKnowledgeState` | `declared` for the required effects; `observed` for the bearer allocations (they are pinned by Claim A); `unknownRegionPresent` for the external CCIP/OP bearers ([§2.3](#23-bearers-outside-the-boundary)) |
| `selectedTransformationFlowStructureRefs` | the flow organisation is **not restated here** — it is `ARCHITECTURE.md` §5.1 (`FlowTransductionStructure`), related to this view per `C.30.TFS-REL` and cited, not duplicated |
| `hiddenOrLostStructure` | fee economics, gas, DON scheduling and finality timing are outside the selected structure; per-lane liveness is not modelled |
| `admissibleUse` | decide what has to work for a transfer or a governance change to complete; find which contract bears a given behaviour; see which required effects have **no bearer** today ([§7](#7-required-behaviour-with-no-current-bearer--the-gaps)) |
| `nonAdmissibleUse` | **not** proof that any of it happened (that is Claim B, `B.3`); **not** an assurance verdict; **not** a substitute for `ARCHITECTURE.md` topology or `PERMISSIONS.md` authority; **not** a quality or "security" claim ([§6](#6-functionality-is-not-a-quality-claim)) |

> **The one repair this document exists to make — and where it has been applied.** The repo's prose
> used to say *"the only **capability** the live 1.5 path cannot enforce is the dual-CCV quorum"*.
> Under `A.6.F` that sentence bundles three separately governed things: a **required effect** (inbound
> value is admitted only when the required verifiers have reported), a **gate** that would enforce it
> (`A-CCV-01`), and a **bearer** that must exist for the gate to run (an OffRamp 2.0). It is not a
> `U.Capability` (`A.2.2`) at all. Split that way the situation states itself exactly: the requirement
> stands ([`RB-05`](#1-required-effects--what-the-system-is-for)), the gate is specified (`A-CCV-01`),
> **the bearer is absent on 1.5-only lanes** ([`FE-06`](#22-behaviour-borne-by-the-ccip-transport)).
>
> The split is now carried at the sites that used the bundled word: `README.md` §4, `ARCHITECTURE.md`
> §6, and `LIVE_DEPLOY_CONCERNS.md` §2's ledger — each by reference to `RB-05` / `A-CCV-01` / `FE-06`
> rather than by restating the analysis (`CC-A6F-2`, `CC-A6F-4`; `A.6.B:6.1`).

---

## 1. Required effects — what the system is *for*

Claim content under `A.6.B` quadrant conventions already used in `README.md` §5. **None of these
asserts that anything happened** (`CC-A6F-4A`); each names the conditions under which it is to hold.

| ID | Required effect | Conditions it is scoped to | Realised by | Gate refs |
|---|---|---|---|---|
| **RB-01** | A holder of L1 wstETH obtains an equal balance of L2 wstETH at a named recipient, and the L1 principal is escrowed for the duration | the lane is supported and un-paused, the amount fits the outbound bucket, the message is attested | `FE-01` → `FE-02` → `FE-04` → `FE-06` → `FE-08` | `A-RL-01`, `A-CCV-01` |
| **RB-02** | The mirror: L2 supply is retired and the corresponding L1 principal is released from that lane's custody | as above, inbound direction | `FE-01` → `FE-03` → `FE-04` → `FE-06` → `FE-07` | `A-RL-01`, `A-CCV-01` |
| **RB-03** | **Conservation** — per lane, escrowed L1 principal equals total L2 supply minted against it | across any sequence of completed round trips | `FE-02` + `FE-03` + `FE-07` + `FE-08` jointly | `L-SILO-01` |
| **RB-04** | **Lane isolation** — a compromise confined to one remote lane cannot reach another lane's escrowed principal | more than one remote lane configured | `FE-02` / `FE-07` (one `ERC20LockBox` per lane) | `L-SILO-01` |
| **RB-05** | Inbound value is admitted only when the required independent verifiers have reported | the destination ramp reads and enforces the pool's declared verifier set | `FE-05` (declare) + `FE-06` (enforce) | `A-CCV-01` |
| **RB-06** | **Throughput containment** — per lane, per direction, transferred volume stays inside a refilling budget | rate limiter enabled on the lane | `FE-01` (outbound), `FE-06` (inbound) | `A-RL-01` |
| **RB-07** | **Halt** — a designated actor stops transfers within one transaction, at three granularities: everything, one pool, one `(lane, direction)` | the actor holds `HALT_ROLE` or is `L1-POM` / `L2-POM` admin | `FE-10` | `A-POM-01` |
| **RB-08** | **Resume is strictly narrower than halt** — restarting is reserved to governance and touches only what it names | — | `FE-10` | `A-POM-01` |
| **RB-09** | **Governance reach** — one L1 DAO decision changes configuration on either chain, with no second trust root | the L2 leg is pinned to the L1 Agent | `FE-09` + `FE-11` | `D-GOV-01`, `A-POM-01` |
| **RB-10** | **Delayed change with a veto window** — a configuration change proposed by the operator is executable only after its delay and only if not vetoed; the DAO retains an immediate path | proposer role and DAO-admin veto authority configured as in `PERMISSIONS.md` §5 | `FE-11` | `A-POM-01` |
| **RB-11** | **Verifiability** — the end-state authority and parameter configuration is machine-checkable against a declared expectation | a deployment record exists | `FE-13` | `E-STATE-01` |

---

## 2. Functional elements — behaviour allocated to a bearer

A row is a `FunctionalElementClaim` (`C.30.ASV` §4.6) only because **both** the behaviour claim and a
bearer are current. **Ports** are behaviour input/output slots under `A.6.0` signature discipline —
they are *not* module interfaces (`CC-A6F-9`, see [§5](#5-functional-ports-are-not-module-interfaces)).

IDs run in flow order, so the two sub-tables interleave: `FE-04`, `FE-06` and `FE-14` sit in
[§2.2](#22-behaviour-borne-by-the-ccip-transport) because their bearer is the CCIP transport, not us.

### 2.1 Behaviour borne inside the boundary

| ID | Required behaviour | Bearer (allocated) | Input condition | Output condition | Functional ports |
|---|---|---|---|---|---|
| **FE-01** | **Send-side admission** — decide whether an outbound transfer may proceed, and consume its budget | `TokenPool._validateLockOrBurn` → `PausableAdvancedPoolHooks.preflightCheck` | supported token; `!RMN.isCursed(sel)`; `msg.sender == Router.getOnRamp(sel)`; finality allowed; outbound bucket ≥ amount; hooks not paused; outbound lane not disabled | admit (bucket debited) or revert | `lockOrBurn(Pool.LockOrBurnInV1)` · `preflightCheck(lockOrBurnIn, finality, tokenArgs, amountPostFee)` |
| **FE-02** | **Custody escrow (L1)** — place principal into the lane's dedicated box | `ERC20LockBox.deposit`, driven by the L1 `SiloedLockReleaseTokenPool` | caller is the box's sole `authorizedCaller` | box balance increased by the amount | `deposit(...)` |
| **FE-03** | **Supply retirement (L2)** — retire the sending balance | `BurnMintTokenPool` → `ERC20BridgedPermit.burn` | caller holds `BURNER_ROLE` | L2 total supply reduced | `burn(uint256)` |
| **FE-05** | **Declare the required verifier set** — publish, per lane and direction, which verifiers a transfer must carry | `PausableAdvancedPoolHooks` CCV config | lane configured via `applyCCVConfigUpdates` | the set the destination ramp is to enforce | `getRequiredCCVs(...)` · `getCCVConfig(sel)` · `getThresholdAmount()` |
| **FE-07** | **Custody release (L1)** — pay out from the *same* lane's box | `ERC20LockBox.withdraw`, driven by the L1 pool | inbound admission passed (`FE-06`) | recipient credited from that box only | `withdraw(...)` |
| **FE-08** | **Supply issuance (L2)** — mint against an L1 lock | `BurnMintTokenPool` → `ERC20BridgedPermit.mint` | caller holds `MINTER_ROLE` | recipient credited | `mint(address,uint256)` |
| **FE-09** | **Governance command transport (L1→L2)** — carry one L1 decision to the L2 authority without introducing a second root | `OptimismBridgeExecutor` (`queue` → `execute`) | `msg.sender` is the OP `L2CrossDomainMessenger` **and** `xDomainMessageSender() == Agent`; delay `0`, grace `1 day` | an executed L2 action set | `queue(...)` · `execute(actionsSetId)` |
| **FE-10** | **Halt and resume** — three independent surfaces, no cross-triggering | `PoolOperationManager` passthroughs → `PausableAdvancedPoolHooks` | pause: `HALT_ROLE` or admin. resume: admin only (`RESUME_ROLE` is ∅) | manager epoch bumped / hooks globally paused / named lanes disabled | `pause` · `pauseTokenPool` · `pauseRemoteLanes` and their three inverses |
| **FE-11** | **Operations gating** — admit a configuration change either immediately or after a delay with a veto window | `PoolOperationManager` | immediate: `DEFAULT_ADMIN_ROLE`. delayed: `propose` → delay (3 d, or 14 d on the pinned selectors) → `Ready` → `execute`, unless vetoed | the call lands on pool · hooks · lockbox · CCV · TAR entry | `directCall(target,value,data)` · `propose` / `veto` / `approve` / `execute` |
| **FE-12** | **Binding registration** — make the token routable by declaring its pool | `TokenAdminRegistry` entry, administered by `L1-POM` / `L2-POM` | caller is the per-token `administrator` | `token → (admin = L1-POM / L2-POM, pool)` | `setPool(token,pool)` · `transferAdminRole(token,newAdmin)` |
| **FE-13** | **State attestation** — produce the end-state diff against a declared expectation | **off-chain Work**: `script/08_verify_state.sh` + `state-mate` over `config/state-mate/wsteth.yaml` | a deploy record exists | a pass/fail diff (the `E-STATE-01` carrier) | `just verify-state` |

> **`FE-13` is a crossing, not an on-chain element (`CC-A6F-5`).** Its bearer is a dated `U.Work`
> occurrence enacted by a system bearing `TransformerRole` (`A.15.1`), not a contract. It is listed
> because `RB-11` is a real required effect of the delivered system, but it belongs to a
> `WorkMethodStructure`, and a green run is a *method-level* check — the Work is the dated broadcast
> with its receipts (`README.md` §6). Do not read this row as an on-chain guarantee.

### 2.2 Behaviour borne by the CCIP transport

Listed because `RB-01`/`RB-02`/`RB-05` cannot complete without them, and their bearer is **not ours**
(`A.1.1`: state the crossing rather than dropping it).

| ID | Required behaviour | Bearer | Status of the allocation |
|---|---|---|---|
| **FE-04** | **Message origination** — turn an admitted send into a cross-chain commitment | CCIP OnRamp (`forwardFromRouter` → `CCIPMessageSent`) | allocated; Chainlink-operated |
| **FE-06** | **Receive-side admission** — enforce the declared verifier quorum, then hand off to the pool | CCIP OffRamp `execute` → `pool.releaseOrMint` (whose own guards then run: RMN, `_onlyOffRamp`, source-pool check, inbound bucket, `postflightCheck`) | **split**. The pool-borne half is allocated and holds on any ramp version. The **quorum half is allocated only on lanes with an OffRamp 2.0** — see [§7](#7-required-behaviour-with-no-current-bearer--the-gaps) |
| **FE-14** | **Attestation** — produce the verifier reports the quorum consumes | the network's independent verifiers | allocated externally. In the validation harness this was modelled by `MockCCV ×2`, an `A.7` artifact substitution — the persisted `DummyMessageIdVerifier` + `VersionedVerifierResolver` are the *configuration and proof-check locus*, not the attesting operators |

> **Where `FE-05` and `FE-06` part company — the single most consequential seam in this system.**
> Our hooks **declare** the required verifier set (`getRequiredCCVs`, a `view`); the OffRamp **reads and
> enforces** it. Neither hook checks the quorum. `preflightCheck` (outbound) checks global pause, the
> lane's outbound pause, the (immutably disabled) allowlist and the (unset) policy engine;
> `postflightCheck` (inbound) checks global pause, the lane's inbound pause and the policy engine —
> **and nothing else**: there is no allowlist call on the inbound side
> (`AdvancedPoolHooks.sol:117-134`). So `RB-05` is a required
> effect whose declaring bearer is ours and whose enforcing bearer is Chainlink's. If nothing reads the
> declaration, the requirement simply is not borne — which is exactly the 1.5-lane situation.

### 2.3 Bearers outside the boundary

These bear no `RB-*` of ours, but they can *withhold* one. Their authority is catalogued in
`PERMISSIONS.md` §2.2.2; here only their functional effect matters.

- **CCIP Router owner** — selects which ramp addresses satisfy `FE-01`/`FE-06`'s caller checks.
- **RMN curse authority** — a curse makes both `lockOrBurn` and `releaseOrMint` revert: `RB-01` and
  `RB-02` stop being deliverable, in both directions, and we cannot lift it.
- **OP `L2CrossDomainMessenger` + sequencer** — the transport `FE-09` runs on; its liveness is a
  precondition for `RB-09` on the L2 side.

---

## 3. Functional dependencies

Read as "cannot deliver without", not as call order. The call order is the flow view
(`ARCHITECTURE.md` §5.1) and is deliberately not restated (`C.30.TFS-REL`: a flow structure is not the
functional structure).

```
RB-01 / RB-02  ──requires──▶  FE-01 ─▶ FE-02│FE-03 ─▶ FE-04 ─▶ FE-06 ─▶ FE-07│FE-08
                                 │                                  ▲
RB-05          ──requires──▶  FE-05 (declare) ───────────────────────┘ (enforce)  ✗ unborne on 1.5 lanes
RB-06          ──requires──▶  FE-01 (outbound bucket) + FE-06 (inbound bucket)
RB-03 / RB-04  ──requires──▶  FE-02 + FE-07 bound to one box per lane            [L-SILO-01]
RB-07 / RB-08  ──requires──▶  FE-10 ──depends on──▶ FE-11 (role gating)
RB-09          ──requires──▶  FE-09 ──depends on──▶ the OP transport (external)
RB-10          ──requires──▶  FE-11
RB-11          ──requires──▶  FE-13 (off-chain Work — A.15 crossing)
```

Two dependencies worth naming because they are asymmetric:

- **`FE-10` halt is one transaction; `FE-10` resume on L2 is a full L1→L2 round trip.** Halting is
  borne by a multisig; resuming is borne by `FE-09`. A lane can therefore be stopped far faster than it
  can be restarted, and the restart path inherits every dependency of `RB-09`.
- **`FE-11` is the sole route to every owner-gated lever.** `L1-POM` / `L2-POM` has no autonomous behaviour; the pool,
  hooks, lockbox, CCV stack and TAR entry are reachable only through it.

---

## 4. Required effect vs actual transformation — the `A.3.4` line

`CC-A6F-4A`. Everything in [§1](#1-required-effects--what-the-system-is-for) and
[§2](#2-functional-elements--behaviour-allocated-to-a-bearer) is **claim content**. A `U.Transformation`
exists only where `A.3.4` independently recovers the changed referent, the boundary, the boundary
conditions, actual before/during/after facts, and a continuity basis. A functional-element row, a
diagram arrow, a passing selector name, and a matching label supply none of that.

**Worked case — the round trip.** `RB-03` (conservation) is a requirement. The actual transformation it
concerns is recovered as:

| `A.3.4` element | Value |
|---|---|
| changed referent | the lane's `ERC20LockBox` principal and the L2 wstETH total supply |
| extent / boundary | one lane, one round trip, on the named fork at a named block |
| boundary conditions | the deployed rate limits, the ramp versions actually resolved from the Router, `!RMN.isCursed` |
| actual before / during / after | measured box balance and L2 supply before the send, the emitted `CCIPMessageSent`, the deltas after the receive leg |
| continuity basis | the same box address and the same token proxy across the interval |
| grounding Work | `RealLaneBridge.test_roundtrip_conserves_lockbox_principal` — a genuine `ccipSend` on the real lane plus a documented prank stand-in for the receive leg |

**And the countercase, stated so it cannot be read the other way.** `RB-05` has *no* corresponding
actual transformation on a 1.5-only lane. `getCCVConfig` returning the configured set is an observed
*configuration* fact, not an enforcement occurrence. The only place the quorum has actually gated a
transfer is `RealCcvLane.test_ccv_quorum_1of2_does_not_mint_on_real_offramp`, against a real OffRamp
2.0 on the `sepolia ↔ mantle_sepolia` lane. Elsewhere, `RB-05` is requirement-only — the stop condition,
not a weaker version of the same claim.

---

## 5. Functional ports are not module interfaces

`CC-A6F-9`. Both use `U.Signature` discipline; they answer different questions.

| | **Functional port** (`A.6.0`) | **Module interface** (`A.6.M`) |
|---|---|---|
| governs | which states, flows and conditions a behaviour accepts and produces | substitution, compatibility, boundary and change policy |
| here | `lockOrBurn` / `releaseOrMint` as the value-path in/out slots; `preflightCheck` / `postflightCheck` as the policy slots; `queue` / `execute` as the governance-command slots | `TokenPool is IPoolV1V2` |

That second cell is the whole 1.5-versus-2.0 story, and it is only sayable because the two are kept
apart: **the module-interface claim holds while a functional allocation does not.** A live 1.5 OnRamp
can drive our 2.0 pool — substitution compatibility obtains via `IPoolV1V2`, so every pool-borne
behaviour (`FE-01`, `FE-02`, `FE-06`'s pool half, `FE-07`, `FE-08`) runs unchanged. What does not
follow is that `FE-06`'s quorum half is borne: a 1.5 OffRamp has no notion of CCVs and never reads
`FE-05`'s declaration. **A satisfied interface is not a delivered behaviour** — naming a module never
allocates a function (`A.6.F` anti-pattern *module allocation shortcut*).

---

## 6. Functionality is not a quality claim

`CC-A6F-8`. "Secure", "safe" and "robust" do not appear as properties of this system in this document,
and "functionality" is not used to smuggle them in. The `A-*` items are **admissibility gates** — yes/no
on one transfer — not scalars, and they are not to be aggregated into a score (`A.19`/`G.5`; the same
guard as `ARCHITECTURE.md` §5.3).

Likewise **capability stays separate from behaviour** (`CC-A6F-4`, `A.2.2`). `FE-10` allocates the halt
behaviour to `L1-POM` / `L2-POM` and the grant to the emergency multisig (`PERMISSIONS.md` `D-ACT-04`). Whether that
multisig *can actually halt in time* — signers reachable, quorum assemblable, monitoring in place, gas
available — is a `U.Capability` claim about the holder, and **nothing in this repository establishes
it.** A role grant is not an ability; a passing test is not an operational readiness claim.

---

## 7. Required behaviour with no current bearer — the gaps

`C.30.ASV` requires that an unallocated required behaviour be recorded as a gap rather than dressed as
a filled functional element.

| Gap      | Required effect                          | Why unborne                                                                                                                                       | Consequence to state, not to soften                                                                                                                                                                   |
| -------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **G-01** | `RB-05` (verifier quorum)                | on 1.5-only lanes no OffRamp 2.0 exists to read `FE-05`'s declaration                                                                             | `A-CCV-01` is relaxed to optional there. Gating only on lanes whose active OnRamp *and* registered OffRamp are 2.0 — set `CCV_LANE_REQUIRED=1` so a regression fails loudly instead of self-skipping  |
| **G-02** | `RB-08` (resume) on L2                   | resume is admin-only and the L2 admin is reachable only through `FE-09`                                                                           | halt is a single multisig transaction; resume is a full DAO L1→L2 round trip. The asymmetry is by design, but its latency is unbudgeted here                                                          |
| **G-04** | `FE-14` (attestation)                    | the persisted CCV stack is inert on the 1.5 transport; the real attesting operators are external and were modelled by `MockCCV ×2`                | the deployed verifier/resolver bear configuration and proof-checking, not attestation. Do not read their presence as a live second verifier                                                           |

**Closed gap G-03.** Current upstream `PoolOperationManager` is UUPS-upgradeable, with
`_authorizeUpgrade` restricted to `DEFAULT_ADMIN_ROLE`. Agent / OpExec can repair the operations
gate in place; selector `0x4f1ef286` is Blocked from the proposal route. `RealPomUpgrade` rehearses
the upgrade and verifies preservation of configured state on both forks.

**Closed gap G-05.** Claim A now pins role cardinalities (including empty `EXECUTOR_ROLE` and
`RESUME_ROLE`) and both POM ↔ pool ↔ hooks bindings. Principal pairwise-distinctness remains a
separate record-level gap (`L-SEP-01`), not a contract-call gap.

---

## 8. FPF cross-reference

| Concern | Governing pattern | Where |
|---|---|---|
| Function-like wording assigned to an exact object; no `U.Function` minted | **`A.6.F`** (RPR-FUNCTION) | this document, §0 and throughout |
| This as a selected functional-structure view of the architecture | **`C.30.ASV`** (`FunctionalStructureView`), under **`C.30`** | §0 |
| Required effect kept apart from actual change | **`A.3.4`** via `CC-A6F-4A` | §4 |
| Flow organisation related to, not identified with, functional structure | **`C.30.TFS-REL`** | §3 (flow view stays in `ARCHITECTURE.md` §5.1) |
| Off-chain bearers as Work, not as contracts | **`A.15`** / **`A.15.1`** / **`A.7`** | `FE-13`, §2.1 |
| Ports vs module interfaces | **`A.6.0`** / **`A.6.M`** | §5 |
| Capability kept apart from grant and from behaviour | **`A.2.2`** / **`A.2.8.PER`** | §6, and `PERMISSIONS.md` §2.2 |
| Gates are admissibility, not quality scalars | **`C.25`** / **`C.16.Q`** / **`A.19`** / **`G.5`** | §6 |
| What is actually evidenced | **`B.3`** (Claim A / Claim B) | `README.md` §3–§5 |

The deployed contracts are the holon; this document only describes a selected structure over them
(`CC-C30-2/3`). Addresses live in `state/*.json` and `config/chains/*.json`, not here.

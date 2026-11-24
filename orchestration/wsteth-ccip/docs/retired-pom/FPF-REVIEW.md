# FPF claim review — the root documentation set

> **This is a dated review, not a current-state document — read it as evidence of what was found on
> 2026-08-18, and do not update its findings.** Two of its dispositions have since changed:
>
> - **R-11** (`0xad0f7c64` — the 14-day override bound to a selector matching no function) is
>   **closed**. It was recorded here as *"deliberately not done — upstream defect"*. The repair did
>   not need an upstream fix: `DEFAULT_CONFIG` is already `vm.envOr` in the vendored scripts, so
>   `config/default_config.json` (ours) is injected instead, binding the recomputed `0xddadfa8e` and
>   adding `setPool` and the CCV `setDynamicConfig` overload. `PARAMETERS.md` §0.2.
> - **R-06** (`L-SEP-01` has no carrier) is **half-closed**. The property now *obtains* — deployer,
>   Emergency Multisig and Chainlink MCMS are distinct addresses — but the pairwise-distinctness
>   assertion this review asked for still does not exist, so Claim A still could not detect a
>   regression. `PERMISSIONS.md` §2.2.4.
> - **G-03 / P-POM-09 / L-NEG-08** are **superseded** by the 2026-09-04 upstream revision:
>   `PoolOperationManager` now implements UUPS with `DEFAULT_ADMIN_ROLE` authorization. Current
>   deployment and evidence are documented in `PARAMETERS.md` `P-POM-09` and `RealPomUpgrade`;
>   the original review text below remains unchanged as a dated finding.
>
> Three findings this review did not raise have since been added: `GUARDIAN_ROLE` confined to `veto`
> (`patches/ccip/0002`), the step 08 §4b capability probe, and Dual Governance's committees sitting on
> publicly-known anvil keys (`plan-v3-dg-committees.md`).

A review of the **claims** carried by the seven markdown documents in the repository root, conducted
against the First Principles Framework patterns those documents themselves cite, and against the
repository the claims are about.

Reviewed: [`README.md`](../README.md) · [`ARCHITECTURE.md`](./ARCHITECTURE.md) ·
[`FUNCTION.md`](./FUNCTION.md) · [`PERMISSIONS.md`](./PERMISSIONS.md) ·
[`PARAMETERS.md`](./PARAMETERS.md) · [`LIVE_DEPLOY_CONCERNS.md`](./LIVE_DEPLOY_CONCERNS.md) ·
[`draft-manual-test-plan.md`](./draft-manual-test-plan.md).

Review date: **2026-08-18**. Repository state: branch `main`, one commit (`eb834c3`), with
`ARCHITECTURE.md`, `PERMISSIONS.md`, `README.md`, `config/README.md`, `config/chains/*.json`
modified in the working tree and `FUNCTION.md` untracked.

---

## 0. What this document is

Per **`C.30`** this is a **description episteme about other description epistemes** — a review
record. It is deliberately *not* any of the following:

- **not a new authority.** Every finding names the pattern that already governs the claim and the
  document that already owns it. The review mints no new claim kinds and no new IDs for the system
  itself; `R-nn` identifies a *finding*, not a system claim.
- **not an assurance verdict** (`CC-C30-9`). It does not raise or lower Claim A or Claim B. Where a
  finding says an assurance claim exceeds its evidence, the repair is stated as a scope narrowing or
  an evidence addition, never as a score.
- **not a code audit.** Contract behaviour was read only where a document asserted something about
  it. Nothing here is a security finding about the contracts.

| Field | Value |
|---|---|
| `admissibleUse` | decide which sentences in the root docs can be relied on as written; find the one place each contested claim should live; drive a documentation repair pass |
| `nonAdmissibleUse` | as evidence about the deployed system; as a substitute for `just verify-state` / `just test-scenarios`; as a re-statement of Claim A or Claim B |
| method | (1) enumerate load-bearing claims per document; (2) check each against the repository (config, contracts, tests, deploy records); (3) check each against the FPF pattern it cites; (4) check the doc set against itself |
| what was **not** done | **no `just verify-state` run and no `forge test` run** — both need RPC endpoints not available here. Every quantitative statement below is derived from committed files and the tools' own source, and says so. This is the same `A.10` discipline the findings demand. |

### 0.1 How findings are grouped

Grouped by **what has to happen to close the finding**, not ranked (`G.5`) — the same convention
`PARAMETERS.md` §8 uses for its open set. No ordering between groups is implied and none should be
read into the sequence.

| Group | What closes it |
|---|---|
| **A** — one claim, two answers | pick the canonical location, restate once, cite by ID everywhere else |
| **B** — claim not carried by its evidence | narrow the claim, or add the carrier |
| **C** — refuted by the repository | correct the sentence |
| **D** — framework conformance | apply the pattern the document already cites |
| **E** — ungoverned claim surface | bring the document inside the framework the rest of the set uses |

### 0.2 Finding index

Validated against the repository on **2026-08-18** and repaired; per-finding verdicts and the exact
edits are in [§J](#j-validation-and-disposition-2026-08-18).

| ID | Finding | Primary site | Verdict | Disposition |
|---|---|---|---|---|
| **R-01** | "nothing deployed to live" vs. a committed live deployment record | `README.md:8` · `LIVE_DEPLOY_CONCERNS.md:3` | CONFIRMED | fixed — `README.md` §1.1 is now the canonical status claim |
| **R-02** | the described holon does not exist in the declared bounded context | `ARCHITECTURE.md:26-27` · `FUNCTION.md` §0 · `PERMISSIONS.md:9` | CONFIRMED | fixed — subject/target split in `ARCHITECTURE.md` §0, `FUNCTION.md` §0, `PERMISSIONS.md` scope |
| **R-03** | Claim A's check count: **43** in three documents, **73** in a fourth | `README.md:98` | CONFIRMED | fixed — 73 everywhere; "per-pair" gloss deleted |
| **R-04** | `A-CCV-01`'s quorum membership has four incompatible descriptions | `PERMISSIONS.md:316` · `PARAMETERS.md` §2 | CONFIRMED, sharpened | fixed — one statement in `README.md` §5; the mechanism is `laneMandatedCCVs`, not `defaultCCVs` |
| **R-05** | the deployed verifier set is **one** CCV; "2-of-2" is a test-time configuration | `README.md` §2/§5 · `ARCHITECTURE.md` §1/§5.3 | CONFIRMED | fixed — gate stated conditional on the declared set; deployed coordinate = 1 |
| **R-06** | separation of duties is asserted, never instantiated, and Claim A cannot detect its absence | `PERMISSIONS.md:443` §2.2.4 | CONFIRMED | fixed (docs) — `L-SEP-01` added; carrier **not** added |
| **R-07** | `D-ACT-07` "Deployer EOA — no POM role" is false on every record in the repo | `PERMISSIONS.md:183` | CONFIRMED | fixed — `D-ACT-07` is now record-derived |
| **R-08** | neither `B.3` claim has a dated, recoverable run carrier | `README.md` §3 | CONFIRMED | fixed — run logs archived by step 08 / `just test-scenarios` |
| **R-09** | the `B.3` tuples are incomplete: no `R`, no `G` for Claim A, no decay condition | `README.md` §3 | CONFIRMED; 2 citations wrong | fixed — §3 rebuilt on `CC-B3.6`/`CC-B3.11`; `B.3:20`/`B.3:22` do not exist |
| **R-10** | "15 tests" is not the count that runs on the substrate the status line names | `README.md:10,99` | CONFIRMED | fixed — count published per `K` (12 / 15) |
| **R-11** | the 14-day delay on `transferAdminRole` is asserted in two documents and refuted in a third | `PERMISSIONS.md:300` · `ARCHITECTURE.md:246` | CONFIRMED | fixed — removed from both 14-day lists; `configureLockBoxes` added |
| **R-12** | `LIVE_DEPLOY_CONCERNS` §1 is refuted by §5.3 of the same file | `LIVE_DEPLOY_CONCERNS.md:47` | CONFIRMED | fixed — §1 dated and marked superseded; §7 row corrected |
| **R-13** | `LIVE_DEPLOY_CONCERNS` §6/§7 are stale on 2.0 availability and feasibility | `LIVE_DEPLOY_CONCERNS.md:289,354` | CONFIRMED | fixed — §6 scoped + dated; §7 verdict made per-lane |
| **R-14** | `postflightCheck` does not check the allowlist | `LIVE_DEPLOY_CONCERNS.md:108` · `FUNCTION.md` §2.2 | CONFIRMED | fixed — allowlist attributed to `preflightCheck` only |
| **R-15** | `PARAMETERS` §9 pin-coverage table overstates two rows | `PARAMETERS.md:359` | CONFIRMED | fixed — `P-TOK-01` moved; `P-TOP-04` split |
| **R-16** | the Claim Register's dependency direction is inverted | `README.md` §5 | CONFIRMED | fixed — adjudication moved onto the `E-*` rows |
| **R-17** | the Claim Register omits `A.6.B:7`'s **Canonical location** column | `README.md` §5 | CONFIRMED | fixed — **Statement** + **Canonical location** columns added |
| **R-18** | `E.11` is cited for a rule it does not carry | `PARAMETERS.md:369` | CONFIRMED | fixed — re-cited as `A.6.B:6.1` / `CC-A.6.B.4` |
| **R-19** | the "capability" repair `FUNCTION.md` announces was never propagated | `README.md:108` · `ARCHITECTURE.md:271` | CONFIRMED | fixed — split applied at all three sites |
| **R-20** | two documents carry the most decision-shaping claims and no classification at all | `LIVE_DEPLOY_CONCERNS.md` · `draft-manual-test-plan.md` | CONFIRMED | fixed — classification block added to both documents |

---

## A. One claim, two answers

### R-01 — "nothing deployed to live" vs. a committed live deployment record

**As written.** `README.md:8`: *"Not tied to any live Lido deployment; every run is throwaway."*
`LIVE_DEPLOY_CONCERNS.md:3`: *"Status: **analysis only, nothing deployed to live.**"*
`draft-manual-test-plan.md:10`: *"**Live deploy #2** placed the wstETH 2.0 bridge on **Sepolia** (L1
…) ↔ **Mantle Sepolia** … Record: `config/chains.live-mantle/`."*

**Finding.** The third statement is the true one. The repository contains, tracked in git:

```
config/chains.live-mantle/{sepolia,mantle_sepolia}.json
deployments/chains.live-mantle/sepolia-mantle_sepolia/2026-06-12_22-49/
    parameters.env · state/{l1,l2,l1.deployed}.json · chains/*.json · state-mate/{wsteth,wsteth.deployed,wsteth.inputs.<l2>}.yaml
```

`.gitignore` excludes `/deployments/forks` but **not** `deployments/chains.live-mantle`, so the live
archive is a deliberate, committed artefact. A live deployment exists as a record; the two governed
documents deny it.

**Governing.** `A.6.B` — this is an **`E-*` claim** (a claim about what actual work produced what
carriers) and it must be settled by the carrier, not by an authoring assumption; `B.3` `CC-B3.1` —
`K` is load-bearing and currently wrong in two documents.

**Repair.** One status claim, one canonical location. Suggest `README.md` §1 carries it (it already
owns "what this is and is not"), enumerating the substrates that exist — persistent anvil
forks and `config/chains.live-mantle` (Sepolia ↔ Mantle Sepolia, 2026-06-12) — and every other
document referring to it rather than restating.
`LIVE_DEPLOY_CONCERNS.md`'s status line becomes *"analysis written before the deploy; superseded by …"*.

---

### R-02 — the described holon does not exist in the declared bounded context

**As written.** `ARCHITECTURE.md:26-27` — `describedHolonRef` = *"the deployed `wsteth-2.0`
system"*, `boundedContextRef` = *"the **live-network target**: Ethereum mainnet (L1, chainid 1) +
an OP-stack L2"*. `FUNCTION.md` §0 repeats both fields verbatim.
`PERMISSIONS.md:9` — *"This matrix and every diagram below depict the **production setup** — Lido DAO
governance on **Ethereum mainnet (L1)** reaching an **OP-stack L2**"*.

**Finding.** Nothing is deployed on mainnet. The three documents therefore name, as their exact
subject, a holon that does not exist, while their evidence (Claim A, Claim B), their addresses
(`state/*.json`, `config/chains*/`), their parameters (testnet placeholders, `PARAMETERS.md` §2) and
now an actual live deployment all belong to different contexts. `describedHolonRef` says *"the
deployed system"*; the deployed systems are the forks and the Sepolia ↔ Mantle Sepolia lane.

This is not pedantry: it is what makes R-05 (a 1-of-1 verifier set described as 2-of-2) and R-06
(four principals that are one key) readable as "true of the target" rather than "false of the thing
that exists".

**Governing.** `C.30` `CC-C30-4` — *"Every architecture description has **one exact** C.2.1
EntityOfConcern … and effective `U.ReferenceScheme`"*; repair clause: *"Recover the exact subject and
scheme, or split the description from the bounded architecture claim."* Also `CC-C30-1`, which
requires distinguishing **actual** subject relations from **candidate/expected** content.

**Repair.** Split the two. `describedHolonRef` = the deployed system(s) that exist, with the
mainnet topology retained as *expected content* of an architecture **claim** — which is what it
actually is — rather than as the description's subject. `PERMISSIONS.md`'s scope note takes the same
split; it already has the vocabulary ("as-tested substrate").

---

### R-03 — Claim A's check count: 43 in three documents, 73 in a fourth

**As written.** `README.md:98`: *"a full ownership/role-matrix schema diff (**43/43** on the default
pair; the count is per-pair — `just verify-state` prints the live total)"*.
`ARCHITECTURE.md:157` and `PERMISSIONS.md:19`: *"`config/state-mate/wsteth.yaml`, **43 checks**"*.
`draft-manual-test-plan.md:40`: *"`just verify-state` # state-mate — expect **73/73**"*.

**Finding.** The configuration yields **73**, and the "per-pair" reconciliation cannot be right.

- Counting assertions in the committed `config/state-mate/wsteth.yaml` gives 73 (L1 34 + L2 39:
  `l1TokenPool` 7, `l1AdvancedPoolHooks` 3, `l1PoolOperationManager` 17, `l1LockBox` 2,
  `l1TokenAdminRegistry` 1, `l1MessageIdVerifier` 2, `l1VerifierResolver` 2; `l2TokenPool` 7,
  `l2AdvancedPoolHooks` 3, `l2PoolOperationManager` 17, `l2TokenAdminRegistry` 1, `l2WstETH` 5,
  `l2MessageIdVerifier` 2, `l2VerifierResolver` 2, `l2OptimismBridgeExecutor` 2).
- That is the unit state-mate counts: `incChecks()` is called once per `_checkViewFunction`, i.e.
  once per `(method, args-entry)` pair — `lib/state-mate/src/section-validators/base.ts:73,104` and
  `checks.ts:68-77`.
- The count **cannot** be per-pair: `config/state-mate/wsteth.yaml` is byte-identical to the copy
  archived with the `mantle_sepolia` fork run (`deployments/forks/sepolia-mantle_sepolia/
  2026-06-12_17-22/state-mate/wsteth.yaml`, modulo the `rpcUrl` line) and byte-identical to the copy
  archived with the live Mantle run. It is unchanged in git since `eb834c3`. Same file, same
  contract list, same assertion count on every pair.
- `script/08_verify_state.sh:152` invokes state-mate with no `--checkOnly` filter, so nothing is
  skipped for some pairs and not others.

**Governing.** `A.10:6` items 1/3/4 — a number quoted from a run is a claim about a dated `U.Work`
whose carrier must be recoverable; `B.3` `CC-B3.11` — a figure with no recoverable evidence path
does not raise assurance.

**Repair.** Correct to 73 (or, better, stop hard-coding a run result in prose: cite the archived
run log per R-08). Delete the "the count is per-pair" gloss — it is a false explanation of a real
discrepancy.

---

### R-04 — `A-CCV-01`'s quorum membership has four incompatible descriptions

**As written.**

| Where | What the second quorum member is said to be |
|---|---|
| `README.md` §4, `ARCHITECTURE.md` §6 | *"a second CCV"* — a `MockCCV` deployed by the test, standing in for a second verifier operator |
| `PARAMETERS.md` §2, note under `P-CCV-01` | *"the second quorum member is **the lane's own default CCV**"* |
| `PERMISSIONS.md:316` | *"the runtime 2-of-2 quorum is **the resolver fanning out to two CCVs**"* |
| `PERMISSIONS.md:407` | *"the network's two independent verifiers (a Chainlink + a second attester) … modelled by **`MockCCV ×2`**"* |

**Finding.** The code says the first. `test/scenario/RealCcvLane.t.sol:110-115` deploys **one**
`MockCCV` per chain as CCV-B and calls `_govEnable2of2`, which issues
`L1-POM.directCall → hooks.applyCCVConfigUpdates` with `[ccvA, ccvB]` in both directions
(`:150-161`). CCV-A is the deployed `VersionedVerifierResolver` read from the record (`:104-106`).
Nothing resolves to "the lane's default CCV", and `VersionedVerifierResolver` routes a version tag to
one verifier — it does not fan out to two.

Four documents, four mechanisms, for the single most load-bearing gate in the repository.

**Governing.** `A.6.B` `CC-A.6.B.4` (dependency by explicit ID reference, never by restating in new
words) and `A.6.B:6.1` (*"reuse by reference, not by copy"*). The structural cause is R-17.

**Repair.** One canonical statement of `A-CCV-01`'s membership — `README.md` §5 is the natural home
since it owns the Claim Register — and `PARAMETERS.md` / `PERMISSIONS.md` cite `A-CCV-01` instead of
re-describing it. `PARAMETERS.md`'s `P-CCV-01` keeps what is genuinely its own: the deployed
coordinate (one entry) and its disposition.

---

### R-05 — the deployed verifier set is one CCV; "2-of-2" is a test-time configuration

**As written.** `README.md` §2 diagram: *"CCIP 2.0 bridge (our own OnRamp/OffRamp + 2-of-2 mock
CCV)"*, *"Every transfer requires **both** mock CCVs to attest before `releaseOrMint`"*.
`ARCHITECTURE.md` §1/§2: *"CCIP 2.0 bridge · 2-of-2 CCV"*, *"**CCV** (×2, independent verifiers)"*.
`ARCHITECTURE.md:244` (`A-CCV-01`): *"`execute` admits a transfer **iff** the 2-of-2 required CCVs
reported"*.

**Finding.** The **deployed** end state declares a single verifier. `config/state-mate/wsteth.yaml:
91-97` and `:230-236` pin `getCCVConfig` as `[[resolver], [], [resolver], []]` — one outbound CCV,
one inbound CCV, empty threshold sets, on both chains. The 2-of-2 exists only *inside*
`RealCcvLane`, after the test performs a governance reconfiguration
(`RealCcvLane.t.sol:111-115,150-161`). `PARAMETERS.md`'s `P-CCV-01` says this correctly — *"our
hooks name a single resolver"* — and is the only place in the set that does.

So `A-CCV-01` as a property of the deployed system is currently: *inbound value is admitted when the
one declared verifier reports*. The 2-of-2 story is a rehearsal of an enablement that has not been
performed on any deployment.

**Governing.** `A.6.B` §5.2 — an `A-*` claim states the admissibility predicate the mechanism
**actually** evaluates; `B.3` `CC-B3.1` — `K` (the configuration under which the quorum was
exercised) is load-bearing and is currently absent from the gate statement.

**Repair.** State `A-CCV-01` as conditional on the deployed CCV set, and record the deployed set
(one entry) at the gate, not only in `PARAMETERS.md`. `RealCcvLane`'s governance step is then read
as what it is: evidence that the *enablement path* works, which is a genuinely valuable and
separate claim.

---

## B. Claim not carried by its evidence

### R-06 — separation of duties is asserted, never instantiated, and Claim A cannot detect its absence

**As written.** `PERMISSIONS.md` §1 lists **Emergency Multisig**, **Chainlink MCMS**, **Guardian**
and **Deployer EOA** as four principals. §2.2.1 gives them disjoint grants (`D-ACT-03`, `D-ACT-04`,
`D-ACT-05`, `D-ACT-07`). §4.3 (`:443`): *"The earlier deploy assigned the guardian slot to
`emergency_brakes` (which was also a pauser), conflating the two; **that overlap has been
removed**"*. §5 end-state matrix: *"`GUARDIAN_ROLE` = **Guardian** (not emergency_brakes)"*,
*"`HALT_ROLE` = **Emergency Multisig + Chainlink MCMS**"*.

**Finding.** In **every** record in the repository the four are one address:

```
config/chains/{sepolia,mantle_sepolia}.json
config/chains.live-mantle/{sepolia,mantle_sepolia}.json
  → chainlink_mcms = emergency_brakes = guardian = deployer = 0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597
```

And Claim A **structurally cannot** flag it. `config/state-mate/wsteth.yaml` asserts
`hasRole(ROLE, *alias)` per alias; when the aliases resolve to the same address, one key satisfies
every row and the run is green. The `guardianBrakesCollapsed` input (`:107-114`) covers exactly one
of the six collapses (guardian ↔ brakes) and is designed to expire; the other five —
guardian ↔ deployer, brakes ↔ deployer, mcms ↔ deployer, mcms ↔ guardian, mcms ↔ brakes — are
invisible.

`PERMISSIONS.md` §2.2.4 is the section that exists to state what Claim A does not pin. It lists
cardinality, `EXECUTOR_ROLE` and the `L1-POM` / `L2-POM` ↔ pool ↔ hooks binding. It does not list **principal
distinctness**, which is the gap that is actually live.

**Governing.** `A.6.B` `CC-A.6.B.3` — a grant `D-*` names its beneficiary, *and writing the claim
does not make it obtain*; `B.3` congruence — the assurance claimed must not exceed the evidence.
The separation-of-duties property is not any single `D-*` row: it is a claim about the *distinctness
of the beneficiaries*, and it is nowhere written down.

**Repair.** Two lines of work.

1. Add the missing atomic claim — an `L-*` well-formedness claim, e.g.
   `L-SEP-01`: *the four governance principals are pairwise distinct addresses, and none equals the
   deployer* — and cite it from `D-ACT-03/04/05/07`.
2. Give it a carrier. `script/08_verify_state.sh` already derives inputs from the record and fails
   on drift; a distinctness assertion over `governance_addresses` costs a few lines and turns
   §4.3's *"that overlap has been removed"* from an intention into an `E-*` result. Until then,
   §4.3 should read *"the record carries a dedicated `guardian` field; its value is not yet
   distinct on any deployment"*, and §2.2.4 should carry the gap.

---

### R-07 — `D-ACT-07` "Deployer EOA — no POM role" is false on every record

**As written.** `PERMISSIONS.md:183` — *"**Deployer EOA** | **no POM role, no owner, no token
admin** | two pinned live-testnet-interim residuals … | everything else — every admin/owner check
asserts `false`"*.

**Finding.** With `chainlink_mcms`, `emergency_brakes` and `guardian` all set to the deployer
address (R-06), the deployer holds `PROPOSER_ROLE`, `HALT_ROLE` and `GUARDIAN_ROLE` on both POMs —
i.e. propose, cancel any queued proposal, all three pause surfaces, veto/approve, and all five
timelock setters (`PoolOperationManager.sol:412,468,646-715`) — in addition to the two documented
residuals. The residual set is five roles, not two.

`draft-manual-test-plan.md:133` states this correctly and is the only place in the set that does:
*"Deployer (all gov roles, interim)"*.

**Governing.** `A.6.B` `CC-A.6.B.3`/`CC-A.6.B.4`.

**Repair.** Make the residual set record-derived rather than fixed prose: `D-ACT-07` states the
rule (*"the deployer holds whatever role its address occupies in `governance_addresses`, plus the
OpExec cancel guardian and the CCV `allowlistAdmin`"*) and points at `L-SEP-01` for the condition
under which that reduces to the intended two.

---

### R-08 — neither `B.3` claim has a dated, recoverable run carrier

**As written.** `README.md` §3 adjudicates Claim A by *"`state-mate` (`just verify-state`) — …
**43/43**"* and Claim B by *"`forge` (`just test-scenarios`) — **15 tests**"*.

**Finding.** No run output exists anywhere in the repository. The deployment archives
(`deployments/<record>/<l1>-<l2>/<timestamp>/`) retain the state-mate **config trio**, the deploy records and `state/*.json`,
but no state-mate stdout and no `forge test` summary. So both figures are asserted rather than
referred, are undated, and are not bound to a commit or a block. R-03 is the direct consequence: a
number drifted and nothing could contradict it.

**Governing.** `A.10:6` items 1 (the claim), 3 (carrier/source recoverable) and 4 (each producing
occurrence is a dated `U.Work`); `B.3` `CC-B3.6` (source-currentness record listing node/edge values
and Evidence Graph Ref) and `CC-B3.11` (a display does not raise assurance without a recoverable
evidence-provenance path).

**Repair.** `script/08_verify_state.sh` already builds an archive directory; tee state-mate's stdout
and the `forge test` summary into it, and have `README.md` §3 cite that path instead of quoting a
constant. This is the cheapest finding in the report to close and it closes R-03 and R-10 with it.

---

### R-09 — the `B.3` tuples are incomplete

**As written.** `README.md` §3 states *"each claim is a typed tuple `Assurance(H, C | K, S)`"* and
*"`R_eff = max(0, min Rᵢ − Φ(CL_min))` (`CC-B3.3/B3.4`)"*, then publishes, per claim: the adjudicator,
`K`, `F`, `CL` and a "Licenses" cell.

**Finding.** Three components of the tuple the section invokes are missing.

- **No `R`.** Neither claim publishes an `R_i` or an `R_eff`. The formula is cited but never
  instantiated, so *"the lowest-confidence edge caps the claim"* is a statement about a quantity that
  does not exist here (`CC-B3.2`: `R` is ratio and uses `min` plus conservative operations).
- **No `G` for Claim A.** Claim B's `ClaimScope` is narrowed explicitly in §4 (a genuinely good
  piece of work). Claim A has no scope value at all — which matters, because R-06 shows exactly
  which slices it does *not* cover.
- **No decay or reopen condition** on either claim. Only `A-CCV-01` carries one (`README.md` §5,
  "Reopen/decay"). ~~`B.3:22`~~ **[corrected — see [J.2](#j2-corrections-to-the-review): the
  requirement is `CC-B3.11`, which names decay condition and reopen condition explicitly]**;
  `CC-B3.6` requires decay/valid-until indicators on empirical bindings.

**Governing.** `B.3` `CC-B3.1`, `CC-B3.2`, `CC-B3.6`.

**Repair.** Two honest options; the second is probably right for this repository.

1. Publish `R_i`, `CL`, `Φ` and `R_eff` per claim, plus `G` for Claim A and a reopen condition for
   both.
2. Drop the full-tuple framing. ~~`B.3:20`~~ **`B.3:4.2b`** ([J.2](#j2-corrections-to-the-review))
   licenses a lighter form — a *compact bounded assurance claim* naming act, context, window,
   calibration condition, stop condition, bounded evidence use, and unsupported attempted use — for
   local, non-release claims. That is what §3 actually is. Keep `F`, `K` and the `CC-B3.8` design/run
   split, add the reopen conditions, and stop quoting the `R_eff` formula that nothing computes.
   **↳ Taken. `README.md` §3 is now this form.**

`CC-B3.8` itself is used correctly: Claim A is state/design-grade and Claim B is run-grade, which is
exactly the separation that CC requires.

---

### R-10 — "15 tests" is not the count that runs on the substrate the status line names

**As written.** `README.md:10`: *"Status: **complete — steps 00–09 done and verified on both
forks**"*, naming a **1.5-only** pair. `README.md:99`: Claim B is adjudicated by
*"**15 tests** (RealLaneBridge 12 + RealCcvLane 3 …)"*.

**Finding.** The arithmetic is right — `RealLaneBridge.t.sol` has 12 `test_*` functions and
`RealCcvLane.t.sol` has 3 — but on the pair the status line named, the three CCV-lane tests
`vm.skip` (`RealCcvLane.t.sol:97-101`, and each test's `vm.skip(!laneIs20)`), because that lane was
1.5-only. Twelve run. The 15 figure belongs to the Sepolia ↔ Mantle Sepolia pair,
which the status line did not mention.

Both facts are stated elsewhere in §3/§4/§8; the defect is that the headline number and the headline
substrate are from different `K`.

**Governing.** `B.3` `CC-B3.1` (`K` is load-bearing) and `CC-B3.5` (`G` composes by intersection —
the union of two pairs' coverage is not the coverage of either).

**Repair.** Give the count per `K`: *"12 gating tests on 1.5-only pairs; 15 on real-2.0 pairs
(sepolia ↔ mantle_sepolia)"*.

---

## C. Refuted by the repository

### R-11 — the 14-day delay on `transferAdminRole`

**As written.** `PERMISSIONS.md:300`: *"per-selector delay … **14 days** (`1209600 s`) on
**`transferAdminRole`**, `setDynamicConfig`, `updateAdvancedPoolHooks`, `configureLockBoxes`"*, and
`D-ACT-03` (`:179`) relies on it. `ARCHITECTURE.md:246` (`A-POM-01`): *"**`transferAdminRole`**/
`setDynamicConfig`/`updateAdvancedPoolHooks` carry a 14-day delay"*.

**Finding.** Refuted, with proof, inside the same doc set. `PARAMETERS.md` §0.2 and `P-POM-05`
(`:193`) show that `default_config.json` binds the 14-day override to selector `0xad0f7c64`, which
matches no function on any `L1-POM` / `L2-POM` target, while the real selector is `0xddadfa8e`. Confirmed here:

```
$ cast sig 'transferAdminRole(address,address)'   →  0xddadfa8e
lib/ccip/chains/evm/contracts/lido-hvmv/config/default_config.json
    custom_delay_selectors[0] = { "function": "transferAdminRole(address,address)",
                                  "selector": "0xad0f7c64", "delay_seconds": 1209600 }
```

`config/state-mate/wsteth.yaml:145-152` pins **both** selectors precisely so the gap stays visible —
`0xad0f7c64 → 1209600`, `0xddadfa8e → 259200`. So the deployment is verified to *not* have the
protection that two documents assert it has.

**Governing.** `A.6.RSIR:4.2.1` — *"Neither the declaration nor representation syntax establishes
the binding"*, the exact rule `PARAMETERS.md` §0.2 invokes; `A.6.B` `CC-A.6.B.4` — the two asserting
documents should reference `P-POM-05` rather than restate the intended behaviour.

**Repair.** Remove `transferAdminRole` from both 14-day lists; both sites cite `P-POM-05`. Note
that `ARCHITECTURE.md:246` also omits `configureLockBoxes`, so it is neither the intended nor the
deployed list.

---

### R-12 — `LIVE_DEPLOY_CONCERNS` §1 is refuted by §5.3 of the same file

**As written.** `:47`: *"Impersonation appears in exactly one deploy step"*; §1 then explains that
the L2 token exposes neither `getCCIPAdmin()` nor `owner()`, so *"on the fork we bypass the module
and call `proposeAdministrator` directly … hence impersonating the module owner"*, and prescribes
*"Fix = add `getCCIPAdmin()`/`setCCIPAdmin()` to the token"*. `:354` (§7 bottom line) still records
*"Impersonation needed? **No (add token `getCCIPAdmin()`)**"* as pending work.

**Finding.** §5.3 of the same document already says *"✅ **DONE** … step 07 runs
**impersonation-free** on the fork (the `anvil_impersonateAccount` fallback is dead code, kept
guarded)"*, and the repository agrees:

- `script/07_set_pool_gov.sh:140` registers the L2 token via `registerAccessControlDefaultAdmin`;
  `:146` probes `getCCIPAdmin()` → `registerAdminViaGetCCIPAdmin` for L1.
- `lib/core/contracts/0.6.12/WstETH.sol:57` implements `getCCIPAdmin()`.
- The impersonation branch (`:155-171`) aborts with *"the registry module owner cannot be
  impersonated there"* on a live RPC.

`ARCHITECTURE.md` §6 states the corrected position. §1 and §7 were never updated.

**Governing.** `C.27` / `A.10:6` item 8 — edition, window and **supersession** are explicit when
they affect use.

**Repair.** Rewrite §1 as a dated, superseded note (it has archaeological value — it explains why
the fallback exists) and correct §7's first row to *"No — already impersonation-free"*.

---

### R-13 — `LIVE_DEPLOY_CONCERNS` §6/§7 are stale on 2.0 availability

**As written.** §6's topology diagram, both chain blocks (`:289`, `:309`): *"✗ OffRamp 2.0.0 / CCV
framework — **NOT deployed on live**"*, and the component table: *"OffRamp 2.0.0 + CCV framework |
✗ absent on live"*. §7 (`:354`): *"2.0 **CCV-gated** security model on real CCIP … Feasible now?
**No** (depends on Chainlink)"*.

**Finding.** Contradicted by the update embedded in §3 of the same file (2026-06-12) and by
`README.md` §4 / `ARCHITECTURE.md` §5.3: Sepolia carries an **active** `OnRamp 2.0.0` and a
**registered** `OffRamp 2.0.0` on the mantle_sepolia lane, and `RealCcvLane.t.sol:214-226` asserts
exactly that against the real deployments. The §6 diagram is a dated observation (read live
2026-06-09, as the section itself says) presented as a
present-tense fact about "live". §7's verdict is refuted by the gating test that now exists.

**Governing.** `C.27`; `A.10:6` item 8.

**Repair.** Scope §6 to the pair it describes and date it; add a mantle_sepolia block. Restate §7's
second row as *"Yes on lanes where Chainlink has shipped 2.0 (sepolia ↔ mantle_sepolia); no
elsewhere"*.

---

### R-14 — `postflightCheck` does not check the allowlist

**As written.** `LIVE_DEPLOY_CONCERNS.md:108`: *"`AdvancedPoolHooks.postflightCheck`
(`pools/AdvancedPoolHooks.sol:117`) runs only `_validateCaller()` + **allowlist** +
policy-engine"*. `FUNCTION.md` §2.2: *"`preflightCheck` / `postflightCheck` do *not* check the
quorum — they check pause, lane pause, the (immutably disabled) allowlist, and the (unset) policy
engine"*.

**Finding.** The body at `AdvancedPoolHooks.sol:117-134` runs `_validateCaller()` and, if a policy
engine is set, `policyEngine.run(...)`. There is no allowlist call; `checkAllowList` is on the
preflight side. The material claim both sentences are making — *no quorum check happens here* — is
correct and unaffected.

**Governing.** `A.10:6` item 6 (result boundary — say what the cited carrier actually contains).

**Repair.** Drop "allowlist" from both sentences, or attribute it to `preflightCheck` only.

---

### R-15 — `PARAMETERS` §9 pin-coverage table overstates two rows

**As written.** `:359` lists, in the *"Pinned ⇒ drift fails the run"* column, `P-TOK-01 (roles/proxy
admin)` and `P-TOP-02–04`.

**Finding.** Two rows do not hold.

- **`P-TOK-01`** is *L2 token metadata* — name, symbol, decimals. `config/state-mate/wsteth.yaml`
  asserts none of them; the `l2Token` block checks `proxy__getAdmin` and four `hasRole` entries
  only. The parenthetical "(roles/proxy admin)" quietly substitutes a different row's content.
- **`P-TOP-04`** covers `{router, rmn_proxy, token_admin_registry, registry_module_owner}`. Only
  `router` is asserted (via `getDynamicConfig`); the TAR is exercised implicitly as a contract
  address; **`rmn_proxy` and `registry_module_owner` are asserted nowhere**. `rmn_proxy` is
  load-bearing — it is the risk-network the pool consults on every transfer (`D-EXT-02`) and it is
  immutable in the pool, so a wrong one at deploy time is unrecoverable.

Every other row in the table checks out: the 20 getters listed in §9 all appear in the yaml.

**Governing.** `A.10` — evidence referred, not asserted. This is §9's own stated purpose.

**Repair.** Move `P-TOK-01` to the unpinned column and split `P-TOP-04` into `router` (pinned) and
`rmn_proxy`/`registry_module_owner` (unpinned). Consider adding an `i_rmnProxy` assertion — like
`getAllowListEnabled` in §9's own recommendation, it costs one line.

---

## D. Framework conformance

### R-16 — the Claim Register's dependency direction is inverted

**As written.** `README.md` §5 gives each claim a **"Checked by"** column. `L-SILO-01` cites Claim A
and a `RealLaneBridge` test; `A-CCV-01`, `A-RL-01` and `A-POM-01` each cite tests and Claim A.
Meanwhile `E-CCV-01` and `E-STATE-01` cite no gate.

**Finding.** `A.6.B` forbids exactly this direction. §6.4: *"`L-*` claims **MUST NOT** depend on or
reference `A-*`, `D-*`, or `E-*` claims"*. §8.4.1, the guideline immediately before Step 4:
*"Keep gate semantics independent of specific evidence carriers: write the gate predicate in `A-*`,
then bind observability in `E-*` that references the gate (`E → A`). `A-*` claims **MUST NOT**
reference `E-*` (no upward dependencies), **even though `E-*` is used to adjudicate gate
satisfaction**."* `E → A` is the canonical motif (§6.2.2).

So the register runs `L → E` and `A → E` on four rows and omits the `E → A` links on the two rows
that should carry them.

**Governing.** `A.6.B` `CC-A.6.B.7`, §6.4, §6.2.2.

**Repair.** Move the adjudication links onto the `E-*` rows — `E-STATE-01 → {A-RL-01, A-POM-01,
L-SILO-01}`, `E-CCV-01 → A-CCV-01` — leaving the gate and law rows pure. If the "Checked by" column
is wanted for readability, mark it explicitly informative, which §6.4 permits for `L-*`.

---

### R-17 — the register omits `A.6.B:7`'s **Canonical location** column

**Finding.** `A.6.B:7` specifies the Claim Register's columns; two of them are missing from
`README.md` §5:

- **Statement (verbatim)** — *"should contain the normative text as authored (copied by value), not
  a paraphrase"*. The register's "Atomic claim" cells are authored summaries.
- **Canonical location** — *"should point to the one place the statement 'lives' … so other faces
  can cite it by ID."*

The second omission is the structural cause of R-04 and R-11. With no declared home per claim, four
documents each wrote their own account of `A-CCV-01`'s quorum and two wrote their own account of the
`transferAdminRole` delay. The register is described in the pattern as *"a drift-control device"*;
without the location column it cannot control drift.

**Governing.** `A.6.B:7`; `A.6.B:6.1`.

**Repair.** Add the column. Suggested homes: `A-RL-01`/`A-POM-01`/`A-CCV-01` gate semantics →
`ARCHITECTURE.md` §5.3; their deployed coordinates → `PARAMETERS.md`; grants (`D-*`) →
`PERMISSIONS.md` §2.2; required effects → `FUNCTION.md` §1; assurance → `README.md` §3.

---

### R-18 — `E.11` is cited for a rule it does not carry

**As written.** `PARAMETERS.md:369`: *"The remaining `EXECUTOR_ROLE` / binding gaps were already
recorded in `PERMISSIONS.md` §2.2.4 and are not restated here (`E.11`: one claim, one governing
location)."*

**Finding.** `E.11` is *Practical-Use Guidance and Pattern Discovery* — it governs how FPF publishes
its own public practical-use cards so a practitioner can find which pattern to open. Its
`EntityOfConcern` is *"one context-free public practical-use guidance episteme … published through
an E.17-conforming public card unit"*. Its closest item, `E11-8`, says *"Preface, ToC, retrieval,
and full patterns do not maintain duplicate card bodies"* — about the spec's own cards, not about
project claims.

The **practice** being invoked is right and is exactly what this review recommends elsewhere. Its
governor is `A.6.B:6.1` (Explicit reference rule) / `CC-A.6.B.4`, supported by `A.10:6` item 6.

**Governing.** `E.8`/`E.11` citation hygiene; `A.6.B:6.1`.

**Repair.** Re-cite as `A.6.B:6.1` / `CC-A.6.B.4`. This is the only misattributed citation found
(see §E-positive below).

---

### R-19 — the "capability" repair `FUNCTION.md` announces was never propagated

**As written.** `FUNCTION.md:40-46` — *"**The one repair this document exists to make.** The repo's
prose says things like *'the only **capability** the live 1.5 path cannot enforce is the dual-CCV
quorum'* (`README.md` §4). Under `A.6.F` that sentence bundles three separately governed things …
It is not a `U.Capability` (`A.2.2`) at all."*

**Finding.** The sentence is still there. `README.md:108`: *"The **only** capability the live 1.5
path cannot enforce is the **dual-CCV 2-of-2 quorum (A-CCV-01)**"*. `ARCHITECTURE.md:271`: *"the one
capability the live 1.5 path cannot enforce"*. And `LIVE_DEPLOY_CONCERNS.md` §2 builds an entire
ledger on the unsplit word: *"of the wstETH 2.0 **target capabilities** … which survive"* (`:159`),
*"loses **exactly one** target capability"* (`:180`).

A repair that is announced in one document and not applied at the sites it names is a claim about
work that did not happen.

**Governing.** `A.6.F` `CC-A6F-2` (no `U.Function`/`U.Capability` minted from function-like
wording), `CC-A6F-4` (capability stays separate from behaviour), `A.2.2`.

**Repair.** Apply `FUNCTION.md`'s own three-way split at each site, by reference — the requirement
is `RB-05`, the gate is `A-CCV-01`, the missing thing is `FE-06`'s **bearer**. `LIVE_DEPLOY_CONCERNS`
§2's ledger becomes a table of *bearers*, which is what it is already measuring ("Borne by (enforced
where)") — only the column header and the word "capability" need to change.

---

## E. Ungoverned claim surfaces

### R-20 — the two most decision-shaping documents carry no classification

**Finding.** `LIVE_DEPLOY_CONCERNS.md` and `draft-manual-test-plan.md` contain **zero** FPF
citations between them — no `L/A/D/E` classification, no `B.3` typing, no `admissibleUse` /
`nonAdmissibleUse` declaration — while the other five documents carry 31 distinct pattern citations.

They are also the two documents whose claims will most directly drive action on a live network:

- feasibility verdicts (*"Feasible now? No"*, §7) that a reader would use to decide whether to
  attempt a deployment;
- a capability ledger that decides what is lost by staying on the real DON;
- a test plan with concrete expected values (*"expect 73/73"*), spend-real-funds steps, and a
  statement of what Step-3 delivery does and does not prove.

And they are the two documents that contradict the governed set — R-01, R-03, R-07, R-12, R-13 all
sit here. That correlation is the finding: the sentences nobody classified are the sentences that
drifted.

**Governing.** `A.6.B` (claim classification); `B.3` `CC-B3.12` — when reliance may materially
change behaviour, safety, release or operational action, the result provides a minimum reliance
safety record **or** explicitly narrows/abstains.

**Repair.** A §0 in each, of the kind `FUNCTION.md` §0 models: subject, `admissibleUse` /
`nonAdmissibleUse`, and a routing of the document's verdicts into the existing IDs rather than into
new prose. `LIVE_DEPLOY_CONCERNS`'s ledger rows are already `A-*`/`L-*` gates by name; the test
plan's steps are already `E-*` evidence for `A-RL-01`, `A-CCV-01`, `L-SILO-01`, `E-STATE-01`.

**Note the good work already there.** `draft-manual-test-plan.md` §5 contains one of the cleanest
scope narrowings in the whole set: *"DON delivery is the one unprovable-from-our-side bit … Treat
Step-3 delivery as 'expected, pending Chainlink', not a hard gate."* That is a `B.3` `G`-narrowing
plus a reopen condition, written without the vocabulary. It should be lifted into `README.md` §3/§5
as Claim B's reopen condition (see R-09).

---

## F. What holds

Stated so this review is not read as a blanket indictment, and so these are not re-litigated.

**Citation integrity is sound.** All **31 distinct pattern IDs** cited across the five governed
documents resolve to real patterns. Every `CC-*` item spot-checked exists and is used with its
actual meaning:

| Cited as | Verified |
|---|---|
| `CC-B3.3` / `CC-B3.4` and `R_eff = max(0, min Rᵢ − Φ(CL_min))` | matches `B.3:7` verbatim |
| `CC-B3.8` (claims published separately, never fused) | `B.3:7` — design-time and run-time in separate tuples; Claim A/Claim B map onto that split correctly |
| `CC-A.6.B.1/2/4` (atomize · classify · reference by ID) | `A.6.B:10` — Atomicity, Quadrant classification, Explicit references |
| `CC-A7.3` / `CC-A7.4` (epistemes do not act; MethodDescription ≠ Work) | `A.7:7` verbatim |
| `A.6.B` §8.4.1 step 4 — *"grants cite gates and evidence; gates never cite grants"* | exact restatement of the supported directions in Step 4 |
| `CC-C30-2/3/8/9`, `CC-A6F-2/4/4A/5/8/9`, `A.18:7.5`, `C.11:4.2.1`, `A.6.RSIR:4.2.1/4.4`, `C.16.P:5` | all present, all used as written |

**The `0xad0f7c64` finding is real and correctly documented.** `PARAMETERS.md` §0.2 is the strongest
piece of analysis in the set: the defect reproduces (`cast sig` = `0xddadfa8e`), the mechanism is
correctly attributed to consuming a representation position as a binding, and the state-mate config
pins both selectors so the gap cannot be silently repaired. R-11 is about two *other* documents not
having caught up with it.

**The permission model matches the contracts.** Every non-trivial claim checked in `PERMISSIONS.md`
§2.2/§3.1 verified against `PoolOperationManager.sol`:

- `propose` / `cancel` are plain `onlyRole(PROPOSER_ROLE) whenNotPaused` — no admin bypass (`:401,457`);
- `execute` is `if (getRoleMemberCount(EXECUTOR_ROLE) != 0) _checkRole(...)`, so the empty set really
  is the grant (`:482-490`);
- the five timelock setters really are `onlyRoleOrAdmin(GUARDIAN_ROLE)` (`:629-698`) — the "the
  guardian's parameter half is the larger half" analysis holds;
- `directCall` is `onlyRole(DEFAULT_ADMIN_ROLE)` (`:709`);
- Neither `L1-POM` nor `L2-POM` has `_authorizeUpgrade`, and neither is `UUPSUpgradeable` (`:26`) — `G-03` / `P-POM-09` /
  `L-NEG-08` are correct.

**The sentinel analysis in `PARAMETERS.md` §7.1 verifies.** `i_allowlistEnabled = allowlist.length
> 0` is `immutable` and `applyAllowListUpdates` reverts `AllowListNotEnabled`
(`AdvancedPoolHooks.sol:86,181`); `_resolveRequiredCCVs` guards `thresholdAmount != 0 && amount >=
thresholdAmount` (`:339-346`). Both sentinel readings are right.

**`FUNCTION.md` is the strongest-typed document in the set.** The `RB-*` / `FE-*` / gap split, the
refusal to mint a `U.Function`, the `A.3.4` countercase for `RB-05`, and §6's insistence that a role
grant is not an ability are all applied consistently. Its own claims verified where checkable
(`FE-09`'s `delay 0` / `grace 1 day`, `FE-10`'s `RESUME_ROLE = ∅`, `FE-11`'s delay structure,
`G-05`'s Claim A gaps). Its only defect is R-19 — a repair it announced for *other* documents.

**Every `just` recipe referenced in `draft-manual-test-plan.md` exists** (`addrs`, `preflight`,
`wsteth-balances`, `ccip-fee`, `stake-eth`, `wrap-steth`, `stake-and-wrap`, `bridge-wsteth`,
`bridge-back-wsteth`, plus the pipeline recipes), as does `script/rpc-proxy.mjs`. Its `73/73` figure
is the correct one (R-03), and its address table matches `config/chains.live-mantle/`.

---

## G. Verification ledger

Every check behind a finding, so the report is itself referred rather than asserted (`A.10:6`).
Run 2026-08-18 against the working tree described in the header.

| # | Check | Result | Feeds |
|---|---|---|---|
| 1 | Count assertions in `config/state-mate/wsteth.yaml` (one per `method`-with-value and per `- args:` entry) | **73** (L1 34 / L2 39) | R-03 |
| 2 | state-mate's counting unit: `incChecks()` call sites | one per `_checkViewFunction`, i.e. per `(method, args-entry)` — `section-validators/base.ts:73,104`, `checks.ts:68-77` | R-03 |
| 3 | `diff` current yaml vs. both archived copies | identical (fork copy differs only in the `rpcUrl` line); unchanged in git since `eb834c3` | R-03 |
| 4 | `git status` / `git log` on `config/state-mate/` | clean, one commit | R-03 |
| 5 | `script/08_verify_state.sh` invocation | `corepack yarn start ${CONFIG} --deployed ${DEPLOYED} --inputs ${INPUTS}`, no `--checkOnly` | R-03 |
| 6 | `test_*` function count | `RealLaneBridge` 12, `RealCcvLane` 3, `CcvBridge` 6 | R-10 |
| 7 | Test names cited by `README.md` §5 | all present in `RealLaneBridge.t.sol` / `RealCcvLane.t.sol` | — |
| 8 | Test names cited by `PERMISSIONS.md:337` (`test_over_cap_rate_limit_reverts`, `test_over_cap_inbound_rate_limit_does_not_mint`) | exist only in `CcvBridge.t.sol` — the **non-gating** self-owned-ramp harness, a different `K` than the gating carriers `README.md` §5 cites for the same gate | R-04-adjacent; see note below |
| 9 | `cast sig 'transferAdminRole(address,address)'` | `0xddadfa8e`; `default_config.json` binds `0xad0f7c64` | R-11 |
| 10 | `cast sig 'setDynamicConfig(address,address,address)'` | `0xae39a257` — matches the config and the state-mate pin | holds |
| 11 | `governance_addresses` across all four chain records | `chainlink_mcms = emergency_brakes = guardian = deployer = 0xE528…0597` in every one | R-06, R-07 |
| 12 | Live deployment archive | `deployments/chains.live-mantle/sepolia-mantle_sepolia/2026-06-12_22-49/` present and tracked; `.gitignore` excludes only `/deployments/forks` | R-01 |
| 13 | Archived run outputs | **none** — archives hold configs, records and `state/`, no state-mate or forge output | R-08 |
| 14 | `RealCcvLane` CCV wiring | `l1.ccvB = new MockCCV()` (`:111`), `_govEnable2of2` → `L1-POM.directCall → applyCCVConfigUpdates([ccvA, ccvB])` (`:150-161`) | R-04, R-05 |
| 15 | Deployed CCV config pinned by Claim A | `getCCVConfig = [[resolver], [], [resolver], []]` — one CCV (`wsteth.yaml:91-97, 230-236`) | R-05 |
| 16 | `script/07_set_pool_gov.sh` registration paths | `registerAccessControlDefaultAdmin` (`:140`), `getCCIPAdmin` probe (`:146`); impersonation branch (`:155-171`) aborts on live RPC | R-12 |
| 17 | `lib/core/contracts/0.6.12/WstETH.sol` | `getCCIPAdmin()` present at `:57` | R-12 |
| 18 | `AdvancedPoolHooks.postflightCheck` body (`:117-134`) | `_validateCaller()` + policy engine; no allowlist | R-14 |
| 19 | `AdvancedPoolHooks` allowlist / threshold sentinels (`:86,181,339-346`) | as documented in `PARAMETERS.md` §7.1 | holds |
| 20 | `PoolOperationManager.sol` gating (`:401,457,482,629-698,709`) and inheritance (`:26`) | as documented in `PERMISSIONS.md` §2.2/§3.1 | holds |
| 21 | Getters named in `PARAMETERS.md` §9 vs. the yaml | all 20 present; `rmn_proxy`, `registry_module_owner`, token metadata absent | R-15 |
| 22 | `justfile` recipes referenced by `draft-manual-test-plan.md` | all present; `script/rpc-proxy.mjs` present | holds |
| 23 | All `` `X.Y.Z` `` pattern citations in the five governed docs vs. the FPF pattern set | 31 distinct IDs, **0 missing** | R-18, §F |
| 24 | `E.11` body and checklist (`E11-1–E11-10`) | governs public practical-use cards; carries no "one claim, one governing location" rule | R-18 |

> **Note on ledger row 8.** `PERMISSIONS.md` §3.3 evidences `A-RL-01` with two `CcvBridge` tests —
> the harness `README.md` §4 and `ARCHITECTURE.md` §6 both classify as **non-gating**, running against
> self-owned ramps under owner impersonation. `README.md` §5 evidences the same gate with the
> **gating** `RealLaneBridge` tests. Both carriers are real; they have different `K` and different
> assurance grade, and `PERMISSIONS.md` states neither. Repair: cite `A-RL-01` and let the register
> own the carrier list (R-17).

---

## H. Governing-pattern cross-reference

| Concern in this review | Governing pattern | Findings |
|---|---|---|
| A claim's exact subject; description ≠ architecture ≠ evidence | **`C.30`** (`CC-C30-1/3/4/9`) | R-02 |
| Atomization, L/A/D/E routing, reference-by-ID, no upward dependencies | **`A.6.B`** (`CC-A.6.B.1/2/3/4/7`, §6.1, §6.4, §7, §8.4.1) | R-01, R-04, R-05, R-06, R-07, R-11, R-16, R-17, R-18, R-20 |
| Typed assurance: `H, C \| K, S`, F–G–R, congruence, decay | **`B.3`** (`CC-B3.1/2/5/6/8/11/12`) | R-03, R-05, R-08, R-09, R-10, R-20 |
| Evidence referred, not asserted; dated Work; carrier recoverable; supersession | **`A.10`** (`:6` items 1, 3, 4, 6, 8) | R-03, R-08, R-12, R-13, R-14, R-15 |
| Representation position ≠ argument declaration ≠ binding ≠ coordinate | **`A.6.RSIR`** (`:4.2.1`) | R-11 |
| Function-like and capability wording carries no claim by itself | **`A.6.F`** (`CC-A6F-2/4`) + **`A.2.2`** | R-19 |
| Currentness of an observation about an external system | **`C.27`** | R-12, R-13 |
| No ranking, no aggregate over the findings | **`G.5`** / **`A.19`** | §0.1 |

---

## I. Suggested order of work

> **Executed 2026-08-18** in this order; outcomes per finding in
> [§J](#j-validation-and-disposition-2026-08-18). Item 3's second half (the step-08 assertion) and
> the pin additions were deliberately deferred — see [J.3](#j3-what-was-changed-and-what-deliberately-was-not).

Not a ranking of the findings (`G.5`) — an ordering by dependency, since several findings close
together.

1. **R-08** (archive the run outputs). One change to `script/08_verify_state.sh` and the `justfile`.
   Closing it makes R-03 and R-10 self-correcting and gives both `B.3` claims the carrier `A.10`
   requires.
2. **R-17** (add the register's *Canonical location* column), then **R-04**, **R-11**, **R-16**.
   The column is what stops the next drift; the three restatements are then deletions, not rewrites.
3. **R-06 / R-07** (principal distinctness). The one finding with a consequence outside the
   documentation: an `L-*` claim plus a step-08 assertion, and `PERMISSIONS.md` §2.2.4 extended.
4. **R-01 / R-02** (status and subject). A decision about what these documents are *about* — worth
   settling before the next live deployment, because everything else inherits the answer.
5. **R-05, R-09, R-12, R-13, R-14, R-15, R-18, R-19, R-20.** Independent; each is a local edit.

---

## J. Validation and disposition (2026-08-18)

A review is itself a description episteme, so its findings are claims that have to be **referred,
not asserted** (`A.10:6`). This section records the independent re-check of each finding against the
repository, and what changed as a result. Grouped, not ranked (`G.5`).

**All twenty findings hold.** Three carry corrections *to the review*, and one is sharpened by a
mechanism the review named imprecisely; none is withdrawn.

### J.1 Re-verification ledger

| # | Check re-run here | Result | Bears on |
|---|---|---|---|
| 1 | Count assertions in `config/state-mate/wsteth.yaml` by hand, per contract block | **73** — L1 34 (`l1TokenPool` 7, `l1AdvancedPoolHooks` 3, `l1PoolOperationManager` 17, `l1LockBox` 2, `l1TokenAdminRegistry` 1, `l1MessageIdVerifier` 2, `l1VerifierResolver` 2) + L2 39 (`l2TokenPool` 7, `l2AdvancedPoolHooks` 3, `l2PoolOperationManager` 17, `l2TokenAdminRegistry` 1, `l2WstETH` 5, `l2MessageIdVerifier` 2, `l2VerifierResolver` 2, `l2OptimismBridgeExecutor` 2) | R-03 |
| 2 | state-mate's counting unit and its summary string | `incChecks()` once per `_checkViewFunction` (`section-validators/base.ts:73`); the printed line is `${g_total_checks} checks passed` / `${g_total_checks} checks, ${g_errors} errors` (`state-mate.ts:164-165`) — **neither `43/43` nor `73/73` is a format state-mate emits** | R-03, R-08 |
| 3 | `git ls-files config/chains.live-mantle deployments` | the live record and the 2026-06-12 Mantle archive are **tracked** | R-01 |
| 4 | `governance_addresses` across all four chain records | `chainlink_mcms = emergency_brakes = guardian = deployer = 0xE528…0597` in **every** one | R-06, R-07 |
| 5 | `test_*` counts and the skip guard | `RealLaneBridge` 12, `RealCcvLane` 3, `CcvBridge` 6; `RealCcvLane` returns early on `!laneIs20` and each test `vm.skip`s | R-10 |
| 6 | `RealCcvLane` CCV wiring | `l1.ccvB = new MockCCV()` then `_govEnable2of2` → `L1-POM.directCall → applyCCVConfigUpdates([ccvA, ccvB])`; `ccvA` is the deployed resolver read from the record | R-04, R-05 |
| 7 | `VersionedVerifierResolver` shape | maps a version tag / dest selector to **one** implementation (`s_versionToInboundImplementation`, `s_destChainToOutboundImplementation`). **It does not fan out** | R-04 |
| 8 | How the OffRamp actually assembles the required set | `OffRamp.sol:523-556` — union of receiver CCVs, **pool CCVs**, and `laneMandatedCCVs`; `defaultCCVs` are appended only if some entry is `address(0)`. `_getCCVsFromPool` calls our hooks' `getRequiredCCVs`, and returns `[address(0)]` **only when the pool declares none** | R-04, R-05 |
| 9 | `AdvancedPoolHooks.preflightCheck` / `postflightCheck` bodies (`:96-134`) and the `Pausable` override | preflight = pause + lane pause + `_validateCaller` + `checkAllowList` + policy engine; postflight = pause + lane pause + `_validateCaller` + policy engine. **No allowlist inbound** | R-14 |
| 10 | `A.6.B` §6.4 and §8.4.1 | §8.4.1 carries verbatim *"`A-*` claims MUST NOT reference `E-*` (no upward dependencies)"*; §6.4 forbids `L-* → {A,D,E}` except explicitly-informative notes; §7 lists **Statement (verbatim)** and **Canonical location** among the register's columns | R-16, R-17 |
| 11 | `E.11` body and checklist | governs FPF's own public practical-use cards; `E11-1–E11-10` carry no "one claim, one governing location" rule. The rule invoked is `A.6.B:6.1` / `CC-A.6.B.4` | R-18 |
| 12 | `B.3` section numbering | `B.3` runs `:1`–`:11b`; **there is no `B.3:20` and no `B.3:22`** — see J.2 | R-09 |
| 13 | `L2BridgeExecutor` / `07_set_pool_gov.sh` / `WstETH.sol` | `updateEthereumGovernanceExecutor` exists (`onlyThis`); step 07 takes `registerAccessControlDefaultAdmin` (`:140`) and the `getCCIPAdmin()` probe (`:146`), and the impersonation branch aborts on a live RPC (`:155-171`); `WstETH.getCCIPAdmin()` is present at `:57` | R-12 |
| 14 | FPF citations per document | `README` 10 · `ARCHITECTURE` 13 · `FUNCTION` 19 · `PERMISSIONS` 8 · `PARAMETERS` 14 · `LIVE_DEPLOY_CONCERNS` **0** · `draft-manual-test-plan` **0**; 31 distinct IDs across the five governed docs, all resolving | R-20, §F |

### J.2 Corrections to the review

Recorded rather than silently fixed, because the review's own citations are load-bearing for the
repairs it prescribes.

1. **R-09 cites two sections that do not exist.** `B.3:20` ("licenses a compact bounded assurance
   claim statement") and `B.3:22` ("requires an assurance claim to name what reopens it") are not in
   `B.3`. The substance survives with the right governors: the *lighter form* is licensed by
   **`B.3:4.2b`**, whose trigger table admits a **compact bounded assurance claim** stating "act,
   context, window, calibration condition, stop condition, bounded evidence use, and unsupported
   attempted use"; the *reopen requirement* is **`CC-B3.11`** (which names decay condition and reopen
   condition explicitly) supported by **`CC-B3.6`** ("decay or valid-until indicators on empirical
   bindings"). `README.md` §3 was rebuilt against those, not against the cited section numbers.
2. **R-04's mechanism is `laneMandatedCCVs`, not `defaultCCVs`.** The review is right that four
   documents gave four accounts and that the code refutes the "resolver fans out" and "lane's own
   default CCV" versions. But it does not name the real one. On a **token-only** transfer — which a
   plain wstETH bridge is — the OffRamp sets `requiredReceiverCCVs = []` and, per its own comment,
   *"don't add the defaults"*; the required set is the pool's declared CCVs ∪ the lane's
   `laneMandatedCCVs`, with `defaultCCVs` reachable only through an `address(0)` placeholder that a
   non-empty pool declaration prevents. `A-CCV-01`'s canonical statement now says this.
3. **R-01's `.gitignore` argument holds.** `.gitignore` lists `/deployments/forks`, and no archived
   fork run is tracked; `deployments/chains.live-mantle` is not ignored and its archive is tracked.
   The conclusion (the live archive is a deliberate, committed artefact) stands.
4. **R-15 understates by one row, in the review's favour.** Besides `P-TOK-01` and `P-TOP-04`, the
   pinned column claimed `P-TOP-02` (`is_siloed`); nothing asserts that flag directly — it is
   *implied* by `l1LockBox.getAllAuthorizedCallers`. Left in the pinned column with that reading,
   since the lockbox's existence and sole caller are genuinely asserted.

### J.3 What was changed, and what deliberately was not

**Documentation repairs** — `README.md` (§1.1 substrates, §3 rebuilt, §4 capability split, §5
register rebuilt with **Statement** + **Canonical location** + `E → A` direction + `L-SEP-01`, §8
counts), `ARCHITECTURE.md` (§0 subject/target split, §1/§5.1/§5.3 gate statements, §3 count, §6
capability split), `PERMISSIONS.md` (scope, §2.2.4, §3.1, §3.2, §3.3, §3.9, §4.3, `D-ACT-07`),
`PARAMETERS.md` (§9 pin coverage, `P-CCV-01` note, `E.11` → `A.6.B:6.1`), `FUNCTION.md` (§0 subject,
§0 repair-applied note, §2.2 allowlist), `LIVE_DEPLOY_CONCERNS.md` (status, new §0a classification,
§1 supersession, §2 allowlist + bearer ledger, §6 scope/date, §7 per-lane verdicts),
`draft-manual-test-plan.md` (new §0.1 classification), `config/README.md`.

**Code repairs (R-08)** — `script/08_verify_state.sh` now tees state-mate's output through a run log,
archives it as `run/state-mate.log`, records `STATE_MATE_RESULT` in `parameters.env`, and copies
`state/forge-scenarios.log` when present; `just test-scenarios` writes that log with a
date/commit/`L2_CHAIN`/record header, under `set -o pipefail` so a failing run still fails. **Neither
was executed** — both need RPC endpoints not available here; the change is syntax-checked
(`bash -n`, `just --evaluate`) and reviewed, not run. Treat the first real run as the verification.

**Deliberately not done, and why:**

- **`L-SEP-01` has no carrier.** R-06's repair has two halves; only the claim half is done. Adding a
  pairwise-distinctness assertion to `script/08_verify_state.sh` would make Claim A **fail on every
  substrate in this repository** — correctly, since the property does not hold. That is a
  deployment decision (rotate four keys, or accept and scope the claim), not a documentation one.
  Until it is taken, `PERMISSIONS.md` §2.2.4 carries the gap and `README.md` §5 marks the claim as
  not obtaining.
- **`getGlobalExpiryPeriod`, `getAllowListEnabled` and `i_rmnProxy` are still unpinned.** Each is one
  line in `config/state-mate/wsteth.yaml`, but each changes the assertion count that every document
  now states, and the count is only re-derivable by a real run. Recorded in `PARAMETERS.md` §9;
  bundle them with the `L-SEP-01` carrier and re-run once.
- **The `0xad0f7c64` selector is not corrected.** It is an upstream `default_config.json` defect;
  `wsteth.yaml` pins both selectors so the gap stays visible. Fixing it changes deployed state.
- **No claim was raised.** Per `CC-C30-9` this review does not adjudicate; the repairs narrow claims
  and add carriers, never scores.

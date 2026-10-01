# Multichain repository approach

## 1. Governing principle

**Organize components by responsibility; make their dependencies explicit; keep
source, target subsystem configurations, plans, execution records, and deployment
claims distinct.**

FPF supplies the distinctions below. The directory layout and engineering rules
are our proposed application of them, rather than prescriptions from FPF.

## 2. Boundaries and ownership

- Root `ledger.json` is the shared deployment catalogue. `components/ledger/`
  owns its schema, validation, formatting, and catalogue-based projections.
- `components/` contains packages with coherent domain responsibilities, explicit
  inputs, outputs, and dependencies: tokens, staking, bridges, governance, the
  deployment catalogue, and its dashboard. Packages
  own their sources, operations, tests, and runbooks, or pin an upstream repository.
- `libs/` contains supporting libraries and tools consumed for implementation,
  building, testing, scripting, or verification. Being required by a deployment
  procedure does not by itself make a dependency a target component.
- `targets/` owns descriptions, configurations, and state checks of named target
  subsystems: their purpose, selected component instances, networks, connections, desired
  parameters, and deployment or upgrade intent.
- `orchestration/` owns reusable procedures that deploy and configure several
  components together. The `wsteth-ccip` deployment scripts belong here; their
  required upstream repositories are classified as components or supporting
  libraries/tools according to their use here. `runs/` holds records of those
  composed operations.
- `components/dashboard/` owns presentation of information consumed from the ledger and
  components; its generated site is written to `docs/` for GitHub Pages.
- `reports/` holds dated catalogue-validation reports; `runs/` holds
  execution records of composed operations. Neither is a source of intent.
- Root tooling coordinates components; each component owns its domain logic.
- Repository membership does not establish on-chain ownership, runtime
  composition, or deployment order.

FPF basis: **A.1, CC-A1-7 and CC-A1-9** — collection membership and system
composition are distinct; managing a system does not make it part of the manager.

## 3. Components and supporting dependencies

- Classify packages by their use in this repository: a component owns a coherent
  domain responsibility; a library/tool supports implementing or operating that
  functionality. Target manifests select relevant components, not every package
  in the directory. Ledger and dashboard serve the multichain product without
  becoming parts of each on-chain deployment. `forge-std` is a script/test library and
  `state-mate` is a verification tool; both belong under `libs/`.
  The current migration moves only these two; OpenZeppelin remains under
  `components/` and in the existing target list as an explicit transitional
  exception, without treating its location as a domain-component claim.
- These are local package categories, not universal claims about upstream
  repositories. A library may contribute compiled code to deployed contracts
  without becoming a separately selected target component. If a repository
  serves both purposes, document both uses and keep one canonical checkout.
- Targets list domain packages in `components` and supporting dependencies in
  `libraries`; the latter does not assert deployed instances. Run provenance
  captures revisions for both, including nested dependencies.
- Allow explicit dependencies, such as the CCIP deployment sources consuming token artifacts.
- Distinguish source/build dependencies, deployed-instance dependencies, and
  orchestration for integration tests or rehearsals.
- Consuming a token component or artifact does not imply deploying a new token.
- Keep build dependencies acyclic and preserve component-specific compiler settings
  and dependency versions.
- Identify consumed sources or artifacts by revision and build provenance.
- Share a dependency checkout when versions are compatible; retain explicit
  separate versions where compatibility requires them.

## 4. Local components and Git submodules

- Local packages and Git submodules may be siblings under `components/` or
  `libs/`, according to their responsibility. Both kinds of dependency need pins
  and consumer compatibility checks.
- Source-management choice is independent of responsibility and dependency type.
- Prefer local ownership for frequent coordinated changes; prefer submodules for
  independently maintained upstream projects and release histories.
- Pin submodules to commits. Review pointer updates together with consumer
  compatibility checks.
- Document each component's source owner, inputs, outputs, and dependencies in a
  small component inventory before introducing a generic orchestration framework.

## 5. Recipe, plan, execution, and catalogue

| Concern | Home | Meaning |
| --- | --- | --- |
| Reusable procedure | Component scripts and runbooks | How an operation is performed |
| Desired subsystem configuration | Target descriptions and manifests | Selected component instances, bindings, and desired parameters |
| Intended change | Component or composed operation plans | What a particular operation should do, in which order and under which conditions |
| Execution record | Component run records or root `runs/` | Inputs, transactions, receipts, and observations from a specific run |
| Deployment claim | Ledger | A supported assertion about an address, role, or relationship |
| Published view | Dashboard | A presentation of identified source information |

- A plan does not establish execution; an execution record is distinct from the
  actual operation it describes.
- Preserve historical run inputs and evidence when current plans or catalogue
  entries change.
- Treat ledger updates as a separate validated step supported by evidence;
  support deployments performed outside this repository too.

FPF basis: **A.15, CC-A15-1, CC-A15-1a, and CC-A15-2** — keep method,
description, intended work, performed work, and records distinct.

## 6. Canonical facts and composition

- Give each maintained fact one canonical home; other modules reference it or
  derive views from it.
- Keep intended parameters, historical observations, and current catalogue
  assertions distinguishable even when they contain the same address.
- Compose components through explicit inputs and outputs, with thin root commands
  and integration checks for affected dependencies.
- Extract shared code when actual reuse justifies it; preserve independent builds
  instead of requiring a single toolchain for the whole repository.

## 7. Shared network and deployment records

- Use the ledger as the common catalogue for token-only, CCIP, direct-staking,
  and other deployments, including externally deployed contracts.
- Preserve its record unit: one concrete network plus one deployed address.
  Proxies and implementations remain separate entries; component membership does
  not create another copy of an address entry.
- Reuse stable `networkId` and `deploymentId` references across components. Keep
  network metadata canonical in the ledger's network catalogue initially; a
  later extraction must preserve one authoritative home.
- Several targets may reference the same token, governance executor, or L1
  receiver. A network may host several tokens, versions, or integrations.
- Generate component-specific address files from selected catalogue bindings when
  tooling requires them. Mark these as derived inputs and retain their source
  revision; do not maintain parallel address books manually.
- Scope fork addresses to their run and fork baseline: a fork can reuse a live
  chain ID and address without representing the live deployment. Keep such
  records separate from the live catalogue.
- Record observations with their network and block/time context. A missing
  catalogue entry does not establish that a deployment does not exist.

## 8. Target subsystem descriptions and configurations

- A **component package** provides reusable code and operations under
  `components/`. A **component instance** is a particular configured use of that
  package; one package may supply multiple contracts or deployments.
- A **target** describes a named subsystem and its intended configuration. Its
  description states purpose and scope; its configuration selects component
  instances, networks, connections, parameters, and intended changes. These
  artifacts describe the subsystem; they are not evidence of deployed state.
- A target directory may hold a subsystem description, deployment configuration,
  and upgrade configurations for that subsystem. Illustrative targets include a
  Mantle Sepolia CCIP setup with intended endorsed governance, and an upgrade
  configuration for an existing deployment. Names identify intent; obtained
  endorsement still requires the governance evidence of section 14.
- An upgrade configuration references the existing deployments, applicable
  starting-state constraints, desired versions and parameters, and changes to
  make. Orchestration derives the operation plan from it and a checked starting
  state; the target configuration alone does not specify the execution order.
- Make the selected component set configuration data. Illustrative selections are
  token plus an existing bridge, token plus CCIP, and direct staking using an
  existing token and shared L1 receiver. These are examples, not exclusive
  network categories or an exhaustive compatibility matrix.
- For each component instance, declare its component package/revision, network,
  parameters, and whether an operation will reuse an existing deployment or
  create a new one. Represent upgrades and configuration changes explicitly.
- Bind existing instances by deployment reference and new instances by symbolic
  output reference. Resolve the latter to actual addresses in the run record;
  never place predicted addresses in the ledger as completed deployments.
- Describe cross-chain lanes and shared L1 components explicitly. One file per
  L2 must not imply a separate deployment of every shared L1 contract.
- Validate references, supported component combinations, network compatibility,
  and required inputs before execution. Omission from a target means
  unselected; removal of an existing deployment requires an explicit operation.

FPF basis: **A.1, CC-A1-11** — a description remains distinct from the system
and construction facts it describes. Target configuration also remains distinct
from the intended work needed to realize it (**A.15, CC-A15-2**).

## 9. Composed operations and shared artifacts

- Let orchestration call component-owned operations through explicit inputs and
  outputs. It owns ordering, cross-component wiring, and integration verification;
  components retain contract-specific deployment and configuration logic.
- Derive an operation plan from the target configuration and an explicitly
  selected, checked starting state. A manifest alone is neither an execution
  plan nor an instruction to redeploy everything.
- Order deployment and configuration steps separately where needed: deploy
  components, resolve addresses, wire permissions and relationships, then check
  the resulting integration. Build dependencies and operation dependencies are
  distinct graphs.
- Snapshot the target configuration, resolved inputs, source revisions, artifacts,
  and starting-state observations for each composed run. Link component run
  records rather than duplicating their evidence.
- Record partial completion and define resume checks for completed steps; a
  failure must not silently trigger redeployment of shared components.
- Publish supported results to the ledger through validation. Keep reusable
  recipes, target configurations, run evidence, and catalogue assertions in their
  respective homes even when one command coordinates their production.
- Put a shared artifact with the module responsible for its meaning: address
  projections with the ledger, target schemas with targets, and
  cross-component procedures with orchestration. Extract common implementation
  libraries only when actual reuse warrants them.

FPF basis: **A.15, CC-A15-1a, CC-A15-2, and CC-A15-7** — distinguish plans,
performed work, and records. **A.15.2** supplies the work-plan distinction for
coordinating intended operations; a selected component list alone is not a plan.

## 10. Migration discipline

- Establish ownership and dependency boundaries before relocating files.
- Move the ledger as a coherent module, updating path-sensitive tooling, hooks,
  CI, provenance links, and publication inputs together.
- Import operational components incrementally, preserving their build environments
  and source provenance.
- Decide explicitly which contract sources become locally maintained and which
  remain pinned upstream dependencies.

## 11. Initial capability set, classified

The requested initial capabilities are of different kinds. Classify each before
giving it a home; do not make them sibling directories by list position.

| Requested capability | Kind | Home |
| --- | --- | --- |
| Scratch debug setup: Lido core scratch deploy plus CCIP wstETH on a testnet | Composed operation over upstream Methods, with a target preset | `targets/` preset + `orchestration/` recipe |
| Community CCIP wstETH deployment | Composed operation over upstream Methods, with a target preset | `targets/` preset + `orchestration/` recipe |
| Current token and bridge contract sources, including the upgrade version | Source and edition dependency | Locally maintained packages or pinned submodules under `components/` (sections 3–4) |
| Deploy contracts needed for an upgrade | Component-owned operation; target declares the change | component script + `targets/` change manifest |
| On-fork integration tests for the live CCIP wstETH setup | Evidence Work against a fork baseline | component tests or `orchestration/` checks; records in `runs/` |
| Dashboard overview of the whole wstETH multichain setup | Publication face over ledger and run records | `components/dashboard/` |
| a.DI governance setup deployment | Component-owned operation of a pinned upstream; shared L1 component | `components/` submodule + target binding |

- A **use case** (debug scratch, community scratch, endorsed scratch, upgrade)
  is a reusable plan template: one target preset, one orchestration
  recipe, and one verification set. It is not a component and not a network
  category.
- "Having the sources" is satisfied by a pinned dependency; it needs no
  operation of its own. Consuming a source edition does not deploy it.

FPF basis: **A.15, CC-A15-1 and CC-A15-2** — Method, description, intended
Work, performed Work, and records stay distinct. **A.15.2, CC-A15.2-2** — a
plan template earns that name only when it states Method, window or entry
condition, performer condition, and the constraints needed to coordinate.

## 12. Wrapping upstream Methods

Most operations reuse deployment scripts owned elsewhere: `lidofinance/core`
scratch deployment, the Chainlink CCIP contract examples, the L2
wstETH token and bridge repository, and the a.DI fork. Each is its own bounded
context with its own configuration model, toolchain, and release history.

- Consume upstream as a Git submodule pinned to a commit. The wrapper calls the
  upstream script in place and does not fork its logic. Record the exact
  edition the wrapper was written against; a pointer update is a compatibility
  change and is reviewed as one.
- A wrapper owns three things: translation of our target configuration into the
  upstream configuration format, invocation with explicit inputs and outputs,
  and post-run verification of what the upstream run produced. It owns no
  contract logic.
- Generated upstream configuration is a derived input. Write it under the run,
  mark its source target configuration and revision, and never hand-edit it.
- Do not assume an upstream field means what a same-named field means in our
  manifests. Map each field explicitly; unmapped upstream fields are reported,
  not silently defaulted.
- Private upstreams (the Chainlink examples) require read access at checkout
  time. A preset intended for external deployers must not depend on a private
  submodule; state this dependency per preset.
- Upstream tests and upstream verification remain upstream evidence. Our
  verification checks our target configuration's intent against observed state;
  it does not restate upstream's own checks as ours.

FPF basis: **A.1.1** — an upstream repository is a bounded model-use
structure; applicability of its model to our target configuration is a claim to be
checked, not assumed. **C.24, items 2, 3, 6** — every planned step names the
upstream Method it calls, the plan records budgets and stop conditions, and a
vendor-bound route description carries its exact edition.

## 13. Two verification layers

Verification after a deployment run and validation of the catalogue are
different claims settled by different work. Keep them apart.

| Layer | Question settled | Inputs | Tooling | Record |
| --- | --- | --- | --- | --- |
| Run-scoped verification | Did this run produce the state the target configuration intended? | target configuration, run outputs, chain reads at a block | state-mate at minimum; source and bytecode checks as the preset requires | run record in `runs/` or the component |
| Catalogue validation | Do current ledger entries still agree with their cited evidence? | ledger, cited sources, public refs | ledger validators, diffyscan cohorts, public-ref probes | dated report under `reports/` |

- Run-scoped verification is a mandatory step of every deployment recipe. Its
  minimum is a state-mate comparison of deployed state against the
  target's intended parameters. Presets may add source verification,
  bytecode comparison, role and permission checks, and lane checks.
- The verification set is part of the preset, because what must be checked
  depends on the component and configuration. A preset without a verification
  set is incomplete.
- A passed run verification supports a ledger entry; it does not create one.
  Ledger publication remains the separate validated step of section 5.
- A verification result names what it checked, at which block, against which
  intended values, and what it did not check. A pass on a fork does not
  establish the live deployment; a pass on a testnet does not establish
  mainnet readiness.
- Catalogue validation runs independently of any deployment and on its own
  schedule. It never redeploys and never edits ledger entries.

FPF basis: **A.6.B, CC-A.6.B.5** — each verification claim names its
predicate, object, observation, scope, and window. **B.3, CC-B3-1, CC-B3-6,
CC-B3-12** — one target claim and one named assurance use per result; design,
fork, testnet, and live results stay separate; a positive result states the
stronger use it does not support.

## 14. Presets and governance neutrality

- Endorsed, community, and debug setups are pre-written target presets
  for the same recipes. They differ in selected components, parameters,
  admin and role holders, target environment, and verification set.
- The repository asserts no endorsement. Whether a deployment is DAO-endorsed
  is a governance fact established by votes and official publications; the
  ledger records pointers to those carriers under `publicRefs` and nothing
  more. A preset named "endorsed" describes intended role holders and
  procedure, not an obtained status.
- Presets are data with a schema. Adding a preset must not require code
  changes to recipes; adding a component type may.

FPF basis: **A.6.B, CC-A.6.B.2 and CC-A.6.B.7** — endorsement is a D-quadrant
governance claim; run and catalogue evidence are E-quadrant claims and must
not reference it as if it followed from them.

## 15. Performers and operating modes

Three kinds of performer will run the recipes, with different admissibility
conditions.

| Performer | Access | Consequence for recipes |
| --- | --- | --- |
| Lido contributors | private submodules, deployer keys, internal RPC | full preset set; review-oriented run records |
| External community deployers | public repositories only, own keys and RPC | community preset must run without private inputs and read as a runbook |
| CI and automation | tokens in secrets, no interactive input | non-interactive mode, explicit budgets, stop conditions, machine-readable results |

- Every recipe supports a non-interactive mode and fails closed when a
  required input is missing. It never prompts in CI and never falls back to a
  different source of inputs.
- Every recipe declares its stop and resume conditions before execution and
  records partial completion. Failure does not trigger redeployment of
  completed or shared components (section 9).
- Reads that inform a decision, such as fork drift checks, record the block or
  time of observation and the RPC used.

FPF basis: **C.24, items 3 and 9** — budgets and stop or replan conditions are
part of the plan; actual calls retain performer, Method, interval, and a trace
reference. **E.16** — unattended runs operate within a declared autonomy
budget.

## 16. Ledgering policy by environment

- Mainnet deployments enter the ledger after validation, as today.
- Long-lived testnet setups that the dashboard shows or that other work relies
  on may enter the ledger with `environment: testnet`. The current Sepolia and
  Mantle Sepolia setup is not ledgered for now; the dashboard keeps reading it from the
  identified upstream chains config record, and says so.
- Throwaway debug runs stay in `runs/` with their run record and derived
  address files. They never enter the ledger.
- Fork deployments are scoped to their run and fork baseline (section 7) and
  never enter the ledger.
- The dashboard reads testnet addresses from the ledger once they are
  ledgered, and from an identified run record until then. It states which.

## 17. First slice and deferred use cases

The first end-to-end slice is the scratch debug testnet setup: a fresh Lido
core from `lidofinance/core` scratch deployment plus CCIP wstETH, on a testnet,
in the shape of the current Sepolia–Mantle Sepolia deployment.

It must exercise, in order: a pinned upstream submodule and wrapper (section
12), a target preset (sections 8 and 14), an orchestration recipe with
recorded partial completion (section 9), run-scoped state-mate verification
(section 13), a run record under `runs/`, and the dashboard reading the run
record as an identified source (sections 5 and 16). Ledger publication is not
part of the slice.

- The upgrade use case is not fixed yet. Represent it as an abstract "change
  an existing deployment" target configuration (section 8) with a fork
  rehearsal as its verification set. Do not encode a target version until it
  is decided.
- The community preset follows the debug slice and reuses its recipe with
  different inputs; it is the first test that presets are data.
- The a.DI deployment serves non-L2 chains, where no rollup-native messaging
  exists to carry governance. It is a component-owned operation of the pinned
  a.DI fork, bound into targets as the governance path for those chains.
  Existing L2 governance executors are unaffected and are not replaced by it.
- On-fork integration tests start on anvil. A fork run record names the fork
  tool, the forked network, the fork block, and the RPC used, so the baseline
  of section 7 is reproducible.

## 18. Open decisions

- **Wrapper toolchain.** Whether wrappers and orchestration stay in Python with
  `just`, matching current repo tooling, or adopt the TypeScript or Foundry
  toolchains of the upstreams. Section 6 permits mixed toolchains; the choice
  shapes `orchestration/` and is not yet made.
- **Upgrade target.** The upgrade use case has no fixed target version
  (section 17).
- **Testnet ledgering trigger.** What makes a testnet setup long-lived enough
  to ledger (section 16) is decided per setup for now.

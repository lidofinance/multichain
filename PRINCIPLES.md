# Design principles

Distilled from [APPROACH.md](APPROACH.md). Principles guide choices; invariants
constrain acceptable designs. The approach supplies details and open decisions.

## 1. Principles — guide choices

1. **Organize by responsibility.** Components own coherent domain responsibilities,
   including deployment functionality, catalogue tooling, and presentation;
   `libs/` supplies supporting libraries and tools for implementation and operations; targets describe named subsystems and own their configurations
   and state checks; orchestration coordinates deployment and upgrade intent;
   the ledger catalogues; the site presents identified sources.
2. **Compose through explicit boundaries.** Connect independently buildable
   components through declared inputs, outputs, and dependencies; keep root tooling
   thin and preserve component-specific toolchains.
3. **Keep one canonical home per fact.** Reference authoritative records and
   generate derived views instead of maintaining parallel address books.
4. **Reuse upstream ownership.** Prefer pinned upstreams for independently
   maintained code and local ownership for frequent coordinated changes. Wrappers
   translate, invoke, and verify upstream operations without copying their logic.
5. **Make variation data.** Express deployment selections and use cases as
   target presets. Extract shared code and frameworks only when reuse
   justifies them.
6. **Evolve incrementally.** Establish ownership before moving files; preserve
   provenance and build environments; prove an end-to-end slice before expanding.

## 2. Invariants — constrain designs

1. **Intent, execution, and claims remain distinct.** Recipes, targets,
   plans, run records, and ledger assertions have separate meanings. Neither a
   manifest nor a plan establishes deployed state.
2. **Dependencies and changes are explicit.** Separate build, deployed-instance,
   and operation dependencies; build dependencies are acyclic. Declare reuse,
   creation, upgrades, and configuration changes. Omission never means removal;
   consuming source never implies deployment.
3. **Identity preserves scope.** A ledger entry identifies one network and one
   deployed address; proxies and implementations are separate. Shared instances
   are referenced, not duplicated. Fork and throwaway deployments never enter
   the ledger.
4. **Runs retain provenance.** Pin upstream commits; review updates for consumer
   compatibility. Preserve run inputs, revisions, artifacts, baseline, and
   evidence. Observations identify their network and block/time; derived inputs
   identify their source and are not hand-maintained.
5. **Execution fails closed and resumes deliberately.** Required inputs, budgets,
   stop conditions, and resume checks are explicit. Recipes support
   non-interactive execution, record partial completion, and never silently
   redeploy completed or shared components after failure.
6. **Verification and publication are separate.** Every deployment preset includes
   run verification, at minimum state-mate checks against intended parameters.
   Results state scope and limits; ledger publication requires separate
   validation. Catalogue validation neither deploys nor edits entries.
7. **Presets do not confer authority.** Adding a preset requires no recipe code
   change; external-deployer presets require no private inputs. Endorsement
   requires governance evidence, never a preset name or a successful run.

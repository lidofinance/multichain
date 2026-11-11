# wstETH CCIP orchestration

The separation of owned migration scripts from unchanged CCIP deployment
scripts, reproducible inputs and acceptance evidence are recorded in the
[implementation report](docs/UPSTREAM-DEPLOY-ISOLATION-RESULTS-2026-11-04.md).

The development target now supports one or more OP-stack spokes, initially Mantle
Sepolia and Base Sepolia, with separate L1 lockboxes. Use the repository-root
`just wsteth` entrypoint to run each phase across the selected topology.
Preparation accepts `--spokes mantle_sepolia` (or `base_sepolia`) for a single-spoke
run. New runs keep L2 state in `state/<chain>.json`.

See [multichain operations](docs/MULTICHAIN-OPERATIONS.md) for run selection,
incremental lane actions, CCV policy, the offline `plan-ccv-update` command and the
Nethermind onboarding checklist. Dummy verification is intentional during setup;
the policy and governance plan allow later implementation/resolver changes.

The [fresh-testnet access guide](docs/SEPOLIA-FRESH-DEPLOY-ACTORS.md) lists
18 controlled actors, key derivation paths, contract authority and operator commands.
Its scratch profile wires the sole TLDO voter, oracle/DSM committees and emergency
controls. The normal DAO-to-L2 path waits 9 minutes in total; CCIP proposals wait
5 minutes, with network delivery measured separately. The profile overrides the
two governance timing values in upstream's default config at runtime; CCIP sources
remain unchanged. `core-access`, `verify-access` and the fork-only `test-access`
are included in `all`. Keys stay outside Git. The fresh public deployment is recorded in
[the 2026-11-04 deployment report](docs/SEPOLIA-FRESH-DEPLOY-2026-11-04.md).

The [Sepolia migration rehearsal plan](docs/SEPOLIA-MIGRATION-REHEARSAL.md)
records the agreed setup for a new token registered in Chainlink's existing
TokenAdminRegistry: impersonation on forks and registration by Chainlink on
public Sepolia. The [Sepolia fork target](../../targets/wsteth-base-migration-sepolia/README.md)
implements the fresh baseline before the shared migration pipeline. The
[Mainnet fork target](../../targets/wsteth-base-migration-mainnet/README.md) starts
from existing contracts. Run `just wsteth-rehearse sepolia`,
`just wsteth-rehearse mainnet`, or `just wsteth-rehearse both` from the repository
root to create fresh owned forks and run the selected lines sequentially.

Imported from the local `wsteth-2.0` checkout at
`9e9b60aaa7b39de08b64f05c1bf9bc9ab11fffd3`, preserving local dependency changes.
The original checkout remains intact. The migration is recorded in this repository's Git history.

`script/` contains the deployment and verification adapters; `justfile` composes
those operations. `src/` contains their small local Solidity build inputs,
`patches/` contains the existing upstream adaptations, and `foundry.toml` retains
the original compiler/profile separation. Required upstream repositories are
under `../../components/` (domain packages) and `../../libs/` (supporting
libraries and tools). Configuration and state/scenario checks are owned by
`../../targets/wsteth-ccip-sepolia-mantle-dev/`.

## Commands

From the repository root:

```sh
just wsteth                         # list recipes
just wsteth patch-submodules-check  # read-only patch/base check
just wsteth build                   # build scripts and scenario tests
just wsteth build-l2-artifacts      # govexec (0.8.10) profile for step 02
just wsteth build-ccip              # the ccip component, release profile (ccip-compile)
```

RPC endpoints and keys stay in ignored `orchestration/wsteth-ccip/.env` or the
process environment. The original `.env` was copied privately, with mode 0600.
Deployment scope, bootstrap mode, fee recipients and migration role overrides
belong to the target or its phase recipes. `workspace.py` and `rehearse.py` reject
caller assignments to the reserved controls listed in `workspace.INTERNAL_CONTROLS`,
including `WSTETH_DEPLOY_SCOPE`, `WSTETH_BOOTSTRAP`, `FEE_AGGREGATOR` and
`HUB_ALLOW_UNACCOUNTED`. The check covers exported variables and assignments in
the orchestration `.env` (even empty values), before child commands or fork startup;
errors name the variables without printing their values. Remove the reported
assignments before retrying. Phase wrappers still set their own internal inputs.
`L2_CHAIN` and `WSTETH_SKIP_L1=1` remain available for individual phase retries;
`all` requires the complete selected topology and does not allow skipping the hub.

Installed dependency packages were copied locally for offline build checks;
compiler outputs were regenerated. Fresh clones use `init` / `init-thirdparty`
with the original upstream package managers and access requirements.

CCIP defaults to `update = none` in the root `.gitmodules` so automatic GitHub
Pages checkouts can skip its private repository. `just wsteth init-thirdparty`
explicitly opts in with `--checkout`. To fetch only CCIP with authorized access:

```sh
git submodule update --init --checkout components/ccip
```

## Target and run boundary

The Sepolia–Mantle Sepolia development target contains the imported configuration,
OP-stack governance route, state checks, and scenario tests. To prepare a new run:

```sh
just wsteth-prepare wsteth-ccip-sepolia-mantle-dev <run-id> fork
just wsteth-use <run-id>
just wsteth preflight
```

Preparation copies the target and owned sources into a new ignored workspace
under `runs/wsteth-2.0/workspaces/`, snapshots revisions and local tracked patches,
and selects it through local `config`, `state`, `broadcast`, and `deployments`
links. It performs no network calls or deployments. Existing run IDs are never
overwritten. Preparation builds in a temporary directory; failures clean it up and
preserve the prior selection. `clean` explains how to prepare a new run; `fresh`
was removed. After resetting forks, prepare a new run ID and run `just wsteth all`.
Execution rejects changes to owned sources, scenario tests, or target templates
since preparation. Prepare a new run for a changed edition; old snapshots remain
historical evidence. This guard does not freeze external packages or RPC state.
CCIP records, broadcasts (`broadcast/ccip/`), and transaction caches are run-local;
upstream build artifacts remain shared.
Operations through `just wsteth` hold a single-workspace lock. Do not run raw
scripts or a second deployment concurrently against shared upstream checkouts.

`--record <repository-relative-path>` on `wsteth-prepare` copies an existing record
under `runs/wsteth-2.0` for inspection/rehearsal; it checks network IDs before
selection. The environment defaults to `fork`, including when options follow:

```sh
just wsteth-prepare wsteth-ccip-sepolia-mantle-dev <new-run-id> --record runs/wsteth-2.0/history/<record>
```

This does not certify the record or determine its substrate.
`dependencies.json` lists current checkouts to capture; preparation requires each
to be its own initialized Git repository. `migration-source.json` remains the
historical import manifest, not a declaration of today's dependency revisions.
The CCIP revision guard reads the parent index's gitlink, including staged updates.

The run environment is explicit (`fork` or `testnet`) and passed to archival
verification. A default record pathname no longer implies a fork. No deployment,
RPC check, governance transaction, or explorer submission was performed by this
migration. Historical claims in `docs/` remain dated source statements; old `just`
examples there refer to the original checkout. Use this entry point for new runs.

FPF basis: A.1 CC-A1-7 separates repository membership from deployed composition;
A.15 CC-A15-1/2 separates procedures, target intent, performed work, and records.

L2 token sources and unit tests are maintained in `components/wsteth-token/`.
Run `just wsteth-token-test` from the repository root. No lido-l2-with-steth
submodule is required. New run snapshots include the local token source edition.

Deployments use `components/ccip` branch `lido-2.0-expiry`, unpatched: the governance of every
deployed CCIP contract is the `LidoTimelock` (Chainlink's `RBACTimelock` plus a proposal-queue
halt and proposal expiry) with its `CallProxy` executor. The pinned revision is `07ae438`;
`governance.expiry_period_seconds` in the component policy is 1,209,600 seconds (14 days
from scheduling, including the minimum delay). Roles after the hand-over: ADMIN = Lido DAO (Agent on L1,
OpExec on L2), PROPOSER = Chainlink MCMS, EXECUTOR = the CallProxy (so anyone executes a ready
proposal), CANCELLER = Emergency Brakes and MCMS, PROPOSAL_QUEUE_HALT = Emergency Brakes, no
bypasser besides the admin. The hooks' pause is a role of their own (Emergency Brakes pause, the
owner unpauses); ownership transfers, upgrades, role changes and TAR admin transfers are blocked
selectors, so they are the DAO's through the bypass only. The policy lives in the component's
`config/default_config.json`; the target carries no copy. The fork scenario `RealTimelockGovernance`
exercises this model on the deployed stack of both chains.

Script 3 registers the pool through whichever registry-module path the token admits — `getCCIPAdmin()`
== deployer (the scratch hub wstETH, core patch 0001; the script then moves the CCIP admin to the DAO
Agent), or the deployer's AccessControl `DEFAULT_ADMIN_ROLE` (the spoke token 1_Deploy deployed; the
script then hands the token admin to the DAO) — binds the pool, hands the registry administration to
the LidoTimelock and the timelock admin to the DAO. Step 07 adds only what the component does not
model: accepting a registry administration another administrator left pending for the timelock
(in-place targets on Ethereum: Chainlink's cutover batch, step 05h; on a target without the hub
migration, the fork-only hand-over of its part D).

## Operations and hubs (2026-10-22)

A target declares its `operation`: `scratch-deployment` (steps 01–02 create the Lido core and the L2
governance executor on Sepolia; the spoke token is deployed by the component) or `in-place-upgrade`
(the contracts exist; step 01m `migration-inputs` records them, step 06 `migration-upgrade` executes
the upgrade batches on forks, after lane deployment/configuration and the hand-over 07). The hub chain is
`L1_CHAIN` (default `sepolia`), exported by `workspace.py` with `WSTETH_OPERATION`; its RPC is
`RPC_<UPPERCASED L1_CHAIN>`, exported as `L1_RPC`. The CCIP governance is the `LidoTimelock` +
`CallProxy` of `components/ccip` branch `lido-2.0-expiry`; the earlier manager binding, its ccip
patches and its documents were retired (`docs/retired-patches/`, `docs/retired-pom/`). First in-place target:
`targets/wsteth-base-migration-mainnet`.

## Hub migration scripts (2026-11-04)

`hub-inventory` reads the old pool at a recorded block and writes the manifest,
standard remote records and `imported_lanes`/`deferred_lanes` metadata. The owned
scripts in `script/hub-migration/` validate those records against the manifest.
`DeployHubForMigration` creates the hub, hooks, governance and the existing lanes'
shared/isolated lockboxes from CCIP release artifacts. `ConfigureHubForMigration`
preserves the full remote pool sets and both rate limits; it configures no extra
CCVs for imported lanes. `hub-prepare` completes ownership and revokes the deployer
admin before `hub-cutover` and `hub-accept-admin`.

`base-prepare` first runs the Ethereum hub checkpoint. Base itself uses stock
upstream `1_Deploy` and `2_Configure`. Our `PrepareHubLane` creates only the new
Ethereum lockbox/verifier/resolver, whose ownership Chainlink MCMS accepts through
a timelock proposal. `BuildHubLaneProposal` writes the six connection calls without
broadcasting or changing deployment records. `hub-connect-lane` checks its run,
chain, hub, timelock and input binding, independently verifies calldata from records
and pinned defaults, executes through CallProxy, then checks old lanes, custody,
balances and TAR. Sepolia also reconnects its bootstrap remotes before Base setup.

`hub_runner.py` runs from this project under `profile.hub-migration`; source scripts
are never copied into CCIP. Broadcast receipts and per-contract artifact/constructor
checks live under `broadcast/hub-migration/` and `state/hub-scripts/`. Failure keeps
partial evidence and requires a new disposable fork. Deployment dry runs cannot
persist simulated addresses; proposal generation intentionally writes its output.

`ccip_build.py` checks the gitlink and tracked/untracked/ignored executable inputs,
then binds actual package/source hashes to a fresh release build. Both runners
verify that binding before execution. CCIP has no local source or test changes.
The two timelock scenarios requiring fresh clock reads after `vm.warp` live in
[`test/hub-migration/LidoTimelockQueue.t.sol`](test/hub-migration/LidoTimelockQueue.t.sol)
and run under `profile.hub-migration` against the CCIP release artifact.
`HUB_MIGRATION_ONLY` is obsolete and rejected.

For replay, pass `--inputs DIR` to `just wsteth-rehearse both`: `DIR/api` contains
the four hashed CCIP API responses and `DIR/{mainnet,sepolia}/forks.json` contains
chain IDs, blocks and hashes. No unavailable input falls back to `latest` or live
CCIP discovery. Without this option the launcher captures a new set. `--capture-only`
saves inputs without deployment; `--through <recipe>` is a development probe and
must not be reported as a full rehearsal. Archive RPCs are still required.

`snapshot-record.py`, record import, CCV policy and state-mate retain the existing
record schema and migration metadata. Chainlink signatures, live DON delivery and
real Nethermind service remain outside the fork rehearsal.

## The component's deploy, used as published (2026-10-25)

For scratch hub/spokes and the new Base stack, steps 04, 05 and 07 run
`1_Deploy`, `2_Configure` and `3_SetPoolAndTransferOwnership` of
`components/ccip` the way its README documents them: from the component's project root, under its
release compiler profile (`FOUNDRY_PROFILE=ccip-compile`, so the deployed bytecode is CCIP's release
build), with its own `config/default_config.json` (no `DEFAULT_CONFIG` override, no target copy of
the policy). The component's `fs_permissions` cover only its `contracts/lido-hvmv/config`, so
`run_ccip_script` (`script/_common.sh`) stages the run's chain records into a run-scoped subdirectory
there for the call and moves them back; only the broadcast receipts are redirected into the run.
A target supplies parameters only: `config/chains/<slug>.json` with the governance addresses, the
lanes, and either the existing token (`addresses.token`) or `token_deployment` (scratch spokes keep
`addresses.token` at `address(0)`; `1_Deploy` deploys the wstETH token behind a
`TransparentUpgradeableProxy` whose ProxyAdmin the L2 executor owns, `2_Configure` grants the pool
mint/burn, `3_SetPool` hands the token admin to the executor). Step 04 writes the scratch
principals (hub token, Agent, OpExec) into the records before the deploy and pins the deployment
identities — timelock, CallProxy, token proxy/implementation, signing key — from the broadcast CREATE
records afterwards (`script/record-deployment.cjs`). The token package the component compiles
(`@lido/wsteth-token`) is pinned by commit in its `package.json`; until the token under review is
released, `script/sync-ccip-packages.sh` keeps that package equal to `components/wsteth-token`
(its OpenZeppelin 4.9.2 copy, RBACTimelock's base, is verified against a pinned commit, not a tag).

Re-runs: `1_Deploy` writes the record only after its broadcast and refuses a record that already
carries a deployment, so step 04 skips a chain whose record carries this run's deployment (its
receipts are under the run's `broadcast/ccip`) and re-deploys only the chain that failed; a
deployment the run never broadcast (an imported record) is refused. The staging directory is named
after the run, comes back through EXIT/INT/TERM traps, and a leftover from a killed call is reported,
never deleted. Which side supplies a spoke's token follows from the record's shape: a record with
`token_deployment` never takes a token from the state file. When step 07 binds a pool while the
registry already names another one (the L1 wstETH of an in-place target without the hub migration),
it announces the cutover and records the displaced pool in the chain state file (`registryPoolBefore`).
With the hub migration the pool is already bound by Chainlink's batch (step 05h, which records the
displaced pool the same way) and step 07 only accepts.

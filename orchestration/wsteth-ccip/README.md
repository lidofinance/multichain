# wstETH CCIP orchestration

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
just wsteth build-l2-artifacts      # separate Solidity 0.8.10 profile
```

RPC endpoints and keys stay in ignored `orchestration/wsteth-ccip/.env` or the
process environment. The original `.env` was copied privately, with mode 0600.
Installed dependency packages were copied locally for offline build checks;
compiler outputs were regenerated. Fresh clones use `init` / `init-thirdparty`
with the original upstream package managers and access requirements.

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

Fresh deployments use CCIP `review/lido-proposals` at `ca8a66b`, with the local
`patches/ccip/0001-token-admin-handover.patch` applied. The POM uses uint16 epochs
and globally keyed proposal IDs: halted proposals remain expired, re-proposal
requires a new ID, and executed predecessors remain Done across halts. This is
a fresh deployment flow; it does not upgrade an older POM storage layout. The
target owns the CCV scenario mocks removed from CCIP upstream.

For CCIP-created tokens (`addresses.token = 0`), configuration grants pool roles,
registers and accepts deployer TAR administration, sets token CCIP admin to the
DAO, then starts the token admin transfer. The DAO may accept before or after
script 3 because TAR administration is separate. The fork scenario suite tests
both acceptance timings with both fresh and pre-proposed TAR registration. The
main target continues to deploy its maintained permit token separately.

Fresh-token scenarios load configuration directly into script harnesses, share the
RPC fallback and `FORK_BLOCK_L2` handling with bridge scenarios, and keep scratch
records in `state`. Configuration rejects foreign TAR proposals; handover checks
TAR readiness before revoking deployer authority. The state-mate matrix checks
the fresh L1 token's separate CCIP admin against the DAO Agent.
Step 07 transfers that admin using the testnet core token's custom authorization;
the CCIP script guards BurnMint setters using DEFAULT_ADMIN_ROLE before broadcast.

### Fresh-flow boundary and handover recovery

The vendored README describes upstream behavior; this section defines the additional host handovers.
Use one reviewed source snapshot for steps 1–3 of the vendored deployment scripts. This flow also
changes token handover ordering: script 2 registers TAR and sets token CCIP administration before
starting the DAO's default-admin transfer. It does not migrate partially configured tokens from
an earlier patch edition. Start a fresh deployment for that case; if governance already accepted
an old token admin transfer, its authorized admin must resolve the remaining authority explicitly.

Step 07 always reads deployment addresses and governance recipients from the active run's canonical
`config/chains` records. `RECORD_DIR` selects records for verification only. The fresh L1 custom
CCIP-admin setter runs after TAR registration and before the POM handover. Each handover can be
retried after a later operation fails, including after the deployer's POM admin was revoked.

The current state matrix asserts the completed fresh-flow end-state, including the L1 token CCIP
admin being the DAO Agent. Older records are not accepted as completed by this matrix. This is an
end-state assertion, not a storage-migration promise. The upgrade rehearsal first rejects the old
epoch-keyed proposal model and checks both expired and pending proposals across the rehearsed upgrade.

Script 3 registers/accepts TAR authority separately from token CCIP administration. For an existing
BurnMint token it calls `setCCIPAdmin` only while the deployer holds token `DEFAULT_ADMIN_ROLE`.
Other token authorization schemes require their own explicit handover; the fresh L1 core integration
in step 07 provides one. A getter alone does not authorize the setter.

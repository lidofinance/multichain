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

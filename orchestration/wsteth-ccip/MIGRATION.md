# wsteth-2.0 import

Source: local `wsteth-2.0`, commit
`9e9b60aaa7b39de08b64f05c1bf9bc9ab11fffd3`, including its local dependency edits.
The original checkout is unchanged. The import performed no deployment.

## Ownership

- Six direct upstream repositories remain pinned submodules under `components/`
  and `libs/`, separated by their use here.
  Their initialized nested dependencies bring the copied checkout count to 16.
- Deployment scripts, recipe ordering, local Solidity build inputs, compiler
  profiles, and upstream patches belong to `orchestration/wsteth-ccip/`.
- Authored configuration, state-mate wiring/ABIs, and scenario checks belong to
  `targets/wsteth-ccip-sepolia-mantle-dev/`.
- Historical tracked records are under `runs/wsteth-2.0/history/`; the complete
  local evidence snapshot is under ignored `runs/wsteth-2.0/imported/`.
- Secrets remain in ignored local files. The source `.env` was copied with mode
  0600; private evidence and generated runtime data are not publication inputs.

This applies FPF A.1 CC-A1-7 (membership is not deployed composition) and
A.15 CC-A15-1/2 (procedure, intended state, performed work, and records are distinct).
The directory names and adapter are repository engineering choices.

## Migration changes

Dependency paths now address `components/` and `libs/` directly. Root `just wsteth` commands
invoke the orchestration recipes from their own directory. Foundry scenario
filters match the absolute paths of target-owned tests; the token compiler
profile continues to build independently.

Run preparation snapshots inputs into a separately named workspace. Deployment
outputs no longer overwrite target templates. Run IDs cannot be reused, and
`clean`/`fresh` refuse destructive resets. Verification archives use the explicit
run environment rather than inferring fork/live from the record pathname.
Historical evidence was copied without rewriting its claims or source revisions.

## Validation

- 502 inventoried original files remain unchanged.
- 457 configuration/evidence files match the private copy byte-for-byte.
- All 16 dependency revisions, tracked changes, and untracked records match;
  copied dependency Git storage and symlinks do not reference the original.
- 112 Python tests pass, including eight run-isolation tests.
- Foundry 0.8.34 and token-profile 0.8.10 builds pass offline, with compiler/lint warnings.
- Token, proxy, and executor runtime instructions match original artifacts after
  excluding compiler metadata changed by relocated source paths.
- Configuration lint, upstream patch/base checks, and shell/Node syntax pass.
- Scenario discovery selects 28 main checks and six optional CCV checks.
  These were listed, not executed against RPC endpoints.
- A local run was prepared successfully without network calls or transactions.

Detailed local inventories and compiler logs are in
`runs/wsteth-2.0/imported/migration-validation/`. The seven Git pointers and
`.gitmodules` record the pinned dependencies; orchestration retains the reproducible
core patches. The migration is committed as separate changes for relocation,
dependencies, procedures, token ownership, run management, history, and documentation. No ledger entries or published dashboard files were changed.

The L2 token subset is now locally maintained in `components/wsteth-token/`.
Its provenance file records the former upstream pin; new run snapshots capture
its sources. The lido-l2-with-steth submodule has been removed.

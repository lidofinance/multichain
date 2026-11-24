# Imported wsteth-2.0 records

- `history/` preserves files that were tracked in the source repository, including
  historical Mantle deployment claims and their original metadata.
- `imported/` preserves the complete local configuration, state, broadcasts and
  deployment archives, including ignored September live and fork records. These
  snapshots are ignored because operator records/logs may contain private data.
- `workspaces/` holds separately named local runs prepared by orchestration.
  Their mutable files and input snapshots are ignored. Publish reviewed evidence
  deliberately; a local run is not automatically a ledger entry.
- `rehearsals/` holds ignored launcher logs, upstream block hashes and outcomes for
  `just wsteth-rehearse mainnet|sepolia|both`. Each entry refers to a workspace with
  the same run ID; a `passed` outcome requires the whole selected pipeline.

The source checkout remains intact. Historical files have not been rewritten to
claim this repository's revision or Monad deployment. Original paths inside the
records describe their source environment. `imported/migration-inventory.json`
retains source hashes for copy-integrity verification.

- [Price-feed research, 2026-10-09](research/price-feeds-20261009/evidence.json) retains the dated observations, sources, calculations and reopen conditions; it is not a current feed selection.
- [Public testnet role holders, 2026-10-08](history/2026-10-08-role-holders.md) records the manager-era deployment.

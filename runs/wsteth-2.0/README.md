# Imported wsteth-2.0 records

- `history/` preserves files that were tracked in the source repository, including
  historical Mantle deployment claims and their original metadata.
- `imported/` preserves the complete local configuration, state, broadcasts and
  deployment archives, including ignored September live and fork records. These
  snapshots are ignored because operator records/logs may contain private data.
- `workspaces/` holds separately named local runs prepared by orchestration.
  Their mutable files and input snapshots are ignored. Publish reviewed evidence
  deliberately; a local run is not automatically a ledger entry.

The source checkout remains intact. Historical files have not been rewritten to
claim this repository's revision or Monad deployment. Original paths inside the
records describe their source environment. `imported/migration-inventory.json`
retains source hashes for copy-integrity verification.

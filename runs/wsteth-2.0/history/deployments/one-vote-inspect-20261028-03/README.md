# Base one-vote fork inspection, 2026-10-28

Preserved on 2026-10-30 from the local step-08 archive of
`one-vote-inspect-20261028-03`, seeded from `one-vote-fork-20261028-02`.
The files under [ethereum-base/2026-10-28_11-08-17](ethereum-base/2026-10-28_11-08-17/)
are byte-for-byte copies; `sha256.json` records their hashes. They include chain
records, state, the component policy, generated state-mate inputs and tables,
ABIs, the scenario log, the state-mate log and the prepared-run manifest.

- `run/state-mate.log`: 219 checks passed, 13 skipped/delegated.
- `run/forge-scenarios.base.log`: 2 scenarios passed (logged at 11:06:09 +0100).
- `migration-run.json`: CCIP revision `07ae438b0028f14d1ccce9072e3f53b8b14e8a09`,
  clean at snapshot time; superproject base `f10eb8a` plus the source hashes
  recorded in `inputHashes`. A base commit alone does not identify its uncommitted changes.

The logs are historical execution evidence, not a run of the current working tree.
The original source snapshots and full broadcasts remain local; this is a reviewed
inspection archive, not a complete standalone replay bundle. The prepared status
in the run manifest is not a deployment acceptance decision.

All endpoints in `parameters.env` are local fork endpoints and all signer material
is limited to public addresses. The archive contains no private keys or credentials.
Logs retain their original local source paths and terminal escape sequences.

The [target README](../../../../../targets/wsteth-base-migration-mainnet/README.md)
states the impersonations, simulated delivery, placeholder role holders and other
limits. This archive does not establish mainnet execution, DON delivery, OP proof
verification, audit completion or readiness for production.

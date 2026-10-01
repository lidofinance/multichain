# Sepolia ↔ Mantle Sepolia upstream rehearsal — 2026-09-15

## Scope and decision

This run evaluates a **fresh deployment** using CCIP `3c1a088`, core `fe5aa4956`
plus the two repository patches, and the other current submodule pins. Transactions
are sent to isolated Anvil forks. Public testnet deployment is deferred.

FPF B.3 (`CC-B3-1`, `CC-B3-2`, `CC-B3-6`, `CC-B3-12`): build compatibility,
deployed state, and behavior are separate claims. The final run result below is
the evidence for this version. Earlier live records and logs do not establish it.
Reopen on any change to source, compiler, configuration, roles, or lane ramps.

## Current integration

This section supersedes the older POM API descriptions in README, config/README,
and the architecture/permissions explainers for this fresh deployment. Existing
live records describe their original deployments and have not been migrated.

- `DeployL2Gov` and `DeployL2Token` compile with Solidity **0.8.34**. They use
  `deployCode` to broadcast CREATE from upstream artifacts compiled separately
  with **0.8.10**, including the proxy's atomic initializer. The `token` profile
  writes `out-token` and `cache-token`; it does not compile deployment scripts.
- The token's compatibility dependency remains OpenZeppelin upgradeable **4.7.3**.
  The directory named `openzeppelin-contracts-upgradeable-4x` had been moved to
  5.7.0, whose API and compiler requirements are incompatible with this token.
- The CCIP POM is UUPS-upgradeable and has **no proposal modes, veto, or approve**.
  `isSelectorBlocked(bytes4)` and `setSelectorBlocked(bytes4,bool)` govern
  admission of new proposals. Cancellation requires `PROPOSER_ROLE`.
- Queue control uses `PROPOSAL_QUEUE_HALT_ROLE` / `PROPOSAL_QUEUE_RESTART_ROLE`
  and `haltProposalQueue()` / `restartProposalQueue()`.
- Transfer control uses `CROSS_CHAIN_TRANSFERS_PAUSE_ROLE` /
  `CROSS_CHAIN_TRANSFERS_UNPAUSE_ROLE` and `pauseCrossChainTransfers()` /
  `unpauseCrossChainTransfers()` (including the hooks' renamed functions).
- Emergency and MCMS receive both stopping roles. Both restart roles are empty;
  DEFAULT_ADMIN can invoke their entry points. A queue halt increments the epoch
  and invalidates pending proposals; a transfer pause leaves the queue intact.
- The hook unpause selector is **`0xa6cc6ef9`**. It is blocked on the L1 hub and
  unblocked on the L2 spoke, preserving the intended three-day MCMS spoke path.
  A proposal can mature before a later pause, so an already-mature proposal can
  reverse that pause immediately. Halting the queue invalidates such proposals.
- `upgradeToAndCall` and `transferOwnership` remain blocked in both queues;
  six sensitive selectors retain their 14-day overrides. Default delay is
  three days and expiry is 30 days from proposal creation.

The state checker pins all four operational roles and their cardinalities,
selector blocking and delays across the current 61-selector ABI surface, proxy
implementation identity, and the remaining pool/token/lane state. The arbitrary
bytes4 space is outside that selector sweep.

## Run conditions

- Fork origins and process details: `/tmp/wsteth-rehearsal-20260915/forks.json`.
- Local transaction endpoints: `http://127.0.0.1:28502` (Sepolia) and
  `http://127.0.0.1:28503` (Mantle Sepolia).
- EVM: Osaka, 100,000,000 block gas limit; Anvil's default transaction gas-limit
  enforcement. These are rehearsal settings, not a claim about live gas limits.
- Core's own state-mate pass remains disabled because its upstream scratch
  schema is known to be stale. This project's state verification remains required.
- CCIP quorum tests require a real 2.0 lane (`CCV_LANE_REQUIRED=1`). Fork tests
  supply receive-side execution/proofs locally; they do not prove DON delivery.

## Result

**Passed on 2026-09-15:** 28 scenario tests, zero failures/skips; 431 state checks,
zero errors; both independent UUPS implementation checks passed. The scenario suite
includes six tests for the new operational roles/timelock alongside bridge, CCV,
permit, and state-preserving UUPS upgrade tests.

- [Archived state and scenario evidence](../deployments/forks/sepolia-mantle_sepolia/2026-09-15_19-03/run/)
- [Local deployment record](../config/chains.rehearsal-2026-09-15/)
- [Source and environment manifest](../deployments/forks/sepolia-mantle_sepolia/2026-09-15_19-03/rehearsal-manifest.json)

The updated state-mate requires explicit chain IDs, proxy declarations, and a
chain/address-keyed gzip ABI store. Step 08 generates that store from the maintained
check ABIs and the chosen record. POM implementation identities are taken from step
04's CREATE transactions and saved with the record, so verification can detect later
implementation changes. `just all` now runs preflight and builds all three compiler
contexts before starting deployment.

Re-run against the retained local nodes:

```sh
RPC_SEPOLIA=http://127.0.0.1:28502 \
RPC_MANTLE_SEPOLIA=http://127.0.0.1:28503 \
L2_CHAIN=mantle_sepolia RECORD_DIR=config/chains.rehearsal-2026-09-15 \
CCV_LANE_REQUIRED=1 just test-leaf
```

Public deployment remains deferred. A public run still needs fresh live preflight,
archived/reset local state, the guarding live RPC proxies, and post-deployment
verification. This rehearsal does not establish real DON delivery or live-network
gas behavior.

### Pre-existing generated artifact

Upstream core pruned `deploy-artifact-11155111-1788528284.toml`. It was reconstructed
from the byte-identical archived scratch parameters, matching DG addresses, and the
historical filename timestamp used to derive emergency-protection expiry. It is not
a byte-for-byte backup restoration. The wrapper now preserves existing DG artifacts
across upstream cleanup. [Recovery details](../deployments/forks/sepolia-mantle_sepolia/2026-09-15_19-03/run/artifact-recovery.md).


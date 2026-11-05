# Multiple spokes and future CCV onboarding

Scope: the development deployment on Ethereum Sepolia, initially with Mantle
Sepolia and Base Sepolia spokes. Nethermind has not supplied its CCV yet.
The initial policy requires Chainlink and our local resolver pointing to the dummy,
in both directions on both spokes. Only Chainlink authenticates source events in
this bootstrap policy; two independent authenticating providers and successful
public delivery remain to be established.

## Topology and run selection

`target.json` uses `networks.l1` and a nonempty `networks.l2s` array. One, two,
three or more spokes use the same runner. Legacy single-spoke targets using
`networks.l2` remain readable. The existing target ID is retained for compatibility.

```sh
# Both configured spokes, with one Sepolia hub:
just wsteth-prepare wsteth-ccip-sepolia-mantle-dev two-spokes-01 fork

# Only one of the configured spokes:
just wsteth-prepare wsteth-ccip-sepolia-mantle-dev base-only-01 fork --spokes base_sepolia

# Inspect, then run the selected target. Use testnet at preparation for a public run.
just wsteth preflight
just wsteth all
```

Supply `RPC_SEPOLIA` and `RPC_<UPPERCASE_SPOKE>` for every selected network.
The full pipeline completes each phase on every spoke before advancing:
core once → all governance executors → all pool stacks (including spoke tokens in step 04) →
configuration → handover → scenarios and state checks per spoke.
Hub deployment/configuration/handover and explorer verification run once per phase.
The L1 state matrix and its archive remain part of each pair check: remote token/pool,
rate limits and lockbox expectations depend on the selected spoke.
`L2_CHAIN=base_sepolia just wsteth verify-state` selects one spoke explicitly;
omit it to check all spokes. `all` requires the complete run topology.
Use the repository-root entrypoint. Internal `all` and `test-leaf` recipes delegate
to the same workspace scheduler; individual shell scripts remain single-spoke workers.

For a retry after the hub phase succeeded, explicitly skip hub work and select the
unfinished spoke, for example:

```sh
WSTETH_SKIP_L1=1 L2_CHAIN=base_sepolia just wsteth ccip-configure
```

The same flag applies to `ccip-deploy`, `set-pool-gov` and `verify-contracts`.
It does not skip any state checks. `ccip-configure` is not generally idempotent:
do not replay completed hub or spoke configuration. If a chain failed partway
through its configuration transactions, inspect its broadcast receipts and state
before continuing; this flag only selects which chains execute, it does not
recover partially applied transactions within one chain.

If upstream configuration completed and only `initial-ccv` failed, inspect its
error and the provider expectations, then rerun just
`just wsteth access-ops initial-ccv <chain>`. This owned step reads back the state
and sends no transaction if it already matches. After deployer handover, any
configuration change must use the DAO route instead.

State is stored in `state/<spoke>.json`; L1 remains `state/l1.json`.
`snapshot-record` copies all chains, their state and CCV policy without resetting
the active deployment. Source snapshots remain immutable; use a new run after
changing source code or the target. Subset selection prunes only the run's copied
configuration, never the target templates or their source snapshot.

For old records without a CCV policy, `verify-state` can apply the historical local-dummy
expectations only to a reciprocal single-lane deployment with a legacy token state.
It reads that record's `state/l2.json`, including old archives with sibling `chains/`
and `state/` directories. It never borrows state from the active run for an alternate
record. Modern records and multi-spoke records require an explicit policy. Missing timelock
and CallProxy pins still need restoration from trusted deployment CREATE records;
compatibility does not bypass those identity checks. If the legacy CCV was changed,
provide its declared policy instead of the historical default.
Importing with `prepare --record` preserves an absent policy rather than inheriting
the target's current intent. Absolute paths, relative paths and symlinks to the
active record use the same state and policy resolution.

Step 08 checks the complete supported-chain, lockbox, CCV and resolver tables with
`verify-state-tables.cjs`, alongside state-mate's per-key and ownership checks.
Only the outer enumeration order is ignored; missing, extra or duplicate rows and
changed bindings fail. The declared expectations (`*.yaml.tables.json`), checked
block numbers and results travel with the verification archive.
State-mate reports these nine delegated getters as skipped; step 08 checks all
nine in the mandatory companion checker before state-mate can run.

Each L1 lane has **a distinct ERC20LockBox**. A single
`SiloedLockReleaseTokenPool` is registered for the L1 token in TAR; it routes each
selector to its own lockbox. Tokens, remote pools, rate limits and CCV requirements
are per lane. Shared timelock/hooks ownership and global pause still have a common
administrative scope. Siloed custody does not imply separate governance or remove
all shared-contract risks.

To author a third spoke, add its chain JSON, reciprocal hub lane with
`is_siloed: true`, `networks.l2s` entry, CCV policy entries and independently pinned
`wsteth.inputs.<spoke>.yaml`. New spokes currently use the OP-stack governance
executor; a non-OP network needs an appropriate governance route as well.
Base infrastructure pins were taken from the
[Chainlink directory](https://docs.chain.link/ccip/directory/testnet/chain/ethereum-testnet-sepolia-base-1)
on 2026-10-08; preflight and the input drift checks remain required for a run.

## CCV policy and generated governance calls

`config/ccv-policy.json` is the desired state, separate from deployment addresses.
Its `chains` must cover exactly the deployed topology. Every chain declares:

- `lanes.<remote>.outbound` and `.inbound`: required resolver arrays.
  `"local"` resolves to that chain's deployed resolver. Literal addresses select
  external resolvers. `0x000...000` explicitly requests lane defaults. Both arrays
  empty means the lane requires no CCVs at all: the hooks hold no entry for it (it is
  absent from `getAllCCVConfigs`, `getRequiredCCVs` is empty) — the state of a lane
  the hub took over from an existing pool (`imported_lanes` in the hub record).
- `localResolver.outbound.<remote>`: verifier implementation for that destination.
  `"dummy"` resolves to the deployed dummy; a literal address selects a replacement;
  `"none"` declares that the local resolver has no implementation for it, and is
  required for (and only for) a lane without required CCVs.
- `localResolver.inbound.<bytes4-tag>`: implementation accepted for that version.
  Remove an entry, or set its address to zero, to request retirement.
- `externalResolvers.<address>`: expected `outbound` implementations keyed by remote
  chain and `inbound` implementations keyed by version tag. These are verification
  expectations for provider-owned contracts, not instructions to configure them.
  Verification checks each declared lane/version binding. Provider ownership, fee
  aggregator, version string and global implementation tables are explicitly outside
  this policy's scope (the provider may serve other projects); state-mate marks those
  getters as skipped. Our local resolver's complete tables remain mandatory checks.

The upstream scripts deploy and configure our dummy/resolver stack. Our owned
`initial-ccv` step then applies the target's two-required-resolver policy before
revoking the deployer's temporary timelock admin. It verifies provider bytecode,
the pinned inbound/outbound mappings and the complete hooks table, recording
`state/initial-ccv.<chain>.json`. The explicit Chainlink resolver is
`0x8f3ee3c77D2B27c32306a89D367654F959Db223D` on all three chains; its expected
implementations and version `0xe9a05a20` are pinned per chain in the policy.
This does not depend on implicit lane defaults. Provider drift stops this step
for review. Upstream `components/ccip` remains unchanged.

After handover, retain a
copy of the verified policy as `before.json`, author the desired `after.json`, then:

```sh
just wsteth plan-ccv-update before.json after.json state/nethermind-plan.json
```

Paths are relative to `orchestration/wsteth-ccip`, or absolute. The planner uses
local records and `cast calldata`; it does not query RPC, sign or broadcast.
The JSON includes policy hashes, chain IDs, required governance callers, decoded
arguments and the timelock `bypasserExecuteBatch` calldata. Reconcile the before-policy with the chain
before executing: this is a plan from explicit inputs, not an on-chain diff tool.
After enactment, install the reviewed after-policy as the run's
`config/ccv-policy.json`, run `verify-state`, and snapshot the result.

Example change for one chain (abbreviated; use actual provider addresses): replace
`"local"` with Nethermind's **local-chain resolver** in both required arrays of every selected
lane, and add its expected inbound/outbound implementations under
`externalResolvers`, preserving the Chainlink entry. Addresses can differ across chains. To replace the local
dummy implementation instead, edit `localResolver`; do not treat an external
resolver address as a verifier implementation.

The generated state-mate matrix retains ownership, role, proxy, remote-pool,
token, rate-limit and custody checks. Whole-hub checks include every supported
selector, every lockbox and every CCV entry; the lockbox guard requires a distinct
lockbox for every siloed lane and exactly one shared lockbox for the lanes that are
not siloed, and the lockboxes other than the selected spoke's are rendered as
contracts of their own (owner, token, authorized callers).
Each spoke's checks run separately. Resolver tables and required CCVs come from
the declared policy; external resolver dispatch is checked against explicit
provider implementation expectations. The checker does not establish the
provider's signer policy, cryptographic correctness or off-chain availability.
Whole-table comparisons ignore the outer row order, including changes caused by
swap-and-pop removal. Row contents, cardinality, duplicates, and the order of tuple
fields and nested arrays remain significant.

## On-chain actions to connect Nethermind

Confirmed scope: **both Sepolia ↔ Base Sepolia and Sepolia ↔ Mantle Sepolia**, in
both directions. Nethermind's contracts replace the dummy verification path.
The intended final requirement is **Chainlink + Nethermind, 2 of 2**; retaining
a dummy does not satisfy it. The initial `ccv-policy.json` requires **Chainlink +
local resolver → dummy** until actual compatible provider addresses and service
settings are supplied. A compatible implementation can replace the dummy behind
our resolver without changing the required resolver arrays.
Resolver dispatch updates and hooks updates preserve token and pool addresses.

There are two arrangements; choose with Nethermind when its implementation exists.

For replacement behind our resolver, the implementation must expose the CCIP 2.0
`ICrossChainVerifierV1` entry points (including fee quoting, forwarding and message
verification), and the first four proof bytes must match the configured inbound
version. For a provider-owned resolver, require the compatible
`getOutboundImplementation(uint64,bytes)` / `getInboundImplementation(bytes)` interface.
An arbitrary contract address is not enough; check the supplied release before
switching. Provider-specific initialization and attestation services remain necessary
in both arrangements.

### Nethermind operates its own resolver (usual external-provider arrangement)

1. Nethermind deploys its verifier and resolver on **Sepolia, Mantle Sepolia and
   Base Sepolia**, or supplies existing supported deployments. Its owner configures
   outbound implementations for each destination, inbound versions, remote-chain
   settings, finality, fees and any allowlists. These are provider transactions.
2. Confirm both directions of both lanes are served. Start the attestation and
   delivery services before making the verifier mandatory.
3. Coordinate the cutover: pause outbound transfers on the affected lanes through
   `hooks.pauseRemoteLanes` (a timelock bypass call), and settle the treatment of already-sent messages. A
   requirement change at the destination can affect messages already in flight.
   Generate explicit pause/unpause transactions separately; the CCV planner emits
   configuration calls only.
4. The Sepolia DAO Agent calls its timelock's `bypasserExecuteBatch([(hooks, 0, data)])`, where
   `data` encodes `applyCCVConfigUpdates`. Submit two entries, one per L2 selector. Each
   entry requires the intended resolvers inbound and outbound; threshold arrays
   remain empty in this setup.
5. Through each L2's governance bridge/executor, call that L2 timelock's same
   `bypasserExecuteBatch` for the Sepolia selector. `requiredCaller` in the generated plan is
   the contract that must call the timelock; it is not an EOA signing instruction. The
   deployer has been revoked and cannot perform these administrative calls.
6. Verify required sets and provider resolver dispatch on all three chains, then
   unpause outbound lanes through the timelock (proposal or bypass) and test delivery
   in all four directions. Include invalid/missing proof rejection and recovery.

Keep the explicitly required Chainlink resolver when connecting Nethermind. Remove the
dummy path from the required sets; if reusing our resolver, retire its dummy
inbound version after resolving messages in flight. Adding a second real path
does not make a still-selectable dummy version safe to retain.

### Replace the implementation behind our existing resolver

1. Deploy/configure an implementation compatible with the resolver and live ramps.
   Establish its unique version tag and off-chain proof availability.
2. On every destination, the timelock calls
   `resolver.applyInboundImplementationUpdates([(newTag, newVerifier)])`.
3. On every source, the timelock calls
   `resolver.applyOutboundImplementationUpdates([(destinationSelector, newVerifier)])`.
   The hub has two destinations; each spoke has Sepolia.
4. Handle old messages according to the cutover policy. Retire the dummy with
   `applyInboundImplementationUpdates([(0xdecafbad, address(0))])` when appropriate.
   A retained dummy version remains selectable by a submitter; merely adding a
   real version does not close that path. Retiring it can strand old dummy messages.
5. Verify the complete resolver tables, then resume and test. The hook resolver
   address, tokens and pools remain unchanged. The planner orders additions before
   outbound switches and places inbound retirements in a separate final phase;
   a phase label does not prove that messages have drained.

The signed `test-access` rehearsal exercises the planner on all three forks:
pause outbound lanes, add inbound implementations, switch outbound implementations,
retain the initial local + Chainlink requirements on all four directions, retire
`0xdecafbad`, verify unchanged token/pool bindings, and unpause. The planner emits
nine resolver updates across the three chains and no hooks update. The replacement
implementation is a `MockCCV` fixture; the rehearsal reverts its changes;
it establishes our governance/control path, not compatibility or authentication
of an unavailable Nethermind release. Provider acceptance still requires its
actual ABI/code, proof format, source/destination configuration, fees, finality,
and running attestation/delivery services.

## What to request from Nethermind

| Required information | Scope / purpose |
| --- | --- |
| Supported networks and directions | Sepolia ↔ Mantle Sepolia and Sepolia ↔ Base Sepolia, four directed lanes |
| Resolver addresses | One on each chain; distinguish resolver from implementation |
| Outbound implementation per destination | Source-chain dispatch and source event metadata |
| Accepted version tags and inbound implementations | Destination-chain proof dispatch, compatibility and retirement policy |
| Verified source/ABI and deployed release | Confirm compatibility with the live CCIP ramps; version labels alone are insufficient |
| Proof format and authentication configuration | Signers/committee, threshold or other trust mechanism, domain separation and who can change it |
| Finality policy | Supported finality encoding, confirmation requirements and reorg handling per source |
| Remote-chain settings and access restrictions | Router/RMN bindings, allowed senders/tokens/pools and who registers our deployment |
| Fees and resource overhead | Fee cents, gas for verification, payload size and any per-transfer arguments |
| Proof service / storage locations | Endpoint, API/schema, access method, availability and message-ID lookup |
| Delivery integration | CCIP indexer onboarding or direct proof retrieval, executor ownership and retries |
| Governance and rollout contact | Who configures provider contracts, upgrade notice, outages and retirement coordination |

Our handoff to Nethermind: chain IDs/selectors, token proxy addresses and decimals,
pool addresses, hooks/resolvers, four directions, deployment transactions/blocks,
and intended verifier policy. Provide finalized addresses from the selected public
run, not addresses of a fork rehearsal. The token address alone does not configure
the pool or enroll an off-chain verifier.

## Adding a later lane to an existing hub

This is an incremental governance operation, not a replay of bootstrap script 05.
The on-chain procedure preserves the hub token/pool and all old lockboxes:

1. Deploy the new spoke's governance executor, token, pool, hooks and initial CCV
   stack. Register the pool in its TAR, grant mint/burn roles, and perform handover.
2. Deploy a new `ERC20LockBox` on Sepolia for the **existing** L1 token. Authorize
   only the existing hub pool with `applyAuthorizedCallerUpdates`, transfer its
   ownership to the existing hub timelock and accept through its bypass (or a proposal).
3. Through the hub timelock, `applyChainUpdates([], [newLane])`: the new selector,
   ABI-encoded spoke token/pool and chosen inbound/outbound rate limits. Add the
   reciprocal lane on the spoke. Do not re-add existing selectors (that reverts).
4. Through the hub timelock, `configureLockBoxes([(newSelector, newLockbox)])` and
   `applyTokenTransferFeeConfigUpdates` for the new lane. Never repoint an old silo
   to a new empty box as a way to add a lane.
5. Configure each selected verifier's remote-chain settings and resolver mappings,
   and set hooks' required CCVs on both ends. For the initial dummy these include
   `applyRemoteChainConfigUpdates` and `applyOutboundImplementationUpdates`.
6. Verify the new lane and preservation of all old ones, then activate and test.

Steps 3–5 on the hub side are what the component's `4_ConnectLane.s.sol` emits for a
lane the hub record lists under `deferred_lanes` (a lane `1_Deploy` built the lockbox
for and `2_Configure` left unconfigured): one JSON batch of owner-only calls —
`applyChainUpdates`, `applyTokenTransferFeeConfigUpdates`, `configureLockBoxes`,
`applyCCVConfigUpdates`, `applyRemoteChainConfigUpdates`,
`applyOutboundImplementationUpdates` — built from the same records and defaults the
scratch configuration uses, for the timelock's proposer (Chainlink MCMS) or the
admin's bypass. The in-place target's step 05c (`hub-connect-lane`,
`script/05c_hub_connect_lane.sh`) replays that batch on a fork as a LidoTimelock
proposal and checks the lane and the preservation of the old ones; see the hub
migration rehearsal in the README.

The new-deployment runner supports arbitrary spoke counts. This incremental
procedure is documented and its custody/governance primitives are tested locally;
it is not an automatic migration/recovery command. Keep transaction receipts,
new lockbox addresses and the expanded desired policy in a new run record before
verifying. Do not run `all` against an already handed-over hub.

Keep target intent, source edition, deployment records and observed configuration distinct.
A generated plan does not establish that its calls were executed. Local contract
tests establish the exercised configuration/custody behavior, not Nethermind
readiness or live cross-chain delivery. See [CCV verification flow](CCV-VERIFICATION-FLOW.md)
for the distinct resolver, verifier, operator and executor roles.

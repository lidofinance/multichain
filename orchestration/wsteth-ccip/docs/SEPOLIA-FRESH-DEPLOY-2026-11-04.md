# Fresh public testnet deployment — 2026-11-04

Status: **deployed and handed over on all three public networks**. Access and
state checks passed. Real L1-to-L2 governance operations completed on both
Base and Mantle. Explorer source is available for all 142 fresh contract addresses;
this includes Similar Match and is not a claim of complete constructor verification.
The stricter 2026-11-05 audit found 32 addresses with no Similar Match marker and
matching constructor arguments, 109 Similar Matches, and one minimal proxy whose
constructor payload was not audited. The four token-address warnings remain.
On 2026-11-05 the user accepted the existing explorer warnings and declined
contacting support; further explorer remediation is not pending for this run.
Public CCIP round trips of **0.001 wstETH per L2** also passed: both deposits
and both returns to Sepolia reached `SUCCESS`, with exact balance conservation.
Four earlier DG source records still contain absolute local paths, accepted by
the user for this deployment. This record describes public transactions, separately from
the earlier disposable fork rehearsals.

Run: `public-20261104-fresh-01`, target `wsteth-ccip-sepolia-mantle-dev`.
Networks: Sepolia (11155111), Mantle Sepolia (5003), Base Sepolia (84532).

The deployment uses the existing privately controlled actors from
[the access guide](SEPOLIA-FRESH-DEPLOY-ACTORS.md). The initial CCV policy requires
Chainlink and our resolver pointing to DummyMessageIdVerifier on all four lane
directions. Nethermind onboarding remains a later operation; the dummy does not
authenticate source events.

## Public records

- [Run workspace](../../../runs/wsteth-2.0/workspaces/public-20261104-fresh-01/)
- [Execution logs and recovery evidence](../../../runs/wsteth-2.0/deployments/public-20261104-fresh-01/)
- [Current execution status](../../../runs/wsteth-2.0/deployments/public-20261104-fresh-01/status.json)

## Addresses for Nethermind

| Network | Chain ID | wstETH token | Creation block |
|---|---:|---|---:|
| Sepolia | 11155111 | `0xEA7dE76a0965696a13ee41AD222978398be27278` | 12064529 |
| Mantle Sepolia | 5003 | `0x0625b02671d6Aa31844175779527D49d119DAfE0` | 46139838 |
| Base Sepolia | 84532 | `0x33C71c79d1A4A1D065865B6a7DB87Ed2FD5DF86e` | 54512593 |

The [shareable address bundle](SEPOLIA-FRESH-DEPLOY-2026-11-04.json) contains
chain selectors, tokens, pools, hooks, both verifier resolvers, dummy verifiers,
timelocks, executors, lockboxes, official routers/registries and creation
transaction hashes. Creation blocks were independently found from public RPC
history and matched to successful CREATE receipts. These are public deployment
addresses, not fork rehearsal addresses. The bundle contains no keys or RPC credentials.

Sepolia stETH is `0x86004A06FbC1AeC7Ea19B09FA3290426A689Dcaf`.
The Lido Agent is `0x25C9d019102BB4b79F1D12D79309E6eE3145f528`, Voting is
`0xD9081AF5eaCE7345F5620Bf423F70e0D73621DB5`, and Dual Governance is
`0xB12Ca69a9B2a294463B51c6D562Bc3a431c4E4A5`.

## Configuration and control

Fresh Core/DG, the Sepolia siloed hub with two separate lockboxes, and both spoke
stacks are deployed. Core is resumed and staking is unpaused. Each token is
registered in the network's existing official Chainlink TokenAdminRegistry, with
the pool selected and registry administration transferred to its LidoTimelock.
Registration succeeded through the supported registry module; these tokens do
not need an additional manual registration by Chainlink.

The initial configuration requires the Chainlink resolver
`0x8f3ee3c77D2B27c32306a89D367654F959Db223D` and our local resolver on every lane
direction. Our resolver still points to DummyMessageIdVerifier. This establishes
only one source-event-authenticating provider until Nethermind is configured.
The pinned Chainlink implementations and initial policy readbacks are recorded
in `state/initial-ccv.<chain>.json`.

LidoTimelock owns the pools, hooks and local verifiers. Its DAO administrator is
the L1 Agent on Sepolia and the corresponding OptimismBridgeExecutor on each L2.
The token and ProxyAdmin roles on L2 are handed over to that executor; temporary
deployer administration has been revoked as required by the access profile.
The existing 18 private actors and their recovery export remain unchanged; see
the [access guide](SEPOLIA-FRESH-DEPLOY-ACTORS.md) for role-specific paths.

Normal governance waits for Voting **300 s**, DG after-submit **120 s**, and DG
after-schedule **120 s**: **9 minutes total configured waiting**. Voting's 60 s
objection period is included in its 300 s. Both L2 executors have **0 s** delay.
Transaction inclusion and messenger delivery add elapsed time. CCIP proposer
operations have a separate **300 s** timelock. Expiry/grace windows are not
additional mandatory waiting periods.

## Verification evidence

| Evidence | Result | Scope |
|---|---|---|
| Access invariants | 192 passed, 0 failed | Public on-chain roles, owners and timing readbacks |
| Core access governance | Vote 0 / DG proposal 1 completed | Real signed public Sepolia transactions |
| Integration scenarios | 35 Mantle + 35 Base passed; no failures or skips | Forks of this fresh public deployment |
| State-mate | 198 passed, 23 skipped for each L1/L2 pair | Read-only public RPC; shared L1 checks repeat per pair |
| Mandatory lane/resolver tables | 9 passed per pair | Complete table comparisons, separate from skipped state-mate enumeration checks |
| L1-to-L2 governance | Passed on both L2s | Real canonical messenger delivery, no impersonation |
| Explorer source availability | 142 source records available; 138 portable | Includes Similar Match; four DG path exceptions accepted |
| Exact constructor audit, 2026-11-05 | 32 pass; 109 Similar Match; 1 minimal proxy without constructor audit | Token re-verification returned Already Verified and retained warnings |
| Public CCIP smoke | All four messages reached SUCCESS; 13 transactions confirmed, none reverted | Sepolia → Base → Sepolia and Sepolia → Mantle → Sepolia, 0.001 wstETH per lane |
| Smoke script tests | 8 passed | Message/proof binding, resume behavior, execution receipt evidence and conservation guards |

Skipped checks are not evidence that their corresponding properties passed.
The state verification archives include the records, generated expectations,
build provenance and readback output under the run workspace's
`deployments/testnet/` directory. The scenario logs are
`state/forge-scenarios.mantle_sepolia.log` and
`state/forge-scenarios.base_sepolia.log`.

The separate [public bridge smoke scripts](../smoke/README.md) completed both
round trips using genuine Chainlink attestations and the current Dummy envelope.
Final Chainlink + Nethermind authentication remains dependent on provider
contracts/configuration and message services.
The [Nethermind onboarding procedure](MULTICHAIN-OPERATIONS.md#on-chain-actions-to-connect-nethermind)
covers both Base and Mantle, in both directions; token addresses remain stable.

## Public governance execution

Both operations followed Voting → Dual Governance → Agent → canonical messenger
→ OptimismBridgeExecutor. Each called its own executor's `updateDelay(0)`,
preserving the agreed zero delay. The messenger's `successfulMessages`, queued
action calldata, executed action state and final delay were independently read
back from public RPCs. All operator receipts and both network relay receipts
were successful; there was no transport impersonation.

| Destination | Vote | DG proposal | L2 action | Network relay transaction | L2 execution transaction |
|---|---:|---:|---:|---|---|
| Mantle Sepolia | 1 | 2 | 0 | `0x613eef76d530231061fff4778a6d81894dfeef299cb0873a7d1cacd508f71184` | `0x10ef12993b17331a834e69298510c1f5dae5962b172f3f9b8d94a97f58d2f2ff` |
| Base Sepolia | 2 | 3 | 0 | `0x7fe8566580a5e9b720060de1a3368db6678b7fa12e6241bf55354912a6bd0695` | `0xae5fdfd99a8b197dea8f6dc1da1af4bca775e378078e734df8feadd6eafe77c9` |

The complete receipts, blocks, timestamps and message hashes are in
[public-governance-proof.json](../../../runs/wsteth-2.0/deployments/public-20261104-fresh-01/public-governance-proof.json).
These operations validate canonical governance delivery, not CCIP token-message
delivery or Nethermind authentication.

## Public token smoke results

The deployer obtained the test tokens through wstETH's public staking entry point,
deposited 0.001 wstETH into each L2, then withdrew both amounts through CCIP.
No privileged token mint, transport impersonation or CCV policy change was used.
Each destination execution supplied a genuine Chainlink attestation and the
deployed Dummy's message-ID envelope. This proves the configured Chainlink +
Dummy path; it does not prove Nethermind or two independent authenticating providers.

| Direction | Destination execution transaction |
|---|---|
| Sepolia → Base | [Base execution](https://sepolia.basescan.org/tx/0xbca3fb748f55ff6a3707ca1c72120f3954d30ba0f5c952089e789f6f0933344d) |
| Sepolia → Mantle | [Mantle execution](https://sepolia.mantlescan.xyz/tx/0x97df3b1b04fe9fa67a794ae7489559d3b41de4941db13e405f5bd663b7e3742d) |
| Base → Sepolia | [Sepolia release](https://sepolia.etherscan.io/tx/0x8ff6f63a0540a806cbbad822901d9fe36f17657c1d0faa3d204ac69c09651ad8) |
| Mantle → Sepolia | [Sepolia release](https://sepolia.etherscan.io/tx/0xa3ee2cdf664ab0e0c79e63ac76619dd8718f418a39ac053b2766ed91e4eea019) |

All four OffRamp execution states are `SUCCESS`; the corresponding execution
events and token transfers were checked in the same successful receipts.
Both L1 lockboxes returned to zero. Both L2 balances and total supplies returned
to zero. The actor's Sepolia balance returned to its post-staking baseline of
`2000000000001000` wei of wstETH (0.002 wstETH plus the 1000-wei staking buffer).
The staked ETH remains wrapped; no Lido withdrawal-queue operation was requested.

The [machine-readable result](SEPOLIA-SMOKE-2026-11-04.json) contains all four
source/destination transactions, message IDs, checked blocks and exact balances.
The full resumable journal, proofs and receipts are retained in
`runs/wsteth-2.0/deployments/public-20261104-fresh-01/smoke/roundtrip-01.json`.
One read-only RPC error interrupted observation; the same journal was resumed
without duplicate transfers. All 13 public transactions confirmed successfully.

## Continuing operations

The active maintenance workspace is `public-20261104-maintenance-20261105`.
It imports the existing three chain records, `.deployed` file and governance
journals, and binds them to the corrected orchestration sources. No contracts
were redeployed and no addresses changed. The original
`public-20261104-fresh-01` deployment snapshot remains unchanged.
Use the maintenance `operator.cjs` under its execution evidence directory to select
`RPC_*_REMOTE` instead of the stopped fork endpoints in the ordinary environment.
For example, from the repository root:

```sh
node runs/wsteth-2.0/deployments/public-20261104-maintenance-20261105/operator.cjs verify-access
node runs/wsteth-2.0/deployments/public-20261104-maintenance-20261105/operator.cjs verify-state
node runs/wsteth-2.0/deployments/public-20261104-maintenance-20261105/operator.cjs governance build l2 base_sepolia /absolute/path/calls.json /absolute/path/operation.plan.json
node runs/wsteth-2.0/deployments/public-20261104-maintenance-20261105/operator.cjs governance advance /absolute/path/operation.plan.json
```

Use Node 24, the existing private environment, and the matching active run.
Build new governance plans against this maintenance run. Historical completed
plans keep their original run identity and must not be replayed. For a new
operation, repeat `advance` after the required waits or messenger delivery and
reuse its same plan and journal after an interruption. Completed deploy/configure/handover
steps must not be rerun as a way to perform later governance changes.

The user approved explorer publication after the deployment. The initial Forge
DG pass used its fully confirmed broadcast; subsequent submissions used direct
explorer verification requests. New source packages must contain only relative
source names and remappings. The archived operator now blocks the old
`verify-contracts` route because that workflow does not enforce this condition.
Use the maintained [exact-verification tools](../verification/README.md) and
prepared portable compiler inputs for publication. They reject absolute paths
and require readback of the expected constructor arguments without Similar Match.
The run's earlier `verify-standard.cjs` / `verify-batch.cjs` helpers now enforce
the same stricter status gate; `Already Verified` alone is not success.

## Explorer verification and accepted exceptions

The [2026-11-05 exact-verification audit](SEPOLIA-EXACT-VERIFICATION-2026-11-05.json)
corrects the earlier interpretation of `verified`: it meant source availability,
including Similar Match. All four token addresses still have Similar Match and
empty constructor records. Submissions with the original encoded arguments
returned `Already Verified` without upgrading those records. The public Mantlescan
verification form also says further verification is unavailable with the current
credentials. [Etherscan documents account whitelisting for this operation](https://info.etherscan.com/update-on-similar-match-contract-verification/).

All four token creation payloads were checked against the saved artifacts and
creation records. The [ready token packages](../../../runs/wsteth-2.0/deployments/public-20261104-fresh-01/verification-exact-20261105/token-exact-verification.zip)
contain relative-path standard-JSON inputs, exact constructor bytes, decoded
arguments, compiler versions and creation-transaction references. The included
support request is an unsent historical draft; the user declined sending it on
2026-11-05 and accepted leaving the current warnings. No contracts were redeployed,
upgraded or reconfigured during this verification attempt.

For the next deployment, normal verification should submit the original compiler
input with relative source paths and the exact creation-time constructor arguments.
This cannot guarantee Exact Match: Etherscan can automatically assign Similar
Match to a new address with already known creation bytecode, before the submission
is processed. Immediate verification alone does not remove that restriction.
The [verification procedure](../verification/README.md) records this limitation;
no compiler or contract changes are made solely to change the explorer badge.

The [address-by-address result](SEPOLIA-EXPLORER-VERIFICATION-2026-11-04.json)
records the earlier source-availability readbacks for 142 fresh addresses. The inventory includes
factory-created Core contracts, the DG escrow clone, DSM guardians, auxiliary
contracts and all three CCIP stacks. Each address had no code at the recorded
pre-deployment baseline and had code at the audit block.

| Network | Addresses with available source | Source packages without absolute paths |
|---|---:|---:|
| Sepolia | 122 | 118 |
| Mantle Sepolia | 10 | 10 |
| Base Sepolia | 10 | 10 |

The four remaining records are on Sepolia:

| Contract | Address |
|---|---|
| Executor | `0xeDC60169EC75Fb4edF2F86466698d8dB44BB980E` |
| EmergencyProtectedTimelock | `0xD616e60431dC32DfC6b82F4C15ed38BC3DE4919C` |
| ImmutableDualGovernanceConfigProvider | `0x6aFC5dD1b0CF91b57469d37616fF30339506e1a8` |
| TimelockedGovernance | `0xAcF071E71dF221711395D657c3250B39a2b17C86` |

These contracts are verified, but their earlier published packages contain
absolute local source names/remappings. Relative-path re-submissions did not
replace those four records. Seven other DG records were successfully verified
with portable packages. The user explicitly accepted these four records for this current deployment.
The absolute paths remain present; no further remediation or redeployment is
requested for this run. All new publications must still use portable packages.
Path normalization changes compiler metadata; it must not be described as an
unchanged metadata hash or as new on-chain bytecode.

The run retains four replacement standard-JSON inputs, compiler versions,
constructor arguments and an [unsent support draft](../../../runs/wsteth-2.0/deployments/public-20261104-fresh-01/verification-repair/etherscan-support-draft.txt)
under `verification-repair/`. Explorer-side remediation requires confirmation
from Etherscan; it has not been promised or requested externally.
[Etherscan's verification FAQ](https://info.etherscan.com/types-of-contract-verification/)
says verified contracts generally cannot be unverified. No replacement deployment
or governance migration was performed to conceal this issue.

A complete record snapshot is retained at
`config/chains.live-public-20261104-fresh-01/` inside the run workspace, including
all three chains, CCV policy, state and completed governance journals.

Known signing keys, the actor mnemonic and configured API credentials were
scanned in the public workspace, execution evidence, relevant Foundry caches,
DG broadcast and helper deployment records. The final scan found no matches;
[scope and file count](../../../runs/wsteth-2.0/deployments/public-20261104-fresh-01/artifact-secret-scan.json)
are recorded. Explorer/provider credentials in generated metadata were redacted;
contract artifacts and bytecode-relevant compiler settings were preserved.

## Execution notes

The DAO voter received 0.02 Sepolia ETH from the deployer for the required signed
governance operations. Other controlling actors were not funded by this run.
The funding receipt is saved as `voter-funding.json` with the execution evidence.

The first CircuitBreaker creation transaction
`0xe57e97f86736019f519268d6f20ae5271fbd5c0587fdec8ab8d3bc194759b350`
failed with `contract creation code storage out of gas`: Foundry supplied
1,426,395 gas, while the public RPC estimated 7,586,344 gas for the same creation.
The owned run launcher now supplies an 800% gas estimate multiplier and sequential
receipts to Sepolia `forge script --broadcast` invocations. This changes gas
allowances and transaction pacing, not contract source or calldata. Base and
Mantle retain their normal estimates. Core resumed from its recorded completed
steps; CircuitBreaker subsequently deployed successfully at
`0x0Cde7564985bC709982F3084B987Fc40bdff82d4`.

The source snapshot and actors JSON are preparation inputs. Their earlier public
deployment status is preserved as part of the frozen input edition; the execution
status linked above records this public run.

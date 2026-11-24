# Dual-CCV fork tests for wstETH

On 18 November 2026, 23 replay tests and 27 current-block tests passed on forks of Sepolia, Mantle Sepolia and Base Sepolia. F-3, F-7 and C-3 remain open. The tables below give the planned checks and the observed outcomes separately. [Switch record](NETHERMIND-CCV-SWITCH-2026-11-18.md) · [Public-testnet checks](NETHERMIND-CCV-MANUAL-VERIFICATION-PLAN.md)

## What the tests must establish

Four live transfers showed that a message passes when both providers sign. They did not show that a message is
rejected when one of them does not. The tests below cover that gap and the behaviour around it:

1. A message executes only with valid proofs from both required CCVs.
2. A proof is bound to one message and cannot be reused or combined with altered content.
3. The retired dummy resolver no longer opens any path.
4. Lido controls (pause, rate limits, CCV list changes) behave as designed with two CCVs.
5. The on-chain configuration behind the Nethermind resolver is what we were told, and a change is noticed.
6. Fees stay within known bounds across transfer sizes.

## What fork tests cannot establish

- That the Nethermind committee signs a new message. A fork has no committee. Tests that need a fresh signature
  either replay recorded real signatures or replace the signers on the fork; the second kind proves contract logic
  only and is marked as such below.
- Delivery by the Chainlink executor, storage location availability, timing.

## Approach

Two kinds of fork, used for different questions.

| Kind | Fork point | Used for | Deterministic |
| --- | --- | --- | --- |
| Replay fork | Destination chain, one block before a recorded message was executed | Proof enforcement with real signatures | Yes, needs an archive RPC |
| Current fork | Latest block of each chain | Configuration, fees, governance operations, source-side behaviour | No. Compare a failed assertion with the deployment at the sampled block |

Recorded messages available as fixtures (real attestations from both providers, taken from the CCIP API):

| Fixture | Route | `messageId` | Executed at destination block | Fork block |
| --- | --- | --- | --- | --- |
| D-MNT | Sepolia → Mantle Sepolia | `0x9c2c261400585b2fd4d1270c4d82c997cbcc15c0993d45d76465ce544d064bed` | 46734791 | 46734790 |
| D-BASE | Sepolia → Base Sepolia | `0x3cd3382210db58904dec6a0b42a8446ad033663caed5716b4b37ddb085d38409` | 60461885 | 60461884 |
| W-MNT | Mantle Sepolia → Sepolia | `0x9b02d36a549585d75191fcb29b188d2f781f02cc004e85fde281f834cf08bba8` | 12162450 | 12162449 |
| W-BASE | Base Sepolia → Sepolia | `0x9849c27fe23608724d670dc78c3b95cb7983bdea44bb88a68e44ca57493a5376` | 12162443 | 12162442 |

Each fixture holds `encodedMessage`, the two CCV addresses and their `ccvData`. The source is
`runs/wsteth-2.0/deployments/public-20261104-ccv-switch-20261118/deposits-01.json` and `withdrawals-01.json`;
`runs/` is not in git, so the fixtures are copied into the test tree.

Fixture O-BASE (optional): one deposit of 2026-11-04 sent under the old policy, with its Chainlink attestation, if
the CCIP API still serves it. It is needed for test F-3 only.

## Running the suites

Run `just wsteth test-dual-ccv` with archive endpoints in `RPC_SEPOLIA`, `RPC_MANTLE_SEPOLIA`
and `RPC_BASE_SEPOLIA`. The recipe writes the test output to `state/forge-dual-ccv.log`. Run it
separately from `all` and `test-scenarios`.

The suites live in `targets/wsteth-ccip-sepolia-mantle-dev/test/scenario/`.
`DualCcvReplay.t.sol` reads the four messages and published attestations from `DualCcvFixtures.sol`.
`DualCcvLive.t.sol` compares each chain with the deployment constants in `DualCcvBase.sol`
and exercises fees, sending and delivery. The switch CLI reads its expected resolver tables from
the CCV policy JSON. Fork-only expectations such as signer addresses and fee bounds are in the Solidity tests.

## Test groups

These tables preserve the original test expectations. “Revert” in an expectation can differ from the observed OffRamp behaviour: the transaction can succeed while the message enters FAILURE. Use the dated results below for the outcome of each case. “Real” identifies checks using deployed verifiers or published attestations. “Logic” identifies checks using test signers or substituted state. Individual rows describe any fork changes.

### A. Proof enforcement (replay forks, all four fixtures)

| ID | Call to `OffRamp.execute` | Expected | Proves |
| --- | --- | --- | --- |
| A-1 | Both real proofs | Success; recipient balance grows by the sent amount; state is SUCCESS | real |
| A-2 | Chainlink proof only | Not executed: state FAILURE, reason `RequiredCCVMissing(Nethermind resolver)`, no token movement | real |
| A-3 | Nethermind proof only | Not executed: state FAILURE, reason `RequiredCCVMissing(Chainlink resolver)`, no token movement | real |
| A-4 | Chainlink proof + dummy proof (`0xdecafbad` ++ `messageId`) under the old local resolver address | Revert | real |
| A-5 | Chainlink proof submitted twice, once under the Nethermind resolver address | Revert | real |
| A-6 | Nethermind proof taken from another fixture of the same lane | Revert | real |
| A-7 | Nethermind proof taken from a fixture of another lane | Revert | real |
| A-8 | Both proofs, message amount changed | Revert | real |
| A-9 | Both proofs, token receiver changed | Revert | real |
| A-10 | Both proofs, destination token changed | Revert | real |
| A-11 | Nethermind proof with one signature byte flipped | Revert | real |
| A-12 | Nethermind proof with one of the two signatures duplicated | Revert | real |
| A-13 | A-1 repeated in the same fork | Second call reverts or leaves balance unchanged | real |
| A-14 | Both proofs, caller is an arbitrary address | Success (execution is permissionless) | real |
| A-15 | A fixture executed on the wrong destination chain | Revert | real |

After every reverting case the test asserts that the recipient balance, the destination supply or lockbox balance
and the execution state are unchanged.

### B. Configuration behind the resolvers (current forks, three chains)

| ID | Check | Expected |
| --- | --- | --- |
| B-1 | Hooks lists for every lane | Nethermind and Chainlink resolvers, outbound and inbound; threshold lists empty |
| B-2 | Nethermind resolver: inbound implementation for tag `0x00010002`, outbound implementation per lane | The recorded verifier of that chain |
| B-3 | Nethermind verifier: signers and threshold per source chain | The two recorded signers, threshold 2 |
| B-4 | Owners of the Nethermind resolver and verifier | The recorded owner |
| B-5 | Runtime code hash of the Nethermind resolver and verifier | The recorded hashes |
| B-6 | Chainlink resolver: implementation for tag `0xe9a05a20` and per lane | The recorded implementation |
| B-7 | Old local resolver | Absent from every hooks list on every chain |
| B-8 | Token pools: supported remote chains | Mantle Sepolia has no lane to Base Sepolia and the reverse |
| B-9 | `OffRamp.getCCVsForMessage` for a fixture message | Exactly the two resolvers required, none optional |

A failure here means the live deployment changed. The test output names the differing value; it does not try to
decide whether the change is acceptable.

### C. Fees (current forks)

| ID | Check | Expected |
| --- | --- | --- |
| C-1 | `router.getFee` for 0.001, 1, 100 and 10000 wstETH on all four routes | Recorded in the log; Nethermind share taken from a simulated send |
| C-2 | Nethermind share as a function of amount | Matches the bps rate read from the verifier, within its minimum and maximum |
| C-3 | Total fee for every amount | Below the bound set in the policy file |
| C-4 | Fee recipients in a simulated `ccipSend` | Nethermind resolver, Chainlink resolver, pool, executor, router; no other recipient |

C-3 needs a bound that Lido chooses; until it is chosen the test only records values.

### D. Source side with two CCVs (current forks)

Sending needs no signature, so these run with unmodified contracts.

| ID | Scenario | Expected | Proves |
| --- | --- | --- | --- |
| D-1 | `ccipSend` on each of the four routes | Success; `CCIPMessageSent` lists both resolvers; tokens locked or burned | real |
| D-2 | Receiver differs from sender; receiver is a contract | Success; message carries the receiver | real |
| D-3 | Non-empty `data` together with a token | Result recorded: accepted or rejected, and by which contract | real |
| D-4 | Amount above the outbound rate limit | Revert | real |
| D-5 | Amount equal to the available rate limit capacity | Success | real |
| D-6 | Zero amount | Revert | real |
| D-7 | Faster-than-finality request in `extraArgs` | Result recorded per contract: hooks, each verifier | real |
| D-8 | Ten sends in one block | Ten distinct message ids, sequence numbers consecutive | real |
| D-9 | Lockbox balance per lane after D-1…D-8 | Grew by exactly the sent amounts | real |

### E. Destination side for messages created on the fork

A message created on the fork has no real signatures. The signers of both verifiers are replaced with test keys by
acting as the verifier owners. These tests show how the contracts treat such messages, not that the committees
would sign them.

| ID | Scenario | Expected | Proves |
| --- | --- | --- | --- |
| E-1 | Round trip for D-2 (contract receiver) | Tokens arrive at the contract | logic |
| E-2 | Amount above the inbound rate limit | Execution reverts; succeeds after the limit refills | logic |
| E-3 | Ten messages executed in reverse order | All succeed | logic |
| E-4 | Signatures from the Nethermind signer set of another source chain | Revert | logic |
| E-5 | One valid signature out of two | Revert | logic |
| E-6 | Supply check after a full round trip on both spokes | Lockbox balance per lane equals the spoke supply change | logic |

### F. Governance and emergency operations (replay and current forks)

Governance calls are made as the timelock caller of each chain, as the existing scenario tests do.

| ID | Scenario | Expected | Proves |
| --- | --- | --- | --- |
| F-1 | Replay fork; hooks paused before execution; execute with both proofs | Revert; after unpause the same call succeeds | real |
| F-2 | Replay fork; hooks list switched back to the old policy before execution | Both real proofs are rejected or accepted — result recorded; Chainlink proof + dummy proof succeeds | real |
| F-3 | Fixture O-BASE on a current fork (sent under the old policy, executed under the new one) | Revert: a message sent before the switch cannot complete after it | real |
| F-4 | Replay fork; Nethermind resolver removed from the inbound list only | Executes with the Chainlink proof alone | real |
| F-5 | Replay fork; time moved forward 30 days; execute with both proofs | Result recorded: proofs do or do not expire | real |
| F-6 | Lane disabled in hooks; `ccipSend` | Revert | real |
| F-7 | `ccv-switch run --revert` in the opposite direction on current forks | Passes; unrelated state unchanged | real |
| F-8 | Replay fork; verifier owner replaces the signers; execute with the recorded real proofs | Revert | real |
| F-9 | Replay fork; resolver owner points tag `0x00010002` at a verifier with one attacker key; forged proof | Success | real |

F-9 is expected to succeed. It is a demonstration, kept as a test so the document for mainnet can cite it: the
owner of the Nethermind resolver can alone satisfy the Nethermind side.

## Results of 2026-11-18

`just wsteth test-dual-ccv` runs two suites in `targets/wsteth-ccip-sepolia-mantle-dev/test/scenario/`:

| Suite | File | Fork | Tests | Result |
| --- | --- | --- | --- | --- |
| `RealDualCcvReplayTest` | `DualCcvReplay.t.sol` | Destination chain one block before each of the four real deliveries | 23 | All pass |
| `RealDualCcvLiveTest` | `DualCcvLive.t.sol` | Current block of the three chains | 27 | All pass |

Shared code is in `DualCcvBase.sol` (the deployment constants and helpers) and `DualCcvFixtures.sol` (the four
messages and their attestations). The first replay run takes about 25 minutes against public archive endpoints;
later runs use the Foundry RPC cache. The live suite takes under a minute.

With the recorded two-provider policy, the four original messages delivered with both attestations. The replay tests also checked missing proofs and altered messages. The result tables identify the configuration used for each case.

### Findings

| # | Finding | Shown by | Why it matters |
| --- | --- | --- | --- |
| 1 | One plain key, `0x36243b8B92b1a0F6C92a69a32aE1F8dC183788A5`, owns the Nethermind resolver and verifier on all three chains. With one call it satisfies the Nethermind side of any message without the committee. | F-9a, F-9b | The second verifier is as strong as this key. The key alone cannot move tokens: a Chainlink attestation over the same message is still needed (F-9c). |
| 2 | The same key can stop or censor sending: enable a sender allowlist (only chosen addresses can bridge out), remove the outbound mapping, or raise its fee to $655.35 per message. On Base Sepolia that fee exceeds the OnRamp limit of $100 per message and sending becomes impossible. | G-1, G-2, G-3 | A liveness and censorship power held by one key, with no delay. |
| 3 | The same key can invalidate attestations already published: after a signer rotation the recorded real proofs are rejected. | F-8 | Messages in flight stay undelivered until the committee re-signs or Lido changes the CCV list by a vote. |
| 4 | The Nethermind committee is 2 of 2, the same two signers for every source chain. | B-3 | One signer offline stops every wstETH transfer in both directions. |
| 5 | Returning the hooks to the previous policy lets anyone deliver a pending message with the Chainlink attestation and a dummy proof built from the message id. | F-2 | The previous policy is not a safe fallback: it is Chainlink alone. An emergency procedure needs another target list. |
| 6 | The Nethermind fee is 5 bps of the transferred value, at least $0.10 and at most $10.00 per message. At 1 wstETH it is $1.10 and is 42% to 81% of the whole fee, depending on the route; from about 9 wstETH it is $10.00. The Chainlink verifier charges nothing on these testnets. | C-1, C-4 | The earlier estimate of 6% to 28% held only for the 0.001 wstETH test transfers. |
| 7 | If the price source of the Nethermind verifier fails, the fee drops to the minimum and the send goes through. | C-2b | Fail-open by configuration (`requireAllTokensPriced` is off); a concern for Nethermind, not a risk for the bridge. |
| 8 | A rejected `execute` call does not revert the first time: the OffRamp records FAILURE and the message stays deliverable. A second failing call reverts with `NoStateProgressMade`. | A-2, A-13b | Anyone can put a pending message into FAILURE; monitoring must not read FAILURE as "lost". |
| 9 | Bytes after the declared signatures in a proof are not checked. | A-12b | One message has many acceptable proofs; nothing may identify a delivery by its proof bytes. |
| 10 | The destination accepted the recorded attestations after the fork clock advanced 30 days. | F-5 | These proofs remained usable after that delay under the same signer configuration. |

### Observed outcome per row

Group A, on all four fixtures unless noted. "FAILURE" means the call returned and the state became FAILURE with
the named reason; in every such case the recipient balance and the token supply did not change, and where the
row says so the same message was then delivered with both real proofs on the same fork.

| ID | Observed |
| --- | --- |
| A-1 | SUCCESS, recipient receives exactly the sent amount |
| A-2 | FAILURE `RequiredCCVMissing(0x28ceF597339bb0B351ae4e62f73d762c9cC51D5c)`; then delivered |
| A-3 | FAILURE `RequiredCCVMissing(0x8f3ee3c77D2B27c32306a89D367654F959Db223D)`; then delivered |
| A-4 | Dummy proof under the old resolver: FAILURE `RequiredCCVMissing`. Dummy proof under the Nethermind resolver: FAILURE `InboundImplementationNotFound` |
| A-5 | One provider's proof in both slots: FAILURE `InboundImplementationNotFound`. The Chainlink resolver listed twice: FAILURE `RequiredCCVMissing` |
| A-6, A-7 | Nethermind or Chainlink proof of another message (other destination chain for the deposits, other source lane for the withdrawals): FAILURE `UnauthorizedSigner`. A second fixture on the same lane does not exist, so A-6 is covered only in this form |
| A-8 | Amount ×1000: FAILURE `UnauthorizedSigner`; the original message untouched, then delivered |
| A-9 | Token receiver or message receiver changed: FAILURE `UnauthorizedSigner`; the other address receives nothing |
| A-10 | Message number, sender or finality changed: FAILURE `UnauthorizedSigner`. Destination token changed to an address without a pool: not executed, no token moved |
| A-11 | One byte flipped in either signature: FAILURE `UnauthorizedSigner` |
| A-12 | A signature repeated or the two swapped: FAILURE `NonOrderedOrNonUniqueSignatures`. One signature or none: FAILURE `WrongNumberOfSignatures`. Declared length longer than the data, or tag only: FAILURE `InvalidVerifierResults` |
| A-13 | Second execution reverts with `SkippedAlreadyExecutedMessage`; no second payout |
| A-14 | SUCCESS from an arbitrary caller |
| A-15 | Each message on the OffRamps of the other fixtures: revert, state stays UNTOUCHED |

Group F on the replay forks:

| ID | Observed |
| --- | --- |
| F-1 | Hooks paused: FAILURE `TokenHandlingError` wrapping `EnforcedPause`; after unpause the same proofs deliver |
| F-2 | Inbound list set to the old resolver and Chainlink: the two real proofs give FAILURE `RequiredCCVMissing`; the Chainlink proof with a dummy proof delivers, from an arbitrary caller |
| F-4 | Inbound list with Chainlink only: delivered with the Chainlink proof alone. With Nethermind only: delivered with the Nethermind proof alone. In both cases an altered amount is still rejected with `UnauthorizedSigner`, so each verifier binds the content on its own |
| F-5 | Delivered after 30 days and 1,000,000 blocks |
| F-8 | After the Nethermind owner replaces the signers: FAILURE `UnauthorizedSigner` |
| F-9 | Passes both ways: the resolver owner points tag `0x00010002` at a verifier that accepts anything; the verifier owner installs a one-key committee and signs. Each time the real Chainlink proof plus the forged Nethermind side delivers the message |
| F-9c | The forged Nethermind side with an altered message (100 wstETH to another address): FAILURE `UnauthorizedSigner` from the Chainlink verifier |

Groups B to G at the current block:

| ID | Observed |
| --- | --- |
| B-1, B-7 | Every lane requires exactly the two resolvers, both directions; threshold lists empty, threshold amount 0, hooks not paused; the old resolver is in no list |
| B-2 to B-5 | Nethermind resolver maps tag `0x00010002` and every outbound lane to the recorded verifier; signers `0x2fb64E058fDF73Da1B39063Dc64F9f0863005B67` and `0xaEE7D7E9748d8a2Ee598a4642634B9eC97a64f53`, threshold 2; owner and code hashes as recorded |
| B-6 | Chainlink resolver maps tag `0xe9a05a20` to the recorded verifier; committee 9 of 16; the owner is a contract |
| B-8 | Sepolia pool supports the two spokes; each spoke pool supports Sepolia only |
| B-9 | `getCCVsForMessage` returns the two resolvers as required, none optional, for all four fixtures |
| B-10 (added) | Pools and the Nethermind verifier accept only full finality; the Chainlink verifier would accept more (`0x00010001` on Sepolia, `0x00000001` on the spokes); fast-finality rate limits are disabled |
| C-1, C-2 | Nethermind fee equals the configured rule for 0.001, 1, 100 and 10000 wstETH on all four routes: 10, 110, 1000 and 1000 cents. OnRamp limit per message: $10,000 on Sepolia and Mantle Sepolia, $100 on Base Sepolia |
| C-3 | Not implemented: needs a bound chosen by Lido |
| C-4 | Five receipts: Nethermind resolver, Chainlink resolver, pool, executor, router; they add up to the quoted fee. Shares at 1 wstETH: Nethermind 80%, 68%, 81% and 42% on the four routes; Chainlink resolver and pool 0 |
| D-1, D-9 | Sent on all four routes; the message names both resolvers; the lockbox grows, or the spoke supply shrinks, by exactly the amount |
| D-2 | Covered by E-1 |
| D-3 | A token transfer with data and a callback gas limit is accepted; both resolvers are paid and both are required at the destination |
| D-4, D-5 | Above the capacity of 330 wstETH: `TokenMaxCapacityExceeded`. The whole available amount is sent; the next send fails with `TokenRateLimitReached` |
| D-6 | `CannotSendZeroTokens` |
| D-7 | A request for block depth 1, block depth 64 or the "safe" flag is refused with `InvalidRequestedFinality` on every route; the same extraArgs format with finality zero is accepted |
| D-8 | Ten sends in one block: consecutive message numbers, accounting exact |
| D-10 (added) | A send between the two spokes is refused by the pool with `ChainNotAllowed` |
| E-1, E-6 | Round trip on both spokes with a contract as receiver: delivered; lockbox and spoke supply move by the same amount and return to the start |
| E-2 | Second delivery above the inbound capacity of 500 wstETH: FAILURE wrapping `TokenRateLimitReached`; delivered after the limit refills |
| E-3 | Ten messages delivered in reverse order on every route |
| E-4, E-5 | Signatures of a committee configured for another source chain, of one member with an outsider: FAILURE `UnauthorizedSigner`; one member alone: `WrongNumberOfSignatures`; the full committee then delivers |
| E-7 (added) | A message signed by both committees that names another source pool: FAILURE wrapping `InvalidSourcePoolAddress` |
| E-8 (added) | A fully signed withdrawal larger than what its lane locked is refused although the other lane's lockbox holds enough |
| F-6 | Outbound lane disabled: send reverts with `DisabledRemoteLane`. Inbound lane disabled: FAILURE wrapping `DisabledRemoteLane` |
| G-1 to G-3 (added) | Each owner action has the effect described in finding 2 |

### Not implemented

- F-3: no message sent under the old policy is available with its attestation. F-2 and F-4 show the rule it
  would test: only the inbound list at execution time decides, so such a message cannot complete without a
  Nethermind attestation.
- F-7: `ccv-switch` in the opposite direction on local forks.
- C-3: the fee bound.
- The fixture builder script and JSON fixtures: the fixtures are a Solidity library generated once.

### Limits of these results

- Groups E and G and the F rows act as an owner on the fork. They show what the contracts allow, not what the
  owners will do.
- The live suite reads the state at the block of the run. It was last run on 2026-11-18.
- Hooks operations are made as the hooks owner (the Lido timelock) directly; the route from a DAO vote to the
  timelock is covered by the vote executed on 2026-11-18, not by these tests.

## Implementation order

The suites were developed in the following order. The outstanding checks are listed above.

1. Capture the four fixtures and establish the contract getters, revert selectors and lane settings needed for assertions.
2. Group A. This is the gap with the highest value and needs nothing else.
3. Group B and C-1, C-4: read-only.
4. F-1 to F-5, F-8, F-9: they reuse the replay harness.
5. Group D, then E, then the remaining F and C.

## Done when

- `just wsteth test-dual-ccv` runs every group against archive RPCs and writes a dated log.
- Each "result recorded" row above is replaced by the observed behaviour, written into this file.
- Rows whose outcome contradicts the design are listed in the manual plan as open questions.

## Known constraints

- Replay forks need archive access to the three testnets at the blocks in the fixture table.
- Group B fails by design when Nethermind or Chainlink change their deployment; it is a detector, not a gate for
  unrelated work, and stays out of `all`.
- Tests in group E depend on being able to act as the verifier owners; if a verifier turns out to be immutable in
  that respect, the affected rows move to the manual plan.

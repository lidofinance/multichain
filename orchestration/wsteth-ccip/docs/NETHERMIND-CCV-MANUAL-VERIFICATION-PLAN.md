# Public-testnet checks for the Chainlink and Nethermind verifiers

On 18 November 2026, the hooks on all three testnets required both resolvers on every wstETH lane.
Chainlink executors delivered one transfer in each of the four directions. Each had attestations
from both providers. Delivery took 18 min 41 s to 22 min 33 s. [Switch record](NETHERMIND-CCV-SWITCH-2026-11-18.md)

The 50 fork tests that passed that day exercised proof verification, pause and lane controls,
rate limits and lockbox accounting. The checks below cover provider operations, executor retries
and public-network timing. For each completed check, add the evidence in its row to the switch record.
[Tests and observed outcomes](NETHERMIND-CCV-FORK-TEST-PLAN.md#results-of-2026-11-18)

## 1. Live operations on the public testnets (Lido)

Lido can run these checks on the public testnets. Allow about 20 minutes of governance time for a vote, plus time for L2 delivery. L-10 reads the balances after the transfers.

| ID | Check | Procedure | Expected | Evidence |
| --- | --- | --- | --- | --- |
| L-1 | Manual execution | Send a deposit. When both attestations are in the CCIP API, call `OffRamp.execute` ourselves before or instead of the executor. Requires the smoke script updated for the new policy. | Our call succeeds, or the executor was first and ours reverts as a repeat | `messageId`, our transaction, state |
| L-2 | Message in flight during a CCV list change (vote) | Send a deposit, then start a switch to another policy so that it lands before the message is signed and executed | Record which inbound policy applied at execution and whether the available attestations satisfied it. F-2 covers the previous inbound list. F-3 remains open | `messageId`, vote id, final state of the message |
| L-3 | Emergency return to the previous policy (vote) | Run `ccv-switch` with the policies reversed, measure the time from decision to all three chains switched, then switch forward again | Completes; the time is recorded as the emergency response time | Timings, transactions |
| L-4 | Pause with two CCVs (vote) | Pause the destination hooks, send, wait for the executor attempt, unpause, execute manually | No execution while paused; success after unpause with the original attestations | `messageId`, the failed and the successful transaction |
| L-5 | Attestation reuse after a delay | Keep one message unexecuted for 24 hours (use L-4), then execute | Success, or an expiry rule is documented | Timestamps |
| L-6 | Burst | Send 10 deposits within one minute on one lane, 10 on the other | All signed by both providers and executed; no message left behind | Ten `messageId`s per lane, delivery times |
| L-7 | Non-typical messages | Receiver differs from sender; receiver is a contract; larger amount (1 wstETH) | Delivered | `messageId`s |
| L-8 | Faster-than-finality request | Send with the fast finality option in `extraArgs`, if the source accepts it (fork test D-7) | Both providers treat it the same way: both sign early or both wait | Attestation timestamps of each provider |
| L-9 | Rate limit at the destination | Send an amount above the inbound limit | Execution fails and succeeds after the limit refills | `messageId`, transactions |
| L-10 | Accounting after the series | Compare lockbox balance per lane with the spoke supply | Equal | Values at a named block |

On 18 November, fork test D-7 recorded source-side rejection on every route for depth 1, depth 64 and the safe flag. L-8 can measure provider signing times only if the source accepts a faster-finality request. Until then, ask each provider for its finality rule.

## 2. Nethermind: questions and joint checks

| ID | Check | What we ask or do | Expected | Evidence |
| --- | --- | --- | --- | --- |
| N-1 | Negative test with a withheld signature | Nethermind stops signing for an agreed window; we send one transfer per direction | No execution during the window; messages execute after signing resumes | `messageId`s, timestamps |
| N-2 | Signing below threshold | One of the two signers is stopped | No valid attestation is published | API response, `messageId` |
| N-3 | Storage location outage | One of the two hosts is taken offline during a transfer | Delivery continues through the other host | `messageId`, which host served |
| N-4 | Both storage locations down | Both offline for an agreed window | Messages wait and complete after recovery; nothing is lost | `messageId`s |
| N-5 | API contract | Documentation of the storage location API, so that we can read attestations without the Chainlink API | We can fetch an attestation by `messageId` | A working request in the smoke script |
| N-6 | Source correspondence | Commit and build settings for the resolver and the verifiers | Our build of that commit matches the deployed runtime code on three chains | Code hashes |
| N-7 | Ownership | Who holds the owner key; what the owner can change (signers, threshold, fee, tag mapping); planned owner for mainnet | Written answer; for mainnet a multisig or timelock with a delay | Their answer |
| N-8 | Signer independence | Where the two signers run, who operates them, how keys are stored | Two signers do not share a host, a key store or an operator account | Their answer |
| N-9 | Finality policy | Which finality the committee waits for on each chain, and how reorganisations are handled | Written rule per chain | Their answer |
| N-10 | Fee policy | Rate, minimum and maximum on mainnet, who can change them, notice period. On the testnets: 5 bps of the value, $0.10 to $10.00 | Written rule | Their answer |
| N-11 | Mock sequencer feed on Mantle Sepolia | What the feed affects and what replaces it on mainnet | Written answer | Their answer |
| N-12 | The Mantle Sepolia ↔ Base Sepolia lane they deployed | Whether anything relies on it | Not used by wstETH; no action needed from Lido | Their answer |
| N-13 | Change notification | How Lido learns about signer rotation, upgrades and incidents | A named channel and a notice period | Their answer |

## 3. Chainlink: questions

| ID | Check | What we ask | Expected |
| --- | --- | --- | --- |
| C-1 | Onboarding record | Confirmation that the Nethermind resolver and both storage locations are registered for the three testnets | Written confirmation |
| C-2 | Executor behaviour | When the executor gives up on a message that lacks one attestation, and whether it retries later | Written rule; determines when manual execution is needed |
| C-3 | Executor and a paused pool | What the executor does when execution reverts | Retries or marks the message for manual execution |
| C-4 | Message status | Meaning of `SENT`, `VERIFYING`, `SUCCESS` and the failure statuses in the CCIP API | Used for monitoring thresholds |
| C-5 | Mainnet process | Steps and lead time to register a third-party CCV on mainnet | Input for the mainnet plan |

## 4. Monitoring to set up before relying on the setup

| ID | Signal | Threshold |
| --- | --- | --- |
| M-1 | A message without both attestations | Older than 40 minutes |
| M-2 | A message with both attestations but not executed | Older than 10 minutes after the second attestation |
| M-3 | Change in the Nethermind resolver or verifier: owner, signers, threshold, implementation, fee | Any |
| M-4 | Change in the hooks CCV lists | Any change not made by a known vote |
| M-5 | Fee quote per route for a reference amount | Above the route bound once Lido chooses it for fork test C-3 |
| M-6 | Lockbox balance against spoke supply | Any difference |

Group B can monitor resolver and committee configuration. Fee and sender-allowlist changes need separate checks.

## 5. Decisions needed from Lido before mainnet

These are not tests; the checks above feed them.

- Acceptable owner arrangement for the Nethermind contracts (N-7). Fork test F-9 shows what a single owner key can do.
- Fee bound (N-10, fork test C-3).
- Emergency procedure when Nethermind stops signing: who decides, which vote, how long it takes (L-3), what happens
  to messages in flight (L-2).
- Whether large transfers need an additional CCV through the threshold lists, which were empty on the three testnets on 18 November 2026.

## 6. Findings of the fork tests that change this plan

Numbers refer to the findings table in [NETHERMIND-CCV-FORK-TEST-PLAN.md](NETHERMIND-CCV-FORK-TEST-PLAN.md).

| Finding | Effect on this plan |
| --- | --- |
| 1, 2, 3: one plain key owns the Nethermind contracts and can alone satisfy the Nethermind side, stop or censor sending, and invalidate published attestations | N-7 becomes the first question to Nethermind and a blocker for mainnet. Ask in addition: who holds the key today, and whether the sender allowlist is ever meant to be used. M-3 must also watch the allowlist state, the fee configuration and the outbound mapping |
| 4: committee is 2 of 2 with the same signers for every source chain | N-2 is expected to show a full stop, not a degraded mode. Ask Nethermind for the mainnet committee size and threshold |
| 5: the previous policy is Chainlink alone, and anyone can complete a pending message under it | L-3 must not use the previous policy as the emergency target on mainnet. Decide the target list first (section 5) |
| 6: the Nethermind fee is 5 bps of the value, bounded at $0.10 and $10.00. At 1 wstETH it represented 42% to 81% of the quoted fee across the four routes | Replaces the numbers in N-10. The question to Nethermind is the mainnet rate, minimum and maximum, and who may change them |
| 7: a failing price source lowers the Nethermind fee to the minimum | Include in N-11: what the price source is on mainnet |
| 8: a rejected `execute` records FAILURE and the message stays deliverable | M-1 and M-2 must use the execution state together with the attestations; FAILURE alone is not an alert. C-2 and C-3 should confirm the executor retries after a FAILURE caused by someone else |
| 10: the four recorded proofs remained usable after 30 days on the forks | For L-5, check whether storage still serves both attestations after 24 hours and whether the message delivers with them |

Not answered by the fork tests and still needed from Nethermind: whether the committee signs a message whose
source receipts do not include the Nethermind resolver (a message sent under another policy).

## Suggested order

1. L-1 and L-6, L-7: no votes, one session.
2. Send the questions N-5 to N-13 and C-1 to C-5 now; answers take time.
3. N-1: the most valuable joint test, schedule it with Nethermind.
4. L-4 and L-5 together, then L-2 and L-3. Include the votes needed to unpause and to restore the forward policy.
5. N-2 to N-4, L-8, L-9.
6. Monitoring M-1 to M-6.

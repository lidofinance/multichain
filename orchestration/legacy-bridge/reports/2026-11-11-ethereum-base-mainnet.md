# Legacy bridge transfers in flight, Ethereum ↔ Base mainnet, 2026-11-11

Output of `just legacy-inflight --l1-rpc "$RPC_ETHEREUM_REMOTE" --l2-rpc "$RPC_BASE_REMOTE"`, run at 2026-11-11 12:16:31Z against live Ethereum and Base mainnet endpoints. Script: `orchestration/legacy-bridge/inflight.py`, SHA-256 `23ec1894810390667d6a8451471097789e26e8a34d946f3eccaa40fcd2c11cbb`. Statuses are defined in the [README](../README.md#statuses).

No deposit is in flight. 28 withdrawals are in flight, 389.785863645693893969 wstETH in total. Any account can finalize each of them: a run on a local fork of Ethereum carried all 28 through prove, the waiting time and finalize, and every recipient received its amount ([details and time estimates](#whether-and-when-all-28-can-be-finalized)).

- 3 withdrawals, 389.317502896855470899 wstETH, were sent 3 to 5 days before the run and proven by their recipients. They wait for their dispute games and become finalizable a few minutes after 2026-11-11 14:20:11Z, 2026-11-11 22:10:23Z and 2026-11-13 04:30:59Z.
- 25 withdrawals, 0.468360748838423070 wstETH, were sent between 2023-10-04 and 2026-08-29 and not completed: 19 were never proven, and 6 have a proof that can no longer pass the portal check. Any account can prove them today. They become finalizable 1 day after a proof against a dispute game that is already resolved, or about 5 days after a proof against the newest game.

The counts, amounts and statuses hold at the two blocks in [Reads](#reads). The two sections after the list of withdrawals add contract reads and the fork run, made between 12:43Z and 13:50Z the same day; each states its own time. Nothing was sent on Ethereum or Base mainnet for this report.

## Reads

|                                 | Ethereum                                     | Base                                         |
| ------------------------------- | -------------------------------------------- | -------------------------------------------- |
| Chain ID                        | 1                                            | 8453                                         |
| Block                           | 26391621                                     | 56045057                                     |
| Block time                      | 2026-11-11 12:16:23Z                         | 2026-11-11 12:16:27Z                         |
| Final through                   | 26391541                                     | 56040194                                     |
| Bridge proxy                    | `0x9de443AdC5A411E83F1878Ef24C3F52C61571e72` | `0xac9D11cD4D7eF6e54F14643a393F68Ca014287AB` |
| Bridge implementation           | pre-migration implementation                 | pre-migration implementation                 |
| Deposits / withdrawals switches | enabled / enabled                            | enabled / enabled                            |
| Messenger                       | `0x866E82a600A1414e583f7F13623F1aC5d58b0Afa` | `0x4200000000000000000000000000000000000007` |
| wstETH                          | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` | `0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452` |

OptimismPortal `0x49048044D57e1C92A77f79988d21Fa8fAF74E97e`, version 6.0.1: not paused, proof maturity 86400 s. Newest dispute game of the respected type 621: `0xeed92bccCdb3967f8D08342c0B0364244a92Da1F`, claims Base block 56034360.

## Result

| Direction | Messages from the bridge | Source blocks | Delivered | In flight | wstETH in flight |
| --- | --- | --- | --- | --- | --- |
| Deposits Ethereum → Base | 3577 | 18236815..26391621 | 3577 | 0 | 0 |
| Withdrawals Base → Ethereum | 990 | 4572995..56045057 | 962 | 28 | 389.785863645693893969 |

At these blocks a relay would not be rejected: deposits are enabled on the Base bridge, withdrawals are enabled on the Ethereum bridge, and the portal is not paused.

| Status of withdrawals in flight | Count | wstETH |
| --- | --- | --- |
| `PROOF_INVALIDATED` | 6 | 0.133157972705915231 |
| `PROVEN_WAITING` | 3 | 389.317502896855470899 |
| `READY_TO_PROVE` | 19 | 0.335202776132507839 |

## Backing

| | wstETH |
| --- | --- |
| Held by the Ethereum bridge | 24632.649365938439766693 |
| Supply on Base | 24242.863501792745872724 |
| Transfers in flight | 389.785863645693893969 |
| Held − supply − in flight | 0.0000005 |

No lockbox is counted: the Ethereum bridge runs the pre-migration implementation, which has none. This run does not establish where the remaining 0.0000005 wstETH (500000000000 wei) comes from.

## Withdrawals in flight

| #   | Status              | wstETH               | Sent (UTC)           | Recipient on Ethereum                        | Base transaction                                                     |
| --- | ------------------- | -------------------- | -------------------- | -------------------------------------------- | -------------------------------------------------------------------- |
| 1   | `PROOF_INVALIDATED` | 0.122737962705915231 | 2024-11-01 09:20:37Z | `0x99Cac20b77F4877108E78538C68CD08393a33362` | `0x9d29d7d012ef612dd6cf6733bad57f307db4f0ab0ff600f02230568494e18498` |
| 2   | `PROOF_INVALIDATED` | 0.00012              | 2025-04-11 13:13:29Z | `0xCF7bF9D3a485b9c4d4A38d65e4d68e081a585662` | `0x9311d5620b0dff33d8ec272ee0392b788d4527f65ba193f970e327d4005d2687` |
| 3   | `PROOF_INVALIDATED` | 0.0001               | 2025-09-20 21:09:07Z | `0xFCc1C98F887C93C38Deb5e38A6Fb820AD3fB9DFD` | `0xa3a72a85f942edaf4a32ff765ee53ccb3e44e8b9ea5c0dea690d1d57369da1e5` |
| 4   | `PROOF_INVALIDATED` | 0.00000001           | 2025-11-06 18:07:03Z | `0x0Cc93B25F86549E5a938bFA6894df755DA52b390` | `0xe14a5d0e914270722c5b32d1ee5a0ba86b665298efcf9aede69c541023bbb229` |
| 5   | `PROOF_INVALIDATED` | 0.0002               | 2026-01-07 03:01:45Z | `0xED9F06e92F908483CF457ECb09af84Dbdc9ed5d0` | `0xd44a714edc846a63524aa0d685005cc3cd877b806b7cfbcef8dba4d55fdb1905` |
| 6   | `PROOF_INVALIDATED` | 0.01                 | 2026-03-28 02:38:03Z | `0x74870e3778C7Fd03459a4CB61Eec1ca9452c4ce2` | `0x4b766ea47938121c36fb084c707f9b4787af4c12e128f843afdb982b15826947` |
| 7   | `PROVEN_WAITING`    | 380                  | 2026-11-06 13:34:26Z | `0x2E788f6f42F8bf850CfE325A39305FAcD52c0Bcc` | `0x55299f74e115590ed0203c7c07526fe46b7aaf40145ad7e772216d7fa4ec702b` |
| 8   | `PROVEN_WAITING`    | 0.800933180757016961 | 2026-11-06 21:31:56Z | `0x352D68686d21237582566c6b95DD7edbF04314dA` | `0x3dd40f8d35a9271df4b6892d8513c1f9172f267b5d94ac7fd786c2597e602ba7` |
| 9   | `PROVEN_WAITING`    | 8.516569716098453938 | 2026-11-08 03:58:04Z | `0x55E662dba0F9346Af15DB83bAa3382B8167877D6` | `0x4cb8548d0b517daaa488642d7eb72155ff62ab88ecb4d6e1b00e137df1ee91c8` |
| 10  | `READY_TO_PROVE`    | 0.0001               | 2023-10-04 16:06:51Z | `0xad79579eEceF31f4719426232D7b527B17b84f85` | `0x5da27a22e39115f053f5cf95448d5d835a14e60b6731206007ed5858a3a66ad0` |
| 11  | `READY_TO_PROVE`    | 0.00000995           | 2023-11-04 09:45:17Z | `0xa7F6c2cfCCA657967F4b4249c1c3fA75A59338F6` | `0x84cd442c632047050f3bace0ca85480bd04fa25426dbb39615fdcf0ace53c4f1` |
| 12  | `READY_TO_PROVE`    | 0.00398              | 2023-11-04 19:26:57Z | `0x3d3be777790ba9F279A188C3F249f0B6F94880Cd` | `0x767d6fa7b098656b62f77a2980e1a8691215851d84e9c84549119aa612d6de5c` |
| 13  | `READY_TO_PROVE`    | 0                    | 2023-11-08 12:21:03Z | `0x913f440Ed5ec7CCbbAB7E72ae3803bDfEa95606A` | `0x91816a6819f6551a2e98d1795e8bd4c0ab0ccbfc5bf7f43beaf7f27ce4636c6f` |
| 14  | `READY_TO_PROVE`    | 0.2905               | 2023-12-29 02:03:03Z | `0x7BD06443251582A2533265d1937daEb9ce96480A` | `0x14c2c1ea7085507efab2cd49419e48b96e5aa41ee44fdc258808cae3ad38e68a` |
| 15  | `READY_TO_PROVE`    | 0.00001              | 2024-02-08 20:04:47Z | `0x24a7F1d5433972e66A4cE10cA591dC3643a0fbe0` | `0xcfce67e2659a2a1aaeda78d833ad0f55b10a21aa4a00930c2a51abc2786c2163` |
| 16  | `READY_TO_PROVE`    | 0.00001              | 2024-02-13 07:35:43Z | `0xD65DeB57d16EEae3Be1ab28A0771671E700cA38c` | `0x2391b91e4c6ad7000efdf19ee9ebfd35ebf333eb2d8ed6ac57462b29cf3b43a9` |
| 17  | `READY_TO_PROVE`    | 0.0001               | 2024-07-22 18:42:47Z | `0x5780342a292680Aa99ccbd8e1b5a4296Db650C45` | `0xb51aec259560423ba4e195f2904cf4b26d9438d6252410b622f211fa563f3d52` |
| 18  | `READY_TO_PROVE`    | 0.0001               | 2024-10-04 15:03:39Z | `0x0463E60C7cE10e57911AB7bD1667eaa21de3e79b` | `0xa7e20d0483542c0a4928a8f6be767a73a827594bbd454d20b5b89400f49f69b5` |
| 19  | `READY_TO_PROVE`    | 0.0008378324098762   | 2025-02-19 21:02:49Z | `0xAd0f3f4BEC42CdA68d2cd31301B3C3De3B0F50E2` | `0xd90b9f157af70a75276bdc86a23aad64245baddef45ee0cd1cff44e811a09fcc` |
| 20  | `READY_TO_PROVE`    | 0.000074103493543789 | 2025-04-21 16:17:23Z | `0x0Cc93B25F86549E5a938bFA6894df755DA52b390` | `0x5a38a91627fac8153695a21ba430758c3c8b08e01c884472ce72ca587a5c350a` |
| 21  | `READY_TO_PROVE`    | 0.001                | 2025-09-04 20:20:55Z | `0xf8553c8552f906C19286F21711721E206EE4909E` | `0x57004e8400827aa6091a57b698d05b9ba6eea2ed99ddd095a52b9c26bb0afdd7` |
| 22  | `READY_TO_PROVE`    | 0.01199              | 2025-09-10 09:10:21Z | `0xD61054f4456D0555dc2dd82B77F7aD6074836149` | `0xfc314b22d19b5ebba2cff66d442a40d27e6976baf107e47559603efda632c32b` |
| 23  | `READY_TO_PROVE`    | 0.01                 | 2026-05-26 00:39:51Z | `0x74870e3778C7Fd03459a4CB61Eec1ca9452c4ce2` | `0xa80b6c402654a5259b9ba8153ffe0c5778367ef428fb82f42d46344fa311d3c8` |
| 24  | `READY_TO_PROVE`    | 0.01                 | 2026-05-28 03:41:15Z | `0x74870e3778C7Fd03459a4CB61Eec1ca9452c4ce2` | `0xd4132e99826bb721eef37799d3b24bc33a863c357535c0e892c9b3501d6a8d00` |
| 25  | `READY_TO_PROVE`    | 0.004881251433191199 | 2026-05-29 03:09:35Z | `0x0BBdfcC61aCe1A1f08222a6FEe0f7e628C09377B` | `0x93de416bfb1483b1e698d1b5cecd4c18a380f804d62641b285ec8180a9f884a8` |
| 26  | `READY_TO_PROVE`    | 0.00000000000001     | 2026-06-09 01:55:57Z | `0x172B70DA382460f1dBd3EceE4C9E4073E4AAe2F9` | `0x55d40405c65079fb793ec7dbf497e2ddf79bf04cd15b4801c882c5dfa3c56736` |
| 27  | `READY_TO_PROVE`    | 0.0000000017021      | 2026-06-30 12:48:51Z | `0x1546B970afC85bb7448B2c50504be0C4640408dd` | `0xcb1ee6f193a9f3f57f5e93c8ca12a7b663df210344fbe6ba25cc4d488b6886cf` |
| 28  | `READY_TO_PROVE`    | 0.001609637093786651 | 2026-08-29 06:39:29Z | `0x1d8c4d80464270AFB50576CAB66F08a29903747F` | `0xa676c759e570af18ef1e73f183c02459bee77d953f24fb450cbc9014814731c7` |

## Whether and when all 28 can be finalized

All 28 can be finalized and delivered, and any account can send the calls. A local fork of Ethereum mainnet, taken at block 26392070 (2026-11-11 13:46:11Z), carried each withdrawal through prove, the waiting time and finalize. Every recipient received exactly its amount, and the bridge balance fell by 389.785863645693893969 wstETH, the sum in flight. The terms used here are explained in [How each status completes](#how-each-status-completes).

### Time estimates

| Withdrawals | Waits for | Earliest finalize |
| --- | --- | --- |
| 380 wstETH, already proven | its game, expected resolution 2026-11-11 14:20:11Z | 2026-11-11, about 14:21Z to 14:27Z |
| 0.800933180757016961 wstETH, already proven | its game, expected resolution 2026-11-11 22:10:23Z | 2026-11-11, about 22:11Z to 22:17Z |
| 8.516569716098453938 wstETH, already proven | its game, expected resolution 2026-11-13 04:30:59Z | 2026-11-13, about 04:32Z to 04:38Z |
| 25 withdrawals, 0.468360748838423070 wstETH, proven against a game already resolved for the defender | the proof maturity delay of 86400 s | 1 day and 1 s after each prove transaction |
| the same 25, proven against the newest game instead | that game, expected to resolve 5 days after its creation | about 5 days after the prove transaction |

If the 25 proofs are sent against a resolved game before 2026-11-12 04:30Z, all 28 can be delivered by about 2026-11-13 04:40Z. Proofs sent later move that time to 1 day after the last proof.

The estimates rest on these observations and conditions:

- **Resolution lag.** Ten games observed on 2026-11-11 were resolved for the defender 1 to 7 minutes after their expected resolution, by accounts other than ours. The estimates add that lag. If nobody resolves a game, any account can, after resolving its parent games in order.
- **Game cadence.** Games are created about 20 minutes apart: 360 games in 431880 s between indexes 25855 and 26215. The newest game is therefore at most about 20 minutes old when a proof is sent against it.
- **What moves the times later.** A pause of the portal or the registry stops prove and finalize until the unpause. A game that is blacklisted, retired or resolved for the challenger requires a new proof. A nullified proof moves a game's expected resolution to 5 days after the nullification.
- **Work.** 25 prove and 28 finalize transactions on Ethereum, 53 in total, or 50 if the three recipients finalize their own withdrawals. On the fork a prove used 366056 to 426126 gas (10184168 for the 25) and a finalize 246929 to 270722 gas (7271417 for the 28). Gas prices were not estimated.

### What was run

Reads on the live chains and the fork run were made on 2026-11-11 between 13:36Z and 13:50Z.

1. **The script again**, at 13:36:49Z (Ethereum block 26392022, Base block 56069145): the same 28 withdrawals with the same statuses, and no blocker for a relay.
2. **A game for the proofs.** Index 25855, `0xcdBc9345674e6b5350f8B26a01AD89Bd0bfa1f8D`, was the newest resolved game at Ethereum block 26392052. It was created at 2026-11-06 13:35:35Z and resolved for the defender at 2026-11-11 13:39:59Z, 4 min 24 s after its expected resolution. It claims Base block 53898360 (2026-11-06 13:00:47Z). `AnchorStateRegistry.isGameProper`, `isGameRespected` and `isGameClaimValid` return true for it.
3. **Proof inputs from Base at block 53898360.** The output root `keccak256(abi.encode(0, stateRoot, messagePasserStorageRoot, blockHash))` computed from that block equals the game's `rootClaim()`. `eth_getProof` returned the storage proof of slot `keccak256(abi.encode(withdrawalHash, 0))` in `L2ToL1MessagePasser(0x4200000000000000000000000000000000000016)` for each withdrawal. The slot holds 1 for the 25 withdrawals without a live proof. It holds 0 for the three already proven ones, which were sent after that block and can be proven only against a game that claims their block or a later one. At the Base head, `sentMessages(withdrawalHash)` is true for all 28.
4. **The 25 on the fork.** A fresh account, `0x00000000000000000000000000000000000A11cE`, sent `proveWithdrawalTransaction(tx, 25855, outputRootProof, withdrawalProof)` for each: 25 of 25 succeeded. Right after the proofs `checkWithdrawal` reverted with `OptimismPortal_ProofNotOldEnough`. After the fork time advanced by 86401 s, the same account sent `finalizeWithdrawalTransactionExternalProof(tx, 0x00000000000000000000000000000000000A11cE)`: 25 of 25 succeeded. The 25 include the six with a retired proof and the withdrawal of 0 wstETH.
5. **The 3 already proven, on the fork.** The fork time was moved to 2026-11-13 04:32:00Z, 61 s after the latest expected resolution. The fresh account called `resolve()` on the games at indexes 25856 to 25972 in order: 117 of 117 succeeded, and the three games of these withdrawals were resolved for the defender. The fresh account then sent `finalizeWithdrawalTransactionExternalProof(tx, <proven by>)` with the account of the original proof: 3 of 3 succeeded.
6. **Result checked for each of the 28:** `OptimismPortal.finalizedWithdrawals(withdrawalHash)` is true, `L1CrossDomainMessenger.successfulMessages(messageHash)` is true, `failedMessages(messageHash)` is false, and the recipient's wstETH balance grew by the amount of the withdrawal.

The fork run shows that the calls succeed against the mainnet state of block 26392070 once the waiting time has passed. It moved the time by hand, so it does not show how long mainnet will take: a challenge, a nullified proof, a pause or a retirement after that block changes the outcome as described above. The proofs were built with `cast block` and `cast proof`; `inflight.py` does not build them.

## How each status completes

All 28 withdrawals are on one path and differ in how far along it they are:

```text
READY_TO_PROVE ── prove ──▶ PROVEN_WAITING ── game resolved for the defender, proof older than 1 day ──▶ READY_TO_FINALIZE ── finalize ──▶ delivered

PROVEN_WAITING ── game resolved for the challenger, blacklisted or retired ──▶ PROOF_INVALIDATED ── prove again ──▶ PROVEN_WAITING
READY_TO_FINALIZE ── finalize, the bridge rejects the call ──▶ RELAY_FAILED ── relayMessage ──▶ delivered
```

Each of the 28 can still be delivered. Its wstETH was burned on Base when it was sent, and the Ethereum bridge still holds the same amount. Any account can send the prove, resolve, finalize and relay calls below; the wstETH goes to the recipient named in the withdrawal message, whichever account sends the call.

### Contract rules for prove, resolve and finalize

The rules were read on 2026-11-11 between 12:43Z and 12:49Z, after the block of the run above, from these contracts at the Ethereum head and from their verified source on Sourcify:

| Contract | Proxy | Implementation |
| --- | --- | --- |
| OptimismPortal 6.0.1 | `0x49048044D57e1C92A77f79988d21Fa8fAF74E97e` | `0x03863Ab7F64B733cFF85C8fF44a86601C568Ca70` |
| AnchorStateRegistry | `0x909f6cf47ed12f010A796527f562bFc26C7F4E72` | `0x4483F964F6711Cb55f633820ED174E780369b99D` |
| DisputeGameFactory | `0x43edB88C4B80fDD2AdFF2412A7BebF9dF42cB40e` | not read |
| Dispute game type 621, `AggregateVerifier` 0.3.0 | one clone per game | `0xc08b8fFAF04Abb1d7013B74a0E57Eccbd7fa5A70` |

- **Prove.** `OptimismPortal.proveWithdrawalTransaction` accepts a dispute game that meets five conditions: it is registered in the factory; it is not blacklisted; it was created after `AnchorStateRegistry.retirementTimestamp()` (2026-05-26 19:59:59Z); its type was the respected type when it was created; it is not resolved for the challenger. A game in progress and a game resolved for the defender both qualify. The portal stores the proof under the pair (withdrawal hash, account that sent the proof). When the same account proves again, the new proof replaces its record and the maturity delay starts again. A proof from another account is stored separately, and the first proof stays as it was.
- **Finalize.** The portal accepts `finalizeWithdrawalTransactionExternalProof(tx, proofSubmitter)` once `OptimismPortal.checkWithdrawal(withdrawalHash, proofSubmitter)` passes. The check requires that the proof is older than `proofMaturityDelaySeconds()` (86400 s) and that `AnchorStateRegistry.isGameClaimValid(game)` is true: the game still meets the first four prove conditions, it is resolved for the defender, and `disputeGameFinalityDelaySeconds()` has passed since `resolvedAt`. That delay is 0, so the block after the resolution is enough.
- **Game resolution.** Any account can call `AggregateVerifier.resolve()`. The call resolves the game once its parent game is resolved and `expectedResolution()` has passed. A game that holds one proof has its expected resolution 5 days after that proof. When it receives its second proof (one TEE, one ZK), the expected resolution moves to 1 day after the second proof if that is earlier. A game resolves for the challenger when its parent game did, or after a successful ZK challenge. A nullified proof moves the expected resolution later: to 5 days after the game records the nullification while one proof remains, and indefinitely while none remains. Nine games sampled with expected resolutions between 07:28Z and 11:12Z on 2026-11-11 were all resolved for the defender 1 to 7 minutes after that time.
- **After finalize.** The portal marks the withdrawal finalized whether or not its inner call succeeds. The inner call is `L1CrossDomainMessenger.relayMessage`, which calls `finalizeERC20Withdrawal` on the bridge. When the bridge reverts, the messenger records the message in `failedMessages`, and any account can relay it again later.

Two of these rules were read from the verified source and then exercised in the [fork run](#what-was-run): the portal accepted 25 proofs against a game already resolved for the defender, and an account unrelated to the games resolved 117 of them. No transaction was sent on mainnet for this report.

### `READY_TO_PROVE`: 19 withdrawals, 0.335202776132507839 wstETH

These withdrawals were sent on Base between 2023-10-04 and 2026-08-29 and never proven on Ethereum. The largest is 0.2905 wstETH; one carries 0 wstETH. The newest dispute game of the respected type claims a Base block later than every one of them.

Next step, any account, Ethereum:

- `OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)`

`--json` gives the withdrawal tuple `tx`. The caller chooses the game (`disputeGameIndex`) and builds the other two arguments at the Base block that game claims: the output root proof, and the storage proof of slot `keccak256(abi.encode(withdrawalHash, 0))` in `L2ToL1MessagePasser(0x4200000000000000000000000000000000000016)`.

The withdrawal then becomes `PROVEN_WAITING` and stays there until the chosen game is resolved for the defender, and for at least 1 day:

- A game already resolved for the defender that claims the withdrawal's Base block or a later one: 1 day, the proof maturity delay. A game with one proof resolves 5 days after its creation, so the Base block it claims is at least 5 days old, and the Base endpoint must serve archive state for the storage proof. The endpoint used for this report served these proofs at Base block 53898360, the block of game index 25855.
- The newest game: 5 days until its expected resolution, or less if it receives a second proof.

### `PROVEN_WAITING`: 3 withdrawals, 389.317502896855470899 wstETH

Each of the three has a proof against a game that meets the prove conditions and is still in progress. The 1-day maturity delay has passed for all three, so they wait only for their games. Each was sent 3 to 5 days before the run and proven by its own recipient within 5 hours of being sent.

| wstETH | Proven by | Proven at | Dispute game | Expected resolution |
| --- | --- | --- | --- | --- |
| 380 | `0x2E788f6f42F8bf850CfE325A39305FAcD52c0Bcc` | 2026-11-06 17:57:23Z | `0xab6d6e9D5AE9b7C925ff8C6Be89836602D291608` | 2026-11-11 14:20:11Z |
| 0.800933180757016961 | `0x352D68686d21237582566c6b95DD7edbF04314dA` | 2026-11-06 22:48:11Z | `0xE6E32BC9de08d543753CdB4BE129EBAD900Eea7E` | 2026-11-11 22:10:23Z |
| 8.516569716098453938 | `0x55E662dba0F9346Af15DB83bAa3382B8167877D6` | 2026-11-08 04:50:59Z | `0xf09A708f881f264b65b57B33c84D481b206F37c5` | 2026-11-13 04:30:59Z |

Each game holds one proof, so its expected resolution is 5 days after its creation. Next steps, Ethereum:

1. Any account, after the expected resolution, unless the game is already resolved:
   - `AggregateVerifier(<dispute game>).resolve()`

   Games resolve in order: the call reverts until the parent game is resolved.
2. Any account, once the game is resolved for the defender and the withdrawal is `READY_TO_FINALIZE`:
   - `OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).finalizeWithdrawalTransactionExternalProof(tx, <proven by>)`

   The account in the "Proven by" column can call `finalizeWithdrawalTransaction(tx)` instead; the portal then checks the caller's own proof.

The portal then calls `L1CrossDomainMessenger(0x866E82a600A1414e583f7F13623F1aC5d58b0Afa).relayMessage`, which calls `finalizeERC20Withdrawal` on the bridge `0x9de443AdC5A411E83F1878Ef24C3F52C61571e72`, and the bridge sends the wstETH to the recipient.

If the game is instead resolved for the challenger or blacklisted, or the Guardian moves the retirement timestamp past the game's creation time, the withdrawal becomes `PROOF_INVALIDATED`.

A second account can prove the same withdrawal against another game without waiting for the first game. The withdrawal is then finalized with whichever proof passes `checkWithdrawal` first.

### `PROOF_INVALIDATED`: 6 withdrawals, 0.133157972705915231 wstETH

Each of the six has a proof that will never pass `checkWithdrawal`. The proofs were sent between 2024-11-01 and 2026-04-20, and none of the six withdrawals was finalized. Their games were resolved for the defender, but the games were created before the retirement timestamp of 2026-05-26 19:59:59Z. The registry therefore reports the games retired, and `checkWithdrawal` reverts with `OptimismPortal_InvalidRootClaim`. The Guardian can only move the retirement timestamp forward, to the time of its call, so these proofs stay rejected.

Next step, any account, Ethereum, against a game created after the retirement timestamp:

- `OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)`

From there the withdrawal follows the `PROVEN_WAITING` steps. Finalize names the account that sent the new proof, so the portal checks only that proof; the old proof stays in the portal under the account that sent it.

### Recovery

Events that can stop a withdrawal on this path, and how it continues:

| What happens | Effect | Recovery |
| --- | --- | --- |
| The game of a proof is resolved for the challenger, blacklisted or retired | `PROOF_INVALIDATED` | prove again against a game that meets the prove conditions |
| The portal or the registry is paused | prove and finalize revert; proofs already stored stay in the portal | after the unpause, continue from the same status |
| Finalize is sent with too little gas | the whole transaction reverts; the withdrawal stays `READY_TO_FINALIZE` | send finalize again with more gas |
| The bridge rejects `finalizeERC20Withdrawal`: withdrawals are disabled on the Ethereum bridge, or the bridge is in `CCIP_ONLY` | the portal has finalized, and the messenger holds the message in `failedMessages`: `RELAY_FAILED` | once the bridge accepts withdrawals again, any account: `L1CrossDomainMessenger(0x866E82a600A1414e583f7F13623F1aC5d58b0Afa).relayMessage(…)`, calldata in `--json` |
| The portal finalized, and the messenger recorded neither success nor failure | `FINALIZED_NOT_RELAYED` | the messenger cannot replay it; investigate the finalize transaction |

### In the Base migration

Cases from the [upgrade path](../../../targets/wsteth-base-migration-mainnet/docs/2026-10-26-upgrade-path.md) (steps 6 and 7, rollback C):

- **Before `close()`.** The steps above work unchanged in the `LEGACY` and `MIGRATING` modes. In `MIGRATING` the bridge pays the withdrawal from the lockbox.
- **The sweep is not finished by `T_close_L1L2`.** The Emergency Brakes block `close()`. They also pause CCIP deposits and withdrawals until a vote re-enables them:
  - `disableDeposits()` on the Ethereum bridge
  - `disableWithdrawals()` on the Base bridge
- **A withdrawal is still in flight after `close()`.** The portal still accepts its prove and finalize, but `finalizeERC20Withdrawal` reverts in `CCIP_ONLY`. The withdrawal stops at `RELAY_FAILED`, and the wstETH that backs it stays in the lockbox. Rollback C delivers it:
  1. DAO vote, Aragon Agent: `L1MigrationBridge.switchBridgeMode(MIGRATING)`
  2. Any account: `L1CrossDomainMessenger.relayMessage(…)`
  3. DAO vote, Aragon Agent: `L1MigrationBridge.switchBridgeMode(CCIP_ONLY)`

The 25 withdrawals in `READY_TO_PROVE` and `PROOF_INVALIDATED` (0.468360748838423070 wstETH) can be proven today, ahead of step 6, and finalized 1 to 5 days after their proofs. While any of them is in flight, the step 6 check fails: the list of withdrawals is not empty, and `just legacy-inflight --expect-empty` exits 2. One that is still in flight after `close()` needs rollback C to be paid out.

## Full output

```text
Legacy wstETH bridge transfers in flight: ethereum ↔ base

  ethereum: chain 1, block 26391621 at 2026-11-11 12:16:23Z (final through 26391541)
    bridge 0x9de443AdC5A411E83F1878Ef24C3F52C61571e72: mode pre-migration implementation, deposits enabled, withdrawals enabled
    messenger 0x866E82a600A1414e583f7F13623F1aC5d58b0Afa
  base: chain 8453, block 56045057 at 2026-11-11 12:16:27Z (final through 56040194)
    bridge 0xac9D11cD4D7eF6e54F14643a393F68Ca014287AB: mode pre-migration implementation, deposits enabled, withdrawals enabled
    messenger 0x4200000000000000000000000000000000000007
  OptimismPortal 0x49048044D57e1C92A77f79988d21Fa8fAF74E97e 6.0.1: not paused, proof maturity 1d 0h
    newest dispute game of the respected type 621: 0xeed92bccCdb3967f8D08342c0B0364244a92Da1F, claims base block 56034360

Deposits ethereum → base
  ────────────────────────
  messages from the bridge: 3577 in ethereum blocks 18236815..26391621; delivered: 3577
  in flight: none

Withdrawals base → ethereum
  ───────────────────────────
  messages from the bridge: 990 in base blocks 4572995..56045057; delivered: 962
  in flight: 28, 389.785863645693893969 wstETH
    PROOF_INVALIDATED         6  0.133157972705915231 wstETH
    PROVEN_WAITING            3  389.317502896855470899 wstETH
    READY_TO_PROVE           19  0.335202776132507839 wstETH

  PROOF_INVALIDATED  0.122737962705915231 wstETH  sent 2024-11-01 09:20:37Z (740d 2h ago)
    from 0x99Cac20b77F4877108E78538C68CD08393a33362 to 0x99Cac20b77F4877108E78538C68CD08393a33362
    base tx 0x9d29d7d012ef612dd6cf6733bad57f307db4f0ab0ff600f02230568494e18498 (block 21831745)
    message 0x850f10f0ecd5882a4fdc246213e7f493c905edd585c77b90347903a6fbe057e9 (messenger nonce 28897)
    withdrawal 0x43a878d01a6a32e91c982c59e5f6d1981bd216592743959b25837d57f7a4739a
    proven 2024-11-01 11:02:35Z by 0x99Cac20b77F4877108E78538C68CD08393a33362
    against dispute game 0x6628e59be485f23291763338066Fb23672D40901 (DEFENDER_WINS); portal check: OptimismPortal_InvalidRootClaim
    note: this proof can no longer finalize: dispute game 0x6628e59be485f23291763338066Fb23672D40901 is retired, not registered in the dispute game factory
    next: prove again: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  PROOF_INVALIDATED  0.00012 wstETH  sent 2025-04-11 13:13:29Z (578d 23h ago)
    from 0xCF7bF9D3a485b9c4d4A38d65e4d68e081a585662 to 0xCF7bF9D3a485b9c4d4A38d65e4d68e081a585662
    base tx 0x9311d5620b0dff33d8ec272ee0392b788d4527f65ba193f970e327d4005d2687 (block 28793931)
    message 0xafd34316842ecc8496a09f4700b3a9c9c12a2fadbd7e0adbe2d55f7c7781abb8 (messenger nonce 37871)
    withdrawal 0x1c70e163d63609482f016e86128156098189b44beecaff4dd4bfe5a85f11c338
    proven 2025-06-27 17:38:35Z by 0xCF7bF9D3a485b9c4d4A38d65e4d68e081a585662
    against dispute game 0xfb2c1eaaa5eF5DECf53E6BaD19FE9720ADe2517F (DEFENDER_WINS); portal check: OptimismPortal_InvalidRootClaim
    note: this proof can no longer finalize: dispute game 0xfb2c1eaaa5eF5DECf53E6BaD19FE9720ADe2517F is retired, not registered in the dispute game factory
    next: prove again: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  PROOF_INVALIDATED  0.0001 wstETH  sent 2025-09-20 21:09:07Z (416d 15h ago)
    from 0x503d45c009F81142556919A3cd0df91E097B3f0e to 0xFCc1C98F887C93C38Deb5e38A6Fb820AD3fB9DFD
    base tx 0xa3a72a85f942edaf4a32ff765ee53ccb3e44e8b9ea5c0dea690d1d57369da1e5 (block 35806600)
    message 0xa0e47e53cf662d13f1874d0400f7065bd32f11bf0469cf7cb29d5fafc8f46530 (messenger nonce 44979)
    withdrawal 0x91033ff0a393eab36a6f2138fb385471bc747bacb60111b37721deada7c05e8c
    proven 2025-09-29 11:25:23Z by 0xCF7bF9D3a485b9c4d4A38d65e4d68e081a585662
    against dispute game 0x2CB593452330A9e6da8232BD1ca44e075D2CC16e (DEFENDER_WINS); portal check: OptimismPortal_InvalidRootClaim
    note: this proof can no longer finalize: dispute game 0x2CB593452330A9e6da8232BD1ca44e075D2CC16e is retired, not registered in the dispute game factory
    next: prove again: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  PROOF_INVALIDATED  0.00000001 wstETH  sent 2025-11-06 18:07:03Z (369d 18h ago)
    from 0x0Cc93B25F86549E5a938bFA6894df755DA52b390 to 0x0Cc93B25F86549E5a938bFA6894df755DA52b390
    base tx 0xe14a5d0e914270722c5b32d1ee5a0ba86b665298efcf9aede69c541023bbb229 (block 37831538)
    message 0xe518880b48be0d45bd3dc00132ea814dbbcd9fdaef03ac1c61a57292ae88bccc (messenger nonce 46906)
    withdrawal 0xd64dbde0ea8e07762272c3bf2f8e03c912792088e7062efe7854e62e821cca94
    proven 2026-02-20 17:35:59Z by 0x0Cc93B25F86549E5a938bFA6894df755DA52b390
    against dispute game 0xdABBe2327B66d1206120AB12A641e5AB7512746B (DEFENDER_WINS); portal check: OptimismPortal_InvalidRootClaim
    note: this proof can no longer finalize: dispute game 0xdABBe2327B66d1206120AB12A641e5AB7512746B is retired
    next: prove again: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  PROOF_INVALIDATED  0.0002 wstETH  sent 2026-01-07 03:01:45Z (308d 9h ago)
    from 0xED9F06e92F908483CF457ECb09af84Dbdc9ed5d0 to 0xED9F06e92F908483CF457ECb09af84Dbdc9ed5d0
    base tx 0xd44a714edc846a63524aa0d685005cc3cd877b806b7cfbcef8dba4d55fdb1905 (block 40482779)
    message 0x63a7db025b2a4549d637c1699dcc862b92abd7f50c4585b51fb512861eef0161 (messenger nonce 49501)
    withdrawal 0xbd07c97c191d6dbe3892b03a88d8db841383188b868591fffd63ee3da7798c9e
    proven 2026-01-26 04:20:59Z by 0xED9F06e92F908483CF457ECb09af84Dbdc9ed5d0
    against dispute game 0xf6A4B51958E5BD3c9246F48a03770fC980E8Ecff (DEFENDER_WINS); portal check: OptimismPortal_InvalidRootClaim
    note: this proof can no longer finalize: dispute game 0xf6A4B51958E5BD3c9246F48a03770fC980E8Ecff is retired
    next: prove again: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  PROOF_INVALIDATED  0.01 wstETH  sent 2026-03-28 02:38:03Z (228d 9h ago)
    from 0x74870e3778C7Fd03459a4CB61Eec1ca9452c4ce2 to 0x74870e3778C7Fd03459a4CB61Eec1ca9452c4ce2
    base tx 0x4b766ea47938121c36fb084c707f9b4787af4c12e128f843afdb982b15826947 (block 43938068)
    message 0xbe5953fa82330c6787db1e8ba6be94a3ca43dbf950e1e07ac744472b8dcdd397 (messenger nonce 53102)
    withdrawal 0xb9504c99dcea4ce82ced021c437bccc2cd4798605c5f5a22dd2b2853e8954562
    proven 2026-04-20 03:13:35Z by 0x74870e3778C7Fd03459a4CB61Eec1ca9452c4ce2
    against dispute game 0x7bf2Abb69EbbE340cDE7b31cC90e668398aD158F (DEFENDER_WINS); portal check: OptimismPortal_InvalidRootClaim
    note: this proof can no longer finalize: dispute game 0x7bf2Abb69EbbE340cDE7b31cC90e668398aD158F is retired
    next: prove again: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  PROVEN_WAITING  380 wstETH  sent 2026-11-06 13:34:26Z (4d 22h ago)
    from 0x2E788f6f42F8bf850CfE325A39305FAcD52c0Bcc to 0x2E788f6f42F8bf850CfE325A39305FAcD52c0Bcc
    base tx 0x55299f74e115590ed0203c7c07526fe46b7aaf40145ad7e772216d7fa4ec702b (block 53908453)
    message 0x40b22048684d005ddbd8196e621f4315b14e2bd7988a9280f0c3a9624b4f8c99 (messenger nonce 61896)
    withdrawal 0x974b58b483b884323ac4c7c08c06d3d81a59d6d5f4dc5f721d8b41da01f353f6
    proven 2026-11-06 17:57:23Z by 0x2E788f6f42F8bf850CfE325A39305FAcD52c0Bcc
    against dispute game 0xab6d6e9D5AE9b7C925ff8C6Be89836602D291608 (IN_PROGRESS); portal check: OptimismPortal_InvalidRootClaim
    next: once dispute game 0xab6d6e9D5AE9b7C925ff8C6Be89836602D291608 is resolved for the defender and final, anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).finalizeWithdrawalTransactionExternalProof(tx, 0x2E788f6f42F8bf850CfE325A39305FAcD52c0Bcc)

  PROVEN_WAITING  0.800933180757016961 wstETH  sent 2026-11-06 21:31:56Z (4d 14h ago)
    from 0x352D68686d21237582566c6b95DD7edbF04314dA to 0x352D68686d21237582566c6b95DD7edbF04314dA
    base tx 0x3dd40f8d35a9271df4b6892d8513c1f9172f267b5d94ac7fd786c2597e602ba7 (block 54051706)
    message 0xd540d0ab9c88eb98439ca34685a850593db7d33fd044d18d043510a0845703d1 (messenger nonce 61911)
    withdrawal 0xdcbcf8d6efc98d4a1f98cb177f7f6efee81548fd93f99b82b0ff4b57eedb6a51
    proven 2026-11-06 22:48:11Z by 0x352D68686d21237582566c6b95DD7edbF04314dA
    against dispute game 0xE6E32BC9de08d543753CdB4BE129EBAD900Eea7E (IN_PROGRESS); portal check: OptimismPortal_InvalidRootClaim
    next: once dispute game 0xE6E32BC9de08d543753CdB4BE129EBAD900Eea7E is resolved for the defender and final, anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).finalizeWithdrawalTransactionExternalProof(tx, 0x352D68686d21237582566c6b95DD7edbF04314dA)

  PROVEN_WAITING  8.516569716098453938 wstETH  sent 2026-11-08 03:58:04Z (3d 8h ago)
    from 0x55E662dba0F9346Af15DB83bAa3382B8167877D6 to 0x55E662dba0F9346Af15DB83bAa3382B8167877D6
    base tx 0x4cb8548d0b517daaa488642d7eb72155ff62ab88ecb4d6e1b00e137df1ee91c8 (block 54599546)
    message 0x51ac10fa943ec2cebe1915544de7f4d1aba34b7b983dad174f13e749a2dd9675 (messenger nonce 61954)
    withdrawal 0x8e8f1a608be636fb65c7d7ce0455e07127d411a8eb9ca3f9c870d9e5e64dab47
    proven 2026-11-08 04:50:59Z by 0x55E662dba0F9346Af15DB83bAa3382B8167877D6
    against dispute game 0xf09A708f881f264b65b57B33c84D481b206F37c5 (IN_PROGRESS); portal check: OptimismPortal_InvalidRootClaim
    next: once dispute game 0xf09A708f881f264b65b57B33c84D481b206F37c5 is resolved for the defender and final, anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).finalizeWithdrawalTransactionExternalProof(tx, 0x55E662dba0F9346Af15DB83bAa3382B8167877D6)

  READY_TO_PROVE  0.0001 wstETH  sent 2023-10-04 16:06:51Z (1133d 20h ago)
    from 0xad79579eEceF31f4719426232D7b527B17b84f85 to 0xad79579eEceF31f4719426232D7b527B17b84f85
    base tx 0x5da27a22e39115f053f5cf95448d5d835a14e60b6731206007ed5858a3a66ad0 (block 4823132)
    message 0xc3edf0cc6c6d7abe198adbd0372fe14b95f25c7cc852d03123e4487aa7dcb700 (messenger nonce 2490)
    withdrawal 0x595b5223408411241d43eb8d6624a99afca7cfe903fdacff788d6a28b37205f2
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.00000995 wstETH  sent 2023-11-04 09:45:17Z (1103d 2h ago)
    from 0xAFf88cf3ffC600bAFC528cD182bA462deF6f3df3 to 0xa7F6c2cfCCA657967F4b4249c1c3fA75A59338F6
    base tx 0x84cd442c632047050f3bace0ca85480bd04fa25426dbb39615fdcf0ace53c4f1 (block 6150885)
    message 0x93045ee1947f507985f395e806e930122cc3103a7f60ef2341fe25edd857e76b (messenger nonce 3645)
    withdrawal 0x2eeebb2daa0e27be538893a63b1bc37991352113472c2b9038bf984a80262262
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.00398 wstETH  sent 2023-11-04 19:26:57Z (1102d 16h ago)
    from 0xAFf88cf3ffC600bAFC528cD182bA462deF6f3df3 to 0x3d3be777790ba9F279A188C3F249f0B6F94880Cd
    base tx 0x767d6fa7b098656b62f77a2980e1a8691215851d84e9c84549119aa612d6de5c (block 6168335)
    message 0x9679ff3a527e9ccffd56b1626f8413575b0141dba1a32d7fccb5467f5619c981 (messenger nonce 3655)
    withdrawal 0x7f83ca564da766e1a192fa7c3485dff91a7712660055200d3e45233b34da3fc7
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0 wstETH  sent 2023-11-08 12:21:03Z (1098d 23h ago)
    from 0x913f440Ed5ec7CCbbAB7E72ae3803bDfEa95606A to 0x913f440Ed5ec7CCbbAB7E72ae3803bDfEa95606A
    base tx 0x91816a6819f6551a2e98d1795e8bd4c0ab0ccbfc5bf7f43beaf7f27ce4636c6f (block 6328358)
    message 0x432a122c4426acf57c6e084ad8b1a24cd5b004bd55e3792b43b69270baab5bd7 (messenger nonce 3789)
    withdrawal 0x7a81df4e1947dc5cd2aacf54f66812b897c553af77149d31f8901a3c5a02dfb9
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.2905 wstETH  sent 2023-12-29 02:03:03Z (1048d 10h ago)
    from 0x7BD06443251582A2533265d1937daEb9ce96480A to 0x7BD06443251582A2533265d1937daEb9ce96480A
    base tx 0x14c2c1ea7085507efab2cd49419e48b96e5aa41ee44fdc258808cae3ad38e68a (block 8513018)
    message 0x5202d9260f10137a340a049829620062da9854fa11793d5a4a0cfdfb4664beb2 (messenger nonce 5002)
    withdrawal 0x63495fd1fa8e6c75104b674830c89beccdf184ab7b85f52ecb7a1d329cdfa5a9
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.00001 wstETH  sent 2024-02-08 20:04:47Z (1006d 16h ago)
    from 0x24a7F1d5433972e66A4cE10cA591dC3643a0fbe0 to 0x24a7F1d5433972e66A4cE10cA591dC3643a0fbe0
    base tx 0xcfce67e2659a2a1aaeda78d833ad0f55b10a21aa4a00930c2a51abc2786c2163 (block 10316670)
    message 0xc452d87ec475c550cc796752820030487582aacf8cf86a4cf3e03e1b9358fd1b (messenger nonce 5929)
    withdrawal 0x306c32ec9baa026430a451b59b570281c771d1aaa719f7267e6791102f6e7497
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.00001 wstETH  sent 2024-02-13 07:35:43Z (1002d 4h ago)
    from 0xD65DeB57d16EEae3Be1ab28A0771671E700cA38c to 0xD65DeB57d16EEae3Be1ab28A0771671E700cA38c
    base tx 0x2391b91e4c6ad7000efdf19ee9ebfd35ebf333eb2d8ed6ac57462b29cf3b43a9 (block 10510198)
    message 0x751fbfc31618fed047c7705f4e0bde6d0cc0fbdd6bd362a8089b994ca156908f (messenger nonce 7197)
    withdrawal 0xb0ef5259e087d16ea67358087cc1538a532528577cf480b74c9bc0f00ede76fe
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.0001 wstETH  sent 2024-07-22 18:42:47Z (841d 17h ago)
    from 0x5780342a292680Aa99ccbd8e1b5a4296Db650C45 to 0x5780342a292680Aa99ccbd8e1b5a4296Db650C45
    base tx 0xb51aec259560423ba4e195f2904cf4b26d9438d6252410b622f211fa563f3d52 (block 17442210)
    message 0x63fbfb7d099ab46bc29c6affb7e65f7eaaf5dda2527bb8ef87c16f1cfaad8115 (messenger nonce 21308)
    withdrawal 0x21d90825b7c5a95b64350a7d9b8ef529bcba18f406f0f4335ce6248e8e7dccbc
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.0001 wstETH  sent 2024-10-04 15:03:39Z (767d 21h ago)
    from 0x0463E60C7cE10e57911AB7bD1667eaa21de3e79b to 0x0463E60C7cE10e57911AB7bD1667eaa21de3e79b
    base tx 0xa7e20d0483542c0a4928a8f6be767a73a827594bbd454d20b5b89400f49f69b5 (block 20632436)
    message 0x24be729ac054f1a7e271b6cc9166add5ea46b989a4a176604f0d21db81f18f4a (messenger nonce 27577)
    withdrawal 0x9095dd39ffe5f76daf3b2fb068617bc370479bdb1bfb6770b5601b029d51d95f
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.0008378324098762 wstETH  sent 2025-02-19 21:02:49Z (629d 15h ago)
    from 0xAd0f3f4BEC42CdA68d2cd31301B3C3De3B0F50E2 to 0xAd0f3f4BEC42CdA68d2cd31301B3C3De3B0F50E2
    base tx 0xd90b9f157af70a75276bdc86a23aad64245baddef45ee0cd1cff44e811a09fcc (block 26604811)
    message 0x77d48868687ea2ca2bff39af2859c0ba16e001fc21f3a895e5e2cda4e2b67f07 (messenger nonce 35525)
    withdrawal 0xd9c5705ce8b210e59aee3b9d534df7ae6e51d1d937109fa942ef89e2bd4ba8b3
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.000074103493543789 wstETH  sent 2025-04-21 16:17:23Z (568d 19h ago)
    from 0x0Cc93B25F86549E5a938bFA6894df755DA52b390 to 0x0Cc93B25F86549E5a938bFA6894df755DA52b390
    base tx 0x5a38a91627fac8153695a21ba430758c3c8b08e01c884472ce72ca587a5c350a (block 29231448)
    message 0x435e47c6cb5c4668a3f9c45d294358107f11e973d31e388fe1a1725a64fee115 (messenger nonce 38343)
    withdrawal 0x3c50243e2e8f91d7bb041edef7ba018f7eac17e11d68db994807e5bbf353a6ff
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.001 wstETH  sent 2025-09-04 20:20:55Z (432d 15h ago)
    from 0xf8553c8552f906C19286F21711721E206EE4909E to 0xf8553c8552f906C19286F21711721E206EE4909E
    base tx 0x57004e8400827aa6091a57b698d05b9ba6eea2ed99ddd095a52b9c26bb0afdd7 (block 35113954)
    message 0xae995e089a0df647f8e7b095a10a652b3abfcd4cb32ac4119a2af2b97fd11b72 (messenger nonce 44267)
    withdrawal 0x4015f4169dfd874776634a44504ac9dda82463dcc2ec473e724cee8a55b57474
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.01199 wstETH  sent 2025-09-10 09:10:21Z (427d 3h ago)
    from 0xD61054f4456D0555dc2dd82B77F7aD6074836149 to 0xD61054f4456D0555dc2dd82B77F7aD6074836149
    base tx 0xfc314b22d19b5ebba2cff66d442a40d27e6976baf107e47559603efda632c32b (block 35353037)
    message 0x4b1b1e7e2ed4e1c655332f5039509ca638230b15320e992c737c4341ec9fb7d2 (messenger nonce 44519)
    withdrawal 0xbd232cc11c94549b0aed314ac9867573f31aaca801a6a625063d9f281a3dd886
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.01 wstETH  sent 2026-05-26 00:39:51Z (169d 11h ago)
    from 0x74870e3778C7Fd03459a4CB61Eec1ca9452c4ce2 to 0x74870e3778C7Fd03459a4CB61Eec1ca9452c4ce2
    base tx 0xa80b6c402654a5259b9ba8153ffe0c5778367ef428fb82f42d46344fa311d3c8 (block 46483322)
    message 0xbfbc31f51dc3c6f7b112a630c409e1f2082862e487a84c0bb06fbb792d49c401 (messenger nonce 55686)
    withdrawal 0xf850fd31a67b1e9bd0bd109682f4c089b9285df94cfe00a014e225c238214d1b
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.01 wstETH  sent 2026-05-28 03:41:15Z (167d 8h ago)
    from 0x74870e3778C7Fd03459a4CB61Eec1ca9452c4ce2 to 0x74870e3778C7Fd03459a4CB61Eec1ca9452c4ce2
    base tx 0xd4132e99826bb721eef37799d3b24bc33a863c357535c0e892c9b3501d6a8d00 (block 46575164)
    message 0xaef7a6112470fa5cec312eb52f310a5b6e715eb78046210f80984ec5903f8366 (messenger nonce 55753)
    withdrawal 0xffbcb0333ed878a94a8d7a77a5a39a04716721ba6f8d1212eb2afd5b5fb09073
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.004881251433191199 wstETH  sent 2026-05-29 03:09:35Z (166d 9h ago)
    from 0x0BBdfcC61aCe1A1f08222a6FEe0f7e628C09377B to 0x0BBdfcC61aCe1A1f08222a6FEe0f7e628C09377B
    base tx 0x93de416bfb1483b1e698d1b5cecd4c18a380f804d62641b285ec8180a9f884a8 (block 46617414)
    message 0xcd84db19c4f537685ba3d3388deb0d2caad9fc2f5fa63dd61dbf8d0e2e4452af (messenger nonce 55772)
    withdrawal 0x4c91a969488b419b3f540c0cb6271a4d5c7a109a3033bbbdebaffe4c8d74e812
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.00000000000001 wstETH  sent 2026-06-09 01:55:57Z (155d 10h ago)
    from 0x7364Ad99A3Acb7BcBd2Dd9A9B147A5a16dc7A8FD to 0x172B70DA382460f1dBd3EceE4C9E4073E4AAe2F9
    base tx 0x55d40405c65079fb793ec7dbf497e2ddf79bf04cd15b4801c882c5dfa3c56736 (block 47090405)
    message 0x6f4431e67486c42e39900d24fa4bdff1186af5d477d53047d4d37ac521535cce (messenger nonce 56337)
    withdrawal 0xd7dc2ad1e2ad030e781a962476b302f3ed75f65da905419c7149f26bbd975229
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.0000000017021 wstETH  sent 2026-06-30 12:48:51Z (133d 23h ago)
    from 0x1546B970afC85bb7448B2c50504be0C4640408dd to 0x1546B970afC85bb7448B2c50504be0C4640408dd
    base tx 0xcb1ee6f193a9f3f57f5e93c8ca12a7b663df210344fbe6ba25cc4d488b6886cf (block 48017192)
    message 0x7b053b3634fd467fc7463ed0f8c8c87dc33e5f8c037ba130466cc870b3d1d895 (messenger nonce 57141)
    withdrawal 0x05719cdacea1c2dbbb2976dd277406d4a5b395267443bafa230c60f5e28fa6df
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

  READY_TO_PROVE  0.001609637093786651 wstETH  sent 2026-08-29 06:39:29Z (74d 5h ago)
    from 0x1d8c4d80464270AFB50576CAB66F08a29903747F to 0x1d8c4d80464270AFB50576CAB66F08a29903747F
    base tx 0xa676c759e570af18ef1e73f183c02459bee77d953f24fb450cbc9014814731c7 (block 50598111)
    message 0x4af9ff5a64c23183f4b3c8dd3d4a464fb350707fe3801cffb1e42d715f5741ab (messenger nonce 59018)
    withdrawal 0x8d33c4f8cccdadc15d4c7d1f851572aaa8b2f0c3b19a561467d6b444c6ba2e5e
    next: anyone, ethereum: OptimismPortal(0x49048044D57e1C92A77f79988d21Fa8fAF74E97e).proveWithdrawalTransaction(tx, disputeGameIndex, outputRootProof, withdrawalProof)

Backing
  ───────
      24632.649365938439766693  wstETH held by the ethereum bridge (block 26391621)
    − 24242.863501792745872724  wstETH supply on base (block 56045057)
      − 389.785863645693893969  transfers in flight listed above
                   = 0.0000005  not explained by this list
  The two chains are read at different moments, and the list covers the legacy bridge only:
  tokens sent to the bridge address directly, CCIP transfers and a transfer that lands
  between the two reads all show up in the last line. It names no cause by itself.
```

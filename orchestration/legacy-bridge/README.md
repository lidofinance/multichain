# Legacy bridge: transfers in flight

`inflight.py` lists the wstETH transfers that the legacy bridge between Ethereum and Base has
started and not finished, and says which step each one is waiting for. It reads both chains,
sends nothing and needs no key.

```sh
just legacy-inflight --l1-rpc "$RPC_ETHEREUM_REMOTE" --l2-rpc "$RPC_BASE_REMOTE"
just legacy-inflight                    # endpoints from RPC_ETHEREUM and RPC_BASE
just legacy-inflight --limit 0          # list every transfer, not the first 20 per direction
just legacy-inflight --json             # full report, with replay calldata and withdrawal tuples
just legacy-inflight --expect-empty     # exit 2 while anything is in flight
```

Addresses come from `targets/wsteth-base-migration-mainnet/target.json` (`.migration`): the two
tokens, the two bridge proxies and the two messengers. `--target` and `--l2` select another
record. The OptimismPortal is the one the L1 messenger names. The header of the report states the
chain, block and time of each read, and says `LOCAL FORK` when an endpoint is Anvil or a similar
node, so a rehearsal is never mistaken for mainnet.

## What counts as in flight

A transfer is in flight when the source messenger emitted `SentMessage` from one bridge proxy to
the other and the destination messenger does not hold `successfulMessages[hash] == true`. The hash
is the keccak-256 of the `relayMessage(nonce, sender, target, 0, gasLimit, message)` calldata, which
is the key both messengers use. A deposit is an Ethereum → Base message carrying `finalizeDeposit`;
a withdrawal is a Base → Ethereum message carrying `finalizeERC20Withdrawal`. Any other message
between the bridges (after the migration, `confirmL1Activation()`) is listed as a control message
with no amount.

A transaction in the mempool, a reverted send and a delivered transfer are not in flight.

## Statuses

| Status | Direction | Established by | Next step |
| --- | --- | --- | --- |
| `AWAITING_L2_INCLUSION` | deposit | neither flag on the Base messenger; the Base transaction derived from the `TransactionDeposited` log has no receipt | none, the sequencer includes it |
| `RELAY_FAILED` | both | `failedMessages[hash] == true` on the destination messenger | anyone calls `relayMessage` there; `--json` carries the calldata |
| `L2_TX_FAILED` | deposit | the derived Base transaction has a receipt with status 0 and the messenger holds no flag | investigate: the messenger cannot replay it |
| `WAITING_FOR_PROPOSAL` | withdrawal | not proven; the newest dispute game of the portal's respected type claims an earlier Base block | none, wait for a later game |
| `READY_TO_PROVE` | withdrawal | not proven (`numProofSubmitters == 0`); that game claims the withdrawal's block or a later one | anyone calls `OptimismPortal.proveWithdrawalTransaction` |
| `NOT_PROVEN` | withdrawal | not proven, and the newest game could not be read | as above, after checking the game by hand |
| `PROVEN_WAITING` | withdrawal | proven; `OptimismPortal.checkWithdrawal` reverts; the dispute game is still usable | wait for proof maturity and for the game to resolve |
| `PROOF_INVALIDATED` | withdrawal | proven; the dispute game lost to the challenger, or the `AnchorStateRegistry` reports it retired, blacklisted or unregistered | prove again against a current game |
| `READY_TO_FINALIZE` | withdrawal | `OptimismPortal.checkWithdrawal(hash, submitter)` passes | anyone calls `finalizeWithdrawalTransactionExternalProof(tx, submitter)` |
| `FINALIZED_NOT_RELAYED` | withdrawal | `finalizedWithdrawals[hash] == true`, no flag on the L1 messenger | investigate: the messenger cannot replay it |
| `UNKNOWN` | both | the records needed for the reads above were not found, or disagree | read the note on the item |

The portal status of a withdrawal is read for the `MessagePassed` entry of the same Base
transaction; its withdrawal hash is recomputed and must equal the emitted one. When several
accounts proved one withdrawal, a proof that passes the portal check wins, then the newest usable
proof.

Above the list, a `⚠` line appears when a relay would revert right now: the receiving switch of
the destination bridge is off, the bridge is in `CCIP_ONLY`, or the portal is paused.

## Backing line

The report ends with `escrow + lockbox − Base supply − transfers in flight`. The lockbox is read
from `ccipLockBox()` once the L1 bridge runs the migration implementation. A legacy transfer the
list missed would show up here, so the line is a check on the list that does not depend on the
event scan. It cannot name a cause: tokens sent straight to the bridge address, CCIP transfers and
a transfer that lands between the Ethereum read and the Base read all change it.

## What the report does not establish

- It covers the legacy bridge. CCIP messages on the same lane are not read.
- Completeness of the list rests on the endpoint returning every `SentMessage` log; the backing
  line is the cross-check.
- `READY_TO_PROVE` means a suitable game exists. The script does not build the proof.
- Every status is true at the two blocks in the header. A delivery in a destination block that is
  not final yet is counted as delivered and its count is shown.
- The hash assumes a message without ETH value, which is how both bridges send
  (`messenger.sendMessage(target, message, gasLimit)`).

## Cache

Messages from source-final blocks and deliveries seen in destination-final blocks never change, so
they are kept in `.workspace/legacy-bridge-inflight/` (ignored by git) and later runs read only
the new blocks and the open transfers. The first mainnet run scans the bridge's whole history,
from the block where the proxy was created; with an endpoint that limits `eth_getLogs` ranges the
scan narrows its range automatically and takes longer. Nothing is cached for a fork, for an
endpoint without the `finalized` tag, with `--l1-from-block` / `--l2-from-block`, or with
`--no-cache`.

## Checks

`uv run --locked python -m pytest -q orchestration/legacy-bridge/tests` runs offline against
recorded mainnet logs: the message hash Base stored for a real deposit, the Base transaction hash
derived from its Ethereum log, the withdrawal hash Base emitted, and every status branch.

Dated records of mainnet runs are in [`reports/`](./reports/); the first is
[2026-11-11](./reports/2026-11-11-ethereum-base-mainnet.md): 3577 deposits, all delivered; 990
withdrawals, 28 in flight for 389.785863645693893969 wstETH; backing line 0.0000005 wstETH.
Step 6 of the [Base upgrade path](../../targets/wsteth-base-migration-mainnet/docs/2026-10-26-upgrade-path.md)
uses this report. On Anvil forks of both chains a deposit left unrelayed, a deposit relayed
with too little gas and a fresh withdrawal were reported as `AWAITING_L2_INCLUSION`,
`RELAY_FAILED` and `WAITING_FOR_PROPOSAL`; the calldata from `--json` replayed the failed deposit
from an unrelated account.

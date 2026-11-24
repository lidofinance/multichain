# Public testnet bridge smoke tests

These scripts test the existing fresh Sepolia, Base Sepolia and Mantle Sepolia
deployment. They do not deploy contracts or alter roles, CCV policies or limits.
They are separate from the frozen deployment pipeline; each smoke journal binds
the deployment addresses, actor, amount and executed script hashes.

Use Node 24 and the existing private actor environment loaded by
`script/testnet/context.cjs`. Only `RPC_SEPOLIA_REMOTE`,
`RPC_BASE_SEPOLIA_REMOTE` and `RPC_MANTLE_SEPOLIA_REMOTE` are used. Public chain IDs,
deployment block hashes and RPC client types are checked before any operation.
No key or RPC URL is accepted on the command line or printed.

Run from the repository root, reusing **the same journal** throughout:

```sh
node --test orchestration/wsteth-ccip/smoke/bridge.test.cjs

# Complete/resume both round trips automatically (one-hour observation window):
node orchestration/wsteth-ccip/smoke/bridge.cjs run runs/wsteth-2.0/deployments/public-20261104-fresh-01/smoke/roundtrip-01.json

# Or execute the individual phases:
node orchestration/wsteth-ccip/smoke/bridge.cjs preflight runs/wsteth-2.0/deployments/public-20261104-fresh-01/smoke/roundtrip-01.json
node orchestration/wsteth-ccip/smoke/bridge.cjs deposits runs/wsteth-2.0/deployments/public-20261104-fresh-01/smoke/roundtrip-01.json
node orchestration/wsteth-ccip/smoke/bridge.cjs advance runs/wsteth-2.0/deployments/public-20261104-fresh-01/smoke/roundtrip-01.json

# Only after both deposits show delivered:
node orchestration/wsteth-ccip/smoke/bridge.cjs withdrawals runs/wsteth-2.0/deployments/public-20261104-fresh-01/smoke/roundtrip-01.json
node orchestration/wsteth-ccip/smoke/bridge.cjs advance runs/wsteth-2.0/deployments/public-20261104-fresh-01/smoke/roundtrip-01.json
node orchestration/wsteth-ccip/smoke/bridge.cjs status runs/wsteth-2.0/deployments/public-20261104-fresh-01/smoke/roundtrip-01.json
```

`preflight` and `status` only read the chains and write local evidence.
`deposits` obtains missing tokens by staking ETH through wstETH's public payable
entry point, then sends **0.001 wstETH to each L2**. `withdrawals` returns those
same amounts through CCIP; this is a bridge withdrawal, not a Lido withdrawal
queue request. Both L2 deposits must be delivered first.

`advance` makes one attempt for every recorded message. Repeat it after source
finality/attestation availability. It can broadcast permissionless destination
execution transactions. It obtains genuine Chainlink proof bytes from the
[official execution-inputs API](https://docs.chain.link/ccip/concepts/manual-execution),
checks the source message hash and fields, and supplies the deployed Dummy's
`0xdecafbad ++ messageId` envelope for the local resolver. The Chainlink proof is
never synthesized. The destination's complete required quorum must still be
exactly Chainlink + local resolver. This validates one authenticating provider
plus Dummy, **not Nethermind verification or two independent providers**.
Automatic Chainlink executor delivery is not required to pass this operator
smoke: the local Dummy is not onboarded into its Indexer.

The script stops if the recorded resolver implementations change. Once
Nethermind replaces Dummy, update the proof adapter and deployment bundle before
starting a new smoke journal; never continue supplying Dummy envelopes to a
different verifier.

Approvals are for the exact transfer amount. Each transaction's unsigned fields
and deterministic hash are saved before broadcast. Resume reconciles that hash
instead of sending another transfer or replacing its nonce. Do not delete a
journal with pending transactions. `run` and `advance` reconstruct any missing
message records from saved sends before delivery and balance checks. Destination
event searches start at the journal's original balance baseline, so a later
preflight cannot hide a transfer delivered during an interruption.
A `.lock` file prevents concurrent commands
on one journal; after a process crash, check its recorded PID before removing
that lock. Run only one smoke journal for this actor/deployment at a time and do
not concurrently use that actor for other transactions.

Limits: 0.001 wstETH per lane; staking at most 0.05 Sepolia ETH; CCIP quote at
most 0.02 ETH or 5 MNT per message; cumulative transaction value plus maximum
execution-gas charges at most 0.1 native ETH per ETH chain and 20 MNT on Mantle.
Rollup L1 data fees are additional native charges. RPC receipts record actual
costs where supplied. Staked funds remain as wstETH on Sepolia after the round
trips; the script does not unstake them.

Success requires OffRamp state `SUCCESS` (a status-1 transaction alone is
insufficient), the corresponding token transfer, exact actor balance and L2
supply changes, and conservation of both Sepolia lockboxes. The final journal
status is `roundtrips-passed`. Concurrent external token activity intentionally
causes strict balance checks to fail for investigation.

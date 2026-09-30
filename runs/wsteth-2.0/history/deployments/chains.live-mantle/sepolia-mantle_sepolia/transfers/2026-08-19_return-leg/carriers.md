# Live dust return leg — Mantle Sepolia -> L1 Sepolia, 2026-08-19

Route A (self-executed). Completes the round trip started in
[`../2026-08-19_deposit-leg/carriers.md`](../2026-08-19_deposit-leg/carriers.md). Amount
`0.00000333` wstETH (`3330000000000` wei).

## Transactions

| Step | Chain | Tx |
|---|---|---|
| `wstETH.approve(router)` | Mantle Sepolia | `0x3629868ea7668952312e1b69418bcb4d61836fd4417f9cc45d21e4719c0bb13e` |
| **`Router.ccipSend`** (burn; fee 6730658364406906035 wei MNT) | Mantle Sepolia | `0x09bc608ba80f9335a41a36328a00ea5aaded014b2abf337043bbabeaa5b32dd0` |
| **`OffRamp 2.0.execute`** — SUCCESS first attempt, gasUsed 246527 | Sepolia | `0x2cf1800d2d1ccd324bd551de1dd5f97165fa016f0f25c7615199c39b5ba912ba` |

- messageId `0x16fa5db7acd42973784d94df3408640a557a2d17dc30da17f9a81add99dfaf2f`
  (`= keccak256(encodedMessage)`, matches the event's indexed arg)
- source OnRamp `0x98C80d0235Eaae38200720Ae86e2D6a62b3B19c9` (`OnRamp 2.0.0`, Mantle Sepolia)
- dest OffRamp `0xc6A246A9AcdAaE651708706494720F79C3E5d0A1` (`OffRamp 2.0.0`, Sepolia)
- required CCVs, read from the dest OffRamp: `[0xd17C644b5F5c058BB57AcC3c285c5C3aFCEbC5E4]`
- proof supplied `0xdecafbad ++ messageId`
- `getExecutionState(messageId)` = **2 (SUCCESS)**

## Balances

| | before return leg | after |
|---|---|---|
| L1 wstETH (deployer) | `4440000000000` | `7770000000000` |
| L1 lockbox (`0x1A84…52Bb`) | `3330000000000` | `0` |
| L2 wstETH (deployer) | `3330000000000` | `0` |
| L1 wstETH totalSupply | `7770000000000` | `7770000000000` |
| L2 wstETH totalSupply | `3330000000000` | `0` |

Round trip conserves exactly: the release equals the burn, and every balance is back to its
pre-bridge value.

## Notes

- **No finality wait was needed.** The L1 release succeeded minutes after the Mantle burn, on the
  first attempt. This had been an open question.
- The delivery succeeded first try because `script/11_self_execute.sh` now passes an explicit gas
  limit — the defect that caused the deposit leg's first attempt to record FAILURE.
- Executor role was ours on both legs. Nothing here evidences DON delivery.

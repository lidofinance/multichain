# Live dust return leg — Mantle Sepolia -> L1 Sepolia, 2026-08-31

Route A (self-executed). Completes the round trip started in
[`../2026-08-31_deposit-leg/carriers.md`](../2026-08-31_deposit-leg/carriers.md). Amount
`0.00000333` wstETH (`3330000000000` wei). Live deploy #3
(`config/chains.live-mantle-v3`).

## Transactions

| Step | Chain | Tx |
|---|---|---|
| `wstETH.approve(router)` | Mantle Sepolia | `0x70d5cb7421970de227e67812de251945670471771057bb91e0cfb0162a612f3a` |
| **`Router.ccipSend`** (burn; fee 4163193386445843848 wei MNT) | Mantle Sepolia | `0xd707c4ccbe07ea450a8ca04ada67ad242b0312579969034a5d86c8fbbe9fb71d` |
| **`OffRamp 2.0.execute`** — SUCCESS first attempt, gasUsed 246027 | Sepolia | `0x70e1d327cf50299597346f680732246d3f0f8c3739a3428591b5ba720e74108a` |

- messageId `0x57444131995a02ec200967018017aa1621eac26c59add168fcca0bd6ae1a03de`
  (`= keccak256(encodedMessage)`, matches the event's indexed arg)
- source OnRamp `0xCAC5826F878b3BfEE32404619C762b33ae199c1b` (`OnRamp 2.0.0`, Mantle Sepolia)
- dest OffRamp `0xc6A246A9AcdAaE651708706494720F79C3E5d0A1` (`OffRamp 2.0.0`, Sepolia)
- required CCVs, read from the dest OffRamp: `[0x2f1e2F615824338001E3CFB4B72a085c3f6A9581]`
- proof supplied `0xdecafbad ++ messageId`
- `getExecutionState(messageId)` = **2 (SUCCESS)**

## Balances

| | before return leg | after |
|---|---|---|
| L1 wstETH (deployer) | `4440000000000` | `7770000000000` |
| L1 lockbox (`0x19ec…c26c`) | `3330000000000` | `0` |
| L2 wstETH (deployer) | `3330000000000` | `0` |
| L1 wstETH totalSupply | `7770000000000` | `7770000000000` |
| L2 wstETH totalSupply | `3330000000000` | `0` |

Round trip conserves exactly: the release equals the burn, and every balance is back to its
pre-bridge value.

## Notes

- **No finality wait was needed.** The L1 release succeeded minutes after the Mantle burn, on the
  first attempt.
- Deposit-leg execute also succeeded first try (gasUsed 277537) with the explicit gas limit in
  `script/11_self_execute.sh`.
- Executor role was ours on both legs. Nothing here evidences DON delivery.

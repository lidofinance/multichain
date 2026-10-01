# Live dust deposit leg — L1 Sepolia -> Mantle Sepolia, 2026-08-19

Route A (self-executed) of `live-dust-roundtrip-plan.md`. Deposit leg only; the withdrawal leg was
deliberately not run. Amounts: staked `0.00000777` ETH, bridged `0.00000333` wstETH.

## Preconditions cleared this run
Lido had never been turned on (`isStopped=true`, `isStakingPaused=true`, wstETH totalSupply 0).
Resumed via the full governance chain — see `../../resume-2026-08-19/`.

## Transactions

| Step | Chain | Tx |
|---|---|---|
| Aragon vote #0 created + supported | Sepolia | via `TokenManager.forward` |
| `Voting.executeVote(0)` -> `DG.submitProposal` (proposal #1) | Sepolia | |
| `DG.scheduleProposal(1)` | Sepolia | |
| `EmergencyProtectedTimelock.execute(1)` -> Agent -> `Lido.resume()` | Sepolia | |
| `Lido.submit` 7770000000000 wei | Sepolia | `0xd9c9a06ebe14227cd49f2902d2f92f84f0bbf71d3debeb241deefd13cbb0859a` |
| `stETH.approve(wstETH)` | Sepolia | `0x9db0dc1fb8c1ee2c1af8a37e16292094eb49c3a2eb92523a112a929e1b4b74d9` |
| `wstETH.wrap(7770000000000)` | Sepolia | `0x7cd446bd98e0b801c14e438d53c42fb19e01842f8b51abfed0552edd64cf26dc` |
| `wstETH.approve(router)` | Sepolia | `0x6ada72d8ce76a62eedb8b2e4c69acf1d6d8a0e772f4fd934463e397758856559` |
| **`Router.ccipSend`** (fee 139618185658803 wei native) | Sepolia | `0xc089074c2fab8d3d8d922f5a719da0ee0a4ea59d29583e5cd9edf7cf91c56a00` |
| `OffRamp 2.0.execute` — attempt 1, recorded **FAILURE** (OOG) | Mantle Sepolia | `0xe505cba76368987582fc80b746485cdf71f2e9075e1f77fe226799aead2a8fb8` |
| **`OffRamp 2.0.execute` — attempt 2, SUCCESS** (gasUsed 260455) | Mantle Sepolia | `0x792360f571c607143896d31c827d2c2af175e699264dde6cd410d62bec7fc17e` |

- messageId `0xcce02216529808443b3a6fb25b8a2aac6a550c250a9aff94fcd4a0a5f772a500`
  (`= keccak256(encodedMessage)`, matches the event's indexed arg)
- source OnRamp `0x181Ac7dC295f1C8C87342d07CFaBA90bC477DB5d` (`OnRamp 2.0.0`)
- dest OffRamp `0xeD8abf93091D3F1Bfb6Ce14E9413F02a358A83E3` (`OffRamp 2.0.0`)
- CCV supplied `0xBEcd653Bd319A0E3F3C23A19A67c3d3747D286ea`, proof `0xdecafbad ++ messageId`
- `getExecutionState(messageId)` = **2 (SUCCESS)**

## Balances

| | before | after |
|---|---|---|
| L1 wstETH (deployer) | 0 | `4440000000000` |
| L1 lockbox (`0x1A84…52Bb`) | 0 | **`3330000000000`** |
| L2 wstETH (deployer) | 0 | `3330000000000` |
| L1 wstETH totalSupply | 0 | `7770000000000` (locked, not burned) |
| L2 wstETH totalSupply | 0 | `3330000000000` |

Lockbox custody equals the bridged amount exactly (`L-SILO-01`); L2 mint equals the L1 lock
(conservation across the leg).

## What this evidences, and what it does not

- **Does:** `A-CCV-01` enforced by the REAL `OffRamp 2.0` on live state — `getCCVsForMessage`
  returned exactly `[verifier_resolver]`, our deployed `DummyMessageIdVerifier` proof was genuinely
  checked, and delivery minted. Plus `L-SILO-01` and per-leg conservation, on live rather than in
  memory.
- **Does not:** show Chainlink's DON delivers. The executor role was ours. Nothing here says the
  DON would have picked this message up — with our CCV in the required set it cannot.

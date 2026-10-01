# Live dust deposit leg — L1 Sepolia -> Mantle Sepolia, 2026-08-31

Route A (self-executed) of `live-dust-roundtrip-plan.md`, against **live deploy #3**
(`config/chains.live-mantle-v3`, archived `2026-08-31_00-02`). Amounts: staked
`0.00000777` ETH, bridged `0.00000333` wstETH.

## Preconditions cleared this run
Lido had never been turned on (`isStopped=true`, `isStakingPaused=true`, wstETH totalSupply 0).
Resumed via the full governance chain — vote #0 → DG proposal #1 →
`EmergencyProtectedTimelock.execute(1)` → Agent → `Lido.resume()`. End state
`isStopped=false`, `isStakingPaused=false` at 2026-08-31T17:10:49Z.

## Transactions

| Step | Chain | Tx |
|---|---|---|
| Aragon vote #0 created + supported | Sepolia | via `TokenManager.forward` |
| `Voting.executeVote(0)` -> `DG.submitProposal` (proposal #1) | Sepolia | |
| `DG.scheduleProposal(1)` | Sepolia | |
| `EmergencyProtectedTimelock.execute(1)` -> Agent -> `Lido.resume()` | Sepolia | |
| `Lido.submit` 7770000000000 wei | Sepolia | `0x26c2b6ff2a261475ddb9c89ca7fd9dc0e55bbe3b0bdf356ea52ba5f5f933d09f` |
| `stETH.approve(wstETH)` | Sepolia | `0xcf2c358327568d3d88cd538c3691fa41900252db10ea942d55a629201949f7d2` |
| `wstETH.wrap(7770000000000)` | Sepolia | `0x62bfc389a643b969ec56f273053dda72e835e05b393f19ec008cb9bbc422dd3e` |
| `wstETH.approve(router)` | Sepolia | `0xa1ee14ffc495b4be76dffef4877889d398891bb9aa629541c4a42bfca9095a25` |
| **`Router.ccipSend`** (fee 113159314256382 wei native) | Sepolia | `0x2d71d9b9c7288a4ce42d53875b1d11a33a2ceef25eed8d94d921743627d3dd91` |
| **`OffRamp 2.0.execute` — SUCCESS** first attempt, gasUsed 277537 | Mantle Sepolia | `0x1f2d5220d0afc9f09d78e060acfaef739a163f5f5e7ca79b54695ab61045905b` |

- messageId `0x48ed0dde1376cc1c0b7c747fc2dfc61711c5b6a6b7651001c7ba34f90768b613`
  (`= keccak256(encodedMessage)`, matches the event's indexed arg)
- source OnRamp `0x8dcf17f298c881A547D91ca4aA3C2AD7568C6777` (`OnRamp 2.0.0`)
- dest OffRamp `0xeD8abf93091D3F1Bfb6Ce14E9413F02a358A83E3` (`OffRamp 2.0.0`)
- CCV supplied `0x15Db1E4E28269e4e96825B851EE9Bd131193426e`, proof `0xdecafbad ++ messageId`
- `getExecutionState(messageId)` = **2 (SUCCESS)**

## Balances

| | before | after |
|---|---|---|
| L1 wstETH (deployer) | 0 | `4440000000000` |
| L1 lockbox (`0x19ec…c26c`) | 0 | **`3330000000000`** |
| L2 wstETH (deployer) | 0 | `3330000000000` |
| L1 wstETH totalSupply | 0 | `7770000000000` (locked, not burned) |
| L2 wstETH totalSupply | 0 | `3330000000000` |

Lockbox custody equals the bridged amount exactly (`L-SILO-01`); L2 mint equals the L1 lock
(conservation across the leg).

## What this evidences, and what it does not

- **Does:** `A-CCV-01` enforced by the REAL `OffRamp 2.0` on live deploy #3 — `getCCVsForMessage`
  returned exactly `[verifier_resolver]`, our deployed `DummyMessageIdVerifier` proof was genuinely
  checked, and delivery minted. Plus `L-SILO-01` and per-leg conservation, on live rather than in
  memory.
- **Does not:** show Chainlink's DON delivers. The executor role was ours. Nothing here says the
  DON would have picked this message up — with our CCV in the required set it cannot.

# Historical live dust round-trip — deploy #2 plan

This procedure is not the September installation’s runbook. See [current deployment](CURRENT-DEPLOYMENT.md);
no live delivery was performed during that deployment.

> **Scope: live deploy #2** (`config/chains.live-mantle`; the record's only archived run is
> `deployments/chains.live-mantle/sepolia-mantle_sepolia/2026-08-19_22-00` at commit `eb834c3`, and
> no deploy date is on record). Every address,
> role assignment and selector delay below is that record's. A deployment made after 2026-08-27
> differs in three ways that change the procedure: gov holders are distinct addresses and the
> deployer holds no POM role; `GUARDIAN_ROLE` is confined to `veto`; and the 14-day override set
> is six real selectors instead of three plus a phantom. See `PERMISSIONS.md` §4.3 and
> `PARAMETERS.md` §0.2.

> **Plan, not a result.** How to move a **dust amount of wstETH** L1 → L2 and back on the live
> deployment (**Sepolia ↔ Mantle Sepolia**, live deploy #2), using the **real** Chainlink CCIP 2.0
> ramps. This is the concrete execution of `draft-manual-test-plan.md` §4 (Step 3), rewritten
> around a fact that document does not state: **with the deployment as it stands, Chainlink's DON
> will not deliver the message** — the required CCV is ours and nothing off-chain serves it (§2).
> The plan therefore branches on *who runs the executor*.

## 0. Classification (`A.6.B`, `B.3`)

| Field | Value |
|---|---|
| Kind | a **method description** (`A.15`) — a sequence of `U.Work` to perform. Running it produces `E-*` evidence; reading it proves nothing. No step here mints a claim, a gate or a grant |
| Substrate | **live deploy #2** — record `config/chains.live-mantle/`, archived at `deployments/chains.live-mantle/sepolia-mantle_sepolia/2026-06-12_22-49/`. `README.md` §1.1 is the canonical status claim |
| What it evidences | a dated on-chain `U.Transformation` per leg, plus carriers for `E-CCV-01` (→ `A-CCV-01`) and `L-SILO-01` on **live state** rather than in-memory fork state. Route B additionally evidences whether Chainlink's DON services this token on this lane |
| `admissibleUse` | confirm the live deployment carries a real transfer both directions; obtain the first dated live-transfer carriers this repository has |
| `nonAdmissibleUse` | as evidence about any other lane; as a substitute for Claim A / Claim B; as proof the DON *will* deliver under any other configuration than the one actually run |
| Reopen | any Chainlink ramp-version change on the lane; any change to the deploy record; any CCV reconfiguration not reverted per §8 |
| Spends | real Sepolia ETH and real Mantle Sepolia MNT, with the deployer key, mutating live state. Not reversible |

---

## 1. Choose the delivery route before starting

Both routes share §3–§4 (funding, acquiring wstETH, the send leg). They differ only in **who calls
`OffRamp.execute`** and **which CCV set is required**.

| | **Route A — self-executed** | **Route B — DON-delivered** |
|---|---|---|
| CCV set stays | ours (`verifier_resolver`), unchanged | switched to the lane defaults (Chainlink's) |
| Governance needed | **none** | `applyCCVConfigUpdates` on both chains, L1-POM & L2-POM propose → **3 days** → execute |
| Who executes | we do, permissionlessly | Chainlink's `defaultExecutor` |
| Elapsed | ~1 hour | ~3 days + delivery latency |
| Proves | `A-CCV-01` enforced by the real OffRamp 2.0 on live state; conservation; siloed custody | that the DON services this token/lane at all |
| Leaves behind | nothing to revert | a CCV reconfiguration that **must** be reverted (§8) |

**Recommended order: A, then B.** A is cheap, reversible-by-construction, and proves the pools and
the gate on live. B answers a different question — one nothing in this repository currently answers
— but costs a 3-day governance round in each direction and temporarily removes the Lido verifier
seat that is the whole point of the design.

---

## 2. Why the DON will not deliver as-is

Three facts, all in deployed code:

1. **The required CCV is ours.** `2_Configure.s.sol:200-218` set the hooks' `outboundCCVs` /
   `inboundCCVs` to `[verifier_resolver]` — non-empty and non-zero. `OffRamp.sol:547-551` unions in
   the source chain's `defaultCCVs` (Chainlink's own `VersionedVerifierResolver 2.0.0`) **only**
   when some entry is `address(0)`; a non-empty declaration prevents that. `PARAMETERS.md`
   `P-CCV-01` is the pinned coordinate.
2. **Our verifier publishes nowhere.** `1_Deploy.s.sol:128-130` sets
   `storageLocations[0] = "dummy://message-id-verifier"` — the placeholder default of
   `vm.envOr("STORAGE_LOCATION", …)`. An executor discovers CCV proofs by fetching from the CCV's
   storage locations. Nothing serves that scheme.
3. **Nobody operates it.** A CCV is a contract *plus* an off-chain service. We deployed the
   contract only.

So origination succeeds and the message then sits unexecuted. That is a configuration consequence,
not a Chainlink outage.

**What makes Route A possible:** `OffRamp.execute` (`OffRamp.sol:188-224`) is **fully
permissionless** — no executor check, no exclusivity window; only RMN curse, source-chain-enabled,
allowed-OnRamp, OffRamp-match, dest-selector, array-length and receiver-shape checks. And
`DummyMessageIdVerifier.verifyMessage` (`:52-71`) checks only
`verifierResults == VERSION_TAG (0xdecafbad) ++ messageId` — no signature, no external proof. So
anyone can produce the proof and anyone can execute.

---

## 3. Prerequisites

### 3.1 Endpoints and environment

```bash
UPSTREAM=$RPC_SEPOLIA_REMOTE        PORT=8546 node script/rpc-proxy.mjs &
UPSTREAM=$RPC_MANTLE_SEPOLIA_REMOTE PORT=8547 node script/rpc-proxy.mjs &

export L2_CHAIN=mantle_sepolia
export RPC_SEPOLIA=http://127.0.0.1:8546
export RPC_MANTLE_SEPOLIA=http://127.0.0.1:8547
export RECORD_DIR=config/chains.live-mantle
export DEPLOYER_PRIVATE_KEY=<0x…>   # + DEPLOYER_ADDRESS
```

> **Hazard — the ambient `RPC_SEPOLIA` points at a fork.** The forks tray app exports
> `RPC_SEPOLIA=http://localhost:28002` (a local anvil fork) into the shell. Every command in this
> plan therefore depends on the explicit exports above being present *in the same shell*. A helper
> script that reads `RPC_SEPOLIA` with a fallback inherits the fork instead of live — that cost a
> 15-minute timeout on 2026-08-19, and would be worse if the fork were actually running and a send
> landed there. `script/12_resume_advance.sh` deliberately ignores `RPC_SEPOLIA` and asserts
> `chain-id == 11155111` before doing anything; hold new helpers to the same rule.

### 3.2 Checklist — all must pass before spending anything

| # | Check | Command | Expect |
|---|---|---|---|
| 1 | Right chains | `just forks-check` | `11155111` / `5003` |
| 2 | Record resolves | `just addrs` | the §9 addresses, incl. `L1 lockbox … (-> mantle_sepolia)` |
| 3 | **`state/l1.json` is the live one** | `jq .stETH state/l1.json` | `0xFD9E9AC20F037bcB12DaAEe483c9E655526505A5` |
| 4 | Deployer funded | `just preflight` | ETH on Sepolia, **MNT on Mantle Sepolia** |
| 5 | Lane is still real-2.0 | `CCV_LANE_REQUIRED=1 just test-scenarios` | 15 gating tests green |
| 6 | Wiring unchanged | `just verify-state` | `73 checks passed` |
| 7 | Pool really uses these hooks | see below | matches the record |

> **Check 3 matters.** `stake-eth` / `wrap-steth` / `stake-and-wrap` read `state/l1.json` — **not**
> `$RECORD_DIR`. A `just fresh` against the anvil forks overwrites that file. It currently matches
> live deploy #2, and `config/chains.live-mantle/state/l1.json` holds the authoritative copy.

> **Check 7 is not covered by Claim A.** `PERMISSIONS.md` §2.2.4: the pool ↔ hooks binding is
> unpinned. Read it directly:
> ```bash
> cast call 0xD8b378EA0e530E1F4D281d6ef913eF0AcB70DdDa 'getAdvancedPoolHooks()(address)' --rpc-url $RPC_SEPOLIA
> # expect 0xCc32162E343dAA169e0487d9Bbe1866E5aB20a37
> cast call 0xeC7Cb3964EdcCa7B7925A7D159e033D1fC1DD0AB 'getAdvancedPoolHooks()(address)' --rpc-url $RPC_MANTLE_SEPOLIA
> # expect 0x3bE031BAC33897d92076cD02f1643a717EdF60A6
> ```

### 3.3 Amount

**0.00000333 wstETH** per leg (stake `0.00000777` ETH). Far under the caps (`500e18` outbound /
`330e18` inbound). Chosen 2026-08-19 for the first run.

---

## 4. Phase 1 — acquire dust wstETH on L1

### 4.0 BLOCKER, found 2026-08-19: the scratch Lido has never been unpaused

Read live before staking anything:

| Read | Value |
|---|---|
| `stETH.isStopped()` | **true** — the whole protocol is stopped, so even transfers revert |
| `stETH.isStakingPaused()` | **true** — `submit` reverts `STAKING_PAUSED` |
| `stETH.totalSupply()` | `10` wei (the bootstrap deposit) |
| `wstETH.totalSupply()` | **0** — no wstETH has ever existed on this deployment |

There is no other way to obtain wstETH: `wrap` needs stETH, `submit` is the only stETH mint path,
and nobody holds any. **Phase 1 cannot run until Lido is resumed.**

`RESUME_ROLE` and `STAKING_CONTROL_ROLE` on Lido are both held by the **Agent**
(`0x0A0D...FD35`) - not Voting, not the deployer (ACL `hasPermission` reads false for both). The
Agent is reachable only through Dual Governance. So unpausing is a full governance round:

```
TokenManager.forward(newVote(...))     # deployer holds 1e24 of 2e24 LDO; CREATE_VOTES_ROLE
                                       # sits with the TokenManager, not the deployer
wait 300s                              # Voting.voteTime = 300 (incl. 60s objection phase)
Voting.executeVote(id)                 # -> DualGovernance.submitProposal
wait 900s                              # EmergencyProtectedTimelock.getAfterSubmitDelay
DualGovernance.scheduleProposal(id)
wait 900s                              # getAfterScheduleDelay
EmergencyProtectedTimelock.execute(id) # -> AdminExecutor -> Agent -> Lido.resume()
```

Two things make this cheaper than it looks:

- **One call does everything.** `Lido.resume()` (`lib/core/contracts/0.4.24/Lido.sol:527-532`) runs
  both `_resume()` and `_resumeStaking()`. No separate `resumeStaking` call is needed.
- **No staking limit to configure.** `getStakeLimitFullInfo` returns `isStakingLimitSet = false`, so
  once resumed, staking is unlimited.

Total wall-clock ~ **35-40 minutes** on these testnet-tuned delays, and DG is in `Normal` state
(`getPersistedState = 1`) with Voting registered as the sole proposer.

This is a **materially larger action than a dust transfer** - it changes the live protocol's
operating state and is the first real exercise of the Voting -> DG -> Timelock -> Agent chain on
this deployment. Treat it as its own decision, and as its own evidence (`D-GOV-01`), not as a step
of this plan.

### 4.1 Once resumed


The wstETH here is the **scratch-deployed** Lido of live deploy #2 (`0xE0d8…B6A6`), not canonical
Sepolia Lido. Stake into *our* stETH, then wrap.

```bash
just wsteth-balances          # baseline — record all three numbers
just stake-and-wrap 0.00000777   # ETH -> stETH -> wstETH (wraps the full stETH balance)
just wsteth-balances          # L1 wstETH(you) should now be ≈0.00000777
```

Skip if the deployer already holds ≥0.00000333 wstETH.

---

## 5. Phase 2 — the deposit leg (L1 → L2)

### 5.1 The required-CCV set — corrected 2026-08-19

An earlier draft of this section said the send must pin `gasLimit = 0`. **That is wrong**, and the
live reads that settled it are worth recording.

- The **source** OnRamp is strict: `isTokenOnlyTransfer = isTokenTransferWithoutData &&
  resolvedArgs.gasLimit == 0` (`OnRamp.sol:549`). Empty `extraArgs` does **not** give gas limit 0 —
  `FeeQuoter.resolveLegacyArgs(mantleSelector, 0x)` returns **200000** on this lane. So the OnRamp
  treats the send as non-token-only and puts the lane's `defaultCCVs` into the message.
- The **destination** OffRamp is what actually enforces the quorum, and it is permissive:
  `_isTokenOnlyTransfer` (`OffRamp.sol:421-428`) returns true when `dataLength == 0 &&
  ccipReceiveGasLimit == 0` **OR `receiver.code.length == 0`** OR the receiver does not support
  `IAny2EVMMessageReceiver`. **An EOA recipient satisfies it on its own.**
- The OffRamp then computes the required set from its own side only — pool CCVs, receiver CCVs,
  lane-mandated, defaults (`OffRamp.sol:473-560`). The CCV list carried in the message is not
  consulted for the quorum.

So for an **EOA recipient**, the required set is exactly the destination pool's `inboundCCVs` —
`[verifier_resolver]` — and empty `extraArgs` is fine. This is why `RealCcvLane` passes against the
real ramps sending `extraArgs: ""`. It also means the quoted fee is higher than necessary (the
source charges for the default CCVs it embedded), which on testnet does not matter.

**Do not reason about this — read it.** The OffRamp exposes
`getCCVsForMessage(bytes) returns (address[] required, address[] optional, uint8 threshold)`.
`script/11_self_execute.sh` calls it and aborts if the required set contains anything we cannot
attest. A **contract** recipient would change the answer.

### 5.2 Quote and send

```bash
just ccip-fee 0.00000333      # read-only quote, native wei
just bridge-wsteth 0.00000333 # approve + ccipSend; prints tx hash / messageId
```

Record the **tx hash** and the **messageId**. Track at <https://ccip.chain.link>.

### 5.3 Extract the message and check the CCV set

`OffRamp.execute` needs the `encodedMessage`, which is the third field of the `CCIPMessageSent` log
emitted by the active OnRamp — ABI `(address, uint256, bytes, OnRamp.Receipt[], bytes[])`.
`test/scenario/BridgeScenarioBase.sol:181-190` already has the exact decode
(`CCIP_MESSAGE_SENT_SIG` + `_extractEncodedMessage`).

**Deliverable for this plan: a small `script/11_self_execute.sh`** (or a `forge script`) that
(a) pulls the receipt, (b) reuses that decode to get `encodedMessage`, (c) asserts
`keccak256(encodedMessage)` equals the router-returned messageId — the OffRamp computes it that way
at `:228` — (d) decodes and **prints the message's CCV list**, and (e) emits the ready-to-run
`execute` calldata.

**Abort if the printed CCV list contains anything other than the L2 `verifier_resolver`.** That
means the transfer was not treated as token-only; the message cannot be delivered by anyone, and the
funds are locked in the lockbox until the required set changes (see §7.2).

---

## 6. Phase 3 — delivery

### Route A — self-execute

```bash
OFFRAMP=<real OffRamp 2.0 for source selector 16015286601757825753, from router.getOffRamps()>
CCV=0xBEcd653Bd319A0E3F3C23A19A67c3d3747D286ea         # L2 verifier_resolver
PROOF=0xdecafbad${MESSAGE_ID#0x}

cast send $OFFRAMP 'execute(bytes,address[],bytes[],uint32)' \
  $ENCODED "[$CCV]" "[$PROOF]" 0 \
  --rpc-url $RPC_MANTLE_SEPOLIA --private-key $DEPLOYER_PRIVATE_KEY
```

- **Pass an explicit `--gas-limit` (≥3M).** `eth_estimateGas` runs the same catch-and-record path
  the real call does, so while a message has not yet succeeded the estimate covers only the
  *failing* branch and under-provisions the real one; the sub-call then OOGs, `execute` catches
  zero-length error data and records FAILURE. **This is exactly how the first live delivery failed
  on 2026-08-19** — the retry with an explicit limit used 260455 gas and succeeded.
- **A clean simulation is not a green light.** `execute` catches a reverting `releaseOrMint` and
  records FAILURE rather than reverting, so `cast call` succeeds either way. It rules out only the
  outer checks (RMN, allowed OnRamp, quorum, ABI). The verdict is `getExecutionState` after the send.
- `gasLimitOverride = 0` means "no override"; a non-zero value below `message.ccipReceiveGasLimit`
  reverts (`OffRamp.sol:222-224`). For a token-only transfer 0 is correct.
- The deployed `execute` takes **`uint32`** here, not the `uint256` of the vendored revision — same
  `typeAndVersion`, different beta interface cut (found 2026-06-12).
- Resolve `$OFFRAMP` at run time from `router.getOffRamps()`, selecting the entry whose
  `sourceChainSelector` is Sepolia's and whose `typeAndVersion()` is `OffRamp 2.0.0` — the same
  resolution `RealCcvLane._resolve20Ramps` does.

### Route B — DON-delivered

Governance first, on **both** chains, in parallel:

```solidity
hooks.applyCCVConfigUpdates([{
  remoteChainSelector: <peer>,
  outboundCCVs: [], thresholdOutboundCCVs: [],
  inboundCCVs:  [], thresholdInboundCCVs:  []
}])
```

An empty list is accepted (`AdvancedPoolHooks.sol:255-271` only rejects empty *base* lists when a
threshold list is non-empty; ours are empty) and both ramps then fall back to the lane defaults —
source `OnRamp.sol:887-889`, destination `OffRamp.sol:756-762` → `[address(0)]` → the union at
`:547-551`. The executor is already Chainlink's (`OnRamp.sol:563-566`, `defaultExecutor`).

Path on live deploy #2: the deployer holds `PROPOSER_ROLE` and `GUARDIAN_ROLE` on **both** the L1-POM
and the L2-POM, because `chainlink_mcms == emergency_brakes == guardian == deployer` **on that
record** (`PERMISSIONS.md` `D-ACT-07`). So the L2 change needs **no** L1→L2 Agent message through
OpExec.

> On a deployment made after 2026-08-27 this shortcut is gone: the three gov holders are distinct
> addresses and the deployer holds no POM role, so the proposer is `chainlink_mcms` and nothing else
> (`PERMISSIONS.md` §4.3).

```
<L1-POM|L2-POM>.propose(hooks, 0, applyCCVConfigUpdates(...))   # deployer as PROPOSER_ROLE, on each chain
wait 259200s (3 days)                               # global min delay; applyCCVConfigUpdates has no
                                                    # 14-day override. On deploy #2 P-POM-05 lists
                                                    # 0xae39a257 / 0xbfeffd3f / 0xefd07eec / 0xad0f7c64;
                                                    # newer deploys list six real selectors instead.
<L1-POM|L2-POM>.execute(...)                                    # EXECUTOR_ROLE is empty ⇒ permissionless
```

Guardian `approve` does **not** shorten this: `_getProposalState` (`PoolOperationManager.sol:392`)
only consults approval in `ExplicitApproval` mode, and the deployment is in `Veto`. The only instant
path is `setGlobalMinDelay(0)` — as guardian **on deploy #2 only**; `patches/ccip/0002` makes it
`DEFAULT_ADMIN_ROLE`-only on newer deploys, i.e. a DAO action. Either way it mutates a Claim-A-pinned
parameter and erases the veto window. **Do not use it for a convenience test.**

Then send per §5 and simply wait; watch ccip.chain.link.

---

## 7. Phase 4 — the withdrawal leg (L2 → L1)

Structurally identical, mirrored. Burn on L2, release from the L1 lockbox
`0x1A84d705549084C1cF7750A23dB9d0AECd0852Bb`.

```bash
just ccip-fee 0.001                # (L2-side quote: adapt, fee is in native MNT)
just bridge-back-wsteth 0.001
# then §5.3 + §6 against the L1 OffRamp 2.0, CCV = 0xd17C644b5F5c058BB57AcC3c285c5C3aFCEbC5E4
```

Two differences to expect:

1. **Fee token is MNT**, not ETH. Fund accordingly.
2. **Finality.** The OffRamp checks the message's requested finality against the receiver's policy on
   delivery. If the L1 `execute` reverts on a finality condition, wait and retry — a failed execute
   records `FAILURE` and is explicitly re-executable (`OffRamp.sol:230-234` admits "never touched"
   or "tried and failed").

### 7.1 Optional negative — `A-CCV-01` on live

Only meaningful once a second CCV is in the required set (2-of-2; see the separate 2-of-2 work).
With the deployed 1-of-1 set there is no "1 of 2" to withhold.

### 7.2 If a message becomes undeliverable

If §5.3 shows a required set nobody can satisfy, the dust is locked in the lockbox — not lost.
Recovery is a governance `applyCCVConfigUpdates` bringing the required set back to something
producible, then re-running `execute` on the same message.

---

## 8. Verification and evidence capture

After each leg:

```bash
just wsteth-balances                                             # deltas
cast call $OFFRAMP 'getExecutionState(bytes32)(uint8)' $MESSAGE_ID   # expect SUCCESS
```

Expected, per leg of 0.001:

| | deposit L1→L2 | withdrawal L2→L1 |
|---|---|---|
| L1 wstETH (you) | −0.001 | +0.001 |
| L1 lockbox | **+0.001** | **−0.001** |
| L2 wstETH (you) | +0.001 | −0.001 |

Lockbox custody moving in lockstep is the `L-SILO-01` carrier; the pair of legs returning every
balance to its baseline is the conservation carrier.

**Record, as the `E-*` carriers this produces:** both tx hashes, both messageIds, both `execute` tx
hashes, `getExecutionState` results, and the balance table before/after. Put them in a dated file
under `deployments/chains.live-mantle/sepolia-mantle_sepolia/<date>/transfers/` so the run is
referable rather than asserted (`A.10`).

## 9. Cleanup

- **Route A:** nothing to revert. Re-run `just verify-state` → still `73 checks passed`.
- **Route B:** revert the CCV set to `[verifier_resolver]` on both chains — another 3-day round —
  then re-run `just verify-state`. It will be **red on `P-CCV-01` until reverted**; that is
  expected, and must not be left standing.
- Stop the RPC proxies: `pkill -f rpc-proxy.mjs`.

## 10. Address quick-reference

| | L1 Sepolia (11155111) | L2 Mantle Sepolia (5003) |
|---|---|---|
| wstETH | `0xE0d8BEE3Db8dad3383561760E7704229838BB6A6` | `0xcc5Ba15FA275e5407d328861C56DDCedEd1250c8` |
| stETH | `0xFD9E9AC20F037bcB12DaAEe483c9E655526505A5` | — |
| pool | `0xD8b378EA0e530E1F4D281d6ef913eF0AcB70DdDa` (SiloedLockRelease) | `0xeC7Cb3964EdcCa7B7925A7D159e033D1fC1DD0AB` (BurnMint) |
| hooks | `0xCc32162E343dAA169e0487d9Bbe1866E5aB20a37` | `0x3bE031BAC33897d92076cD02f1643a717EdF60A6` |
| POM (L1-POM / L2-POM) | `0xe2F13D85d34CEC0E46BC878044B88d3cA8ec3F14` | `0x535618bb310546ca854f65D78332caf63cc8B124` |
| CCV resolver | `0xd17C644b5F5c058BB57AcC3c285c5C3aFCEbC5E4` | `0xBEcd653Bd319A0E3F3C23A19A67c3d3747D286ea` |
| CCV verifier | `0x9e4015f4C5D7f4576936903AE96DCA2fF36E0998` | `0xfbAE3675db48b700dd7b0c9c21A147096780E862` |
| router | `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59` | `0xFd33fd627017fEf041445FC19a2B6521C9778f86` |
| selector | `16015286601757825753` | `8236463271206331221` |
| lockbox → mantle | `0x1A84d705549084C1cF7750A23dB9d0AECd0852Bb` | — |

Deployer (holds all gov roles **on this record**): `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597`.

## 11. Open items

1. ~~`script/11_self_execute.sh` does not exist~~ — **written 2026-08-19**, with a
   `getCCVsForMessage` pre-check and a `cast call` simulation that refuses to send on a revert.
2. ~~Whether the resolved gas limit is 0 for empty `extraArgs`~~ — **settled 2026-08-19**: it is
   `200000`, and it does not matter for an EOA recipient. See the corrected §5.1.
3. ~~Whether the L1-side `execute` needs a finality wait after a Mantle-side burn~~ — **settled
   2026-08-19: no wait was needed.** The release succeeded on the first attempt, minutes after the
   burn.
4. Route B's real question — whether Chainlink's DON services a self-registered token on this beta
   2.0 lane — has no answer in this repository. Running Route B is how it gets one.

---

## 12. Run log

### 2026-08-19 — Route A deposit leg, **completed**

Preconditions: `verify-state` 73/73 green; `test-scenarios` 15/15 green with `A-CCV-01 GATING`;
lane re-probed live (`OnRamp 2.0.0` active both directions).

Blocker cleared first: Lido was resumed through the full governance chain (§4.0) — Aragon vote #0
(1e24 yea / 0 nay) -> DG proposal #1 -> 900s -> schedule -> 900s -> `EmergencyProtectedTimelock.execute`
-> Agent -> `Lido.resume()`. End state `isStopped=false`, `isStakingPaused=false`. The proposal
carried exactly one call: `Agent.forward(callsScript[Lido.resume()])`, verified before execution.

Deposit leg: staked `0.00000777` ETH, wrapped to wstETH (first wstETH ever minted on this
deployment), bridged `0.00000333` via a genuine `ccipSend` through the real `OnRamp 2.0`, and
self-executed on the real `OffRamp 2.0`. `getExecutionState` = **2 (SUCCESS)**.

Carriers: `deployments/chains.live-mantle/sepolia-mantle_sepolia/transfers/2026-08-19_deposit-leg/carriers.md`.

Three findings folded back into this document: the corrected §5.1 (an EOA recipient makes the
transfer token-only regardless of gas limit), the §6 gas-estimation trap, and the §3.1 ambient-RPC
hazard.

### 2026-08-19 — return leg, **completed**

Burn on Mantle Sepolia through the real `OnRamp 2.0` (fee `6.73` MNT), released from the L1 lockbox
via a self-executed `OffRamp 2.0.execute` on Sepolia. **SUCCESS on the first attempt** — the gas-limit
fix from the deposit leg carried over — using 246527 gas. Required CCV set on the L1 side read as
`[0xd17C…C5E4]`, that chain's own resolver alone, mirroring the L2 side exactly.

**No finality wait was needed** (open item 3, now closed).

Round-trip conservation holds: L1 holder back to `7770000000000`, lockbox `0`, L2 supply `0`, L1
supply unchanged throughout.

Carriers: `deployments/chains.live-mantle/sepolia-mantle_sepolia/transfers/2026-08-19_return-leg/carriers.md`.

**Remaining deviation from the starting state:** Lido is unpaused and was not re-paused.

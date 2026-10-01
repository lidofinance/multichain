// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {Pool} from "@chainlink/contracts-ccip/libraries/Pool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";

import {BridgeScenarioBase, IPom, IPausableHooks} from "./BridgeScenarioBase.sol";

/// @notice The deployed Chainlink 1.2.0 Router surface we read (NOT write): resolve the real,
/// DON-served 1.5 OnRamp/OffRamp for a lane, and (optionally) originate a real ccipSend.
interface IRouterReal {
    struct OffRamp {
        uint64 sourceChainSelector;
        address offRamp;
    }

    function getOnRamp(uint64 destChainSelector) external view returns (address);
    function getOffRamps() external view returns (OffRamp[] memory);
    function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message) external view returns (uint256);
    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32);
}

/// @notice Our 2.0 TokenPool's *legacy IPoolV1* surface — the exact entrypoints the real 1.5
/// OffRamp/OnRamp invoke (the single-arg overloads). `TokenPool is IPoolV1V2`, so a live 1.5 ramp
/// drives these directly (see LIVE_DEPLOY_CONCERNS.md §0).
interface ITokenPoolV1 {
    function lockOrBurn(Pool.LockOrBurnInV1 calldata) external returns (Pool.LockOrBurnOutV1 memory);
    function releaseOrMint(Pool.ReleaseOrMintInV1 calldata) external returns (Pool.ReleaseOrMintOutV1 memory);
    function getRemotePools(uint64 remoteChainSelector) external view returns (bytes[] memory);
    function getCurrentRateLimiterState(uint64 remoteChainSelector, bool fastFinality)
        external
        view
        returns (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound);
}

interface IERC20Supply {
    function totalSupply() external view returns (uint256);
}

/// @title RealLaneBridge — Claim B (gating): the real-DON (CCIP 1.5) transport rehearsal.
/// @notice Rehearses the *live* bridging path — our 2.0 pools/hooks/lockbox driven by the **real,
/// forked Chainlink 1.5 ramps** (resolved from the deployed 1.2.0 Router via TAR), NOT by a
/// self-owned 2.0 ramp layer. This is the path a live deployment takes: `ccipSend` → real 1.5
/// OnRamp → our pool's V1 `lockOrBurn`; real DON commit/execute → real 1.5 OffRamp → our pool's V1
/// `releaseOrMint`. Asserts every capability the live 1.5 DON keeps (rate limits A-RL-01, pause,
/// RMN curse, caller-auth, siloed-lockbox custody, conservation). The dual-CCV quorum (A-CCV-01) is
/// intentionally OUT of scope here — it lives only in an OffRamp 2.0 that Chainlink has not shipped
/// to these testnets; it is validated separately by the optional CcvBridge harness (`just test-ccv`).
/// See LIVE_DEPLOY_CONCERNS.md §2/§6 (capability ledger) and the approved plan.
///
/// @dev TWO test-side DON stand-ins are used — both forced by "a fork has no live DON" (no OCR2
/// signers, no Merkle-root commit), and both are TEST CODE, never deploy steps:
///   (1) Inbound: we `vm.prank` the real 1.5 OffRamp address and call the pool's V1 `releaseOrMint`
///       directly — the exact call the real DON's OffRamp makes after resolving our pool via the
///       real TAR. `_onlyOffRamp` passes because the pool's `s_router` is the real router, which
///       already registers that OffRamp for the lane.
///   (2) Outbound: we likewise `vm.prank` the real 1.5 OnRamp and call V1 `lockOrBurn` — the call
///       the real OnRamp makes when processing a `ccipSend`. (A genuine end-to-end `ccipSend` is
///       additionally rehearsed in `test_real_ccipSend_originates_on_real_lane`, which needs no DON
///       for the SEND leg — origination is on-chain — only for delivery.)
contract RealLaneBridgeTest is BridgeScenarioBase {
    // Pinned revert selectors so negatives assert the *specific* gate, not "any revert"
    // (the pause + rate-limit selectors come from BridgeScenarioBase).
    bytes4 internal constant CALLER_IS_NOT_A_RAMP_SELECTOR = bytes4(keccak256("CallerIsNotARampOnRouter(address)"));
    bytes4 internal constant CURSED_BY_RMN_SELECTOR = bytes4(keccak256("CursedByRMN()"));

    function setUp() public {
        _setUpForksAndRecord();

        vm.selectFork(l1Fork);
        _resolveRealRamps(l1);
        vm.selectFork(l2Fork);
        _resolveRealRamps(l2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Resolution (record loading + deployment preconditions live in BridgeScenarioBase)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Runs on `c`'s fork. Resolves the real, DON-served 1.5 ramps for the lane from the
    /// deployed 1.2.0 Router, plus the configured remote pool address our pool will accept.
    function _resolveRealRamps(Ctx storage c) internal {
        c.realOnRamp = IRouterReal(c.router).getOnRamp(c.remoteSelector);
        require(c.realOnRamp != address(0), "no real OnRamp for lane on router");

        IRouterReal.OffRamp[] memory offRamps = IRouterReal(c.router).getOffRamps();
        for (uint256 i = 0; i < offRamps.length; i++) {
            if (offRamps[i].sourceChainSelector == c.remoteSelector) {
                c.realOffRamp = offRamps[i].offRamp;
                break;
            }
        }
        require(c.realOffRamp != address(0), "no real OffRamp for lane on router");

        bytes[] memory remotes = ITokenPoolV1(c.pool).getRemotePools(c.remoteSelector);
        require(remotes.length > 0, "no remote pool configured for lane");
        c.remotePool = remotes[0];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Bridge primitives — drive our pool's V1 path AS THE REAL RAMP would
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev V1 lockOrBurn input for `c`'s lane (also used standalone by the negative tests,
    /// which must order their own prank/expectRevert around the call).
    function _lockOrBurnIn(Ctx storage c, uint256 amount, address to)
        internal
        view
        returns (Pool.LockOrBurnInV1 memory)
    {
        return Pool.LockOrBurnInV1({
            receiver: abi.encode(to),
            remoteChainSelector: c.remoteSelector,
            originalSender: user,
            amount: amount,
            localToken: c.token
        });
    }

    /// @dev V1 releaseOrMint input for `c`'s lane. `sourcePoolData` empty ⇒ pool falls back to
    /// local decimals (both ends are 18), so the local amount equals the source amount.
    function _releaseOrMintIn(Ctx storage c, uint256 amount, address to)
        internal
        view
        returns (Pool.ReleaseOrMintInV1 memory)
    {
        return Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(user),
            remoteChainSelector: c.remoteSelector,
            receiver: to,
            sourceDenominatedAmount: amount,
            localToken: c.token,
            sourcePoolAddress: c.remotePool,
            sourcePoolData: "",
            offchainTokenData: ""
        });
    }

    /// @dev Source leg: position `amount` at the pool (as the Router transfers it pre-lock), then
    /// call V1 `lockOrBurn` pranked as the REAL 1.5 OnRamp. L1 = deposit to siloed lockbox; L2 = burn.
    function _lockOrBurnAsRealOnRamp(Ctx storage c, uint256 amount, address to) internal {
        // adjust=true bumps totalSupply alongside the balance so the L2 burn path
        // (ERC20._burn: _totalSupply -= amount) can't underflow on a standalone leg.
        deal(c.token, c.pool, IERC20(c.token).balanceOf(c.pool) + amount, true);
        vm.prank(c.realOnRamp);
        ITokenPoolV1(c.pool).lockOrBurn(_lockOrBurnIn(c, amount, to));
    }

    /// @dev Dest leg: call V1 `releaseOrMint` pranked as the REAL 1.5 OffRamp. L1 = withdraw from
    /// the siloed lockbox; L2 = mint.
    /// @dev B.3 congruence note: this prank stands in for the real DON's OffRamp.execute (a fork has
    /// no DON) — a CL0–CL1 edge. The SEND leg's genuine `ccipSend` is higher-CL; see README §3/§4.
    function _releaseOrMintAsRealOffRamp(Ctx storage c, uint256 amount, address to) internal {
        vm.prank(c.realOffRamp);
        ITokenPoolV1(c.pool).releaseOrMint(_releaseOrMintIn(c, amount, to));
    }

    function _outboundTokens(Ctx storage c) internal view returns (uint256) {
        (RateLimiter.TokenBucket memory outbound,) =
            ITokenPoolV1(c.pool).getCurrentRateLimiterState(c.remoteSelector, false);
        return outbound.tokens;
    }

    function _inboundTokens(Ctx storage c) internal view returns (uint256) {
        (, RateLimiter.TokenBucket memory inbound) =
            ITokenPoolV1(c.pool).getCurrentRateLimiterState(c.remoteSelector, false);
        return inbound.tokens;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outbound (send) leg — real 1.5 OnRamp drives our pool's lockOrBurn
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice L1 send: the real 1.5 OnRamp's V1 lockOrBurn locks into the per-lane siloed lockbox
    /// (L-SILO-01) and consumes the outbound token bucket (A-RL-01).
    function test_l1_lock_via_real_onramp_consumes_outbound_limit() public {
        vm.selectFork(l1Fork);
        uint256 amount = 10e18;
        uint256 lockBefore = IERC20(l1.token).balanceOf(l1.lockBox);
        uint256 outBefore = _outboundTokens(l1);

        _lockOrBurnAsRealOnRamp(l1, amount, recipient);

        assertEq(IERC20(l1.token).balanceOf(l1.lockBox), lockBefore + amount, "L1 lockbox did not grow by amount");
        assertEq(outBefore - _outboundTokens(l1), amount, "outbound rate-limit bucket not consumed by amount");
    }

    /// @notice L2 send: the real 1.5 OnRamp's V1 lockOrBurn burns L2 supply and consumes the
    /// outbound bucket.
    function test_l2_burn_via_real_onramp_consumes_outbound_limit() public {
        vm.selectFork(l2Fork);
        uint256 amount = 10e18;
        uint256 supplyBefore = IERC20Supply(l2.token).totalSupply();
        uint256 outBefore = _outboundTokens(l2);

        // _lockOrBurnAsRealOnRamp deals +amount supply then burns amount ⇒ net supply unchanged.
        _lockOrBurnAsRealOnRamp(l2, amount, recipient);

        assertEq(IERC20Supply(l2.token).totalSupply(), supplyBefore, "L2 burn did not offset the dealt supply");
        assertEq(outBefore - _outboundTokens(l2), amount, "outbound rate-limit bucket not consumed by amount");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Inbound (receive) leg — real 1.5 OffRamp drives our pool's releaseOrMint
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice L2 receive: the real 1.5 OffRamp's V1 releaseOrMint mints to the recipient and
    /// consumes the inbound bucket (A-RL-01; distinct 330e18 cap).
    function test_l2_mint_via_real_offramp_consumes_inbound_limit() public {
        vm.selectFork(l2Fork);
        uint256 amount = 10e18;
        uint256 balBefore = IERC20(l2.token).balanceOf(recipient);
        uint256 inBefore = _inboundTokens(l2);

        _releaseOrMintAsRealOffRamp(l2, amount, recipient);

        assertEq(IERC20(l2.token).balanceOf(recipient), balBefore + amount, "L2 mint mismatch");
        assertEq(inBefore - _inboundTokens(l2), amount, "inbound rate-limit bucket not consumed by amount");
    }

    /// @notice L1 receive: the real 1.5 OffRamp's V1 releaseOrMint withdraws from the siloed
    /// lockbox to the recipient. Locks first to fund the lane's lockbox (lock-release has no
    /// standalone liquidity), then releases.
    function test_l1_release_via_real_offramp_draws_from_lockbox() public {
        vm.selectFork(l1Fork);
        uint256 amount = 10e18;

        _lockOrBurnAsRealOnRamp(l1, amount, user); // fund the lane's lockbox
        uint256 lockAfterLock = IERC20(l1.token).balanceOf(l1.lockBox);
        uint256 recvBefore = IERC20(l1.token).balanceOf(recipient);
        uint256 inBefore = _inboundTokens(l1);

        _releaseOrMintAsRealOffRamp(l1, amount, recipient);

        assertEq(IERC20(l1.token).balanceOf(recipient), recvBefore + amount, "L1 release mismatch");
        assertEq(IERC20(l1.token).balanceOf(l1.lockBox), lockAfterLock - amount, "L1 lockbox did not shrink by amount");
        assertEq(inBefore - _inboundTokens(l1), amount, "inbound rate-limit bucket not consumed by amount");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Round-trip conservation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice L1→L2→L1 over the real ramps conserves principal: the L1 siloed lockbox returns to
    /// its starting balance after a lock (send) and a matching release (return), and the recipient
    /// is made whole on both legs. (Custody/Conservation view: L1.lockbox == Σ minted, per lane.)
    function test_roundtrip_conserves_lockbox_principal() public {
        uint256 amount = 7e18;

        // L1 → L2: lock on L1, mint on L2.
        vm.selectFork(l1Fork);
        uint256 lockStart = IERC20(l1.token).balanceOf(l1.lockBox);
        _lockOrBurnAsRealOnRamp(l1, amount, recipient);
        assertEq(IERC20(l1.token).balanceOf(l1.lockBox), lockStart + amount, "lock leg: lockbox did not grow");

        vm.selectFork(l2Fork);
        uint256 l2RecvBefore = IERC20(l2.token).balanceOf(recipient);
        _releaseOrMintAsRealOffRamp(l2, amount, recipient);
        assertEq(IERC20(l2.token).balanceOf(recipient), l2RecvBefore + amount, "mint leg mismatch");

        // L2 → L1: burn on L2, release on L1 (draws the locked principal back out).
        vm.selectFork(l2Fork);
        _lockOrBurnAsRealOnRamp(l2, amount, recipient);

        vm.selectFork(l1Fork);
        uint256 l1RecvBefore = IERC20(l1.token).balanceOf(recipient);
        _releaseOrMintAsRealOffRamp(l1, amount, recipient);
        assertEq(IERC20(l1.token).balanceOf(recipient), l1RecvBefore + amount, "release leg mismatch");
        assertEq(IERC20(l1.token).balanceOf(l1.lockBox), lockStart, "conservation: lockbox did not return to start");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Negative gates — each still enforced on the real 1.5 path
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Over-capacity outbound is rejected by the pool token bucket (A-RL-01). Read the live
    /// capacity instead of hardcoding 500e18 so a reconfig can't make this a false positive.
    function test_outbound_over_cap_reverts() public {
        vm.selectFork(l1Fork);
        (RateLimiter.TokenBucket memory outbound,) =
            ITokenPoolV1(l1.pool).getCurrentRateLimiterState(l1.remoteSelector, false);
        assertTrue(outbound.isEnabled, "precondition: outbound rate limit must be enabled");
        uint256 amount = uint256(outbound.capacity) + 1;

        deal(l1.token, l1.pool, IERC20(l1.token).balanceOf(l1.pool) + amount, true);
        vm.prank(l1.realOnRamp);
        vm.expectPartialRevert(TOKEN_MAX_CAPACITY_EXCEEDED_SELECTOR);
        ITokenPoolV1(l1.pool).lockOrBurn(_lockOrBurnIn(l1, amount, recipient));
    }

    /// @notice Over-capacity inbound is rejected by the destination pool's inbound bucket (A-RL-01;
    /// distinct 330e18 cap). Called directly on the pool, so the revert bubbles (unlike the 2.0
    /// OffRamp.execute try/catch path).
    function test_inbound_over_cap_reverts() public {
        vm.selectFork(l2Fork);
        (, RateLimiter.TokenBucket memory inbound) =
            ITokenPoolV1(l2.pool).getCurrentRateLimiterState(l2.remoteSelector, false);
        assertTrue(inbound.isEnabled, "precondition: inbound rate limit must be enabled");
        uint256 amount = uint256(inbound.capacity) + 1;

        vm.prank(l2.realOffRamp);
        vm.expectPartialRevert(TOKEN_MAX_CAPACITY_EXCEEDED_SELECTOR);
        ITokenPoolV1(l2.pool).releaseOrMint(_releaseOrMintIn(l2, amount, recipient));
    }

    /// @notice A-RL-01 (refill leg): the outbound token bucket REFILLS at its configured `rate`
    /// over time — the half of A-RL-01 the over-cap tests do NOT exercise (they check only the
    /// capacity ceiling). Draw the bucket down, warp a span computed from the LIVE rate so it
    /// refills strictly part-way (pinning the rate, not just the cap), and assert it grew by
    /// exactly rate*dt. Makes the README "refills over ~24h" clause behaviourally evidenced rather
    /// than only state-mate-pinned (Claim A).
    function test_outbound_bucket_refills_at_configured_rate() public {
        vm.selectFork(l1Fork);
        (RateLimiter.TokenBucket memory b0,) =
            ITokenPoolV1(l1.pool).getCurrentRateLimiterState(l1.remoteSelector, false);
        assertTrue(b0.isEnabled, "precondition: outbound rate limit must be enabled");
        uint256 rate = uint256(b0.rate);
        uint256 capacity = uint256(b0.capacity);
        assertGt(rate, 0, "precondition: refill rate must be positive");

        uint256 amount = 10e18;
        // b0 was just read with no intervening state change, so b0.tokens is the current balance.
        assertGe(uint256(b0.tokens), amount, "precondition: bucket must hold >= amount to draw down");
        _lockOrBurnAsRealOnRamp(l1, amount, recipient);
        uint256 afterConsume = _outboundTokens(l1);
        assertLt(afterConsume, capacity, "precondition: bucket has headroom after consume");

        // Warp a span that refills ~half of `amount` — strictly below the headroom, so the bucket is
        // NOT clamped to capacity and the assertion pins the actual refill rate (not just "hit cap"):
        // afterConsume <= capacity - amount and rate*dt <= amount/2, so expected stays < capacity.
        uint256 dt = (amount / 2) / rate;
        assertGt(dt, 0, "precondition: dt must be positive to observe a partial refill");
        vm.warp(block.timestamp + dt);

        uint256 expected = afterConsume + rate * dt;
        assertEq(_outboundTokens(l1), expected, "outbound bucket did not refill at the configured rate");
    }

    /// @notice A paused hook blocks the send even on the real lane: the DAO (POM admin) pauses the
    /// pool hooks via POM.directCall; the real OnRamp's lockOrBurn then reverts in the preflight hook.
    function test_paused_hook_blocks_real_onramp_lock() public {
        vm.selectFork(l1Fork);
        vm.prank(l1.govAdmin);
        IPom(l1.pom).directCall(l1.hooks, 0, abi.encodeCall(IPausableHooks.pauseCrossChainTransfers, ()));

        uint256 amount = 1e18;
        deal(l1.token, l1.pool, IERC20(l1.token).balanceOf(l1.pool) + amount, true);
        vm.prank(l1.realOnRamp);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        ITokenPoolV1(l1.pool).lockOrBurn(_lockOrBurnIn(l1, amount, recipient));
    }

    /// @notice An RMN curse on the lane blocks release even on the real lane. We mock the REAL
    /// ARMProxy's `isCursed(bytes16)` to true for the lane (a curse is owner/RMN-gated, not
    /// reproducible on a fork) and assert the pool's V1 releaseOrMint reverts CursedByRMN.
    function test_rmn_curse_blocks_real_offramp_release() public {
        vm.selectFork(l2Fork);
        vm.mockCall(
            l2.arm,
            abi.encodeWithSignature("isCursed(bytes16)", bytes16(uint128(l2.remoteSelector))),
            abi.encode(true)
        );

        vm.prank(l2.realOffRamp);
        vm.expectRevert(CURSED_BY_RMN_SELECTOR);
        ITokenPoolV1(l2.pool).releaseOrMint(_releaseOrMintIn(l2, 1e18, recipient));
        vm.clearMockedCalls();
    }

    /// @notice Caller-auth gate (A.7 "carrier does not act"): only a ramp the real Router recognizes
    /// may move tokens. An arbitrary caller's lockOrBurn reverts CallerIsNotARampOnRouter — proving
    /// the gate binds to the *real* router's ramp set, not to our deploy-time assumptions.
    function test_unauthorized_caller_cannot_lock() public {
        vm.selectFork(l1Fork);
        uint256 amount = 1e18;
        deal(l1.token, l1.pool, IERC20(l1.token).balanceOf(l1.pool) + amount, true);
        // no prank: msg.sender = this test, which is not router.getOnRamp(remoteSelector)
        vm.expectPartialRevert(CALLER_IS_NOT_A_RAMP_SELECTOR);
        ITokenPoolV1(l1.pool).lockOrBurn(_lockOrBurnIn(l1, amount, recipient));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Genuine origination — a real ccipSend through the real Router (no DON stand-in for SEND)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The most faithful outbound rehearsal: a real `ccipSend` through the deployed 1.5
    /// Router/OnRamp. Origination is fully on-chain (no DON needed for the send leg), so this runs
    /// end-to-end on a fork and proves the live lane accepts our token + pool and locks principal.
    /// Pays the fee in native. Whether a fresh, Chainlink-unconfigured token's send succeeds on the
    /// real 1.5 OnRamp fee path is the open question recorded in LIVE_DEPLOY_CONCERNS.md §5.
    function test_real_ccipSend_originates_on_real_lane() public {
        vm.selectFork(l1Fork);
        uint256 amount = 1e18;

        Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
        ta[0] = Client.EVMTokenAmount({token: l1.token, amount: amount});
        Client.EVM2AnyMessage memory m = Client.EVM2AnyMessage({
            receiver: abi.encode(recipient),
            data: "",
            tokenAmounts: ta,
            feeToken: address(0), // pay in native
            extraArgs: ""
        });

        uint256 fee = IRouterReal(l1.router).getFee(l1.remoteSelector, m);

        deal(l1.token, user, amount);
        vm.deal(user, fee);
        vm.startPrank(user);
        IERC20(l1.token).approve(l1.router, amount);

        uint256 lockBefore = IERC20(l1.token).balanceOf(l1.lockBox);
        IRouterReal(l1.router).ccipSend{value: fee}(l1.remoteSelector, m);
        vm.stopPrank();

        assertEq(IERC20(l1.token).balanceOf(l1.lockBox), lockBefore + amount, "real ccipSend did not lock principal");
    }
}

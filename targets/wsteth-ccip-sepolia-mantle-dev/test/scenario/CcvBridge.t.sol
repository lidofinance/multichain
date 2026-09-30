// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {IRMN} from "@chainlink/contracts-ccip/interfaces/IRMN.sol";
import {IRouter} from "@chainlink/contracts-ccip/interfaces/IRouter.sol";
import {OnRamp} from "@chainlink/contracts-ccip/onRamp/OnRamp.sol";
import {OffRamp} from "@chainlink/contracts-ccip/offRamp/OffRamp.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/pools/AdvancedPoolHooks.sol";
import {Internal} from "@chainlink/contracts-ccip/libraries/Internal.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";

import {MockCCV} from "@ccip-lido/test/mocks/MockCCV.sol";
import {MockFeeQuoter} from "@ccip-lido/test/mocks/MockFeeQuoter.sol";
import {MockArmProxy} from "@ccip-lido/test/mocks/MockArmProxy.sol";

import {BridgeScenarioBase, IPom, IPausableHooks} from "./BridgeScenarioBase.sol";

/// @notice Forked 1.2.0 Router surface we need: register our 2.0 ramps + read back.
interface IForkedRouter {
    struct OnRampU {
        uint64 destChainSelector;
        address onRamp;
    }
    struct OffRampU {
        uint64 sourceChainSelector;
        address offRamp;
    }

    function owner() external view returns (address);
    function applyRampUpdates(OnRampU[] calldata, OffRampU[] calldata, OffRampU[] calldata) external;
    function getOnRamp(uint64) external view returns (address);
    function isOffRamp(uint64, address) external view returns (bool);
}

/// @notice OffRamp execution-state view. The returned uint8 is an Internal.MessageExecutionState
/// ordinal (UNTOUCHED=0, IN_PROGRESS=1, SUCCESS=2, FAILURE=3); assertions cast that enum rather
/// than hardcoding 2/3, so a CCIP enum reorder is a compile-time/semantic break, not a silent flip.
interface IOffRampState {
    function getExecutionState(bytes32 messageId) external view returns (uint8);
}

/// @notice OptimismBridgeExecutor (L2 gov entrypoint) surface.
interface IOpExec {
    function queue(
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        bool[] memory withDelegatecalls
    ) external;
    function execute(uint256 actionsSetId) external payable;
    function getActionsSetCount() external view returns (uint256);
    function getDelay() external view returns (uint256);
}

/// @notice AdvancedPoolHooks.getRequiredCCVs (direction as uint8: 0=Outbound, 1=Inbound).
interface IHooksView {
    function getRequiredCCVs(address token, uint64 remoteChainSelector, uint256 amount, bytes4 finality, bytes calldata extra, uint8 direction)
        external
        view
        returns (address[] memory);
}

/// @notice TokenPool.getCurrentRateLimiterState — lets the rate-limit test read the *actual*
/// configured capacity instead of hardcoding it, so it can't become a false positive if the
/// bucket is reconfigured on the live pool.
interface IPoolRateLimit {
    function getCurrentRateLimiterState(uint64 remoteChainSelector, bool fastFinality)
        external
        view
        returns (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound);
}

/// @title CcvBridge — step 06/09 Claim-B harness.
/// @notice The forks only have CCIP 1.5 system ramps, so this test deploys our OWN CCIP 2.0
/// OnRamp + OffRamp on each fork, registers them in the forked 1.5 Router (via owner
/// impersonation), reconfigures our pool hooks to a 2-of-2 mock-CCV quorum (via POM.directCall
/// pranked as the DAO admin), and drives a real bridge round-trip:
///   L1 ccipSend (lock in siloed lockbox) -> capture CCIPMessageSent.encodedMessage ->
///   L2 OffRamp.execute (2-of-2 CCV quorum -> releaseOrMint -> mint), and the reverse.
/// See PLAN §1/§6b.1 (corrected) + memory `reference-ccip-version-fork`.
contract CcvBridgeTest is BridgeScenarioBase {
    function setUp() public {
        _setUpForksAndRecord();

        // 1) deploy our 2.0 ramp layer + mocks on each fork
        vm.selectFork(l1Fork);
        _deployRamps(l1);
        vm.selectFork(l2Fork);
        _deployRamps(l2);

        // 2) wire each side (references the OTHER fork's offRamp/onRamp addresses)
        vm.selectFork(l1Fork);
        _wire(l1, l2);
        vm.selectFork(l2Fork);
        _wire(l2, l1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deploy + wiring (record loading + common preconditions live in BridgeScenarioBase)
    // ─────────────────────────────────────────────────────────────────────────

    function _assertDeployedExtraL1() internal view override {
        _requireCode(l1.tar, "l1 TAR");
    }

    function _assertDeployedExtraL2() internal view override {
        _requireCode(l2.tar, "l2 TAR");
        // OptimismBridgeExecutor (L2 gov entrypoint). test_gov_roundtrip_reconfigures_ccv calls
        // IOpExec(l2.govAdmin).queue(...); a stale/undeployed address would otherwise surface as an
        // opaque "call to non-contract" deep in the test instead of this clear precondition failure.
        _requireCode(l2.govAdmin, "l2 govAdmin (OptimismBridgeExecutor)");
    }

    /// @dev Runs on the currently-selected fork. Deploys mocks + OnRamp + OffRamp.
    function _deployRamps(Ctx storage c) internal {
        c.arm = address(new MockArmProxy());
        c.feeQuoter = address(new MockFeeQuoter());
        c.ccvA = address(new MockCCV());
        c.ccvB = address(new MockCCV());

        c.onRamp = address(
            new OnRamp(
                OnRamp.StaticConfig({
                    chainSelector: c.selector,
                    rmnRemote: IRMN(c.arm),
                    maxUSDCentsPerMessage: type(uint32).max,
                    tokenAdminRegistry: c.tar
                }),
                OnRamp.DynamicConfig({feeQuoter: c.feeQuoter, reentrancyGuardEntered: false, feeAggregator: address(this)})
            )
        );

        c.offRamp = address(
            new OffRamp(
                OffRamp.StaticConfig({
                    localChainSelector: c.selector,
                    gasForCallExactCheck: 5_000,
                    rmnRemote: IRMN(c.arm),
                    tokenAdminRegistry: c.tar,
                    maxGasBufferToUpdateState: 100_000
                })
            )
        );
    }

    /// @dev Runs on `c`'s fork. `r` is the remote chain (for cross-referencing offRamp/onRamp).
    function _wire(Ctx storage c, Ctx storage r) internal {
        // Ramp config validation requires a non-empty default/lane-mandated CCV set. We pass the
        // two CCVs as `defaultCCVs` purely to satisfy that check; for our token-only transfers the
        // ramp defaults are intentionally NOT applied (CCIP skips sender/receiver defaults for pure
        // token transfers), so the POOL HOOKS' getRequiredCCVs remains the sole 2-of-2 enforcer.
        address[] memory both = _ccvs(c);

        // a) OnRamp dest-chain config (-> remote). offRamp = REMOTE offRamp, raw 20 bytes.
        OnRamp.DestChainConfigArgs[] memory dca = new OnRamp.DestChainConfigArgs[](1);
        dca[0] = OnRamp.DestChainConfigArgs({
            destChainSelector: c.remoteSelector,
            router: IRouter(c.router),
            addressBytesLength: 20,
            tokenReceiverAllowed: false,
            messageNetworkFeeUSDCents: 0,
            tokenNetworkFeeUSDCents: 0,
            baseExecutionGasCost: 200_000,
            defaultCCVs: both,
            laneMandatedCCVs: new address[](0),
            defaultExecutor: Client.NO_EXECUTION_ADDRESS,
            offRamp: abi.encodePacked(r.offRamp)
        });
        OnRamp(c.onRamp).applyDestChainConfigUpdates(dca);

        // b) OffRamp source-chain config (<- remote). onRamps = REMOTE onRamp, abi-encoded.
        OffRamp.SourceChainConfigArgs[] memory sca = new OffRamp.SourceChainConfigArgs[](1);
        bytes[] memory onRamps = new bytes[](1);
        onRamps[0] = abi.encode(r.onRamp);
        sca[0] = OffRamp.SourceChainConfigArgs({
            router: IRouter(c.router),
            sourceChainSelector: c.remoteSelector,
            isEnabled: true,
            onRamps: onRamps,
            defaultCCVs: both,
            laneMandatedCCVs: new address[](0)
        });
        OffRamp(c.offRamp).applySourceChainConfigUpdates(sca);

        // c) register our ramps in the forked 1.5 Router (so the pool's isOffRamp/getOnRamp pass)
        IForkedRouter fr = IForkedRouter(c.router);
        IForkedRouter.OnRampU[] memory onUpd = new IForkedRouter.OnRampU[](1);
        onUpd[0] = IForkedRouter.OnRampU({destChainSelector: c.remoteSelector, onRamp: c.onRamp});
        IForkedRouter.OffRampU[] memory offAdd = new IForkedRouter.OffRampU[](1);
        offAdd[0] = IForkedRouter.OffRampU({sourceChainSelector: c.remoteSelector, offRamp: c.offRamp});
        // offRampRemoves is intentionally empty: we ADD our 2.0 OffRamp without removing the fork's
        // pre-existing 1.5 OffRamp (whose address we don't track). Both stay valid Router callers,
        // but CCV quorum is enforced at the POOL hooks regardless of which OffRamp calls
        // releaseOrMint, so the stale 1.5 ramp cannot move tokens without the CCV set. The negative
        // tests (quorum_1of2, paused) exercise that pool-level gate.
        vm.prank(fr.owner());
        fr.applyRampUpdates(onUpd, new IForkedRouter.OffRampU[](0), offAdd);

        // d) reconfigure pool hooks to require BOTH CCVs (2-of-2) for the lane, via POM.directCall
        //    (POM admin is the DAO: Agent on L1 / OpExec on L2).
        AdvancedPoolHooks.CCVConfigArg[] memory cfg = new AdvancedPoolHooks.CCVConfigArg[](1);
        cfg[0] = AdvancedPoolHooks.CCVConfigArg({
            remoteChainSelector: c.remoteSelector,
            outboundCCVs: both,
            thresholdOutboundCCVs: new address[](0),
            inboundCCVs: both,
            thresholdInboundCCVs: new address[](0)
        });
        vm.prank(c.govAdmin);
        IPom(c.pom).directCall(c.hooks, 0, abi.encodeCall(AdvancedPoolHooks.applyCCVConfigUpdates, (cfg)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Bridge primitives
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Token-only message: empty data + EVM_EXTRA_ARGS_V1 with gasLimit 0 => no receiver callback.
    function _tokenOnlyMessage(address token, uint256 amount, address to)
        internal
        pure
        returns (Client.EVM2AnyMessage memory m)
    {
        Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
        ta[0] = Client.EVMTokenAmount({token: token, amount: amount});
        m = Client.EVM2AnyMessage({
            receiver: abi.encode(to),
            data: "",
            tokenAmounts: ta,
            feeToken: token,
            extraArgs: abi.encodePacked(Client.EVM_EXTRA_ARGS_V1_TAG, abi.encode(uint256(0)))
        });
    }

    /// @dev On the source fork: position `amount` at the pool, then drive the source OnRamp as
    /// the (forked) Router would. Returns (messageId, encodedMessage) from CCIPMessageSent.
    function _send(Ctx storage src, uint256 amount, address to)
        internal
        returns (bytes32 messageId, bytes memory encodedMessage)
    {
        // adjust=true so totalSupply is bumped alongside the balance. Without it, a standalone
        // L2->L1 leg on a fork where wstETH totalSupply < amount would panic with arithmetic
        // underflow inside the burn path (ERC20._burn: _totalSupply -= amount) rather than burning.
        deal(src.token, src.pool, IERC20(src.token).balanceOf(src.pool) + amount, true);
        Client.EVM2AnyMessage memory m = _tokenOnlyMessage(src.token, amount, to);

        vm.recordLogs();
        vm.prank(src.router);
        messageId = OnRamp(src.onRamp).forwardFromRouter(src.remoteSelector, m, 0, user);
        // CCIP_MESSAGE_SENT_SIG / _extractEncodedMessage (the event-shape-coupled log scrape)
        // live in BridgeScenarioBase, shared with RealCcvLane.
        encodedMessage = _extractEncodedMessage(src.onRamp);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Full round-trip: L1 -> L2 (lock + mint), then L2 -> L1 (burn + release).
    function test_bridge_roundtrip() public {
        uint256 amount = 10e18;

        // ── L1 -> L2 ──
        vm.selectFork(l1Fork);
        uint256 lockBefore = IERC20(l1.token).balanceOf(l1.lockBox);
        (bytes32 mid1, bytes memory enc1) = _send(l1, amount, recipient);
        assertEq(IERC20(l1.token).balanceOf(l1.lockBox), lockBefore + amount, "L1 lockbox did not grow by amount");

        vm.selectFork(l2Fork);
        uint256 l2Before = IERC20(l2.token).balanceOf(recipient);
        bytes[] memory vr = new bytes[](2);
        OffRamp(l2.offRamp).execute(enc1, _ccvs(l2), vr, 0);
        assertEq(IERC20(l2.token).balanceOf(recipient), l2Before + amount, "L2 mint mismatch");
        assertEq(
            IOffRampState(l2.offRamp).getExecutionState(mid1),
            uint8(Internal.MessageExecutionState.SUCCESS),
            "L2 exec state != SUCCESS"
        );

        // ── L2 -> L1 ──
        vm.selectFork(l2Fork);
        (bytes32 mid2, bytes memory enc2) = _send(l2, amount, recipient);

        vm.selectFork(l1Fork);
        uint256 l1RecvBefore = IERC20(l1.token).balanceOf(recipient);
        uint256 lockBefore2 = IERC20(l1.token).balanceOf(l1.lockBox);
        bytes[] memory vr2 = new bytes[](2);
        OffRamp(l1.offRamp).execute(enc2, _ccvs(l1), vr2, 0);
        // Assert the OffRamp recorded SUCCESS, not just the balance deltas: the 2.0 OffRamp wraps
        // executeSingleMessage in try/catch, so a siloed-lockbox releaseOrMint failure would be
        // swallowed as a FAILURE state. Without this the balance asserts alone could mask a
        // regression where the L1 release silently no-ops (e.g. insufficient lockbox liquidity).
        assertEq(
            IOffRampState(l1.offRamp).getExecutionState(mid2),
            uint8(Internal.MessageExecutionState.SUCCESS),
            "L1 exec state != SUCCESS"
        );
        assertEq(IERC20(l1.token).balanceOf(recipient), l1RecvBefore + amount, "L1 release mismatch");
        assertEq(IERC20(l1.token).balanceOf(l1.lockBox), lockBefore2 - amount, "L1 lockbox did not shrink");
    }

    /// @notice A 1-of-2 (non-quorum) delivery MUST NOT mint (gate A-CCV-01). The 2.0 OffRamp wraps
    /// executeSingleMessage in a try/catch, so a missing-CCV revert is recorded as a FAILURE
    /// execution state rather than bubbling up — assert FAILURE + zero mint.
    function test_quorum_1of2_does_not_mint() public {
        uint256 amount = 5e18;

        vm.selectFork(l1Fork);
        (bytes32 mid, bytes memory enc) = _send(l1, amount, recipient);

        vm.selectFork(l2Fork);
        uint256 balBefore = IERC20(l2.token).balanceOf(recipient);
        address[] memory one = new address[](1);
        one[0] = l2.ccvA; // only one of the two required CCVs
        bytes[] memory vr = new bytes[](1);
        OffRamp(l2.offRamp).execute(enc, one, vr, 0);

        assertEq(
            IOffRampState(l2.offRamp).getExecutionState(mid),
            uint8(Internal.MessageExecutionState.FAILURE),
            "1-of-2 must record FAILURE, not SUCCESS"
        );
        assertEq(IERC20(l2.token).balanceOf(recipient), balBefore, "1-of-2 must not mint any tokens");
    }

    /// @notice A paused hook blocks outbound transfers. The DAO (POM admin) pauses the pool hooks
    /// via POM.directCall; the source send then reverts in lockOrBurn (whenNotPaused).
    function test_paused_hook_blocks_send() public {
        vm.selectFork(l1Fork);

        // pause L1 pool hooks (onlyOwner == POM; admin == Agent)
        vm.prank(l1.govAdmin);
        IPom(l1.pom).directCall(l1.hooks, 0, abi.encodeCall(IPausableHooks.pauseCrossChainTransfers, ()));

        uint256 amount = 1e18;
        deal(l1.token, l1.pool, IERC20(l1.token).balanceOf(l1.pool) + amount);
        Client.EVM2AnyMessage memory m = _tokenOnlyMessage(l1.token, amount, recipient);

        vm.prank(l1.router);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        OnRamp(l1.onRamp).forwardFromRouter(l1.remoteSelector, m, 0, user);
    }

    /// @notice Governance round-trip (PLAN §5.1 / D-GOV-01): the L1 Agent (tail of
    /// Voting→DG→Timelock→AdminExecutor→Agent, pinned as OpExec.ethereumGovernanceExecutor) sends
    /// a cross-domain message that, relayed by the L2 messenger, queues an OpExec action which —
    /// after the delay — calls POM.directCall to reconfigure the lane's CCV quorum (2 -> 1).
    /// We relay by impersonating the L2CrossDomainMessenger with xDomainMessageSender == Agent.
    function test_gov_roundtrip_reconfigures_ccv() public {
        vm.selectFork(l2Fork);
        address opExec = l2.govAdmin; // OptimismBridgeExecutor == POM admin on L2
        address agent = l1.govAdmin; // L1 Aragon Agent == OpExec.ethereumGovernanceExecutor
        address messenger = 0x4200000000000000000000000000000000000007;

        uint256 beforeLen =
            IHooksView(l2.hooks).getRequiredCCVs(l2.token, l2.remoteSelector, 1e18, bytes4(0), "", 0).length;
        assertEq(beforeLen, 2, "precondition: lane should be 2-of-2");

        // Action: POM.directCall(hooks, applyCCVConfigUpdates([single CCV])) for the L1 lane.
        address[] memory one = new address[](1);
        one[0] = l2.ccvA;
        AdvancedPoolHooks.CCVConfigArg[] memory cfg = new AdvancedPoolHooks.CCVConfigArg[](1);
        cfg[0] = AdvancedPoolHooks.CCVConfigArg({
            remoteChainSelector: l2.remoteSelector,
            outboundCCVs: one,
            thresholdOutboundCCVs: new address[](0),
            inboundCCVs: one,
            thresholdInboundCCVs: new address[](0)
        });
        bytes memory pomCall =
            abi.encodeCall(IPom.directCall, (l2.hooks, 0, abi.encodeCall(AdvancedPoolHooks.applyCCVConfigUpdates, (cfg))));

        address[] memory targets = new address[](1);
        targets[0] = l2.pom;
        uint256[] memory values = new uint256[](1);
        string[] memory sigs = new string[](1);
        sigs[0] = "";
        bytes[] memory cds = new bytes[](1);
        cds[0] = pomCall;
        bool[] memory dels = new bool[](1);

        // Relay: queue must come from the L2 messenger with xDomainMessageSender == Agent.
        vm.mockCall(messenger, abi.encodeWithSignature("xDomainMessageSender()"), abi.encode(agent));
        uint256 actionId = IOpExec(opExec).getActionsSetCount();
        vm.prank(messenger);
        IOpExec(opExec).queue(targets, values, sigs, cds, dels);
        // Clear the mock immediately after the queue call so it can't bleed into the execute() path
        // (or any later messenger read) and feed a stale sender to subsequent validation.
        vm.clearMockedCalls();

        // Execute after the timelock delay.
        vm.warp(block.timestamp + IOpExec(opExec).getDelay() + 1);
        IOpExec(opExec).execute(actionId);

        uint256 afterLen =
            IHooksView(l2.hooks).getRequiredCCVs(l2.token, l2.remoteSelector, 1e18, bytes4(0), "", 0).length;
        assertEq(afterLen, 1, "gov action should have reduced the lane to a single CCV");
    }

    /// @notice An over-capacity outbound transfer is rejected by the pool's token-bucket rate
    /// limiter (gate A-RL-01; outbound capacity = 500e18). A single consume > capacity reverts.
    function test_over_cap_rate_limit_reverts() public {
        vm.selectFork(l1Fork);

        // Read the lane's actual outbound bucket instead of hardcoding 500e18, so this stays a real
        // test of the rate-limit gate even if the live pool is reconfigured (a stale hardcoded
        // amount could otherwise sit under a raised capacity and pass as a false positive).
        (RateLimiter.TokenBucket memory outbound,) =
            IPoolRateLimit(l1.pool).getCurrentRateLimiterState(l1.remoteSelector, false);
        assertTrue(outbound.isEnabled, "precondition: outbound rate limit must be enabled");
        uint256 amount = uint256(outbound.capacity) + 1; // strictly greater than capacity => single consume reverts
        deal(l1.token, l1.pool, IERC20(l1.token).balanceOf(l1.pool) + amount);
        Client.EVM2AnyMessage memory m = _tokenOnlyMessage(l1.token, amount, recipient);

        vm.prank(l1.router);
        // TokenMaxCapacityExceeded carries args (capacity, requested, token); match the selector
        // only so the test stays robust to the exact configured capacity.
        vm.expectPartialRevert(TOKEN_MAX_CAPACITY_EXCEEDED_SELECTOR);
        OnRamp(l1.onRamp).forwardFromRouter(l1.remoteSelector, m, 0, user);
    }

    /// @notice An over-capacity INBOUND transfer is rejected by the DESTINATION pool's inbound
    /// token-bucket limiter (gate A-RL-01; inbound capacity = 330e18, distinct from the 500e18
    /// outbound cap). Mirrors test_over_cap_rate_limit_reverts for the receive leg: the 2.0 OffRamp
    /// wraps executeSingleMessage in try/catch, so the releaseOrMint rate-limit revert surfaces as a
    /// FAILURE execution state (not a bubbled revert) — assert FAILURE + zero mint. Full 2-of-2 CCVs
    /// are supplied so the ONLY gate that can fail is the inbound rate limit, not the CCV quorum.
    function test_over_cap_inbound_rate_limit_does_not_mint() public {
        // Read the L2 pool's actual inbound bucket for the L1 lane (read dynamically, like the
        // outbound test, so a reconfig can't turn this into a false positive).
        vm.selectFork(l2Fork);
        (, RateLimiter.TokenBucket memory inbound) =
            IPoolRateLimit(l2.pool).getCurrentRateLimiterState(l2.remoteSelector, false);
        assertTrue(inbound.isEnabled, "precondition: inbound rate limit must be enabled");
        uint256 amount = uint256(inbound.capacity) + 1; // > inbound cap => releaseOrMint consume reverts

        // Source leg on L1: amount (330e18+1) is below the 500e18 outbound cap, so the send itself
        // succeeds and only the L2 inbound cap is exceeded on receive.
        vm.selectFork(l1Fork);
        (bytes32 mid, bytes memory enc) = _send(l1, amount, recipient);

        // Dest leg on L2: execute with full 2-of-2 CCVs; releaseOrMint hits the inbound cap.
        vm.selectFork(l2Fork);
        uint256 balBefore = IERC20(l2.token).balanceOf(recipient);
        bytes[] memory vr = new bytes[](2);
        OffRamp(l2.offRamp).execute(enc, _ccvs(l2), vr, 0);

        assertEq(
            IOffRampState(l2.offRamp).getExecutionState(mid),
            uint8(Internal.MessageExecutionState.FAILURE),
            "over-cap inbound must record FAILURE, not SUCCESS"
        );
        assertEq(IERC20(l2.token).balanceOf(recipient), balBefore, "over-cap inbound must not mint any tokens");
    }
}

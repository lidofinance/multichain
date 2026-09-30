// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/pools/AdvancedPoolHooks.sol";
import {Internal} from "@chainlink/contracts-ccip/libraries/Internal.sol";

import {MockCCV} from "@ccip-lido/test/mocks/MockCCV.sol";

import {BridgeScenarioBase, IPom} from "./BridgeScenarioBase.sol";

/// @notice Deployed-contract surfaces we read/drive (real Chainlink deployments, NOT ours).
interface ITypeAndVersion {
    function typeAndVersion() external view returns (string memory);
}

interface IRouterCcv {
    struct OffRampEntry {
        uint64 sourceChainSelector;
        address offRamp;
    }

    function getOnRamp(uint64 destChainSelector) external view returns (address);
    function getOffRamps() external view returns (OffRampEntry[] memory);
    function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message) external view returns (uint256);
    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32);
}

/// @notice The real 2.0 OffRamp's permissionless execute + execution-state view. NOTE: the
/// DEPLOYED testnet OffRamp 2.0.0 takes a uint32 gasLimit here, unlike the vendored revision's
/// uint256 (same typeAndVersion, different beta interface cut) — verified against the Etherscan
/// ABI of the sepolia-side deployment.
interface IOffRamp20 {
    function execute(bytes calldata encodedMessage, address[] calldata ccvs, bytes[] calldata verifierResults, uint32 gasLimit)
        external;
    function getExecutionState(bytes32 messageId) external view returns (uint8);
}

/// @title RealCcvLane — A-CCV-01 on the REAL Chainlink 2.0 ramps.
/// @notice On lanes where Chainlink has shipped CCIP 2.0 (e.g. sepolia <-> mantle_sepolia, probed
/// 2026-06-12: OnRamp 2.0.0 is the router's ACTIVE onramp both directions, and an OffRamp 2.0.0 is
/// registered alongside the legacy 1.5/1.6 ones), the dual-CCV quorum gate can be exercised on the
/// REAL ramp deployments — no self-owned ramp layer, no router-owner impersonation (the delta vs
/// the CcvBridge harness). This rehearses the full CCV 2-of-2 enablement story:
///   1. governance enables 2-of-2 via the production path (POM.directCall ->
///      hooks.applyCCVConfigUpdates), CCVs = [our deployed VersionedVerifierResolver
///      (-> DummyMessageIdVerifier, from the step-04/05 deploy), a second CCV];
///   2. a GENUINE `ccipSend` through the real Router/OnRamp 2.0 originates the message
///      (fee in native; the message carries the hooks-required CCV set);
///   3. the REAL OffRamp 2.0's permissionless `execute` enforces the quorum on delivery
///      (`_ensureCCVQuorumIsReached`): 2-of-2 mints, 1-of-2 records FAILURE and does not mint.
///
/// Test-side stand-ins, both unavoidable on a fork and both test-code only:
///   - the second CCV is a MockCCV deployed by the test (stands in for a second verifier operator,
///     e.g. a Lido-run CCV; the FIRST CCV is the real deployed stack and its proof is genuinely
///     checked by DummyMessageIdVerifier.verifyMessage — version tag + attested messageId);
///   - we call the real OffRamp's `execute` ourselves (a fork has no live DON/executor), supplying
///     each CCV's verifier data exactly as a live executor would.
///
/// On pairs whose lane is still 1.5-only every test self-skips —
/// A-CCV-01 there remains covered by the self-owned CcvBridge harness (`just test-ccv`).
contract RealCcvLaneTest is BridgeScenarioBase {
    /// @dev DummyMessageIdVerifier's VERSION_TAG: the 4-byte prefix the deployed
    /// VersionedVerifierResolver maps to the verifier, and the prefix of its expected proof.
    bytes4 internal constant DUMMY_VERIFIER_VERSION_TAG = 0xdecafbad;

    bool internal laneIs20;

    function setUp() public {
        _setUpForksAndRecord();

        vm.selectFork(l1Fork);
        bool l1Is20 = _resolve20Ramps(l1);
        vm.selectFork(l2Fork);
        bool l2Is20 = _resolve20Ramps(l2);
        laneIs20 = l1Is20 && l2Is20;

        // A-CCV-01 coverage is conditional on a LIVE external fact: Chainlink keeping real CCIP 2.0
        // ramps on this lane (active OnRamp 2.0.0 + registered OffRamp 2.0.0, matching `execute`
        // ABI). Make a run STATE its A-CCV-01 scope instead of skipping silently, and let CI / an
        // operator DECLARE a pair as a real-2.0 lane via CCV_LANE_REQUIRED=1 so a regression back to
        // 1.5-only fails LOUD here rather than going green-with-skips (B.3 continuous-assurance).
        console2.log(
            laneIs20
                ? "RealCcvLane: A-CCV-01 GATING (lane resolved real CCIP 2.0 ramps)"
                : "RealCcvLane: A-CCV-01 SKIPPED (1.5-only lane; covered by `just test-ccv`)"
        );
        if (!laneIs20) {
            require(
                !vm.envOr("CCV_LANE_REQUIRED", false),
                "CCV_LANE_REQUIRED set but lane resolved 1.5-only: A-CCV-01 coverage regressed"
            );
            return; // 1.5-only lane: nothing to wire; the 3 tests vm.skip
        }

        // Our deployed CCV stack (step 04/05): the lane's first required CCV on each chain.
        string memory dir = vm.envOr("RECORD_DIR", string("config/chains"));
        l1.ccvA = vm.parseJsonAddress(vm.readFile(string.concat(dir, "/sepolia.json")), ".ccv.verifier_resolver");
        l2.ccvA = vm.parseJsonAddress(vm.readFile(string.concat(dir, "/", l2Chain, ".json")), ".ccv.verifier_resolver");

        // Second CCV per chain (test-local stand-in for a second verifier operator) + gov-enable
        // 2-of-2 through the production path.
        vm.selectFork(l1Fork);
        l1.ccvB = address(new MockCCV());
        _govEnable2of2(l1);
        vm.selectFork(l2Fork);
        l2.ccvB = address(new MockCCV());
        _govEnable2of2(l2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Resolution + wiring
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Runs on `c`'s fork. True iff the lane's ACTIVE onramp is 2.0 and a 2.0 offramp is
    /// registered for the lane (then both are stored). The active-onramp requirement matters:
    /// `ccipSend` always routes through `getOnRamp`, so a 2.0 send is only genuine if 2.0 is live.
    function _resolve20Ramps(Ctx storage c) internal returns (bool) {
        address onRamp = IRouterCcv(c.router).getOnRamp(c.remoteSelector);
        if (onRamp == address(0) || !_is(onRamp, "OnRamp 2.0.0")) return false;

        IRouterCcv.OffRampEntry[] memory offRamps = IRouterCcv(c.router).getOffRamps();
        for (uint256 i = 0; i < offRamps.length; i++) {
            if (offRamps[i].sourceChainSelector == c.remoteSelector && _is(offRamps[i].offRamp, "OffRamp 2.0.0")) {
                c.onRamp = onRamp;
                c.offRamp = offRamps[i].offRamp;
                return true;
            }
        }
        return false;
    }

    function _is(address target, string memory expected) internal view returns (bool) {
        try ITypeAndVersion(target).typeAndVersion() returns (string memory got) {
            return keccak256(bytes(got)) == keccak256(bytes(expected));
        } catch {
            return false;
        }
    }

    /// @dev Runs on `c`'s fork. The production CCV-enablement action: the DAO (POM admin — Agent
    /// on L1 / OpExec on L2) reconfigures the lane's hooks to require BOTH CCVs, in and out.
    function _govEnable2of2(Ctx storage c) internal {
        address[] memory both = _ccvs(c);
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
    // Bridge primitives — genuine origination, real-OffRamp delivery
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev GENUINE send on `c`'s fork: `from` approves the real Router and pays the quoted fee in
    /// native; the real OnRamp 2.0 runs our pool's lockOrBurn and emits the message. Returns the
    /// router-issued messageId + the encodedMessage scraped from CCIPMessageSent.
    function _sendReal(Ctx storage c, address from, uint256 amount, address to)
        internal
        returns (bytes32 messageId, bytes memory encodedMessage)
    {
        Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
        ta[0] = Client.EVMTokenAmount({token: c.token, amount: amount});
        Client.EVM2AnyMessage memory m = Client.EVM2AnyMessage({
            receiver: abi.encode(to),
            data: "",
            tokenAmounts: ta,
            feeToken: address(0), // pay in native
            extraArgs: ""
        });

        uint256 fee = IRouterCcv(c.router).getFee(c.remoteSelector, m);
        vm.deal(from, from.balance + fee);

        vm.startPrank(from);
        IERC20(c.token).approve(c.router, amount);
        vm.recordLogs();
        messageId = IRouterCcv(c.router).ccipSend{value: fee}(c.remoteSelector, m);
        vm.stopPrank();
        // CCIP_MESSAGE_SENT_SIG / _extractEncodedMessage (the event-shape-coupled log scrape)
        // live in BridgeScenarioBase, shared with CcvBridge.
        encodedMessage = _extractEncodedMessage(c.onRamp);
    }

    /// @dev Per-CCV verifier data for delivery, as a live executor would supply it: the deployed
    /// DummyMessageIdVerifier genuinely checks its proof (VERSION_TAG ++ attested messageId, which
    /// the resolver also uses to route to the verifier); the mock second CCV takes empty data.
    function _verifierResults(bytes32 messageId) internal pure returns (bytes[] memory vr) {
        vr = new bytes[](2);
        vr[0] = abi.encodePacked(DUMMY_VERIFIER_VERSION_TAG, messageId);
        vr[1] = "";
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Documents WHY this suite runs on this pair: the lane's ramps are CCIP 2.0 on both
    /// sides (active OnRamp 2.0.0 + registered OffRamp 2.0.0), i.e. the CCV quorum gate exists in
    /// the real deployments here — the capability that is absent on the 1.5-only pairs.
    function test_real_lane_carries_ccip_2_0_ramps() public {
        vm.skip(!laneIs20);
        vm.selectFork(l1Fork);
        assertEq(ITypeAndVersion(l1.onRamp).typeAndVersion(), "OnRamp 2.0.0", "l1 active onramp");
        assertEq(ITypeAndVersion(l1.offRamp).typeAndVersion(), "OffRamp 2.0.0", "l1 offramp");
        vm.selectFork(l2Fork);
        assertEq(ITypeAndVersion(l2.onRamp).typeAndVersion(), "OnRamp 2.0.0", "l2 active onramp");
        assertEq(ITypeAndVersion(l2.offRamp).typeAndVersion(), "OffRamp 2.0.0", "l2 offramp");
    }

    /// @notice CCV 2-of-2 round-trip on the REAL ramps: genuine ccipSend (lock) -> real OffRamp 2.0
    /// execute with both CCVs' proofs (quorum reached -> mint), then the reverse leg (burn ->
    /// release). Conservation: the L1 lockbox returns to its starting balance.
    function test_ccv_2of2_roundtrip_on_real_ramps() public {
        vm.skip(!laneIs20);
        uint256 amount = 10e18;

        // ── L1 -> L2: genuine send locks into the siloed lockbox ──
        vm.selectFork(l1Fork);
        deal(l1.token, user, amount);
        uint256 lockStart = IERC20(l1.token).balanceOf(l1.lockBox);
        (bytes32 mid1, bytes memory enc1) = _sendReal(l1, user, amount, recipient);
        assertEq(IERC20(l1.token).balanceOf(l1.lockBox), lockStart + amount, "L1 lockbox did not grow by amount");

        // ── deliver on L2 through the REAL OffRamp 2.0 with the full 2-of-2 quorum ──
        vm.selectFork(l2Fork);
        uint256 l2Before = IERC20(l2.token).balanceOf(recipient);
        IOffRamp20(l2.offRamp).execute(enc1, _ccvs(l2), _verifierResults(mid1), 0);
        assertEq(
            IOffRamp20(l2.offRamp).getExecutionState(mid1),
            uint8(Internal.MessageExecutionState.SUCCESS),
            "L2 exec state != SUCCESS"
        );
        assertEq(IERC20(l2.token).balanceOf(recipient), l2Before + amount, "L2 mint mismatch");

        // ── L2 -> L1: the recipient sends the minted tokens back (genuine send burns) ──
        (bytes32 mid2, bytes memory enc2) = _sendReal(l2, recipient, amount, recipient);

        vm.selectFork(l1Fork);
        uint256 l1RecvBefore = IERC20(l1.token).balanceOf(recipient);
        IOffRamp20(l1.offRamp).execute(enc2, _ccvs(l1), _verifierResults(mid2), 0);
        assertEq(
            IOffRamp20(l1.offRamp).getExecutionState(mid2),
            uint8(Internal.MessageExecutionState.SUCCESS),
            "L1 exec state != SUCCESS"
        );
        assertEq(IERC20(l1.token).balanceOf(recipient), l1RecvBefore + amount, "L1 release mismatch");
        assertEq(IERC20(l1.token).balanceOf(l1.lockBox), lockStart, "conservation: lockbox did not return to start");
    }

    /// @notice A-CCV-01 enforced by the REAL OffRamp 2.0: delivering with only ONE of the two
    /// required CCVs records FAILURE (the quorum revert is swallowed by execute's try/catch) and
    /// MUST NOT mint.
    function test_ccv_quorum_1of2_does_not_mint_on_real_offramp() public {
        vm.skip(!laneIs20);
        uint256 amount = 5e18;

        vm.selectFork(l1Fork);
        deal(l1.token, user, amount);
        (bytes32 mid, bytes memory enc) = _sendReal(l1, user, amount, recipient);

        vm.selectFork(l2Fork);
        uint256 balBefore = IERC20(l2.token).balanceOf(recipient);
        address[] memory one = new address[](1);
        one[0] = l2.ccvA; // only the deployed resolver — quorum requires the second CCV too
        bytes[] memory vr = new bytes[](1);
        vr[0] = abi.encodePacked(DUMMY_VERIFIER_VERSION_TAG, mid);
        IOffRamp20(l2.offRamp).execute(enc, one, vr, 0);

        assertEq(
            IOffRamp20(l2.offRamp).getExecutionState(mid),
            uint8(Internal.MessageExecutionState.FAILURE),
            "1-of-2 must record FAILURE, not SUCCESS"
        );
        assertEq(IERC20(l2.token).balanceOf(recipient), balBefore, "1-of-2 must not mint any tokens");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {MessageV1Codec} from "@chainlink/contracts-ccip/libraries/MessageV1Codec.sol";
import {OnRamp} from "@chainlink/contracts-ccip/onRamp/OnRamp.sol";

import {MockCCV} from "../mocks/MockCCV.sol";

import {
    DualCcvBase,
    DualCcvDeployment,
    IBalance,
    ICommitteeVerifier,
    IHooksCcv,
    IOffRampReplay,
    IOwned,
    IVerifierResolver
} from "./DualCcvBase.sol";
import {DualCcvFixtures} from "./DualCcvFixtures.sol";

interface IRouterLive {
    function getOnRamp(uint64 destChainSelector) external view returns (address);
    function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message) external view returns (uint256);
    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32);
}

interface IPoolLive {
    struct TokenBucket {
        uint128 tokens;
        uint32 lastUpdated;
        bool isEnabled;
        uint128 capacity;
        uint128 rate;
    }

    function getSupportedChains() external view returns (uint64[] memory);
    function getAllowedFinalityConfig() external view returns (bytes4);
    function getCurrentRateLimiterState(uint64 remoteChainSelector, bool fastFinality)
        external
        view
        returns (TokenBucket memory outbound, TokenBucket memory inbound);
}

interface INethermindVerifier {
    struct BpsFeeConfig {
        uint16 feeBps;
        uint16 minFeeUSDCents;
        uint16 capUSDCents;
        bool enabled;
    }

    function getFee(uint64 destChainSelector, Client.EVM2AnyMessage memory message, bytes memory extraArgs, bytes4 finality)
        external
        view
        returns (uint16 feeUSDCents, uint32 gasForVerification, uint32 payloadSizeBytes);
    function getFeeConfig(uint64 destChainSelector) external view returns (BpsFeeConfig memory);
    function getPriceAdapter(address token) external view returns (address);
    function requireAllTokensPriced() external view returns (bool);
}

interface INethermindOwnerActions {
    struct AllowlistConfigArgs {
        uint64 destChainSelector;
        bool allowlistEnabled;
        address[] addedAllowlistedSenders;
        address[] removedAllowlistedSenders;
    }

    struct OutboundImplementationArgs {
        uint64 destChainSelector;
        address verifier;
    }

    function applyAllowlistUpdates(AllowlistConfigArgs[] calldata args) external;
    function setFeeConfig(uint64 destChainSelector, INethermindVerifier.BpsFeeConfig calldata config) external;
    function applyOutboundImplementationUpdates(OutboundImplementationArgs[] calldata args) external;
}

interface IPriceAdapter {
    function getValueInUSDCents(uint256 amount) external view returns (uint256);
}

interface IOnRampLive {
    struct StaticConfig {
        uint64 chainSelector;
        address rmnRemote;
        uint32 maxUSDCentsPerMessage;
        address tokenAdminRegistry;
    }

    function getStaticConfig() external view returns (StaticConfig memory);
}

/// @title Dual-CCV configuration and transfers on current-block testnet forks
/// @notice Groups B through D check deployment settings, quote fees and send transfers. Group E installs
/// test signers on the forks to exercise destination delivery. F-6 checks lane pauses and group G exercises
/// owner-controlled settings. Case IDs refer to docs/NETHERMIND-CCV-FORK-TEST-PLAN.md.
/// Set RPC_SEPOLIA, RPC_MANTLE_SEPOLIA and RPC_BASE_SEPOLIA for the three forks.
contract RealDualCcvLiveTest is DualCcvBase {
    address internal constant NM = DualCcvDeployment.NETHERMIND_RESOLVER;
    address internal constant CL = DualCcvDeployment.CHAINLINK_RESOLVER;
    bytes32 internal constant CCIP_MESSAGE_SENT_SIG =
        keccak256("CCIPMessageSent(uint64,address,bytes32,address,uint256,bytes,(address,uint32,uint32,uint256,bytes)[],bytes[])");

    // Test committees installed by group E.
    uint256 internal constant NM_KEY_1 = 0x1001;
    uint256 internal constant NM_KEY_2 = 0x1002;
    uint256 internal constant CL_KEY = 0x2001;

    mapping(uint64 selector => uint256 forkId) internal forkOf;
    mapping(uint64 selector => mapping(uint64 source => bool done)) internal committeesReplaced;

    address internal user = makeAddr("dualCcvUser");
    address internal recipient = makeAddr("dualCcvRecipient");

    struct Sent {
        bool ok;
        bytes err;
        bytes32 messageId;
        bytes encodedMessage;
        OnRamp.Receipt[] receipts;
        uint256 fee;
    }

    function setUp() public {
        for (uint256 i = 0; i < DualCcvDeployment.COUNT; ++i) {
            DualCcvDeployment.Chain memory c = DualCcvDeployment.get(i);
            forkOf[c.selector] = vm.createFork(vm.envString(c.rpcEnv));
        }
    }

    // ═════════════════════════ B: configuration behind the resolvers ═════════════════════════

    function test_B01_B07_hooks_require_exactly_the_two_resolvers() public {
        for (uint256 i = 0; i < DualCcvDeployment.COUNT; ++i) {
            DualCcvDeployment.Chain memory c = _select(i);
            IHooksCcv.CCVConfigArg[] memory all = IHooksCcv(c.hooks).getAllCCVConfigs();
            assertEq(all.length, c.selector == DualCcvDeployment.SEPOLIA ? 2 : 1, string.concat(c.name, ": number of lanes"));
            for (uint256 j = 0; j < all.length; ++j) {
                _assertPair(all[j].outboundCCVs, string.concat(c.name, " outbound"));
                _assertPair(all[j].inboundCCVs, string.concat(c.name, " inbound"));
                assertEq(all[j].thresholdOutboundCCVs.length, 0, string.concat(c.name, ": threshold outbound list"));
                assertEq(all[j].thresholdInboundCCVs.length, 0, string.concat(c.name, ": threshold inbound list"));
                // B-7 follows: the retired resolver is in no list.
                assertTrue(all[j].inboundCCVs[0] != c.oldResolver && all[j].inboundCCVs[1] != c.oldResolver, "old resolver listed");
            }
            assertEq(IHooksCcv(c.hooks).getThresholdAmount(), 0, string.concat(c.name, ": threshold amount"));
            assertFalse(IHooksCcv(c.hooks).paused(), string.concat(c.name, ": hooks paused"));
        }
    }

    function test_B02_B05_nethermind_contracts_are_the_recorded_ones() public {
        for (uint256 i = 0; i < DualCcvDeployment.COUNT; ++i) {
            DualCcvDeployment.Chain memory c = _select(i);

            IVerifierResolver.InboundImplementationArgs[] memory inbound = IVerifierResolver(NM).getAllInboundImplementations();
            assertEq(inbound.length, 1, string.concat(c.name, ": Nethermind resolver inbound entries"));
            assertEq(inbound[0].version, DualCcvDeployment.NETHERMIND_TAG, string.concat(c.name, ": inbound tag"));
            assertEq(inbound[0].verifier, c.nethermindVerifier, string.concat(c.name, ": inbound verifier"));

            IVerifierResolver.OutboundImplementationArgs[] memory outbound = IVerifierResolver(NM).getAllOutboundImplementations();
            for (uint256 j = 0; j < outbound.length; ++j) {
                assertEq(outbound[j].verifier, c.nethermindVerifier, string.concat(c.name, ": outbound verifier"));
            }

            // B-3: the committee, for every source chain wstETH accepts messages from.
            uint64[] memory remotes = IPoolLive(c.pool).getSupportedChains();
            for (uint256 j = 0; j < remotes.length; ++j) {
                (address[] memory signers, uint8 threshold) = ICommitteeVerifier(c.nethermindVerifier).getSignatureConfig(remotes[j]);
                assertEq(threshold, 2, string.concat(c.name, ": Nethermind threshold"));
                assertEq(signers.length, 2, string.concat(c.name, ": Nethermind signer count"));
                assertTrue(
                    (signers[0] == DualCcvDeployment.NETHERMIND_SIGNER_1 && signers[1] == DualCcvDeployment.NETHERMIND_SIGNER_2)
                        || (signers[0] == DualCcvDeployment.NETHERMIND_SIGNER_2 && signers[1] == DualCcvDeployment.NETHERMIND_SIGNER_1),
                    string.concat(c.name, ": Nethermind signers")
                );
            }

            // B-4, B-5.
            assertEq(IOwned(NM).owner(), DualCcvDeployment.NETHERMIND_OWNER, string.concat(c.name, ": resolver owner"));
            assertEq(IOwned(c.nethermindVerifier).owner(), DualCcvDeployment.NETHERMIND_OWNER, string.concat(c.name, ": verifier owner"));
            assertEq(NM.codehash, DualCcvDeployment.RESOLVER_CODE_HASH, string.concat(c.name, ": Nethermind resolver code"));
            assertEq(c.nethermindVerifier.codehash, c.nethermindVerifierCodeHash, string.concat(c.name, ": Nethermind verifier code"));
            assertEq(ICommitteeVerifier(c.nethermindVerifier).versionTag(), DualCcvDeployment.NETHERMIND_TAG, "verifier tag");
        }
    }

    function test_B06_chainlink_resolver_is_the_recorded_one() public {
        for (uint256 i = 0; i < DualCcvDeployment.COUNT; ++i) {
            DualCcvDeployment.Chain memory c = _select(i);
            assertEq(CL.codehash, DualCcvDeployment.RESOLVER_CODE_HASH, string.concat(c.name, ": Chainlink resolver code"));
            assertEq(
                IVerifierResolver(CL).getInboundImplementation(abi.encodePacked(DualCcvDeployment.CHAINLINK_TAG)),
                c.chainlinkVerifier,
                string.concat(c.name, ": Chainlink inbound verifier")
            );
            assertTrue(IOwned(CL).owner().code.length > 0, string.concat(c.name, ": Chainlink resolver owner is a contract"));
            uint64[] memory remotes = IPoolLive(c.pool).getSupportedChains();
            for (uint256 j = 0; j < remotes.length; ++j) {
                (address[] memory signers, uint8 threshold) = ICommitteeVerifier(c.chainlinkVerifier).getSignatureConfig(remotes[j]);
                assertGe(threshold, 2, string.concat(c.name, ": Chainlink threshold"));
                _note("B-6", string.concat(c.name, ": Chainlink committee ", vm.toString(uint256(threshold)), " of ", vm.toString(signers.length)));
            }
        }
    }

    function test_B08_spokes_have_no_lane_to_each_other() public {
        for (uint256 i = 0; i < DualCcvDeployment.COUNT; ++i) {
            DualCcvDeployment.Chain memory c = _select(i);
            uint64[] memory remotes = IPoolLive(c.pool).getSupportedChains();
            if (c.selector == DualCcvDeployment.SEPOLIA) {
                assertEq(remotes.length, 2, "sepolia: supported chains");
            } else {
                assertEq(remotes.length, 1, string.concat(c.name, ": supported chains"));
                assertEq(remotes[0], DualCcvDeployment.SEPOLIA, string.concat(c.name, ": only lane is Sepolia"));
            }
        }
    }

    function test_B09_offramp_reports_both_resolvers_for_a_real_message() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = DualCcvFixtures.get(i);
            vm.selectFork(forkOf[DualCcvDeployment.byRpcEnv(f.rpcEnv).selector]);
            (address[] memory required, address[] memory optional, uint8 threshold) =
                IOffRampReplay(f.offRamp).getCCVsForMessage(f.encodedMessage);
            _assertPair(required, string.concat(f.name, " required"));
            assertEq(optional.length, 0, string.concat(f.name, ": optional CCVs"));
            assertEq(threshold, 0, string.concat(f.name, ": optional threshold"));
        }
    }

    /// @notice Not in the plan: the three finality settings a faster-than-finality request has to pass.
    function test_B10_finality_settings() public {
        for (uint256 i = 0; i < DualCcvDeployment.COUNT; ++i) {
            DualCcvDeployment.Chain memory c = _select(i);
            assertEq(IPoolLive(c.pool).getAllowedFinalityConfig(), bytes4(0), string.concat(c.name, ": pool accepts only finality"));
            assertEq(
                ICommitteeVerifier(c.nethermindVerifier).getAllowedFinalityConfig(),
                bytes4(0),
                string.concat(c.name, ": Nethermind verifier accepts only finality")
            );
            _note(
                "B-10",
                string.concat(
                    c.name,
                    ": Chainlink verifier allowed finality ",
                    vm.toString(abi.encodePacked(ICommitteeVerifier(c.chainlinkVerifier).getAllowedFinalityConfig()))
                )
            );
            (IPoolLive.TokenBucket memory fastOut, IPoolLive.TokenBucket memory fastIn) =
                IPoolLive(c.pool).getCurrentRateLimiterState(IPoolLive(c.pool).getSupportedChains()[0], true);
            assertFalse(fastOut.isEnabled || fastIn.isEnabled, string.concat(c.name, ": fast-finality rate limit enabled"));
        }
    }

    // ═════════════════════════ C: fees ═════════════════════════

    /// @notice C-1 and C-2: the Nethermind fee follows its configuration (5 bps of the value, at least $0.10, at
    /// most $10.00) on every route and amount; the total quote is logged.
    function test_C01_C02_fee_by_amount() public {
        uint256[4] memory amounts = [uint256(0.001 ether), 1 ether, 100 ether, 10_000 ether];
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            INethermindVerifier verifier = INethermindVerifier(c.nethermindVerifier);
            INethermindVerifier.BpsFeeConfig memory cfg = verifier.getFeeConfig(dest);
            assertTrue(cfg.enabled, "fee config disabled");
            assertEq(cfg.feeBps, 5, "Nethermind fee bps");
            assertEq(cfg.minFeeUSDCents, 10, "Nethermind minimum fee");
            assertEq(cfg.capUSDCents, 1000, "Nethermind maximum fee");
            assertEq(verifier.getPriceAdapter(c.token), c.priceAdapter, "price adapter");

            uint256 previousFee;
            for (uint256 a = 0; a < amounts.length; ++a) {
                uint256 total = _checkFee(c, dest, amounts[a]);
                assertGe(total, previousFee, "total fee decreased with amount");
                previousFee = total;
            }
            _note("C-3", string.concat(c.name, ": OnRamp limit per message, cents: ",
                vm.toString(uint256(IOnRampLive(IRouterLive(c.router).getOnRamp(dest)).getStaticConfig().maxUSDCentsPerMessage))));
        }
    }

    function _checkFee(DualCcvDeployment.Chain memory c, uint64 dest, uint256 amount) internal view returns (uint256 total) {
        Client.EVM2AnyMessage memory m = _message(c.token, amount, recipient, "", _defaultArgs());
        uint256 value = IPriceAdapter(c.priceAdapter).getValueInUSDCents(amount);
        uint256 expected = value * 5 / 10_000;
        if (expected < 10) expected = 10;
        if (expected > 1000) expected = 1000;
        (uint16 cents,,) = INethermindVerifier(c.nethermindVerifier).getFee(dest, m, "", bytes4(0));
        assertEq(cents, expected, "Nethermind fee does not follow its configuration");
        total = IRouterLive(c.router).getFee(dest, m);
        console2.log(
            string.concat("[C-1] ", c.name, " -> ", DualCcvDeployment.bySelector(dest).name, " amount e-3 wstETH ", vm.toString(amount / 1e15))
        );
        console2.log(
            string.concat("      value $", vm.toString(value / 100), ", Nethermind fee cents ", vm.toString(uint256(cents)), ", total fee wei ", vm.toString(total))
        );
    }

    /// @notice Recorded behaviour: with `requireAllTokensPriced` off, a failing price source lowers the fee to the
    /// minimum instead of blocking the send.
    function test_C02b_price_source_failure_falls_back_to_minimum_fee() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            assertFalse(INethermindVerifier(c.nethermindVerifier).requireAllTokensPriced(), "requireAllTokensPriced");
            vm.mockCallRevert(c.priceAdapter, abi.encodeWithSelector(IPriceAdapter.getValueInUSDCents.selector), "price down");
            Client.EVM2AnyMessage memory m = _message(c.token, 100 ether, recipient, "", _defaultArgs());
            (uint16 cents,,) = INethermindVerifier(c.nethermindVerifier).getFee(dest, m, "", bytes4(0));
            assertEq(cents, 10, "fee with a failing price source");
            Sent memory s = _send(c, dest, 1 ether, recipient, "", _defaultArgs());
            assertTrue(s.ok, "send with a failing price source");
            vm.clearMockedCalls();
        }
    }

    /// @notice C-4: who is paid by one send, in the order of the receipts.
    function test_C04_fee_recipients() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            Sent memory s = _send(c, dest, 1 ether, recipient, "", _defaultArgs());
            assertTrue(s.ok, "send");
            assertEq(s.receipts.length, 5, "number of receipts");
            assertEq(s.receipts[0].issuer, NM, "first receipt: Nethermind resolver");
            assertEq(s.receipts[1].issuer, CL, "second receipt: Chainlink resolver");
            assertEq(s.receipts[2].issuer, c.pool, "third receipt: token pool");
            uint256 sum;
            for (uint256 i = 0; i < s.receipts.length; ++i) {
                sum += s.receipts[i].feeTokenAmount;
            }
            assertEq(sum, s.fee, "receipts do not add up to the quoted fee");
            for (uint256 i = 0; i < s.receipts.length; ++i) {
                console2.log(
                    string.concat(
                        "[C-4] ", c.name, " -> ", DualCcvDeployment.bySelector(dest).name, " receipt ", vm.toString(i), " ",
                        vm.toString(s.receipts[i].issuer), " share bps ", vm.toString(s.receipts[i].feeTokenAmount * 10_000 / sum)
                    )
                );
            }
        }
    }

    // ═════════════════════════ D: sending with two CCVs ═════════════════════════

    function test_D01_D09_send_on_every_route() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            uint256 amount = 3 ether;
            _fund(c, amount);
            uint256 heldBefore = _held(c, dest);
            Sent memory s = _sendFrom(c, dest, user, amount, recipient, "", _defaultArgs());
            assertTrue(s.ok, string.concat(c.name, ": send failed"));

            MessageV1Codec.MessageV1 memory m = _decode(s.encodedMessage);
            assertEq(keccak256(s.encodedMessage), s.messageId, "message id is the hash of the message");
            assertEq(m.sourceChainSelector, c.selector, "source");
            assertEq(m.destChainSelector, dest, "destination");
            assertEq(m.finality, bytes4(0), "finality");
            assertEq(m.tokenTransfer.length, 1, "token transfers");
            assertEq(m.tokenTransfer[0].amount, amount, "amount");
            assertEq(address(bytes20(m.tokenTransfer[0].tokenReceiver)), recipient, "token receiver");
            assertEq(address(bytes20(m.tokenTransfer[0].destTokenAddress)), DualCcvDeployment.bySelector(dest).token, "destination token");
            _assertBothPaid(s.receipts, c.name);
            // D-9: Sepolia locks into the lane's lockbox, a spoke burns.
            if (c.selector == DualCcvDeployment.SEPOLIA) {
                assertEq(_held(c, dest), heldBefore + amount, "lockbox did not grow by the amount");
            } else {
                assertEq(_held(c, dest), heldBefore - amount, "supply did not shrink by the amount");
            }
        }
    }

    /// @notice D-3: a token transfer that also carries data and a callback gas limit.
    function test_D03_token_with_data() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            bytes memory args = abi.encodePacked(bytes4(0x181dcf10), abi.encode(uint256(200_000), true));
            Sent memory s = _send(c, dest, 1 ether, recipient, hex"c0ffee", args);
            if (s.ok) {
                MessageV1Codec.MessageV1 memory m = _decode(s.encodedMessage);
                assertEq(m.data, hex"c0ffee", "data");
                assertEq(m.ccipReceiveGasLimit, 200_000, "callback gas limit");
                _assertBothPaid(s.receipts, c.name);
                _note(
                    "D-3",
                    string.concat(
                        c.name, ": token with data accepted, first receipts ", vm.toString(s.receipts[0].issuer), ", ",
                        vm.toString(s.receipts[1].issuer), ", receipts ", vm.toString(s.receipts.length)
                    )
                );
                // The destination still asks for both resolvers when the message carries data.
                vm.selectFork(forkOf[dest]);
                (address[] memory required,,) =
                    IOffRampReplay(address(bytes20(m.offRampAddress))).getCCVsForMessage(s.encodedMessage);
                _assertPair(required, string.concat(c.name, " D-3 required at destination"));
            } else {
                _note("D-3", string.concat(c.name, ": token with data rejected: ", vm.toString(s.err)));
            }
        }
    }

    function test_D04_D05_outbound_rate_limit() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            (IPoolLive.TokenBucket memory out,) = IPoolLive(c.pool).getCurrentRateLimiterState(dest, false);
            assertTrue(out.isEnabled, "outbound rate limit disabled");
            assertEq(out.capacity, 330 ether, "outbound capacity");

            Sent memory s = _send(c, dest, uint256(out.capacity) + 1, recipient, "", _defaultArgs());
            assertFalse(s.ok, "D-4: amount above capacity was sent");
            assertTrue(_contains(s.err, TOKEN_MAX_CAPACITY_EXCEEDED), "D-4: reason");

            (out,) = IPoolLive(c.pool).getCurrentRateLimiterState(dest, false);
            s = _send(c, dest, out.tokens, recipient, "", _defaultArgs());
            assertTrue(s.ok, "D-5: the available amount was not sent");
            s = _send(c, dest, 1 ether, recipient, "", _defaultArgs());
            assertFalse(s.ok, "D-5: sent past the drained limit");
            assertTrue(_contains(s.err, TOKEN_RATE_LIMIT_REACHED), "D-5: reason");
        }
    }

    function test_D06_zero_amount() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            Sent memory s = _send(c, dest, 0, recipient, "", _defaultArgs());
            assertFalse(s.ok, "zero amount was sent");
            _note("D-6", string.concat(c.name, ": zero amount rejected: ", vm.toString(_first(s.err, 4))));
        }
    }

    /// @notice D-7: a faster-than-finality request is refused at the source, so no message exists that one
    /// committee could sign earlier than the other.
    function test_D07_faster_than_finality_is_refused() public {
        bytes4[3] memory requests = [bytes4(uint32(1)), bytes4(uint32(1 << 16)), bytes4(uint32(64))];
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            for (uint256 q = 0; q < requests.length; ++q) {
                bytes memory args = abi.encodePacked(bytes4(0xa69dd4aa), uint32(0), requests[q], bytes7(0));
                Sent memory s = _send(c, dest, 1 ether, recipient, "", args);
                assertFalse(s.ok, "faster-than-finality request was sent");
                _note(
                    "D-7",
                    string.concat(c.name, ": finality ", vm.toString(abi.encodePacked(requests[q])), " rejected: ", vm.toString(_first(s.err, 4)))
                );
            }
            // The same extraArgs format with finality zero is accepted: the refusal is about finality.
            Sent memory ok = _send(c, dest, 1 ether, recipient, "", abi.encodePacked(bytes4(0xa69dd4aa), uint32(0), bytes4(0), bytes7(0)));
            assertTrue(ok.ok, "extraArgs V3 with finality zero");
        }
    }

    function test_D08_ten_sends_in_one_block() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            _fund(c, 10 ether);
            uint256 heldBefore = _held(c, dest);
            uint64 previous;
            for (uint256 i = 0; i < 10; ++i) {
                Sent memory s = _sendFrom(c, dest, user, 1 ether, recipient, "", _defaultArgs());
                assertTrue(s.ok, "send");
                uint64 number = _decode(s.encodedMessage).messageNumber;
                if (i > 0) assertEq(number, previous + 1, "message numbers are not consecutive");
                previous = number;
            }
            uint256 moved = c.selector == DualCcvDeployment.SEPOLIA ? _held(c, dest) - heldBefore : heldBefore - _held(c, dest);
            assertEq(moved, 10 ether, "accounting after ten sends");
        }
    }

    /// @notice A spoke cannot send wstETH to the other spoke.
    function test_D10_no_send_between_spokes() public {
        DualCcvDeployment.Chain memory c = _select(1);
        Sent memory s = _send(c, DualCcvDeployment.BASE, 1 ether, recipient, "", _defaultArgs());
        assertFalse(s.ok, "mantle_sepolia -> base_sepolia was sent");
        _note("D-10", string.concat("mantle_sepolia -> base_sepolia rejected: ", vm.toString(_first(s.err, 4))));
        c = _select(2);
        s = _send(c, DualCcvDeployment.MANTLE, 1 ether, recipient, "", _defaultArgs());
        assertFalse(s.ok, "base_sepolia -> mantle_sepolia was sent");
        _note("D-10", string.concat("base_sepolia -> mantle_sepolia rejected: ", vm.toString(_first(s.err, 4))));
    }

    /// @notice F-6: a lane disabled in the hooks refuses sends and deliveries.
    function test_F06_disabled_lane() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            Sent memory pending = _send(c, dest, 1 ether, recipient, "", _defaultArgs());
            assertTrue(pending.ok, "send before the lane is disabled");

            IHooksCcv.RemoteLane[] memory lanes = new IHooksCcv.RemoteLane[](1);
            lanes[0] = IHooksCcv.RemoteLane({remoteChainSelector: dest, direction: 0});
            vm.prank(IOwned(c.hooks).owner());
            IHooksCcv(c.hooks).pauseRemoteLanes(lanes);
            Sent memory s = _send(c, dest, 1 ether, recipient, "", _defaultArgs());
            assertFalse(s.ok, "sent on a disabled outbound lane");
            assertTrue(_contains(s.err, bytes4(keccak256("DisabledRemoteLane((uint64,uint8))"))), "F-6: outbound reason");

            // The message sent before is refused at a destination whose inbound lane is disabled.
            DualCcvDeployment.Chain memory d = DualCcvDeployment.bySelector(dest);
            vm.selectFork(forkOf[dest]);
            lanes[0] = IHooksCcv.RemoteLane({remoteChainSelector: c.selector, direction: 1});
            vm.prank(IOwned(d.hooks).owner());
            IHooksCcv(d.hooks).pauseRemoteLanes(lanes);
            Outcome memory o = _deliver(pending.encodedMessage);
            _assertFailed(o, TOKEN_HANDLING_ERROR, "F-6 inbound");
            assertTrue(_contains(o.returnData, bytes4(keccak256("DisabledRemoteLane((uint64,uint8))"))), "F-6: inbound reason");
        }
    }

    // ═════════════════════════ G: what the Nethermind owner key can do to sending ═════════════════════════
    // Not in the plan. These are demonstrations, expected to pass: each is one call by the single key that owns
    // the Nethermind resolver and verifier. F-8 and F-9 in the replay suite show the destination side.

    /// @notice The sender allowlist of the Nethermind verifier decides who may bridge wstETH out.
    function test_G01_nethermind_owner_can_choose_who_may_send() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            address favoured = makeAddr("favoured");
            INethermindOwnerActions.AllowlistConfigArgs[] memory args = new INethermindOwnerActions.AllowlistConfigArgs[](1);
            args[0] = INethermindOwnerActions.AllowlistConfigArgs({
                destChainSelector: dest,
                allowlistEnabled: true,
                addedAllowlistedSenders: _list(favoured),
                removedAllowlistedSenders: new address[](0)
            });
            vm.prank(DualCcvDeployment.NETHERMIND_OWNER);
            INethermindOwnerActions(c.nethermindVerifier).applyAllowlistUpdates(args);

            Sent memory s = _send(c, dest, 1 ether, recipient, "", _defaultArgs());
            assertFalse(s.ok, "G-1: a sender outside the allowlist sent");
            assertTrue(_contains(s.err, bytes4(keccak256("SenderNotAllowed(address)"))), "G-1: reason");

            deal(c.token, favoured, 1 ether, c.selector != DualCcvDeployment.SEPOLIA);
            s = _sendFrom(c, dest, favoured, 1 ether, recipient, "", _defaultArgs());
            assertTrue(s.ok, "G-1: the allowlisted sender did not send");
        }
    }

    /// @notice The fee configuration alone makes a send cost up to $655.35 more, or impossible where the OnRamp
    /// limit per message is lower than that.
    function test_G02_nethermind_owner_can_price_sending_out() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            Client.EVM2AnyMessage memory m = _message(c.token, 1 ether, recipient, "", _defaultArgs());
            uint256 feeBefore = IRouterLive(c.router).getFee(dest, m);
            vm.prank(DualCcvDeployment.NETHERMIND_OWNER);
            INethermindOwnerActions(c.nethermindVerifier).setFeeConfig(
                dest, INethermindVerifier.BpsFeeConfig({feeBps: 10_000, minFeeUSDCents: 65_535, capUSDCents: 65_535, enabled: true})
            );
            try IRouterLive(c.router).getFee(dest, m) returns (uint256 feeAfter) {
                assertGt(feeAfter, feeBefore, "G-2: fee did not grow");
                _note("G-2", string.concat(c.name, " -> ", DualCcvDeployment.bySelector(dest).name, ": fee multiplied by ", vm.toString(feeAfter / feeBefore)));
            } catch (bytes memory err) {
                assertEq(_selector(err), bytes4(keccak256("FeeExceedsMaxAllowed(uint256,uint32)")), "G-2: reason");
                _note("G-2", string.concat(c.name, " -> ", DualCcvDeployment.bySelector(dest).name, ": sending impossible, fee above the OnRamp limit"));
            }
        }
    }

    /// @notice Removing the outbound mapping in the resolver stops every wstETH send on that route.
    function test_G03_nethermind_owner_can_stop_sending() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            INethermindOwnerActions.OutboundImplementationArgs[] memory args = new INethermindOwnerActions.OutboundImplementationArgs[](1);
            args[0] = INethermindOwnerActions.OutboundImplementationArgs({destChainSelector: dest, verifier: address(0)});
            vm.prank(DualCcvDeployment.NETHERMIND_OWNER);
            INethermindOwnerActions(NM).applyOutboundImplementationUpdates(args);
            Sent memory s = _send(c, dest, 1 ether, recipient, "", _defaultArgs());
            assertFalse(s.ok, "G-3: sent without an outbound Nethermind verifier");
            _note("G-3", string.concat(c.name, ": send rejected: ", vm.toString(_first(s.err, 4))));
        }
    }

    // ═════════════════════════ E: delivery of messages created on the fork ═════════════════════════

    function test_E01_E06_round_trip_with_contract_receiver() public {
        for (uint256 spoke = 1; spoke <= 2; ++spoke) {
            DualCcvDeployment.Chain memory hub = _select(0);
            DualCcvDeployment.Chain memory s = DualCcvDeployment.get(spoke);
            uint256 amount = 7 ether;
            address lockBox = DualCcvDeployment.lockBox(s.selector);
            uint256 lockedBefore = IBalance(hub.token).balanceOf(lockBox);

            // Receiver on the spoke is a contract that does not implement ccipReceive.
            vm.selectFork(forkOf[s.selector]);
            address vault = address(new MockCCV());
            uint256 supplyBefore = IBalance(s.token).totalSupply();

            vm.selectFork(forkOf[hub.selector]);
            Sent memory out = _send(hub, s.selector, amount, vault, "", _defaultArgs());
            assertTrue(out.ok, "hub send");
            _assertSucceeded(_deliverFrom(out.encodedMessage), "E-1 delivery to a contract");
            assertEq(IBalance(s.token).balanceOf(vault), amount, "E-1: contract receiver balance");
            // E-6: what the lane's lockbox holds more equals what the spoke supply grew by.
            assertEq(IBalance(s.token).totalSupply() - supplyBefore, amount, "E-6: spoke supply");
            vm.selectFork(forkOf[hub.selector]);
            assertEq(IBalance(hub.token).balanceOf(lockBox) - lockedBefore, amount, "E-6: lockbox");

            // Back: the contract sends the tokens home.
            vm.selectFork(forkOf[s.selector]);
            Sent memory back = _sendFrom(s, hub.selector, vault, amount, recipient, "", _defaultArgs());
            assertTrue(back.ok, "spoke send");
            assertEq(IBalance(s.token).totalSupply(), supplyBefore, "E-6: spoke supply after return");
            vm.selectFork(forkOf[hub.selector]);
            uint256 recipientBefore = IBalance(hub.token).balanceOf(recipient);
            _assertSucceeded(_deliverFrom(back.encodedMessage), "E-1 return delivery");
            assertEq(IBalance(hub.token).balanceOf(recipient) - recipientBefore, amount, "return amount");
            assertEq(IBalance(hub.token).balanceOf(lockBox), lockedBefore, "E-6: lockbox after return");
        }
    }

    function test_E02_inbound_rate_limit() public {
        for (uint256 spoke = 1; spoke <= 2; ++spoke) {
            DualCcvDeployment.Chain memory hub = _select(0);
            DualCcvDeployment.Chain memory s = DualCcvDeployment.get(spoke);
            // Two sends of 300: together above the inbound capacity of 500. The source limit refills in between.
            Sent memory first = _send(hub, s.selector, 300 ether, recipient, "", _defaultArgs());
            vm.warp(block.timestamp + 2 days);
            Sent memory second = _send(hub, s.selector, 300 ether, recipient, "", _defaultArgs());
            assertTrue(first.ok && second.ok, "sends");

            _assertSucceeded(_deliverFrom(first.encodedMessage), "E-2 first");
            Outcome memory o = _deliverFrom(second.encodedMessage);
            _assertFailed(o, TOKEN_HANDLING_ERROR, "E-2 second, above the inbound limit");
            assertTrue(_contains(o.returnData, TOKEN_RATE_LIMIT_REACHED), "E-2: reason");
            assertEq(IBalance(s.token).balanceOf(recipient), 300 ether, "E-2: balance after the refused delivery");

            vm.warp(block.timestamp + 2 days);
            _assertSucceeded(_deliverFrom(second.encodedMessage), "E-2 second after refill");
            assertEq(IBalance(s.token).balanceOf(recipient), 600 ether, "E-2: balance after refill");
        }
    }

    function test_E03_delivery_in_reverse_order() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            address destToken = DualCcvDeployment.bySelector(dest).token;
            vm.selectFork(forkOf[dest]);
            uint256 before = IBalance(destToken).balanceOf(recipient);
            vm.selectFork(forkOf[c.selector]);
            bytes[] memory messages = new bytes[](10);
            for (uint256 i = 0; i < 10; ++i) {
                Sent memory s = _send(c, dest, 1 ether, recipient, "", _defaultArgs());
                assertTrue(s.ok, "send");
                messages[i] = s.encodedMessage;
            }
            for (uint256 i = 10; i > 0; --i) {
                vm.selectFork(forkOf[c.selector]);
                _assertSucceeded(_deliverFrom(messages[i - 1]), "E-3 reverse order");
            }
            assertEq(IBalance(destToken).balanceOf(recipient) - before, 10 ether, "E-3: delivered amount");
        }
    }

    /// @notice E-4 and E-5: a committee signature set that does not meet the rule of the message's source chain.
    function test_E04_E05_wrong_or_incomplete_committee() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            Sent memory s = _send(c, dest, 1 ether, recipient, "", _defaultArgs());
            assertTrue(s.ok, "send");
            DualCcvDeployment.Chain memory d = DualCcvDeployment.bySelector(dest);
            vm.selectFork(forkOf[dest]);
            _replaceCommittees(d, c.selector);
            bytes memory chainlinkProof = _committeeProof(DualCcvDeployment.CHAINLINK_TAG, s.messageId, _keys(CL_KEY));
            address offRamp = address(bytes20(_decode(s.encodedMessage).offRampAddress));

            // E-4: keys that form the committee of another source chain only.
            _setSigners(d.nethermindVerifier, 4949039107694359620, _keys(0x3001, 0x3002), 2);
            _refuse(offRamp, s, chainlinkProof, _keys(0x3001, 0x3002), UNAUTHORIZED_SIGNER, "E-4 committee of another source chain");
            // E-5: one committee member plus an outsider, then one member alone.
            _refuse(offRamp, s, chainlinkProof, _keys(NM_KEY_1, 0x3001), UNAUTHORIZED_SIGNER, "E-5 one member and an outsider");
            _refuse(offRamp, s, chainlinkProof, _keys(NM_KEY_1), WRONG_NUMBER_OF_SIGNATURES, "E-5 one member alone");

            _assertSucceeded(_deliver(s.encodedMessage), "E-4/E-5: the full committee still delivers");
        }
    }

    /// @notice Not in the plan. Both committees sign a message that claims the wstETH destination token but comes
    /// from another source pool: the destination pool refuses it. CCV approval does not replace the pool's own
    /// check of where the message comes from.
    function test_E07_signed_message_from_a_foreign_pool_is_refused() public {
        for (uint256 r = 0; r < 4; ++r) {
            (DualCcvDeployment.Chain memory c, uint64 dest) = _route(r);
            Sent memory s = _send(c, dest, 1 ether, recipient, "", _defaultArgs());
            assertTrue(s.ok, "send");
            MessageV1Codec.MessageV1 memory m = _decode(s.encodedMessage);
            m.tokenTransfer[0].sourcePoolAddress = abi.encode(makeAddr("foreignPool"));
            m.tokenTransfer[0].amount = 100 ether;
            vm.selectFork(forkOf[dest]);
            Outcome memory o = _deliver(_encode(m));
            _assertFailed(o, TOKEN_HANDLING_ERROR, "E-7 foreign source pool");
            assertTrue(_contains(o.returnData, INVALID_SOURCE_POOL), "E-7: reason");
            assertEq(IBalance(DualCcvDeployment.bySelector(dest).token).balanceOf(recipient), 0, "E-7: tokens moved");
        }
    }

    /// @notice Not in the plan. A fully signed withdrawal larger than what its lane locked is refused even though
    /// the other lane's lockbox holds enough: the two spokes cannot draw on each other's collateral.
    function test_E08_withdrawal_cannot_draw_on_the_other_lane_mantle() public {
        _withdrawalAboveCollateral(1, 2);
    }

    function test_E08_withdrawal_cannot_draw_on_the_other_lane_base() public {
        _withdrawalAboveCollateral(2, 1);
    }

    function _withdrawalAboveCollateral(uint256 spoke, uint256 otherSpoke) internal {
        DualCcvDeployment.Chain memory hub = _select(0);
        DualCcvDeployment.Chain memory s = DualCcvDeployment.get(spoke);
        address otherLockBox = DualCcvDeployment.lockBox(DualCcvDeployment.get(otherSpoke).selector);
        // Give the other lane ample collateral through a genuine deposit.
        Sent memory fund = _send(hub, DualCcvDeployment.get(otherSpoke).selector, 200 ether, recipient, "", _defaultArgs());
        assertTrue(fund.ok, "funding deposit");
        uint256 amount = IBalance(hub.token).balanceOf(DualCcvDeployment.lockBox(s.selector)) + 50 ether;
        uint256 otherLocked = IBalance(hub.token).balanceOf(otherLockBox);
        assertGe(otherLocked, amount, "other lockbox holds enough");

        vm.selectFork(forkOf[s.selector]);
        Sent memory back = _send(s, hub.selector, amount, recipient, "", _defaultArgs());
        assertTrue(back.ok, "spoke send");
        vm.selectFork(forkOf[hub.selector]);
        uint256 recipientBefore = IBalance(hub.token).balanceOf(recipient);
        Outcome memory o = _deliverFrom(back.encodedMessage);
        _assertFailed(o, TOKEN_HANDLING_ERROR, "E-8 withdrawal above the lane's collateral");
        assertEq(IBalance(hub.token).balanceOf(recipient), recipientBefore, "E-8: tokens moved");
        assertEq(IBalance(hub.token).balanceOf(otherLockBox), otherLocked, "E-8: other lockbox touched");
    }

    // ═════════════════════════ helpers ═════════════════════════

    function _select(uint256 index) internal returns (DualCcvDeployment.Chain memory c) {
        c = DualCcvDeployment.get(index);
        vm.selectFork(forkOf[c.selector]);
    }

    /// @dev The four routes: Sepolia → Mantle, Sepolia → Base, Mantle → Sepolia, Base → Sepolia. Selects the source fork.
    function _route(uint256 r) internal returns (DualCcvDeployment.Chain memory c, uint64 dest) {
        if (r == 0) return (_select(0), DualCcvDeployment.MANTLE);
        if (r == 1) return (_select(0), DualCcvDeployment.BASE);
        if (r == 2) return (_select(1), DualCcvDeployment.SEPOLIA);
        return (_select(2), DualCcvDeployment.SEPOLIA);
    }

    function _assertBothPaid(OnRamp.Receipt[] memory receipts, string memory label) internal pure {
        bool nethermind;
        bool chainlink;
        for (uint256 i = 0; i < receipts.length; ++i) {
            if (receipts[i].issuer == NM) nethermind = true;
            if (receipts[i].issuer == CL) chainlink = true;
        }
        assertTrue(nethermind, string.concat(label, ": no Nethermind receipt"));
        assertTrue(chainlink, string.concat(label, ": no Chainlink receipt"));
    }

    function _assertPair(address[] memory ccvs, string memory label) internal pure {
        assertEq(ccvs.length, 2, string.concat(label, ": number of CCVs"));
        assertTrue((ccvs[0] == NM && ccvs[1] == CL) || (ccvs[0] == CL && ccvs[1] == NM), string.concat(label, ": not the two resolvers"));
    }

    /// @dev What the source side holds for a lane: the lockbox balance on Sepolia, the supply on a spoke.
    function _held(DualCcvDeployment.Chain memory c, uint64 dest) internal view returns (uint256) {
        if (c.selector == DualCcvDeployment.SEPOLIA) return IBalance(c.token).balanceOf(DualCcvDeployment.lockBox(dest));
        return IBalance(c.token).totalSupply();
    }

    /// @dev The extraArgs of the live test transfers: EVMExtraArgsV2, gas limit 0, out-of-order execution allowed.
    function _defaultArgs() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes4(0x181dcf10), abi.encode(uint256(0), true));
    }

    function _message(address token, uint256 amount, address to, bytes memory data, bytes memory extraArgs)
        internal
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
        ta[0] = Client.EVMTokenAmount({token: token, amount: amount});
        return Client.EVM2AnyMessage({receiver: abi.encode(to), data: data, tokenAmounts: ta, feeToken: address(0), extraArgs: extraArgs});
    }

    function _send(DualCcvDeployment.Chain memory c, uint64 dest, uint256 amount, address to, bytes memory data, bytes memory extraArgs)
        internal
        returns (Sent memory)
    {
        _fund(c, amount);
        return _sendFrom(c, dest, user, amount, to, data, extraArgs);
    }

    /// @dev Gives `user` tokens on the selected fork. On a spoke the supply is adjusted too: the pool burns what is sent.
    function _fund(DualCcvDeployment.Chain memory c, uint256 amount) internal {
        deal(c.token, user, IBalance(c.token).balanceOf(user) + amount, c.selector != DualCcvDeployment.SEPOLIA);
    }

    /// @dev A genuine send through the deployed Router and OnRamp on the selected fork. Never reverts: a refusal
    /// by `getFee` or `ccipSend` is returned in `err`.
    function _sendFrom(
        DualCcvDeployment.Chain memory c,
        uint64 dest,
        address from,
        uint256 amount,
        address to,
        bytes memory data,
        bytes memory extraArgs
    ) internal returns (Sent memory s) {
        Client.EVM2AnyMessage memory m = _message(c.token, amount, to, data, extraArgs);
        try IRouterLive(c.router).getFee(dest, m) returns (uint256 fee) {
            s.fee = fee;
        } catch (bytes memory err) {
            s.err = err;
            return s;
        }
        vm.deal(from, from.balance + s.fee);
        vm.prank(from);
        IERC20(c.token).approve(c.router, amount);
        address onRamp = IRouterLive(c.router).getOnRamp(dest);
        vm.recordLogs();
        vm.prank(from);
        try IRouterLive(c.router).ccipSend{value: s.fee}(dest, m) returns (bytes32 messageId) {
            s.ok = true;
            s.messageId = messageId;
        } catch (bytes memory err) {
            s.err = err;
            return s;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == onRamp && logs[i].topics.length > 0 && logs[i].topics[0] == CCIP_MESSAGE_SENT_SIG) {
                (,, s.encodedMessage, s.receipts,) = abi.decode(logs[i].data, (address, uint256, bytes, OnRamp.Receipt[], bytes[]));
                return s;
            }
        }
        revert("CCIPMessageSent not found");
    }

    /// @dev Acts as both verifier owners on the selected (destination) fork, once per source chain.
    function _replaceCommittees(DualCcvDeployment.Chain memory d, uint64 source) internal {
        if (committeesReplaced[d.selector][source]) return;
        committeesReplaced[d.selector][source] = true;
        _setSigners(d.nethermindVerifier, source, _keys(NM_KEY_1, NM_KEY_2), 2);
        _setSigners(d.chainlinkVerifier, source, _keys(CL_KEY), 1);
    }

    /// @dev Delivers on the selected fork, which must be the message's destination, with both test committees.
    function _deliver(bytes memory encodedMessage) internal returns (Outcome memory) {
        MessageV1Codec.MessageV1 memory m = _decode(encodedMessage);
        DualCcvDeployment.Chain memory d = DualCcvDeployment.bySelector(m.destChainSelector);
        _replaceCommittees(d, m.sourceChainSelector);
        bytes32 id = keccak256(encodedMessage);
        (address[] memory ccvs, bytes[] memory proofs) = _pair(
            CL,
            _committeeProof(DualCcvDeployment.CHAINLINK_TAG, id, _keys(CL_KEY)),
            NM,
            _committeeProof(DualCcvDeployment.NETHERMIND_TAG, id, _keys(NM_KEY_1, NM_KEY_2))
        );
        return _execute(address(bytes20(m.offRampAddress)), encodedMessage, ccvs, proofs);
    }

    /// @dev Switches to the destination fork of the message and delivers.
    function _deliverFrom(bytes memory encodedMessage) internal returns (Outcome memory) {
        vm.selectFork(forkOf[_decode(encodedMessage).destChainSelector]);
        return _deliver(encodedMessage);
    }

    function _refuse(
        address offRamp,
        Sent memory s,
        bytes memory chainlinkProof,
        uint256[] memory nethermindKeys,
        bytes4 reason,
        string memory label
    ) internal {
        (address[] memory ccvs, bytes[] memory proofs) =
            _pair(CL, chainlinkProof, NM, _committeeProof(DualCcvDeployment.NETHERMIND_TAG, s.messageId, nethermindKeys));
        Outcome memory o = _execute(offRamp, s.encodedMessage, ccvs, proofs);
        if (o.reverted) {
            // A second failing call on the same message reverts and carries the inner reason.
            assertEq(o.revertSelector, NO_STATE_PROGRESS, string.concat(label, ": revert"));
            assertTrue(_contains(o.revertData, reason), string.concat(label, ": reason"));
        } else {
            _assertFailed(o, reason, label);
        }
    }

    function _first(bytes memory data, uint256 n) internal pure returns (bytes memory out) {
        if (data.length < n) return data;
        out = new bytes(n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = data[i];
        }
    }
}

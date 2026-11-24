// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {MessageV1Codec} from "@chainlink/contracts-ccip/libraries/MessageV1Codec.sol";

import {DualCcvFixtures} from "./DualCcvFixtures.sol";

interface IOffRampReplay {
    function execute(bytes calldata encodedMessage, address[] calldata ccvs, bytes[] calldata verifierResults, uint32 gasLimit)
        external;
    function getExecutionState(bytes32 messageId) external view returns (uint8);
    function getCCVsForMessage(bytes calldata encodedMessage)
        external
        view
        returns (address[] memory requiredCCVs, address[] memory optionalCCVs, uint8 threshold);
}

interface IBalance {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IOwned {
    function owner() external view returns (address);
}

interface IHooksCcv {
    struct CCVConfigArg {
        uint64 remoteChainSelector;
        address[] outboundCCVs;
        address[] thresholdOutboundCCVs;
        address[] inboundCCVs;
        address[] thresholdInboundCCVs;
    }

    struct RemoteLane {
        uint64 remoteChainSelector;
        uint8 direction; // 0 outbound, 1 inbound (IPausableAdvancedPoolHooks.Direction)
    }

    function getAllCCVConfigs() external view returns (CCVConfigArg[] memory);
    function applyCCVConfigUpdates(CCVConfigArg[] calldata args) external;
    function getThresholdAmount() external view returns (uint256);
    function paused() external view returns (bool);
    function pauseCrossChainTransfers() external;
    function unpauseCrossChainTransfers() external;
    function pauseRemoteLanes(RemoteLane[] calldata lanes) external;
}

interface ICommitteeVerifier {
    struct SignatureConfig {
        uint64 sourceChainSelector;
        uint8 threshold;
        address[] signers;
    }

    function getSignatureConfig(uint64 sourceChainSelector) external view returns (address[] memory signers, uint8 threshold);
    function applySignatureConfigs(uint64[] calldata toRemove, SignatureConfig[] calldata configs) external;
    function getAllowedFinalityConfig() external view returns (bytes4);
    function versionTag() external view returns (bytes4);
}

interface IVerifierResolver {
    struct InboundImplementationArgs {
        bytes4 version;
        address verifier;
    }

    struct OutboundImplementationArgs {
        uint64 destChainSelector;
        address verifier;
    }

    function getInboundImplementation(bytes calldata verifierResults) external view returns (address);
    function getAllInboundImplementations() external view returns (InboundImplementationArgs[] memory);
    function getAllOutboundImplementations() external view returns (OutboundImplementationArgs[] memory);
    function applyInboundImplementationUpdates(InboundImplementationArgs[] calldata args) external;
}

/// @notice The public testnet deployment after the switch of 2026-11-18 (docs/NETHERMIND-CCV-SWITCH-2026-11-18.md).
/// Values that the tests compare the live state against are constants here on purpose: a change on-chain must
/// make a test fail, not silently move the expectation.
library DualCcvDeployment {
    address internal constant NETHERMIND_RESOLVER = 0x28ceF597339bb0B351ae4e62f73d762c9cC51D5c;
    address internal constant CHAINLINK_RESOLVER = 0x8f3ee3c77D2B27c32306a89D367654F959Db223D;
    bytes4 internal constant NETHERMIND_TAG = 0x00010002;
    bytes4 internal constant CHAINLINK_TAG = 0xe9a05a20;
    bytes4 internal constant DUMMY_TAG = 0xdecafbad;

    address internal constant NETHERMIND_OWNER = 0x36243b8B92b1a0F6C92a69a32aE1F8dC183788A5;
    address internal constant NETHERMIND_SIGNER_1 = 0x2fb64E058fDF73Da1B39063Dc64F9f0863005B67;
    address internal constant NETHERMIND_SIGNER_2 = 0xaEE7D7E9748d8a2Ee598a4642634B9eC97a64f53;
    bytes32 internal constant RESOLVER_CODE_HASH = 0x575b65b0346568412549f6fc765374865805ad6a57ada25489d2b695ceb2cbfc;

    uint64 internal constant SEPOLIA = 16015286601757825753;
    uint64 internal constant MANTLE = 8236463271206331221;
    uint64 internal constant BASE = 10344971235874465080;

    uint256 internal constant COUNT = 3;

    struct Chain {
        string name;
        string rpcEnv;
        uint64 selector;
        address token;
        address pool;
        address hooks;
        address router;
        address oldResolver; // the retired local resolver that served the dummy verifier
        address nethermindVerifier;
        bytes32 nethermindVerifierCodeHash;
        address chainlinkVerifier;
        address priceAdapter; // the adapter the Nethermind verifier prices wstETH with
    }

    function get(uint256 index) internal pure returns (Chain memory) {
        if (index == 0) {
            return Chain({
                name: "sepolia",
                rpcEnv: "RPC_SEPOLIA",
                selector: SEPOLIA,
                token: 0xEA7dE76a0965696a13ee41AD222978398be27278,
                pool: 0x90Bd1BA45b6fB0A6CF7397EC62a6fd2017925033,
                hooks: 0x93d9772F228F7c6C677A3Aca76CFec5636648dE9,
                router: 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59,
                oldResolver: 0xac4684527386209f289434E84879499dE45B71b9,
                nethermindVerifier: 0x3FD15Ac39a06850c06563eAc511968229111635C,
                nethermindVerifierCodeHash: 0x1f12f50bfd31caac032f93e0e2e43ee4856a06b1655a761f420ec500a571d444,
                chainlinkVerifier: 0x5295455B4fD7010DB3729456f2C33ca8f2c2BF1d,
                priceAdapter: 0xDc6de941468Fb6884A4A5497A09de0eD81E68124
            });
        }
        if (index == 1) {
            return Chain({
                name: "mantle_sepolia",
                rpcEnv: "RPC_MANTLE_SEPOLIA",
                selector: MANTLE,
                token: 0x0625b02671d6Aa31844175779527D49d119DAfE0,
                pool: 0xEa207062B60bB2b34402C8807B06CcDb3ee35D50,
                hooks: 0x174F4240C8605f2CCf5D9979F75595Cc7e6510a0,
                router: 0xFd33fd627017fEf041445FC19a2B6521C9778f86,
                oldResolver: 0x1Ac7265B69402AFf447A1397D608f687C3F1b11F,
                nethermindVerifier: 0x3FD15Ac39a06850c06563eAc511968229111635C,
                nethermindVerifierCodeHash: 0x57d31c6ff3a42e331021ff47326c53967c62f3ce625085e3d077ffcfc7cdbb42,
                chainlinkVerifier: 0x5Ec7F9e1b74D3ee88ABfe58C41445eb92B7c3969,
                priceAdapter: 0x20F24F29300025d7a8B0dA4dcB0012c3f4D9BE9F
            });
        }
        return Chain({
            name: "base_sepolia",
            rpcEnv: "RPC_BASE_SEPOLIA",
            selector: BASE,
            token: 0x33C71c79d1A4A1D065865B6a7DB87Ed2FD5DF86e,
            pool: 0x4b44164848e9D39BB128Ca404fbCC846120c0F6b,
            hooks: 0x1fbb35e57c6937dd7EADD3f0749D494E53666D12,
            router: 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93,
            oldResolver: 0xAAC40536b69c72db395859248Afe30e74c447670,
            nethermindVerifier: 0xF80D2Ccf5F7180F6D837B3EB774e5eC59a83Db32,
            nethermindVerifierCodeHash: 0x87c64ff6c1dcd17fc1d941276dcfde759066233f93fea3a390b5a85bf4c39230,
            chainlinkVerifier: 0xEdB3Af523b8e348B8c12218d47bA8FfBeeD967ea,
            priceAdapter: 0x3FD15Ac39a06850c06563eAc511968229111635C
        });
    }

    function bySelector(uint64 selector) internal pure returns (Chain memory) {
        if (selector == SEPOLIA) return get(0);
        if (selector == MANTLE) return get(1);
        if (selector == BASE) return get(2);
        revert("unknown chain selector");
    }

    function byRpcEnv(string memory rpcEnv) internal pure returns (Chain memory) {
        for (uint256 i = 0; i < COUNT; ++i) {
            Chain memory c = get(i);
            if (keccak256(bytes(c.rpcEnv)) == keccak256(bytes(rpcEnv))) return c;
        }
        revert("unknown rpc env");
    }

    /// @dev Sepolia lockbox of a spoke lane.
    function lockBox(uint64 spokeSelector) internal pure returns (address) {
        if (spokeSelector == MANTLE) return 0xD3621826b34BC7eFaB3AeA766d8D0A341C5d4fe0;
        if (spokeSelector == BASE) return 0x1763971bC9dD5Af58a37Fa1048205EaE9A05e9d5;
        revert("no lockbox for selector");
    }
}

/// @notice Shared helpers of the dual-CCV tests: one execute call with its exact outcome, proof building,
/// message re-encoding, and the hooks operations of the Lido timelock.
abstract contract DualCcvBase is Test {
    uint8 internal constant UNTOUCHED = 0;
    uint8 internal constant SUCCESS = 2;
    uint8 internal constant FAILURE = 3;

    // OffRamp 2.0.0
    bytes4 internal constant REQUIRED_CCV_MISSING = bytes4(keccak256("RequiredCCVMissing(address)"));
    bytes4 internal constant INBOUND_IMPL_NOT_FOUND = bytes4(keccak256("InboundImplementationNotFound(address,bytes)"));
    bytes4 internal constant ALREADY_EXECUTED = bytes4(keccak256("SkippedAlreadyExecutedMessage(bytes32,uint64,uint64)"));
    bytes4 internal constant NO_STATE_PROGRESS = bytes4(keccak256("NoStateProgressMade(bytes32,bytes)"));
    bytes4 internal constant INVALID_OFF_RAMP = bytes4(keccak256("InvalidOffRamp(address,bytes)"));
    bytes4 internal constant TOKEN_HANDLING_ERROR = bytes4(keccak256("TokenHandlingError(address,bytes)"));
    // CommitteeVerifier 2.0.0 / SignatureQuorumValidator
    bytes4 internal constant UNAUTHORIZED_SIGNER = bytes4(keccak256("UnauthorizedSigner()"));
    bytes4 internal constant NON_ORDERED_SIGNATURES = bytes4(keccak256("NonOrderedOrNonUniqueSignatures()"));
    bytes4 internal constant WRONG_NUMBER_OF_SIGNATURES = bytes4(keccak256("WrongNumberOfSignatures()"));
    bytes4 internal constant INVALID_VERIFIER_RESULTS = bytes4(keccak256("InvalidVerifierResults()"));
    bytes4 internal constant INVALID_CCV_VERSION = bytes4(keccak256("InvalidCCVVersion(bytes4)"));
    bytes4 internal constant SOURCE_NOT_CONFIGURED = bytes4(keccak256("SourceNotConfigured(uint64)"));
    // Pool, hooks, rate limiter
    bytes4 internal constant ENFORCED_PAUSE = bytes4(keccak256("EnforcedPause()"));
    bytes4 internal constant INVALID_SOURCE_POOL = bytes4(keccak256("InvalidSourcePoolAddress(bytes)"));
    bytes4 internal constant TOKEN_MAX_CAPACITY_EXCEEDED = bytes4(keccak256("TokenMaxCapacityExceeded(uint256,uint256,address)"));
    bytes4 internal constant TOKEN_RATE_LIMIT_REACHED = bytes4(keccak256("TokenRateLimitReached(uint256,uint256,address)"));

    bytes32 internal constant EXECUTION_STATE_CHANGED_SIG = keccak256("ExecutionStateChanged(uint64,uint64,bytes32,uint8,bytes)");
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @dev What one `OffRamp.execute` call did. Either the call reverted (`reverted`, `revertSelector`), or it
    /// returned and recorded a state with a reason (`state`, `reason`, `returnData`).
    struct Outcome {
        bool reverted;
        bytes4 revertSelector;
        bytes revertData;
        uint8 state;
        bytes4 reason;
        bytes returnData;
    }

    function _execute(address offRamp, bytes memory encodedMessage, address[] memory ccvs, bytes[] memory proofs)
        internal
        returns (Outcome memory o)
    {
        bytes32 messageId = keccak256(encodedMessage);
        vm.recordLogs();
        try IOffRampReplay(offRamp).execute(encodedMessage, ccvs, proofs, 0) {}
        catch (bytes memory err) {
            o.reverted = true;
            o.revertData = err;
            o.revertSelector = _selector(err);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == offRamp && logs[i].topics.length == 4 && logs[i].topics[0] == EXECUTION_STATE_CHANGED_SIG
                    && logs[i].topics[3] == messageId
            ) {
                (, o.returnData) = abi.decode(logs[i].data, (uint8, bytes));
                o.reason = _selector(o.returnData);
            }
        }
        o.state = IOffRampReplay(offRamp).getExecutionState(messageId);
    }

    function _selector(bytes memory data) internal pure returns (bytes4 s) {
        if (data.length < 4) return bytes4(0);
        assembly {
            s := mload(add(data, 0x20))
        }
    }

    /// @dev True if `needle` occurs anywhere in `data`: the OffRamp wraps pool errors and truncates them.
    function _contains(bytes memory data, bytes4 needle) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; ++i) {
            if (data[i] == needle[0] && data[i + 1] == needle[1] && data[i + 2] == needle[2] && data[i + 3] == needle[3]) {
                return true;
            }
        }
        return false;
    }

    function _assertFailed(Outcome memory o, bytes4 reason, string memory label) internal pure {
        assertFalse(o.reverted, string.concat(label, ": call reverted, expected a recorded FAILURE"));
        assertEq(o.state, FAILURE, string.concat(label, ": state"));
        assertEq(o.reason, reason, string.concat(label, ": failure reason"));
    }

    function _assertSucceeded(Outcome memory o, string memory label) internal pure {
        assertFalse(o.reverted, string.concat(label, ": call reverted"));
        assertEq(o.state, SUCCESS, string.concat(label, ": state"));
    }

    // ───────────────────────── proofs ─────────────────────────

    function _pair(address a, bytes memory pa, address b, bytes memory pb)
        internal
        pure
        returns (address[] memory ccvs, bytes[] memory proofs)
    {
        ccvs = new address[](2);
        proofs = new bytes[](2);
        ccvs[0] = a;
        proofs[0] = pa;
        ccvs[1] = b;
        proofs[1] = pb;
    }

    function _single(address a, bytes memory pa) internal pure returns (address[] memory ccvs, bytes[] memory proofs) {
        ccvs = new address[](1);
        proofs = new bytes[](1);
        ccvs[0] = a;
        proofs[0] = pa;
    }

    function _both(DualCcvFixtures.Fixture memory f) internal pure returns (address[] memory, bytes[] memory) {
        return _pair(DualCcvFixtures.CHAINLINK_RESOLVER, f.chainlinkProof, DualCcvFixtures.NETHERMIND_RESOLVER, f.nethermindProof);
    }

    /// @dev A committee proof as CommitteeVerifier expects it: tag, uint16 length, 64-byte signatures with v = 27,
    /// ordered by signer address.
    function _committeeProof(bytes4 tag, bytes32 messageId, uint256[] memory keys) internal pure returns (bytes memory) {
        for (uint256 i = 0; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
            }
        }
        bytes32 signedHash = keccak256(bytes.concat(tag, messageId));
        bytes memory signatures;
        for (uint256 i = 0; i < keys.length; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], signedHash);
            if (v == 28) s = bytes32(SECP256K1_N - uint256(s));
            signatures = bytes.concat(signatures, r, s);
        }
        return abi.encodePacked(tag, uint16(signatures.length), signatures);
    }

    function _keys(uint256 a) internal pure returns (uint256[] memory k) {
        k = new uint256[](1);
        k[0] = a;
    }

    function _keys(uint256 a, uint256 b) internal pure returns (uint256[] memory k) {
        k = new uint256[](2);
        k[0] = a;
        k[1] = b;
    }

    /// @dev Acts as the verifier owner: replaces the committee of one source chain.
    function _setSigners(address verifier, uint64 sourceSelector, uint256[] memory keys, uint8 threshold) internal {
        ICommitteeVerifier.SignatureConfig[] memory cfg = new ICommitteeVerifier.SignatureConfig[](1);
        address[] memory signers = new address[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            signers[i] = vm.addr(keys[i]);
        }
        cfg[0] = ICommitteeVerifier.SignatureConfig({sourceChainSelector: sourceSelector, threshold: threshold, signers: signers});
        vm.prank(IOwned(verifier).owner());
        ICommitteeVerifier(verifier).applySignatureConfigs(new uint64[](0), cfg);
    }

    // ───────────────────────── message ─────────────────────────

    function decodeMessage(bytes calldata encoded) external pure returns (MessageV1Codec.MessageV1 memory) {
        return MessageV1Codec._decodeMessageV1(encoded);
    }

    function _decode(bytes memory encoded) internal view returns (MessageV1Codec.MessageV1 memory) {
        return this.decodeMessage(encoded);
    }

    function _encode(MessageV1Codec.MessageV1 memory message) internal pure returns (bytes memory) {
        return MessageV1Codec._encodeMessageV1(message);
    }

    // ───────────────────────── hooks, as their owner (the Lido timelock) ─────────────────────────

    /// @dev Sets the inbound CCV list of one lane and leaves the outbound list as it is.
    function _setInboundCcvs(address hooks, uint64 remoteSelector, address[] memory inbound) internal {
        IHooksCcv.CCVConfigArg[] memory all = IHooksCcv(hooks).getAllCCVConfigs();
        IHooksCcv.CCVConfigArg[] memory update = new IHooksCcv.CCVConfigArg[](1);
        bool found;
        for (uint256 i = 0; i < all.length; ++i) {
            if (all[i].remoteChainSelector == remoteSelector) {
                update[0] = all[i];
                found = true;
            }
        }
        require(found, "lane not configured in hooks");
        update[0].inboundCCVs = inbound;
        vm.prank(IOwned(hooks).owner());
        IHooksCcv(hooks).applyCCVConfigUpdates(update);
    }

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        l[0] = a;
        l[1] = b;
    }

    function _note(string memory id, string memory text) internal pure {
        console2.log(string.concat("[", id, "] ", text));
    }
}

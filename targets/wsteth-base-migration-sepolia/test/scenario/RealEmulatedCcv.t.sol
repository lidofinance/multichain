// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {CcvBridgeTest} from "../../../wsteth-ccip-sepolia-mantle-dev/test/scenario/CcvBridge.t.sol";
import {Vm} from "forge-std/Vm.sol";

interface IActivationBridge {
    function activate() external;
    function getActivationTime() external view returns (uint256);
    function isL1ActivationConfirmed() external view returns (bool);
}

interface IActivationMessenger {
    function relayMessage(uint256, address, address, uint256, uint256, bytes calldata) external payable;
}

/// @notice Both verifiers and the 2.0 ramp layer are emulated. This checks quorum enforcement,
/// not the availability of Chainlink or Nethermind services on the public testnet.
contract RealEmulatedCcvTest is CcvBridgeTest {
    struct Confirmation {
        address sender;
        bytes message;
        uint256 nonce;
        uint256 gasLimit;
    }
    /// @dev The CCV round trip starts after migration activation. Keep the real
    /// outbound policy installed: move L1 backing and relay its actual confirmation
    /// through the canonical messenger before activating Base. The lifecycle suite
    /// separately covers the pre-activation gate, L1 veto and failed relay/retry.
    function _setUpCcvForks() internal override {
        super._setUpCcvForks();
        string memory first = vm.readFile("state/l1.json");
        string memory second = vm.readFile(string.concat("state/", l2Chain, ".json"));
        address bridge1 = vm.parseJsonAddress(first, ".legacyBridge");
        address bridge2 = vm.parseJsonAddress(second, ".legacyBridge");
        address messenger1 = vm.parseJsonAddress(first, ".messenger");
        address messenger2 = vm.parseJsonAddress(second, ".messenger");
        vm.selectFork(l1Fork);
        uint256 at = IActivationBridge(bridge1).getActivationTime();
        if (vm.getBlockTimestamp() < at) vm.warp(at);
        vm.recordLogs();
        IActivationBridge(bridge1).activate();
        _relayActivation(messenger1, messenger2, bridge1, bridge2);
        at = IActivationBridge(bridge2).getActivationTime();
        if (vm.getBlockTimestamp() < at) vm.warp(at);
        IActivationBridge(bridge2).activate();
    }

    function _relayActivation(address messenger1, address messenger2, address bridge1, address bridge2) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != messenger1 || log.topics.length != 2 ||
                log.topics[0] != keccak256("SentMessage(address,address,bytes,uint256,uint256)")) continue;
            assertEq(address(uint160(uint256(log.topics[1]))), bridge2);
            Confirmation memory c;
            (c.sender, c.message, c.nonce, c.gasLimit) =
                abi.decode(log.data, (address, bytes, uint256, uint256));
            assertEq(c.sender, bridge1);
            assertEq(c.message, abi.encodeWithSignature("confirmL1Activation()"));
            vm.selectFork(l2Fork);
            address aliased;
            unchecked { aliased = address(uint160(messenger1) + uint160(0x1111000000000000000000000000000000001111)); }
            vm.prank(aliased);
            IActivationMessenger(messenger2).relayMessage(c.nonce, c.sender, bridge2, 0, c.gasLimit, c.message);
            assertTrue(IActivationBridge(bridge2).isL1ActivationConfirmed(), "activation confirmation not delivered");
            return;
        }
        revert("activation confirmation not emitted");
    }
}

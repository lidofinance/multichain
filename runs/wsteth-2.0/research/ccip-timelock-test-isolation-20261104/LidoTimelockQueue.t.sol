// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ILidoTimelock} from "@ccip-lido/interfaces/ILidoTimelock.sol";

interface IQueueTimelock is ILidoTimelock {
    function restartProposalQueue() external;
    function isOperationDone(bytes32 id) external view returns (bool);
    function isOperationReady(bytes32 id) external view returns (bool);
}

contract TimelockQueueTarget {
    uint256 public value;

    function setValue(uint256 next) external {
        value = next;
    }
}

/// @dev Own the two multi-warp regressions here instead of patching CCIP's test suite.
/// Deploy the release artifact, so the test profile does not recompile the timelock.
contract LidoTimelockQueueTest is Test {
    uint256 constant MIN_DELAY = 3 days;
    IQueueTimelock timelock;
    TimelockQueueTarget target;
    address admin = makeAddr("Admin");
    address proposer = makeAddr("Proposer");
    address executor = makeAddr("Executor");
    address halter = makeAddr("Halter");

    function setUp() public {
        timelock = IQueueTimelock(
            deployCode(
                "../../components/ccip/chains/evm/foundry-artifacts/LidoTimelock.sol/LidoTimelock.json",
                abi.encode(
                    MIN_DELAY,
                    uint120(14 days),
                    admin,
                    _single(proposer),
                    _single(executor),
                    _single(makeAddr("Canceller")),
                    _single(makeAddr("Bypasser")),
                    _single(halter)
                )
            )
        );
        target = new TimelockQueueTarget();
    }

    function testDoneProposalRemainsAValidPredecessorAfterRestart() public {
        ILidoTimelock.Call[] memory first = _calls(1);
        bytes32 firstId = _schedule(first, bytes32(0));
        _advanceDelay();
        _execute(first, bytes32(0));

        _haltAndRestart();
        assertTrue(timelock.isOperationDone(firstId));

        ILidoTimelock.Call[] memory second = _calls(2);
        bytes32 secondId = _schedule(second, firstId);
        assertFalse(timelock.isOperationReady(secondId));
        _advanceDelay();
        _execute(second, firstId);
        assertTrue(timelock.isOperationDone(secondId));
        assertEq(target.value(), 2);
    }

    function testInvalidatedPredecessorMustBeReproposedAndExecuted() public {
        ILidoTimelock.Call[] memory first = _calls(1);
        bytes32 firstId = _schedule(first, bytes32(0));
        _haltAndRestart();
        assertFalse(timelock.isOperationPending(firstId));

        ILidoTimelock.Call[] memory second = _calls(2);
        bytes32 secondId = _schedule(second, firstId);
        _advanceDelay();
        assertTrue(timelock.isOperationReady(secondId));
        vm.prank(executor);
        vm.expectRevert("RBACTimelock: missing dependency");
        timelock.executeBatch(second, firstId, bytes32(0));

        assertEq(_schedule(first, bytes32(0)), firstId);
        assertFalse(timelock.isOperationReady(firstId));
        _advanceDelay();
        _execute(first, bytes32(0));
        _execute(second, firstId);
        assertTrue(timelock.isOperationDone(firstId));
        assertTrue(timelock.isOperationDone(secondId));
        assertEq(target.value(), 2);
    }

    function _advanceDelay() internal {
        // Read the cheatcode clock after every warp; the optimizer may reuse block.timestamp.
        vm.warp(vm.getBlockTimestamp() + MIN_DELAY);
    }

    function _haltAndRestart() internal {
        vm.prank(halter);
        timelock.haltProposalQueue();
        vm.prank(admin);
        timelock.restartProposalQueue();
    }

    function _schedule(ILidoTimelock.Call[] memory calls, bytes32 predecessor) internal returns (bytes32) {
        vm.prank(proposer);
        timelock.scheduleBatch(calls, predecessor, bytes32(0), MIN_DELAY);
        return timelock.hashOperationBatch(calls, predecessor, bytes32(0));
    }

    function _execute(ILidoTimelock.Call[] memory calls, bytes32 predecessor) internal {
        vm.prank(executor);
        timelock.executeBatch(calls, predecessor, bytes32(0));
    }

    function _calls(uint256 value) internal view returns (ILidoTimelock.Call[] memory calls) {
        calls = new ILidoTimelock.Call[](1);
        calls[0] = ILidoTimelock.Call(address(target), 0, abi.encodeCall(TimelockQueueTarget.setValue, (value)));
    }

    function _single(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}

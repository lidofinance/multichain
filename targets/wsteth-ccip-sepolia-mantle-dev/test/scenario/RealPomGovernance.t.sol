// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PoolOperationManager} from "@ccip-lido/PoolOperationManager.sol";
import {PausableAdvancedPoolHooks} from "@ccip-lido/PausableAdvancedPoolHooks.sol";
import {BridgeScenarioBase} from "./BridgeScenarioBase.sol";

/// @notice Exercises the updated upstream role separation and timelock on the deployed fork stack.
contract RealPomGovernance is BridgeScenarioBase {
    function setUp() public {
        _setUpForksAndRecord();
    }

    function test_L1IndependentOperationalRoles() public {
        vm.selectFork(l1Fork);
        _independentRoles(l1);
    }

    function test_L2IndependentOperationalRoles() public {
        vm.selectFork(l2Fork);
        _independentRoles(l2);
    }

    function _independentRoles(Ctx storage c) internal {
        PoolOperationManager p = PoolOperationManager(payable(c.pom));
        PausableAdvancedPoolHooks h = PausableAdvancedPoolHooks(c.hooks);
        address queueActor = makeAddr("queueActor");
        address transferActor = makeAddr("transferActor");
        bytes32 queueRole = p.PROPOSAL_QUEUE_HALT_ROLE();
        bytes32 transferRole = p.CROSS_CHAIN_TRANSFERS_PAUSE_ROLE();
        bytes32 unpauseRole = p.CROSS_CHAIN_TRANSFERS_UNPAUSE_ROLE();
        bytes32 restartRole = p.PROPOSAL_QUEUE_RESTART_ROLE();
        vm.startPrank(c.govAdmin);
        p.grantRole(queueRole, queueActor);
        p.grantRole(transferRole, transferActor);
        vm.stopPrank();

        vm.prank(queueActor);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, queueActor, transferRole)
        );
        p.pauseCrossChainTransfers();
        vm.prank(transferActor);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, transferActor, queueRole)
        );
        p.haltProposalQueue();

        uint24 epoch = p.getEpoch();
        vm.prank(transferActor);
        p.pauseCrossChainTransfers();
        assertTrue(h.paused());
        assertFalse(p.paused());
        assertEq(p.getEpoch(), epoch);
        vm.prank(queueActor);
        p.haltProposalQueue();
        assertTrue(p.paused());
        assertTrue(h.paused());
        assertEq(p.getEpoch(), epoch + 1);

        vm.prank(transferActor);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, transferActor, unpauseRole)
        );
        p.unpauseCrossChainTransfers();
        vm.prank(queueActor);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, queueActor, restartRole)
        );
        p.restartProposalQueue();
        vm.prank(c.govAdmin);
        p.restartProposalQueue();
        assertFalse(p.paused());
        assertTrue(h.paused());
        vm.prank(c.govAdmin);
        p.unpauseCrossChainTransfers();
        assertFalse(h.paused());
        assertEq(p.getEpoch(), epoch + 1);
    }

    function test_L1HaltInvalidatesProposalAfterRestart() public {
        vm.selectFork(l1Fork);
        _haltInvalidates(l1);
    }

    function test_L2HaltInvalidatesProposalAfterRestart() public {
        vm.selectFork(l2Fork);
        _haltInvalidates(l2);
    }

    function _haltInvalidates(Ctx storage c) internal {
        PoolOperationManager p = PoolOperationManager(payable(c.pom));
        address proposer = p.getRoleMember(p.PROPOSER_ROLE(), 0);
        bytes memory data = abi.encodeCall(PausableAdvancedPoolHooks.pauseCrossChainTransfers, ());
        uint40 delay = p.getGlobalMinDelay();
        vm.prank(proposer);
        p.propose(c.hooks, 0, data, bytes32(0), bytes32(0), delay);
        vm.prank(c.govAdmin);
        p.haltProposalQueue();
        vm.prank(c.govAdmin);
        p.restartProposalQueue();
        vm.warp(block.timestamp + delay);
        bytes32 id = p.hashOperation(c.hooks, 0, data, bytes32(0), bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                PoolOperationManager.InvalidProposalState.selector,
                id,
                uint256(1) << uint8(PoolOperationManager.ProposalState.Ready)
            )
        );
        p.execute(c.hooks, 0, data, bytes32(0), bytes32(0));
        assertFalse(PausableAdvancedPoolHooks(c.hooks).paused());
    }

    function test_L1HubUnpauseCannotBeQueued() public {
        vm.selectFork(l1Fork);
        PoolOperationManager p = PoolOperationManager(payable(l1.pom));
        bytes memory data = abi.encodeCall(PausableAdvancedPoolHooks.unpauseCrossChainTransfers, ());
        address proposer = p.getRoleMember(p.PROPOSER_ROLE(), 0);
        uint40 delay = p.getGlobalMinDelay();
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(PoolOperationManager.BlockedSelector.selector, bytes4(data)));
        p.propose(l1.hooks, 0, data, bytes32(0), bytes32(0), delay);
    }

    function test_L2SpokeUnpauseRequiresTimelockThenPermissionlessExecution() public {
        vm.selectFork(l2Fork);
        PoolOperationManager p = PoolOperationManager(payable(l2.pom));
        PausableAdvancedPoolHooks h = PausableAdvancedPoolHooks(l2.hooks);
        address proposer = p.getRoleMember(p.PROPOSER_ROLE(), 0);
        bytes memory data = abi.encodeCall(PausableAdvancedPoolHooks.unpauseCrossChainTransfers, ());
        uint40 delay = p.getGlobalMinDelay();
        vm.startPrank(proposer);
        p.pauseCrossChainTransfers();
        bytes32 id = p.propose(l2.hooks, 0, data, bytes32(0), bytes32(0), delay);
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(
                PoolOperationManager.InvalidProposalState.selector,
                id,
                uint256(1) << uint8(PoolOperationManager.ProposalState.Ready)
            )
        );
        p.execute(l2.hooks, 0, data, bytes32(0), bytes32(0));
        assertTrue(h.paused());
        vm.warp(block.timestamp + delay);
        p.execute(l2.hooks, 0, data, bytes32(0), bytes32(0));
        assertFalse(h.paused());
    }
}

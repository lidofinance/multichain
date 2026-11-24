// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {PausableAdvancedPoolHooks} from "@ccip-lido/PausableAdvancedPoolHooks.sol";
import {ILidoTimelock} from "@ccip-lido/interfaces/ILidoTimelock.sol";
import {BridgeScenarioBase} from "./BridgeScenarioBase.sol";

interface IRestartableTimelock {
    function restartProposalQueue() external;
}

/// @title RealTimelockGovernance
/// @notice The governance model the component hands over to, exercised on the deployed fork stack
/// of both chains: Chainlink MCMS proposes through the LidoTimelock, anyone executes a ready
/// proposal through the CallProxy after the minimum delay, Emergency Brakes pause the hooks at once
/// and can halt the proposal queue, the DAO (Agent on L1 / OpExec on L2) acts immediately through
/// the bypass and restarts a halted queue, and the deployment's blocked selectors cannot be queued.
/// Actors and addresses come from the deploy record, never from constants.
contract RealTimelockGovernance is BridgeScenarioBase {
    function setUp() public {
        _setUpForksAndRecord();
    }

    // ── proposal path ────────────────────────────────────────────────────────

    function test_L1ProposalExecutesThroughCallProxyAfterDelay() public {
        vm.selectFork(l1Fork);
        _proposalExecutesAfterDelay(l1);
    }

    function test_L2ProposalExecutesThroughCallProxyAfterDelay() public {
        vm.selectFork(l2Fork);
        _proposalExecutesAfterDelay(l2);
    }

    function _proposalExecutesAfterDelay(Ctx storage c) internal {
        ILidoTimelock timelock = ILidoTimelock(c.timelock);
        PausableAdvancedPoolHooks hooks = PausableAdvancedPoolHooks(c.hooks);
        uint256 delay = timelock.getMinDelay();

        vm.prank(c.emergencyBrakes);
        hooks.pauseCrossChainTransfers();
        assertTrue(hooks.paused());

        ILidoTimelock.Call[] memory calls = _hooksCall(c, abi.encodeCall(hooks.unpauseCrossChainTransfers, ()));
        bytes32 salt = keccak256("unpause");
        vm.prank(c.mcms);
        timelock.scheduleBatch(calls, bytes32(0), salt, delay);
        assertTrue(timelock.isOperationPending(timelock.hashOperationBatch(calls, bytes32(0), salt)));

        address anyone = makeAddr("anyone");
        vm.warp(block.timestamp + delay - 1);
        vm.prank(anyone);
        vm.expectRevert("RBACTimelock: operation is not ready");
        ILidoTimelock(c.callProxy).executeBatch(calls, bytes32(0), salt);

        // Only the CallProxy executes: the timelock's EXECUTOR_ROLE is the proxy, not the caller.
        vm.warp(block.timestamp + 1);
        vm.prank(anyone);
        vm.expectRevert();
        timelock.executeBatch(calls, bytes32(0), salt);

        vm.prank(anyone);
        ILidoTimelock(c.callProxy).executeBatch(calls, bytes32(0), salt);
        assertFalse(hooks.paused());
    }

    // ── halt ─────────────────────────────────────────────────────────────────

    function test_L1HaltInvalidatesPendingProposalUntilRestartAndReproposal() public {
        vm.selectFork(l1Fork);
        _haltInvalidates(l1);
    }

    function test_L2HaltInvalidatesPendingProposalUntilRestartAndReproposal() public {
        vm.selectFork(l2Fork);
        _haltInvalidates(l2);
    }

    function _haltInvalidates(Ctx storage c) internal {
        ILidoTimelock timelock = ILidoTimelock(c.timelock);
        PausableAdvancedPoolHooks hooks = PausableAdvancedPoolHooks(c.hooks);
        uint256 delay = timelock.getMinDelay();
        ILidoTimelock.Call[] memory calls = _hooksCall(c, abi.encodeCall(hooks.pauseCrossChainTransfers, ()));

        bytes32 salt = keccak256("pause-before-halt");
        vm.prank(c.mcms);
        timelock.scheduleBatch(calls, bytes32(0), salt, delay);

        vm.prank(c.emergencyBrakes);
        timelock.haltProposalQueue();
        assertTrue(timelock.isProposalQueueHalted());

        // Nothing can be scheduled or executed while halted.
        vm.prank(c.mcms);
        vm.expectRevert();
        timelock.scheduleBatch(calls, bytes32(0), keccak256("while-halted"), delay);
        vm.warp(block.timestamp + delay);
        vm.expectRevert("RBACTimelock: operation is not ready");
        ILidoTimelock(c.callProxy).executeBatch(calls, bytes32(0), salt);
        assertFalse(hooks.paused());

        // Only the admin restarts; the halted proposal stays dead, a fresh one goes through.
        vm.prank(c.emergencyBrakes);
        vm.expectRevert();
        IRestartableTimelock(c.timelock).restartProposalQueue();
        vm.prank(c.govAdmin);
        IRestartableTimelock(c.timelock).restartProposalQueue();
        assertFalse(timelock.isProposalQueueHalted());
        vm.expectRevert("RBACTimelock: operation is not ready");
        ILidoTimelock(c.callProxy).executeBatch(calls, bytes32(0), salt);

        bytes32 newSalt = keccak256("pause-after-restart");
        vm.prank(c.mcms);
        timelock.scheduleBatch(calls, bytes32(0), newSalt, delay);
        vm.warp(block.timestamp + delay);
        ILidoTimelock(c.callProxy).executeBatch(calls, bytes32(0), newSalt);
        assertTrue(hooks.paused());
    }

    // ── blocked selectors ────────────────────────────────────────────────────

    function test_L1BlockedSelectorsCannotBeScheduled() public {
        vm.selectFork(l1Fork);
        _blockedSelectors(l1);
    }

    function test_L2BlockedSelectorsCannotBeScheduled() public {
        vm.selectFork(l2Fork);
        _blockedSelectors(l2);
    }

    function _blockedSelectors(Ctx storage c) internal {
        ILidoTimelock timelock = ILidoTimelock(c.timelock);
        PausableAdvancedPoolHooks hooks = PausableAdvancedPoolHooks(c.hooks);
        uint256 delay = timelock.getMinDelay();
        bytes32 unpauseRole = hooks.CROSS_CHAIN_TRANSFERS_UNPAUSE_ROLE();

        // Role changes, ownership transfers and upgrades leave the proposal queue entirely: they
        // are the DAO's through the bypass (default_config.json blocked_selectors).
        bytes[] memory blocked = new bytes[](3);
        blocked[0] = abi.encodeCall(hooks.grantRole, (unpauseRole, c.mcms));
        blocked[1] = abi.encodeCall(hooks.revokeRole, (hooks.CROSS_CHAIN_TRANSFERS_PAUSE_ROLE(), c.emergencyBrakes));
        blocked[2] = abi.encodeWithSignature("transferOwnership(address)", c.mcms);
        for (uint256 i; i < blocked.length; i++) {
            vm.prank(c.mcms);
            vm.expectRevert("RBACTimelock: selector is blocked");
            timelock.scheduleBatch(_hooksCall(c, blocked[i]), bytes32(0), keccak256(abi.encode(i)), delay);
        }

        // The same grant is the DAO's immediate call.
        _bypass(c, c.hooks, blocked[0]);
        assertTrue(hooks.hasRole(unpauseRole, c.mcms));
    }

    // ── pause roles ──────────────────────────────────────────────────────────

    function test_L1EmergencyBrakesPauseAndOnlyTheDaoUnpausesAtOnce() public {
        vm.selectFork(l1Fork);
        _pauseRoles(l1);
    }

    function test_L2EmergencyBrakesPauseAndOnlyTheDaoUnpausesAtOnce() public {
        vm.selectFork(l2Fork);
        _pauseRoles(l2);
    }

    function _pauseRoles(Ctx storage c) internal {
        PausableAdvancedPoolHooks hooks = PausableAdvancedPoolHooks(c.hooks);

        vm.prank(c.mcms);
        vm.expectRevert(
            abi.encodeWithSelector(PausableAdvancedPoolHooks.OnlyRoleOrOwner.selector, hooks.CROSS_CHAIN_TRANSFERS_PAUSE_ROLE())
        );
        hooks.pauseCrossChainTransfers();

        vm.prank(c.emergencyBrakes);
        hooks.pauseCrossChainTransfers();
        assertTrue(hooks.paused());

        vm.prank(c.emergencyBrakes);
        vm.expectRevert(
            abi.encodeWithSelector(PausableAdvancedPoolHooks.OnlyRoleOrOwner.selector, hooks.CROSS_CHAIN_TRANSFERS_UNPAUSE_ROLE())
        );
        hooks.unpauseCrossChainTransfers();

        _bypass(c, c.hooks, abi.encodeCall(hooks.unpauseCrossChainTransfers, ()));
        assertFalse(hooks.paused());
    }

    // ── end state of the hand-over ───────────────────────────────────────────

    function test_L1DeployerHoldsNoAuthority() public {
        vm.selectFork(l1Fork);
        _deployerRevoked(l1);
    }

    function test_L2DeployerHoldsNoAuthority() public {
        vm.selectFork(l2Fork);
        _deployerRevoked(l2);
    }

    function _deployerRevoked(Ctx storage c) internal view {
        ILidoTimelock timelock = ILidoTimelock(c.timelock);
        PausableAdvancedPoolHooks hooks = PausableAdvancedPoolHooks(c.hooks);
        assertFalse(timelock.hasRole(timelock.ADMIN_ROLE(), c.deployer), "deployer keeps timelock admin");
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), c.deployer), "deployer proposes");
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), c.deployer), "deployer executes");
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), c.deployer), "deployer cancels");
        assertFalse(timelock.hasRole(timelock.BYPASSER_ROLE(), c.deployer), "deployer bypasses");
        assertFalse(timelock.hasRole(timelock.PROPOSAL_QUEUE_HALT_ROLE(), c.deployer), "deployer halts");
        assertFalse(hooks.hasRole(hooks.CROSS_CHAIN_TRANSFERS_PAUSE_ROLE(), c.deployer), "deployer pauses");
        assertTrue(timelock.hasRole(timelock.ADMIN_ROLE(), c.govAdmin), "DAO is not the timelock admin");
        assertEq(timelock.getRoleMemberCount(timelock.ADMIN_ROLE()), 1, "more than one timelock admin");
        assertEq(timelock.getRoleMemberCount(timelock.BYPASSER_ROLE()), 0, "a bypasser besides the admin");
        assertEq(hooks.owner(), c.timelock, "hooks owner");
    }

    function _hooksCall(Ctx storage c, bytes memory data) internal view returns (ILidoTimelock.Call[] memory calls) {
        calls = new ILidoTimelock.Call[](1);
        calls[0] = ILidoTimelock.Call({target: c.hooks, value: 0, data: data});
    }
}

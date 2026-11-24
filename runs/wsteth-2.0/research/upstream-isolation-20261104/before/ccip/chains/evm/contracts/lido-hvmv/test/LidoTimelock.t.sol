// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {IERC1155Receiver} from "openzeppelin-contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";

import {LidoTimelock} from "../LidoTimelock.sol";
import {RBACTimelock} from "@chainlink/ccip-owner-contracts/RBACTimelock.sol";

contract LidoTimelockTest is Test {
  event ProposalQueueHaltedAtEpoch(uint128 epoch);
  event ProposalQueueRestarted(uint128 epoch);
  event ExpiryPeriodSet(uint120 expiryPeriod);

  uint256 internal constant MIN_DELAY = 3 days;
  uint120 internal constant EXPIRY_PERIOD = 14 days;
  bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
  bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
  bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
  bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
  bytes32 internal constant BYPASSER_ROLE = keccak256("BYPASSER_ROLE");
  bytes32 internal constant PROPOSAL_QUEUE_HALT_ROLE = keccak256("PROPOSAL_QUEUE_HALT_ROLE");

  LidoTimelock internal s_timelock;
  MockTarget internal s_target;

  address internal s_admin = makeAddr("Admin");
  address internal s_proposer = makeAddr("Proposer");
  address internal s_executor = makeAddr("Executor");
  address internal s_canceller = makeAddr("Canceller");
  address internal s_bypasser = makeAddr("Bypasser");
  address internal s_halter = makeAddr("Halter");
  address internal s_stranger = makeAddr("Stranger");

  function setUp() public {
    s_timelock = new LidoTimelock(
      MIN_DELAY,
      EXPIRY_PERIOD,
      s_admin,
      _single(s_proposer),
      _single(s_executor),
      _single(s_canceller),
      _single(s_bypasser),
      _single(s_halter)
    );
    s_target = new MockTarget();
  }

  // ════════════════════════════════════════════════════════════════════════
  // Helpers
  // ════════════════════════════════════════════════════════════════════════

  function _single(
    address account
  ) internal pure returns (address[] memory accounts) {
    accounts = new address[](1);
    accounts[0] = account;
  }

  function _setValueCalls(
    uint256 value
  ) internal view returns (RBACTimelock.Call[] memory calls) {
    calls = new RBACTimelock.Call[](1);
    calls[0] = RBACTimelock.Call(address(s_target), 0, abi.encodeCall(MockTarget.setValue, (value)));
  }

  function _schedule(RBACTimelock.Call[] memory calls, bytes32 predecessor, bytes32 salt) internal returns (bytes32) {
    vm.prank(s_proposer);
    s_timelock.scheduleBatch(calls, predecessor, salt, MIN_DELAY);
    return s_timelock.hashOperationBatch(calls, predecessor, salt);
  }

  function _execute(RBACTimelock.Call[] memory calls, bytes32 predecessor, bytes32 salt) internal {
    vm.prank(s_executor);
    s_timelock.executeBatch(calls, predecessor, salt);
  }

  function _halt() internal {
    vm.prank(s_halter);
    s_timelock.haltProposalQueue();
  }

  function _restart() internal {
    vm.prank(s_admin);
    s_timelock.restartProposalQueue();
  }

  function _missingRole(address account, bytes32 role) internal pure returns (bytes memory) {
    return bytes(
      string.concat(
        "AccessControl: account ",
        Strings.toHexString(account),
        " is missing role ",
        Strings.toHexString(uint256(role), 32)
      )
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // Construction
  // ════════════════════════════════════════════════════════════════════════

  function test_Constructor() public view {
    assertEq(s_timelock.getMinDelay(), MIN_DELAY);
    assertEq(s_timelock.getExpiryPeriod(), EXPIRY_PERIOD);
    assertTrue(s_timelock.hasRole(ADMIN_ROLE, s_admin));
    assertTrue(s_timelock.hasRole(PROPOSER_ROLE, s_proposer));
    assertTrue(s_timelock.hasRole(EXECUTOR_ROLE, s_executor));
    assertTrue(s_timelock.hasRole(CANCELLER_ROLE, s_canceller));
    assertTrue(s_timelock.hasRole(BYPASSER_ROLE, s_bypasser));
    assertTrue(s_timelock.hasRole(PROPOSAL_QUEUE_HALT_ROLE, s_halter));
    assertEq(s_timelock.getRoleAdmin(PROPOSAL_QUEUE_HALT_ROLE), ADMIN_ROLE);
    assertEq(s_timelock.getEpoch(), 0);
    assertFalse(s_timelock.isProposalQueueHalted());
  }

  function test_AdminManagesHalters() public {
    bytes32 haltRole = PROPOSAL_QUEUE_HALT_ROLE;
    vm.startPrank(s_admin);
    s_timelock.grantRole(haltRole, s_stranger);
    s_timelock.revokeRole(haltRole, s_halter);
    vm.stopPrank();

    assertTrue(s_timelock.hasRole(haltRole, s_stranger));
    assertFalse(s_timelock.hasRole(haltRole, s_halter));
  }

  // ════════════════════════════════════════════════════════════════════════
  // Base timelock flow
  // ════════════════════════════════════════════════════════════════════════

  function test_ScheduleAndExecute() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(42);
    bytes32 id = _schedule(calls, bytes32(0), bytes32(0));

    assertTrue(s_timelock.isOperationPending(id));
    assertFalse(s_timelock.isOperationReady(id));
    assertEq(s_timelock.getTimestamp(id), block.timestamp + MIN_DELAY);

    vm.warp(block.timestamp + MIN_DELAY);
    assertTrue(s_timelock.isOperationReady(id));
    _execute(calls, bytes32(0), bytes32(0));

    assertEq(s_target.value(), 42);
    assertTrue(s_timelock.isOperationDone(id));
  }

  function test_RevertWhen_ExecuteBeforeDelay() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    _schedule(calls, bytes32(0), bytes32(0));

    vm.warp(block.timestamp + MIN_DELAY - 1);
    vm.prank(s_executor);
    vm.expectRevert("RBACTimelock: operation is not ready");
    s_timelock.executeBatch(calls, bytes32(0), bytes32(0));
  }

  function test_RevertWhen_ScheduleBelowMinDelay() public {
    vm.prank(s_proposer);
    vm.expectRevert("RBACTimelock: insufficient delay");
    s_timelock.scheduleBatch(_setValueCalls(1), bytes32(0), bytes32(0), MIN_DELAY - 1);
  }

  function test_RevertWhen_ScheduleTwice() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    _schedule(calls, bytes32(0), bytes32(0));

    vm.prank(s_proposer);
    vm.expectRevert("RBACTimelock: operation already scheduled");
    s_timelock.scheduleBatch(calls, bytes32(0), bytes32(0), MIN_DELAY);
  }

  function test_RevertWhen_NonProposerSchedules() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    address[3] memory callers = [s_halter, s_canceller, s_executor];
    for (uint256 i; i < callers.length; ++i) {
      vm.prank(callers[i]);
      vm.expectRevert(_missingRole(callers[i], PROPOSER_ROLE));
      s_timelock.scheduleBatch(calls, bytes32(0), bytes32(0), MIN_DELAY);
    }
  }

  function test_RevertWhen_NonExecutorExecutes() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    _schedule(calls, bytes32(0), bytes32(0));
    vm.warp(block.timestamp + MIN_DELAY);

    vm.prank(s_proposer);
    vm.expectRevert(_missingRole(s_proposer, EXECUTOR_ROLE));
    s_timelock.executeBatch(calls, bytes32(0), bytes32(0));
  }

  function test_Cancel() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    bytes32 id = _schedule(calls, bytes32(0), bytes32(0));

    vm.prank(s_canceller);
    s_timelock.cancel(id);

    assertFalse(s_timelock.isOperation(id));
    vm.warp(block.timestamp + MIN_DELAY);
    vm.prank(s_executor);
    vm.expectRevert("RBACTimelock: operation is not ready");
    s_timelock.executeBatch(calls, bytes32(0), bytes32(0));
  }

  function test_RevertWhen_NonCancellerCancels() public {
    bytes32 id = _schedule(_setValueCalls(1), bytes32(0), bytes32(0));

    vm.prank(s_halter);
    vm.expectRevert(_missingRole(s_halter, CANCELLER_ROLE));
    s_timelock.cancel(id);
  }

  function test_RevertWhen_PredecessorNotDone() public {
    RBACTimelock.Call[] memory first = _setValueCalls(1);
    RBACTimelock.Call[] memory second = _setValueCalls(2);
    bytes32 firstId = _schedule(first, bytes32(0), bytes32(0));
    _schedule(second, firstId, bytes32(0));
    vm.warp(block.timestamp + MIN_DELAY);

    vm.prank(s_executor);
    vm.expectRevert("RBACTimelock: missing dependency");
    s_timelock.executeBatch(second, firstId, bytes32(0));

    _execute(first, bytes32(0), bytes32(0));
    _execute(second, firstId, bytes32(0));
    assertEq(s_target.value(), 2);
  }

  function test_RevertWhen_UnderlyingCallReverts() public {
    RBACTimelock.Call[] memory calls = new RBACTimelock.Call[](1);
    calls[0] = RBACTimelock.Call(address(s_target), 0, abi.encodeCall(MockTarget.fail, ()));
    _schedule(calls, bytes32(0), bytes32(0));
    vm.warp(block.timestamp + MIN_DELAY);

    vm.prank(s_executor);
    vm.expectRevert("RBACTimelock: underlying transaction reverted");
    s_timelock.executeBatch(calls, bytes32(0), bytes32(0));
  }

  function test_BlockedSelector() public {
    bytes4 selector = MockTarget.setValue.selector;
    vm.prank(s_admin);
    s_timelock.blockFunctionSelector(selector);
    assertEq(s_timelock.getBlockedFunctionSelectorCount(), 1);
    assertEq(s_timelock.getBlockedFunctionSelectorAt(0), selector);

    vm.prank(s_proposer);
    vm.expectRevert("RBACTimelock: selector is blocked");
    s_timelock.scheduleBatch(_setValueCalls(1), bytes32(0), bytes32(0), MIN_DELAY);

    vm.prank(s_admin);
    s_timelock.unblockFunctionSelector(selector);
    assertEq(s_timelock.getBlockedFunctionSelectorCount(), 0);
    _schedule(_setValueCalls(1), bytes32(0), bytes32(0));
  }

  function test_UpdateDelay() public {
    vm.prank(s_admin);
    s_timelock.updateDelay(5 days);
    assertEq(s_timelock.getMinDelay(), 5 days);

    vm.prank(s_proposer);
    vm.expectRevert(_missingRole(s_proposer, ADMIN_ROLE));
    s_timelock.updateDelay(1 days);
  }

  function test_BypasserExecutesImmediately() public {
    vm.prank(s_bypasser);
    s_timelock.bypasserExecuteBatch(_setValueCalls(7));
    assertEq(s_target.value(), 7);

    vm.prank(s_proposer);
    vm.expectRevert(_missingRole(s_proposer, BYPASSER_ROLE));
    s_timelock.bypasserExecuteBatch(_setValueCalls(8));
  }

  /// @dev A proposal runs with the timelock as msg.sender, which holds no role on itself.
  function test_RevertWhen_ProposalGrantsRoles() public {
    RBACTimelock.Call[] memory calls = new RBACTimelock.Call[](1);
    calls[0] = RBACTimelock.Call(address(s_timelock), 0, abi.encodeCall(s_timelock.grantRole, (ADMIN_ROLE, s_stranger)));
    _schedule(calls, bytes32(0), bytes32(0));
    vm.warp(block.timestamp + MIN_DELAY);

    vm.prank(s_executor);
    vm.expectRevert("RBACTimelock: underlying transaction reverted");
    s_timelock.executeBatch(calls, bytes32(0), bytes32(0));
  }

  function test_ReceivesTokensAndEth() public {
    assertEq(s_timelock.onERC721Received(address(0), address(0), 0, ""), IERC721Receiver.onERC721Received.selector);
    assertEq(
      s_timelock.onERC1155Received(address(0), address(0), 0, 0, ""), IERC1155Receiver.onERC1155Received.selector
    );
    assertEq(
      s_timelock.onERC1155BatchReceived(address(0), address(0), new uint256[](0), new uint256[](0), ""),
      IERC1155Receiver.onERC1155BatchReceived.selector
    );
    assertTrue(s_timelock.supportsInterface(type(IERC1155Receiver).interfaceId));

    vm.deal(address(this), 1 ether);
    (bool success,) = address(s_timelock).call{value: 1 ether}("");
    assertTrue(success);
    assertEq(address(s_timelock).balance, 1 ether);
  }

  // ════════════════════════════════════════════════════════════════════════
  // Halt and restart
  // ════════════════════════════════════════════════════════════════════════

  function test_HaltInvalidatesPendingProposals() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    bytes32 id = _schedule(calls, bytes32(0), bytes32(0));

    vm.expectEmit(address(s_timelock));
    emit ProposalQueueHaltedAtEpoch(1);
    _halt();

    assertTrue(s_timelock.isProposalQueueHalted());
    assertEq(s_timelock.getEpoch(), 1);
    assertEq(s_timelock.getTimestamp(id), 0);
    assertFalse(s_timelock.isOperation(id));
    assertFalse(s_timelock.isOperationPending(id));

    vm.warp(block.timestamp + MIN_DELAY);
    assertFalse(s_timelock.isOperationReady(id));
    vm.prank(s_executor);
    vm.expectRevert("RBACTimelock: operation is not ready");
    s_timelock.executeBatch(calls, bytes32(0), bytes32(0));

    vm.prank(s_canceller);
    vm.expectRevert("RBACTimelock: operation cannot be cancelled");
    s_timelock.cancel(id);
  }

  function test_RevertWhen_ScheduleWhileHalted() public {
    _halt();

    vm.prank(s_proposer);
    vm.expectRevert(LidoTimelock.ProposalQueueHalted.selector);
    s_timelock.scheduleBatch(_setValueCalls(1), bytes32(0), bytes32(0), MIN_DELAY);

    vm.prank(s_admin);
    vm.expectRevert(LidoTimelock.ProposalQueueHalted.selector);
    s_timelock.scheduleBatch(_setValueCalls(1), bytes32(0), bytes32(0), MIN_DELAY);
  }

  function test_RevertWhen_HaltTwice() public {
    _halt();

    vm.prank(s_halter);
    vm.expectRevert(LidoTimelock.ProposalQueueHalted.selector);
    s_timelock.haltProposalQueue();
  }

  function test_AdminCanHalt() public {
    vm.prank(s_admin);
    s_timelock.haltProposalQueue();
    assertTrue(s_timelock.isProposalQueueHalted());
  }

  function test_RevertWhen_NonHalterHalts() public {
    vm.prank(s_canceller);
    vm.expectRevert(_missingRole(s_canceller, PROPOSAL_QUEUE_HALT_ROLE));
    s_timelock.haltProposalQueue();
  }

  function test_Restart() public {
    _halt();

    vm.expectEmit(address(s_timelock));
    emit ProposalQueueRestarted(1);
    _restart();

    assertFalse(s_timelock.isProposalQueueHalted());
    assertEq(s_timelock.getEpoch(), 1);
  }

  function test_RevertWhen_NonAdminRestarts() public {
    _halt();

    vm.prank(s_halter);
    vm.expectRevert(_missingRole(s_halter, ADMIN_ROLE));
    s_timelock.restartProposalQueue();
  }

  function test_RevertWhen_RestartWhileNotHalted() public {
    vm.prank(s_admin);
    vm.expectRevert(LidoTimelock.ProposalQueueNotHalted.selector);
    s_timelock.restartProposalQueue();
  }

  function test_HaltedProposalsStayDeadAfterRestart() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    bytes32 id = _schedule(calls, bytes32(0), bytes32(0));
    _halt();
    _restart();

    vm.warp(block.timestamp + MIN_DELAY);
    assertFalse(s_timelock.isOperationReady(id));
    vm.prank(s_executor);
    vm.expectRevert("RBACTimelock: operation is not ready");
    s_timelock.executeBatch(calls, bytes32(0), bytes32(0));
  }

  function test_SameBatchCanBeReproposedAfterRestart() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(5);
    bytes32 id = _schedule(calls, bytes32(0), bytes32(0));
    _halt();
    _restart();

    assertEq(_schedule(calls, bytes32(0), bytes32(0)), id);
    assertTrue(s_timelock.isOperationPending(id));
    vm.warp(block.timestamp + MIN_DELAY);
    _execute(calls, bytes32(0), bytes32(0));
    assertEq(s_target.value(), 5);
  }

  function test_DoneProposalsSurviveHalt() public {
    RBACTimelock.Call[] memory first = _setValueCalls(1);
    bytes32 firstId = _schedule(first, bytes32(0), bytes32(0));
    vm.warp(vm.getBlockTimestamp() + MIN_DELAY);
    _execute(first, bytes32(0), bytes32(0));

    _halt();
    _restart();
    assertTrue(s_timelock.isOperationDone(firstId));

    RBACTimelock.Call[] memory second = _setValueCalls(2);
    _schedule(second, firstId, bytes32(0));
    vm.warp(vm.getBlockTimestamp() + MIN_DELAY);
    _execute(second, firstId, bytes32(0));
    assertEq(s_target.value(), 2);
  }

  function test_HaltInvalidatesReadyProposal() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    bytes32 id = _schedule(calls, bytes32(0), bytes32(0));
    vm.warp(block.timestamp + MIN_DELAY);
    assertTrue(s_timelock.isOperationReady(id));

    _halt();

    assertFalse(s_timelock.isOperationReady(id));
    vm.prank(s_executor);
    vm.expectRevert("RBACTimelock: operation is not ready");
    s_timelock.executeBatch(calls, bytes32(0), bytes32(0));
  }

  function test_PredecessorPendingAtHaltBlocksDependentUntilReproposed() public {
    RBACTimelock.Call[] memory first = _setValueCalls(1);
    RBACTimelock.Call[] memory second = _setValueCalls(2);
    bytes32 firstId = _schedule(first, bytes32(0), bytes32(0));
    _halt();
    _restart();

    _schedule(second, firstId, bytes32(0));
    vm.warp(vm.getBlockTimestamp() + MIN_DELAY);
    vm.prank(s_executor);
    vm.expectRevert("RBACTimelock: missing dependency");
    s_timelock.executeBatch(second, firstId, bytes32(0));

    assertEq(_schedule(first, bytes32(0), bytes32(0)), firstId);
    vm.warp(vm.getBlockTimestamp() + MIN_DELAY);
    _execute(first, bytes32(0), bytes32(0));
    _execute(second, firstId, bytes32(0));
    assertEq(s_target.value(), 2);
  }

  function test_ReproposedBatchGetsFreshTimestamp() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    bytes32 id = _schedule(calls, bytes32(0), bytes32(0));
    _halt();
    _restart();

    vm.warp(block.timestamp + 1 days);
    _schedule(calls, bytes32(0), bytes32(0));
    assertEq(s_timelock.getTimestamp(id), block.timestamp + MIN_DELAY);
  }

  function test_BypassWorksWhileHalted() public {
    _halt();

    vm.prank(s_admin);
    s_timelock.bypasserExecuteBatch(_setValueCalls(9));
    assertEq(s_target.value(), 9);
  }

  function testFuzz_EveryHaltInvalidatesTheQueue(
    uint8 halts
  ) public {
    halts = uint8(bound(halts, 1, 20));
    for (uint256 i; i < halts; ++i) {
      RBACTimelock.Call[] memory calls = _setValueCalls(i);
      bytes32 id = _schedule(calls, bytes32(0), bytes32(i));
      _halt();
      assertFalse(s_timelock.isOperation(id));
      _restart();
    }
    assertEq(s_timelock.getEpoch(), halts);
  }

  // ════════════════════════════════════════════════════════════════════════
  // Expiry
  // ════════════════════════════════════════════════════════════════════════

  function test_ExecutesUntilExpiry() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    _schedule(calls, bytes32(0), bytes32(0));

    vm.warp(block.timestamp + EXPIRY_PERIOD);
    _execute(calls, bytes32(0), bytes32(0));
    assertEq(s_target.value(), 1);
  }

  function test_RevertWhen_ExecuteAfterExpiry() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    bytes32 id = _schedule(calls, bytes32(0), bytes32(0));

    vm.warp(block.timestamp + EXPIRY_PERIOD + 1);
    assertFalse(s_timelock.isOperation(id));
    vm.prank(s_executor);
    vm.expectRevert("RBACTimelock: operation is not ready");
    s_timelock.executeBatch(calls, bytes32(0), bytes32(0));
  }

  function test_RevertWhen_CancelAfterExpiry() public {
    bytes32 id = _schedule(_setValueCalls(1), bytes32(0), bytes32(0));

    vm.warp(block.timestamp + EXPIRY_PERIOD + 1);
    vm.prank(s_canceller);
    vm.expectRevert("RBACTimelock: operation cannot be cancelled");
    s_timelock.cancel(id);
  }

  function test_ExpiredBatchCanBeRescheduled() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    _schedule(calls, bytes32(0), bytes32(0));
    vm.warp(block.timestamp + EXPIRY_PERIOD + 1);

    bytes32 id = _schedule(calls, bytes32(0), bytes32(0));
    assertEq(s_timelock.getTimestamp(id), block.timestamp + MIN_DELAY);
    vm.warp(block.timestamp + MIN_DELAY);
    _execute(calls, bytes32(0), bytes32(0));
    assertEq(s_target.value(), 1);
  }

  function test_DoneProposalsDoNotExpire() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    bytes32 id = _schedule(calls, bytes32(0), bytes32(0));
    vm.warp(block.timestamp + MIN_DELAY);
    _execute(calls, bytes32(0), bytes32(0));

    vm.warp(block.timestamp + EXPIRY_PERIOD + 1);
    assertTrue(s_timelock.isOperationDone(id));
  }

  function test_DelayAtOrAboveExpiryNeverExecutes() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    vm.prank(s_proposer);
    s_timelock.scheduleBatch(calls, bytes32(0), bytes32(0), EXPIRY_PERIOD + 1);

    vm.warp(block.timestamp + EXPIRY_PERIOD + 1);
    vm.prank(s_executor);
    vm.expectRevert("RBACTimelock: operation is not ready");
    s_timelock.executeBatch(calls, bytes32(0), bytes32(0));
  }

  function test_GetProposalState() public {
    bytes32 id = _schedule(_setValueCalls(1), bytes32(0), bytes32(0));
    uint256 scheduledAt = block.timestamp;

    LidoTimelock.ProposalState memory state = s_timelock.getProposalState(id);
    assertEq(state.epoch, 0);
    assertEq(state.expiresAt, scheduledAt + EXPIRY_PERIOD);

    _halt();
    state = s_timelock.getProposalState(id);
    assertEq(state.epoch, 0, "kept after the halt");
    assertFalse(s_timelock.isOperationPending(id));
  }

  function test_SetExpiryPeriod() public {
    vm.expectEmit(address(s_timelock));
    emit ExpiryPeriodSet(30 days);
    vm.prank(s_admin);
    s_timelock.setExpiryPeriod(30 days);

    assertEq(s_timelock.getExpiryPeriod(), 30 days);
  }

  function test_SetExpiryPeriodKeepsScheduledExpiry() public {
    RBACTimelock.Call[] memory calls = _setValueCalls(1);
    _schedule(calls, bytes32(0), bytes32(0));

    vm.prank(s_admin);
    s_timelock.setExpiryPeriod(uint120(MIN_DELAY + 1));

    vm.warp(block.timestamp + EXPIRY_PERIOD);
    _execute(calls, bytes32(0), bytes32(0));
    assertEq(s_target.value(), 1);
  }

  function test_RevertWhen_NonAdminSetsExpiryPeriod() public {
    vm.prank(s_proposer);
    vm.expectRevert(_missingRole(s_proposer, ADMIN_ROLE));
    s_timelock.setExpiryPeriod(30 days);
  }

  function test_RevertWhen_ExpiryPeriodNotAboveMinDelay() public {
    vm.prank(s_admin);
    vm.expectRevert(LidoTimelock.ExpiryPeriodBelowMinDelay.selector);
    s_timelock.setExpiryPeriod(uint120(MIN_DELAY));

    address[] memory none = new address[](0);
    vm.expectRevert(LidoTimelock.ExpiryPeriodBelowMinDelay.selector);
    new LidoTimelock(MIN_DELAY, uint120(MIN_DELAY), s_admin, none, none, none, none, none);
  }

  function testFuzz_ExecutableOnlyUntilExpiry(
    uint256 elapsed
  ) public {
    elapsed = bound(elapsed, MIN_DELAY, 2 * EXPIRY_PERIOD);
    bytes32 id = _schedule(_setValueCalls(1), bytes32(0), bytes32(0));

    vm.warp(block.timestamp + elapsed);
    assertEq(s_timelock.isOperationReady(id), elapsed <= EXPIRY_PERIOD);
  }
}

contract MockTarget {
  uint256 public value;

  function setValue(
    uint256 newValue
  ) external {
    value = newValue;
  }

  function fail() external pure {
    revert("MockTarget: fail");
  }
}

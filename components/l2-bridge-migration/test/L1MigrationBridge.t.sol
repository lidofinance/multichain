// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {BridgingManager} from "../contracts/BridgingManager.sol";
import {BridgeableTokens} from "../contracts/BridgeableTokens.sol";
import {CrossDomainEnabled} from "../contracts/optimism/CrossDomainEnabled.sol";
import {CCIPMigrationSender} from "../contracts/optimism/CCIPMigrationSender.sol";
import {L1ERC20TokenBridge} from "../contracts/optimism/L1ERC20TokenBridge.sol";
import {L1MigrationBridge} from "../contracts/optimism/L1MigrationBridge.sol";
import {IL1ERC20Bridge} from "../contracts/optimism/interfaces/IL1ERC20Bridge.sol";
import {IL2ERC20Bridge} from "../contracts/optimism/interfaces/IL2ERC20Bridge.sol";

import {MigrationTestBase} from "./utils/MigrationTestBase.sol";
import {OssifiableProxyDouble} from "./doubles/OssifiableProxyDouble.sol";
import {MockCrossDomainMessenger} from "./doubles/MockCrossDomainMessenger.sol";
import {MockRouter} from "./doubles/MockRouter.sol";
import {MockLockBox} from "./doubles/MockLockBox.sol";
import {MockTokenAdminRegistry} from "./doubles/MockTokenAdminRegistry.sol";
import {CallerWithReceive} from "./doubles/Callers.sol";

/// @dev The Ethereum side: the escrow proxy that ran the legacy `L1ERC20TokenBridge` is upgraded
///     in place to `L1MigrationBridge`, is scheduled by its admin, activated by anyone (escrow to
///     the lane lockbox, deposits through CCIP, legacy withdrawals paid from the lockbox) and
///     closed by anyone (legacy receives refused).
contract L1MigrationBridgeTest is MigrationTestBase {
    uint256 constant FEE = 0.02 ether;
    uint256 constant ESCROW = 1_000e18;
    uint256 constant USER_FUNDS = 10e18;

    MockCrossDomainMessenger messenger;
    MockRouter router;
    MockLockBox lockBox;
    MockTokenAdminRegistry registry;
    ERC20Mock wsteth;
    address pool = makeAddr("ccip-lock-release-pool");
    address l2Token = makeAddr("l2-wsteth");
    address l2Bridge = makeAddr("l2-bridge");

    OssifiableProxyDouble proxy;
    L1MigrationBridge impl;
    L1MigrationBridge bridge;

    uint256 activateAt;
    uint256 closeAt;

    function setUp() public {
        messenger = new MockCrossDomainMessenger();
        messenger.setXDomainMessageSender(l2Bridge);
        router = new MockRouter(pool, BASE_SELECTOR);
        router.setFee(FEE);
        wsteth = new ERC20Mock();
        lockBox = new MockLockBox(address(wsteth));
        registry = new MockTokenAdminRegistry();
        registry.setPool(address(wsteth), pool);

        L1ERC20TokenBridge legacy = new L1ERC20TokenBridge(address(messenger), l2Bridge, address(wsteth), l2Token);
        proxy = new OssifiableProxyDouble(address(legacy), admin, abi.encodeCall(BridgingManager.initialize, (admin)));
        bridge = L1MigrationBridge(address(proxy));
        vm.startPrank(admin);
        bridge.grantRole(bridge.DEPOSITS_ENABLER_ROLE(), admin);
        bridge.grantRole(bridge.DEPOSITS_DISABLER_ROLE(), admin);
        bridge.grantRole(bridge.WITHDRAWALS_ENABLER_ROLE(), admin);
        bridge.grantRole(bridge.WITHDRAWALS_DISABLER_ROLE(), admin);
        bridge.enableDeposits();
        bridge.enableWithdrawals();
        vm.stopPrank();
        // The escrow legacy deposits have accumulated, and a user ready to deposit.
        wsteth.mint(address(proxy), ESCROW);
        wsteth.mint(user, USER_FUNDS);
        vm.prank(user);
        wsteth.approve(address(proxy), type(uint256).max);
        vm.deal(user, 10 ether);

        impl = _newImpl(address(router), BASE_SELECTOR, address(registry), pool, address(lockBox));
        vm.prank(admin);
        proxy.proxy__upgradeTo(address(impl));
        // The vote also authorizes the bridge on the lockbox.
        lockBox.setAuthorized(address(proxy), true);

        vm.warp(1_700_000_000);
        activateAt = block.timestamp + 1 days;
        closeAt = activateAt + 11 days;
    }

    function _newImpl(address router_, uint64 selector_, address registry_, address pool_, address lockBox_)
        internal
        returns (L1MigrationBridge)
    {
        return new L1MigrationBridge(
            address(messenger), l2Bridge, address(wsteth), l2Token, router_, selector_, registry_, pool_, lockBox_
        );
    }

    function _switch(CCIPMigrationSender.BridgeMode mode_) internal {
        vm.prank(admin);
        bridge.switchBridgeMode(mode_);
    }

    function _schedule() internal {
        vm.prank(admin);
        bridge.scheduleActivation(activateAt);
        vm.prank(admin);
        bridge.scheduleClose(closeAt);
    }

    function _activate() internal {
        _schedule();
        vm.warp(activateAt);
        vm.prank(other);
        bridge.activate();
    }

    function test_ActivationConfirmsL2OnlyAfterMovingEscrow() public {
        _activate();
        assertEq(wsteth.balanceOf(address(bridge)), 0);
        assertEq(wsteth.balanceOf(address(lockBox)), ESCROW);
        MockCrossDomainMessenger.Message memory confirmation = messenger.lastMessage();
        assertEq(confirmation.target, l2Bridge);
        assertEq(confirmation.data, abi.encodeWithSignature("confirmL1Activation()"));
        assertEq(confirmation.gasLimit, bridge.ACTIVATION_CONFIRMATION_GAS());
    }

    function test_ConfirmationSendFailureRollsBackEscrowAndActivation() public {
        _schedule();
        vm.warp(activateAt);
        bytes memory data = abi.encodeWithSignature(
            "sendMessage(address,bytes,uint32)",
            l2Bridge,
            abi.encodeWithSignature("confirmL1Activation()"),
            bridge.ACTIVATION_CONFIRMATION_GAS()
        );
        vm.mockCallRevert(address(messenger), data, abi.encodeWithSignature("MessengerUnavailable()"));
        vm.expectRevert(bytes4(keccak256("MessengerUnavailable()")));
        bridge.activate();
        assertFalse(bridge.isActivated());
        assertEq(uint256(bridge.getBridgeMode()), uint256(LEGACY));
        assertEq(wsteth.balanceOf(address(bridge)), ESCROW);
        assertEq(wsteth.balanceOf(address(lockBox)), 0);
        vm.clearMockedCalls();
        bridge.activate();
        assertTrue(bridge.isActivated());
        assertEq(wsteth.balanceOf(address(lockBox)), ESCROW);
    }

    function _close() internal {
        _activate();
        vm.warp(closeAt);
        vm.prank(other);
        bridge.close();
    }

    function _legacyWithdrawal(address to_, uint256 amount_) internal {
        vm.prank(address(messenger));
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, to_, amount_, "");
    }

    function _depositData(address to_, uint256 amount_, bytes memory data_) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            IL2ERC20Bridge.finalizeDeposit.selector, address(wsteth), l2Token, user, to_, amount_, data_
        );
    }

    // ── deployment and upgrade ────────────────────────────────────────────────────────────────

    function test_ConstructorRejectsZeroAddressesAndZeroSelector() public {
        vm.expectRevert(CCIPMigrationSender.ErrorZeroAddress.selector);
        _newImpl(address(0), BASE_SELECTOR, address(registry), pool, address(lockBox));
        vm.expectRevert(CCIPMigrationSender.ErrorZeroChainSelector.selector);
        _newImpl(address(router), 0, address(registry), pool, address(lockBox));
        vm.expectRevert(CCIPMigrationSender.ErrorZeroAddress.selector);
        _newImpl(address(router), BASE_SELECTOR, address(0), pool, address(lockBox));
        vm.expectRevert(CCIPMigrationSender.ErrorZeroAddress.selector);
        _newImpl(address(router), BASE_SELECTOR, address(registry), address(0), address(lockBox));
        vm.expectRevert(CCIPMigrationSender.ErrorZeroAddress.selector);
        _newImpl(address(router), BASE_SELECTOR, address(registry), pool, address(0));
    }

    function test_ImplementationCannotBeInitialized() public {
        assertTrue(impl.isInitialized());
        vm.expectRevert(BridgingManager.ErrorAlreadyInitialized.selector);
        impl.initialize(attacker);
    }

    function test_UpgradeInPlaceKeepsStateEscrowAndStartsInLegacyUnscheduled() public view {
        assertEq(proxy.proxy__getImplementation(), address(impl));
        assertTrue(bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(bridge.isInitialized());
        assertTrue(bridge.isDepositsEnabled());
        assertTrue(bridge.isWithdrawalsEnabled());
        assertEq(uint256(bridge.getBridgeMode()), uint256(LEGACY));
        assertEq(bridge.getActivationTime(), 0);
        assertEq(bridge.getCloseTime(), 0);
        assertFalse(bridge.isActivated());
        assertFalse(bridge.isClosed());
        assertEq(address(bridge.ccipRouter()), address(router));
        assertEq(bridge.ccipDestinationChainSelector(), BASE_SELECTOR);
        assertEq(address(bridge.ccipTokenAdminRegistry()), address(registry));
        assertEq(bridge.ccipTokenPool(), pool);
        assertEq(address(bridge.ccipLockBox()), address(lockBox));
        assertEq(bridge.l2TokenBridge(), l2Bridge);
        assertEq(bridge.l1Token(), address(wsteth));
        assertEq(bridge.l2Token(), l2Token);
        assertEq(wsteth.balanceOf(address(proxy)), ESCROW);
    }

    function test_LinearStorageStaysEmptyAcrossTheSchedule() public {
        _close();
        for (uint256 slot = 0; slot < 64; slot++) {
            assertEq(vm.load(address(proxy), bytes32(slot)), bytes32(0));
        }
        // mode (1 byte) | activateAt (8) | closeAt (8) | activated (1) | closed (1), packed.
        uint256 word = uint256(vm.load(address(proxy), MIGRATION_SLOT));
        assertEq(word & 0xff, uint256(CCIP_ONLY));
        assertEq((word >> 8) & type(uint64).max, activateAt);
        assertEq((word >> 72) & type(uint64).max, closeAt);
        assertEq((word >> 136) & 0xff, 1);
        assertEq((word >> 144) & 0xff, 1);
    }

    // ── LEGACY ────────────────────────────────────────────────────────────────────────────────

    function test_Legacy_DepositLocksHereAndMessagesL2() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IL1ERC20Bridge.ERC20DepositInitiated(address(wsteth), l2Token, user, user, 1e18, "");
        bridge.depositERC20(address(wsteth), l2Token, 1e18, 200_000, "");
        assertEq(wsteth.balanceOf(address(proxy)), ESCROW + 1e18);
        assertEq(wsteth.balanceOf(user), USER_FUNDS - 1e18);
        assertEq(messenger.sentCount(), 1);
        MockCrossDomainMessenger.Message memory m = messenger.lastMessage();
        assertEq(m.target, l2Bridge);
        assertEq(m.data, _depositData(user, 1e18, ""));
        assertEq(m.gasLimit, 200_000);
        assertEq(router.sendCount(), 0);
    }

    function test_Legacy_DepositFromContractRejectedButDepositToAllowed() public {
        CallerWithReceive caller = new CallerWithReceive();
        wsteth.mint(address(caller), 2e18);
        caller.approve(address(wsteth), address(proxy), 2e18);

        vm.expectRevert(L1ERC20TokenBridge.ErrorSenderNotEOA.selector);
        caller.exec(
            address(proxy), 0, abi.encodeCall(bridge.depositERC20, (address(wsteth), l2Token, 1e18, 200_000, ""))
        );

        caller.exec(
            address(proxy),
            0,
            abi.encodeCall(bridge.depositERC20To, (address(wsteth), l2Token, other, 1e18, 200_000, ""))
        );
        MockCrossDomainMessenger.Message memory m = messenger.lastMessage();
        assertEq(
            m.data,
            abi.encodeWithSelector(
                IL2ERC20Bridge.finalizeDeposit.selector, address(wsteth), l2Token, address(caller), other, 1e18, ""
            )
        );
    }

    function test_Legacy_RejectsValue() public {
        vm.prank(user);
        vm.expectRevert(CCIPMigrationSender.ErrorValueNotAccepted.selector);
        bridge.depositERC20{value: 1}(address(wsteth), l2Token, 1e18, 200_000, "");
        vm.prank(user);
        vm.expectRevert(CCIPMigrationSender.ErrorValueNotAccepted.selector);
        bridge.depositERC20To{value: 1}(address(wsteth), l2Token, other, 1e18, 200_000, "");
    }

    function test_Legacy_UnsupportedTokensAndZeroRecipientRejected() public {
        vm.prank(user);
        vm.expectRevert(BridgeableTokens.ErrorUnsupportedL1Token.selector);
        bridge.depositERC20(other, l2Token, 1e18, 200_000, "");
        vm.prank(user);
        vm.expectRevert(BridgeableTokens.ErrorUnsupportedL2Token.selector);
        bridge.depositERC20(address(wsteth), other, 1e18, 200_000, "");
        vm.prank(user);
        vm.expectRevert(BridgeableTokens.ErrorAccountIsZeroAddress.selector);
        bridge.depositERC20To(address(wsteth), l2Token, address(0), 1e18, 200_000, "");
    }

    function test_Legacy_FinalizeWithdrawalPaysFromTheEscrowAndNeverTouchesTheLockBox() public {
        vm.prank(address(messenger));
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IL1ERC20Bridge.ERC20WithdrawalFinalized(address(wsteth), l2Token, user, other, 3e18, "");
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, other, 3e18, "");
        assertEq(wsteth.balanceOf(other), 3e18);
        assertEq(wsteth.balanceOf(address(proxy)), ESCROW - 3e18);
        assertEq(lockBox.withdrawCount(), 0);

        vm.prank(attacker);
        vm.expectRevert(CrossDomainEnabled.ErrorUnauthorizedMessenger.selector);
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, attacker, 3e18, "");

        // Unfunded in LEGACY: the lockbox is not a backing before activation.
        vm.prank(address(messenger));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(proxy), ESCROW - 3e18, ESCROW
            )
        );
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, other, ESCROW, "");
    }

    function test_Legacy_FeeQuoteIsZero() public view {
        assertEq(bridge.getCCIPFee(user, 1e18), 0);
    }

    function test_SwitchBridgeMode_AdminOnly() public {
        vm.prank(attacker);
        vm.expectRevert(unauthorized(attacker, bytes32(0)));
        bridge.switchBridgeMode(MIGRATING);
        _switch(MIGRATING);
        bridge.requireBridgeMode(MIGRATING);
    }

    // ── schedule ──────────────────────────────────────────────────────────────────────────────

    function test_Schedule_AdminOnlyOnceInLegacyInTheFutureAndOrdered() public {
        vm.prank(attacker);
        vm.expectRevert(unauthorized(attacker, bytes32(0)));
        bridge.scheduleActivation(activateAt);

        // Close needs an activation first.
        vm.prank(admin);
        vm.expectRevert(CCIPMigrationSender.ErrorActivationNotScheduled.selector);
        bridge.scheduleClose(closeAt);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorInvalidSchedule.selector, block.timestamp));
        bridge.scheduleActivation(block.timestamp);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPMigrationSender.ErrorInvalidSchedule.selector, uint256(type(uint64).max) + 1)
        );
        bridge.scheduleActivation(uint256(type(uint64).max) + 1);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.ActivationScheduled(admin, activateAt);
        bridge.scheduleActivation(activateAt);
        assertEq(bridge.getActivationTime(), activateAt);

        vm.prank(admin);
        vm.expectRevert(CCIPMigrationSender.ErrorAlreadyScheduled.selector);
        bridge.scheduleActivation(activateAt + 1);

        vm.prank(attacker);
        vm.expectRevert(unauthorized(attacker, bytes32(0)));
        bridge.scheduleClose(closeAt);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorInvalidSchedule.selector, activateAt));
        bridge.scheduleClose(activateAt);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.CloseScheduled(admin, closeAt);
        bridge.scheduleClose(closeAt);
        assertEq(bridge.getCloseTime(), closeAt);

        vm.prank(admin);
        vm.expectRevert(CCIPMigrationSender.ErrorAlreadyScheduled.selector);
        bridge.scheduleClose(closeAt + 1);
    }

    function test_Schedule_ActivationRequiresLegacy() public {
        _switch(MIGRATING);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPMigrationSender.ErrorUnexpectedBridgeMode.selector, MIGRATING, LEGACY)
        );
        bridge.scheduleActivation(activateAt);
    }

    // ── activate ──────────────────────────────────────────────────────────────────────────────

    function test_Activate_GuardsTimerModePoolAndDepositsFlag() public {
        vm.expectRevert(CCIPMigrationSender.ErrorActivationNotScheduled.selector);
        bridge.activate();

        _schedule();
        vm.warp(activateAt - 1);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorTooEarly.selector, activateAt));
        bridge.activate();

        vm.warp(activateAt);
        // The registry does not bind the hub pool yet (Chainlink's hand-over pending).
        registry.setPool(address(wsteth), other);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorUnexpectedTokenPool.selector, other, pool));
        bridge.activate();
        registry.setPool(address(wsteth), pool);

        // The Emergency Brakes veto: deposits disabled.
        vm.prank(admin);
        bridge.disableDeposits();
        vm.expectRevert(CCIPMigrationSender.ErrorSendsDisabled.selector);
        bridge.activate();
        vm.prank(admin);
        bridge.enableDeposits();

        // A direct mode switch by the admin also blocks it: activation is LEGACY → MIGRATING only.
        _switch(CCIP_ONLY);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPMigrationSender.ErrorUnexpectedBridgeMode.selector, CCIP_ONLY, LEGACY)
        );
        bridge.activate();
        _switch(LEGACY);

        assertEq(wsteth.balanceOf(address(proxy)), ESCROW);
        assertEq(uint256(bridge.getBridgeMode()), uint256(LEGACY));
    }

    function test_Activate_AnyoneMovesTheWholeEscrowToTheLockBoxAndSwitchesOnce() public {
        _schedule();
        vm.warp(activateAt);
        vm.prank(other);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.BridgeModeUpdated(other, LEGACY, MIGRATING);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.Activated(other);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit L1MigrationBridge.EscrowMigrated(address(lockBox), ESCROW);
        bridge.activate();

        assertEq(uint256(bridge.getBridgeMode()), uint256(MIGRATING));
        assertTrue(bridge.isActivated());
        assertEq(wsteth.balanceOf(address(proxy)), 0);
        assertEq(wsteth.balanceOf(address(lockBox)), ESCROW);

        vm.expectRevert(CCIPMigrationSender.ErrorAlreadyActivated.selector);
        bridge.activate();
    }

    function test_Activate_WithEmptyEscrowStillSwitches() public {
        wsteth.burn(address(proxy), ESCROW);
        _schedule();
        vm.warp(activateAt);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit L1MigrationBridge.EscrowMigrated(address(lockBox), 0);
        bridge.activate();
        assertEq(uint256(bridge.getBridgeMode()), uint256(MIGRATING));
    }

    function test_RollbackAfterActivationDoesNotReArmActivate() public {
        _activate();
        _switch(LEGACY);
        vm.expectRevert(CCIPMigrationSender.ErrorAlreadyActivated.selector);
        bridge.activate();
        // The escrow is in the lockbox and LEGACY does not draw from it: a legacy withdrawal is
        // unfunded until the admin returns liquidity or goes forward again.
        vm.prank(address(messenger));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(proxy), 0, 1e18));
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, other, 1e18, "");
        _switch(MIGRATING);
        _legacyWithdrawal(other, 1e18);
        assertEq(wsteth.balanceOf(other), 1e18);
    }

    // ── MIGRATING ─────────────────────────────────────────────────────────────────────────────

    function test_Migrating_DepositGoesThroughTheRouter() public {
        _activate();
        assertEq(bridge.getCCIPFee(user, 1e18), FEE);
        uint256 ethBefore = user.balance;
        bytes32 expectedId = router.messageIdFor(1, BASE_SELECTOR, abi.encode(user), address(proxy));

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.CCIPTransferInitiated(expectedId, user, user, 1e18, FEE);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IL1ERC20Bridge.ERC20DepositInitiated(address(wsteth), l2Token, user, user, 1e18, "");
        bridge.depositERC20{value: FEE + 1 ether}(address(wsteth), l2Token, 1e18, 200_000, "");

        assertEq(wsteth.balanceOf(address(proxy)), 0);
        assertEq(wsteth.balanceOf(pool), 1e18);
        assertEq(wsteth.balanceOf(user), USER_FUNDS - 1e18);
        assertEq(wsteth.allowance(address(proxy), address(router)), 0);
        assertEq(user.balance, ethBefore - FEE);
        assertEq(address(proxy).balance, 0);
        assertEq(messenger.sentCount(), 1); // Activation confirmation only; no legacy deposit message.

        assertEq(router.sendCount(), 1);
        assertEq(router.lastSender(), address(proxy));
        assertEq(router.lastValue(), FEE);
        assertEq(router.lastSelector(), BASE_SELECTOR);
        assertEq(router.lastReceiver(), abi.encode(user));
        assertEq(router.lastData(), "");
        assertEq(router.lastFeeToken(), address(0));
        assertEq(router.lastTokenCount(), 1);
        assertEq(router.lastToken(), address(wsteth));
        assertEq(router.lastAmount(), 1e18);
        assertEq(router.lastExtraArgs(), extraArgsV2(0, true));
    }

    function test_Migrating_DepositToDoesNotForwardPayloadOrGasButStillEmitsTheLegacyEvent() public {
        _activate();
        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IL1ERC20Bridge.ERC20DepositInitiated(address(wsteth), l2Token, user, other, 1e18, hex"c0ffee");
        bridge.depositERC20To{value: FEE}(address(wsteth), l2Token, other, 1e18, 250_000, hex"c0ffee");
        assertEq(router.lastReceiver(), abi.encode(other));
        assertEq(router.lastData(), "");
        assertEq(router.lastExtraArgs(), extraArgsV2(0, true));
    }

    function test_Migrating_DepositStillRequiresEoaAndEnabledDeposits() public {
        _activate();
        CallerWithReceive caller = new CallerWithReceive();
        wsteth.mint(address(caller), 1e18);
        caller.approve(address(wsteth), address(proxy), 1e18);
        vm.deal(address(caller), FEE);
        vm.expectRevert(L1ERC20TokenBridge.ErrorSenderNotEOA.selector);
        caller.exec(address(proxy), FEE, abi.encodeCall(bridge.depositERC20, (address(wsteth), l2Token, 1e18, 0, "")));

        vm.prank(admin);
        bridge.disableDeposits();
        vm.prank(user);
        vm.expectRevert(BridgingManager.ErrorDepositsDisabled.selector);
        bridge.depositERC20{value: FEE}(address(wsteth), l2Token, 1e18, 0, "");
    }

    function test_Migrating_InsufficientFeeReverts() public {
        _activate();
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorInsufficientCCIPFee.selector, FEE, FEE - 1));
        bridge.depositERC20{value: FEE - 1}(address(wsteth), l2Token, 1e18, 0, "");
        assertEq(wsteth.balanceOf(user), USER_FUNDS);
    }

    function test_Migrating_LegacyWithdrawalsDrawTheShortfallFromTheLockBox() public {
        _activate();
        // Escrow is empty: the whole amount comes from the lockbox, through the bridge.
        vm.prank(address(messenger));
        vm.expectEmit(true, true, true, true, address(proxy));
        emit L1MigrationBridge.EscrowReplenished(address(lockBox), 5e18);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IL1ERC20Bridge.ERC20WithdrawalFinalized(address(wsteth), l2Token, user, other, 5e18, "");
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, other, 5e18, "");
        assertEq(wsteth.balanceOf(other), 5e18);
        assertEq(wsteth.balanceOf(address(proxy)), 0);
        assertEq(wsteth.balanceOf(address(lockBox)), ESCROW - 5e18);
        assertEq(lockBox.withdrawCount(), 1);
        assertEq(lockBox.lastSelector(), BASE_SELECTOR);
        assertEq(lockBox.lastAmount(), 5e18);
        assertEq(lockBox.lastRecipient(), address(proxy));

        // A partial balance on the bridge (a stray transfer) only draws what is missing.
        wsteth.mint(address(proxy), 2e18);
        _legacyWithdrawal(other, 3e18);
        assertEq(lockBox.lastAmount(), 1e18);
        assertEq(wsteth.balanceOf(address(proxy)), 0);
        assertEq(wsteth.balanceOf(other), 8e18);

        // Enough on the bridge: nothing drawn.
        wsteth.mint(address(proxy), 4e18);
        _legacyWithdrawal(other, 4e18);
        assertEq(lockBox.withdrawCount(), 2);
    }

    function test_Migrating_LegacyWithdrawalChecksTheCallerBeforeDrawing() public {
        _activate();
        vm.prank(attacker);
        vm.expectRevert(CrossDomainEnabled.ErrorUnauthorizedMessenger.selector);
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, attacker, 5e18, "");
        messenger.setXDomainMessageSender(attacker);
        vm.prank(address(messenger));
        vm.expectRevert(CrossDomainEnabled.ErrorWrongCrossDomainSender.selector);
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, attacker, 5e18, "");
        messenger.setXDomainMessageSender(l2Bridge);
        vm.prank(admin);
        bridge.disableWithdrawals();
        vm.prank(address(messenger));
        vm.expectRevert(BridgingManager.ErrorWithdrawalsDisabled.selector);
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, other, 5e18, "");
        assertEq(lockBox.withdrawCount(), 0);
    }

    function test_Migrating_LegacyWithdrawalFailsWhenTheLockBoxCannotCover() public {
        _activate();
        vm.prank(address(messenger));
        vm.expectRevert(abi.encodeWithSelector(MockLockBox.InsufficientBalance.selector, ESCROW + 1, ESCROW));
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, other, ESCROW + 1, "");

        lockBox.setAuthorized(address(proxy), false);
        vm.prank(address(messenger));
        vm.expectRevert(abi.encodeWithSelector(MockLockBox.UnauthorizedCaller.selector, address(proxy)));
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, other, 1e18, "");
    }

    // ── close ─────────────────────────────────────────────────────────────────────────────────

    function test_Close_GuardsTimerModeAndDepositsFlag() public {
        vm.expectRevert(CCIPMigrationSender.ErrorCloseNotScheduled.selector);
        bridge.close();

        _schedule();
        vm.warp(closeAt);
        // Not activated yet: close is MIGRATING → CCIP_ONLY only.
        vm.expectRevert(
            abi.encodeWithSelector(CCIPMigrationSender.ErrorUnexpectedBridgeMode.selector, LEGACY, MIGRATING)
        );
        bridge.close();

        vm.warp(activateAt);
        bridge.activate();
        vm.warp(closeAt - 1);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorTooEarly.selector, closeAt));
        bridge.close();

        vm.warp(closeAt);
        vm.prank(admin);
        bridge.disableDeposits();
        vm.expectRevert(CCIPMigrationSender.ErrorSendsDisabled.selector);
        bridge.close();
        vm.prank(admin);
        bridge.enableDeposits();

        vm.prank(other);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.BridgeModeUpdated(other, MIGRATING, CCIP_ONLY);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.Closed(other);
        bridge.close();
        assertEq(uint256(bridge.getBridgeMode()), uint256(CCIP_ONLY));
        assertTrue(bridge.isClosed());

        vm.expectRevert(CCIPMigrationSender.ErrorAlreadyClosed.selector);
        bridge.close();
    }

    function test_CcipOnly_LegacyWithdrawalsRevertAndDepositsUseTheRouter() public {
        _close();
        vm.prank(address(messenger));
        vm.expectRevert(modeNotAllowed(CCIP_ONLY));
        bridge.finalizeERC20Withdrawal(address(wsteth), l2Token, user, other, 1e18, "");
        assertEq(lockBox.withdrawCount(), 0);

        vm.prank(user);
        bridge.depositERC20{value: FEE}(address(wsteth), l2Token, 1e18, 0, "");
        assertEq(router.sendCount(), 1);
        assertEq(wsteth.balanceOf(address(proxy)), 0);
    }

    function test_RollbackAfterCloseFundsALateWithdrawalFromTheLockBox() public {
        _close();
        // The late legacy withdrawal is refused in CCIP_ONLY; the admin steps back to MIGRATING
        // and the bridge, still authorized on the lockbox, pays it; then forward again.
        _switch(MIGRATING);
        _legacyWithdrawal(other, 2e18);
        assertEq(wsteth.balanceOf(other), 2e18);
        assertEq(wsteth.balanceOf(address(lockBox)), ESCROW - 2e18);
        _switch(CCIP_ONLY);
        vm.expectRevert(CCIPMigrationSender.ErrorAlreadyClosed.selector);
        bridge.close();
    }
}

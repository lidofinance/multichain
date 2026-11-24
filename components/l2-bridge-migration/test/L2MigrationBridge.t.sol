// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {IAdvancedPoolHooks} from "@chainlink/contracts-ccip/interfaces/IAdvancedPoolHooks.sol";
import {IPolicyEngine} from "@chainlink/policy-management/interfaces/IPolicyEngine.sol";

import {BridgingManager} from "../contracts/BridgingManager.sol";
import {CrossDomainEnabled} from "../contracts/optimism/CrossDomainEnabled.sol";
import {CCIPMigrationSender} from "../contracts/optimism/CCIPMigrationSender.sol";
import {L2ERC20TokenBridge} from "../contracts/optimism/L2ERC20TokenBridge.sol";
import {L2MigrationBridge} from "../contracts/optimism/L2MigrationBridge.sol";
import {IL1ERC20Bridge} from "../contracts/optimism/interfaces/IL1ERC20Bridge.sol";
import {IL2ERC20Bridge} from "../contracts/optimism/interfaces/IL2ERC20Bridge.sol";

import {MigrationTestBase} from "./utils/MigrationTestBase.sol";
import {OssifiableProxyDouble} from "./doubles/OssifiableProxyDouble.sol";
import {MockCrossDomainMessenger} from "./doubles/MockCrossDomainMessenger.sol";
import {MockRouter} from "./doubles/MockRouter.sol";
import {MockL2Token} from "./doubles/MockL2Token.sol";
import {MockTokenAdminRegistry} from "./doubles/MockTokenAdminRegistry.sol";
import {CallerWithoutReceive} from "./doubles/Callers.sol";

/// @dev The Base side: a proxy that ran the legacy `L2ERC20TokenBridge` is upgraded in place to
///     `L2MigrationBridge` and driven through LEGACY → MIGRATING → CCIP_ONLY (and back).
contract L2MigrationBridgeTest is MigrationTestBase {
    uint256 constant FEE = 0.01 ether;
    uint256 constant SEED = 10e18;

    MockCrossDomainMessenger messenger;
    MockRouter router;
    MockL2Token token;
    MockTokenAdminRegistry registry;
    address pool = makeAddr("ccip-burn-mint-pool");
    address l1Token = makeAddr("l1-wsteth");
    address l1Bridge = makeAddr("l1-bridge");

    OssifiableProxyDouble proxy;
    L2MigrationBridge impl;
    L2MigrationBridge bridge;

    function setUp() public {
        messenger = new MockCrossDomainMessenger();
        messenger.setXDomainMessageSender(l1Bridge);
        router = new MockRouter(pool, ETH_SELECTOR);
        router.setFee(FEE);
        token = new MockL2Token(admin);
        registry = new MockTokenAdminRegistry();
        registry.setPool(address(token), pool);

        // Deployed state: legacy implementation behind the proxy, initialized, both directions
        // enabled, the bridge holding the token's mint/burn roles, a user with a legacy balance.
        L2ERC20TokenBridge legacy = new L2ERC20TokenBridge(address(messenger), l1Bridge, l1Token, address(token));
        proxy = new OssifiableProxyDouble(address(legacy), admin, abi.encodeCall(BridgingManager.initialize, (admin)));
        bridge = L2MigrationBridge(address(proxy));
        vm.startPrank(admin);
        bridge.grantRole(bridge.DEPOSITS_ENABLER_ROLE(), admin);
        bridge.grantRole(bridge.WITHDRAWALS_ENABLER_ROLE(), admin);
        bridge.grantRole(bridge.WITHDRAWALS_DISABLER_ROLE(), admin);
        bridge.enableDeposits();
        bridge.enableWithdrawals();
        token.grantRole(token.MINTER_ROLE(), address(proxy));
        token.grantRole(token.BURNER_ROLE(), address(proxy));
        vm.stopPrank();
        _legacyDeposit(user, SEED);
        vm.deal(user, 10 ether);

        // The upgrade under test.
        impl = _newImpl(address(router), ETH_SELECTOR, address(registry), pool);
        vm.prank(admin);
        proxy.proxy__upgradeTo(address(impl));
    }

    function _newImpl(address router_, uint64 selector_, address registry_, address pool_)
        internal
        returns (L2MigrationBridge)
    {
        return new L2MigrationBridge(
            address(messenger), l1Bridge, l1Token, address(token), router_, selector_, registry_, pool_
        );
    }

    function _legacyDeposit(address to_, uint256 amount_) internal {
        vm.prank(address(messenger));
        bridge.finalizeDeposit(l1Token, address(token), to_, to_, amount_, "");
    }

    function _switch(CCIPMigrationSender.BridgeMode mode_) internal {
        vm.prank(admin);
        bridge.switchBridgeMode(mode_);
    }

    function _approveBridge(address from_, uint256 amount_) internal {
        vm.prank(from_);
        token.approve(address(proxy), amount_);
    }

    // ── deployment and upgrade ────────────────────────────────────────────────────────────────

    function test_ConstructorRejectsZeroAddressesAndZeroSelector() public {
        vm.expectRevert(CCIPMigrationSender.ErrorZeroAddress.selector);
        _newImpl(address(0), ETH_SELECTOR, address(registry), pool);
        vm.expectRevert(CCIPMigrationSender.ErrorZeroChainSelector.selector);
        _newImpl(address(router), 0, address(registry), pool);
        vm.expectRevert(CCIPMigrationSender.ErrorZeroAddress.selector);
        _newImpl(address(router), ETH_SELECTOR, address(0), pool);
        vm.expectRevert(CCIPMigrationSender.ErrorZeroAddress.selector);
        _newImpl(address(router), ETH_SELECTOR, address(registry), address(0));
    }

    function test_ImplementationCannotBeInitialized() public {
        assertTrue(impl.isInitialized());
        vm.expectRevert(BridgingManager.ErrorAlreadyInitialized.selector);
        impl.initialize(attacker);
        assertFalse(impl.hasRole(impl.DEFAULT_ADMIN_ROLE(), attacker));
    }

    function test_UpgradeInPlaceKeepsStateAndStartsInLegacy() public view {
        assertEq(proxy.proxy__getImplementation(), address(impl));
        assertTrue(bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(bridge.hasRole(bridge.DEPOSITS_ENABLER_ROLE(), admin));
        assertTrue(bridge.isInitialized());
        assertTrue(bridge.isDepositsEnabled());
        assertTrue(bridge.isWithdrawalsEnabled());
        assertEq(uint256(bridge.getBridgeMode()), uint256(LEGACY));
        assertEq(address(bridge.ccipRouter()), address(router));
        assertEq(bridge.ccipDestinationChainSelector(), ETH_SELECTOR);
        assertEq(address(bridge.ccipTokenAdminRegistry()), address(registry));
        assertEq(bridge.ccipTokenPool(), pool);
        assertEq(bridge.getActivationTime(), 0);
        assertEq(bridge.getCloseTime(), 0);
        assertFalse(bridge.isActivated());
        assertFalse(bridge.isClosed());
        assertEq(address(bridge.messenger()), address(messenger));
        assertEq(bridge.l1TokenBridge(), l1Bridge);
        assertEq(bridge.l1Token(), l1Token);
        assertEq(bridge.l2Token(), address(token));
        assertEq(token.balanceOf(user), SEED);
    }

    function test_ProxyInitializeStaysLockedAfterUpgrade() public {
        vm.prank(attacker);
        vm.expectRevert(BridgingManager.ErrorAlreadyInitialized.selector);
        bridge.initialize(attacker);
    }

    function test_MigrationStorageIsErc7201NamespacedAndLinearSlotsStayEmpty() public {
        assertEq(MIGRATION_SLOT, erc7201("lido.storage.CCIPMigrationSender"));
        assertEq(vm.load(address(proxy), MIGRATION_SLOT), bytes32(0));
        _switch(CCIP_ONLY);
        assertEq(uint256(vm.load(address(proxy), MIGRATION_SLOT)) & 0xff, uint256(CCIP_ONLY));
        // AccessControl._roles (a mapping head, never written) is the only linear variable.
        for (uint256 slot = 0; slot < 64; slot++) {
            assertEq(vm.load(address(proxy), bytes32(slot)), bytes32(0));
        }
    }

    // ── LEGACY ────────────────────────────────────────────────────────────────────────────────

    function test_Legacy_FinalizeDepositMintsOnlyFromTheMessenger() public {
        vm.prank(address(messenger));
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IL2ERC20Bridge.DepositFinalized(l1Token, address(token), user, other, 1e18, hex"01");
        bridge.finalizeDeposit(l1Token, address(token), user, other, 1e18, hex"01");
        assertEq(token.balanceOf(other), 1e18);
        assertEq(token.totalSupply(), SEED + 1e18);

        vm.prank(attacker);
        vm.expectRevert(CrossDomainEnabled.ErrorUnauthorizedMessenger.selector);
        bridge.finalizeDeposit(l1Token, address(token), user, other, 1e18, "");

        messenger.setXDomainMessageSender(attacker);
        vm.prank(address(messenger));
        vm.expectRevert(CrossDomainEnabled.ErrorWrongCrossDomainSender.selector);
        bridge.finalizeDeposit(l1Token, address(token), user, other, 1e18, "");
    }

    function test_Legacy_WithdrawBurnsThroughAllowanceAndMessagesL1() public {
        _approveBridge(user, 1e18);
        bytes memory expected = abi.encodeWithSelector(
            IL1ERC20Bridge.finalizeERC20Withdrawal.selector, l1Token, address(token), user, user, 1e18, hex""
        );
        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IL2ERC20Bridge.WithdrawalInitiated(l1Token, address(token), user, user, 1e18, "");
        bridge.withdraw(address(token), 1e18, 200_000, "");

        assertEq(token.balanceOf(user), SEED - 1e18);
        assertEq(token.totalSupply(), SEED - 1e18);
        assertEq(token.allowance(user, address(proxy)), 0);
        assertEq(messenger.sentCount(), 1);
        MockCrossDomainMessenger.Message memory m = messenger.lastMessage();
        assertEq(m.target, l1Bridge);
        assertEq(m.data, expected);
        assertEq(m.gasLimit, 200_000);
        assertEq(router.sendCount(), 0);
    }

    function test_Legacy_WithdrawToNamesTheRecipientOnL1() public {
        _approveBridge(user, 1e18);
        vm.prank(user);
        bridge.withdrawTo(address(token), other, 1e18, 150_000, hex"beef");
        MockCrossDomainMessenger.Message memory m = messenger.lastMessage();
        assertEq(
            m.data,
            abi.encodeWithSelector(
                IL1ERC20Bridge.finalizeERC20Withdrawal.selector, l1Token, address(token), user, other, 1e18, hex"beef"
            )
        );
        assertEq(m.gasLimit, 150_000);
    }

    function test_Legacy_WithdrawWithoutAllowanceReverts() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(proxy), 0, 1e18)
        );
        bridge.withdraw(address(token), 1e18, 200_000, "");
    }

    function test_Legacy_RejectsValue() public {
        _approveBridge(user, 2e18);
        vm.prank(user);
        vm.expectRevert(CCIPMigrationSender.ErrorValueNotAccepted.selector);
        bridge.withdraw{value: 1}(address(token), 1e18, 200_000, "");
        vm.prank(user);
        vm.expectRevert(CCIPMigrationSender.ErrorValueNotAccepted.selector);
        bridge.withdrawTo{value: 1}(address(token), other, 1e18, 200_000, "");
    }

    function test_Legacy_FeeQuoteIsZero() public view {
        assertEq(bridge.getCCIPFee(user, 1e18), 0);
    }

    // ── mode switch ───────────────────────────────────────────────────────────────────────────

    function test_SwitchBridgeMode_AdminOnlyDistinctAndObservable() public {
        vm.prank(attacker);
        vm.expectRevert(unauthorized(attacker, bytes32(0)));
        bridge.switchBridgeMode(MIGRATING);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorSameBridgeMode.selector, LEGACY));
        bridge.switchBridgeMode(LEGACY);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.BridgeModeUpdated(admin, LEGACY, MIGRATING);
        bridge.switchBridgeMode(MIGRATING);
        assertEq(uint256(bridge.getBridgeMode()), uint256(MIGRATING));

        bridge.requireBridgeMode(MIGRATING);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPMigrationSender.ErrorUnexpectedBridgeMode.selector, MIGRATING, LEGACY)
        );
        bridge.requireBridgeMode(LEGACY);
    }

    function test_SwitchBridgeMode_AnyTransitionBetweenDistinctModes() public {
        _switch(CCIP_ONLY);
        _switch(LEGACY);
        _switch(MIGRATING);
        _switch(LEGACY);
        assertEq(uint256(bridge.getBridgeMode()), uint256(LEGACY));
    }

    // ── MIGRATING ─────────────────────────────────────────────────────────────────────────────

    function test_Migrating_LegacyDepositsStillFinalize() public {
        _switch(MIGRATING);
        _legacyDeposit(other, 1e18);
        assertEq(token.balanceOf(other), 1e18);
    }

    function test_Migrating_FinalizeDepositNeedsTheTokenMinterRole() public {
        _switch(MIGRATING);
        bytes32 minter = token.MINTER_ROLE();
        vm.prank(admin);
        token.revokeRole(minter, address(proxy));
        vm.prank(address(messenger));
        vm.expectRevert(unauthorized(address(proxy), minter));
        bridge.finalizeDeposit(l1Token, address(token), user, user, 1e18, "");
    }

    function test_Migrating_WithdrawSendsThroughTheRouterAndRefundsExcess() public {
        _switch(MIGRATING);
        assertEq(bridge.getCCIPFee(user, 1e18), FEE);
        _approveBridge(user, 1e18);
        uint256 ethBefore = user.balance;
        bytes32 expectedId = router.messageIdFor(1, ETH_SELECTOR, abi.encode(user), address(proxy));

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.CCIPTransferInitiated(expectedId, user, user, 1e18, FEE);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IL2ERC20Bridge.WithdrawalInitiated(l1Token, address(token), user, user, 1e18, "");
        bridge.withdraw{value: FEE + 0.5 ether}(address(token), 1e18, 200_000, "");

        assertEq(token.balanceOf(user), SEED - 1e18);
        assertEq(token.balanceOf(address(proxy)), 0);
        assertEq(token.balanceOf(pool), 1e18);
        assertEq(token.allowance(address(proxy), address(router)), 0);
        assertEq(user.balance, ethBefore - FEE);
        assertEq(address(proxy).balance, 0);
        assertEq(messenger.sentCount(), 0);

        assertEq(router.sendCount(), 1);
        assertEq(router.lastSender(), address(proxy));
        assertEq(router.lastValue(), FEE);
        assertEq(router.lastSelector(), ETH_SELECTOR);
        assertEq(router.lastReceiver(), abi.encode(user));
        assertEq(router.lastData(), "");
        assertEq(router.lastFeeToken(), address(0));
        assertEq(router.lastTokenCount(), 1);
        assertEq(router.lastToken(), address(token));
        assertEq(router.lastAmount(), 1e18);
        // No payload: execution gas is dropped, out-of-order execution allowed.
        assertEq(router.lastExtraArgs(), extraArgsV2(0, true));
    }

    function test_Migrating_WithdrawToDoesNotForwardPayloadOrGasButStillEmitsTheLegacyEvent() public {
        _switch(MIGRATING);
        _approveBridge(user, 1e18);
        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IL2ERC20Bridge.WithdrawalInitiated(l1Token, address(token), user, other, 1e18, hex"c0ffee");
        bridge.withdrawTo{value: FEE}(address(token), other, 1e18, 300_000, hex"c0ffee");
        // The bridge never relays caller-chosen payloads under its own address: token-only message.
        assertEq(router.lastReceiver(), abi.encode(other));
        assertEq(router.lastData(), "");
        assertEq(router.lastExtraArgs(), extraArgsV2(0, true));
        assertEq(user.balance, 10 ether - FEE);
    }

    function test_Migrating_InsufficientFeeReverts() public {
        _switch(MIGRATING);
        _approveBridge(user, 1e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorInsufficientCCIPFee.selector, FEE, FEE - 1));
        bridge.withdraw{value: FEE - 1}(address(token), 1e18, 200_000, "");
        assertEq(token.balanceOf(user), SEED);
    }

    function test_Migrating_FeeRiseBetweenQuoteAndSendReverts() public {
        _switch(MIGRATING);
        uint256 quoted = bridge.getCCIPFee(user, 1e18);
        router.setFee(quoted * 2);
        _approveBridge(user, 1e18);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPMigrationSender.ErrorInsufficientCCIPFee.selector, quoted * 2, quoted)
        );
        bridge.withdraw{value: quoted}(address(token), 1e18, 0, "");
    }

    function test_Migrating_WithdrawWithoutAllowanceReverts() public {
        _switch(MIGRATING);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(proxy), 0, 1e18)
        );
        bridge.withdraw{value: FEE}(address(token), 1e18, 200_000, "");
    }

    function test_Migrating_RefundFailureRevertsTheWholeWithdrawal() public {
        _switch(MIGRATING);
        CallerWithoutReceive caller = new CallerWithoutReceive();
        vm.deal(address(caller), 1 ether);
        _legacyDeposit(address(caller), 1e18);
        caller.approve(address(token), address(proxy), 1e18);
        bytes memory data = abi.encodeCall(bridge.withdraw, (address(token), 1e18, 200_000, ""));

        vm.expectRevert(Address.FailedInnerCall.selector);
        caller.exec(address(proxy), FEE + 1, data);
        assertEq(token.balanceOf(address(caller)), 1e18);

        caller.exec(address(proxy), FEE, data);
        assertEq(token.balanceOf(pool), 1e18);
    }

    function test_Migrating_WithdrawalsDisabledStillGatesTheCcipPath() public {
        _switch(MIGRATING);
        vm.prank(admin);
        bridge.disableWithdrawals();
        _approveBridge(user, 1e18);
        vm.prank(user);
        vm.expectRevert(BridgingManager.ErrorWithdrawalsDisabled.selector);
        bridge.withdraw{value: FEE}(address(token), 1e18, 200_000, "");
    }

    function test_Migrating_QuoteFailurePropagates() public {
        _switch(MIGRATING);
        router.setQuoteReverts(true);
        bytes memory err = abi.encodeWithSelector(IRouterClient.UnsupportedDestinationChain.selector, ETH_SELECTOR);
        vm.expectRevert(err);
        bridge.getCCIPFee(user, 1e18);
        _approveBridge(user, 1e18);
        vm.prank(user);
        vm.expectRevert(err);
        bridge.withdraw{value: FEE}(address(token), 1e18, 0, "");
    }

    function testFuzz_Migrating_RefundsExactlyTheExcess(uint96 excess_) public {
        _switch(MIGRATING);
        vm.deal(user, FEE + excess_);
        _approveBridge(user, 1e18);
        vm.prank(user);
        bridge.withdraw{value: FEE + excess_}(address(token), 1e18, 0, "");
        assertEq(user.balance, excess_);
        assertEq(router.lastValue(), FEE);
    }

    // ── CCIP_ONLY and rollback ────────────────────────────────────────────────────────────────

    function test_CcipOnly_LegacyDepositsRevertAndWithdrawalsUseTheRouter() public {
        _switch(CCIP_ONLY);
        vm.prank(address(messenger));
        vm.expectRevert(modeNotAllowed(CCIP_ONLY));
        bridge.finalizeDeposit(l1Token, address(token), user, user, 1e18, "");

        _approveBridge(user, 1e18);
        vm.prank(user);
        bridge.withdraw{value: FEE}(address(token), 1e18, 0, "");
        assertEq(router.sendCount(), 1);
        assertEq(messenger.sentCount(), 0);
    }

    function test_RollbackToLegacyRestoresTheMessengerPath() public {
        _switch(CCIP_ONLY);
        _switch(LEGACY);
        _approveBridge(user, 1e18);
        vm.prank(user);
        bridge.withdraw(address(token), 1e18, 0, "");
        assertEq(messenger.sentCount(), 1);
        assertEq(router.sendCount(), 0);
        _legacyDeposit(other, 1e18);
        assertEq(token.balanceOf(other), 1e18);
    }

    // ── schedule, activate, close ─────────────────────────────────────────────────────────────

    uint256 constant ACTIVATE_AT = 1_700_000_000 + 2 days;
    uint256 constant CLOSE_AT = ACTIVATE_AT + 10 days;

    function _schedule() internal {
        vm.warp(1_700_000_000);
        vm.prank(admin);
        bridge.scheduleActivation(ACTIVATE_AT);
        vm.prank(admin);
        bridge.scheduleClose(CLOSE_AT);
    }

    function _activate() internal {
        _schedule();
        vm.warp(ACTIVATE_AT);
        _confirmL1Activation();
        vm.prank(other);
        bridge.activate();
    }

    function _confirmL1Activation() internal {
        vm.prank(address(messenger));
        bridge.confirmL1Activation();
    }

    function test_ConfirmationRequiresCanonicalMessengerAndL1Bridge() public {
        vm.expectRevert(CrossDomainEnabled.ErrorUnauthorizedMessenger.selector);
        bridge.confirmL1Activation();
        messenger.setXDomainMessageSender(attacker);
        vm.prank(address(messenger));
        vm.expectRevert(CrossDomainEnabled.ErrorWrongCrossDomainSender.selector);
        bridge.confirmL1Activation();
        assertFalse(bridge.isL1ActivationConfirmed());
        messenger.setXDomainMessageSender(l1Bridge);
        _confirmL1Activation();
        _confirmL1Activation(); // Duplicate delivery is idempotent.
        assertTrue(bridge.isL1ActivationConfirmed());
        assertFalse(bridge.isActivated());
    }

    function test_PoolPolicyBlocksDirectSendsUntilConfirmedActivationButAllowsReceives() public {
        address hooks = makeAddr("pool-hooks");
        vm.mockCall(pool, abi.encodeWithSignature("getAdvancedPoolHooks()"), abi.encode(hooks));
        IPolicyEngine.Payload memory payload = IPolicyEngine.Payload({
            selector: IAdvancedPoolHooks.preflightCheck.selector, sender: pool, data: "", context: ""
        });
        vm.expectRevert(L2MigrationBridge.ErrorUnexpectedPolicyCaller.selector);
        bridge.run(payload);
        vm.prank(hooks);
        bridge.attach();
        vm.prank(hooks);
        vm.expectRevert(L2MigrationBridge.ErrorMigrationNotActivated.selector);
        bridge.run(payload);
        payload.selector = IAdvancedPoolHooks.postflightCheck.selector;
        vm.prank(hooks);
        bridge.run(payload);
        _confirmL1Activation();
        payload.selector = IAdvancedPoolHooks.preflightCheck.selector;
        vm.prank(hooks);
        vm.expectRevert(L2MigrationBridge.ErrorMigrationNotActivated.selector);
        bridge.run(payload);
        _activate();
        vm.prank(hooks);
        bridge.run(payload);
        payload.sender = attacker;
        vm.prank(hooks);
        vm.expectRevert(L2MigrationBridge.ErrorUnexpectedPolicyPayload.selector);
        bridge.run(payload);
    }

    function test_Schedule_AdminOnlyOnceAndOrdered() public {
        vm.warp(1_700_000_000);
        vm.prank(attacker);
        vm.expectRevert(unauthorized(attacker, bytes32(0)));
        bridge.scheduleActivation(ACTIVATE_AT);
        vm.prank(admin);
        vm.expectRevert(CCIPMigrationSender.ErrorActivationNotScheduled.selector);
        bridge.scheduleClose(CLOSE_AT);
        vm.prank(admin);
        bridge.scheduleActivation(ACTIVATE_AT);
        vm.prank(admin);
        vm.expectRevert(CCIPMigrationSender.ErrorAlreadyScheduled.selector);
        bridge.scheduleActivation(ACTIVATE_AT);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorInvalidSchedule.selector, ACTIVATE_AT));
        bridge.scheduleClose(ACTIVATE_AT);
        vm.prank(admin);
        bridge.scheduleClose(CLOSE_AT);
        assertEq(bridge.getActivationTime(), ACTIVATE_AT);
        assertEq(bridge.getCloseTime(), CLOSE_AT);
    }

    function test_Activate_GuardsTimerModePoolAndWithdrawalsFlag() public {
        vm.expectRevert(CCIPMigrationSender.ErrorActivationNotScheduled.selector);
        bridge.activate();
        _schedule();
        vm.warp(ACTIVATE_AT - 1);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorTooEarly.selector, ACTIVATE_AT));
        bridge.activate();
        vm.warp(ACTIVATE_AT);
        registry.setPool(address(token), address(0));
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorUnexpectedTokenPool.selector, address(0), pool));
        bridge.activate();
        registry.setPool(address(token), pool);
        // The Emergency Brakes veto on Base: withdrawals disabled.
        vm.prank(admin);
        bridge.disableWithdrawals();
        vm.expectRevert(CCIPMigrationSender.ErrorSendsDisabled.selector);
        bridge.activate();
        vm.prank(admin);
        bridge.enableWithdrawals();
        vm.expectRevert(L2MigrationBridge.ErrorL1ActivationNotConfirmed.selector);
        bridge.activate();
        assertFalse(bridge.isActivated());
        assertEq(uint256(bridge.getBridgeMode()), uint256(LEGACY));
        _confirmL1Activation();
        vm.prank(other);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.BridgeModeUpdated(other, LEGACY, MIGRATING);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.Activated(other);
        bridge.activate();
        assertEq(uint256(bridge.getBridgeMode()), uint256(MIGRATING));
        assertTrue(bridge.isActivated());
        vm.expectRevert(CCIPMigrationSender.ErrorAlreadyActivated.selector);
        bridge.activate();
        // The bridge keeps the token roles while MIGRATING: legacy deposits still finalize.
        _legacyDeposit(other, 1e18);
        assertEq(token.balanceOf(other), 1e18);
    }

    function test_Close_GuardsTimerModeAndWithdrawalsFlagThenRenouncesTheTokenRoles() public {
        vm.expectRevert(CCIPMigrationSender.ErrorCloseNotScheduled.selector);
        bridge.close();
        _activate();
        vm.warp(CLOSE_AT - 1);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorTooEarly.selector, CLOSE_AT));
        bridge.close();
        vm.warp(CLOSE_AT);
        vm.prank(admin);
        bridge.disableWithdrawals();
        vm.expectRevert(CCIPMigrationSender.ErrorSendsDisabled.selector);
        bridge.close();
        vm.prank(admin);
        bridge.enableWithdrawals();

        bytes32 minter = token.MINTER_ROLE();
        bytes32 burner = token.BURNER_ROLE();
        assertTrue(token.hasRole(minter, address(proxy)) && token.hasRole(burner, address(proxy)));
        vm.prank(other);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.BridgeModeUpdated(other, MIGRATING, CCIP_ONLY);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit CCIPMigrationSender.Closed(other);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit L2MigrationBridge.TokenRolesRenounced(address(token));
        bridge.close();
        assertEq(uint256(bridge.getBridgeMode()), uint256(CCIP_ONLY));
        assertTrue(bridge.isClosed());
        assertFalse(token.hasRole(minter, address(proxy)));
        assertFalse(token.hasRole(burner, address(proxy)));
        vm.expectRevert(CCIPMigrationSender.ErrorAlreadyClosed.selector);
        bridge.close();

        // Legacy receives are refused by the mode; and after a rollback to MIGRATING, by the
        // token, until its admin re-grants the roles.
        vm.prank(address(messenger));
        vm.expectRevert(modeNotAllowed(CCIP_ONLY));
        bridge.finalizeDeposit(l1Token, address(token), user, user, 1e18, "");
        _switch(MIGRATING);
        vm.prank(address(messenger));
        vm.expectRevert(unauthorized(address(proxy), minter));
        bridge.finalizeDeposit(l1Token, address(token), user, user, 1e18, "");
        vm.prank(admin);
        token.grantRole(minter, address(proxy));
        _legacyDeposit(user, 1e18);
        assertEq(token.balanceOf(user), SEED + 1e18);
        // CCIP withdrawals keep working throughout.
        _approveBridge(user, 1e18);
        vm.prank(user);
        bridge.withdraw{value: FEE}(address(token), 1e18, 0, "");
        assertEq(router.sendCount(), 1);
    }

    function test_Close_RenounceIsANoOpForRolesTheBridgeDoesNotHold() public {
        _activate();
        vm.startPrank(admin);
        token.revokeRole(token.MINTER_ROLE(), address(proxy));
        token.revokeRole(token.BURNER_ROLE(), address(proxy));
        vm.stopPrank();
        vm.warp(CLOSE_AT);
        bridge.close();
        assertEq(uint256(bridge.getBridgeMode()), uint256(CCIP_ONLY));
    }

    function test_Close_RequiresMigratingSoAnUnactivatedBridgeCannotBeClosed() public {
        _schedule();
        vm.warp(CLOSE_AT);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPMigrationSender.ErrorUnexpectedBridgeMode.selector, LEGACY, MIGRATING)
        );
        bridge.close();
    }
}

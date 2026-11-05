// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {L2MigrationBridge} from "../contracts/optimism/L2MigrationBridge.sol";
import {L1MigrationBridge} from "../contracts/optimism/L1MigrationBridge.sol";
import {CCIPMigrationSender} from "../contracts/optimism/CCIPMigrationSender.sol";
import {BridgingManager} from "../contracts/BridgingManager.sol";
import {ERC20BridgedPermit} from "wsteth-token/contracts/token/ERC20BridgedPermit.sol";
import {MockLockBox} from "../test/doubles/MockLockBox.sol";

interface ITokenAdminRegistryLike {
    function getPool(address token) external view returns (address);
}

interface IOssifiableProxy {
    function proxy__getAdmin() external view returns (address);
    function proxy__getImplementation() external view returns (address);
    function proxy__upgradeTo(address) external;
    function proxy__upgradeToAndCall(address, bytes memory, bool) external;
}

interface ILegacy {
    function messenger() external view returns (address);
    function l1Token() external view returns (address);
    function l2Token() external view returns (address);
    function l1TokenBridge() external view returns (address);
    function l2TokenBridge() external view returns (address);
    function isDepositsEnabled() external view returns (bool);
    function isWithdrawalsEnabled() external view returns (bool);
    function hasRole(bytes32, address) external view returns (bool);
    function finalizeDeposit(address, address, address, address, uint256, bytes calldata) external;
}

interface IMeta is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

contract BaseMigrationForkTest is Test {
    bytes4 constant XDMS = bytes4(keccak256("xDomainMessageSender()"));

    address constant OPEXEC = 0x0E37599436974a25dDeEdF795C848d30Af46eaCF;
    address constant BASE_TOKEN_PROXY = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant BASE_BRIDGE_PROXY = 0xac9D11cD4D7eF6e54F14643a393F68Ca014287AB;
    address constant BASE_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address constant BASE_TAR = 0x6f6C373d09C07425BaAE72317863d7F6bb731e37;
    uint64 constant ETH_SELECTOR = 5009297550715157269;

    address constant AGENT = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;
    address constant L1_BRIDGE_PROXY = 0x9de443AdC5A411E83F1878Ef24C3F52C61571e72;
    address constant ETH_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address constant ETH_TAR = 0xb22764f98dD05c789929716D677382Df22C05Cb6;
    uint64 constant BASE_SELECTOR = 15971525489660198786;

    address user = makeAddr("lido-base-migration-user-2026-10-21");
    address other = makeAddr("lido-base-migration-other-2026-10-21");
    address attacker = makeAddr("lido-base-migration-attacker-2026-10-21");
    address stranger = makeAddr("lido-base-migration-stranger-2026-10-21");
    address basePool = makeAddr("lido-base-migration-base-pool-2026-10-21");

    function _mockRelay(address messenger, address xdms) internal {
        vm.mockCall(messenger, abi.encodeWithSelector(XDMS), abi.encode(xdms));
    }

    function testBaseTokenAndBridgeUpgrade() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));
        IOssifiableProxy tokenProxy = IOssifiableProxy(BASE_TOKEN_PROXY);
        IOssifiableProxy bridgeProxy = IOssifiableProxy(BASE_BRIDGE_PROXY);
        IMeta token = IMeta(BASE_TOKEN_PROXY);
        ILegacy old = ILegacy(BASE_BRIDGE_PROXY);
        assertEq(tokenProxy.proxy__getAdmin(), OPEXEC);
        assertEq(bridgeProxy.proxy__getAdmin(), OPEXEC);

        // Seed state on the OLD code: a legacy deposit mints to `user`, who sets an allowance.
        address messenger = old.messenger();
        address l1Token = old.l1Token();
        address l2Token = old.l2Token();
        address l1Bridge = old.l1TokenBridge();
        _mockRelay(messenger, l1Bridge);
        vm.prank(messenger);
        old.finalizeDeposit(l1Token, l2Token, user, user, 10e18, "");
        vm.prank(user);
        token.approve(other, 3e18);

        string memory name = token.name();
        string memory symbol = token.symbol();
        uint256 supply = token.totalSupply();
        assertEq(token.balanceOf(user), 10e18);

        // 1. Token: atomic upgrade + finalizeUpgrade_v3 by the proxy admin.
        ERC20BridgedPermit tokenImpl = new ERC20BridgedPermit(name, symbol, "2", 18);
        vm.prank(OPEXEC);
        tokenProxy.proxy__upgradeToAndCall(
            address(tokenImpl), abi.encodeCall(ERC20BridgedPermit.finalizeUpgrade_v3, ("2", OPEXEC)), false
        );
        ERC20BridgedPermit t = ERC20BridgedPermit(BASE_TOKEN_PROXY);
        assertEq(t.name(), name);
        assertEq(t.symbol(), symbol);
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), supply);
        assertEq(t.balanceOf(user), 10e18);
        assertEq(t.allowance(user, other), 3e18);
        assertEq(t.getContractVersion(), 3);
        assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), OPEXEC));
        (, string memory dn, string memory dv,,,,) = t.eip712Domain();
        assertEq(dn, name);
        assertEq(dv, "2");
        assertTrue(t.DOMAIN_SEPARATOR() != bytes32(0));
        // no second seating, no fresh init, no bridge authority left
        vm.prank(attacker);
        vm.expectRevert();
        t.finalizeUpgrade_v3("2", attacker);
        vm.prank(attacker);
        vm.expectRevert();
        t.initialize(name, symbol, "2", attacker);
        vm.prank(OPEXEC);
        vm.expectRevert();
        t.finalizeUpgrade_v3("2", OPEXEC);
        (bool ok,) = BASE_TOKEN_PROXY.call(abi.encodeWithSignature("bridgeMint(address,uint256)", user, 1));
        assertFalse(ok);
        // increase/decreaseAllowance ABI kept
        vm.prank(user);
        t.increaseAllowance(other, 1e18);
        assertEq(t.allowance(user, other), 4e18);

        // 2. Bridge: plain upgrade, storage carried over.
        L2MigrationBridge bridgeImpl = new L2MigrationBridge(
            messenger, l1Bridge, l1Token, l2Token, BASE_ROUTER, ETH_SELECTOR, BASE_TAR, basePool
        );
        vm.expectRevert(BridgingManager.ErrorAlreadyInitialized.selector);
        bridgeImpl.initialize(attacker);
        vm.prank(OPEXEC);
        bridgeProxy.proxy__upgradeTo(address(bridgeImpl));
        L2MigrationBridge b = L2MigrationBridge(BASE_BRIDGE_PROXY);
        assertTrue(b.hasRole(b.DEFAULT_ADMIN_ROLE(), OPEXEC));
        assertTrue(b.isInitialized());
        assertTrue(b.isDepositsEnabled());
        assertTrue(b.isWithdrawalsEnabled());
        assertEq(uint256(b.getBridgeMode()), uint256(CCIPMigrationSender.BridgeMode.LEGACY));
        assertEq(address(b.ccipRouter()), BASE_ROUTER);

        // Roles the legacy paths need while the queue drains.
        vm.startPrank(OPEXEC);
        t.grantRole(t.MINTER_ROLE(), BASE_BRIDGE_PROXY);
        t.grantRole(t.BURNER_ROLE(), BASE_BRIDGE_PROXY);
        vm.stopPrank();

        // LEGACY: legacy deposit mints, legacy withdraw burns (now via allowance) and messages L1.
        vm.prank(messenger);
        b.finalizeDeposit(l1Token, l2Token, user, user, 1e18, "");
        assertEq(t.balanceOf(user), 11e18);
        vm.prank(user);
        t.approve(BASE_BRIDGE_PROXY, 2e18);
        vm.prank(user);
        b.withdraw(l2Token, 1e18, 0, "");
        assertEq(t.balanceOf(user), 10e18);
        assertEq(t.totalSupply(), supply);
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(CCIPMigrationSender.ErrorValueNotAccepted.selector);
        b.withdraw{value: 1}(l2Token, 1e18, 0, "");

        // The scheduled path: the admin arms the timers; `activate()` refuses to run while Base's
        // TokenAdminRegistry has no entry for wstETH (a live fact, 2026-10-21: the lane must be
        // registered before the activation can happen).
        vm.startPrank(OPEXEC);
        b.scheduleActivation(block.timestamp + 1 days);
        b.scheduleClose(block.timestamp + 11 days);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        assertEq(ITokenAdminRegistryLike(BASE_TAR).getPool(l2Token), address(0));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPMigrationSender.ErrorUnexpectedTokenPool.selector, address(0), basePool)
        );
        b.activate();

        // Mode switch: admin only; MIGRATING keeps legacy receives, CCIP_ONLY rejects them.
        vm.prank(attacker);
        vm.expectRevert();
        b.switchBridgeMode(CCIPMigrationSender.BridgeMode.MIGRATING);
        vm.prank(OPEXEC);
        b.switchBridgeMode(CCIPMigrationSender.BridgeMode.MIGRATING);
        b.requireBridgeMode(CCIPMigrationSender.BridgeMode.MIGRATING);
        vm.expectRevert();
        b.requireBridgeMode(CCIPMigrationSender.BridgeMode.LEGACY);
        vm.prank(messenger);
        b.finalizeDeposit(l1Token, l2Token, user, user, 1e18, "");
        assertEq(t.balanceOf(user), 11e18);
        // CCIP send on Base cannot be quoted today: wstETH has no Base TokenAdminRegistry entry.
        vm.expectRevert();
        b.getCCIPFee(user, 1e18);
        // `close()` after its timer: CCIP_ONLY and the token roles given up by the bridge itself.
        vm.warp(block.timestamp + 10 days);
        vm.prank(stranger);
        b.close();
        assertEq(uint256(b.getBridgeMode()), uint256(CCIPMigrationSender.BridgeMode.CCIP_ONLY));
        assertFalse(t.hasRole(t.MINTER_ROLE(), BASE_BRIDGE_PROXY));
        assertFalse(t.hasRole(t.BURNER_ROLE(), BASE_BRIDGE_PROXY));
        vm.prank(messenger);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPMigrationSender.ErrorBridgeModeNotAllowed.selector, CCIPMigrationSender.BridgeMode.CCIP_ONLY
            )
        );
        b.finalizeDeposit(l1Token, l2Token, user, user, 1e18, "");
    }

    function testEthereumL1BridgeUpgrade() public {
        vm.createSelectFork(vm.envOr("ETH_RPC", string("https://ethereum-rpc.publicnode.com")));
        IOssifiableProxy proxy = IOssifiableProxy(L1_BRIDGE_PROXY);
        ILegacy old = ILegacy(L1_BRIDGE_PROXY);
        assertEq(proxy.proxy__getAdmin(), AGENT);
        address l1Token = old.l1Token();
        address l2Token = old.l2Token();
        address l2Bridge = old.l2TokenBridge();
        IERC20 wst = IERC20(l1Token);
        uint256 escrow = wst.balanceOf(L1_BRIDGE_PROXY);
        address messenger = old.messenger();

        // The hub pool the registry binds today is Chainlink's; the bridge is built against it so
        // that the activation guard can be met on the fork. The lane lockbox is a double.
        address currentPool = ITokenAdminRegistryLike(ETH_TAR).getPool(l1Token);
        assertTrue(currentPool != address(0), "wstETH has no CCIP pool on L1");
        MockLockBox lockbox = new MockLockBox(l1Token);
        L1MigrationBridge impl = new L1MigrationBridge(
            messenger, l2Bridge, l1Token, l2Token, ETH_ROUTER, BASE_SELECTOR, ETH_TAR, currentPool, address(lockbox)
        );
        vm.prank(AGENT);
        proxy.proxy__upgradeTo(address(impl));
        L1MigrationBridge b = L1MigrationBridge(L1_BRIDGE_PROXY);
        assertTrue(b.hasRole(b.DEFAULT_ADMIN_ROLE(), AGENT));
        assertTrue(b.isDepositsEnabled());
        assertTrue(b.isWithdrawalsEnabled());
        assertEq(uint256(b.getBridgeMode()), uint256(CCIPMigrationSender.BridgeMode.LEGACY));
        assertEq(wst.balanceOf(L1_BRIDGE_PROXY), escrow);
        lockbox.setAuthorized(L1_BRIDGE_PROXY, true);

        // LEGACY: a legacy deposit still locks here; the timers are armed by the admin.
        deal(address(wst), user, 10e18);
        vm.startPrank(user);
        wst.approve(L1_BRIDGE_PROXY, 10e18);
        b.depositERC20(l1Token, l2Token, 1e18, 200_000, "");
        vm.stopPrank();
        assertEq(wst.balanceOf(L1_BRIDGE_PROXY), escrow + 1e18);
        vm.startPrank(AGENT);
        b.scheduleActivation(block.timestamp + 1 days);
        b.scheduleClose(block.timestamp + 11 days);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CCIPMigrationSender.ErrorTooEarly.selector, block.timestamp + 1 days));
        b.activate();

        // activate(): anyone, after the timer; the whole escrow moves to the lockbox and legacy
        // withdrawals are paid from there.
        vm.warp(block.timestamp + 1 days);
        uint256 before = wst.balanceOf(L1_BRIDGE_PROXY);
        vm.prank(stranger);
        b.activate();
        assertEq(uint256(b.getBridgeMode()), uint256(CCIPMigrationSender.BridgeMode.MIGRATING));
        assertEq(wst.balanceOf(address(lockbox)), before);
        assertEq(wst.balanceOf(L1_BRIDGE_PROXY), 0);
        _mockRelay(messenger, l2Bridge);
        vm.prank(messenger);
        b.finalizeERC20Withdrawal(l1Token, l2Token, user, other, 1e18, "");
        assertEq(wst.balanceOf(other), 1e18);
        assertEq(wst.balanceOf(address(lockbox)), before - 1e18);
        assertEq(wst.balanceOf(L1_BRIDGE_PROXY), 0);

        // MIGRATING: deposits go to the Router. The lane quotes a fee, but Chainlink's wstETH L1
        // pool has no Base remote chain configured, so the send reverts with ChainNotAllowed.
        uint256 fee = b.getCCIPFee(user, 1e18);
        assertGt(fee, 0);
        vm.deal(user, fee * 2);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("ChainNotAllowed(uint64)", BASE_SELECTOR));
        b.depositERC20{value: fee * 2}(l1Token, l2Token, 1e18, 200_000, "");
        assertEq(wst.balanceOf(user), 9e18);

        // close(): anyone, after its timer; legacy receive rejected.
        vm.warp(block.timestamp + 10 days);
        vm.prank(stranger);
        b.close();
        assertEq(uint256(b.getBridgeMode()), uint256(CCIPMigrationSender.BridgeMode.CCIP_ONLY));
        vm.prank(messenger);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPMigrationSender.ErrorBridgeModeNotAllowed.selector, CCIPMigrationSender.BridgeMode.CCIP_ONLY
            )
        );
        b.finalizeERC20Withdrawal(l1Token, l2Token, user, other, 1e18, "");
    }
}

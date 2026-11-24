// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "openzeppelin-contracts-5.3.0/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "openzeppelin-contracts-5.3.0/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "openzeppelin-contracts-5.3.0/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {ERC20BridgedPermit} from "../contracts/token/ERC20BridgedPermit.sol";
import {ERC20Core} from "../contracts/token/ERC20Core.sol";
import {PermitExtension} from "../contracts/token/PermitExtension.sol";
import {Versioned} from "../contracts/utils/Versioned.sol";
import {LegacyERC20Bridged} from "./legacy/LegacyERC20Bridged.sol";
import {OssifiableProxyDouble} from "./legacy/OssifiableProxyDouble.sol";

/// @dev In-place upgrade of a fleet proxy (Base shape: lido-l2 `ERC20Bridged`, contract version 0)
///     to this implementation through `finalizeUpgrade_v3`, plus the two ABI additions the legacy
///     bridge relies on afterwards (`burnFrom`, `increaseAllowance`/`decreaseAllowance`).
contract WstethTokenMigrationTest is Test {
    string constant NAME = "Wrapped liquid staked Ether 2.0";
    string constant SYMBOL = "wstETH";
    uint256 constant KEY = 12345;
    bytes32 constant VERSION_SLOT = keccak256("lido.Versioned.contractVersion");
    bytes32 constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    address opexec = makeAddr("optimism-bridge-executor");
    address legacyBridge = makeAddr("legacy-l2-bridge");
    address spender = makeAddr("spender");
    address attacker = makeAddr("attacker");
    address holder;

    LegacyERC20Bridged legacyImpl;
    OssifiableProxyDouble proxy;
    ERC20BridgedPermit next;

    function setUp() public {
        holder = vm.addr(KEY);
        legacyImpl = new LegacyERC20Bridged(NAME, SYMBOL, 18, legacyBridge);
        proxy = new OssifiableProxyDouble(
            address(legacyImpl), opexec, abi.encodeCall(LegacyERC20Bridged.initialize, (NAME, SYMBOL))
        );
        LegacyERC20Bridged legacy = LegacyERC20Bridged(address(proxy));
        vm.prank(legacyBridge);
        legacy.bridgeMint(holder, 100e18);
        vm.prank(holder);
        legacy.approve(spender, 7e18);
        next = new ERC20BridgedPermit(NAME, SYMBOL, "2", 18);
    }

    function upgradeData(string memory version_, address admin_) internal pure returns (bytes memory) {
        return abi.encodeCall(ERC20BridgedPermit.finalizeUpgrade_v3, (version_, admin_));
    }

    function upgraded() internal returns (ERC20BridgedPermit) {
        vm.prank(opexec);
        proxy.proxy__upgradeToAndCall(address(next), upgradeData("2", opexec), false);
        return ERC20BridgedPermit(address(proxy));
    }

    function unauthorized(address account_, bytes32 role_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account_, role_);
    }

    function domainSeparator(address verifying_) internal view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(bytes(NAME)), keccak256(bytes("2")), block.chainid, verifying_)
        );
    }

    // ── prior state ───────────────────────────────────────────────────────────────────────────

    function test_LegacyDoubleStoresWhatTheFleetProxyStores() public view {
        assertEq(uint256(vm.load(address(proxy), bytes32(0))), 100e18);
        assertEq(uint256(vm.load(address(proxy), keccak256(abi.encode(holder, uint256(1))))), 100e18);
        assertEq(
            uint256(vm.load(address(proxy), keccak256(abi.encode(spender, keccak256(abi.encode(holder, uint256(2))))))),
            7e18
        );
        assertTrue(vm.load(address(proxy), keccak256("ERC20Metdata.dynamicMetadata")) != bytes32(0));
        assertEq(vm.load(address(proxy), VERSION_SLOT), bytes32(0));
        assertEq(vm.load(address(proxy), INITIALIZABLE_STORAGE), bytes32(0));
        assertEq(LegacyERC20Bridged(address(proxy)).bridge(), legacyBridge);
        assertEq(proxy.proxy__getAdmin(), opexec);
    }

    // ── finalizeUpgrade_v3 ────────────────────────────────────────────────────────────────────

    function test_FinalizeUpgradeV3_PreservesStateSeatsAdminAndSetsVersion3() public {
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IERC5267.EIP712DomainChanged();
        vm.expectEmit(true, true, true, true, address(proxy));
        emit Versioned.ContractVersionSet(3);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IAccessControl.RoleGranted(bytes32(0), opexec, opexec);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit Initializable.Initialized(2);
        vm.prank(opexec);
        proxy.proxy__upgradeToAndCall(address(next), upgradeData("2", opexec), false);

        ERC20BridgedPermit t = ERC20BridgedPermit(address(proxy));
        assertEq(proxy.proxy__getImplementation(), address(next));
        assertEq(t.name(), NAME);
        assertEq(t.symbol(), SYMBOL);
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), 100e18);
        assertEq(t.balanceOf(holder), 100e18);
        assertEq(t.allowance(holder, spender), 7e18);
        assertEq(t.getContractVersion(), 3);
        assertTrue(t.hasRole(bytes32(0), opexec));
        assertEq(t.getRoleMemberCount(bytes32(0)), 1);
        assertEq(t.getRoleMember(bytes32(0), 0), opexec);

        (, string memory dn, string memory dv, uint256 cid, address vc,,) = t.eip712Domain();
        assertEq(dn, NAME);
        assertEq(dv, "2");
        assertEq(cid, block.chainid);
        assertEq(vc, address(proxy));
        assertEq(t.DOMAIN_SEPARATOR(), domainSeparator(address(proxy)));

        assertEq(uint64(uint256(vm.load(address(proxy), INITIALIZABLE_STORAGE))), 2);
        assertEq(uint256(vm.load(address(proxy), VERSION_SLOT)), 3);
        for (uint256 slot = 3; slot < 256; slot++) {
            assertEq(vm.load(address(proxy), bytes32(slot)), bytes32(0));
        }

        (bool ok,) = address(proxy).call(abi.encodeWithSignature("bridgeMint(address,uint256)", holder, 1));
        assertFalse(ok);
        (ok,) = address(proxy).call(abi.encodeWithSignature("bridge()"));
        assertFalse(ok);
    }

    function test_FinalizeUpgradeV3_RunsOnce() public {
        ERC20BridgedPermit t = upgraded();
        vm.prank(opexec);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        t.finalizeUpgrade_v3("2", opexec);
        vm.prank(opexec);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        t.initialize(NAME, SYMBOL, "2", opexec);
        vm.expectRevert(ERC20BridgedPermit.ErrorMetadataIsAlreadyInitialized.selector);
        t.initialize(NAME, SYMBOL, "2");
        vm.expectRevert(Versioned.NonZeroContractVersionOnInit.selector);
        t.finalizeUpgrade_v2(NAME, "2");
    }

    function test_FinalizeUpgradeV3_OnlyTheProxyAdminEvenWhenNotAtomic() public {
        // A plain upgrade without the setup call opens the window the admin check closes.
        vm.prank(opexec);
        proxy.proxy__upgradeTo(address(next));
        ERC20BridgedPermit t = ERC20BridgedPermit(address(proxy));

        vm.prank(attacker);
        vm.expectRevert(ERC20BridgedPermit.ErrorNotProxyAdmin.selector);
        t.finalizeUpgrade_v3("2", attacker);
        assertFalse(t.hasRole(bytes32(0), attacker));
        assertEq(t.getContractVersion(), 0);

        vm.prank(opexec);
        t.finalizeUpgrade_v3("2", opexec);
        assertTrue(t.hasRole(bytes32(0), opexec));
        assertEq(t.getContractVersion(), 3);
    }

    function test_FinalizeUpgradeV3_ProxyLevelAdminCheckStillApplies() public {
        vm.prank(attacker);
        vm.expectRevert(OssifiableProxyDouble.ErrorNotAdmin.selector);
        proxy.proxy__upgradeToAndCall(address(next), upgradeData("2", attacker), false);
    }

    function test_FinalizeUpgradeV3_RejectsZeroAdmin() public {
        vm.prank(opexec);
        vm.expectRevert(ERC20BridgedPermit.ZeroAdmin.selector);
        proxy.proxy__upgradeToAndCall(address(next), upgradeData("2", address(0)), false);
    }

    function test_FinalizeUpgradeV3_RejectsAnImplementationBuiltForAnotherDomain() public {
        ERC20BridgedPermit otherName = new ERC20BridgedPermit("Other", SYMBOL, "2", 18);
        vm.prank(opexec);
        vm.expectRevert(PermitExtension.ErrorEIP712DomainMismatch.selector);
        proxy.proxy__upgradeToAndCall(address(otherName), upgradeData("2", opexec), false);
        vm.prank(opexec);
        vm.expectRevert(PermitExtension.ErrorEIP712DomainMismatch.selector);
        proxy.proxy__upgradeToAndCall(address(next), upgradeData("1", opexec), false);
    }

    function test_FinalizeUpgradeV3_RejectsUninitializedMetadata() public {
        OssifiableProxyDouble bare = new OssifiableProxyDouble(address(legacyImpl), opexec, "");
        vm.prank(opexec);
        vm.expectRevert(ERC20BridgedPermit.ErrorMetadataIsNotInitialized.selector);
        bare.proxy__upgradeToAndCall(address(next), upgradeData("2", opexec), false);
    }

    function test_FinalizeUpgradeV3_FromSyntheticContractVersion2() public {
        // Exercises version dispatch only, using the Base-shaped legacy double.
        // This does not establish compatibility with Optimism's metadata/initializer state.
        vm.store(address(proxy), VERSION_SLOT, bytes32(uint256(2)));
        ERC20BridgedPermit t = upgraded();
        assertEq(t.getContractVersion(), 3);
    }

    function test_FinalizeUpgradeV3_RejectsNonIncrementalVersions() public {
        vm.store(address(proxy), VERSION_SLOT, bytes32(uint256(1)));
        vm.prank(opexec);
        vm.expectRevert(Versioned.InvalidContractVersionIncrement.selector);
        proxy.proxy__upgradeToAndCall(address(next), upgradeData("2", opexec), false);
        vm.store(address(proxy), VERSION_SLOT, bytes32(uint256(3)));
        vm.prank(opexec);
        vm.expectRevert(Versioned.InvalidContractVersionIncrement.selector);
        proxy.proxy__upgradeToAndCall(address(next), upgradeData("2", opexec), false);
    }

    function test_FinalizeUpgradeV3_OnTheImplementationOrAFreshProxyReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        next.finalizeUpgrade_v3("2", opexec);
        OssifiableProxyDouble freshProxy = new OssifiableProxyDouble(
            address(next),
            opexec,
            abi.encodeWithSignature("initialize(string,string,string,address)", NAME, SYMBOL, "2", opexec)
        );
        vm.prank(opexec);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ERC20BridgedPermit(address(freshProxy)).finalizeUpgrade_v3("2", opexec);
    }

    function test_FinalizeUpgradeV3_ThroughATransparentProxyAdmin() public {
        TransparentUpgradeableProxy tp = new TransparentUpgradeableProxy(
            address(legacyImpl), address(this), abi.encodeCall(LegacyERC20Bridged.initialize, (NAME, SYMBOL))
        );
        ProxyAdmin pa = ProxyAdmin(address(uint160(uint256(vm.load(address(tp), ERC1967Utils.ADMIN_SLOT)))));
        vm.prank(legacyBridge);
        LegacyERC20Bridged(address(tp)).bridgeMint(holder, 5e18);

        pa.upgradeAndCall(ITransparentUpgradeableProxy(address(tp)), address(next), upgradeData("2", address(this)));
        ERC20BridgedPermit t = ERC20BridgedPermit(address(tp));
        assertEq(t.balanceOf(holder), 5e18);
        assertEq(t.getContractVersion(), 3);
        assertTrue(t.hasRole(bytes32(0), address(this)));
        assertEq(t.DOMAIN_SEPARATOR(), domainSeparator(address(tp)));

        // The ProxyAdmin's owner is not the proxy admin recorded in the EIP-1967 slot.
        TransparentUpgradeableProxy tp2 = new TransparentUpgradeableProxy(
            address(legacyImpl), address(this), abi.encodeCall(LegacyERC20Bridged.initialize, (NAME, SYMBOL))
        );
        ProxyAdmin pa2 = ProxyAdmin(address(uint160(uint256(vm.load(address(tp2), ERC1967Utils.ADMIN_SLOT)))));
        pa2.upgradeAndCall(ITransparentUpgradeableProxy(address(tp2)), address(next), "");
        vm.expectRevert(ERC20BridgedPermit.ErrorNotProxyAdmin.selector);
        ERC20BridgedPermit(address(tp2)).finalizeUpgrade_v3("2", address(this));
    }

    function test_PermitWorksAfterTheUpgrade() public {
        ERC20BridgedPermit t = upgraded();
        uint256 deadline = block.timestamp + 100;
        bytes32 body = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                holder,
                spender,
                uint256(42),
                t.nonces(holder),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, keccak256(abi.encodePacked(hex"1901", t.DOMAIN_SEPARATOR(), body)));
        t.permit(holder, spender, 42, deadline, v, r, s);
        assertEq(t.allowance(holder, spender), 42);
        assertEq(t.nonces(holder), 1);
    }

    function test_FourArgInitializeCannotSeatAnAdminInTheUpgradeWindow() public {
        // Review finding: on a legacy-shaped proxy (no OZ Initializable state, version 0, metadata
        // set) the fresh `initialize` must not be a second way to seat DEFAULT_ADMIN_ROLE.
        vm.prank(opexec);
        proxy.proxy__upgradeTo(address(next));
        ERC20BridgedPermit t = ERC20BridgedPermit(address(proxy));
        vm.prank(attacker);
        vm.expectRevert(ERC20BridgedPermit.ErrorMetadataIsAlreadyInitialized.selector);
        t.initialize(NAME, "x", "2", attacker);
        assertFalse(t.hasRole(bytes32(0), attacker));
        assertEq(t.symbol(), SYMBOL);
        assertEq(t.getContractVersion(), 0);
        // finalizeUpgrade_v2 stays harmless in the window: no roles, and v3 still lands afterwards.
        vm.prank(attacker);
        t.finalizeUpgrade_v2(NAME, "2");
        assertEq(t.getContractVersion(), 2);
        vm.prank(opexec);
        t.finalizeUpgrade_v3("2", opexec);
        assertEq(t.getContractVersion(), 3);
        assertTrue(t.hasRole(bytes32(0), opexec));
    }

    // ── what the legacy bridge needs afterwards ───────────────────────────────────────────────

    function test_AfterUpgrade_LegacyBridgeNeedsRolesAndAnAllowance() public {
        ERC20BridgedPermit t = upgraded();
        bytes32 minter = t.MINTER_ROLE();
        bytes32 burner = t.BURNER_ROLE();

        // Between the upgrade and the role grants the legacy bridge can neither mint nor burn.
        vm.prank(legacyBridge);
        vm.expectRevert(unauthorized(legacyBridge, minter));
        t.mint(holder, 1e18);
        vm.prank(legacyBridge);
        vm.expectRevert(unauthorized(legacyBridge, burner));
        t.burnFrom(holder, 1e18);

        vm.startPrank(opexec);
        t.grantRole(minter, legacyBridge);
        t.grantRole(burner, legacyBridge);
        vm.stopPrank();
        vm.prank(legacyBridge);
        t.mint(holder, 1e18);
        assertEq(t.balanceOf(holder), 101e18);

        // burnFrom is allowance based, unlike the removed bridgeBurn.
        vm.prank(legacyBridge);
        vm.expectRevert(ERC20Core.ErrorNotEnoughAllowance.selector);
        t.burnFrom(holder, 1e18);
        vm.prank(holder);
        t.approve(legacyBridge, 1e18);
        vm.prank(legacyBridge);
        t.burnFrom(holder, 1e18);
        assertEq(t.balanceOf(holder), 100e18);
        assertEq(t.allowance(holder, legacyBridge), 0);

        // CCIP_ONLY: roles revoked, the legacy mint path is closed on the token side too.
        vm.startPrank(opexec);
        t.revokeRole(minter, legacyBridge);
        t.revokeRole(burner, legacyBridge);
        vm.stopPrank();
        vm.prank(legacyBridge);
        vm.expectRevert(unauthorized(legacyBridge, minter));
        t.mint(holder, 1);
    }

    function test_BurnFrom_SpendsTheAllowanceExceptAnInfiniteOne() public {
        ERC20BridgedPermit t = upgraded();
        bytes32 burner = t.BURNER_ROLE();
        vm.prank(opexec);
        t.grantRole(burner, spender);

        vm.prank(spender);
        t.burnFrom(holder, 3e18);
        assertEq(t.allowance(holder, spender), 4e18);
        assertEq(t.balanceOf(holder), 97e18);
        assertEq(t.totalSupply(), 97e18);

        vm.prank(spender);
        vm.expectRevert(ERC20Core.ErrorNotEnoughAllowance.selector);
        t.burnFrom(holder, 5e18);

        vm.prank(holder);
        t.approve(spender, type(uint256).max);
        vm.prank(spender);
        t.burnFrom(holder, 97e18);
        assertEq(t.allowance(holder, spender), type(uint256).max);
        assertEq(t.balanceOf(holder), 0);
        vm.prank(spender);
        vm.expectRevert(ERC20Core.ErrorNotEnoughBalance.selector);
        t.burnFrom(holder, 1);

        vm.prank(attacker);
        vm.expectRevert(unauthorized(attacker, burner));
        t.burnFrom(holder, 0);
    }

    function test_IncreaseAndDecreaseAllowanceKeepTheLegacyAbi() public {
        ERC20BridgedPermit t = upgraded();
        vm.prank(holder);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit IERC20.Approval(holder, spender, 9e18);
        assertTrue(t.increaseAllowance(spender, 2e18));
        assertEq(t.allowance(holder, spender), 9e18);

        vm.prank(holder);
        assertTrue(t.decreaseAllowance(spender, 9e18));
        assertEq(t.allowance(holder, spender), 0);

        vm.prank(holder);
        vm.expectRevert(ERC20Core.ErrorDecreasedAllowanceBelowZero.selector);
        t.decreaseAllowance(spender, 1);
        vm.prank(holder);
        vm.expectRevert(ERC20Core.ErrorAccountIsZeroAddress.selector);
        t.increaseAllowance(address(0), 1);
    }
}

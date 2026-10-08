// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable} from "openzeppelin-contracts-5.3.0/contracts/access/Ownable.sol";
import {ProxyAdmin} from "openzeppelin-contracts-5.3.0/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "openzeppelin-contracts-5.3.0/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "openzeppelin-contracts-5.3.0/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ERC20BridgedPermit} from "../contracts/token/ERC20BridgedPermit.sol";

// Behavior cases adapted from upstream ERC20BridgedPermit, PermitExtension and ERC20Metadata
// tests, exercised on the maintained token with mint/burn roles behind OpenZeppelin 5.3.0's
// TransparentUpgradeableProxy. Storage cases pin slots; they do not test fleet role migration.
contract WstethTokenTest is Test {
    ERC20BridgedPermit token;
    ERC20BridgedPermit implementation;
    TransparentUpgradeableProxy proxy;
    ProxyAdmin proxyAdmin;
    address holder;
    address spender = address(0xBEEF);
    uint256 constant KEY = 12345;
    string constant NAME = "Wrapped liquid staked Ether 2.0";

    // ERC-7201 namespaces of the OpenZeppelin 5.0.2 bases the token inherits. The deployed fleet
    // (Optimism, Arbitrum, Base) keeps only ERC20Core state in linear slots 0-2; everything the
    // OZ bases own must live here, never in linear slots.
    bytes32 constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant ACCESS_CONTROL_STORAGE = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;
    bytes32 constant ACCESS_CONTROL_ENUMERABLE_STORAGE =
        0xc1f6fe24621ce81ec5827caf0253cadb74709b061630e6b55e82371705932000;

    function fresh() internal returns (ERC20BridgedPermit) {
        return new ERC20BridgedPermit(NAME, "wstETH", "2", 18);
    }

    function initData(string memory name, address admin) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("initialize(string,string,string,address)", name, "wstETH", "2", admin);
    }

    function setUp() public {
        holder = vm.addr(KEY);
        implementation = fresh();
        // initialOwner of the ProxyAdmin is this test, standing in for the governance executor.
        proxy = new TransparentUpgradeableProxy(address(implementation), address(this), initData(NAME, address(this)));
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT)))));
        token = ERC20BridgedPermit(address(proxy));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.grantRole(token.BURNER_ROLE(), address(this));
    }

    function signature(uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 body = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            holder, spender, uint256(42), token.nonces(holder), deadline));
        return vm.sign(KEY, keccak256(abi.encodePacked(hex"1901", token.DOMAIN_SEPARATOR(), body)));
    }

    function implementationOf(address p) internal view returns (address) {
        return address(uint160(uint256(vm.load(p, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function unauthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    function testMetadataAndAtomicInitialization() public view {
        assertEq(token.name(), NAME); assertEq(token.symbol(), "wstETH"); assertEq(token.decimals(), 18);
        assertEq(token.getContractVersion(), 2);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)));
        assertEq(implementationOf(address(proxy)), address(implementation));
        assertEq(proxyAdmin.owner(), address(this));
        assertTrue(address(proxyAdmin).code.length > 0);
    }

    function testEnumerableAdminHandover() public {
        bytes32 admin = token.DEFAULT_ADMIN_ROLE();
        assertEq(token.getRoleMemberCount(admin), 1);
        assertEq(token.getRoleMember(admin, 0), address(this));
        token.grantRole(admin, holder);
        assertEq(token.getRoleMemberCount(admin), 2);
        token.renounceRole(admin, address(this));
        assertFalse(token.hasRole(admin, address(this)));
        assertEq(token.getRoleMemberCount(admin), 1);
        assertEq(token.getRoleMember(admin, 0), holder);
        bytes32 minter = token.MINTER_ROLE();
        vm.expectRevert(unauthorized(address(this), admin)); token.grantRole(minter, spender);
        vm.prank(holder); token.grantRole(minter, spender);
        assertTrue(token.hasRole(minter, spender));
    }

    function testNoCustomCCIPAdminHooks() public {
        (bool readable,) = address(token).staticcall(abi.encodeWithSignature("getCCIPAdmin()"));
        (bool writable,) = address(token).call(abi.encodeWithSignature("setCCIPAdmin(address)", holder));
        assertFalse(readable);
        assertFalse(writable);
    }

    function testImplementationAndProxyCannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(NAME, "wstETH", "2", address(this));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize(NAME, "wstETH", "2", address(this));
        vm.expectRevert(ERC20BridgedPermit.ErrorMetadataIsAlreadyInitialized.selector);
        token.initialize(NAME, "wstETH", "2");
        vm.expectRevert(); token.finalizeUpgrade_v2(NAME, "2");
    }

    function testZeroAdminRejected() public {
        vm.expectRevert(ERC20BridgedPermit.ZeroAdmin.selector);
        new TransparentUpgradeableProxy(address(implementation), address(this), initData(NAME, address(0)));
    }

    function testMismatchedDomainRejected() public {
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(implementation), address(this), initData("Wrong", address(this)));
    }

    function testInitializationEmitsEIP712DomainChanged() public {
        // ERC-5267: the event MUST be emitted whenever the advertised domain may have changed, and
        // initialize() is where this token first writes name/version into eip712Domain().
        ERC20BridgedPermit impl = fresh();
        bytes memory data = initData(NAME, address(this));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(true, true, true, true, predicted);
        emit IERC5267.EIP712DomainChanged();
        new TransparentUpgradeableProxy(address(impl), address(this), data);
    }

    function testMintBurnAndRevocation() public {
        token.mint(address(this), 100); token.burn(40);
        assertEq(token.balanceOf(address(this)), 60); assertEq(token.totalSupply(), 60);
        bytes32 role = token.MINTER_ROLE(); token.revokeRole(role, address(this));
        vm.expectRevert(unauthorized(address(this), role)); token.mint(holder, 1);
        role = token.BURNER_ROLE(); token.revokeRole(role, address(this));
        vm.expectRevert(unauthorized(address(this), role)); token.burn(1);
    }

    function testUnauthorizedMintBurnAndRoleGrant() public {
        bytes32 minter = token.MINTER_ROLE();
        bytes32 burner = token.BURNER_ROLE();
        bytes32 admin = token.DEFAULT_ADMIN_ROLE();
        vm.startPrank(holder);
        vm.expectRevert(unauthorized(holder, minter)); token.mint(holder, 1);
        vm.expectRevert(unauthorized(holder, burner)); token.burn(1);
        vm.expectRevert(unauthorized(holder, admin)); token.grantRole(minter, holder);
        vm.stopPrank();
    }

    function testTransferAndAllowance() public {
        token.mint(holder, 100);
        vm.prank(holder); token.approve(spender, 60);
        vm.prank(spender); token.transferFrom(holder, spender, 40);
        assertEq(token.allowance(holder, spender), 20); assertEq(token.balanceOf(spender), 40);
        vm.prank(holder); token.transfer(spender, 10);
        assertEq(token.balanceOf(holder), 50); assertEq(token.totalSupply(), 100);
    }

    function testPermitReplayRejected() public {
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = signature(deadline);
        token.permit(holder, spender, 42, deadline, v, r, s);
        assertEq(token.allowance(holder, spender), 42); assertEq(token.nonces(holder), 1);
        vm.expectRevert(); token.permit(holder, spender, 42, deadline, v, r, s);
        assertEq(token.nonces(holder), 1);
    }

    function testExpiredPermitRejected() public {
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = signature(deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(); token.permit(holder, spender, 42, deadline, v, r, s);
        assertEq(token.nonces(holder), 0);
    }

    function testInvalidSignerRejected() public {
        (uint8 v, bytes32 r, bytes32 s) = signature(block.timestamp + 100);
        vm.expectRevert(); token.permit(spender, holder, 42, block.timestamp + 100, v, r, s);
        assertEq(token.nonces(spender), 0);
    }

    function testDomainSeparatorMatchesAdvertisedDomain() public view {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = token.eip712Domain();
        bytes32 expected = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifying));
        assertEq(verifying, address(proxy));
        assertEq(token.DOMAIN_SEPARATOR(), expected);
        // The implementation answers for itself, never for the proxy: distinct separators.
        assertTrue(implementation.DOMAIN_SEPARATOR() != token.DOMAIN_SEPARATOR());
    }

    function testUpgradePreservesBalancesRolesAndPendingPermit() public {
        token.mint(holder, 100);
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = signature(deadline);
        ERC20BridgedPermit next = fresh();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(next), "");
        assertEq(implementationOf(address(proxy)), address(next));
        assertEq(token.balanceOf(holder), 100); assertEq(token.totalSupply(), 100);
        assertTrue(token.hasRole(token.MINTER_ROLE(), address(this)));
        token.permit(holder, spender, 42, deadline, v, r, s);
        assertEq(token.nonces(holder), 1); assertEq(token.allowance(holder, spender), 42);
    }

    function testUnauthorizedProxyOperationsRejected() public {
        ITransparentUpgradeableProxy p = ITransparentUpgradeableProxy(address(proxy));
        vm.startPrank(holder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder));
        proxyAdmin.upgradeAndCall(p, address(implementation), "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder));
        proxyAdmin.transferOwnership(holder);
        // Only the ProxyAdmin reaches the proxy's own upgrade dispatch; anyone else falls through
        // to the implementation, which has no such function.
        vm.expectRevert();
        p.upgradeToAndCall(address(implementation), "");
        vm.stopPrank();
    }

    function testAdminHandover() public {
        proxyAdmin.transferOwnership(holder);
        assertEq(proxyAdmin.owner(), holder);
        ITransparentUpgradeableProxy p = ITransparentUpgradeableProxy(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        proxyAdmin.upgradeAndCall(p, address(implementation), "");
        vm.prank(holder); proxyAdmin.upgradeAndCall(p, address(implementation), "");
    }

    function testRenouncedProxyAdminFreezesImplementation() public {
        // The TransparentUpgradeableProxy equivalent of ossification: no owner, no upgrades, ever.
        proxyAdmin.renounceOwnership();
        assertEq(proxyAdmin.owner(), address(0));
        ITransparentUpgradeableProxy p = ITransparentUpgradeableProxy(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        proxyAdmin.upgradeAndCall(p, address(implementation), "");
        assertEq(implementationOf(address(proxy)), address(implementation));
    }

    function testNoLegacyBridgeAuthority() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("bridge()")); assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("bridgeMint(address,uint256)", holder, 1)); assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("bridgeBurn(address,uint256)", holder, 1)); assertFalse(ok);
    }

    // ── storage layout ──────────────────────────────────────────────────────────────────────

    function testNamespaceConstantsMatchErc7201() public pure {
        assertEq(INITIALIZABLE_STORAGE, erc7201("openzeppelin.storage.Initializable"));
        assertEq(ACCESS_CONTROL_STORAGE, erc7201("openzeppelin.storage.AccessControl"));
        assertEq(ACCESS_CONTROL_ENUMERABLE_STORAGE, erc7201("openzeppelin.storage.AccessControlEnumerable"));
    }

    function testOnlyERC20CoreUsesLinearStorage() public {
        token.mint(holder, 100);
        vm.prank(holder); token.approve(spender, 7);
        assertEq(uint256(vm.load(address(proxy), bytes32(uint256(0)))), 100); // totalSupply
        assertEq(uint256(vm.load(address(proxy), keccak256(abi.encode(holder, uint256(1))))), 100); // balanceOf
        assertEq(uint256(vm.load(address(proxy), keccak256(abi.encode(spender, keccak256(abi.encode(holder, uint256(2))))))), 7);
        // Slots the OZ 4.x build used (Initializable 3, AccessControl 104, Enumerable 154) and
        // every other linear slot the fleet proxies carry empty stay untouched.
        for (uint256 slot = 3; slot < 256; slot++) {
            assertEq(vm.load(address(proxy), bytes32(slot)), bytes32(0));
        }
    }

    function testOzStateLivesInNamespaces() public view {
        // Initializable: _initialized == 2 after reinitializer(2), in the low 64 bits of the namespace slot.
        assertEq(uint64(uint256(vm.load(address(proxy), INITIALIZABLE_STORAGE))), 2);
        // AccessControl: _roles[role].hasRole[account] == true for this test's DEFAULT_ADMIN_ROLE.
        bytes32 roleData = keccak256(abi.encode(bytes32(0), ACCESS_CONTROL_STORAGE));
        assertEq(uint256(vm.load(address(proxy), keccak256(abi.encode(address(this), roleData)))), 1);
        // AccessControlEnumerable: _roleMembers[role]._inner._values.length == 1 for DEFAULT_ADMIN_ROLE.
        bytes32 members = keccak256(abi.encode(bytes32(0), ACCESS_CONTROL_ENUMERABLE_STORAGE));
        assertEq(uint256(vm.load(address(proxy), members)), 1);
    }

    function testLidoUnstructuredSlotsAreUnchanged() public view {
        // These constants are what the deployed fleet (Optimism, Arbitrum, Base) reads today; an
        // future migration depends on these staying put, AND on a separate migration initializer
        // to seat roles on an already-v2 proxy. This build supports fresh deployments. Proxies initialized
        // with the earlier OpenZeppelin 4.x build (Mantle Sepolia dev: `_initialized` in linear slot 3,
        // roles at 104/154) are NOT upgrade targets for this implementation — they keep their roles in
        // slots this code never reads — and must be redeployed (README, "Storage layout").
        bytes32 version = keccak256("lido.Versioned.contractVersion");
        assertEq(uint256(vm.load(address(proxy), version)), 2);
        bytes32 metadata = keccak256("ERC20Metdata.dynamicMetadata");
        assertTrue(vm.load(address(proxy), metadata) != bytes32(0)); // name string head
        bytes32 eip5267 = keccak256("PermitExtension.eip5267MetadataSlot");
        assertTrue(vm.load(address(proxy), eip5267) != bytes32(0)); // domain name string head
        bytes32 nonces = keccak256("PermitExtension.NONCE_BY_ADDRESS_POSITION");
        assertEq(uint256(vm.load(address(proxy), keccak256(abi.encode(holder, nonces)))), 0);
    }

    function erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}

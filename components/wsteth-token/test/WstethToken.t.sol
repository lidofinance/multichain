// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.10;

interface Vm {
    function addr(uint256) external returns (address);
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
}

contract Test {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    function assertTrue(bool value) internal pure { require(value, "expected true"); }
    function assertFalse(bool value) internal pure { require(!value, "expected false"); }
    function assertEq(uint256 a, uint256 b) internal pure { require(a == b, "uint mismatch"); }
    function assertEq(address a, address b) internal pure { require(a == b, "address mismatch"); }
    function assertEq(string memory a, string memory b) internal pure {
        require(keccak256(bytes(a)) == keccak256(bytes(b)), "string mismatch");
    }
}
import {ERC20BridgedPermit} from "../contracts/token/ERC20BridgedPermit.sol";
import {OssifiableProxy} from "../contracts/proxy/OssifiableProxy.sol";

// Behavior cases adapted from upstream ERC20BridgedPermit, PermitExtension,
// ERC20Metadata and OssifiableProxy tests; exercised on the maintained token with mint/burn roles.
contract WstethTokenTest is Test {
    ERC20BridgedPermit token;
    ERC20BridgedPermit implementation;
    OssifiableProxy proxy;
    address holder;
    address spender = address(0xBEEF);
    uint256 constant KEY = 12345;
    string constant NAME = "Wrapped liquid staked Ether 2.0";

    function fresh() internal returns (ERC20BridgedPermit) {
        return new ERC20BridgedPermit(NAME, "wstETH", "2", 18);
    }

    function setUp() public {
        holder = vm.addr(KEY);
        implementation = fresh();
        proxy = new OssifiableProxy(address(implementation), address(this),
            abi.encodeWithSignature("initialize(string,string,string,address)", NAME, "wstETH", "2", address(this)));
        token = ERC20BridgedPermit(address(proxy));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.grantRole(token.BURNER_ROLE(), address(this));
    }

    function signature(uint256 deadline) internal returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 body = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            holder, spender, uint256(42), token.nonces(holder), deadline));
        return vm.sign(KEY, keccak256(abi.encodePacked(hex"1901", token.DOMAIN_SEPARATOR(), body)));
    }

    function testMetadataAndAtomicInitialization() public {
        assertEq(token.name(), NAME); assertEq(token.symbol(), "wstETH"); assertEq(token.decimals(), 18);
        assertEq(token.getContractVersion(), 2);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)));
        assertEq(proxy.proxy__getAdmin(), address(this));
        assertEq(proxy.proxy__getImplementation(), address(implementation));
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
        vm.expectRevert(); token.grantRole(minter, spender);
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
        vm.expectRevert(); implementation.initialize(NAME, "wstETH", "2", address(this));
        vm.expectRevert(); token.initialize(NAME, "wstETH", "2", address(this));
        vm.expectRevert(); token.initialize(NAME, "wstETH", "2");
        vm.expectRevert(); token.finalizeUpgrade_v2(NAME, "2");
    }

    function testZeroAdminRejected() public {
        vm.expectRevert(ERC20BridgedPermit.ZeroAdmin.selector);
        new OssifiableProxy(address(implementation), address(this),
            abi.encodeWithSignature("initialize(string,string,string,address)", NAME, "wstETH", "2", address(0)));
    }

    function testMismatchedDomainRejected() public {
        vm.expectRevert();
        new OssifiableProxy(address(implementation), address(this),
            abi.encodeWithSignature("initialize(string,string,string,address)", "Wrong", "wstETH", "2", address(this)));
    }

    function testMintBurnAndRevocation() public {
        token.mint(address(this), 100); token.burn(40);
        assertEq(token.balanceOf(address(this)), 60); assertEq(token.totalSupply(), 60);
        bytes32 role = token.MINTER_ROLE(); token.revokeRole(role, address(this));
        vm.expectRevert(); token.mint(holder, 1);
        role = token.BURNER_ROLE(); token.revokeRole(role, address(this));
        vm.expectRevert(); token.burn(1);
    }

    function testUnauthorizedMintBurnAndRoleGrant() public {
        bytes32 role = token.MINTER_ROLE();
        vm.startPrank(holder);
        vm.expectRevert(); token.mint(holder, 1);
        vm.expectRevert(); token.burn(1);
        vm.expectRevert(); token.grantRole(role, holder);
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

    function testUpgradePreservesBalancesRolesAndPendingPermit() public {
        token.mint(holder, 100);
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = signature(deadline);
        ERC20BridgedPermit next = fresh();
        proxy.proxy__upgradeTo(address(next));
        assertEq(proxy.proxy__getImplementation(), address(next));
        assertEq(token.balanceOf(holder), 100); assertEq(token.totalSupply(), 100);
        assertTrue(token.hasRole(token.MINTER_ROLE(), address(this)));
        token.permit(holder, spender, 42, deadline, v, r, s);
        assertEq(token.nonces(holder), 1); assertEq(token.allowance(holder, spender), 42);
    }

    function testUnauthorizedProxyOperationsRejected() public {
        vm.startPrank(holder);
        vm.expectRevert(OssifiableProxy.ErrorNotAdmin.selector); proxy.proxy__upgradeTo(address(implementation));
        vm.expectRevert(OssifiableProxy.ErrorNotAdmin.selector); proxy.proxy__changeAdmin(holder);
        vm.expectRevert(OssifiableProxy.ErrorNotAdmin.selector); proxy.proxy__ossify();
        vm.expectRevert(OssifiableProxy.ErrorNotAdmin.selector); proxy.proxy__upgradeToAndCall(address(implementation), "", false);
        vm.stopPrank();
    }

    function testAdminHandover() public {
        proxy.proxy__changeAdmin(holder);
        assertEq(proxy.proxy__getAdmin(), holder);
        vm.expectRevert(OssifiableProxy.ErrorNotAdmin.selector); proxy.proxy__upgradeTo(address(implementation));
        vm.prank(holder); proxy.proxy__upgradeTo(address(implementation));
    }

    function testOssificationIsPermanent() public {
        proxy.proxy__ossify(); assertTrue(proxy.proxy__getIsOssified());
        vm.expectRevert(OssifiableProxy.ErrorProxyIsOssified.selector); proxy.proxy__upgradeTo(address(implementation));
        vm.expectRevert(OssifiableProxy.ErrorProxyIsOssified.selector); proxy.proxy__changeAdmin(holder);
        vm.expectRevert(OssifiableProxy.ErrorProxyIsOssified.selector); proxy.proxy__upgradeToAndCall(address(implementation), "", false);
    }

    function testNoLegacyBridgeAuthority() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("bridge()")); assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("bridgeMint(address,uint256)", holder, 1)); assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("bridgeBurn(address,uint256)", holder, 1)); assertFalse(ok);
    }
}

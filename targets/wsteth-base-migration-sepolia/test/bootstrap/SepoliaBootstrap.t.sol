// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBaselineRegistry {
    function getTokenConfig(address) external view returns (address, address, address);
    function owner() external view returns (address);
}

interface IBaselinePool {
    function getToken() external view returns (address);
    function owner() external view returns (address);
    function getAvailableTokens(uint64) external view returns (uint256);
    function isSiloed(uint64) external view returns (bool);
    function getRemotePools(uint64) external view returns (bytes[] memory);
    function getRemoteToken(uint64) external view returns (bytes memory);
}

interface IFullWstETH {
    function stETH() external view returns (address);
    function getStETHByWstETH(uint256) external view returns (uint256);
}

/// @notice Runs before hub deployment. Final migration tests use the same run's later state.
contract SepoliaBootstrapTest is Test {
    string internal baseline;
    uint256 internal l1;
    address internal token;
    address internal pool;

    function setUp() public {
        baseline = vm.readFile("state/bootstrap.json");
        l1 = vm.createSelectFork(vm.envString("RPC_SEPOLIA"));
        token = vm.parseJsonAddress(baseline, ".token");
        pool = vm.parseJsonAddress(baseline, ".oldPool");
    }

    function test_full_lido_and_pristine_backed_token() public {
        string memory core = vm.readFile("state/l1.json");
        assertEq(IFullWstETH(token).stETH(), vm.parseJsonAddress(core, ".stETH"));
        assertGt(IERC20(token).totalSupply(), 0);
        assertGe(
            IERC20(IFullWstETH(token).stETH()).balanceOf(token),
            IFullWstETH(token).getStETHByWstETH(IERC20(token).totalSupply())
        );
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("getCCIPAdmin()"));
        assertTrue(!success || data.length == 0, "testnet registration hook changed the token");
        string[7] memory keys = [
            string(".agent"),
            ".voting",
            ".lidoLocator",
            ".stETH",
            ".dg.dualGovernance",
            ".dg.adminExecutor",
            ".dg.timelock"
        ];
        for (uint256 i; i < keys.length; ++i) {
            assertGt(vm.parseJsonAddress(core, keys[i]).code.length, 0, keys[i]);
        }
    }

    function test_official_registry_and_legacy_pool_authority() public {
        address registry = vm.parseJsonAddress(baseline, ".registry");
        assertEq(registry, 0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82);
        (address admin, address pending, address registeredPool) = IBaselineRegistry(registry).getTokenConfig(token);
        assertEq(admin, vm.parseJsonAddress(baseline, ".timelock"));
        assertEq(pending, address(0));
        assertEq(registeredPool, pool);
        assertEq(IBaselinePool(pool).owner(), admin);
        assertEq(IBaselinePool(pool).getToken(), token);
        // Use an unregistered token so AlreadyRegistered cannot hide an authorization defect.
        address unregistered = IFullWstETH(token).stETH();
        (admin, pending, registeredPool) = IBaselineRegistry(registry).getTokenConfig(unregistered);
        assertEq(admin, address(0));
        assertEq(pending, address(0));
        assertEq(registeredPool, address(0));
        address unauthorized = makeAddr("unauthorized-registrant");
        vm.prank(unauthorized);
        (bool registered, bytes memory reason) =
            registry.call(abi.encodeWithSignature("proposeAdministrator(address,address)", unregistered, address(this)));
        assertFalse(registered, "registration must retain its permission checks");
        assertEq(reason, abi.encodeWithSignature("OnlyRegistryModuleOrOwner(address)", unauthorized));
    }

    function test_two_reciprocal_existing_lanes_and_custody() public {
        uint256 total;
        for (uint256 i; i < 2; ++i) {
            string memory k = string.concat(".lanes[", vm.toString(i), "]");
            uint64 selector = uint64(vm.parseJsonUint(baseline, string.concat(k, ".chain.selector")));
            uint256 amount = vm.parseJsonUint(baseline, string.concat(k, ".amount"));
            address remoteToken = vm.parseJsonAddress(baseline, string.concat(k, ".token"));
            address remotePool = vm.parseJsonAddress(baseline, string.concat(k, ".pool"));
            assertEq(IBaselinePool(pool).isSiloed(selector), vm.parseJsonBool(baseline, string.concat(k, ".siloed")));
            assertEq(IBaselinePool(pool).getAvailableTokens(selector), amount);
            assertEq(IBaselinePool(pool).getRemotePools(selector)[0], abi.encode(remotePool));
            assertEq(IBaselinePool(pool).getRemoteToken(selector), abi.encode(remoteToken));
            total += amount;
        }
        assertEq(IERC20(token).balanceOf(pool), total);
    }

    function test_base_starts_on_legacy_bridge_with_backing() public {
        uint256 amount = vm.parseJsonUint(baseline, ".baseSeedWei");
        assertEq(IERC20(token).balanceOf(vm.parseJsonAddress(baseline, ".l1Bridge")), amount);
        vm.createSelectFork(vm.envString("RPC_BASE_SEPOLIA"));
        address baseToken = vm.parseJsonAddress(baseline, ".baseToken");
        assertEq(IERC20(baseToken).totalSupply(), amount);
        (bool success, bytes memory bridge) = baseToken.staticcall(abi.encodeWithSignature("bridge()"));
        assertTrue(success);
        assertEq(abi.decode(bridge, (address)), vm.parseJsonAddress(baseline, ".baseBridge"));
    }
}

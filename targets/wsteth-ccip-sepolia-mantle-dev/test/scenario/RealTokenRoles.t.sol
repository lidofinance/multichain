// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BridgeScenarioBase} from "./BridgeScenarioBase.sol";

interface IRoleToken {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function MINTER_ROLE() external view returns (bytes32);
    function BURNER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleMemberCount(bytes32 role) external view returns (uint256);
}

interface ICcipAdminToken {
    function getCCIPAdmin() external view returns (address);
}

interface ITokenAdminRegistryLike {
    struct TokenConfig {
        address administrator;
        address pendingAdministrator;
        address tokenPool;
    }

    function getTokenConfig(address token) external view returns (TokenConfig memory);
}

/// @title RealTokenRoles — the token authority matrix the component's 1_Deploy and
/// 3_SetPoolAndTransferOwnership leave behind, read from the DEPLOYED contracts.
/// @notice The spoke token is deployed by the component (ERC20BridgedPermit behind a transparent
/// proxy) with the deployer as its transient administrator; 3_SetPool registers it, binds the pool,
/// hands the administration to the DAO and renounces the deployer's role. These checks pin that
/// end state here as well as in state-mate, so the scenario log carries it next to the lane evidence.
contract RealTokenRolesTest is BridgeScenarioBase {
    function setUp() public {
        _setUpForksAndRecord();
    }

    function test_SpokeTokenRolesBelongToPoolAndDao() public {
        vm.selectFork(l2Fork);
        IRoleToken token = IRoleToken(l2.token);
        bytes32 admin = token.DEFAULT_ADMIN_ROLE();
        bytes32 minter = token.MINTER_ROLE();
        bytes32 burner = token.BURNER_ROLE();

        assertTrue(token.hasRole(admin, l2.govAdmin), "DAO executor administers the token");
        assertTrue(token.hasRole(minter, l2.pool), "pool mints");
        assertTrue(token.hasRole(burner, l2.pool), "pool burns");
        assertFalse(token.hasRole(admin, l2.deployer), "deployer renounced the admin role");
        assertFalse(token.hasRole(minter, l2.deployer), "deployer never minted");
        assertFalse(token.hasRole(burner, l2.deployer), "deployer never burned");
        assertFalse(token.hasRole(admin, l2.timelock), "timelock does not administer the token");

        // Cardinalities: the only checks that can see an EXTRA holder.
        assertEq(token.getRoleMemberCount(admin), 1, "one token administrator");
        assertEq(token.getRoleMemberCount(minter), 1, "one minter");
        assertEq(token.getRoleMemberCount(burner), 1, "one burner");
    }

    function test_RegistryAdministrationAndPoolBindingOnBothChains() public {
        vm.selectFork(l1Fork);
        _assertRegistry(l1, "l1");
        vm.selectFork(l2Fork);
        _assertRegistry(l2, "l2");
    }

    /// @dev The scratch hub token (core patch 0001) exposes getCCIPAdmin(); 3_SetPool moves it
    /// from the deployer to the DAO Agent after registering through it.
    function test_HubTokenCcipAdminIsTheDao() public {
        vm.selectFork(l1Fork);
        assertEq(ICcipAdminToken(l1.token).getCCIPAdmin(), l1.govAdmin, "hub token CCIP admin");
    }

    function _assertRegistry(Ctx storage c, string memory tag) internal view {
        ITokenAdminRegistryLike.TokenConfig memory cfg = ITokenAdminRegistryLike(c.tar).getTokenConfig(c.token);
        assertEq(cfg.administrator, c.timelock, string.concat(tag, ": registry administrator is the timelock"));
        assertEq(cfg.pendingAdministrator, address(0), string.concat(tag, ": no pending administrator"));
        assertEq(cfg.tokenPool, c.pool, string.concat(tag, ": registry pool"));
    }
}

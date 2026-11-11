// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {
    MigrationBase,
    IOssifiableProxy,
    IBridgeExecutorLike,
    ITokenAdminRegistryLike,
    IAccessControlLike,
    ICrossDomainMessengerLike,
    IMigrationBridgeLike
} from "./MigrationBase.s.sol";

interface IVersionedLike {
    function getContractVersion() external view returns (uint256);
}

interface IMigrationPolicyLike {
    function getPolicyEngine() external view returns (address);
}

/// @notice Step 06, part 3 (Base), read-only: after the bash relay queued and executed the action
///         set, prove the executed set is the one the Agent sent and that every post-condition of
///         the vote's Base part holds. Runs without --broadcast.
contract MigrationL2Verify is MigrationBase {
    function run() external {
        _load();
        string memory l2Deploy = vm.readFile(vm.envString("L2_DEPLOY_JSON"));
        string memory l1Upgrade = vm.readFile(vm.envString("L1_UPGRADE_JSON"));
        uint256 actionsSetId = vm.envUint("ACTIONS_SET_ID");
        bytes32 relayedHash = vm.envBytes32("RELAYED_HASH");

        ActionSetA memory a = _actionSetAInputs(l2Deploy);
        bytes memory expected = _actionSetA(a);
        require(
            keccak256(expected) == vm.parseJsonBytes32(l1Upgrade, ".queueCalldataHash"),
            "the relayed action set is not the one the Agent sent"
        );

        address bridge = a.bridge;
        address messenger = _addr(l2State, ".messenger");
        require(ICrossDomainMessengerLike(messenger).successfulMessages(relayedHash), "governance message not relayed");
        require(IBridgeExecutorLike(a.executor).getCurrentState(actionsSetId) == 1, "action set not executed");

        require(IOssifiableProxy(a.token).proxy__getImplementation() == a.tokenImplementation, "token not upgraded");
        require(IOssifiableProxy(bridge).proxy__getImplementation() == a.bridgeImplementation, "bridge not upgraded");
        require(IVersionedLike(a.token).getContractVersion() == 3, "token contract version is not 3");
        IAccessControlLike token = IAccessControlLike(a.token);
        require(token.hasRole(DEFAULT_ADMIN_ROLE, a.executor), "executor is not the token administrator");
        require(token.hasRole(MINTER_ROLE, bridge) && token.hasRole(BURNER_ROLE, bridge), "bridge lacks token roles");
        require(token.hasRole(MINTER_ROLE, a.pool) && token.hasRole(BURNER_ROLE, a.pool), "pool lacks token roles");
        require(IMigrationPolicyLike(a.hooks).getPolicyEngine() == bridge, "outbound migration gate missing");

        IMigrationBridgeLike b = IMigrationBridgeLike(bridge);
        require(b.getBridgeMode() == 0, "bridge is not in LEGACY mode");
        require(b.isInitialized() && b.isDepositsEnabled() && b.isWithdrawalsEnabled(), "bridge flags changed");
        require(IAccessControlLike(bridge).hasRole(DEFAULT_ADMIN_ROLE, a.executor), "bridge admin role lost");
        require(b.getActivationTime() == a.activateAt && b.getCloseTime() == a.closeAt, "L2 timers not set");
        require(!b.isActivated() && !b.isClosed(), "L2 bridge already activated or closed");
        require(b.ccipTokenAdminRegistry() == a.registry && b.ccipTokenPool() == a.pool, "L2 bridge lane wiring");

        ITokenAdminRegistryLike.TokenConfig memory config = ITokenAdminRegistryLike(a.registry).getTokenConfig(a.token);
        require(config.administrator == a.timelock, "registry administrator is not the Base timelock");
        require(config.pendingAdministrator == address(0), "registry administration still pending");
        require(config.tokenPool == a.pool, "registry pool is not the Base pool");

        string memory o = "l2-execute";
        vm.serializeUint(o, "actionsSetId", actionsSetId);
        vm.serializeBytes32(o, "relayedMessageHash", relayedHash);
        string memory json = vm.serializeBytes32(o, "executedActionSetHash", keccak256(expected));
        vm.writeJson(json, vm.envString("OUT_JSON"));
        console2.log("action set", actionsSetId, "executed; Base token, bridge, roles, registry and timers verified");
    }
}

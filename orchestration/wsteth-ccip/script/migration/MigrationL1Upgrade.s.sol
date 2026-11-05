// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {
    MigrationBase,
    IL1BridgeLike,
    IOssifiableProxy,
    ICrossDomainMessengerLike,
    ITokenAdminRegistryLike,
    IMigrationBridgeLike,
    ILidoTimelockLike,
    ILockBoxLike
} from "./MigrationBase.s.sol";

/// @notice Step 06 (Ethereum): the Aragon Agent executes the one vote using the prepared
///         implementation: upgrade the L1 bridge in place,
///         authorize it on the lane lockbox through the timelock's admin bypass, set its two
///         migration timers, and send the governance message that queues the Base action set A′.
///         On a fork the Agent is impersonated; on mainnet this is the vote's enactment.
///         Prereq: the L1 Lido timelock administers the token in the Ethereum registry with the hub
///         pool bound (Chainlink's cutover, step 05h on a hub target, accepted in step 07), so the
///         L1 `activate()` guard can be met, and both timelocks are administered by the DAO (step 07).
///         The Base registry entry is created by action set A′ itself.
contract MigrationL1Upgrade is MigrationBase {
    function run() external {
        _load();
        string memory l2Deploy = vm.readFile(vm.envString("L2_DEPLOY_JSON"));
        address agent = _addr(l1State, ".agent");
        address bridge = _addr(l1State, ".legacyBridge");
        address token = _addr(l1Cfg, ".addresses.token");
        address registry = _addr(l1Cfg, ".ccip.token_admin_registry");
        address pool = _addr(l1Cfg, ".deployed.token_pool");
        address timelock = _addr(l1Cfg, ".deployed.timelock");
        address lockBox = _lockBox(l1Cfg, vm.parseJsonString(l2State, ".l2Chain"));
        address executor = _addr(l2State, ".opExec");
        uint256 activateAt = vm.envUint("ACTIVATE_L1_AT");
        uint256 closeAt = vm.envUint("CLOSE_AT");

        require(IOssifiableProxy(bridge).proxy__getAdmin() == agent, "L1 bridge proxy admin is not the Agent");
        require(IL1BridgeLike(bridge).l1Token() == token, "bridge/token mismatch");
        address messenger = IL1BridgeLike(bridge).messenger();
        address l2Bridge = IL1BridgeLike(bridge).l2TokenBridge();
        address l2Token = IL1BridgeLike(bridge).l2Token();
        require(l2Bridge == _addr(l2State, ".legacyBridge"), "L1 bridge names another L2 bridge");
        require(l2Token == _addr(l2Cfg, ".addresses.token"), "L1 bridge names another L2 token");
        require(
            ILidoTimelockLike(timelock).hasRole(ILidoTimelockLike(timelock).ADMIN_ROLE(), agent),
            "the Agent is not the L1 timelock admin (run step 07 first)"
        );
        address implementationBefore = IOssifiableProxy(bridge).proxy__getImplementation();

        // The implementation was deployed and checked during Base preparation, before this vote.
        address implementation = _addr(vm.readFile(vm.envString("L1_DEPLOY_JSON")), ".l1BridgeImplementation");
        require(implementation.code.length > 0, "Prepared L1 implementation has no code");
        IMigrationBridgeLike prepared = IMigrationBridgeLike(implementation);
        require(
            prepared.ccipLockBox() == lockBox && prepared.ccipTokenPool() == pool,
            "Prepared implementation lane mismatch"
        );

        // 2. The Agent, one vote: upgrade, lockbox authorization, timers, governance message.
        bytes memory queueCalldata = _actionSetA(_actionSetAInputs(l2Deploy));
        uint256 nonce = ICrossDomainMessengerLike(messenger).messageNonce();
        address[] memory added = new address[](1);
        added[0] = bridge;
        ILidoTimelockLike.Call[] memory authorize = new ILidoTimelockLike.Call[](1);
        authorize[0] = ILidoTimelockLike.Call(
            lockBox,
            0,
            abi.encodeCall(
                ILockBoxLike.applyAuthorizedCallerUpdates,
                (ILockBoxLike.AuthorizedCallerArgs({addedCallers: added, removedCallers: new address[](0)}))
            )
        );
        vm.startBroadcast(agent);
        IOssifiableProxy(bridge).proxy__upgradeTo(implementation);
        ILidoTimelockLike(timelock).bypasserExecuteBatch(authorize);
        IMigrationBridgeLike(bridge).scheduleActivation(activateAt);
        IMigrationBridgeLike(bridge).scheduleClose(closeAt);
        ICrossDomainMessengerLike(messenger).sendMessage(executor, queueCalldata, GOVERNANCE_MESSAGE_GAS);
        vm.stopBroadcast();

        // 3. Post-conditions of the L1 part.
        require(IOssifiableProxy(bridge).proxy__getImplementation() == implementation, "upgrade not applied");
        IMigrationBridgeLike b = IMigrationBridgeLike(bridge);
        require(b.getBridgeMode() == 0, "L1 bridge not in LEGACY");
        require(b.getActivationTime() == activateAt && b.getCloseTime() == closeAt, "L1 timers not set");
        require(b.ccipLockBox() == lockBox && b.ccipTokenPool() == pool, "L1 bridge lane wiring");
        require(b.isInitialized() && b.isDepositsEnabled() && b.isWithdrawalsEnabled(), "L1 bridge flags changed");
        require(_authorized(lockBox, bridge), "L1 bridge not authorized on the lockbox");
        ITokenAdminRegistryLike.TokenConfig memory config = ITokenAdminRegistryLike(registry).getTokenConfig(token);
        require(config.administrator == timelock, "the L1 timelock does not administer the token (run step 07 first)");
        require(config.tokenPool == pool, "the L1 registry does not bind the hub pool (run steps 05h and 07 first)");

        string memory o = "l1-upgrade";
        vm.serializeAddress(o, "l1BridgeImplementation", implementation);
        vm.serializeAddress(o, "l1BridgeImplementationBefore", implementationBefore);
        vm.serializeAddress(o, "l1LockBox", lockBox);
        vm.serializeUint(o, "governanceMessageNonce", nonce);
        vm.serializeUint(o, "governanceMessageGas", GOVERNANCE_MESSAGE_GAS);
        vm.serializeBytes(o, "queueCalldata", queueCalldata);
        vm.serializeUint(o, "activateL1At", activateAt);
        vm.serializeUint(o, "activateL2At", vm.envUint("ACTIVATE_L2_AT"));
        vm.serializeUint(o, "closeAt", closeAt);
        string memory json = vm.serializeBytes32(o, "queueCalldataHash", keccak256(queueCalldata));
        vm.writeJson(json, vm.envString("OUT_JSON"));

        console2.log("L1 bridge implementation: ", implementation);
        console2.log("governance message nonce: ", nonce);
        console2.log("L1 activate at", activateAt, "close at", closeAt);
    }

    function _authorized(address lockBox, address caller) internal view returns (bool) {
        address[] memory callers = ILockBoxLike(lockBox).getAllAuthorizedCallers();
        for (uint256 i; i < callers.length; ++i) {
            if (callers[i] == caller) return true;
        }
        return false;
    }
}

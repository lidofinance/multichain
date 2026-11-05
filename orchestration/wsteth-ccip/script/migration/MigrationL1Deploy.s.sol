// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {MigrationBase, IL1BridgeLike, IOssifiableProxy} from "./MigrationBase.s.sol";

/// @notice Deploy the L1 bridge implementation during Base preparation, without upgrading a proxy.
contract MigrationL1Deploy is MigrationBase {
    function run() external {
        _load();
        address bridge = _addr(l1State, ".legacyBridge");
        IL1BridgeLike legacy = IL1BridgeLike(bridge);
        require(IOssifiableProxy(bridge).proxy__getAdmin() == _addr(l1State, ".agent"), "Wrong proxy admin");
        address lockBox = _lockBox(l1Cfg, vm.parseJsonString(l2State, ".l2Chain"));
        bytes memory creation = _creation(
            vm.envString("L1_BRIDGE_ARTIFACT"),
            abi.encode(
                legacy.messenger(),
                legacy.l2TokenBridge(),
                legacy.l1Token(),
                legacy.l2Token(),
                _addr(l1Cfg, ".ccip.router"),
                _selector(l2Cfg),
                _addr(l1Cfg, ".ccip.token_admin_registry"),
                _addr(l1Cfg, ".deployed.token_pool"),
                lockBox
            )
        );
        vm.startBroadcast(vm.envAddress("DEPLOYER_ADDRESS"));
        address implementation = _deploy(creation);
        vm.stopBroadcast();
        string memory json = vm.serializeAddress("l1-deploy", "l1BridgeImplementation", implementation);
        vm.writeJson(json, vm.envString("OUT_JSON"));
    }
}

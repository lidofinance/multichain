// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {MigrationBase, IL2BridgeLike, IERC20MetadataLike, IOssifiableProxy} from "./MigrationBase.s.sol";

/// @notice Base preparation: deploy the new token implementation and the L2 migration bridge
///         implementation as the deployer. Nothing is upgraded here; the executor action set built
///         on L1 references these addresses.
contract MigrationL2Deploy is MigrationBase {
    function run() external {
        _load();
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address token = _addr(l2Cfg, ".addresses.token");
        address bridge = _addr(l2State, ".legacyBridge");
        address executor = _addr(l2State, ".opExec");
        require(IOssifiableProxy(token).proxy__getAdmin() == executor, "token proxy admin is not the executor");
        require(IOssifiableProxy(bridge).proxy__getAdmin() == executor, "bridge proxy admin is not the executor");
        require(IL2BridgeLike(bridge).l2Token() == token, "bridge/token mismatch");

        address messenger = IL2BridgeLike(bridge).messenger();
        address l1Bridge = IL2BridgeLike(bridge).l1TokenBridge();
        address l1Token = IL2BridgeLike(bridge).l1Token();
        address router = _addr(l2Cfg, ".ccip.router");
        address registry = _addr(l2Cfg, ".ccip.token_admin_registry");
        address pool = _addr(l2Cfg, ".deployed.token_pool");
        uint64 l1Selector = _selector(l1Cfg);

        // The implementation's EIP-712 domain is immutable: it must be built with the name the
        // proxy already stores, or finalizeUpgrade_v3 rejects it (ErrorEIP712DomainMismatch).
        string memory name = IERC20MetadataLike(token).name();
        string memory symbol = IERC20MetadataLike(token).symbol();
        uint8 decimals = IERC20MetadataLike(token).decimals();
        string memory version = vm.envString("TOKEN_VERSION");

        bytes memory tokenCreation =
            _creation(vm.envString("TOKEN_ARTIFACT"), abi.encode(name, symbol, version, decimals));
        bytes memory bridgeCreation = _creation(
            vm.envString("L2_BRIDGE_ARTIFACT"),
            abi.encode(messenger, l1Bridge, l1Token, token, router, l1Selector, registry, pool)
        );

        vm.startBroadcast(deployer);
        address tokenImplementation = _deploy(tokenCreation);
        address bridgeImplementation = _deploy(bridgeCreation);
        vm.stopBroadcast();

        string memory o = "l2-deploy";
        vm.serializeAddress(o, "l2TokenImplementation", tokenImplementation);
        vm.serializeAddress(o, "l2BridgeImplementation", bridgeImplementation);
        vm.serializeString(o, "tokenName", name);
        vm.serializeString(o, "tokenSymbol", symbol);
        vm.serializeUint(o, "tokenDecimals", decimals);
        string memory json = vm.serializeString(o, "tokenVersion", version);
        vm.writeJson(json, vm.envString("OUT_JSON"));

        console2.log("L2 token implementation:  ", tokenImplementation);
        console2.log("L2 bridge implementation: ", bridgeImplementation);
    }
}

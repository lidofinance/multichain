// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

// Keep these upstream artifacts in profile.token's source graph so forge verification
// can resolve their compiler inputs as well as deployment builds resolving bytecode.
import {
    OptimismBridgeExecutor
} from "governance-crosschain-bridges/contracts/bridges/OptimismBridgeExecutor.sol";
import {OssifiableProxy} from "@wsteth-token/contracts/proxy/OssifiableProxy.sol";
import {ERC20BridgedPermit} from "@wsteth-token/contracts/token/ERC20BridgedPermit.sol";

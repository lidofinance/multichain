// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

// Keep the pinned upstream governance executor in profile.govexec's source graph so forge
// verification can resolve its compiler inputs as well as deployment builds resolving bytecode.
import {
    OptimismBridgeExecutor
} from "governance-crosschain-bridges/contracts/bridges/OptimismBridgeExecutor.sol";

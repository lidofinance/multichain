// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CCIPMigrationSender} from "../../contracts/optimism/CCIPMigrationSender.sol";

abstract contract MigrationTestBase is Test {
    // Live CCIP chain selectors (Ethereum, Base); the tests only need them to be distinct and non-zero.
    uint64 constant ETH_SELECTOR = 5009297550715157269;
    uint64 constant BASE_SELECTOR = 15971525489660198786;

    bytes32 constant MIGRATION_SLOT = 0x5f13d1d6525b00150ceb4a1ca6bb5b19096fea6f8da7e4e62c48db5202dc7b00;
    bytes4 constant GENERIC_EXTRA_ARGS_V2_TAG = 0x181dcf10;

    CCIPMigrationSender.BridgeMode constant LEGACY = CCIPMigrationSender.BridgeMode.LEGACY;
    CCIPMigrationSender.BridgeMode constant MIGRATING = CCIPMigrationSender.BridgeMode.MIGRATING;
    CCIPMigrationSender.BridgeMode constant CCIP_ONLY = CCIPMigrationSender.BridgeMode.CCIP_ONLY;

    address admin = makeAddr("bridge-admin");
    address user = makeAddr("user");
    address other = makeAddr("other");
    address attacker = makeAddr("attacker");
    address lockbox = makeAddr("ccip-lane-lockbox");

    function erc7201(string memory id_) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id_))) - 1)) & ~bytes32(uint256(0xff));
    }

    function unauthorized(address account_, bytes32 role_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account_, role_);
    }

    function modeNotAllowed(CCIPMigrationSender.BridgeMode mode_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CCIPMigrationSender.ErrorBridgeModeNotAllowed.selector, mode_);
    }

    /// @dev What `Client._argsToBytes(GenericExtraArgsV2)` produces.
    function extraArgsV2(uint256 gasLimit_, bool allowOutOfOrder_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(GENERIC_EXTRA_ARGS_V2_TAG, gasLimit_, allowOutOfOrder_);
    }
}

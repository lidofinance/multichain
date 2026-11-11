// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {
    RealHubMigrationTest as SharedRealHubMigrationTest
} from "../../../wsteth-base-migration-mainnet/test/scenario/RealHubMigration.t.sol";

contract RealHubMigrationTest is SharedRealHubMigrationTest {
    function _expectedExistingLockBoxes() internal pure override returns (uint256) {
        return 2; // Monad shared custody and the isolated OP Sepolia direction.
    }
}

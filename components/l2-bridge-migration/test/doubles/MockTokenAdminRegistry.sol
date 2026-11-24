// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

/// @dev The one view of the CCIP `TokenAdminRegistry` the bridges read: the pool bound to a token.
contract MockTokenAdminRegistry {
    mapping(address => address) internal _pools;

    function setPool(address token_, address pool_) external {
        _pools[token_] = pool_;
    }

    function getPool(address token_) external view returns (address) {
        return _pools[token_];
    }
}

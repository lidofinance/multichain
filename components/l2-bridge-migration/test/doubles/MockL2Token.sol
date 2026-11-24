// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @dev Minimal stand-in for `components/wsteth-token` `ERC20BridgedPermit` as the L2 bridge
///     uses it: `mint` under MINTER_ROLE, `burnFrom` under BURNER_ROLE spending the caller's
///     allowance, no bridge authority. The real token is exercised in its own component's tests
///     and in the fork test.
contract MockL2Token is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    constructor(address admin_) ERC20("Wrapped liquid staked Ether 2.0", "wstETH") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function mint(address account_, uint256 amount_) external onlyRole(MINTER_ROLE) {
        _mint(account_, amount_);
    }

    function burn(uint256 amount_) external onlyRole(BURNER_ROLE) {
        _burn(msg.sender, amount_);
    }

    function burnFrom(address account_, uint256 amount_) external onlyRole(BURNER_ROLE) {
        _spendAllowance(account_, msg.sender, amount_);
        _burn(account_, amount_);
    }
}

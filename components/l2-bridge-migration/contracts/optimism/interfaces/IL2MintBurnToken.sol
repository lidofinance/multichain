// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The part of the L2 token ABI the legacy bridge uses. The token authorizes both calls
///     by role: `mint` needs MINTER_ROLE and `burnFrom` needs BURNER_ROLE, both held by the bridge
///     until `close()` renounces them.
interface IL2MintBurnToken is IERC20 {
    /// @notice Creates `amount_` tokens for `account_`
    function mint(address account_, uint256 amount_) external;

    /// @notice Destroys `amount_` tokens of `account_`, spending the caller's allowance
    function burnFrom(address account_, uint256 amount_) external;

    /// @notice OpenZeppelin AccessControl: the caller gives up `role_`; `callerConfirmation_` must
    ///     be the caller
    function renounceRole(bytes32 role_, address callerConfirmation_) external;
}

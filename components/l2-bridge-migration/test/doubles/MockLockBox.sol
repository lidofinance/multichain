// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILockBox} from "@chainlink/contracts-ccip/interfaces/ILockBox.sol";

/// @dev Stand-in for the CCIP 2.0 `ERC20LockBox` as the L1 bridge uses it: one token, an
///     authorized-caller list, balance-based `withdraw` that ignores the chain selector and
///     reverts on a shortfall, like the real one. Plain transfers into it count as balance.
contract MockLockBox is ILockBox {
    using SafeERC20 for IERC20;

    error UnauthorizedCaller(address caller);
    error UnsupportedToken(address token);
    error TokenAmountCannotBeZero();
    error RecipientCannotBeZeroAddress();
    error InsufficientBalance(uint256 requested, uint256 available);

    IERC20 public immutable token;
    mapping(address => bool) public authorized;
    uint256 public withdrawCount;
    uint64 public lastSelector;
    uint256 public lastAmount;
    address public lastRecipient;

    constructor(address token_) {
        token = IERC20(token_);
    }

    function setAuthorized(address caller_, bool allowed_) external {
        authorized[caller_] = allowed_;
    }

    function deposit(address token_, uint64, uint256 amount_) external {
        _validate(token_, amount_);
        token.safeTransferFrom(msg.sender, address(this), amount_);
    }

    function withdraw(address token_, uint64 remoteChainSelector_, uint256 amount_, address recipient_) external {
        _validate(token_, amount_);
        if (recipient_ == address(0)) {
            revert RecipientCannotBeZeroAddress();
        }
        uint256 balance = token.balanceOf(address(this));
        if (amount_ == type(uint256).max) {
            amount_ = balance;
        }
        if (amount_ > balance) {
            revert InsufficientBalance(amount_, balance);
        }
        withdrawCount += 1;
        lastSelector = remoteChainSelector_;
        lastAmount = amount_;
        lastRecipient = recipient_;
        token.safeTransfer(recipient_, amount_);
    }

    function isTokenSupported(address token_) external view returns (bool) {
        return token_ == address(token);
    }

    function _validate(address token_, uint256 amount_) internal view {
        if (!authorized[msg.sender]) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (token_ != address(token)) {
            revert UnsupportedToken(token_);
        }
        if (amount_ == 0) {
            revert TokenAmountCannotBeZero();
        }
    }
}

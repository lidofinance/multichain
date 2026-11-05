// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A contract account that forwards arbitrary calls and cannot receive ether (no `receive`),
///     so a fee refund to it fails.
contract CallerWithoutReceive {
    function exec(address target_, uint256 value_, bytes calldata data_) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target_.call{value: value_}(data_);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    function approve(address token_, address spender_, uint256 amount_) external {
        IERC20(token_).approve(spender_, amount_);
    }
}

/// @dev Same, but refunds land.
contract CallerWithReceive is CallerWithoutReceive {
    receive() external payable {}
}

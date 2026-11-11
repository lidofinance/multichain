// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";

/// @dev Stand-in for the CCIP Router as the bridge sees it: quotes a configurable native fee,
///     accepts `msg.value >= fee` and keeps all of it (the real Router does the same, see
///     Router.ccipSend), pulls every `tokenAmounts[i]` from the caller into `pool`, and records
///     the last message field by field for assertions.
contract MockRouter is IRouterClient {
    using SafeERC20 for IERC20;

    address public immutable pool;
    uint64 public immutable supportedChainSelector;

    uint256 public fee;
    bool public quoteReverts;
    uint256 public sendCount;

    address public lastSender;
    uint256 public lastValue;
    uint64 public lastSelector;
    bytes public lastReceiver;
    bytes public lastData;
    bytes public lastExtraArgs;
    address public lastFeeToken;
    uint256 public lastTokenCount;
    address public lastToken;
    uint256 public lastAmount;

    constructor(address pool_, uint64 supportedChainSelector_) {
        pool = pool_;
        supportedChainSelector = supportedChainSelector_;
    }

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function setQuoteReverts(bool reverts_) external {
        quoteReverts = reverts_;
    }

    function isChainSupported(uint64 destChainSelector) external view returns (bool) {
        return destChainSelector == supportedChainSelector;
    }

    function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage memory) public view returns (uint256) {
        if (quoteReverts || destinationChainSelector != supportedChainSelector) {
            revert UnsupportedDestinationChain(destinationChainSelector);
        }
        return fee;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32)
    {
        uint256 required = getFee(destinationChainSelector, message);
        if (message.feeToken != address(0)) {
            revert InvalidMsgValue();
        }
        if (msg.value < required) {
            revert InsufficientFeeTokenAmount();
        }
        for (uint256 i = 0; i < message.tokenAmounts.length; i++) {
            IERC20(message.tokenAmounts[i].token).safeTransferFrom(msg.sender, pool, message.tokenAmounts[i].amount);
        }
        sendCount += 1;
        lastSender = msg.sender;
        lastValue = msg.value;
        lastSelector = destinationChainSelector;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastExtraArgs = message.extraArgs;
        lastFeeToken = message.feeToken;
        lastTokenCount = message.tokenAmounts.length;
        if (message.tokenAmounts.length > 0) {
            lastToken = message.tokenAmounts[0].token;
            lastAmount = message.tokenAmounts[0].amount;
        }
        return messageIdFor(sendCount, destinationChainSelector, message.receiver, msg.sender);
    }

    function messageIdFor(uint256 nonce_, uint64 selector_, bytes memory receiver_, address sender_)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(nonce_, selector_, receiver_, sender_));
    }
}

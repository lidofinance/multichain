// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {ICrossDomainMessenger} from "../../contracts/optimism/interfaces/ICrossDomainMessenger.sol";

/// @dev Records outgoing legacy messages and reports a configurable cross-domain sender.
contract MockCrossDomainMessenger is ICrossDomainMessenger {
    struct Message {
        address target;
        bytes data;
        uint32 gasLimit;
    }

    address public xDomainMessageSender;
    Message[] internal _sent;

    function setXDomainMessageSender(address sender_) external {
        xDomainMessageSender = sender_;
    }

    function sendMessage(address target_, bytes calldata message_, uint32 gasLimit_) external {
        _sent.push(Message({target: target_, data: message_, gasLimit: gasLimit_}));
    }

    function sentCount() external view returns (uint256) {
        return _sent.length;
    }

    function lastMessage() external view returns (Message memory) {
        return _sent[_sent.length - 1];
    }
}

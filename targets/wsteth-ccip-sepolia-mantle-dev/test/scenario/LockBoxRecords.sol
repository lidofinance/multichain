// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Vm} from "forge-std/Vm.sol";

library LockBoxRecords {
    // Foundry encodes JSON object fields in alphabetical order.
    struct Entry {
        address lock_box;
        string remote_chain_name;
    }

    function find(Vm vm, string memory record, string memory chain) internal pure returns (address result) {
        Entry[] memory entries = abi.decode(vm.parseJson(record, ".deployed.lock_boxes"), (Entry[]));
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (keccak256(bytes(entries[i].remote_chain_name)) == keccak256(bytes(chain))) {
                require(!found, "duplicate lockbox lane");
                found = true;
                result = entries[i].lock_box;
            }
        }
        require(result != address(0), "missing lane lockbox");
    }
}

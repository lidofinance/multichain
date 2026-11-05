// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @notice Single-signer ERC-1271 guardian for the controlled Sepolia rehearsal.
/// @dev DSM requires contract guardians. This adapter validates its signer's raw
/// digest signatures; it does not imitate a production multisig's independence.
/// Rotate by replacing the guardian through DSM's owner (DAO Agent).
contract TestnetDsmGuardian is IERC1271 {
    address public immutable signer;

    constructor(address signer_) {
        require(signer_ != address(0), "zero signer");
        signer = signer_;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1271).interfaceId || interfaceId == 0x01ffc9a7;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(hash, signature);
        return error == ECDSA.RecoverError.NoError && recovered == signer ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

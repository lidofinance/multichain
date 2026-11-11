// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;
import {Test} from "forge-std/Test.sol";
import {TestnetDsmGuardian} from "../src/testnet/TestnetDsmGuardian.sol";

contract TestnetDsmGuardianTest is Test {
    function testAcceptsOnlyConfiguredSignerAndDigest() public {
        uint256 key = 12345;
        TestnetDsmGuardian guardian = new TestnetDsmGuardian(vm.addr(key));
        bytes32 hash = keccak256("DSM intent");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        bytes memory signature = abi.encodePacked(r, s, v);
        assertEq(guardian.isValidSignature(hash, signature), bytes4(0x1626ba7e));
        assertEq(guardian.isValidSignature(keccak256("different intent"), signature), bytes4(0xffffffff));
        (v, r, s) = vm.sign(key + 1, hash);
        assertEq(guardian.isValidSignature(hash, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
        assertEq(guardian.isValidSignature(hash, hex"abcd"), bytes4(0xffffffff));
        assertTrue(guardian.supportsInterface(0x1626ba7e));
        assertTrue(guardian.supportsInterface(0x01ffc9a7));
        assertFalse(guardian.supportsInterface(0xffffffff));
    }
}

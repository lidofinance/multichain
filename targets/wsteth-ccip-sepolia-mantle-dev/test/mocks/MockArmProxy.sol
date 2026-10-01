// SPDX-License-Identifier: BUSL
pragma solidity ^0.8.24;

contract MockArmProxy {
  mapping(bytes16 => bool) private s_isCursed;

  function setIsCursed(bytes16 subject, bool cursed) external {
    s_isCursed[subject] = cursed;
  }

  function isCursed() external view returns (bool) {
    return s_isCursed[bytes16(0)];
  }

  function isCursed(
    bytes16 subject
  ) external view returns (bool) {
    return s_isCursed[subject];
  }

  function test() external pure {}
}

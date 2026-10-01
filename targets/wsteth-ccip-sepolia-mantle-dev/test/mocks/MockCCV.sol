// SPDX-License-Identifier: BUSL
pragma solidity ^0.8.24;

import {ICrossChainVerifierResolver} from "@chainlink/contracts-ccip/interfaces/ICrossChainVerifierResolver.sol";
import {ICrossChainVerifierV1} from "@chainlink/contracts-ccip/interfaces/ICrossChainVerifierV1.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {MessageV1Codec} from "@chainlink/contracts-ccip/libraries/MessageV1Codec.sol";
import {IERC165} from "@openzeppelin/contracts@5.3.0/utils/introspection/IERC165.sol";

/// @notice Minimal mock CCV for test infrastructure.
/// Returns itself as the implementation, charges zero fees, and accepts all verifications.
contract MockCCV is ICrossChainVerifierResolver, ICrossChainVerifierV1 {
  function getInboundImplementation(
    bytes calldata
  ) external view override returns (address) {
    return address(this);
  }

  function getOutboundImplementation(uint64, bytes calldata) external view override returns (address) {
    return address(this);
  }

  function verifyMessage(MessageV1Codec.MessageV1 memory, bytes32, bytes memory) external override {}

  function forwardToVerifier(
    MessageV1Codec.MessageV1 calldata,
    bytes32,
    address,
    uint256,
    bytes calldata
  ) external pure override returns (bytes memory) {
    return "";
  }

  function getFee(
    uint64,
    Client.EVM2AnyMessage memory,
    bytes memory,
    bytes4
  ) external pure override returns (uint16, uint32, uint32) {
    return (0, 0, 0);
  }

  function getStorageLocations() external pure override returns (string[] memory) {
    return new string[](0);
  }

  function supportsInterface(
    bytes4 interfaceId
  ) external pure override returns (bool) {
    return interfaceId == type(ICrossChainVerifierV1).interfaceId || interfaceId == type(IERC165).interfaceId;
  }

  function test() external pure {}
}

// SPDX-License-Identifier: BUSL
pragma solidity ^0.8.24;

import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";

contract MockFeeQuoter {
  mapping(uint64 => uint256) private s_fees;
  uint32 public defaultPoolGasLimit = 100_000;

  function setDefaultPoolGasLimit(
    uint32 gasLimit
  ) external {
    defaultPoolGasLimit = gasLimit;
  }

  function setFee(uint64 chainSelector, uint256 fee) external {
    s_fees[chainSelector] = fee;
  }

  function resolveLegacyArgs(
    uint64,
    bytes calldata extraArgs
  ) external pure returns (bytes memory tokenReceiver, uint32 gasLimit, bytes memory executorArgs) {
    gasLimit = 200_000;
    if (extraArgs.length >= 4) {
      bytes4 tag = bytes4(extraArgs[:4]);
      if (tag == Client.EVM_EXTRA_ARGS_V1_TAG) {
        gasLimit = uint32(abi.decode(extraArgs[4:], (uint256)));
      } else if (tag == Client.GENERIC_EXTRA_ARGS_V2_TAG) {
        Client.GenericExtraArgsV2 memory v2 = abi.decode(extraArgs[4:], (Client.GenericExtraArgsV2));
        gasLimit = uint32(v2.gasLimit);
      }
    }
    return ("", gasLimit, "");
  }

  function getTokenTransferFee(uint64, address) external view returns (uint32, uint32, uint32) {
    return (0, defaultPoolGasLimit, 128);
  }

  function quoteGasForExec(
    uint64 destChainSelector,
    uint32 nonCalldataGas,
    uint32,
    address
  )
    external
    view
    returns (uint32 totalGas, uint256 gasCostInUsdCents, uint256 feeTokenPrice, uint256 premiumMultiplier)
  {
    return (nonCalldataGas, s_fees[destChainSelector], 1e18, 100);
  }

  function test() external pure {}
}

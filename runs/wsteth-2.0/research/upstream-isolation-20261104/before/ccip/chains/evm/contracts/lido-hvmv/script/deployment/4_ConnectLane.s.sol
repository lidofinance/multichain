// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/ccvs/VersionedVerifierResolver.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/ccvs/components/BaseVerifier.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/pools/AdvancedPoolHooks.sol";
import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {console} from "forge-std/console.sol";

import {ISiloedLockReleaseTokenPool} from "../lib/ISiloedLockReleaseTokenPool.sol";
import {ConfigureScript} from "./2_Configure.s.sol";

import {DummyMessageIdVerifier} from "../../ccvs/DummyMessageIdVerifier.sol";

/// @title ConnectLaneScript
/// @notice Emits the owner-only calls that connect one deferred lane to the deployed pool — exactly what 2_Configure
///         applies for a lane it configures — as the batch of a LidoTimelock proposal, written to a JSON file.
/// @dev Nothing is broadcast. After 2_Configure the pool, its hooks, the placeholder verifier and the resolver belong
///      to the LidoTimelock: the lane is connected by a proposal its proposer (Chainlink MCMS) schedules and its
///      CallProxy executes after the delay, or by the admin through the bypass. The calls, in order:
///        1. TokenPool.applyChainUpdates([], [lane])                     selector, remote pool and token, limits
///        2. TokenPool.applyTokenTransferFeeConfigUpdates([lane], [])
///        3. SiloedLockReleaseTokenPool.configureLockBoxes([lane])        SiloedLockRelease pools only: the lockbox
///                                                                        1_Deploy built for the lane
///        4. AdvancedPoolHooks.applyCCVConfigUpdates([lane])              the local resolver on both directions
///        5. DummyMessageIdVerifier.applyRemoteChainConfigUpdates([lane])
///        6. VersionedVerifierResolver.applyOutboundImplementationUpdates([lane])
///      Env vars: CHAIN_CONFIG (the local record), LANE (a `remote_chain_name` listed in the record's
///      `deferred_lanes`), PROPOSAL_OUT (the file to write; must lie within the project's fs permissions, e.g. under
///      contracts/lido-hvmv/config), DEFAULT_CONFIG (optional).
contract ConnectLaneScript is ConfigureScript {
  error LaneNotDeferred(string remoteChainName);

  function run() public override {
    string memory lane = vm.envString("LANE");
    string memory out = vm.envString("PROPOSAL_OUT");
    if (!_isDeferredLane(lane)) revert LaneNotDeferred(lane);
    require(block.chainid == s_chainConfig.chain.chain_id, "Chain ID mismatch: RPC chain != config chain_id");

    vm.writeFile(out, string.concat(_headerJson(lane), ',"expected":', _expectedJson(lane), ',"calls":[', _callsJson(lane), "]}"));

    console.log("=== Lane connection proposal ===");
    console.log("Chain:", s_chainConfig.chain.chain_name);
    console.log("Lane:", lane);
    console.log("Written to:", out);
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // THE BATCH
  // ═══════════════════════════════════════════════════════════════════════════════

  function _callsJson(
    string memory lane
  ) internal view returns (string memory calls) {
    calls = _callChainUpdate(lane);
    calls = string.concat(calls, ",", _callFeeConfig(lane));
    if (s_chainConfig.chain.pool_type == PoolType.SiloedLockRelease) {
      calls = string.concat(calls, ",", _callLockBox(lane));
    }
    calls = string.concat(calls, ",", _callHooks(lane));
    calls = string.concat(calls, ",", _callVerifier(lane));
    calls = string.concat(calls, ",", _callResolver(lane));
  }

  function _callChainUpdate(
    string memory lane
  ) internal view returns (string memory) {
    TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
    updates[0] = _chainUpdateFor(lane);
    return _call(
      s_deployed.token_pool,
      abi.encodeCall(TokenPool.applyChainUpdates, (new uint64[](0), updates)),
      "TokenPool.applyChainUpdates([], [lane]): selector, remote pool and token, outbound and inbound limits"
    );
  }

  function _callFeeConfig(
    string memory lane
  ) internal view returns (string memory) {
    TokenPool.TokenTransferFeeConfigArgs[] memory fees = new TokenPool.TokenTransferFeeConfigArgs[](1);
    fees[0] = _feeConfigFor(lane);
    return _call(
      s_deployed.token_pool,
      abi.encodeCall(TokenPool.applyTokenTransferFeeConfigUpdates, (fees, new uint64[](0))),
      "TokenPool.applyTokenTransferFeeConfigUpdates([lane], []): destination gas overhead, fee config enabled"
    );
  }

  function _callLockBox(
    string memory lane
  ) internal view returns (string memory) {
    ISiloedLockReleaseTokenPool.LockBoxConfig[] memory boxes = new ISiloedLockReleaseTokenPool.LockBoxConfig[](1);
    boxes[0] = _lockBoxConfigFor(lane);
    return _call(
      s_deployed.token_pool,
      abi.encodeCall(ISiloedLockReleaseTokenPool.configureLockBoxes, (boxes)),
      "SiloedLockReleaseTokenPool.configureLockBoxes([(selector, lockbox)]): the lane's custody"
    );
  }

  function _callHooks(
    string memory lane
  ) internal view returns (string memory) {
    AdvancedPoolHooks.CCVConfigArg[] memory ccv = new AdvancedPoolHooks.CCVConfigArg[](1);
    ccv[0] = _ccvConfigFor(lane);
    return _call(
      s_deployed.advanced_pool_hooks,
      abi.encodeCall(AdvancedPoolHooks.applyCCVConfigUpdates, (ccv)),
      "AdvancedPoolHooks.applyCCVConfigUpdates([lane]): the local resolver required outbound and inbound"
    );
  }

  function _callVerifier(
    string memory lane
  ) internal view returns (string memory) {
    BaseVerifier.RemoteChainConfigArgs[] memory remoteConfigs = new BaseVerifier.RemoteChainConfigArgs[](1);
    remoteConfigs[0] = _verifierRemoteConfigFor(lane);
    return _call(
      s_ccv.message_id_verifier,
      abi.encodeCall(DummyMessageIdVerifier.applyRemoteChainConfigUpdates, (remoteConfigs)),
      "DummyMessageIdVerifier.applyRemoteChainConfigUpdates([lane]): router, gas and payload size for the lane"
    );
  }

  function _callResolver(
    string memory lane
  ) internal view returns (string memory) {
    VersionedVerifierResolver.OutboundImplementationArgs[] memory outbound =
      new VersionedVerifierResolver.OutboundImplementationArgs[](1);
    outbound[0] = _resolverOutboundFor(lane);
    return _call(
      s_ccv.verifier_resolver,
      abi.encodeCall(VersionedVerifierResolver.applyOutboundImplementationUpdates, (outbound)),
      "VersionedVerifierResolver.applyOutboundImplementationUpdates([lane]): the placeholder verifier"
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // JSON
  // ═══════════════════════════════════════════════════════════════════════════════

  function _headerJson(
    string memory lane
  ) internal view returns (string memory) {
    string memory head = string.concat('{"chain":"', s_chainConfig.chain.chain_name, '","lane":"', lane);
    head = string.concat(
      head, '","remoteChainSelector":"', vm.toString(s_remoteData[lane].ccip.chain_selector), '","timelock":"'
    );
    head = string.concat(head, vm.toString(s_deployed.timelock), '","callProxy":"', vm.toString(s_deployed.call_proxy));
    return string.concat(
      head, '","proposer":"', vm.toString(s_chainConfig.governance_addresses.chainlink_mcms), '"'
    );
  }

  /// @dev What the lane must read back as once the batch has executed.
  function _expectedJson(
    string memory lane
  ) internal view returns (string memory) {
    TokenPool.ChainUpdate memory update = _chainUpdateFor(lane);
    string memory json = string.concat('{"remotePools":[', _remotePoolsJson(update.remotePoolAddresses), "]");
    json = string.concat(json, ',"remoteToken":"', vm.toString(s_remoteData[lane].token), '"');
    json = string.concat(json, ',"lockBox":', _lockBoxJson(lane));
    json = string.concat(json, ',"outbound":', _limiterJson(update.outboundRateLimiterConfig));
    json = string.concat(json, ',"inbound":', _limiterJson(update.inboundRateLimiterConfig));
    json = string.concat(json, ',"resolver":"', vm.toString(s_ccv.verifier_resolver), '"');
    json = string.concat(json, ',"verifier":"', vm.toString(s_ccv.message_id_verifier), '"');
    return string.concat(
      json,
      ',"destGasOverhead":',
      vm.toString(uint256(s_defaultConfig.token_transfer_fee_defaults.dest_gas_overhead)),
      "}"
    );
  }

  function _remotePoolsJson(
    bytes[] memory pools
  ) internal pure returns (string memory json) {
    for (uint256 i; i < pools.length; i++) {
      json = string.concat(json, i == 0 ? '"' : ',"', vm.toString(abi.decode(pools[i], (address))), '"');
    }
  }

  function _lockBoxJson(
    string memory lane
  ) internal view returns (string memory) {
    if (s_chainConfig.chain.pool_type != PoolType.SiloedLockRelease) return "null";
    return string.concat('"', vm.toString(_lockBoxConfigFor(lane).lockBox), '"');
  }

  function _limiterJson(
    RateLimiter.Config memory config
  ) internal pure returns (string memory) {
    return string.concat(
      '{"enabled":',
      config.isEnabled ? "true" : "false",
      ',"capacity":"',
      vm.toString(uint256(config.capacity)),
      '","rate":"',
      vm.toString(uint256(config.rate)),
      '"}'
    );
  }

  function _call(
    address target,
    bytes memory data,
    string memory description
  ) internal pure returns (string memory) {
    string memory json = string.concat('{"target":"', vm.toString(target), '","value":"0","data":"');
    return string.concat(json, vm.toString(data), '","description":"', description, '"}');
  }
}

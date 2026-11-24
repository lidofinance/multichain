// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/ccvs/VersionedVerifierResolver.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/ccvs/components/BaseVerifier.sol";
import {IAdvancedPoolHooks} from "@chainlink/contracts-ccip/interfaces/IAdvancedPoolHooks.sol";
import {IPoolV2} from "@chainlink/contracts-ccip/interfaces/IPoolV2.sol";
import {IRouter} from "@chainlink/contracts-ccip/interfaces/IRouter.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/pools/AdvancedPoolHooks.sol";
import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";
import {Ownable2Step} from "@chainlink/contracts/src/v0.8/shared/access/Ownable2Step.sol";
import {ERC20BridgedPermit} from "@lido/wsteth-token/token/ERC20BridgedPermit.sol";
import {console} from "forge-std/console.sol";

import {ConfigParser} from "../lib/ConfigParser.sol";
import {ISiloedLockReleaseTokenPool} from "../lib/ISiloedLockReleaseTokenPool.sol";

import {PausableAdvancedPoolHooks} from "../../PausableAdvancedPoolHooks.sol";

import {DummyMessageIdVerifier} from "../../ccvs/DummyMessageIdVerifier.sol";
import {ILidoTimelock} from "../../interfaces/ILidoTimelock.sol";

/// @title ConfigureScript
/// @notice Configures all deployed contracts and transfers their ownership to the LidoTimelock.
/// @dev Prerequisite: 1_Deploy has been run on ALL chains (local + all remote chains).
///      Reads remote chain JSONs to resolve cross-chain addresses.
///      Lanes listed in the record's `deferred_lanes` are left for the pool's owner: their lockbox is authorized and
///      handed over like the others, but their chain update, fee config, lockbox binding, CCV entry and verifier and
///      resolver entries are not applied here — 4_ConnectLane emits those calls for an owner's proposal. The per-lane
///      builders below are shared with that script, so both apply the same configuration.
///      Env vars: CHAIN_CONFIG (required), DEFAULT_CONFIG (optional), DEPLOYER_PRIVATE_KEY (optional)
contract ConfigureScript is ConfigParser {
  error MissingCCVDeployment(address verifier, address resolver);
  error ImportedLaneRemotePoolMismatch(string remoteChainName, address recordPool);
  error NoLockBoxForLane(string remoteChainName);

  uint32 internal constant DUMMY_MESSAGE_ID_GAS_FOR_VERIFICATION = 1;
  uint16 internal constant DUMMY_MESSAGE_ID_PAYLOAD_SIZE_BYTES = 36;
  uint32 internal constant STOCK_SOURCE_POOL_DATA_LENGTH = 32;

  string internal s_chainConfigPath;
  uint256 internal s_deployerPrivateKey;
  address internal s_deployer;
  bool internal s_hubMigrationOnly;

  // Resolved remote chain data (indexed same as s_chainConfig.remote_lanes)
  mapping(address lockBox => bool configured) internal s_configuredLockBoxes;
  mapping(address lockBox => bool transferred) internal s_transferredLockBoxes;
  mapping(string remoteChainName => RemoteChainData remoteData) internal s_remoteData;

  function setUp() public {
    _loadConfigs();
    _resolveRemoteData();
  }

  function getDeployer() public view returns (address) {
    return s_deployer;
  }

  function run() public virtual {
    _revertIfBroadcastingWithTestKey(s_deployerPrivateKey);
    require(block.chainid == s_chainConfig.chain.chain_id, "Chain ID mismatch: RPC chain != config chain_id");

    vm.startBroadcast(s_deployerPrivateKey);

    _configureTokenIfNeeded();
    _configureTokenPool();
    _configureLockBoxes();
    _configureAdvancedPoolHooks();
    _configureCCVStack();
    _configureBlockedSelectors();
    _transferOwnershipToTimelock();

    vm.stopBroadcast();

    _logResult();
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // LOAD
  // ═══════════════════════════════════════════════════════════════════════════════

  function _loadConfigs() internal {
    string memory defaultConfigPath =
      vm.envOr("DEFAULT_CONFIG", string("./contracts/lido-hvmv/config/default_config.json"));
    s_chainConfigPath = vm.envString("CHAIN_CONFIG");
    s_deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(1));
    s_deployer = vm.addr(s_deployerPrivateKey);

    _loadDefaultConfig(defaultConfigPath);
    _loadChainConfig(s_chainConfigPath);
    s_hubMigrationOnly = vm.envOr("HUB_MIGRATION_ONLY", false);
    if (s_hubMigrationOnly) {
      require(s_chainConfig.chain.pool_type == PoolType.SiloedLockRelease, "Hub migration requires a lock/release pool");
      require(_lanesWithLocalCCVs() == 0, "Hub migration cannot omit required CCVs");
    }
    _loadCCIPAddresses(s_chainConfigPath);
    _loadDeployedAddresses(s_chainConfigPath);
    _loadCCVDeployment(s_chainConfigPath);
    if (!s_hubMigrationOnly && (s_ccv.message_id_verifier == address(0) || s_ccv.verifier_resolver == address(0))) {
      revert MissingCCVDeployment(s_ccv.message_id_verifier, s_ccv.verifier_resolver);
    }
  }

  function _logResult() internal view {
    console.log("=== Configuration Complete ===");
    console.log("Chain:", s_chainConfig.chain.chain_name);
    console.log("All contracts configured and ownership transferred to the timelock\n");
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // RESOLVE REMOTE DATA
  // ═══════════════════════════════════════════════════════════════════════════════

  function _resolveRemoteData() internal {
    string memory configDir = _getDirectory(s_chainConfigPath);

    for (uint256 i; i < s_chainConfig.remote_lanes.length; i++) {
      string memory remoteName = s_chainConfig.remote_lanes[i].remote_chain_name;
      if (s_hubMigrationOnly && _isDeferredLane(remoteName)) continue;
      string memory remotePath = string.concat(configDir, "/", remoteName, ".json");
      s_remoteData[remoteName] = _loadRemoteChainData(remotePath);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // CONFIGURE FUNCTIONS
  // ═══════════════════════════════════════════════════════════════════════════════

  /// @dev Only for a token deployed by 1_Deploy. Its admin moves to the Lido DAO in 3_SetPoolAndTransferOwnership.
  function _configureTokenIfNeeded() internal {
    if (!s_tokenDeployedByScripts) return;

    ERC20BridgedPermit token = ERC20BridgedPermit(s_chainConfig.addresses.token);
    token.grantRole(token.MINTER_ROLE(), s_deployed.token_pool);
    token.grantRole(token.BURNER_ROLE(), s_deployed.token_pool);
  }

  function _configureTokenPool() internal {
    TokenPool(s_deployed.token_pool).updateAdvancedPoolHooks(IAdvancedPoolHooks(s_deployed.advanced_pool_hooks));

    uint256 count = _lanesConfiguredHere();
    TokenPool.ChainUpdate[] memory chainUpdates = new TokenPool.ChainUpdate[](count);
    TokenPool.TokenTransferFeeConfigArgs[] memory tokenTransferFeeConfigs =
      new TokenPool.TokenTransferFeeConfigArgs[](count);
    uint256 configured;

    for (uint256 i; i < s_chainConfig.remote_lanes.length; i++) {
      string memory remoteName = s_chainConfig.remote_lanes[i].remote_chain_name;
      if (_isDeferredLane(remoteName)) continue;
      chainUpdates[configured] = _chainUpdateFor(remoteName);
      tokenTransferFeeConfigs[configured++] = _feeConfigFor(remoteName);
    }

    if (count > 0) {
      TokenPool(s_deployed.token_pool).applyChainUpdates(new uint64[](0), chainUpdates);
      TokenPool(s_deployed.token_pool).applyTokenTransferFeeConfigUpdates(tokenTransferFeeConfigs, new uint64[](0));
    }
  }

  function _configureLockBoxes() internal {
    if (s_chainConfig.chain.pool_type != PoolType.SiloedLockRelease || s_deployed.lock_boxes.length == 0) return;

    address[] memory callers = new address[](1);
    callers[0] = s_deployed.token_pool;

    uint256 bound;
    for (uint256 i; i < s_deployed.lock_boxes.length; i++) {
      if (!_isDeferredLane(s_deployed.lock_boxes[i].remote_chain_name)) bound++;
    }
    ISiloedLockReleaseTokenPool.LockBoxConfig[] memory lockBoxConfigs =
      new ISiloedLockReleaseTokenPool.LockBoxConfig[](bound);
    uint256 configured;

    for (uint256 i; i < s_deployed.lock_boxes.length; i++) {
      LockBoxEntry memory entry = s_deployed.lock_boxes[i];
      // Every lockbox authorizes the pool once, a deferred lane's included: when the owner binds that lane, its
      // lockbox is already the pool's.
      if (!s_configuredLockBoxes[entry.lock_box]) {
        s_configuredLockBoxes[entry.lock_box] = true;
        AuthorizedCallers(entry.lock_box)
          .applyAuthorizedCallerUpdates(
            AuthorizedCallers.AuthorizedCallerArgs({addedCallers: callers, removedCallers: new address[](0)})
          );
      }
      if (_isDeferredLane(entry.remote_chain_name)) continue;
      lockBoxConfigs[configured++] = _lockBoxConfigFor(entry.remote_chain_name);
    }

    if (bound > 0) {
      ISiloedLockReleaseTokenPool(s_deployed.token_pool).configureLockBoxes(lockBoxConfigs);
    }
  }

  /// @dev Imported lanes get no entry: the hooks require no CCVs for them, so they keep their default verification.
  ///      Deferred lanes get theirs from the owner (4_ConnectLane).
  function _configureAdvancedPoolHooks() internal {
    PausableAdvancedPoolHooks hooks = PausableAdvancedPoolHooks(payable(s_deployed.advanced_pool_hooks));
    AdvancedPoolHooks.CCVConfigArg[] memory ccvConfigs = new AdvancedPoolHooks.CCVConfigArg[](_lanesWithLocalCCVs());
    uint256 configured;

    for (uint256 i; i < s_chainConfig.remote_lanes.length; i++) {
      string memory remoteName = s_chainConfig.remote_lanes[i].remote_chain_name;
      if (!_hasLocalCCVs(remoteName)) continue;
      ccvConfigs[configured++] = _ccvConfigFor(remoteName);
    }

    if (ccvConfigs.length > 0) {
      hooks.applyCCVConfigUpdates(ccvConfigs);
    }
    hooks.setThresholdAmount(vm.envOr("CCV_THRESHOLD_AMOUNT", uint256(0)));
  }

  /// @dev The placeholder verifier and the resolver serve the lanes whose hooks require them; imported and deferred
  ///      lanes are left out.
  function _configureCCVStack() internal {
    if (s_hubMigrationOnly) return;
    uint256 localCount = _lanesWithLocalCCVs();
    BaseVerifier.RemoteChainConfigArgs[] memory remoteConfigs = new BaseVerifier.RemoteChainConfigArgs[](localCount);
    VersionedVerifierResolver.OutboundImplementationArgs[] memory outbound =
      new VersionedVerifierResolver.OutboundImplementationArgs[](localCount);
    uint256 configured;

    for (uint256 i; i < s_chainConfig.remote_lanes.length; i++) {
      string memory remoteName = s_chainConfig.remote_lanes[i].remote_chain_name;
      if (!_hasLocalCCVs(remoteName)) continue;
      remoteConfigs[configured] = _verifierRemoteConfigFor(remoteName);
      outbound[configured++] = _resolverOutboundFor(remoteName);
    }

    DummyMessageIdVerifier(s_ccv.message_id_verifier).applyRemoteChainConfigUpdates(remoteConfigs);

    VersionedVerifierResolver.InboundImplementationArgs[] memory inbound =
      new VersionedVerifierResolver.InboundImplementationArgs[](1);
    inbound[0] = VersionedVerifierResolver.InboundImplementationArgs({
      version: DummyMessageIdVerifier(s_ccv.message_id_verifier).versionTag(), verifier: s_ccv.message_id_verifier
    });

    VersionedVerifierResolver resolver = VersionedVerifierResolver(s_ccv.verifier_resolver);
    if (outbound.length > 0) {
      resolver.applyOutboundImplementationUpdates(outbound);
    }
    resolver.applyInboundImplementationUpdates(inbound);
    resolver.setFeeAggregator(vm.envOr("FEE_AGGREGATOR", s_chainConfig.governance_addresses.lido_dao_agent));
  }

  function _configureBlockedSelectors() internal {
    ILidoTimelock timelock = ILidoTimelock(s_deployed.timelock);
    for (uint256 i; i < s_defaultConfig.blocked_selectors.length; i++) {
      timelock.blockFunctionSelector(s_defaultConfig.blocked_selectors[i].selector);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // PER-LANE CONFIGURATION (shared with 4_ConnectLane)
  // ═══════════════════════════════════════════════════════════════════════════════

  /// @dev The lane's chain update: an imported lane keeps the replaced pool's remote pools and limits (the remote
  ///      record's pool must be among them); any other lane gets the remote record's pool and the defaults.
  function _chainUpdateFor(
    string memory remoteName
  ) internal view returns (TokenPool.ChainUpdate memory) {
    RemoteChainData memory remote = s_remoteData[remoteName];
    ImportedLane storage imported = s_importedLanes[remoteName];
    bytes[] memory remotePoolAddresses;
    RateLimiterConfig memory outbound = s_defaultConfig.rate_limiter_defaults.outbound;
    RateLimiterConfig memory inbound = s_defaultConfig.rate_limiter_defaults.inbound;
    if (imported.present) {
      remotePoolAddresses = new bytes[](imported.remote_pools.length);
      bool recordPoolListed;
      for (uint256 j; j < imported.remote_pools.length; j++) {
        remotePoolAddresses[j] = abi.encode(imported.remote_pools[j]);
        if (imported.remote_pools[j] == remote.token_pool) recordPoolListed = true;
      }
      if (!recordPoolListed) revert ImportedLaneRemotePoolMismatch(remoteName, remote.token_pool);
      outbound = imported.outbound;
      inbound = imported.inbound;
    } else {
      remotePoolAddresses = new bytes[](1);
      remotePoolAddresses[0] = abi.encode(remote.token_pool);
    }

    return TokenPool.ChainUpdate({
      remoteChainSelector: remote.ccip.chain_selector,
      remotePoolAddresses: remotePoolAddresses,
      remoteTokenAddress: abi.encode(remote.token),
      outboundRateLimiterConfig: _toRateLimiterConfig(outbound),
      inboundRateLimiterConfig: _toRateLimiterConfig(inbound)
    });
  }

  function _feeConfigFor(
    string memory remoteName
  ) internal view returns (TokenPool.TokenTransferFeeConfigArgs memory) {
    return TokenPool.TokenTransferFeeConfigArgs({
      destChainSelector: s_remoteData[remoteName].ccip.chain_selector,
      tokenTransferFeeConfig: IPoolV2.TokenTransferFeeConfig({
        destGasOverhead: s_defaultConfig.token_transfer_fee_defaults.dest_gas_overhead,
        destBytesOverhead: STOCK_SOURCE_POOL_DATA_LENGTH,
        finalityFeeUSDCents: 0,
        fastFinalityFeeUSDCents: 0,
        finalityTransferFeeBps: 0,
        fastFinalityTransferFeeBps: 0,
        isEnabled: true
      })
    });
  }

  /// @dev The lockbox 1_Deploy recorded for the lane, bound to the lane's selector.
  function _lockBoxConfigFor(
    string memory remoteName
  ) internal view returns (ISiloedLockReleaseTokenPool.LockBoxConfig memory) {
    for (uint256 i; i < s_deployed.lock_boxes.length; i++) {
      if (keccak256(bytes(s_deployed.lock_boxes[i].remote_chain_name)) == keccak256(bytes(remoteName))) {
        return ISiloedLockReleaseTokenPool.LockBoxConfig({
          remoteChainSelector: s_remoteData[remoteName].ccip.chain_selector, lockBox: s_deployed.lock_boxes[i].lock_box
        });
      }
    }
    revert NoLockBoxForLane(remoteName);
  }

  /// @dev The hooks entry of a lane verified by the local resolver (placeholder CCV on both directions).
  function _ccvConfigFor(
    string memory remoteName
  ) internal view returns (AdvancedPoolHooks.CCVConfigArg memory) {
    address[] memory resolver = new address[](1);
    resolver[0] = s_ccv.verifier_resolver;
    return AdvancedPoolHooks.CCVConfigArg({
      remoteChainSelector: s_remoteData[remoteName].ccip.chain_selector,
      outboundCCVs: resolver,
      thresholdOutboundCCVs: new address[](0),
      inboundCCVs: resolver,
      thresholdInboundCCVs: new address[](0)
    });
  }

  function _verifierRemoteConfigFor(
    string memory remoteName
  ) internal view returns (BaseVerifier.RemoteChainConfigArgs memory) {
    return BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(s_ccip.router),
      remoteChainSelector: s_remoteData[remoteName].ccip.chain_selector,
      allowlistEnabled: false,
      feeUSDCents: 0,
      gasForVerification: DUMMY_MESSAGE_ID_GAS_FOR_VERIFICATION,
      payloadSizeBytes: DUMMY_MESSAGE_ID_PAYLOAD_SIZE_BYTES
    });
  }

  function _resolverOutboundFor(
    string memory remoteName
  ) internal view returns (VersionedVerifierResolver.OutboundImplementationArgs memory) {
    return VersionedVerifierResolver.OutboundImplementationArgs({
      destChainSelector: s_remoteData[remoteName].ccip.chain_selector, verifier: s_ccv.message_id_verifier
    });
  }

  /// @dev A lane whose hooks require the local resolver: neither imported (no CCVs) nor deferred (the owner's call).
  function _hasLocalCCVs(
    string memory remoteName
  ) internal view returns (bool) {
    return !s_importedLanes[remoteName].present && !_isDeferredLane(remoteName);
  }

  function _lanesWithLocalCCVs() internal view returns (uint256 count) {
    for (uint256 i; i < s_chainConfig.remote_lanes.length; i++) {
      if (_hasLocalCCVs(s_chainConfig.remote_lanes[i].remote_chain_name)) count++;
    }
  }

  /// @dev Lanes this script configures on the pool: every lane that is not deferred.
  function _lanesConfiguredHere() internal view returns (uint256 count) {
    for (uint256 i; i < s_chainConfig.remote_lanes.length; i++) {
      if (!_isDeferredLane(s_chainConfig.remote_lanes[i].remote_chain_name)) count++;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // OWNERSHIP TRANSFER
  // ═══════════════════════════════════════════════════════════════════════════════

  /// @dev Starts each 2-step ownership transfer to the timelock, then accepts them all in one bypass batch while the
  ///      deployer still holds the timelock's ADMIN_ROLE.
  function _transferOwnershipToTimelock() internal {
    address timelock = s_deployed.timelock;
    uint256 count = s_hubMigrationOnly ? 2 : 4;
    address[] memory owned = new address[](count + s_deployed.lock_boxes.length);
    owned[0] = s_deployed.token_pool;
    owned[1] = s_deployed.advanced_pool_hooks;
    if (!s_hubMigrationOnly) {
      owned[2] = s_ccv.message_id_verifier;
      owned[3] = s_ccv.verifier_resolver;
    }
    for (uint256 i; i < s_deployed.lock_boxes.length; i++) {
      address lockBox = s_deployed.lock_boxes[i].lock_box;
      if (s_transferredLockBoxes[lockBox]) continue;
      s_transferredLockBoxes[lockBox] = true;
      owned[count++] = lockBox;
    }

    ILidoTimelock.Call[] memory accepts = new ILidoTimelock.Call[](count);
    for (uint256 i; i < count; i++) {
      Ownable2Step(owned[i]).transferOwnership(timelock);
      accepts[i] = ILidoTimelock.Call(owned[i], 0, abi.encodeCall(Ownable2Step.acceptOwnership, ()));
    }
    ILidoTimelock(timelock).bypasserExecuteBatch(accepts);
  }
}

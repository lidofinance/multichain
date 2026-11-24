// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts@5.3.0/utils/math/SafeCast.sol";

import {CcipDeployBase} from "./CcipDeployBase.sol";

/// @title ConfigParser
/// @notice Library for parsing JSON configuration files for Lido HVMV deployment scripts.
/// @dev The JSON workflow is:
///   1. User creates chain JSON with input fields (chain, addresses, governance, token_deployment, remote_lanes)
///   2. 1_Deploy fetches CCIP addresses from API and writes .ccip + .deployed sections
///   3. 2_Configure reads local + remote chain JSONs for cross-chain configuration
///   CCIP-infra discovery, rate-limiter parsing, and broadcast guards live in CcipDeployBase.
abstract contract ConfigParser is CcipDeployBase {
  using SafeCast for uint256;

  // ============ Errors ============

  error InvalidPoolType(string poolType);
  error InvalidFunctionSelector(string functionSig, bytes selector, bytes4 expectedSelector);
  error RemoteChainMissingData(string remoteChainName, CCIPAddresses ccip, address tokenPool, address token);
  error NoDeployment(string path, address advanced_pool_hooks, address timelock, address call_proxy, address token_pool);
  error TokenDeploymentRequiresBurnMint(string path);
  error MissingTokenDeployment(string path);
  error InvalidTokenDeployment(string path);
  error MissingDeployedToken(string path);
  error InvalidChainConfig(
    string path,
    uint256 chain_id,
    string chain_name,
    address lido_dao_agent,
    address emergency_brakes,
    address chainlink_mcms
  );
  error InvalidImportedLane(string path, string remoteChainName, string reason);
  error InvalidDeferredLane(string path, string remoteChainName, string reason);

  // ============ Enums ============

  enum PoolType {
    BurnMint,
    SiloedLockRelease
  }

  // ============ Default Config Structs ============

  struct TokenTransferFeeDefaults {
    uint32 dest_gas_overhead;
  }

  struct DefaultConfig {
    GovernanceConfig governance;
    BlockedSelector[] blocked_selectors;
    RateLimiterDefaults rate_limiter_defaults;
    TokenTransferFeeDefaults token_transfer_fee_defaults;
  }

  struct GovernanceConfig {
    uint40 min_delay_seconds;
    uint120 expiry_period_seconds;
  }

  struct BlockedSelector {
    string function_sig;
    bytes4 selector;
    string reason;
  }

  struct RateLimiterDefaults {
    RateLimiterConfig outbound;
    RateLimiterConfig inbound;
  }

  struct ChainConfig {
    ChainInfo chain;
    Addresses addresses;
    GovernanceAddresses governance_addresses;
    RemoteLane[] remote_lanes;
  }

  struct ChainInfo {
    uint256 chain_id;
    string chain_name;
    PoolType pool_type;
  }

  /// @dev Parameters of the token that 1_Deploy deploys when addresses.token is address(0).
  struct TokenDeployment {
    string name;
    string symbol;
    uint8 decimals;
    string version; // EIP-712 signing domain version
  }

  struct Addresses {
    address token;
  }

  struct GovernanceAddresses {
    address lido_dao_agent;
    address emergency_brakes;
    address chainlink_mcms;
  }

  struct RemoteLane {
    bool is_siloed;
    string remote_chain_name;
  }

  /// @dev A lane the pool takes over from an existing deployment (`.imported_lanes.<remote_chain_name>`): the remote
  ///      chain is not deployed by these scripts, the lane keeps the remote pools and rate limits the replaced pool
  ///      serves today, and the hooks require no CCVs for it.
  struct ImportedLane {
    bool present;
    address[] remote_pools;
    RateLimiterConfig outbound;
    RateLimiterConfig inbound;
  }

  // ============ Helper structs for JSON parsing ============

  struct BlockedSelectorRaw {
    string function_sig;
    string reason;
    bytes selector;
  }

  // ============ Deployed Addresses (written by 1_Deploy) ============

  struct DeployedAddresses {
    address advanced_pool_hooks;
    LockBoxEntry[] lock_boxes;
    address timelock;
    address call_proxy;
    address token_pool;
    // Set only when 1_Deploy deployed the token (addresses.token is address(0) in the config)
    address token;
    address token_impl;
    address token_proxy_admin;
  }

  struct LockBoxEntry {
    address lock_box;
    string remote_chain_name;
  }

  struct CCVDeployment {
    address message_id_verifier;
    address verifier_resolver;
  }

  // ============ Remote Chain Data (loaded from remote chain JSON by 2_Configure) ============

  struct RemoteChainData {
    CCIPAddresses ccip;
    address token_pool;
    address token;
  }

  // ============ Storage ============

  DefaultConfig internal s_defaultConfig;
  ChainConfig internal s_chainConfig;
  CCIPAddresses internal s_ccip;
  DeployedAddresses internal s_deployed;
  CCVDeployment internal s_ccv;
  /// @dev Set by _loadChainConfig: addresses.token is address(0) in the config, so the scripts deploy the token.
  /// Stays true after the deployed address is copied into addresses.token.
  bool internal s_tokenDeployedByScripts;
  /// @dev Set by _loadChainConfig from `.imported_lanes`; absent lanes have `present == false`.
  mapping(string remoteChainName => ImportedLane lane) internal s_importedLanes;
  /// @dev Set by _loadChainConfig from `.deferred_lanes`: lanes 2_Configure leaves to the pool's owner (4_ConnectLane).
  mapping(string remoteChainName => bool deferred) internal s_deferredLanes;

  // ============ Loading Functions ============

  /// @notice Load the default configuration from JSON
  /// @param path Path to default_config.json
  function _loadDefaultConfig(
    string memory path
  ) internal {
    string memory json = vm.readFile(path);

    // Governance
    s_defaultConfig.governance.min_delay_seconds =
      abi.decode(vm.parseJson(json, ".governance.min_delay_seconds"), (uint256)).toUint40();
    s_defaultConfig.governance.expiry_period_seconds =
      abi.decode(vm.parseJson(json, ".governance.expiry_period_seconds"), (uint256)).toUint120();

    // Blocked selectors
    bytes memory selectorsData = vm.parseJson(json, ".blocked_selectors");
    BlockedSelectorRaw[] memory rawSelectors = abi.decode(selectorsData, (BlockedSelectorRaw[]));
    delete s_defaultConfig.blocked_selectors;
    for (uint256 i; i < rawSelectors.length; i++) {
      bytes4 selector = _validateFunctionSelector(rawSelectors[i].function_sig, rawSelectors[i].selector);
      s_defaultConfig.blocked_selectors.push(
        BlockedSelector({function_sig: rawSelectors[i].function_sig, selector: selector, reason: rawSelectors[i].reason})
      );
    }

    // Rate limiter defaults
    s_defaultConfig.rate_limiter_defaults.outbound = _parseRateLimiterConfig(json, ".rate_limiter_defaults.outbound");
    s_defaultConfig.rate_limiter_defaults.inbound = _parseRateLimiterConfig(json, ".rate_limiter_defaults.inbound");

    // Token transfer fee defaults
    s_defaultConfig.token_transfer_fee_defaults.dest_gas_overhead =
      abi.decode(vm.parseJson(json, ".token_transfer_fee_defaults.dest_gas_overhead"), (uint256)).toUint32();
  }

  /// @notice Load chain-specific configuration from JSON (input fields only, no CCIP/deployed)
  /// @param path Path to chain config JSON file (e.g., config/chains/base_sepolia.json)
  function _loadChainConfig(
    string memory path
  ) internal {
    string memory json = vm.readFile(path);

    // Chain info
    s_chainConfig.chain.chain_id = vm.parseJsonUint(json, ".chain.chain_id");
    s_chainConfig.chain.pool_type = _getPoolType(vm.parseJsonString(json, ".chain.pool_type"));
    s_chainConfig.chain.chain_name = vm.parseJsonString(json, ".chain.chain_name");

    // Token address: address(0) means the scripts deploy the token
    s_chainConfig.addresses.token = vm.parseJsonAddress(json, ".addresses.token");
    s_tokenDeployedByScripts = s_chainConfig.addresses.token == address(0);
    if (s_tokenDeployedByScripts && s_chainConfig.chain.pool_type != PoolType.BurnMint) {
      revert TokenDeploymentRequiresBurnMint(path);
    }

    // Governance addresses
    s_chainConfig.governance_addresses.lido_dao_agent =
      vm.parseJsonAddress(json, ".governance_addresses.lido_dao_agent");
    s_chainConfig.governance_addresses.emergency_brakes =
      vm.parseJsonAddress(json, ".governance_addresses.emergency_brakes");
    s_chainConfig.governance_addresses.chainlink_mcms =
      vm.parseJsonAddress(json, ".governance_addresses.chainlink_mcms");
    if (
      s_chainConfig.chain.chain_id == 0 || bytes(s_chainConfig.chain.chain_name).length == 0
        || s_chainConfig.governance_addresses.lido_dao_agent == address(0)
        || s_chainConfig.governance_addresses.emergency_brakes == address(0)
        || s_chainConfig.governance_addresses.chainlink_mcms == address(0)
    ) {
      revert InvalidChainConfig(
        path,
        s_chainConfig.chain.chain_id,
        s_chainConfig.chain.chain_name,
        s_chainConfig.governance_addresses.lido_dao_agent,
        s_chainConfig.governance_addresses.emergency_brakes,
        s_chainConfig.governance_addresses.chainlink_mcms
      );
    }

    // Remote lanes
    RemoteLane[] memory lanes = abi.decode(vm.parseJson(json, ".remote_lanes"), (RemoteLane[]));
    delete s_chainConfig.remote_lanes;
    for (uint256 i; i < lanes.length; i++) {
      s_chainConfig.remote_lanes.push(lanes[i]);
    }
    _loadImportedLanes(path, json);
    _loadDeferredLanes(path, json);
  }

  /// @notice Load the lanes whose configuration 2_Configure leaves to the pool's owner (`.deferred_lanes`, an array of
  ///         `remote_chain_name`s).
  /// @dev A deferred lane is deployed like any other (1_Deploy builds its lockbox, 2_Configure authorizes the pool on it
  ///      and hands it to the timelock) but gets no chain update, fee config, lockbox binding, CCV entry or verifier and
  ///      resolver entries from the deployer: 4_ConnectLane emits exactly those calls for a proposal of the owner.
  ///      Imported lanes cannot be deferred: they are the lanes the pool must serve from the moment it is bound.
  function _loadDeferredLanes(string memory path, string memory json) internal {
    if (!vm.keyExistsJson(json, ".deferred_lanes")) return;
    string[] memory names = vm.parseJsonStringArray(json, ".deferred_lanes");
    for (uint256 i; i < names.length; i++) {
      string memory name = names[i];
      if (!_isRemoteLane(name)) revert InvalidDeferredLane(path, name, "not a remote lane");
      if (s_importedLanes[name].present) revert InvalidDeferredLane(path, name, "an imported lane cannot be deferred");
      if (s_deferredLanes[name]) revert InvalidDeferredLane(path, name, "listed twice");
      s_deferredLanes[name] = true;
    }
  }

  function _isDeferredLane(string memory name) internal view returns (bool) {
    return s_deferredLanes[name];
  }

  /// @notice Load the lanes the pool takes over from an existing deployment (`.imported_lanes.<remote_chain_name>`).
  /// @dev Each entry names a lane of `.remote_lanes` and carries `remote_pools` (every remote pool the replaced pool
  ///      accepts for that chain; the remote record's `deployed.token_pool` must be among them), `rate_limits.outbound`
  ///      and `rate_limits.inbound` (applied instead of `rate_limiter_defaults`), and `required_ccvs`, which must be
  ///      `"none"`: 2_Configure configures no CCVs for the lane, so the lane keeps its default verification.
  function _loadImportedLanes(string memory path, string memory json) internal {
    if (!vm.keyExistsJson(json, ".imported_lanes")) return;
    string[] memory names = vm.parseJsonKeys(json, ".imported_lanes");
    for (uint256 i; i < names.length; i++) {
      string memory name = names[i];
      if (!_isRemoteLane(name)) revert InvalidImportedLane(path, name, "not a remote lane");
      string memory key = string.concat(".imported_lanes.", name);
      ImportedLane storage lane = s_importedLanes[name];
      lane.present = true;
      delete lane.remote_pools;
      address[] memory pools = vm.parseJsonAddressArray(json, string.concat(key, ".remote_pools"));
      if (pools.length == 0) revert InvalidImportedLane(path, name, "remote_pools is empty");
      for (uint256 j; j < pools.length; j++) {
        if (pools[j] == address(0)) revert InvalidImportedLane(path, name, "zero remote pool");
        lane.remote_pools.push(pools[j]);
      }
      lane.outbound = _parseRateLimiterConfig(json, string.concat(key, ".rate_limits.outbound"));
      lane.inbound = _parseRateLimiterConfig(json, string.concat(key, ".rate_limits.inbound"));
      string memory requiredCCVs = vm.parseJsonString(json, string.concat(key, ".required_ccvs"));
      if (keccak256(bytes(requiredCCVs)) != keccak256(bytes("none"))) {
        revert InvalidImportedLane(path, name, "required_ccvs must be none");
      }
    }
  }

  function _isRemoteLane(string memory name) internal view returns (bool) {
    for (uint256 i; i < s_chainConfig.remote_lanes.length; i++) {
      if (keccak256(bytes(s_chainConfig.remote_lanes[i].remote_chain_name)) == keccak256(bytes(name))) return true;
    }
    return false;
  }

  /// @notice Load the parameters of the token to deploy (.token_deployment), read only when addresses.token is 0.
  function _loadTokenDeployment(
    string memory path
  ) internal view returns (TokenDeployment memory token) {
    string memory json = vm.readFile(path);
    if (!vm.keyExistsJson(json, ".token_deployment")) revert MissingTokenDeployment(path);
    token.name = vm.parseJsonString(json, ".token_deployment.name");
    token.symbol = vm.parseJsonString(json, ".token_deployment.symbol");
    token.decimals = vm.parseJsonUint(json, ".token_deployment.decimals").toUint8();
    token.version = vm.parseJsonString(json, ".token_deployment.version");
    if (bytes(token.name).length == 0 || bytes(token.symbol).length == 0 || bytes(token.version).length == 0) {
      revert InvalidTokenDeployment(path);
    }
    return token;
  }

  /// @notice Load CCIP addresses from chain JSON (populated by 1_Deploy)
  /// @dev Reverts if .ccip section doesn't exist (means 1_Deploy hasn't run)
  function _loadCCIPAddresses(
    string memory path
  ) internal {
    string memory json = vm.readFile(path);

    s_ccip.chain_selector = vm.parseUint(vm.parseJsonString(json, ".ccip.chain_selector")).toUint64();
    s_ccip.router = vm.parseJsonAddress(json, ".ccip.router");
    s_ccip.rmn_proxy = vm.parseJsonAddress(json, ".ccip.rmn_proxy");
    s_ccip.token_admin_registry = vm.parseJsonAddress(json, ".ccip.token_admin_registry");
    s_ccip.registry_module_owner = vm.parseJsonAddress(json, ".ccip.registry_module_owner");

    _validateCCIPAddresses(s_ccip);
  }

  /// @notice Load deployed addresses from chain JSON (populated by 1_Deploy)
  /// @dev Reverts if .deployed section doesn't exist (means 1_Deploy hasn't run). Load the chain config first:
  ///      when the scripts deploy the token, its address is copied from .deployed.token into addresses.token.
  function _loadDeployedAddresses(
    string memory path
  ) internal {
    string memory json = vm.readFile(path);
    s_deployed.advanced_pool_hooks = vm.parseJsonAddress(json, ".deployed.advanced_pool_hooks");
    s_deployed.timelock = vm.parseJsonAddress(json, ".deployed.timelock");
    s_deployed.call_proxy = vm.parseJsonAddress(json, ".deployed.call_proxy");
    s_deployed.token_pool = vm.parseJsonAddress(json, ".deployed.token_pool");
    if (s_tokenDeployedByScripts) {
      if (!vm.keyExistsJson(json, ".deployed.token")) revert MissingDeployedToken(path);
      s_deployed.token = vm.parseJsonAddress(json, ".deployed.token");
      s_deployed.token_impl = vm.parseJsonAddress(json, ".deployed.token_impl");
      s_deployed.token_proxy_admin = vm.parseJsonAddress(json, ".deployed.token_proxy_admin");
      s_chainConfig.addresses.token = s_deployed.token;
    } else {
      delete s_deployed.token;
      delete s_deployed.token_impl;
      delete s_deployed.token_proxy_admin;
    }

    LockBoxEntry[] memory lockBoxes = abi.decode(vm.parseJson(json, ".deployed.lock_boxes"), (LockBoxEntry[]));
    delete s_deployed.lock_boxes;
    for (uint256 i; i < lockBoxes.length; i++) {
      s_deployed.lock_boxes.push(lockBoxes[i]);
    }

    if (
      s_deployed.advanced_pool_hooks == address(0) || s_deployed.timelock == address(0)
        || s_deployed.call_proxy == address(0) || s_deployed.token_pool == address(0)
    ) {
      revert NoDeployment(
        path, s_deployed.advanced_pool_hooks, s_deployed.timelock, s_deployed.call_proxy, s_deployed.token_pool
      );
    }
  }

  function _loadCCVDeployment(
    string memory path
  ) internal {
    string memory json = vm.readFile(path);
    s_ccv.message_id_verifier = _parseOptionalJsonAddress(json, ".ccv.message_id_verifier");
    s_ccv.verifier_resolver = _parseOptionalJsonAddress(json, ".ccv.verifier_resolver");
  }

  /// @dev Returns address(0) when the key is missing.
  function _parseOptionalJsonAddress(string memory json, string memory key) internal view returns (address) {
    return vm.keyExistsJson(json, key) ? vm.parseJsonAddress(json, key) : address(0);
  }

  /// @notice Load all needed data from a remote chain's JSON for cross-chain configuration.
  /// @dev Used by 2_Configure to resolve remote pool, token, and CCIP selector.
  ///      Reverts if the remote chain hasn't been deployed yet.
  /// @param path Path to remote chain's JSON (e.g., config/chains/sepolia.json)
  /// @return data The remote chain's data
  function _loadRemoteChainData(
    string memory path
  ) internal view returns (RemoteChainData memory data) {
    string memory json = vm.readFile(path);

    data.ccip.chain_selector = vm.parseUint(vm.parseJsonString(json, ".ccip.chain_selector")).toUint64();
    data.ccip.router = vm.parseJsonAddress(json, ".ccip.router");
    data.ccip.rmn_proxy = vm.parseJsonAddress(json, ".ccip.rmn_proxy");
    data.ccip.token_admin_registry = vm.parseJsonAddress(json, ".ccip.token_admin_registry");
    data.ccip.registry_module_owner = vm.parseJsonAddress(json, ".ccip.registry_module_owner");
    data.token = vm.parseJsonAddress(json, ".addresses.token");
    if (data.token == address(0)) data.token = _parseOptionalJsonAddress(json, ".deployed.token");
    data.token_pool = vm.parseJsonAddress(json, ".deployed.token_pool");

    if (
      data.ccip.chain_selector == 0 || data.ccip.router == address(0) || data.ccip.rmn_proxy == address(0)
        || data.ccip.token_admin_registry == address(0) || data.ccip.registry_module_owner == address(0)
        || data.token_pool == address(0) || data.token == address(0)
    ) {
      revert RemoteChainMissingData(path, data.ccip, data.token_pool, data.token);
    }
  }

  // ============ Write Functions ============

  /// @notice Save CCIP and deployed addresses to the chain config JSON.
  /// @dev Loads the existing JSON into the serializer, then adds/overwrites the ccip, deployed and ccv
  ///      sections. Input fields, including addresses.token, are left as written. Running again overwrites the same keys.
  function _saveCCIPAndDeployedAddresses(
    string memory path,
    CCIPAddresses memory ccip,
    DeployedAddresses memory deployed,
    CCVDeployment memory ccv
  ) internal {
    string memory root = "root_save";
    vm.serializeJson(root, vm.readFile(path));
    vm.serializeString(root, "ccip", _ccipJson(ccip));
    vm.serializeString(root, "deployed", _deployedJson(deployed));
    string memory finalJson = vm.serializeString(root, "ccv", _ccvJson(ccv));

    _writeJsonUnlessDryRun(finalJson, path);
  }

  function _ccipJson(
    CCIPAddresses memory ccip
  ) internal returns (string memory) {
    string memory key = "ccip_save";
    vm.serializeString(key, "chain_selector", vm.toString(ccip.chain_selector));
    vm.serializeAddress(key, "registry_module_owner", ccip.registry_module_owner);
    vm.serializeAddress(key, "rmn_proxy", ccip.rmn_proxy);
    vm.serializeAddress(key, "router", ccip.router);
    return vm.serializeAddress(key, "token_admin_registry", ccip.token_admin_registry);
  }

  /// @dev Each lockbox is serialized as its own object; a string[] of object JSON nests as an array of objects.
  function _deployedJson(
    DeployedAddresses memory deployed
  ) internal returns (string memory) {
    string[] memory lockBoxes = new string[](deployed.lock_boxes.length);
    for (uint256 i; i < deployed.lock_boxes.length; i++) {
      string memory lockBoxKey = string.concat("lock_box_save_", vm.toString(i));
      vm.serializeAddress(lockBoxKey, "lock_box", deployed.lock_boxes[i].lock_box);
      lockBoxes[i] = vm.serializeString(lockBoxKey, "remote_chain_name", deployed.lock_boxes[i].remote_chain_name);
    }

    string memory key = "deployed_save";
    vm.serializeAddress(key, "advanced_pool_hooks", deployed.advanced_pool_hooks);
    vm.serializeAddress(key, "timelock", deployed.timelock);
    vm.serializeAddress(key, "call_proxy", deployed.call_proxy);
    vm.serializeAddress(key, "token_pool", deployed.token_pool);
    if (deployed.token != address(0)) {
      vm.serializeAddress(key, "token_proxy_admin", deployed.token_proxy_admin);
      vm.serializeAddress(key, "token", deployed.token);
      vm.serializeAddress(key, "token_impl", deployed.token_impl);
    }
    return vm.serializeString(key, "lock_boxes", lockBoxes);
  }

  function _ccvJson(
    CCVDeployment memory ccv
  ) internal returns (string memory) {
    string memory key = "ccv_save";
    vm.serializeAddress(key, "message_id_verifier", ccv.message_id_verifier);
    return vm.serializeAddress(key, "verifier_resolver", ccv.verifier_resolver);
  }

  // ============ Helper Functions ============

  function _getPoolType(
    string memory poolType
  ) internal pure returns (PoolType) {
    if (keccak256(bytes(poolType)) == keccak256(bytes("BurnMint"))) return PoolType.BurnMint;
    if (keccak256(bytes(poolType)) == keccak256(bytes("SiloedLockRelease"))) return PoolType.SiloedLockRelease;
    revert InvalidPoolType(poolType);
  }

  function _validateFunctionSelector(
    string memory functionSig,
    bytes memory selector
  ) internal pure returns (bytes4 validatedSelector) {
    bytes4 expectedSelector = bytes4(keccak256(bytes(functionSig)));
    validatedSelector = bytes4(selector);
    if (selector.length != 4 || validatedSelector != expectedSelector) {
      revert InvalidFunctionSelector(functionSig, selector, expectedSelector);
    }
  }

  /// @notice Extract directory path from a file path
  /// @param filePath Full file path (e.g., "./config/chains/sepolia.json")
  /// @return Directory path (e.g., "./config/chains")
  function _getDirectory(
    string memory filePath
  ) internal pure returns (string memory) {
    bytes memory pathBytes = bytes(filePath);
    uint256 lastSlash = type(uint256).max;

    for (uint256 i = 0; i < pathBytes.length; i++) {
      if (pathBytes[i] == "/") lastSlash = i;
    }

    if (lastSlash == type(uint256).max) return ".";
    if (lastSlash == 0) return "/";

    bytes memory dirBytes = new bytes(lastSlash);
    for (uint256 i = 0; i < lastSlash; i++) {
      dirBytes[i] = pathBytes[i];
    }

    return string(dirBytes);
  }
}

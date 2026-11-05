// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CcipDeployBase} from "../../../script/lib/CcipDeployBase.sol";
import {ConfigParser} from "../../../script/lib/ConfigParser.sol";

/// @notice Test harness that exposes ConfigParser internals for unit testing.
contract ConfigParserHarness is ConfigParser {
  function exposed_validateCCIPAddresses(
    CCIPAddresses memory ccip
  ) external pure {
    _validateCCIPAddresses(ccip);
  }

  function exposed_getPoolType(
    string memory poolType
  ) external pure returns (PoolType) {
    return _getPoolType(poolType);
  }

  function exposed_validateFunctionSelector(
    string memory functionSig,
    bytes memory selector
  ) external pure returns (bytes4) {
    return _validateFunctionSelector(functionSig, selector);
  }

  function exposed_getDirectory(
    string memory filePath
  ) external pure returns (string memory) {
    return _getDirectory(filePath);
  }

  function exposed_loadChainConfig(
    string memory path
  ) external {
    _loadChainConfig(path);
  }

  function exposed_loadDefaultConfig(
    string memory path
  ) external {
    _loadDefaultConfig(path);
  }

  function exposed_loadDeployedAddresses(
    string memory path
  ) external {
    _loadDeployedAddresses(path);
  }

  function exposed_revertIfAlreadyDeployed(
    string memory path
  ) external view {
    _revertIfAlreadyDeployed(path);
  }

  function exposed_loadCCIPAddresses(
    string memory path
  ) external {
    _loadCCIPAddresses(path);
  }

  function exposed_loadRemoteChainData(
    string memory path
  ) external view returns (RemoteChainData memory) {
    return _loadRemoteChainData(path);
  }

  function exposed_loadCCVDeployment(
    string memory path
  ) external {
    _loadCCVDeployment(path);
  }

  function exposed_loadTokenDeployment(
    string memory path
  ) external view returns (TokenDeployment memory) {
    return _loadTokenDeployment(path);
  }

  function exposed_tokenDeployedByScripts() external view returns (bool) {
    return s_tokenDeployedByScripts;
  }

  function exposed_isDeferredLane(
    string memory name
  ) external view returns (bool) {
    return _isDeferredLane(name);
  }

  function exposed_isImportedLane(
    string memory name
  ) external view returns (bool) {
    return s_importedLanes[name].present;
  }

  function exposed_saveCCIPAndDeployedAddresses(
    string memory path,
    CCIPAddresses memory ccip,
    DeployedAddresses memory deployed,
    CCVDeployment memory ccv
  ) external {
    _saveCCIPAndDeployedAddresses(path, ccip, deployed, ccv);
  }

  function exposed_defaultConfig() external view returns (DefaultConfig memory) {
    return s_defaultConfig;
  }

  function exposed_chainConfig() external view returns (ChainConfig memory) {
    return s_chainConfig;
  }

  function exposed_ccip() external view returns (CCIPAddresses memory) {
    return s_ccip;
  }

  function exposed_deployed() external view returns (DeployedAddresses memory) {
    return s_deployed;
  }

  function exposed_ccv() external view returns (CCVDeployment memory) {
    return s_ccv;
  }

  function exposed_tryParseCCIPData(
    string memory json,
    string memory chainIdStr
  ) external pure returns (bool ok, CCIPAddresses memory ccip) {
    ok = _tryParseCCIPData(json, chainIdStr, ccip);
  }

  function exposed_fetchCCIPAddresses(
    uint256 chainId
  ) external returns (CCIPAddresses memory) {
    return _fetchCCIPAddresses(chainId);
  }
}

contract ConfigParserTest is Test {
  ConfigParserHarness internal harness;

  string internal constant FIXTURE_DIR = "contracts/lido-hvmv/test/script/deployment/fixtures";

  function setUp() public {
    harness = new ConfigParserHarness();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _validateCCIPAddresses
  // ═══════════════════════════════════════════════════════════════════════════

  function test_validateCCIPAddresses_ValidAddresses() public view {
    harness.exposed_validateCCIPAddresses(
      CcipDeployBase.CCIPAddresses({
        chain_selector: 1,
        router: address(1),
        rmn_proxy: address(2),
        token_admin_registry: address(3),
        registry_module_owner: address(4)
      })
    );
  }

  function test_RevertWhen_validateCCIPAddresses_ZeroChainSelector() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        CcipDeployBase.InvalidCCIPAddresses.selector, uint64(0), address(1), address(2), address(3), address(4)
      )
    );
    harness.exposed_validateCCIPAddresses(
      CcipDeployBase.CCIPAddresses({
        chain_selector: 0,
        router: address(1),
        rmn_proxy: address(2),
        token_admin_registry: address(3),
        registry_module_owner: address(4)
      })
    );
  }

  function test_RevertWhen_validateCCIPAddresses_ZeroRouter() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        CcipDeployBase.InvalidCCIPAddresses.selector, uint64(1), address(0), address(2), address(3), address(4)
      )
    );
    harness.exposed_validateCCIPAddresses(
      CcipDeployBase.CCIPAddresses({
        chain_selector: 1,
        router: address(0),
        rmn_proxy: address(2),
        token_admin_registry: address(3),
        registry_module_owner: address(4)
      })
    );
  }

  function test_RevertWhen_validateCCIPAddresses_ZeroRmnProxy() public {
    vm.expectRevert();
    harness.exposed_validateCCIPAddresses(
      CcipDeployBase.CCIPAddresses({
        chain_selector: 1,
        router: address(1),
        rmn_proxy: address(0),
        token_admin_registry: address(3),
        registry_module_owner: address(4)
      })
    );
  }

  function test_RevertWhen_validateCCIPAddresses_ZeroTAR() public {
    vm.expectRevert();
    harness.exposed_validateCCIPAddresses(
      CcipDeployBase.CCIPAddresses({
        chain_selector: 1,
        router: address(1),
        rmn_proxy: address(2),
        token_admin_registry: address(0),
        registry_module_owner: address(4)
      })
    );
  }

  function test_RevertWhen_validateCCIPAddresses_ZeroRegistryModule() public {
    vm.expectRevert();
    harness.exposed_validateCCIPAddresses(
      CcipDeployBase.CCIPAddresses({
        chain_selector: 1,
        router: address(1),
        rmn_proxy: address(2),
        token_admin_registry: address(3),
        registry_module_owner: address(0)
      })
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _getPoolType
  // ═══════════════════════════════════════════════════════════════════════════

  function test_getPoolType_BurnMint() public view {
    assertEq(uint8(harness.exposed_getPoolType("BurnMint")), uint8(ConfigParser.PoolType.BurnMint));
  }

  function test_getPoolType_SiloedLockRelease() public view {
    assertEq(uint8(harness.exposed_getPoolType("SiloedLockRelease")), uint8(ConfigParser.PoolType.SiloedLockRelease));
  }

  function test_RevertWhen_getPoolType_Invalid() public {
    vm.expectRevert(abi.encodeWithSelector(ConfigParser.InvalidPoolType.selector, "BadType"));
    harness.exposed_getPoolType("BadType");
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _validateFunctionSelector
  // ═══════════════════════════════════════════════════════════════════════════

  function test_validateFunctionSelector_MatchingSelector() public view {
    assertEq(harness.exposed_validateFunctionSelector("transferOwnership(address)", hex"f2fde38b"), bytes4(0xf2fde38b));
  }

  function test_RevertWhen_validateFunctionSelector_SelectorMismatch() public {
    string memory functionSig = "transferOwnership(address)";
    bytes memory selector = hex"00000000";

    vm.expectRevert(
      abi.encodeWithSelector(ConfigParser.InvalidFunctionSelector.selector, functionSig, selector, bytes4(0xf2fde38b))
    );
    harness.exposed_validateFunctionSelector(functionSig, selector);
  }

  function test_RevertWhen_validateFunctionSelector_InvalidLength() public {
    string memory functionSig = "transferOwnership(address)";
    bytes memory selector = hex"f2fde38b00";

    vm.expectRevert(
      abi.encodeWithSelector(ConfigParser.InvalidFunctionSelector.selector, functionSig, selector, bytes4(0xf2fde38b))
    );
    harness.exposed_validateFunctionSelector(functionSig, selector);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _getDirectory
  // ═══════════════════════════════════════════════════════════════════════════

  function test_getDirectory_NormalPath() public view {
    assertEq(harness.exposed_getDirectory("./config/chains/sepolia.json"), "./config/chains");
  }

  function test_getDirectory_NoSlash() public view {
    assertEq(harness.exposed_getDirectory("file.json"), ".");
  }

  function test_getDirectory_RootPath() public view {
    assertEq(harness.exposed_getDirectory("/file.json"), "/");
  }

  function test_getDirectory_DeepPath() public view {
    assertEq(harness.exposed_getDirectory("/a/b/c/d.json"), "/a/b/c");
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _loadChainConfig — InvalidChainConfig revert
  // ═══════════════════════════════════════════════════════════════════════════

  function test_RevertWhen_loadChainConfig_ZeroLidoDaoAgent() public {
    string memory path = string.concat(FIXTURE_DIR, "/invalid_chain_zero_dao.json");

    vm.expectRevert();
    harness.exposed_loadChainConfig(path);
  }

  function test_RevertWhen_loadChainConfig_ZeroChainId() public {
    string memory path = string.concat(FIXTURE_DIR, "/invalid_chain_zero_id.json");

    harness.exposed_loadDefaultConfig("./contracts/lido-hvmv/config/default_config.json");

    vm.expectRevert();
    harness.exposed_loadChainConfig(path);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _loadDeployedAddresses — NoDeployment revert
  // ═══════════════════════════════════════════════════════════════════════════

  function test_RevertWhen_loadDeployedAddresses_ZeroTokenPool() public {
    vm.expectRevert();
    harness.exposed_loadDeployedAddresses(string.concat(FIXTURE_DIR, "/invalid_deployed_zero.json"));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _loadCCIPAddresses — InvalidCCIPAddresses revert
  // ═══════════════════════════════════════════════════════════════════════════

  function test_RevertWhen_loadCCIPAddresses_ZeroRouter() public {
    vm.expectRevert();
    harness.exposed_loadCCIPAddresses(string.concat(FIXTURE_DIR, "/invalid_ccip_zero_router.json"));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _revertIfAlreadyDeployed
  // ═══════════════════════════════════════════════════════════════════════════

  function test_revertIfAlreadyDeployed_NoDeployedSection() public view {
    // Should NOT revert when .deployed.token_pool doesn't exist
    harness.exposed_revertIfAlreadyDeployed(string.concat(FIXTURE_DIR, "/input_sepolia.json"));
  }

  function test_RevertWhen_revertIfAlreadyDeployed_AlreadyDeployed() public {
    vm.expectRevert("Already deployed: finish an interrupted broadcast with --resume, or remove .deployed to redeploy");
    harness.exposed_revertIfAlreadyDeployed(string.concat(FIXTURE_DIR, "/already_deployed.json"));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _loadRemoteChainData — RemoteChainMissingData revert
  // ═══════════════════════════════════════════════════════════════════════════

  function test_RevertWhen_loadRemoteChainData_ZeroTokenPool() public {
    vm.expectRevert();
    harness.exposed_loadRemoteChainData(string.concat(FIXTURE_DIR, "/invalid_remote_zero_pool.json"));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _loadDefaultConfig — invalid selectors
  // ═══════════════════════════════════════════════════════════════════════════

  function test_RevertWhen_loadDefaultConfig_BlockedSelectorDoesNotMatchSignature() public {
    string memory functionSig = "transferOwnership(address)";
    bytes memory selector = hex"00000000";

    vm.expectRevert(
      abi.encodeWithSelector(ConfigParser.InvalidFunctionSelector.selector, functionSig, selector, bytes4(0xf2fde38b))
    );
    harness.exposed_loadDefaultConfig(string.concat(FIXTURE_DIR, "/invalid_default_blocked_selector.json"));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Success-path loaders
  // ══════════════════════════════════════════════════════════════════════════

  function test_loadDefaultConfig_PopulatesAllFields() public {
    harness.exposed_loadDefaultConfig("./contracts/lido-hvmv/config/default_config.json");

    ConfigParser.DefaultConfig memory cfg = harness.exposed_defaultConfig();

    assertEq(cfg.governance.min_delay_seconds, 3 days);
    assertEq(cfg.governance.expiry_period_seconds, 14 days);
    assertGt(cfg.blocked_selectors.length, 0);
    assertTrue(cfg.rate_limiter_defaults.outbound.enabled);
    assertTrue(cfg.rate_limiter_defaults.inbound.enabled);
    assertGt(cfg.token_transfer_fee_defaults.dest_gas_overhead, 0);
  }

  function test_loadChainConfig_PopulatesAllFields() public {
    harness.exposed_loadChainConfig(string.concat(FIXTURE_DIR, "/input_sepolia.json"));

    ConfigParser.ChainConfig memory cc = harness.exposed_chainConfig();

    assertEq(cc.chain.chain_id, 11155111);
    assertEq(cc.chain.chain_name, "sepolia");
    assertEq(uint8(cc.chain.pool_type), uint8(ConfigParser.PoolType.SiloedLockRelease));
    assertTrue(cc.addresses.token != address(0));
    assertTrue(cc.governance_addresses.lido_dao_agent != address(0));
    assertTrue(cc.governance_addresses.emergency_brakes != address(0));
    assertTrue(cc.governance_addresses.chainlink_mcms != address(0));
    assertGt(cc.remote_lanes.length, 0);
  }

  function test_loadChainConfig_ZeroTokenMeansScriptsDeployIt() public {
    harness.exposed_loadChainConfig(string.concat(FIXTURE_DIR, "/input_base_sepolia.json"));

    ConfigParser.ChainConfig memory cc = harness.exposed_chainConfig();
    assertEq(cc.addresses.token, address(0));
    assertTrue(harness.exposed_tokenDeployedByScripts());
  }

  function test_loadChainConfig_ExistingTokenIsNotDeployedByScripts() public {
    harness.exposed_loadChainConfig(string.concat(FIXTURE_DIR, "/input_sepolia.json"));

    assertTrue(harness.exposed_chainConfig().addresses.token != address(0));
    assertFalse(harness.exposed_tokenDeployedByScripts());
  }

  function test_loadChainConfig_NoDeferredLanesByDefault() public {
    harness.exposed_loadChainConfig(string.concat(FIXTURE_DIR, "/input_sepolia.json"));

    assertFalse(harness.exposed_isDeferredLane("base_sepolia"));
    assertFalse(harness.exposed_isDeferredLane("avalanche_fuji"));
  }

  function test_loadChainConfig_DeferredLanes() public {
    harness.exposed_loadChainConfig(string.concat(FIXTURE_DIR, "/input_hub_deferred.json"));

    assertTrue(harness.exposed_isDeferredLane("base_sepolia"), "the listed lane is deferred");
    assertFalse(harness.exposed_isDeferredLane("avalanche_fuji"), "an unlisted lane is configured by 2_Configure");
    assertFalse(harness.exposed_isImportedLane("base_sepolia"), "a deferred lane is not imported");
    assertEq(harness.exposed_chainConfig().remote_lanes.length, 2, "a deferred lane stays a remote lane");
  }

  function test_RevertWhen_loadChainConfig_DeferredLaneIsNotARemoteLane() public {
    string memory path = string.concat(FIXTURE_DIR, "/invalid_deferred_not_a_lane.json");
    vm.expectRevert(
      abi.encodeWithSelector(ConfigParser.InvalidDeferredLane.selector, path, "nowhere", "not a remote lane")
    );
    harness.exposed_loadChainConfig(path);
  }

  function test_RevertWhen_loadChainConfig_DeferredLaneIsImported() public {
    string memory path = string.concat(FIXTURE_DIR, "/invalid_deferred_imported.json");
    vm.expectRevert(
      abi.encodeWithSelector(
        ConfigParser.InvalidDeferredLane.selector, path, "base_sepolia", "an imported lane cannot be deferred"
      )
    );
    harness.exposed_loadChainConfig(path);
  }

  function test_loadCCIPAddresses_PopulatesAllFields() public {
    harness.exposed_loadCCIPAddresses(string.concat(FIXTURE_DIR, "/valid_full.json"));

    CcipDeployBase.CCIPAddresses memory ccip = harness.exposed_ccip();

    assertEq(ccip.chain_selector, 16015286601757825753);
    assertEq(ccip.router, address(0x0000000000000000000000000000000000000111));
    assertEq(ccip.rmn_proxy, address(0x0000000000000000000000000000000000000222));
    assertEq(ccip.token_admin_registry, address(0x0000000000000000000000000000000000000333));
    assertEq(ccip.registry_module_owner, address(0x0000000000000000000000000000000000000444));
  }

  function test_loadDeployedAddresses_PopulatesAllFields() public {
    harness.exposed_loadDeployedAddresses(string.concat(FIXTURE_DIR, "/valid_full.json"));

    ConfigParser.DeployedAddresses memory dep = harness.exposed_deployed();

    assertEq(dep.advanced_pool_hooks, address(0xAaa));
    assertEq(dep.timelock, address(0xcCC));
    assertEq(dep.call_proxy, address(0xC0C));
    assertEq(dep.token_pool, address(0xdDd));
    assertEq(dep.lock_boxes.length, 1);
    assertEq(dep.lock_boxes[0].lock_box, address(0xBb1));
    assertEq(dep.lock_boxes[0].remote_chain_name, "base_sepolia");
  }

  function test_RevertWhen_loadChainConfig_ZeroTokenWithLockRelease() public {
    string memory path = _copyFixtureForSave("valid_full.json", "zero_token_lock_release");
    vm.writeJson(string.concat("\"", vm.toString(address(0)), "\""), path, ".addresses.token");

    vm.expectRevert(abi.encodeWithSelector(ConfigParser.TokenDeploymentRequiresBurnMint.selector, path));
    harness.exposed_loadChainConfig(path);
    vm.removeFile(path);
  }

  function test_loadTokenDeployment_ParsesTestnetConfig() public {
    string memory path = string.concat(FIXTURE_DIR, "/input_base_sepolia.json");
    harness.exposed_loadChainConfig(path);
    ConfigParser.TokenDeployment memory token = harness.exposed_loadTokenDeployment(path);

    assertTrue(harness.exposed_tokenDeployedByScripts(), "zero token means scripts deploy it");
    assertEq(token.name, "Mock wstETH");
    assertEq(token.symbol, "mwstETH");
    assertEq(token.decimals, 18);
    assertEq(token.version, "2");
  }

  function test_RevertWhen_loadTokenDeployment_EmptyName() public {
    string memory path = "contracts/lido-hvmv/config/chains/_template_new_token.json";
    vm.expectRevert(abi.encodeWithSelector(ConfigParser.InvalidTokenDeployment.selector, path));
    harness.exposed_loadTokenDeployment(path);
  }

  function test_RevertWhen_loadTokenDeployment_SectionMissing() public {
    // An existing-token config left with address(0) must fail clearly rather than on a missing JSON key.
    string memory path = "contracts/lido-hvmv/config/chains/_template_existing_token.json";
    vm.expectRevert(abi.encodeWithSelector(ConfigParser.MissingTokenDeployment.selector, path));
    harness.exposed_loadTokenDeployment(path);
  }

  function test_RevertWhen_loadDeployedAddresses_MissingDeployedToken() public {
    string memory path = _copyFixtureForSave("valid_full.json", "missing_deployed_token");
    vm.writeJson(string.concat("\"", vm.toString(address(0)), "\""), path, ".addresses.token");
    vm.writeJson("\"BurnMint\"", path, ".chain.pool_type");
    harness.exposed_loadChainConfig(path);

    vm.expectRevert(abi.encodeWithSelector(ConfigParser.MissingDeployedToken.selector, path));
    harness.exposed_loadDeployedAddresses(path);
    vm.removeFile(path);
  }

  function test_saveThenLoad_DeployedTokenAndLockBoxes() public {
    string memory path = _copyFixtureForSave("valid_full.json", "deployed_token");
    vm.writeJson(string.concat("\"", vm.toString(address(0)), "\""), path, ".addresses.token");
    vm.writeJson("\"BurnMint\"", path, ".chain.pool_type");
    ConfigParser.DeployedAddresses memory deployed = _deployedForSave(2);
    deployed.token = address(0x7070);
    deployed.token_impl = address(0x1111);
    deployed.token_proxy_admin = address(0x2222);

    harness.exposed_saveCCIPAndDeployedAddresses(path, _ccipForSave(), deployed, _ccvForSave());
    harness.exposed_loadChainConfig(path);
    harness.exposed_loadDeployedAddresses(path);
    harness.exposed_loadCCVDeployment(path);
    ConfigParser.RemoteChainData memory asRemote = harness.exposed_loadRemoteChainData(path);
    address savedInputToken = vm.parseJsonAddress(vm.readFile(path), ".addresses.token");
    vm.removeFile(path);

    assertEq(savedInputToken, address(0), "input addresses.token left as written");
    assertEq(harness.exposed_chainConfig().addresses.token, address(0x7070), "deployed token copied on load");
    assertEq(asRemote.token, address(0x7070), "remote chain sees the deployed token");
    _assertDeployedRoundTrip(harness.exposed_deployed(), deployed);
    assertEq(harness.exposed_ccv().verifier_resolver, address(0xC2), "ccv saved");
  }

  function test_saveThenLoad_ExistingTokenAndNoLockBoxes() public {
    string memory path = _copyFixtureForSave("valid_full.json", "existing_token");
    ConfigParser.DeployedAddresses memory deployed = _deployedForSave(0);

    harness.exposed_saveCCIPAndDeployedAddresses(path, _ccipForSave(), deployed, _ccvForSave());
    harness.exposed_loadChainConfig(path);
    harness.exposed_loadDeployedAddresses(path);
    vm.removeFile(path);

    assertEq(harness.exposed_chainConfig().addresses.token, address(0xA11), "existing token kept");
    _assertDeployedRoundTrip(harness.exposed_deployed(), deployed);
  }

  function _copyFixtureForSave(string memory fixture, string memory name) internal returns (string memory) {
    string memory path = string.concat("contracts/lido-hvmv/test/script/deployment/.save_", name, ".json");
    vm.writeFile(path, vm.readFile(string.concat(FIXTURE_DIR, "/", fixture)));
    return path;
  }

  function _deployedForSave(
    uint256 lockBoxCount
  ) internal pure returns (ConfigParser.DeployedAddresses memory) {
    ConfigParser.DeployedAddresses memory deployed;
    deployed.advanced_pool_hooks = address(0xA1);
    deployed.timelock = address(0xA2);
    deployed.call_proxy = address(0xA4);
    deployed.token_pool = address(0xA3);
    deployed.lock_boxes = new ConfigParser.LockBoxEntry[](lockBoxCount);
    for (uint256 i; i < lockBoxCount; i++) {
      deployed.lock_boxes[i] = ConfigParser.LockBoxEntry({
        lock_box: address(uint160(0xB0 + i)),
        remote_chain_name: i == 0 ? "base_sepolia" : "arbitrum_sepolia"
      });
    }
    return deployed;
  }

  function _ccipForSave() internal pure returns (CcipDeployBase.CCIPAddresses memory) {
    return CcipDeployBase.CCIPAddresses({
      chain_selector: 16015286601757825753,
      router: address(0x111),
      rmn_proxy: address(0x222),
      token_admin_registry: address(0x333),
      registry_module_owner: address(0x444)
    });
  }

  function _ccvForSave() internal pure returns (ConfigParser.CCVDeployment memory) {
    return ConfigParser.CCVDeployment({message_id_verifier: address(0xC1), verifier_resolver: address(0xC2)});
  }

  function _assertDeployedRoundTrip(
    ConfigParser.DeployedAddresses memory actual,
    ConfigParser.DeployedAddresses memory expected
  ) internal pure {
    assertEq(actual.advanced_pool_hooks, expected.advanced_pool_hooks, "advanced_pool_hooks");
    assertEq(actual.timelock, expected.timelock, "timelock");
    assertEq(actual.call_proxy, expected.call_proxy, "call_proxy");
    assertEq(actual.token_pool, expected.token_pool, "token_pool");
    assertEq(actual.token, expected.token, "token");
    assertEq(actual.token_impl, expected.token_impl, "token_impl");
    assertEq(actual.token_proxy_admin, expected.token_proxy_admin, "token_proxy_admin");
    assertEq(actual.lock_boxes.length, expected.lock_boxes.length, "lock_boxes length");
    for (uint256 i; i < expected.lock_boxes.length; i++) {
      assertEq(actual.lock_boxes[i].lock_box, expected.lock_boxes[i].lock_box, "lock_box");
      assertEq(actual.lock_boxes[i].remote_chain_name, expected.lock_boxes[i].remote_chain_name, "remote_chain_name");
    }
  }

  function test_loadCCVDeployment_PopulatesAllFields() public {
    harness.exposed_loadCCVDeployment(string.concat(FIXTURE_DIR, "/valid_full.json"));

    ConfigParser.CCVDeployment memory ccv = harness.exposed_ccv();

    assertEq(ccv.message_id_verifier, address(0xeeE));
    assertEq(ccv.verifier_resolver, address(0xfFf));
  }

  function test_loadCCVDeployment_MissingSectionLeavesZero() public {
    // sepolia test config has no .ccv section — the loader should swallow the parse error and leave fields zero.
    harness.exposed_loadCCVDeployment(string.concat(FIXTURE_DIR, "/input_sepolia.json"));

    ConfigParser.CCVDeployment memory ccv = harness.exposed_ccv();
    assertEq(ccv.message_id_verifier, address(0));
    assertEq(ccv.verifier_resolver, address(0));
  }

  function test_RevertWhen_loadCCVDeployment_MalformedValues() public {
    // Missing keys are optional, but a present key must hold an address: a typo fails instead of loading address(0).
    vm.expectRevert();
    harness.exposed_loadCCVDeployment(string.concat(FIXTURE_DIR, "/malformed_addresses.json"));
  }

  function test_revertIfAlreadyDeployed_MalformedTokenPoolSwallowed() public view {
    // .deployed.token_pool is a non-address string — the loader's catch should swallow it and not revert.
    harness.exposed_revertIfAlreadyDeployed(string.concat(FIXTURE_DIR, "/malformed_addresses.json"));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _tryParseCCIPData — covers the inner JSON-parse catches without HTTP
  // ═══════════════════════════════════════════════════════════════════════════

  function test_tryParseCCIPData_SuccessfulRouter_OptionalFieldsMissing() public view {
    // Router present, all optional sub-fields absent — exercises the success-path return value plus all four
    // inner try-blocks where the parsed bytes come back empty (so the if-guarded assignments are skipped).
    string memory json = "{\"data\":{\"evm\":{\"1\":{\"router\":\"0x0000000000000000000000000000000000000111\"}}}}";

    (bool ok, CcipDeployBase.CCIPAddresses memory ccip) = harness.exposed_tryParseCCIPData(json, "1");

    assertTrue(ok);
    assertEq(ccip.router, address(0x0000000000000000000000000000000000000111));
    assertEq(ccip.rmn_proxy, address(0));
    assertEq(ccip.token_admin_registry, address(0));
    assertEq(ccip.registry_module_owner, address(0));
    assertEq(ccip.chain_selector, 0);
  }

  function test_tryParseCCIPData_ChainMissingReturnsFalse() public view {
    // Chain "1" exists in the response, but we query for "999" — outer try succeeds with empty bytes,
    // exercising the `routerData.length == 0 -> return false` early exit.
    string memory json = "{\"data\":{\"evm\":{\"1\":{\"router\":\"0x0000000000000000000000000000000000000111\"}}}}";

    (bool ok,) = harness.exposed_tryParseCCIPData(json, "999");

    assertFalse(ok);
  }

  function test_tryParseCCIPData_MalformedJsonReturnsFalse() public view {
    // Outer try should fail when the JSON is structurally invalid, hitting the outer catch.
    string memory json = "this is not json";

    (bool ok,) = harness.exposed_tryParseCCIPData(json, "1");

    assertFalse(ok);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _fetchCCIPAddresses (mainnet fallback)
  // ═══════════════════════════════════════════════════════════════════════════

  /// @dev Exercises the mainnet-fallback branch: testnet API doesn't have chain 1 (mainnet Ethereum),
  /// so the lookup falls through to the mainnet API and returns. Requires network access via `vm.ffi`.
  function test_fetchCCIPAddresses_FallsBackToMainnet() public {
    CcipDeployBase.CCIPAddresses memory ccip = harness.exposed_fetchCCIPAddresses(1);

    // Don't assert specific addresses — those can change if Chainlink redeploys CCIP infra.
    // Asserting non-zero suffices and is stable.
    assertGt(uint256(ccip.chain_selector), 0);
    assertTrue(ccip.router != address(0));
    assertTrue(ccip.rmn_proxy != address(0));
    assertTrue(ccip.token_admin_registry != address(0));
    assertTrue(ccip.registry_module_owner != address(0));
  }

  function test_loadRemoteChainData_PopulatesAllFields() public view {
    ConfigParser.RemoteChainData memory data =
      harness.exposed_loadRemoteChainData(string.concat(FIXTURE_DIR, "/valid_full.json"));

    assertEq(data.ccip.chain_selector, 16015286601757825753);
    assertEq(data.ccip.router, address(0x0000000000000000000000000000000000000111));
    assertEq(data.token, address(0xa11));
    assertEq(data.token_pool, address(0xdDd));
  }
}

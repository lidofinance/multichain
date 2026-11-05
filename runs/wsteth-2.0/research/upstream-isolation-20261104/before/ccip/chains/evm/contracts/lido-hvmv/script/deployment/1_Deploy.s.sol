// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {PausableAdvancedPoolHooks} from "../../PausableAdvancedPoolHooks.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/ccvs/VersionedVerifierResolver.sol";
import {ERC20BridgedPermit} from "@lido/wsteth-token/token/ERC20BridgedPermit.sol";
import {
  TransparentUpgradeableProxy
} from "@openzeppelin/contracts@5.3.0/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts@5.3.0/token/ERC20/extensions/IERC20Metadata.sol";
import {console} from "forge-std/console.sol";

import {Artifact} from "../lib/Artifact.sol";
import {ConfigParser} from "../lib/ConfigParser.sol";

import {DummyMessageIdVerifier} from "../../ccvs/DummyMessageIdVerifier.sol";
import {ILidoTimelock} from "../../interfaces/ILidoTimelock.sol";

/// @title DeployScript
/// @notice Deploys all Lido HVMV contracts for a single chain. Does NOT configure or transfer ownership.
/// @dev Run this on each chain first. After all chains are deployed, run 2_Configure on each chain.
///      Env vars: CHAIN_CONFIG (required), DEFAULT_CONFIG (optional), DEPLOYER_PRIVATE_KEY (optional)
contract DeployScript is ConfigParser {
  address internal s_deployer;
  uint256 internal s_deployerPrivateKey;
  string internal s_chainConfigPath;
  TokenDeployment internal s_tokenDeployment;
  bool internal s_hubMigrationOnly;

  function setUp() public {
    _loadConfigs();
  }

  function getDeployer() public view returns (address) {
    return s_deployer;
  }

  function run() public virtual {
    _revertIfBroadcastingWithTestKey(s_deployerPrivateKey);
    _revertIfAlreadyDeployed(s_chainConfigPath);
    require(block.chainid == s_chainConfig.chain.chain_id, "Chain ID mismatch: RPC chain != config chain_id");

    vm.startBroadcast(s_deployerPrivateKey);

    _deployTokenIfNeeded();
    _deployLockBoxes();
    _deployTokenPool();
    _deployAdvancedPoolHooks();
    if (!s_hubMigrationOnly) _deployCCVStack();
    _deployTimelock();

    vm.stopBroadcast();

    _saveResults();
    _logDeployment();
  }

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
      for (uint256 i; i < s_chainConfig.remote_lanes.length; ++i) {
        string memory name = s_chainConfig.remote_lanes[i].remote_chain_name;
        require(_isDeferredLane(name) || s_importedLanes[name].present, "Hub migration only admits imported lanes");
      }
    }
    if (s_tokenDeployedByScripts) s_tokenDeployment = _loadTokenDeployment(s_chainConfigPath);

    s_ccip = _fetchCCIPAddresses(s_chainConfig.chain.chain_id);
  }

  /// @dev The Lido DAO owns the ProxyAdmin from the start. The deployer is the transient token admin.
  function _deployTokenIfNeeded() internal {
    if (!s_tokenDeployedByScripts) return;

    TokenDeployment memory t = s_tokenDeployment;
    ERC20BridgedPermit impl = new ERC20BridgedPermit(t.name, t.symbol, t.version, t.decimals);
    bytes memory initData =
      abi.encodeWithSignature("initialize(string,string,string,address)", t.name, t.symbol, t.version, s_deployer);
    TransparentUpgradeableProxy proxy =
      new TransparentUpgradeableProxy(address(impl), s_chainConfig.governance_addresses.lido_dao_agent, initData);

    s_deployed.token = address(proxy);
    s_deployed.token_impl = address(impl);
    s_deployed.token_proxy_admin = _proxyAdminOf(address(proxy));
    // In memory only: the lockboxes and pool below use it; the saved config keeps address(0) as written.
    s_chainConfig.addresses.token = address(proxy);
  }

  function _deployLockBoxes() internal {
    PoolType poolType = s_chainConfig.chain.pool_type;
    if (poolType == PoolType.SiloedLockRelease) {
      address sharedLockBox;

      for (uint256 i; i < s_chainConfig.remote_lanes.length; i++) {
        RemoteLane memory lane = s_chainConfig.remote_lanes[i];
        if (s_hubMigrationOnly && _isDeferredLane(lane.remote_chain_name)) continue;
        address lockBox;

        if (lane.is_siloed) {
          lockBox = _deployLockBox();
        } else {
          if (sharedLockBox == address(0)) {
            sharedLockBox = _deployLockBox();
          }
          lockBox = sharedLockBox;
        }

        s_deployed.lock_boxes.push(LockBoxEntry({lock_box: lockBox, remote_chain_name: lane.remote_chain_name}));
      }
    }
  }

  function _deployLockBox() internal returns (address) {
    return Artifact.deploy(vm, "ERC20LockBox.sol:ERC20LockBox", abi.encode(s_chainConfig.addresses.token));
  }

  function _deployTokenPool() internal {
    string memory artifact = s_chainConfig.chain.pool_type == PoolType.BurnMint
      ? "BurnMintTokenPool.sol:BurnMintTokenPool"
      : "SiloedLockReleaseTokenPool.sol:SiloedLockReleaseTokenPool";
    uint8 decimals = IERC20Metadata(s_chainConfig.addresses.token).decimals();

    // advancedPoolHooks is address(0) here; it is wired in _deployAdvancedPoolHooks.
    s_deployed.token_pool = Artifact.deploy(
      vm, artifact, abi.encode(s_chainConfig.addresses.token, decimals, address(0), s_ccip.rmn_proxy, s_ccip.router)
    );
  }

  function _deployAdvancedPoolHooks() internal {
    address[] memory authorizedCallers = new address[](1);
    authorizedCallers[0] = s_deployed.token_pool;
    address[] memory pausers = new address[](1);
    pausers[0] = s_chainConfig.governance_addresses.emergency_brakes;
    s_deployed.advanced_pool_hooks = address(
      new PausableAdvancedPoolHooks(new address[](0), 0, address(0), authorizedCallers, pausers, new address[](0))
    );
  }

  function _deployCCVStack() internal {
    string[] memory storageLocations = new string[](1);
    storageLocations[0] = vm.envOr("STORAGE_LOCATION", string("dummy://message-id-verifier"));

    DummyMessageIdVerifier.DynamicConfig memory dynamicConfig = DummyMessageIdVerifier.DynamicConfig({
      feeAggregator: vm.envOr("FEE_AGGREGATOR", s_chainConfig.governance_addresses.lido_dao_agent),
      allowlistAdmin: vm.envOr("ALLOWLIST_ADMIN", address(0))
    });

    address rmn = vm.envOr("RMN_REMOTE", s_ccip.rmn_proxy);

    s_ccv.message_id_verifier = address(new DummyMessageIdVerifier(storageLocations, dynamicConfig, rmn));
    s_ccv.verifier_resolver = address(new VersionedVerifierResolver());
  }

  /// @dev The deployer is the transient admin; 3_SetPoolAndTransferOwnership hands ADMIN_ROLE to the Lido DAO.
  ///      The CallProxy is the only executor, so anyone can execute a ready proposal through it.
  ///      Both are deployed from their artifacts: they are compiled with solc 0.8.19, which this script cannot import.
  function _deployTimelock() internal {
    GovernanceAddresses memory governance = s_chainConfig.governance_addresses;
    address[] memory proposers = new address[](1);
    proposers[0] = governance.chainlink_mcms;
    address[] memory cancellers = new address[](2);
    cancellers[0] = governance.emergency_brakes;
    cancellers[1] = governance.chainlink_mcms;
    address[] memory proposalQueueHalters = new address[](1);
    proposalQueueHalters[0] = governance.emergency_brakes;

    // There are no bypassers besides the admin.
    s_deployed.timelock = Artifact.deploy(
      vm,
      "LidoTimelock.sol:LidoTimelock",
      abi.encode(
        uint256(s_defaultConfig.governance.min_delay_seconds),
        s_defaultConfig.governance.expiry_period_seconds,
        s_deployer,
        proposers,
        new address[](0),
        cancellers,
        new address[](0),
        proposalQueueHalters
      )
    );

    ILidoTimelock timelock = ILidoTimelock(s_deployed.timelock);
    s_deployed.call_proxy = Artifact.deploy(vm, "CallProxy.sol:CallProxy", abi.encode(address(timelock)));
    timelock.grantRole(timelock.EXECUTOR_ROLE(), s_deployed.call_proxy);
  }

  function _saveResults() internal {
    _saveCCIPAndDeployedAddresses(s_chainConfigPath, s_ccip, s_deployed, s_ccv);
  }

  function _logDeployment() internal view {
    console.log("=== Deployment Complete ===");
    console.log("Chain:", s_chainConfig.chain.chain_name);
    console.log("Chain ID:", s_chainConfig.chain.chain_id);
    console.log("Pool Type:", s_chainConfig.chain.pool_type == PoolType.BurnMint ? "BurnMint" : "SiloedLockRelease");
    console.log("TokenPool:", s_deployed.token_pool);
    console.log("PausableAdvancedPoolHooks:", s_deployed.advanced_pool_hooks);
    console.log("LidoTimelock:", s_deployed.timelock);
    console.log("CallProxy (timelock executor):", s_deployed.call_proxy);
    console.log("DummyMessageIdVerifier:", s_ccv.message_id_verifier);
    console.log("VerifierResolver:", s_ccv.verifier_resolver);
    if (s_tokenDeployedByScripts) {
      console.log("Token (deployed):", s_deployed.token);
      console.log("Token implementation:", s_deployed.token_impl);
      console.log("Token ProxyAdmin (owned by the Lido DAO):", s_deployed.token_proxy_admin);
    }
    console.log("LockBoxes:", s_deployed.lock_boxes.length);
    console.log("CCIP Chain Selector:", s_ccip.chain_selector);
    console.log("Router:", s_ccip.router, "\n");
  }
}

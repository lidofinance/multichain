// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ConfigureScript} from "@ccip-lido/script/deployment/2_Configure.s.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {RegistryModuleOwnerCustom} from "@chainlink/contracts-ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {BurnMintERC20Transparent} from
  "@chainlink/contracts/src/v0.8/shared/token/ERC20/upgradeable/BurnMintERC20Transparent.sol";
import {TransparentUpgradeableProxy} from
  "@openzeppelin/contracts@5.3.0/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test} from "forge-std/Test.sol";

contract ConfigureTokenHarness is ConfigureScript {
  function loadConfig(string memory path) external {
    _loadConfigs("./config/default_config.non_l1.json", path, 1);
  }

  function configureToken(address token, address pool, address dao, address deployer, address registry, address module)
    external
  {
    s_tokenDeployedByScripts = true;
    s_chainConfig.addresses.token = token;
    s_chainConfig.governance_addresses.lido_dao_agent = dao;
    s_deployed.token_pool = pool;
    s_deployer = deployer;
    s_ccip.token_admin_registry = registry;
    s_ccip.registry_module_owner = module;
    vm.startPrank(deployer);
    _configureTokenIfNeeded();
    vm.stopPrank();
  }
}

contract ConfigureTokenTest is Test {
  BurnMintERC20Transparent internal s_token;
  TokenAdminRegistry internal s_registry;
  RegistryModuleOwnerCustom internal s_module;
  ConfigureTokenHarness internal s_script;
  address internal s_dao = makeAddr("DAO");
  address internal s_pool = makeAddr("Pool");
  address internal s_foreign = makeAddr("ForeignAdmin");

  function setUp() public {
    s_registry = new TokenAdminRegistry();
    s_module = new RegistryModuleOwnerCustom(address(s_registry));
    s_registry.addRegistryModule(address(s_module));
    s_script = new ConfigureTokenHarness();
    s_token = BurnMintERC20Transparent(address(new TransparentUpgradeableProxy(
      address(new BurnMintERC20Transparent()), s_dao,
      abi.encodeCall(BurnMintERC20Transparent.initialize, ("Fresh token", "FRESH", 18, 0, 0, address(this)))
    )));
  }

  function _configure() internal {
    s_script.configureToken(address(s_token), s_pool, s_dao, address(this), address(s_registry), address(s_module));
  }

  function _assertConfigured() internal view {
    TokenAdminRegistry.TokenConfig memory config = s_registry.getTokenConfig(address(s_token));
    assertEq(config.administrator, address(this));
    assertEq(config.pendingAdministrator, address(0));
    assertEq(config.tokenPool, address(0));
    assertEq(s_token.getCCIPAdmin(), s_dao);
    (address pendingAdmin,) = s_token.pendingDefaultAdmin();
    assertEq(pendingAdmin, s_dao);
    assertTrue(s_token.hasRole(s_token.MINTER_ROLE(), s_pool));
    assertTrue(s_token.hasRole(s_token.BURNER_ROLE(), s_pool));
  }

  function test_SharedLoader_RejectsMissingCCVDeployment() public {
    string memory path = "state/.configure_missing_ccv.json";
    vm.writeFile(path, vm.readFile("./config/chains/mantle_sepolia.json"));
    vm.writeJson("\"0x1111111111111111111111111111111111111111\"", path, ".addresses.token");
    vm.writeJson(
      "{\"advanced_pool_hooks\":\"0x1111111111111111111111111111111111111111\",\"pool_operation_manager\":\"0x1111111111111111111111111111111111111111\",\"token_pool\":\"0x1111111111111111111111111111111111111111\",\"lock_boxes\":[]}",
      path, ".deployed"
    );
    vm.writeJson("\"0x1111111111111111111111111111111111111111\"", path, ".governance_addresses.lido_dao_agent");
    vm.writeJson("{}", path, ".ccv");
    vm.expectRevert(abi.encodeWithSelector(ConfigureScript.MissingCCVDeployment.selector, address(0), address(0)));
    s_script.loadConfig(path);
    vm.removeFile(path);
  }

  function test_Unregistered_SelfRegistersBeforeTokenAdminTransfer() public {
    _configure();
    _assertConfigured();
  }

  function test_Preproposed_AcceptsBeforeTokenAdminTransfer() public {
    s_registry.proposeAdministrator(address(s_token), address(this));
    _configure();
    _assertConfigured();
  }

  function test_AlreadyRegistered_KeepsDeployerTarAuthority() public {
    s_registry.proposeAdministrator(address(s_token), address(this));
    s_registry.acceptAdminRole(address(s_token));
    _configure();
    _assertConfigured();
  }

  function test_RevertWhen_ForeignAdministrator() public {
    s_registry.proposeAdministrator(address(s_token), s_foreign);
    vm.prank(s_foreign);
    s_registry.acceptAdminRole(address(s_token));
    vm.expectRevert(abi.encodeWithSelector(ConfigureScript.UnexpectedTokenAdministrator.selector, s_foreign));
    _configure();
    assertEq(s_registry.getTokenConfig(address(s_token)).administrator, s_foreign);
    assertEq(s_token.getCCIPAdmin(), address(this));
  }

  function test_RevertWhen_ForeignPendingAdministrator_NotOverwritten() public {
    s_registry.proposeAdministrator(address(s_token), s_foreign);
    vm.expectRevert(abi.encodeWithSelector(ConfigureScript.UnexpectedPendingTokenAdministrator.selector, s_foreign));
    _configure();
    assertEq(s_registry.getTokenConfig(address(s_token)).pendingAdministrator, s_foreign);
    assertFalse(s_token.hasRole(s_token.MINTER_ROLE(), s_pool));
  }

  function test_RevertWhen_DeployerRegisteredWithForeignPendingAdministrator() public {
    s_registry.proposeAdministrator(address(s_token), address(this));
    s_registry.acceptAdminRole(address(s_token));
    s_registry.transferAdminRole(address(s_token), s_foreign);
    vm.expectRevert(abi.encodeWithSelector(ConfigureScript.UnexpectedPendingTokenAdministrator.selector, s_foreign));
    _configure();
    assertEq(s_registry.getTokenConfig(address(s_token)).pendingAdministrator, s_foreign);
  }
}

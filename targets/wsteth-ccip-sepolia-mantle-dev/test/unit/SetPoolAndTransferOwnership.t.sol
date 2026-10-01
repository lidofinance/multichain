// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PausableAdvancedPoolHooks} from "@ccip-lido/PausableAdvancedPoolHooks.sol";
import {PoolOperationManager} from "@ccip-lido/PoolOperationManager.sol";
import {SetPoolAndTransferOwnershipScript} from "@ccip-lido/script/deployment/3_SetPoolAndTransferOwnership.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {BurnMintERC20Transparent} from
  "@chainlink/contracts/src/v0.8/shared/token/ERC20/upgradeable/BurnMintERC20Transparent.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts@5.3.0/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts@5.3.0/proxy/ERC1967/ERC1967Utils.sol";
import {TransparentUpgradeableProxy} from
  "@openzeppelin/contracts@5.3.0/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test} from "forge-std/Test.sol";

// Injects the state that script 3 otherwise loads from the chain JSON.
contract SetPoolAndTransferOwnershipHarness is SetPoolAndTransferOwnershipScript {
  function setRegistryState(address registry, address manager) external {
    s_ccip.token_admin_registry = registry;
    s_deployed.pool_operation_manager = manager;
  }

  function exposed_transferManagerAdminToDao() external {
    vm.startPrank(s_deployer);
    _transferManagerAdminToDao();
    vm.stopPrank();
  }

  function exposed_tryRegisterPoolAndTransferAdmin() external {
    vm.startPrank(s_deployer);
    _tryRegisterPoolAndTransferAdmin();
    vm.stopPrank();
  }

  function setTokenState(
    address deployer,
    address lidoDao,
    bool tokenDeployedByScripts,
    address token,
    address tokenPool,
    address proxyAdmin
  ) external {
    s_deployer = deployer;
    s_chainConfig.governance_addresses.lido_dao_agent = lidoDao;
    s_tokenDeployedByScripts = tokenDeployedByScripts;
    s_chainConfig.addresses.token = token;
    s_deployed.token_pool = tokenPool;
    s_deployed.proxy_admin = proxyAdmin;
  }

  function setManagedContracts(
    address manager,
    address tokenPool,
    address hooks,
    address verifier,
    address resolver
  ) external {
    s_deployed.pool_operation_manager = manager;
    s_deployed.token_pool = tokenPool;
    s_deployed.advanced_pool_hooks = hooks;
    s_ccv.message_id_verifier = verifier;
    s_ccv.verifier_resolver = resolver;
  }

  function loadDefaultConfig() external {
    _loadDefaultConfig("./config/default_config.json");
  }

  function defaultConfig() external view returns (DefaultConfig memory) {
    return s_defaultConfig;
  }

  function exposed_checkOwnedByManager() external view {
    _checkOwnedByManager();
  }

  function exposed_checkManagerWiring() external view {
    _checkManagerWiring();
  }

  function exposed_checkGovernanceConfig() external view {
    _checkGovernanceConfig();
  }

  function exposed_checkLidoDaoHasCode() external view {
    _checkLidoDaoHasCode();
  }

  function exposed_checkDeployedTokenHandoverToDao() external view {
    _checkDeployedTokenHandoverToDao();
  }

  function exposed_poolHasTokenRole(
    bytes32 role
  ) external view returns (bool known, bool hasRole) {
    return _poolHasTokenRole(role);
  }
}

contract ReadOnlyCCIPAdminToken {
  address public immutable getCCIPAdmin;

  constructor(address admin) {
    getCCIPAdmin = admin;
  }
}

contract SetPoolAndTransferOwnershipTest is Test {
  bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
  bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");

  address internal s_dao = makeAddr("LidoDao");
  address internal s_pool = makeAddr("TokenPool");
  SetPoolAndTransferOwnershipHarness internal s_script;
  BurnMintERC20Transparent internal s_token;
  address internal s_proxyAdmin;
  TokenAdminRegistry internal s_registry;

  function setUp() public {
    (s_token, s_proxyAdmin) = _deployToken(s_dao);
    s_script = new SetPoolAndTransferOwnershipHarness();
    s_script.setTokenState(address(this), s_dao, true, address(s_token), s_pool, s_proxyAdmin);
    s_registry = new TokenAdminRegistry();
    s_registry.proposeAdministrator(address(s_token), address(this));
    s_registry.acceptAdminRole(address(s_token));
    s_script.setRegistryState(address(s_registry), makeAddr("Manager"));
  }

  function _deployToken(
    address proxyAdminOwner
  ) internal returns (BurnMintERC20Transparent token, address proxyAdmin) {
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new BurnMintERC20Transparent()),
      proxyAdminOwner,
      abi.encodeCall(BurnMintERC20Transparent.initialize, ("Mock wstETH", "mwstETH", 18, 0, 0, address(this)))
    );
    token = BurnMintERC20Transparent(address(proxy));
    proxyAdmin = address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT))));
  }

  // ════════════════════════════════════════════════════════════════════════
  // Deployed token handover to the Lido DAO
  // ════════════════════════════════════════════════════════════════════════

  function test_checkDeployedTokenHandoverToDao_SkipsExistingToken() public {
    s_script.setTokenState(address(this), s_dao, false, address(s_token), s_pool, s_proxyAdmin);
    s_script.exposed_checkDeployedTokenHandoverToDao();
  }

  function test_checkDeployedTokenHandoverToDao_PassesWhilePending() public {
    s_token.setCCIPAdmin(s_dao);
    s_token.beginDefaultAdminTransfer(s_dao);
    s_script.exposed_checkDeployedTokenHandoverToDao();
  }

  function test_checkDeployedTokenHandoverToDao_PassesAfterDaoAccepted() public {
    s_token.setCCIPAdmin(s_dao);
    s_token.beginDefaultAdminTransfer(s_dao);
    vm.warp(block.timestamp + 1);
    vm.prank(s_dao);
    s_token.acceptDefaultAdminTransfer();

    s_script.exposed_checkDeployedTokenHandoverToDao();
  }

  function test_RevertWhen_checkDeployedTokenHandoverToDao_CCIPAdminNotDao() public {
    s_token.beginDefaultAdminTransfer(s_dao);
    vm.expectRevert(
      abi.encodeWithSelector(SetPoolAndTransferOwnershipScript.TokenCCIPAdminNotDao.selector, address(this))
    );
    s_script.exposed_checkDeployedTokenHandoverToDao();
  }

  function test_RevertWhen_checkDeployedTokenHandoverToDao_TransferNotStarted() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        SetPoolAndTransferOwnershipScript.DeployedTokenAdminTransferNotStarted.selector, address(0)
      )
    );
    s_script.exposed_checkDeployedTokenHandoverToDao();
  }

  function test_RevertWhen_checkDeployedTokenHandoverToDao_ProxyAdminNotOwnedByDao() public {
    (BurnMintERC20Transparent token, address proxyAdmin) = _deployToken(address(this));
    token.setCCIPAdmin(s_dao);
    token.beginDefaultAdminTransfer(s_dao);
    s_script.setTokenState(address(this), s_dao, true, address(token), s_pool, proxyAdmin);

    vm.expectRevert(
      abi.encodeWithSelector(SetPoolAndTransferOwnershipScript.ProxyAdminNotOwnedByDao.selector, address(this))
    );
    s_script.exposed_checkDeployedTokenHandoverToDao();
  }

  function test_RevertWhen_checkDeployedTokenHandoverToDao_Unregistered() public {
    s_token.setCCIPAdmin(s_dao);
    s_token.beginDefaultAdminTransfer(s_dao);
    s_script.setRegistryState(address(new TokenAdminRegistry()), makeAddr("Manager"));
    vm.expectRevert(
      abi.encodeWithSelector(SetPoolAndTransferOwnershipScript.UnexpectedTokenAdministrator.selector, address(0))
    );
    s_script.exposed_checkDeployedTokenHandoverToDao();
  }

  function test_RevertWhen_checkDeployedTokenHandoverToDao_ForeignAdministrator() public {
    s_token.setCCIPAdmin(s_dao);
    s_token.beginDefaultAdminTransfer(s_dao);
    s_registry.transferAdminRole(address(s_token), s_dao);
    vm.prank(s_dao);
    s_registry.acceptAdminRole(address(s_token));
    vm.expectRevert(
      abi.encodeWithSelector(SetPoolAndTransferOwnershipScript.UnexpectedTokenAdministrator.selector, s_dao)
    );
    s_script.exposed_checkDeployedTokenHandoverToDao();
  }

  function test_RevertWhen_checkDeployedTokenHandoverToDao_ManagerHasWrongPool() public {
    s_token.setCCIPAdmin(s_dao);
    s_token.beginDefaultAdminTransfer(s_dao);
    s_script.setRegistryState(address(s_registry), address(this));
    vm.expectRevert(
      abi.encodeWithSelector(SetPoolAndTransferOwnershipScript.UnexpectedTokenPool.selector, address(0))
    );
    s_script.exposed_checkDeployedTokenHandoverToDao();
  }

  function test_checkDeployedTokenHandoverToDao_ManagerHasCorrectPool() public {
    s_token.setCCIPAdmin(s_dao);
    s_token.beginDefaultAdminTransfer(s_dao);
    s_script.setRegistryState(address(s_registry), address(this));
    vm.mockCall(s_pool, abi.encodeWithSignature("isSupportedToken(address)", address(s_token)), abi.encode(true));
    s_registry.setPool(address(s_token), s_pool);
    s_script.exposed_checkDeployedTokenHandoverToDao();
  }

  function _handoverExistingToken(address token, bool alreadyRegistered) internal {
    TokenAdminRegistry registry = new TokenAdminRegistry();
    registry.proposeAdministrator(token, address(this));
    if (alreadyRegistered) registry.acceptAdminRole(token);
    PoolOperationManager manager = _deployManager(s_pool);
    s_script.setTokenState(address(this), s_dao, false, token, s_pool, s_proxyAdmin);
    s_script.setRegistryState(address(registry), address(manager));
    vm.mockCall(s_pool, abi.encodeWithSignature("isSupportedToken(address)", token), abi.encode(true));
    s_script.exposed_tryRegisterPoolAndTransferAdmin();
    TokenAdminRegistry.TokenConfig memory config = registry.getTokenConfig(token);
    assertEq(config.administrator, address(manager));
    assertEq(config.pendingAdministrator, address(0));
    assertEq(config.tokenPool, s_pool);
  }

  function test_ExistingToken_Preproposed_TransfersCCIPAdmin() public {
    _handoverExistingToken(address(s_token), false);
    assertEq(s_token.getCCIPAdmin(), s_dao);
  }

  function test_ExistingToken_Registered_TransfersCCIPAdmin() public {
    _handoverExistingToken(address(s_token), true);
    assertEq(s_token.getCCIPAdmin(), s_dao);
  }

  function test_ExistingToken_DaoAcceptedEarly_TarHandoverStillWorks() public {
    s_token.beginDefaultAdminTransfer(s_dao);
    vm.warp(block.timestamp + 1);
    vm.prank(s_dao);
    s_token.acceptDefaultAdminTransfer();
    _handoverExistingToken(address(s_token), false);
    assertEq(s_token.defaultAdmin(), s_dao);
    assertEq(s_token.getCCIPAdmin(), address(this), "Token admin must finish this separately");
  }

  function test_ExistingToken_NoCCIPAdminSetter_TarHandoverStillWorks() public {
    ReadOnlyCCIPAdminToken token = new ReadOnlyCCIPAdminToken(address(this));
    vm.expectCall(address(token), abi.encodeWithSignature("setCCIPAdmin(address)", s_dao), uint64(0));
    _handoverExistingToken(address(token), false);
    assertEq(token.getCCIPAdmin(), address(this));
  }

  function test_ManagerAdminHandover_CanBeRetriedAfterDeployerRevoked() public {
    PoolOperationManager manager = _deployManager(s_pool);
    s_script.setRegistryState(address(s_registry), address(manager));
    s_script.exposed_transferManagerAdminToDao();
    assertTrue(manager.hasRole(bytes32(0), s_dao));
    assertFalse(manager.hasRole(bytes32(0), address(this)));
    s_script.exposed_transferManagerAdminToDao();
    assertTrue(manager.hasRole(bytes32(0), s_dao));
  }

  // ════════════════════════════════════════════════════════════════════════
  // Pool mint/burn roles
  // ════════════════════════════════════════════════════════════════════════

  function test_poolHasTokenRole_ReportsGrantedRoles() public {
    (bool known, bool hasRole) = s_script.exposed_poolHasTokenRole(MINTER_ROLE);
    assertTrue(known, "known before grant");
    assertFalse(hasRole, "no role before grant");

    s_token.grantMintAndBurnRoles(s_pool);

    (known, hasRole) = s_script.exposed_poolHasTokenRole(MINTER_ROLE);
    assertTrue(known && hasRole, "minter after grant");
    (known, hasRole) = s_script.exposed_poolHasTokenRole(BURNER_ROLE);
    assertTrue(known && hasRole, "burner after grant");
  }

  function test_poolHasTokenRole_UnknownWithoutAccessControl() public {
    address tokenWithoutAccessControl = address(new TokenAdminRegistry());
    s_script.setTokenState(address(this), s_dao, false, tokenWithoutAccessControl, s_pool, s_proxyAdmin);

    (bool known, bool hasRole) = s_script.exposed_poolHasTokenRole(MINTER_ROLE);
    assertFalse(known, "contract without hasRole");
    assertFalse(hasRole, "contract without hasRole");

    s_script.setTokenState(address(this), s_dao, false, makeAddr("NoCode"), s_pool, s_proxyAdmin);
    (known, hasRole) = s_script.exposed_poolHasTokenRole(MINTER_ROLE);
    assertFalse(known, "address without code");
    assertFalse(hasRole, "address without code");
  }

  // ════════════════════════════════════════════════════════════════════════
  // Preflight: ownership, wiring, governance config, DAO
  // ════════════════════════════════════════════════════════════════════════

  function _ownable() internal returns (address) {
    return address(new PausableAdvancedPoolHooks(new address[](0), 0, address(0), new address[](0)));
  }

  function test_checkOwnedByManager_PassesWhenManagerOwnsAll() public {
    s_script.setManagedContracts(address(this), _ownable(), _ownable(), _ownable(), _ownable());
    s_script.exposed_checkOwnedByManager();
  }

  function test_RevertWhen_checkOwnedByManager_NotOwnedByManager() public {
    address manager = makeAddr("PoolOperationManager");
    address pool = _ownable();
    s_script.setManagedContracts(manager, pool, _ownable(), _ownable(), _ownable());

    vm.expectRevert(
      abi.encodeWithSelector(SetPoolAndTransferOwnershipScript.NotOwnedByManager.selector, pool, address(this))
    );
    s_script.exposed_checkOwnedByManager();
  }

  function _deployManager(
    address tokenPool
  ) internal returns (PoolOperationManager) {
    s_script.loadDefaultConfig();
    PoolOperationManager.InitialRoles memory roles;
    roles.admin = address(this);
    return PoolOperationManager(
      address(
        new ERC1967Proxy(
          address(new PoolOperationManager()),
          abi.encodeCall(
            PoolOperationManager.initialize,
            (
              tokenPool,
              s_script.defaultConfig().governance.min_delay_seconds,
              s_script.defaultConfig().governance.validity_period_seconds,
              roles
            )
          )
        )
      )
    );
  }

  function _applyDefaultSelectorPolicy(
    PoolOperationManager manager
  ) internal {
    SetPoolAndTransferOwnershipHarness.DefaultConfig memory defaults = s_script.defaultConfig();
    for (uint256 i; i < defaults.blocked_selectors.length; i++) {
      manager.setSelectorBlocked(defaults.blocked_selectors[i].selector, true);
    }
    for (uint256 i; i < defaults.custom_delay_selectors.length; i++) {
      manager.setSelectorMinDelay(
        defaults.custom_delay_selectors[i].selector, defaults.custom_delay_selectors[i].delay_seconds
      );
    }
  }

  function test_checkManagerWiring_PassesWhenWired() public {
    address hooks = makeAddr("Hooks");
    PoolOperationManager manager = _deployManager(s_pool);
    _mockPoolHooks(hooks);
    s_script.setManagedContracts(address(manager), s_pool, hooks, address(0), address(0));

    s_script.exposed_checkManagerWiring();
  }

  function test_RevertWhen_checkManagerWiring_PoolUsesOtherHooks() public {
    address otherHooks = makeAddr("OtherHooks");
    PoolOperationManager manager = _deployManager(s_pool);
    _mockPoolHooks(otherHooks);
    s_script.setManagedContracts(address(manager), s_pool, makeAddr("Hooks"), address(0), address(0));

    vm.expectRevert(
      abi.encodeWithSelector(SetPoolAndTransferOwnershipScript.ManagerNotWired.selector, s_pool, otherHooks)
    );
    s_script.exposed_checkManagerWiring();
  }

  function _mockPoolHooks(
    address hooks
  ) internal {
    vm.etch(s_pool, hex"00");
    vm.mockCall(s_pool, abi.encodeWithSelector(TokenPool.getAdvancedPoolHooks.selector), abi.encode(hooks));
  }

  function test_checkGovernanceConfig_PassesWithDefaultPolicy() public {
    PoolOperationManager manager = _deployManager(s_pool);
    _applyDefaultSelectorPolicy(manager);
    s_script.setManagedContracts(address(manager), s_pool, address(0), address(0), address(0));

    s_script.exposed_checkGovernanceConfig();
  }

  function test_RevertWhen_checkGovernanceConfig_TimingMismatch() public {
    PoolOperationManager manager = _deployManager(s_pool);
    _applyDefaultSelectorPolicy(manager);
    manager.setGlobalMinDelay(1 days);
    s_script.setManagedContracts(address(manager), s_pool, address(0), address(0), address(0));

    vm.expectRevert(
      abi.encodeWithSelector(
        SetPoolAndTransferOwnershipScript.GovernanceTimingMismatch.selector,
        1 days,
        s_script.defaultConfig().governance.validity_period_seconds
      )
    );
    s_script.exposed_checkGovernanceConfig();
  }

  function test_RevertWhen_checkGovernanceConfig_SelectorNotBlocked() public {
    PoolOperationManager manager = _deployManager(s_pool);
    _applyDefaultSelectorPolicy(manager);
    bytes4 selector = s_script.defaultConfig().blocked_selectors[0].selector;
    manager.setSelectorBlocked(selector, false);
    s_script.setManagedContracts(address(manager), s_pool, address(0), address(0), address(0));

    vm.expectRevert(abi.encodeWithSelector(SetPoolAndTransferOwnershipScript.SelectorNotBlocked.selector, selector));
    s_script.exposed_checkGovernanceConfig();
  }

  function test_RevertWhen_checkGovernanceConfig_SelectorDelayMismatch() public {
    PoolOperationManager manager = _deployManager(s_pool);
    _applyDefaultSelectorPolicy(manager);
    SetPoolAndTransferOwnershipHarness.CustomDelaySelector memory custom =
      s_script.defaultConfig().custom_delay_selectors[0];
    manager.setSelectorMinDelay(custom.selector, 0);
    s_script.setManagedContracts(address(manager), s_pool, address(0), address(0), address(0));

    vm.expectRevert(
      abi.encodeWithSelector(
        SetPoolAndTransferOwnershipScript.SelectorDelayMismatch.selector,
        custom.selector,
        custom.delay_seconds,
        manager.getGlobalMinDelay()
      )
    );
    s_script.exposed_checkGovernanceConfig();
  }

  function test_checkLidoDaoHasCode_PassesForContract() public {
    s_script.setTokenState(address(this), address(this), false, address(s_token), s_pool, s_proxyAdmin);
    s_script.exposed_checkLidoDaoHasCode();
  }

  function test_RevertWhen_checkLidoDaoHasCode_Eoa() public {
    vm.expectRevert(abi.encodeWithSelector(SetPoolAndTransferOwnershipScript.LidoDaoHasNoCode.selector, s_dao));
    s_script.exposed_checkLidoDaoHasCode();
  }
}

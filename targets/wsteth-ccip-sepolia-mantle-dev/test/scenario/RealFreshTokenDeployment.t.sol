// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BridgeScenarioBase} from "./BridgeScenarioBase.sol";
import {DeployScript} from "@ccip-lido/script/deployment/1_Deploy.s.sol";
import {ConfigureScript} from "@ccip-lido/script/deployment/2_Configure.s.sol";
import {SetPoolAndTransferOwnershipScript} from "@ccip-lido/script/deployment/3_SetPoolAndTransferOwnership.s.sol";
import {PoolOperationManager} from "@ccip-lido/PoolOperationManager.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {RegistryModuleOwnerCustom} from "@chainlink/contracts-ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {
    BurnMintERC20Transparent
} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/upgradeable/BurnMintERC20Transparent.sol";
import {ProxyAdmin} from "@openzeppelin/contracts@5.3.0/proxy/transparent/ProxyAdmin.sol";

// Use the target's pinned, real CCIP infrastructure rather than fetching changing API data.
// Contract creation, persisted records, configuration and handover use the actual scripts.
contract FreshTokenDeployHarness is DeployScript {
    function loadPinnedConfig(string memory path, string memory defaults) external {
        _loadConfigs(defaults, path, 1);
    }

    function _loadDeploymentInfrastructure() internal override {
        _loadCCIPAddresses(s_chainConfigPath);
    }
}

contract FreshTokenConfigureHarness is ConfigureScript {
    function loadPinnedConfig(string memory path, string memory defaults) external {
        _loadConfigs(defaults, path, 1);
        _resolveRemoteData();
    }
}

contract FreshTokenHandoverHarness is SetPoolAndTransferOwnershipScript {
    function loadPinnedConfig(string memory path, string memory defaults) external {
        _loadConfigs(defaults, path, 1);
    }
}

contract RealFreshTokenDeployment is BridgeScenarioBase {
    string internal freshRecord;
    address internal dao;

    // Foundry runs setUp once and gives each test an isolated copy of its EVM baseline.
    // Deploy the common stack once; only TAR proposal / DAO acceptance ordering varies.
    function setUp() public {
        l2Chain = vm.envOr("L2_CHAIN", string("mantle_sepolia"));
        vm.selectFork(_createL2Fork(l2Chain));
        string memory path = "state/.fresh_token_deployment.json";
        dao = _inputConfig(path);
        vm.deal(vm.addr(1), 100 ether);
        FreshTokenDeployHarness deploy = new FreshTokenDeployHarness();
        deploy.loadPinnedConfig(path, "./config/default_config.non_l1.json");
        deploy.run();
        freshRecord = vm.readFile(path);
        vm.removeFile(path);
    }

    function test_FreshToken_Unregistered_DaoAcceptsAfterHandover() public {
        _freshDeployment(false, false);
    }

    function test_FreshToken_Preproposed_DaoAcceptsBeforeHandover() public {
        _freshDeployment(true, true);
    }

    function test_FreshToken_Preproposed_DaoAcceptsAfterHandover() public {
        _freshDeployment(true, false);
    }

    function test_FreshToken_Unregistered_DaoAcceptsBeforeHandover() public {
        _freshDeployment(false, true);
    }

    function _freshDeployment(bool preproposed, bool acceptBefore) internal {
        string memory path = string.concat(
            "state/.fresh_token_", vm.toString(preproposed), "_", vm.toString(acceptBefore), ".json"
        );
        if (vm.exists(path)) vm.removeFile(path);
        vm.writeFile(path, freshRecord);
        string memory defaults = "./config/default_config.non_l1.json";
        address deployer = vm.addr(1);
        string memory record = freshRecord;
        BurnMintERC20Transparent token = BurnMintERC20Transparent(vm.parseJsonAddress(record, ".deployed.token"));
        TokenAdminRegistry registry = TokenAdminRegistry(vm.parseJsonAddress(record, ".ccip.token_admin_registry"));

        if (preproposed) {
            vm.prank(deployer);
            RegistryModuleOwnerCustom(vm.parseJsonAddress(record, ".ccip.registry_module_owner"))
                .registerAdminViaGetCCIPAdmin(address(token));
        }

        FreshTokenConfigureHarness configure = new FreshTokenConfigureHarness();
        configure.loadPinnedConfig(path, defaults);
        configure.run();
        assertEq(registry.getTokenConfig(address(token)).administrator, deployer);
        assertEq(registry.getTokenConfig(address(token)).tokenPool, address(0), "Configure must not activate the pool");
        assertEq(token.getCCIPAdmin(), dao);
        vm.warp(block.timestamp + 1);
        if (acceptBefore) {
            vm.prank(dao);
            token.acceptDefaultAdminTransfer();
        }

        FreshTokenHandoverHarness handover = new FreshTokenHandoverHarness();
        handover.loadPinnedConfig(path, defaults);
        handover.run();
        if (!acceptBefore) {
            vm.prank(dao);
            token.acceptDefaultAdminTransfer();
        }

        _assertFinal(record, dao, deployer);
        vm.removeFile(path);
    }

    function _inputConfig(string memory path) internal returns (address recipient) {
        string memory records = vm.envOr("RECORD_DIR", string("config/chains"));
        string memory deployedRecord = vm.readFile(string.concat(records, "/", l2Chain, ".json"));
        recipient = vm.parseJsonAddress(deployedRecord, ".governance_addresses.lido_dao_agent");
        require(recipient.code.length != 0, "Deploy L2 governance before this fork rehearsal");

        // Failure artifacts belong in state, never among broadcast deployment records.
        if (vm.exists(path)) vm.removeFile(path);
        vm.writeFile(path, deployedRecord);
        vm.writeJson("{}", path, ".deployed");
        vm.writeJson("\"0x0000000000000000000000000000000000000000\"", path, ".addresses.token");
        vm.writeJson(string.concat("\"", vm.toString(recipient), "\""), path, ".governance_addresses.lido_dao_agent");
        vm.writeJson("[]", path, ".remote_lanes");
        vm.writeJson(
            "{\"name\":\"Fresh wstETH\",\"symbol\":\"fwstETH\",\"decimals\":18,\"max_supply\":0}",
            path,
            ".token_deployment"
        );
    }

    function _assertFinal(string memory record, address recipient, address deployer) internal view {
        BurnMintERC20Transparent token = BurnMintERC20Transparent(vm.parseJsonAddress(record, ".deployed.token"));
        address pool = vm.parseJsonAddress(record, ".deployed.token_pool");
        PoolOperationManager manager =
            PoolOperationManager(vm.parseJsonAddress(record, ".deployed.pool_operation_manager"));
        TokenAdminRegistry registry = TokenAdminRegistry(vm.parseJsonAddress(record, ".ccip.token_admin_registry"));
        TokenAdminRegistry.TokenConfig memory finalConfig = registry.getTokenConfig(address(token));
        assertEq(finalConfig.administrator, address(manager));
        assertEq(finalConfig.pendingAdministrator, address(0));
        assertEq(finalConfig.tokenPool, pool);
        assertEq(token.defaultAdmin(), recipient);
        assertEq(token.getCCIPAdmin(), recipient);
        assertTrue(token.hasRole(token.MINTER_ROLE(), pool));
        assertTrue(token.hasRole(token.BURNER_ROLE(), pool));
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(manager)));
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), recipient));
        assertFalse(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), deployer));
        assertEq(ProxyAdmin(vm.parseJsonAddress(record, ".deployed.proxy_admin")).owner(), recipient);
        assertEq(vm.parseJsonAddress(record, ".addresses.token"), address(0), "Keep the input token sentinel");
    }
}

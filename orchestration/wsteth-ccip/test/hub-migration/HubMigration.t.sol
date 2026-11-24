// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HubMigrationBase} from "../../script/hub-migration/HubMigrationBase.sol";
import {DeployHubForMigration} from "../../script/hub-migration/DeployHubForMigration.s.sol";
import {ConfigureHubForMigration} from "../../script/hub-migration/ConfigureHubForMigration.s.sol";
import {PrepareHubLane} from "../../script/hub-migration/PrepareHubLane.s.sol";
import {BuildHubLaneProposal} from "../../script/hub-migration/BuildHubLaneProposal.s.sol";
import {ILidoTimelock} from "@ccip-lido/interfaces/ILidoTimelock.sol";
import {ConfigParser} from "@ccip-lido/script/lib/ConfigParser.sol";
import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {ISiloedLockReleaseTokenPool} from "@ccip-lido/script/lib/ISiloedLockReleaseTokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";

contract FixtureToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

interface HubLockBoxes {
    function getLockBox(uint64 selector) external view returns (address);
}

contract MigrationParserHarness is HubMigrationBase {
    function load(string memory chain, string memory manifest) external {
        _loadMigrationInputs(
            chain,
            manifest,
            "../../components/ccip/chains/evm/contracts/lido-hvmv/config/default_config.json",
            2,
            false,
            false
        );
    }

    function update(string memory name) external view returns (TokenPool.ChainUpdate memory) {
        return _chainUpdateFor(name);
    }
}

contract StockParserHarness is ConfigParser {
    function read(string memory path) external returns (address pool) {
        _loadChainConfig(path);
        _loadCCIPAddresses(path);
        _loadDeployedAddresses(path);
        return s_deployed.token_pool;
    }
}

contract HubMigrationTest is Test {
    string constant FIXTURES = "tests/fixtures/hub-migration/";
    string RUN;
    string CFG;
    string MANIFEST;

    function _fixture(string memory name) internal {
        RUN = string.concat(FIXTURES, "runtime/", name, "/");
        CFG = string.concat(RUN, "hub.json");
        MANIFEST = string.concat(RUN, "manifest.json");
        vm.chainId(1);
        vm.createDir(RUN, true);
        string[6] memory names = ["hub", "manifest", "shared_a", "shared_b", "isolated", "base"];
        for (uint256 i; i < names.length; ++i) {
            vm.writeFile(string.concat(RUN, names[i], ".json"), vm.readFile(string.concat(FIXTURES, names[i], ".json")));
        }
        address token = address(new FixtureToken());
        vm.writeJson(vm.toString(token), CFG, ".addresses.token");
        vm.writeJson(vm.toString(token), MANIFEST, ".token");
    }

    function _environment() internal {
        vm.setEnv("CHAIN_CONFIG", CFG);
        vm.setEnv("HUB_MANIFEST", MANIFEST);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "2");
        vm.setEnv("DEFAULT_CONFIG", "../../components/ccip/chains/evm/contracts/lido-hvmv/config/default_config.json");
        vm.setEnv("CCIP_ARTIFACTS", "../../components/ccip/chains/evm/foundry-artifacts");
        vm.setEnv("ARTIFACT_DEPLOYMENTS_OUT", string.concat(RUN, "deployments.json"));
    }

    function testFullRemotePoolSetAndDistinctLimits() public {
        _fixture("testFullRemotePoolSetAndDistinctLimits");
        MigrationParserHarness parser = new MigrationParserHarness();
        parser.load(CFG, MANIFEST);
        TokenPool.ChainUpdate memory shared = parser.update("shared_a");
        TokenPool.ChainUpdate memory isolated = parser.update("isolated");
        assertEq(isolated.remotePoolAddresses.length, 2);
        assertEq(abi.decode(isolated.remotePoolAddresses[1], (address)), address(132));
        assertEq(shared.outboundRateLimiterConfig.capacity, 1000);
        assertEq(isolated.outboundRateLimiterConfig.capacity, 1200);
        assertEq(isolated.inboundRateLimiterConfig.rate, 22);
    }

    function testManifestDisagreementRejected() public {
        _fixture("testManifestDisagreementRejected");
        vm.writeJson('"9999"', CFG, ".imported_lanes.isolated.rate_limits.outbound.capacity");
        MigrationParserHarness parser = new MigrationParserHarness();
        vm.expectRevert("Manifest outbound mismatch");
        parser.load(CFG, MANIFEST);
    }

    function testImportedLaneCannotAlsoBeDeferred() public {
        _fixture("testImportedLaneCannotAlsoBeDeferred");
        vm.writeJson('["isolated"]', CFG, ".deferred_lanes");
        MigrationParserHarness parser = new MigrationParserHarness();
        vm.expectRevert(
            abi.encodeWithSelector(
                HubMigrationBase.InvalidDeferredLane.selector, CFG, "isolated", "an imported lane cannot be deferred"
            )
        );
        parser.load(CFG, MANIFEST);
    }

    function testWrongChainRejected() public {
        _fixture("testWrongChainRejected");
        vm.chainId(2);
        MigrationParserHarness parser = new MigrationParserHarness();
        vm.expectRevert("Chain ID mismatch");
        parser.load(CFG, MANIFEST);
    }

    function testArtifactsDeployConfigureAndStockRecordRead() public {
        _fixture("testArtifactsDeployConfigureAndStockRecordRead");
        _environment();
        DeployHubForMigration deployer = new DeployHubForMigration();
        deployer.setUp();
        deployer.run();
        string memory record = vm.readFile(CFG);
        address pool = vm.parseJsonAddress(record, ".deployed.token_pool");
        assertEq(new StockParserHarness().read(CFG), pool);
        assertEq(vm.parseJsonAddress(record, ".ccv.message_id_verifier"), address(0));
        ConfigureHubForMigration configurator = new ConfigureHubForMigration();
        configurator.setUp();
        configurator.run();
        assertEq(TokenPool(pool).getSupportedChains().length, 3);
        assertFalse(TokenPool(pool).isSupportedChain(105), "Base must remain absent");
        assertEq(TokenPool(pool).getRemotePools(104).length, 2);
        (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound) =
            TokenPool(pool).getCurrentRateLimiterState(104, false);
        assertEq(outbound.capacity, 1200);
        assertEq(inbound.capacity, 2200);
        address shared = HubLockBoxes(pool).getLockBox(102);
        assertEq(shared, HubLockBoxes(pool).getLockBox(103));
        assertNotEq(shared, HubLockBoxes(pool).getLockBox(104));
        assertEq(TokenPool(pool).owner(), vm.parseJsonAddress(record, ".deployed.timelock"));

        ILidoTimelock timelock = ILidoTimelock(vm.parseJsonAddress(record, ".deployed.timelock"));
        vm.startPrank(vm.addr(2));
        timelock.grantRole(timelock.ADMIN_ROLE(), address(15));
        timelock.renounceRole(timelock.ADMIN_ROLE(), vm.addr(2));
        vm.stopPrank();
        vm.setEnv("LANE", "base");
        PrepareHubLane prepare = new PrepareHubLane();
        prepare.setUp();
        prepare.run();
        string memory ownership = vm.readFile(string.concat(RUN, "lane-preparation.json"));
        ILidoTimelock.Call[] memory accepts = new ILidoTimelock.Call[](3);
        for (uint256 i; i < 3; ++i) {
            string memory key = string.concat(".calls[", vm.toString(i), "]");
            accepts[i] = ILidoTimelock.Call(
                vm.parseJsonAddress(ownership, string.concat(key, ".target")),
                0,
                vm.parseJsonBytes(ownership, string.concat(key, ".data"))
            );
        }
        vm.prank(address(15));
        timelock.bypasserExecuteBatch(accepts);
        vm.setEnv("PROPOSAL_OUT", string.concat(RUN, "proposal.json"));
        vm.setEnv("WSTETH_RUN_ID", "unit-probe");
        vm.setEnv("HUB_INPUTS_HASH", "fixture");
        bytes32 beforeRecord = keccak256(bytes(vm.readFile(CFG)));
        BuildHubLaneProposal builder = new BuildHubLaneProposal();
        builder.setUp();
        builder.run();
        assertEq(keccak256(bytes(vm.readFile(CFG))), beforeRecord, "Builder must not change records");
        assertFalse(TokenPool(pool).isSupportedChain(105), "Writing a proposal must not connect Base");
        string memory proposal = vm.readFile(string.concat(RUN, "proposal.json"));
        assertEq(vm.parseJsonUint(proposal, ".chainId"), 1);
        assertEq(vm.parseJsonAddress(proposal, ".hub"), pool);
        assertTrue(vm.keyExistsJson(proposal, ".calls[5]"));
        assertFalse(vm.keyExistsJson(proposal, ".calls[6]"));
    }
}

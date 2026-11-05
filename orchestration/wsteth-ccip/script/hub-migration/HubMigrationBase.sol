// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// The stock parser supplies standard records/defaults; only migration metadata lives here.
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/ccvs/VersionedVerifierResolver.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/ccvs/components/BaseVerifier.sol";
import {IAdvancedPoolHooks} from "@chainlink/contracts-ccip/interfaces/IAdvancedPoolHooks.sol";
import {IPoolV2} from "@chainlink/contracts-ccip/interfaces/IPoolV2.sol";
import {IRouter} from "@chainlink/contracts-ccip/interfaces/IRouter.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/pools/AdvancedPoolHooks.sol";
import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";
import {Ownable2Step} from "@chainlink/contracts/src/v0.8/shared/access/Ownable2Step.sol";
import {console} from "forge-std/console.sol";

import {ConfigParser} from "@ccip-lido/script/lib/ConfigParser.sol";
import {ISiloedLockReleaseTokenPool} from "@ccip-lido/script/lib/ISiloedLockReleaseTokenPool.sol";

import {PausableAdvancedPoolHooks} from "@ccip-lido/PausableAdvancedPoolHooks.sol";

import {DummyMessageIdVerifier} from "@ccip-lido/ccvs/DummyMessageIdVerifier.sol";
import {ILidoTimelock} from "@ccip-lido/interfaces/ILidoTimelock.sol";

import {IERC20Metadata} from "@openzeppelin/contracts@5.3.0/token/ERC20/extensions/IERC20Metadata.sol";

abstract contract HubMigrationBase is ConfigParser {
    error InvalidImportedLane(string path, string remoteChainName, string reason);
    error InvalidDeferredLane(string path, string remoteChainName, string reason);
    error ImportedLaneRemotePoolMismatch(string remoteChainName, address recordPool);
    error NoLockBoxForLane(string remoteChainName);
    error MissingCCVDeployment(address verifier, address resolver);

    struct ImportedLane {
        bool present;
        address[] remote_pools;
        RateLimiterConfig outbound;
        RateLimiterConfig inbound;
    }
    mapping(string => ImportedLane) internal s_importedLanes;
    mapping(string => bool) internal s_deferredLanes;
    mapping(string => RemoteChainData) internal s_remoteData;
    string internal s_chainConfigPath;
    string internal s_manifest;
    uint256 internal s_deployerPrivateKey;
    address internal s_deployer;
    string internal s_artifactDeployments;
    uint32 internal constant DUMMY_MESSAGE_ID_GAS_FOR_VERIFICATION = 1;
    uint16 internal constant DUMMY_MESSAGE_ID_PAYLOAD_SIZE_BYTES = 36;
    uint32 internal constant STOCK_SOURCE_POOL_DATA_LENGTH = 32;

    function _loadMigration(bool deployed, bool resolveDeferred) internal {
        require(!vm.envExists("HUB_MIGRATION_ONLY"), "Obsolete HUB_MIGRATION_ONLY is forbidden");
        _loadMigrationInputs(
            vm.envString("CHAIN_CONFIG"),
            vm.envString("HUB_MANIFEST"),
            vm.envString("DEFAULT_CONFIG"),
            vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(1)),
            deployed,
            resolveDeferred
        );
    }

    function _loadMigrationInputs(
        string memory chainPath,
        string memory manifestPath,
        string memory defaultsPath,
        uint256 deployerKey,
        bool deployed,
        bool resolveDeferred
    ) internal {
        s_chainConfigPath = chainPath;
        s_deployerPrivateKey = deployerKey;
        s_deployer = vm.addr(s_deployerPrivateKey);
        _loadDefaultConfig(defaultsPath);
        _loadChainConfig(s_chainConfigPath);
        require(block.chainid == s_chainConfig.chain.chain_id, "Chain ID mismatch");
        require(s_chainConfig.chain.pool_type == PoolType.SiloedLockRelease, "Expected lock/release hub");
        require(!s_tokenDeployedByScripts, "Migration requires the existing token");
        string memory json = vm.readFile(s_chainConfigPath);
        _loadImportedLanes(s_chainConfigPath, json);
        _loadDeferredLanes(s_chainConfigPath, json);
        _loadCCIPAddresses(s_chainConfigPath);
        for (uint256 i; i < s_chainConfig.remote_lanes.length; ++i) {
            string memory name = s_chainConfig.remote_lanes[i].remote_chain_name;
            require(s_importedLanes[name].present || _isDeferredLane(name), "Unclassified migration lane");
            for (uint256 j; j < i; ++j) {
                require(
                    keccak256(bytes(name)) != keccak256(bytes(s_chainConfig.remote_lanes[j].remote_chain_name)),
                    "Duplicate lane"
                );
            }
            if (resolveDeferred || !_isDeferredLane(name)) {
                s_remoteData[name] =
                    _loadRemoteChainData(string.concat(_getDirectory(s_chainConfigPath), "/", name, ".json"));
            }
        }
        s_manifest = vm.readFile(manifestPath);
        _validateManifest();
        if (deployed) {
            _loadDeployedAddresses(s_chainConfigPath);
            _loadCCVDeployment(s_chainConfigPath);
        }
    }

    function _validateManifest() internal view {
        require(vm.parseJsonUint(s_manifest, ".readAt.chainId") == block.chainid, "Manifest chain mismatch");
        require(vm.parseJsonAddress(s_manifest, ".token") == s_chainConfig.addresses.token, "Manifest token mismatch");
        require(
            vm.parseJsonAddress(s_manifest, ".registry.address") == s_ccip.token_admin_registry, "Manifest TAR mismatch"
        );
        uint256 count;
        while (vm.keyExistsJson(s_manifest, string.concat(".lanes[", vm.toString(count), "]"))) ++count;
        require(count > 0 && count == _lanesConfiguredHere(), "Manifest lane set mismatch");
        for (uint256 i; i < count; ++i) {
            string memory key = string.concat(".lanes[", vm.toString(i), "]");
            string memory name = vm.parseJsonString(s_manifest, string.concat(key, ".slug"));
            require(s_importedLanes[name].present, "Manifest lane not imported");
            for (uint256 j; j < i; ++j) {
                require(
                    keccak256(bytes(name))
                        != keccak256(
                            bytes(vm.parseJsonString(s_manifest, string.concat(".lanes[", vm.toString(j), "].slug")))
                        ),
                    "Duplicate manifest lane"
                );
            }
            RemoteChainData memory remote = s_remoteData[name];
            require(
                vm.parseUint(vm.parseJsonString(s_manifest, string.concat(key, ".selector")))
                    == remote.ccip.chain_selector,
                "Manifest selector mismatch"
            );
            require(
                vm.parseJsonAddress(s_manifest, string.concat(key, ".remoteToken")) == remote.token,
                "Manifest remote token mismatch"
            );
            address[] memory pools = vm.parseJsonAddressArray(s_manifest, string.concat(key, ".remotePools"));
            require(
                keccak256(abi.encode(pools)) == keccak256(abi.encode(s_importedLanes[name].remote_pools)),
                "Manifest remote pools mismatch"
            );
            require(
                keccak256(abi.encode(_parseRateLimiterConfig(s_manifest, string.concat(key, ".outbound"))))
                    == keccak256(abi.encode(s_importedLanes[name].outbound)),
                "Manifest outbound mismatch"
            );
            require(
                keccak256(abi.encode(_parseRateLimiterConfig(s_manifest, string.concat(key, ".inbound"))))
                    == keccak256(abi.encode(s_importedLanes[name].inbound)),
                "Manifest inbound mismatch"
            );
            for (uint256 j; j < s_chainConfig.remote_lanes.length; ++j) {
                if (keccak256(bytes(name)) == keccak256(bytes(s_chainConfig.remote_lanes[j].remote_chain_name))) {
                    require(
                        vm.parseJsonBool(s_manifest, string.concat(key, ".siloed"))
                            == s_chainConfig.remote_lanes[j].is_siloed,
                        "Manifest custody mismatch"
                    );
                }
            }
            // Also checks that the standard remote record's pool belongs to the full imported set.
            _chainUpdateFor(name);
        }
    }

    function _requireCCVs() internal view {
        if (s_ccv.message_id_verifier == address(0) || s_ccv.verifier_resolver == address(0)) {
            revert MissingCCVDeployment(s_ccv.message_id_verifier, s_ccv.verifier_resolver);
        }
    }

    function _deployArtifact(string memory name, bytes memory args) internal returns (address result) {
        string memory path = string.concat(vm.envString("CCIP_ARTIFACTS"), "/", name, ".sol/", name, ".json");
        string memory artifact = vm.readFile(path);
        bytes memory bytecode = vm.parseJsonBytes(artifact, ".bytecode.object");
        require(bytecode.length > 0, "Empty component bytecode");
        bytes memory creation = abi.encodePacked(bytecode, args);
        assembly ("memory-safe") { result := create(0, add(creation, 32), mload(creation)) }
        require(result != address(0) && result.code.length > 0, "Component deployment failed");
        s_artifactDeployments = string.concat(
            s_artifactDeployments,
            bytes(s_artifactDeployments).length == 0 ? "" : ",",
            '{"contract":"',
            name,
            '","address":"',
            vm.toString(result),
            '","creationCodeHash":"',
            vm.toString(keccak256(bytecode)),
            '","constructorArgs":"',
            vm.toString(args),
            '"}'
        );
        _writeJsonUnlessDryRun(
            string.concat('{"deployments":[', s_artifactDeployments, "]}"), vm.envString("ARTIFACT_DEPLOYMENTS_OUT")
        );
    }

    function _deployLockBox() internal returns (address) {
        return _deployArtifact("ERC20LockBox", abi.encode(s_chainConfig.addresses.token));
    }

    function _deployCCVStack() internal {
        string[] memory locations = new string[](1);
        locations[0] = vm.envOr("STORAGE_LOCATION", string("dummy://message-id-verifier"));
        DummyMessageIdVerifier.DynamicConfig memory config = DummyMessageIdVerifier.DynamicConfig({
            feeAggregator: vm.envOr("FEE_AGGREGATOR", s_chainConfig.governance_addresses.lido_dao_agent),
            allowlistAdmin: vm.envOr("ALLOWLIST_ADMIN", address(0))
        });
        s_ccv.message_id_verifier = _deployArtifact(
            "DummyMessageIdVerifier", abi.encode(locations, config, vm.envOr("RMN_REMOTE", s_ccip.rmn_proxy))
        );
        s_ccv.verifier_resolver = _deployArtifact("VersionedVerifierResolver", "");
    }

    function _saveResults() internal {
        _saveCCIPAndDeployedAddresses(s_chainConfigPath, s_ccip, s_deployed, s_ccv);
    }

    function _loadDeferredLanes(string memory path, string memory json) internal {
        if (!vm.keyExistsJson(json, ".deferred_lanes")) return;
        string[] memory names = vm.parseJsonStringArray(json, ".deferred_lanes");
        for (uint256 i; i < names.length; i++) {
            string memory name = names[i];
            if (!_isRemoteLane(name)) revert InvalidDeferredLane(path, name, "not a remote lane");
            if (s_importedLanes[name].present) {
                revert InvalidDeferredLane(path, name, "an imported lane cannot be deferred");
            }
            if (s_deferredLanes[name]) revert InvalidDeferredLane(path, name, "listed twice");
            s_deferredLanes[name] = true;
        }
    }

    function _isDeferredLane(string memory name) internal view returns (bool) {
        return s_deferredLanes[name];
    }

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
            if (keccak256(bytes(s_chainConfig.remote_lanes[i].remote_chain_name)) == keccak256(bytes(name))) {
                return true;
            }
        }
        return false;
    }

    function _chainUpdateFor(string memory remoteName) internal view returns (TokenPool.ChainUpdate memory) {
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

    function _feeConfigFor(string memory remoteName)
        internal
        view
        returns (TokenPool.TokenTransferFeeConfigArgs memory)
    {
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

    function _lockBoxConfigFor(string memory remoteName)
        internal
        view
        returns (ISiloedLockReleaseTokenPool.LockBoxConfig memory)
    {
        for (uint256 i; i < s_deployed.lock_boxes.length; i++) {
            if (keccak256(bytes(s_deployed.lock_boxes[i].remote_chain_name)) == keccak256(bytes(remoteName))) {
                return ISiloedLockReleaseTokenPool.LockBoxConfig({
                    remoteChainSelector: s_remoteData[remoteName].ccip.chain_selector,
                    lockBox: s_deployed.lock_boxes[i].lock_box
                });
            }
        }
        revert NoLockBoxForLane(remoteName);
    }

    function _ccvConfigFor(string memory remoteName) internal view returns (AdvancedPoolHooks.CCVConfigArg memory) {
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

    function _verifierRemoteConfigFor(string memory remoteName)
        internal
        view
        returns (BaseVerifier.RemoteChainConfigArgs memory)
    {
        return BaseVerifier.RemoteChainConfigArgs({
            router: IRouter(s_ccip.router),
            remoteChainSelector: s_remoteData[remoteName].ccip.chain_selector,
            allowlistEnabled: false,
            feeUSDCents: 0,
            gasForVerification: DUMMY_MESSAGE_ID_GAS_FOR_VERIFICATION,
            payloadSizeBytes: DUMMY_MESSAGE_ID_PAYLOAD_SIZE_BYTES
        });
    }

    function _resolverOutboundFor(string memory remoteName)
        internal
        view
        returns (VersionedVerifierResolver.OutboundImplementationArgs memory)
    {
        return VersionedVerifierResolver.OutboundImplementationArgs({
            destChainSelector: s_remoteData[remoteName].ccip.chain_selector, verifier: s_ccv.message_id_verifier
        });
    }

    function _lanesConfiguredHere() internal view returns (uint256 count) {
        for (uint256 i; i < s_chainConfig.remote_lanes.length; i++) {
            if (!_isDeferredLane(s_chainConfig.remote_lanes[i].remote_chain_name)) count++;
        }
    }
}

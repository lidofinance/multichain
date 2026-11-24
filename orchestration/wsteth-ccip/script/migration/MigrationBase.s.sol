// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/// @dev The deployed OssifiableProxy behind the Base wstETH and both legacy bridges.
interface IOssifiableProxy {
    function proxy__getAdmin() external view returns (address);
    function proxy__getImplementation() external view returns (address);
    function proxy__upgradeTo(address newImplementation) external;
    function proxy__upgradeToAndCall(address newImplementation, bytes memory data, bool forceCall) external;
}

/// @dev Bedrock cross-domain messenger surface used on both sides.
interface ICrossDomainMessengerLike {
    function messageNonce() external view returns (uint256);
    function sendMessage(address target, bytes calldata message, uint32 minGasLimit) external payable;
    function OTHER_MESSENGER() external view returns (address);
    function successfulMessages(bytes32 hash) external view returns (bool);
}

/// @dev The Base OptimismBridgeExecutor (governance-crosschain-bridges), pinned at 0.8.10 upstream,
///      so it is declared here instead of imported.
interface IBridgeExecutorLike {
    function getActionsSetCount() external view returns (uint256);
    function getCurrentState(uint256 actionsSetId) external view returns (uint8);
    function getDelay() external view returns (uint256);
    function getEthereumGovernanceExecutor() external view returns (address);
}

interface ITokenAdminRegistryLike {
    struct TokenConfig {
        address administrator;
        address pendingAdministrator;
        address tokenPool;
    }

    function getTokenConfig(address token) external view returns (TokenConfig memory);
    function transferAdminRole(address token, address newAdmin) external;
}

interface IAccessControlLike {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IERC20MetadataLike {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface ILegacyBridgeLike {
    function messenger() external view returns (address);
    function l1Token() external view returns (address);
    function l2Token() external view returns (address);
}

interface IL1BridgeLike is ILegacyBridgeLike {
    function l2TokenBridge() external view returns (address);
}

interface IL2BridgeLike is ILegacyBridgeLike {
    function l1TokenBridge() external view returns (address);
}

/// @dev The migration schedule and mode of an upgraded bridge (CCIPMigrationSender).
interface IMigrationBridgeLike {
    function getBridgeMode() external view returns (uint8);
    function getActivationTime() external view returns (uint256);
    function getCloseTime() external view returns (uint256);
    function isActivated() external view returns (bool);
    function isClosed() external view returns (bool);
    function isInitialized() external view returns (bool);
    function isDepositsEnabled() external view returns (bool);
    function isWithdrawalsEnabled() external view returns (bool);
    function ccipTokenAdminRegistry() external view returns (address);
    function ccipTokenPool() external view returns (address);
    function ccipLockBox() external view returns (address);
    function scheduleActivation(uint256 activateAt) external;
    function scheduleClose(uint256 closeAt) external;
}

/// @dev The Lido timelock's admin bypass and the lane lockbox's caller list.
interface ILidoTimelockLike {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    function ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function bypasserExecuteBatch(Call[] calldata calls) external payable;
}

interface ILockBoxLike {
    struct AuthorizedCallerArgs {
        address[] addedCallers;
        address[] removedCallers;
    }

    function applyAuthorizedCallerUpdates(AuthorizedCallerArgs calldata args) external;
    function getAllAuthorizedCallers() external view returns (address[] memory);
}

/// @notice Shared inputs and the governance payload builder for the in-place migration scripts.
///         Everything that reaches a chain is built from the run's records (config/chains/*.json,
///         state/*.json), never from literals, and the executor action set is built by ONE
///         function so the L1 sender and the L2 relay cannot drift apart.
abstract contract MigrationBase is Script {
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
    /// @dev Gas the Agent's governance message asks the Base messenger to forward to the executor.
    uint32 internal constant GOVERNANCE_MESSAGE_GAS = 3_000_000;

    string internal l1Cfg;
    string internal l2Cfg;
    string internal l1State;
    string internal l2State;

    /// @dev The Base part of the one vote (action set A′), atomic: token upgrade + finalization,
    ///      roles for the legacy bridge and the CCIP pool, bridge upgrade, CCIP registry
    ///      registration through the token's DEFAULT_ADMIN_ROLE holder (the executor itself),
    ///      pool binding, hand-over of the registry administration to the Base timelock and its
    ///      acceptance through the timelock's admin bypass (the executor is the timelock admin),
    ///      and the two migration timers on the upgraded bridge.
    struct ActionSetA {
        address token;
        address tokenImplementation;
        address bridge;
        address bridgeImplementation;
        address pool;
        address hooks;
        address registryModule;
        address registry;
        address timelock;
        address executor;
        string tokenVersion;
        uint256 activateAt;
        uint256 closeAt;
    }

    struct LockBoxEntry {
        address lock_box;
        string remote_chain_name;
    }

    function _load() internal {
        l1Cfg = vm.readFile(vm.envString("L1_CFG"));
        l2Cfg = vm.readFile(vm.envString("L2_CFG"));
        l1State = vm.readFile(vm.envString("L1_STATE"));
        l2State = vm.readFile(vm.envString("L2_STATE"));
    }

    function _addr(string memory json, string memory key) internal pure returns (address) {
        return vm.parseJsonAddress(json, key);
    }

    function _selector(string memory json) internal pure returns (uint64) {
        return uint64(vm.parseJsonUint(json, ".ccip.chain_selector"));
    }

    /// @dev The L1 lockbox of the lane to `remoteChain` (one per lane in the hub record).
    function _lockBox(string memory cfg, string memory remoteChain) internal pure returns (address result) {
        LockBoxEntry[] memory entries = abi.decode(vm.parseJson(cfg, ".deployed.lock_boxes"), (LockBoxEntry[]));
        for (uint256 i; i < entries.length; ++i) {
            if (keccak256(bytes(entries[i].remote_chain_name)) == keccak256(bytes(remoteChain))) {
                require(result == address(0), "duplicate lockbox lane");
                result = entries[i].lock_box;
            }
        }
        require(result != address(0), "missing lane lockbox in the L1 record");
    }

    /// @dev Creation code of a component artifact (built by that component's own foundry.toml, so
    ///      the rehearsal deploys the bytes the component build produces) plus constructor args.
    function _creation(string memory artifactPath, bytes memory constructorArgs) internal view returns (bytes memory) {
        string memory artifact = vm.readFile(artifactPath);
        return abi.encodePacked(vm.parseJsonBytes(artifact, ".bytecode.object"), constructorArgs);
    }

    function _deploy(bytes memory creation) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(creation, 32), mload(creation))
        }
        require(deployed != address(0), "deployment failed");
    }

    function _actionSetA(ActionSetA memory a) internal pure returns (bytes memory queueCalldata) {
        uint256 n = 13;
        address[] memory targets = new address[](n);
        uint256[] memory values = new uint256[](n);
        string[] memory signatures = new string[](n);
        bytes[] memory calldatas = new bytes[](n);
        bool[] memory withDelegatecalls = new bool[](n);

        targets[0] = a.token;
        calldatas[0] = abi.encodeWithSignature(
            "proxy__upgradeToAndCall(address,bytes,bool)",
            a.tokenImplementation,
            abi.encodeWithSignature("finalizeUpgrade_v3(string,address)", a.tokenVersion, a.executor),
            false
        );
        targets[1] = a.token;
        calldatas[1] = abi.encodeWithSignature("grantRole(bytes32,address)", MINTER_ROLE, a.bridge);
        targets[2] = a.token;
        calldatas[2] = abi.encodeWithSignature("grantRole(bytes32,address)", BURNER_ROLE, a.bridge);
        targets[3] = a.token;
        calldatas[3] = abi.encodeWithSignature("grantRole(bytes32,address)", MINTER_ROLE, a.pool);
        targets[4] = a.token;
        calldatas[4] = abi.encodeWithSignature("grantRole(bytes32,address)", BURNER_ROLE, a.pool);
        targets[5] = a.bridge;
        calldatas[5] = abi.encodeWithSignature("proxy__upgradeTo(address)", a.bridgeImplementation);
        targets[6] = a.registryModule;
        calldatas[6] = abi.encodeWithSignature("registerAccessControlDefaultAdmin(address)", a.token);
        targets[7] = a.registry;
        calldatas[7] = abi.encodeWithSignature("acceptAdminRole(address)", a.token);
        targets[8] = a.registry;
        calldatas[8] = abi.encodeWithSignature("setPool(address,address)", a.token, a.pool);
        targets[9] = a.registry;
        calldatas[9] = abi.encodeWithSignature("transferAdminRole(address,address)", a.token, a.timelock);
        // The pool is already bound by item 9. Accept administration and install the send gate.
        ILidoTimelockLike.Call[] memory accept = new ILidoTimelockLike.Call[](2);
        accept[0] = ILidoTimelockLike.Call(a.registry, 0, abi.encodeWithSignature("acceptAdminRole(address)", a.token));
        // Atomic with roles and pool registration: every outbound Router send is
        // gated by the bridge's authenticated L1 confirmation + activation state.
        accept[1] = ILidoTimelockLike.Call(a.hooks, 0, abi.encodeWithSignature("setPolicyEngine(address)", a.bridge));
        targets[10] = a.timelock;
        calldatas[10] = abi.encodeWithSignature("bypasserExecuteBatch((address,uint256,bytes)[])", accept);
        targets[11] = a.bridge;
        calldatas[11] = abi.encodeWithSignature("scheduleActivation(uint256)", a.activateAt);
        targets[12] = a.bridge;
        calldatas[12] = abi.encodeWithSignature("scheduleClose(uint256)", a.closeAt);

        queueCalldata = abi.encodeWithSignature(
            "queue(address[],uint256[],string[],bytes[],bool[])", targets, values, signatures, calldatas, withDelegatecalls
        );
    }

    /// @dev The action set inputs, read identically by the L1 sender and the L2 verifier.
    function _actionSetAInputs(string memory l2Deploy) internal view returns (ActionSetA memory a) {
        a.token = _addr(l2Cfg, ".addresses.token");
        a.tokenImplementation = _addr(l2Deploy, ".l2TokenImplementation");
        a.bridge = _addr(l2State, ".legacyBridge");
        a.bridgeImplementation = _addr(l2Deploy, ".l2BridgeImplementation");
        a.pool = _addr(l2Cfg, ".deployed.token_pool");
        a.hooks = _addr(l2Cfg, ".deployed.advanced_pool_hooks");
        a.registryModule = _addr(l2Cfg, ".ccip.registry_module_owner");
        a.registry = _addr(l2Cfg, ".ccip.token_admin_registry");
        a.timelock = _addr(l2Cfg, ".deployed.timelock");
        a.executor = _addr(l2State, ".opExec");
        a.tokenVersion = vm.parseJsonString(l2Deploy, ".tokenVersion");
        a.activateAt = vm.envUint("ACTIVATE_L2_AT");
        a.closeAt = vm.envUint("CLOSE_AT");
    }
}

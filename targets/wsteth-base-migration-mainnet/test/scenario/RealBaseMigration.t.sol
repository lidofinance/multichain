// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pool} from "@chainlink/contracts-ccip/libraries/Pool.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";

interface IMigrationBridge {
    function getBridgeMode() external view returns (uint8);
    function requireBridgeMode(uint8 expected) external view;
    function switchBridgeMode(uint8 newMode) external;
    function getActivationTime() external view returns (uint256);
    function getCloseTime() external view returns (uint256);
    function isActivated() external view returns (bool);
    function isClosed() external view returns (bool);
    function isL1ActivationConfirmed() external view returns (bool);
    function activate() external;
    function close() external;
    function ccipTokenPool() external view returns (address);
    function ccipTokenAdminRegistry() external view returns (address);
    function ccipLockBox() external view returns (address);
    function getCCIPFee(address to, uint256 amount) external view returns (uint256);
    function depositERC20(address l1Token, address l2Token, uint256 amount, uint32 l2Gas, bytes calldata data)
        external
        payable;
    function depositERC20To(
        address l1Token,
        address l2Token,
        address to,
        uint256 amount,
        uint32 l2Gas,
        bytes calldata data
    ) external payable;
    function withdraw(address l2Token, uint256 amount, uint32 l1Gas, bytes calldata data) external payable;
    function withdrawTo(address l2Token, address to, uint256 amount, uint32 l1Gas, bytes calldata data)
        external
        payable;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function isDepositsEnabled() external view returns (bool);
    function isWithdrawalsEnabled() external view returns (bool);
    function enableDeposits() external;
    function disableDeposits() external;
    function enableWithdrawals() external;
    function disableWithdrawals() external;
}

interface IMessengerLike {
    function relayMessage(
        uint256 nonce,
        address sender,
        address target,
        uint256 value,
        uint256 minGasLimit,
        bytes calldata message
    ) external payable;
    function sendMessage(address target, bytes calldata message, uint32 minGasLimit) external payable;
    function successfulMessages(bytes32 hash) external view returns (bool);
    function failedMessages(bytes32 hash) external view returns (bool);
    function OTHER_MESSENGER() external view returns (address);
}

interface IExecutorLike {
    function execute(uint256 actionsSetId) external payable;
    function getActionsSetCount() external view returns (uint256);
    function getCurrentState(uint256 actionsSetId) external view returns (uint8);
}

interface IRouterLike {
    struct OffRamp {
        uint64 sourceChainSelector;
        address offRamp;
    }

    function getOffRamps() external view returns (OffRamp[] memory);
    function getOnRamp(uint64 destChainSelector) external view returns (address);
}

interface IPoolLike {
    function getRemotePools(uint64 remoteChainSelector) external view returns (bytes[] memory);
    function releaseOrMint(Pool.ReleaseOrMintInV1 calldata input) external returns (Pool.ReleaseOrMintOutV1 memory);
    function owner() external view returns (address);
}

interface ITokenLike is IERC20 {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getContractVersion() external view returns (uint256);
}

interface ITarLike {
    struct TokenConfig {
        address administrator;
        address pendingAdministrator;
        address tokenPool;
    }

    function getTokenConfig(address token) external view returns (TokenConfig memory);
    function getPool(address token) external view returns (address);
}

interface ITimelockLike {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    function ADMIN_ROLE() external view returns (bytes32);
    function PROPOSER_ROLE() external view returns (bytes32);
    function PROPOSAL_QUEUE_HALT_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);
    function getMinDelay() external view returns (uint256);
    function scheduleBatch(Call[] calldata calls, bytes32 predecessor, bytes32 salt, uint256 delay) external;
    function executeBatch(Call[] calldata calls, bytes32 predecessor, bytes32 salt) external payable;
    function hashOperationBatch(Call[] calldata calls, bytes32 predecessor, bytes32 salt)
        external
        pure
        returns (bytes32);
    function isOperationReady(bytes32 id) external view returns (bool);
    function isOperationPending(bytes32 id) external view returns (bool);
    function haltProposalQueue() external;
    function restartProposalQueue() external;
    function isProposalQueueHalted() external view returns (bool);
    function getEpoch() external view returns (uint248);
    function bypasserExecuteBatch(Call[] calldata calls) external payable;
}

interface IHooksLike {
    function getPolicyEngine() external view returns (address);
    function pauseCrossChainTransfers() external;
    function unpauseCrossChainTransfers() external;
    function paused() external view returns (bool);
    function owner() external view returns (address);
}

interface ILockBoxLike {
    struct AuthorizedCallerArgs {
        address[] addedCallers;
        address[] removedCallers;
    }

    function applyAuthorizedCallerUpdates(AuthorizedCallerArgs calldata args) external;
    function withdraw(address token, uint64 remoteChainSelector, uint256 amount, address recipient) external;
    function getAllAuthorizedCallers() external view returns (address[] memory);
}

/// @title RealBaseMigration — the one-vote Base migration runbook on forks of Ethereum and Base.
/// @notice Starts where the pipeline left the forks (steps 01m–05, the hub steps 01h, 05h and 05c
/// when the target declares the hub migration, step 07 and the vote of step 06 at T_vote_L1: lane deployed
/// and handed to the Lido timelocks, the three proxies upgraded, both bridges on the new code in
/// LEGACY with their two timers armed, the L1 bridge authorized on the lane lockbox).
/// Then walks the time-gated, permissionless steps in order — `activate()` on L1 at T_activate_L1,
/// `activate()` on Base at T_activate_L2, the operators' sweep, `close()` on both chains at T_close_L1L2 — with
/// legacy transfers of every kind in flight across every switch, CCIP transport in both directions,
/// the Emergency Brakes veto at each gate, the late-message hazard after the close with its
/// rollback, the lockbox hygiene, and the timelock levers. Every conservation check also asserts
/// that the hub's other lockboxes (the lanes the hub migration imported) keep their balances.
///
/// Transfer kinds in flight (started in LEGACY, the only mode that can start one) and where each
/// one finalizes:
///   D1, W1   started on the OLD implementations (step 06), finalize on the new ones at T_vote_L1
///   d0, w0   round trip inside the checkpoint (both LEGACY)
///   d2       finalizes on Base (LEGACY) after L1 activated
///   d4       finalizes on Base (MIGRATING) after Base activated
///   d3       first relay fails (gas-starved), replayed by the operators during the sweep
///   w2       finalizes on L1 (MIGRATING, paid from the lockbox) after L1 activated
///   w3       started after L1 activated (Base still LEGACY); first L1 relay fails, replayed in
///            the sweep after Base activated
///   dLate    held back past the close: fails at the Base messenger, replayed after rollback B
///   wLate    held back past the close: fails at the L1 messenger, replayed after rollback C
///   CCIP     deposit after L1 activated (Base still LEGACY), withdrawal after Base activated,
///            both again after the close
///
/// Transport is simulated at the messenger and pool boundaries: an L1→L2 governance or deposit
/// message is relayed through the REAL Base messenger from the aliased L1 messenger (the exact entry
/// the OP relayer uses); an L2→L1 message is relayed through the REAL L1 messenger with the portal's
/// `l2Sender` mocked (skipping the dispute game and the proof maturity delay); a CCIP send goes through the REAL Router and
/// OnRamp, and its delivery is the REAL destination OffRamp's `releaseOrMint` call on our pool,
/// impersonated. The Emergency Brakes multisigs are impersonated. No DON and no OP proof system run.
contract RealBaseMigrationTest is Test {
    uint8 internal constant LEGACY = 0;
    uint8 internal constant MIGRATING = 1;
    uint8 internal constant CCIP_ONLY = 2;
    uint8 internal constant ACTION_SET_EXECUTED = 1;
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant SENT_MESSAGE = keccak256("SentMessage(address,address,bytes,uint256,uint256)");
    bytes4 internal constant MODE_NOT_ALLOWED = bytes4(keccak256("ErrorBridgeModeNotAllowed(uint8)"));
    bytes4 internal constant UNEXPECTED_MODE = bytes4(keccak256("ErrorUnexpectedBridgeMode(uint8,uint8)"));
    bytes4 internal constant INSUFFICIENT_FEE = bytes4(keccak256("ErrorInsufficientCCIPFee(uint256,uint256)"));
    bytes4 internal constant TOO_EARLY = bytes4(keccak256("ErrorTooEarly(uint256)"));
    bytes4 internal constant SENDS_DISABLED = bytes4(keccak256("ErrorSendsDisabled()"));
    bytes4 internal constant ALREADY_ACTIVATED = bytes4(keccak256("ErrorAlreadyActivated()"));
    bytes4 internal constant ALREADY_CLOSED = bytes4(keccak256("ErrorAlreadyClosed()"));
    bytes4 internal constant UNEXPECTED_POOL = bytes4(keccak256("ErrorUnexpectedTokenPool(address,address)"));
    uint32 internal constant LEGACY_GAS = 200_000;
    uint32 internal constant GOVERNANCE_GAS = 2_000_000;
    /// @dev Below the messenger's minimum for a 200k message: the relay is recorded as failed, not executed.
    uint256 internal constant STARVED_GAS = 150_000;

    struct Side {
        uint256 fork;
        string slug;
        address token;
        address bridge;
        address messenger;
        address router;
        address tar;
        address pool;
        address hooks;
        address timelock;
        address callProxy;
        address lockBox;
        address gov; // Aragon Agent on L1, the OptimismBridgeExecutor on L2
        address emergencyBrakes; // placeholder multisig holding the timelock / hooks roles (record)
        address bridgeBrakes; // the real Emergency Brakes multisig holding the legacy bridge disabler roles
        address chainlinkMcms;
        address deployer;
        uint64 selector;
        uint64 remoteSelector;
        address realOffRamp;
        bytes remotePool;
        uint256 activateAt;
        uint256 closeAt;
    }

    struct Sent {
        uint256 nonce;
        address sender;
        address target;
        uint256 gasLimit;
        bytes message;
    }

    Side internal l1;
    Side internal l2;
    address internal user;
    address internal recipient = makeAddr("base-migration-recipient");
    address internal stranger = makeAddr("base-migration-stranger");
    /// @dev Legacy amounts in flight (sent, not yet finalized); the conservation check accounts for them.
    uint256 internal inFlight;
    /// @dev escrow + lockbox − Base supply − inFlight at the start; conserved by every step below.
    int256 internal baseline;
    /// @dev The hub's other L1 lockboxes (the shared one and the siloed ones of the lanes the hub migration
    ///      imported; none on a hub that serves Base only) and their balances at the start. No Base step —
    ///      activation, legacy replay, rollback, close — may move them.
    address[] internal otherLockBoxes;
    uint256[] internal otherLockBoxBalances;
    Sent internal preUpgradeDeposit;
    Sent internal preUpgradeWithdrawal;
    Sent internal activationConfirmation;

    // ─────────────────────────────────────────────────────────────────────────
    // Set-up: forks, records, ramps, the state the pipeline left
    // ─────────────────────────────────────────────────────────────────────────

    // Create forks per test: Foundry can retain a fork's warped block environment across
    // tests that share forks created in setUp(), even though contract storage is isolated.
    function _setUpMigrationForks() internal {
        l1.slug = vm.envOr("L1_CHAIN", string("ethereum"));
        l2.slug = vm.envOr("L2_CHAIN", string("base"));
        l1.fork = _freshFork(_rpc(l1.slug, "L1_RPC"));
        l2.fork = _freshFork(_rpc(l2.slug, "L2_RPC"));
        string memory dir = vm.envOr("RECORD_DIR", string("config/chains"));
        string memory c1 = vm.readFile(string.concat(dir, "/", l1.slug, ".json"));
        string memory c2 = vm.readFile(string.concat(dir, "/", l2.slug, ".json"));
        string memory s1 = vm.readFile("state/l1.json");
        string memory s2 = vm.readFile(string.concat("state/", l2.slug, ".json"));
        string memory migration = vm.readFile("state/migration.json");
        _loadChain(l1, c1, s1, ".agent");
        _loadChain(l2, c2, s2, ".opExec");
        l1.lockBox = _lockBox(c1, l2.slug);
        l1.remoteSelector = l2.selector;
        l2.remoteSelector = l1.selector;
        user = vm.parseJsonAddress(migration, ".user");
        preUpgradeDeposit = _sentFromRecord(migration, ".inFlightDeposit", l2.bridge);
        preUpgradeWithdrawal = _sentFromRecord(migration, ".inFlightWithdrawal", l1.bridge);
        inFlight = vm.parseJsonUint(migration, ".inFlightDeposit.amount")
            + vm.parseJsonUint(migration, ".inFlightWithdrawal.amount");

        vm.selectFork(l1.fork);
        _resolveRamps(l1);
        vm.selectFork(l2.fork);
        _resolveRamps(l2);
        _assertPipelineEndState();
        _snapshotOtherLockBoxes(c1);
        baseline = _conservation();
    }

    function _freshFork(string memory url) internal returns (uint256 id) {
        // Read the owned Anvil head, not a previous scenario's warped Foundry environment.
        string memory head = vm.rpcJson(url, "eth_getBlockByNumber", '["latest",false]');
        id = vm.createSelectFork(url, vm.parseUint(vm.parseJsonString(head, ".number")));
        vm.warp(vm.parseUint(vm.parseJsonString(head, ".timestamp")));
    }

    function _rpc(string memory slug, string memory override_) internal view returns (string memory url) {
        url = vm.envOr(override_, string(""));
        if (bytes(url).length == 0) url = vm.envOr(string.concat("RPC_", _upper(slug)), string(""));
        require(bytes(url).length != 0, string.concat("set ", override_, " or RPC_", _upper(slug)));
    }

    function _upper(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] >= 0x61 && b[i] <= 0x7a) b[i] = bytes1(uint8(b[i]) - 32);
        }
        return string(b);
    }

    function _loadChain(Side storage c, string memory cfg, string memory state, string memory govKey) internal {
        c.token = vm.parseJsonAddress(cfg, ".addresses.token");
        c.router = vm.parseJsonAddress(cfg, ".ccip.router");
        c.tar = vm.parseJsonAddress(cfg, ".ccip.token_admin_registry");
        c.pool = vm.parseJsonAddress(cfg, ".deployed.token_pool");
        c.hooks = vm.parseJsonAddress(cfg, ".deployed.advanced_pool_hooks");
        c.timelock = vm.parseJsonAddress(cfg, ".deployed.timelock");
        c.callProxy = vm.parseJsonAddress(cfg, ".deployed.call_proxy");
        c.emergencyBrakes = vm.parseJsonAddress(cfg, ".governance_addresses.emergency_brakes");
        c.chainlinkMcms = vm.parseJsonAddress(cfg, ".governance_addresses.chainlink_mcms");
        c.deployer = vm.parseJsonAddress(cfg, ".governance_addresses.deployer");
        c.selector = uint64(vm.parseJsonUint(cfg, ".ccip.chain_selector"));
        c.bridge = vm.parseJsonAddress(state, ".legacyBridge");
        c.messenger = vm.parseJsonAddress(state, ".messenger");
        c.gov = vm.parseJsonAddress(state, govKey);
        c.bridgeBrakes = vm.parseJsonAddress(state, ".emergencyBrakes");
    }

    struct LockBoxEntry {
        address lock_box;
        string remote_chain_name;
    }

    function _lockBox(string memory cfg, string memory lane) internal pure returns (address result) {
        LockBoxEntry[] memory entries = abi.decode(vm.parseJson(cfg, ".deployed.lock_boxes"), (LockBoxEntry[]));
        for (uint256 i; i < entries.length; ++i) {
            if (keccak256(bytes(entries[i].remote_chain_name)) == keccak256(bytes(lane))) {
                require(result == address(0), "duplicate lockbox lane");
                result = entries[i].lock_box;
            }
        }
        require(result != address(0), "missing lane lockbox");
    }

    /// @dev Distinct L1 lockboxes of the hub record other than this lane's, with their balances now.
    function _snapshotOtherLockBoxes(string memory cfg) internal {
        LockBoxEntry[] memory entries = abi.decode(vm.parseJson(cfg, ".deployed.lock_boxes"), (LockBoxEntry[]));
        vm.selectFork(l1.fork);
        for (uint256 i; i < entries.length; ++i) {
            address box = entries[i].lock_box;
            if (box == l1.lockBox) continue;
            bool seen;
            for (uint256 j; j < otherLockBoxes.length; ++j) {
                if (otherLockBoxes[j] == box) seen = true;
            }
            if (seen) continue;
            otherLockBoxes.push(box);
            otherLockBoxBalances.push(IERC20(l1.token).balanceOf(box));
        }
    }

    function _sentFromRecord(string memory json, string memory key, address target)
        internal
        pure
        returns (Sent memory s)
    {
        s.nonce = vm.parseJsonUint(json, string.concat(key, ".nonce"));
        s.gasLimit = vm.parseJsonUint(json, string.concat(key, ".gasLimit"));
        s.sender = vm.parseJsonAddress(json, string.concat(key, ".sender"));
        s.message = vm.parseJsonBytes(json, string.concat(key, ".message"));
        s.target = target;
    }

    function _resolveRamps(Side storage c) internal {
        IRouterLike.OffRamp[] memory offRamps = IRouterLike(c.router).getOffRamps();
        for (uint256 i = 0; i < offRamps.length; i++) {
            if (offRamps[i].sourceChainSelector == c.remoteSelector) c.realOffRamp = offRamps[i].offRamp;
        }
        require(c.realOffRamp != address(0), "no OffRamp for the lane on the router");
        bytes[] memory remotes = IPoolLike(c.pool).getRemotePools(c.remoteSelector);
        require(remotes.length > 0, "no remote pool configured for the lane");
        c.remotePool = remotes[0];
    }

    /// @dev What steps 01m–07 and the vote (06) must have left on the forks before the runbook continues.
    function _assertPipelineEndState() internal {
        vm.selectFork(l1.fork);
        _assertLaneHandedOver(l1);
        _assertArmed(l1);
        assertTrue(IMigrationBridge(l1.bridge).hasRole(0x00, l1.gov), "Agent lost the L1 bridge admin role");
        assertEq(IMigrationBridge(l1.bridge).ccipLockBox(), l1.lockBox, "L1 bridge lockbox");
        assertTrue(_authorizedOnLockBox(l1.bridge), "L1 bridge not authorized on the lane lockbox");
        assertGt(_escrow(), 0, "the escrow is empty before activation");
        vm.selectFork(l2.fork);
        _assertLaneHandedOver(l2);
        _assertArmed(l2);
        assertEq(ITokenLike(l2.token).getContractVersion(), 3, "token contract version");
        assertTrue(ITokenLike(l2.token).hasRole(0x00, l2.gov), "executor is not the token admin");
        assertTrue(ITokenLike(l2.token).hasRole(MINTER_ROLE, l2.bridge) && ITokenLike(l2.token).hasRole(BURNER_ROLE, l2.bridge), "bridge roles");
        assertTrue(ITokenLike(l2.token).hasRole(MINTER_ROLE, l2.pool) && ITokenLike(l2.token).hasRole(BURNER_ROLE, l2.pool), "pool roles");
        assertEq(IHooksLike(l2.hooks).getPolicyEngine(), l2.bridge, "Base outbound migration policy");
        assertLt(l1.activateAt, l2.activateAt, "Base must activate after L1");
        assertEq(l1.closeAt, l2.closeAt, "one close time on both chains");
    }

    function _assertArmed(Side storage c) internal {
        IMigrationBridge b = IMigrationBridge(c.bridge);
        assertEq(b.getBridgeMode(), LEGACY, string.concat(c.slug, ": bridge not in LEGACY"));
        c.activateAt = b.getActivationTime();
        c.closeAt = b.getCloseTime();
        assertGt(c.activateAt, vm.getBlockTimestamp(), string.concat(c.slug, ": activation not in the future"));
        assertGt(c.closeAt, c.activateAt, string.concat(c.slug, ": close not after activation"));
        assertFalse(b.isActivated() || b.isClosed(), string.concat(c.slug, ": already activated or closed"));
        assertEq(b.ccipTokenPool(), c.pool, string.concat(c.slug, ": bridge expects another pool"));
        assertEq(b.ccipTokenAdminRegistry(), c.tar, string.concat(c.slug, ": bridge reads another registry"));
        assertTrue(b.isDepositsEnabled() && b.isWithdrawalsEnabled(), string.concat(c.slug, ": bridge flags"));
    }

    function _assertLaneHandedOver(Side storage c) internal view {
        ITarLike.TokenConfig memory cfg = ITarLike(c.tar).getTokenConfig(c.token);
        assertEq(cfg.administrator, c.timelock, string.concat(c.slug, ": registry administrator is not the timelock"));
        assertEq(cfg.tokenPool, c.pool, string.concat(c.slug, ": registry pool"));
        bytes32 admin = ITimelockLike(c.timelock).ADMIN_ROLE();
        assertTrue(ITimelockLike(c.timelock).hasRole(admin, c.gov), string.concat(c.slug, ": DAO is not the timelock admin"));
        assertFalse(ITimelockLike(c.timelock).hasRole(admin, c.deployer), string.concat(c.slug, ": deployer still timelock admin"));
        assertEq(IPoolLike(c.pool).owner(), c.timelock, string.concat(c.slug, ": pool owner"));
        assertEq(IHooksLike(c.hooks).owner(), c.timelock, string.concat(c.slug, ": hooks owner"));
    }

    function _authorizedOnLockBox(address caller) internal view returns (bool) {
        address[] memory callers = ILockBoxLike(l1.lockBox).getAllAuthorizedCallers();
        for (uint256 i; i < callers.length; ++i) {
            if (callers[i] == caller) return true;
        }
        return false;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Conservation
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev escrow + lockbox − Base supply − legacy amounts in flight. Constant through the runbook.
    function _conservation() internal returns (int256) {
        vm.selectFork(l1.fork);
        uint256 backing = IERC20(l1.token).balanceOf(l1.bridge) + IERC20(l1.token).balanceOf(l1.lockBox);
        vm.selectFork(l2.fork);
        uint256 supply = IERC20(l2.token).totalSupply();
        return int256(backing) - int256(supply) - int256(inFlight);
    }

    /// @dev Also checks the hub's other lockboxes first, so the fork selected on return stays the L2 one.
    function _assertConserved(string memory where) internal {
        vm.selectFork(l1.fork);
        for (uint256 i; i < otherLockBoxes.length; ++i) {
            assertEq(
                IERC20(l1.token).balanceOf(otherLockBoxes[i]),
                otherLockBoxBalances[i],
                string.concat("another lane's lockbox moved: ", where)
            );
        }
        assertEq(_conservation(), baseline, string.concat("conservation broken: ", where));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // OP transport, at the messengers
    // ─────────────────────────────────────────────────────────────────────────

    function _alias(address l1Address) internal pure returns (address) {
        unchecked {
            return address(uint160(l1Address) + uint160(0x1111000000000000000000000000000000001111));
        }
    }

    function _messageHash(Sent memory s) internal pure returns (bytes32) {
        return keccak256(
            abi.encodeWithSignature(
                "relayMessage(uint256,address,address,uint256,uint256,bytes)",
                s.nonce,
                s.sender,
                s.target,
                uint256(0),
                s.gasLimit,
                s.message
            )
        );
    }

    /// @dev The last SentMessage the given messenger emitted since vm.recordLogs().
    function _lastSentMessage(address messenger) internal returns (Sent memory s) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter == messenger && log.topics.length > 1 && log.topics[0] == SENT_MESSAGE) {
                s.target = address(uint160(uint256(log.topics[1])));
                (s.sender, s.message, s.nonce, s.gasLimit) = abi.decode(log.data, (address, bytes, uint256, uint256));
                return s;
            }
        }
        revert("no SentMessage recorded");
    }

    /// @dev Relay an L1→L2 message exactly as the OP relayer does: the Base messenger accepts it from
    ///      the aliased L1 messenger and sets xDomainMessageSender to the L1 sender. `gas` below the
    ///      messenger's minimum makes it record the relay as failed (replayable), like a relayer
    ///      that under-provisioned the transaction.
    function _relayToL2(Sent memory s) internal returns (bool delivered) {
        return _relayToL2WithGas(s, s.gasLimit + 1_000_000);
    }

    function _relayToL2WithGas(Sent memory s, uint256 gas) internal returns (bool delivered) {
        vm.selectFork(l2.fork);
        bytes32 hash = _messageHash(s);
        IMessengerLike m = IMessengerLike(l2.messenger);
        // First delivery comes from the aliased L1 messenger; a message that already failed is
        // replayed by anyone (the messenger asserts the two paths apart).
        if (m.failedMessages(hash)) vm.prank(stranger);
        else vm.prank(_alias(l1.messenger));
        m.relayMessage{gas: gas}(s.nonce, s.sender, s.target, 0, s.gasLimit, s.message);
        delivered = m.successfulMessages(hash);
        if (!delivered) assertTrue(m.failedMessages(hash), "relay neither succeeded nor failed");
    }

    /// @dev Relay an L2→L1 message through the real L1 messenger. The portal's finalized-withdrawal
    ///      path (dispute game and proof maturity delay) is replaced by impersonating the portal with `l2Sender`
    ///      mocked to the Base messenger, which is what the messenger checks.
    function _relayToL1(Sent memory s) internal returns (bool delivered) {
        return _relayToL1WithGas(s, s.gasLimit + 1_000_000);
    }

    function _relayToL1WithGas(Sent memory s, uint256 gas) internal returns (bool delivered) {
        vm.selectFork(l1.fork);
        bytes32 hash = _messageHash(s);
        IMessengerLike m = IMessengerLike(l1.messenger);
        if (m.failedMessages(hash)) {
            // Replay of a failed message: anyone, no portal involved.
            vm.prank(stranger);
            m.relayMessage{gas: gas}(s.nonce, s.sender, s.target, 0, s.gasLimit, s.message);
        } else {
            address portal = _portal();
            vm.mockCall(portal, abi.encodeWithSignature("l2Sender()"), abi.encode(l2.messenger));
            vm.prank(portal);
            m.relayMessage{gas: gas}(s.nonce, s.sender, s.target, 0, s.gasLimit, s.message);
            vm.clearMockedCalls();
        }
        delivered = m.successfulMessages(hash);
        if (!delivered) assertTrue(m.failedMessages(hash), "relay neither succeeded nor failed");
    }

    function _portal() internal view returns (address) {
        (bool ok, bytes memory r) = l1.messenger.staticcall(abi.encodeWithSignature("portal()"));
        if (!ok || r.length < 32) (ok, r) = l1.messenger.staticcall(abi.encodeWithSignature("PORTAL()"));
        require(ok && r.length >= 32, "L1 messenger exposes no portal getter");
        return abi.decode(r, (address));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Governance: the Agent on L1, the executor on Base through the relayed message
    // ─────────────────────────────────────────────────────────────────────────

    function _agent(address target, bytes memory data) internal {
        vm.selectFork(l1.fork);
        vm.prank(l1.gov);
        (bool ok, bytes memory r) = target.call(data);
        require(ok, string.concat("Agent call failed: ", vm.toString(r)));
    }

    /// @dev One Base executor action set: the Agent sends the governance message on L1, it is relayed
    ///      through the Base messenger, the executor queues it under its own sender check, anyone
    ///      executes it (delay 0 on Base).
    function _executorActionSet(address[] memory targets, bytes[] memory calldatas) internal returns (uint256 id) {
        uint256 n = targets.length;
        bytes memory queueCalldata = abi.encodeWithSignature(
            "queue(address[],uint256[],string[],bytes[],bool[])",
            targets,
            new uint256[](n),
            new string[](n),
            calldatas,
            new bool[](n)
        );
        vm.selectFork(l1.fork);
        vm.recordLogs();
        vm.prank(l1.gov);
        IMessengerLike(l1.messenger).sendMessage(l2.gov, queueCalldata, GOVERNANCE_GAS);
        Sent memory s = _lastSentMessage(l1.messenger);
        vm.selectFork(l2.fork);
        id = IExecutorLike(l2.gov).getActionsSetCount();
        assertTrue(_relayToL2(s), "governance message not delivered");
        assertEq(IExecutorLike(l2.gov).getActionsSetCount(), id + 1, "action set not queued");
        vm.prank(stranger);
        IExecutorLike(l2.gov).execute(id);
        assertEq(IExecutorLike(l2.gov).getCurrentState(id), ACTION_SET_EXECUTED, "action set not executed");
    }

    function _single(address a, bytes memory da) internal pure returns (address[] memory targets, bytes[] memory calldatas) {
        targets = new address[](1);
        calldatas = new bytes[](1);
        (targets[0], calldatas[0]) = (a, da);
    }

    function _switchMode(uint8 mode) internal pure returns (bytes memory) {
        return abi.encodeCall(IMigrationBridge.switchBridgeMode, (mode));
    }

    function _role(string memory fn, bytes32 role, address who) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(string.concat(fn, "(bytes32,address)"), role, who);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Time and the permissionless steps
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Both forks at least at `t` (each keeps its own clock; neither goes backwards).
    function _warpTo(uint256 t) internal {
        vm.selectFork(l1.fork);
        if (vm.getBlockTimestamp() < t) vm.warp(t);
        vm.selectFork(l2.fork);
        if (vm.getBlockTimestamp() < t) vm.warp(t);
    }

    function _activate(Side storage c) internal {
        vm.selectFork(c.fork);
        if (c.fork == l1.fork) vm.recordLogs();
        vm.prank(stranger);
        IMigrationBridge(c.bridge).activate();
        if (c.fork == l1.fork) activationConfirmation = _lastSentMessage(l1.messenger);
        assertEq(IMigrationBridge(c.bridge).getBridgeMode(), MIGRATING, string.concat(c.slug, ": not MIGRATING"));
        assertTrue(IMigrationBridge(c.bridge).isActivated());
    }

    function _close(Side storage c) internal {
        vm.selectFork(c.fork);
        vm.prank(stranger);
        IMigrationBridge(c.bridge).close();
        assertEq(IMigrationBridge(c.bridge).getBridgeMode(), CCIP_ONLY, string.concat(c.slug, ": not CCIP_ONLY"));
        assertTrue(IMigrationBridge(c.bridge).isClosed());
    }

    function _expectStepRevert(Side storage c, bytes memory err, bool closeStep) internal {
        vm.selectFork(c.fork);
        if (bytes4(err) == TOO_EARLY) {
            assertLt(vm.getBlockTimestamp(), closeStep ? c.closeAt : c.activateAt, "test clock passed the expected timer");
        }
        vm.prank(stranger);
        vm.expectRevert(err);
        if (closeStep) IMigrationBridge(c.bridge).close();
        else IMigrationBridge(c.bridge).activate();
    }

    /// @dev The L1 Emergency Brakes switch deposits off; only the Agent switches them back on.
    function _l1Veto(bool on) internal {
        vm.selectFork(l1.fork);
        if (on) {
            vm.prank(l1.bridgeBrakes);
            IMigrationBridge(l1.bridge).disableDeposits();
        } else {
            _agent(l1.bridge, abi.encodeCall(IMigrationBridge.enableDeposits, ()));
        }
    }

    /// @dev The Base Emergency Brakes switch withdrawals off; only the executor (a vote) switches
    ///      them back on.
    function _l2Veto(bool on) internal {
        vm.selectFork(l2.fork);
        if (on) {
            vm.prank(l2.bridgeBrakes);
            IMigrationBridge(l2.bridge).disableWithdrawals();
        } else {
            (address[] memory t, bytes[] memory d) = _single(l2.bridge, abi.encodeCall(IMigrationBridge.enableWithdrawals, ()));
            _executorActionSet(t, d);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // User flows
    // ─────────────────────────────────────────────────────────────────────────

    function _legacyDeposit(uint256 amount) internal returns (Sent memory s) {
        vm.selectFork(l1.fork);
        vm.startPrank(user);
        IERC20(l1.token).approve(l1.bridge, amount);
        vm.recordLogs();
        IMigrationBridge(l1.bridge).depositERC20(l1.token, l2.token, amount, LEGACY_GAS, "");
        vm.stopPrank();
        s = _lastSentMessage(l1.messenger);
        inFlight += amount;
    }

    function _legacyWithdraw(uint256 amount) internal returns (Sent memory s) {
        vm.selectFork(l2.fork);
        vm.startPrank(user);
        IERC20(l2.token).approve(l2.bridge, amount);
        vm.recordLogs();
        IMigrationBridge(l2.bridge).withdraw(l2.token, amount, LEGACY_GAS, "");
        vm.stopPrank();
        s = _lastSentMessage(l2.messenger);
        inFlight += amount;
    }

    function _finalizeOnL2(Sent memory s, uint256 amount) internal {
        assertTrue(_relayToL2(s), "legacy deposit did not finalize on Base");
        inFlight -= amount;
    }

    function _finalizeOnL1(Sent memory s, uint256 amount) internal {
        assertTrue(_relayToL1(s), "legacy withdrawal did not finalize on L1");
        inFlight -= amount;
    }

    /// @dev Legacy sends are impossible outside LEGACY: the send path quotes a CCIP fee and a
    ///      zero-value call reverts on it. The quote is read before the prank; the bridge pulls the
    ///      tokens before it checks the fee, so the allowance is in place.
    function _assertLegacyDepositImpossible() internal {
        vm.selectFork(l1.fork);
        uint256 quote = IMigrationBridge(l1.bridge).getCCIPFee(user, 1e18);
        assertGt(quote, 0);
        vm.startPrank(user);
        IERC20(l1.token).approve(l1.bridge, 1e18);
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_FEE, quote, 0));
        IMigrationBridge(l1.bridge).depositERC20(l1.token, l2.token, 1e18, LEGACY_GAS, "");
        vm.stopPrank();
    }

    function _assertLegacyWithdrawalImpossible() internal {
        vm.selectFork(l2.fork);
        uint256 quote = IMigrationBridge(l2.bridge).getCCIPFee(user, 1e18);
        assertGt(quote, 0);
        vm.startPrank(user);
        IERC20(l2.token).approve(l2.bridge, 1e18);
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_FEE, quote, 0));
        IMigrationBridge(l2.bridge).withdraw(l2.token, 1e18, LEGACY_GAS, "");
        vm.stopPrank();
    }

    /// @dev Send through the real Router/OnRamp on the source chain, deliver on the destination as
    ///      the real OffRamp would: releaseOrMint on our pool.
    function _ccipDeliver(Side storage dst, address originalSender, address to, uint256 amount) internal {
        vm.selectFork(dst.fork);
        vm.prank(dst.realOffRamp);
        IPoolLike(dst.pool).releaseOrMint(
            Pool.ReleaseOrMintInV1({
                originalSender: abi.encode(originalSender),
                remoteChainSelector: dst.remoteSelector,
                receiver: to,
                sourceDenominatedAmount: amount,
                localToken: dst.token,
                sourcePoolAddress: dst.remotePool,
                sourcePoolData: "",
                offchainTokenData: ""
            })
        );
    }

    function _ccipDeposit(uint256 amount, address to) internal {
        vm.selectFork(l1.fork);
        uint256 fee = IMigrationBridge(l1.bridge).getCCIPFee(to, amount);
        assertGt(fee, 0, "CCIP quote is zero");
        vm.deal(user, fee * 2);
        uint256 lockBoxBefore = IERC20(l1.token).balanceOf(l1.lockBox);
        vm.startPrank(user);
        IERC20(l1.token).approve(l1.bridge, amount);
        IMigrationBridge(l1.bridge).depositERC20To{value: fee * 2}(l1.token, l2.token, to, amount, LEGACY_GAS, "");
        vm.stopPrank();
        assertEq(user.balance, fee, "excess fee not refunded");
        assertEq(IERC20(l1.token).balanceOf(l1.lockBox), lockBoxBefore + amount, "hub pool did not lock into the lane lockbox");
        vm.selectFork(l2.fork);
        uint256 toBefore = IERC20(l2.token).balanceOf(to);
        _ccipDeliver(l2, l1.bridge, to, amount);
        assertEq(IERC20(l2.token).balanceOf(to), toBefore + amount, "CCIP deposit not minted on Base");
    }

    function _ccipWithdraw(uint256 amount, address to) internal {
        vm.selectFork(l2.fork);
        uint256 fee = IMigrationBridge(l2.bridge).getCCIPFee(to, amount);
        assertGt(fee, 0, "CCIP quote is zero");
        vm.deal(user, fee * 2);
        uint256 supplyBefore = IERC20(l2.token).totalSupply();
        vm.startPrank(user);
        IERC20(l2.token).approve(l2.bridge, amount);
        IMigrationBridge(l2.bridge).withdrawTo{value: fee * 2}(l2.token, to, amount, LEGACY_GAS, "");
        vm.stopPrank();
        assertEq(user.balance, fee, "excess fee not refunded");
        assertEq(IERC20(l2.token).totalSupply(), supplyBefore - amount, "Base pool did not burn");
        vm.selectFork(l1.fork);
        uint256 toBefore = IERC20(l1.token).balanceOf(to);
        uint256 lockBoxBefore = IERC20(l1.token).balanceOf(l1.lockBox);
        _ccipDeliver(l1, l2.bridge, to, amount);
        assertEq(IERC20(l1.token).balanceOf(to), toBefore + amount, "CCIP withdrawal not released on L1");
        assertEq(IERC20(l1.token).balanceOf(l1.lockBox), lockBoxBefore - amount, "release did not come from the lane lockbox");
    }

    function _escrow() internal view returns (uint256) {
        return IERC20(l1.token).balanceOf(l1.bridge);
    }

    function _lockBoxBalance() internal view returns (uint256) {
        return IERC20(l1.token).balanceOf(l1.lockBox);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The runbook: T_vote_L1 → T_activate_L1 → T_activate_L2 → sweep → T_close_L1L2 → late messages
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A public Router caller must obey the same activation barrier as the bridge frontend.
    function _directCcipWithdrawal(bool allowed) internal {
        vm.selectFork(l2.fork);
        uint256 amount = 1e18;
        Client.EVMTokenAmount[] memory tokens = new Client.EVMTokenAmount[](1);
        tokens[0] = Client.EVMTokenAmount(l2.token, amount);
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(recipient),
            data: "",
            tokenAmounts: tokens,
            feeToken: address(0),
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 0, allowOutOfOrderExecution: true}))
        });
        uint256 fee = IRouterClient(l2.router).getFee(l2.remoteSelector, message);
        uint256 supply = IERC20(l2.token).totalSupply();
        uint256 balance = IERC20(l2.token).balanceOf(user);
        vm.deal(user, fee);
        vm.startPrank(user);
        IERC20(l2.token).approve(l2.router, amount);
        if (!allowed) vm.expectRevert(bytes4(keccak256("ErrorMigrationNotActivated()")));
        IRouterClient(l2.router).ccipSend{value: fee}(l2.remoteSelector, message);
        vm.stopPrank();
        assertEq(IERC20(l2.token).totalSupply(), allowed ? supply - amount : supply, "direct send supply");
        assertEq(IERC20(l2.token).balanceOf(user), allowed ? balance - amount : balance, "direct send balance");
        if (allowed) _ccipDeliver(l1, user, recipient, amount);
        _assertConserved("direct Router send");
    }

    function test_base_outbound_waits_for_l1_confirmation_and_activation() public {
        _setUpMigrationForks();
        _directCcipWithdrawal(false);
        _warpTo(l2.activateAt);
        _l1Veto(true);
        _expectStepRevert(l1, abi.encodeWithSelector(SENDS_DISABLED), false);
        bytes memory unconfirmed = abi.encodeWithSignature("ErrorL1ActivationNotConfirmed()");
        _expectStepRevert(l2, unconfirmed, false);
        _directCcipWithdrawal(false);

        _l1Veto(false);
        _activate(l1);
        assertEq(_escrow(), 0, "escrow not migrated");
        _expectStepRevert(l2, unconfirmed, false);
        _directCcipWithdrawal(false);

        assertFalse(_relayToL2WithGas(activationConfirmation, STARVED_GAS), "starved relay succeeded");
        _expectStepRevert(l2, unconfirmed, false);
        assertTrue(_relayToL2(activationConfirmation), "confirmation retry failed");
        assertTrue(IMigrationBridge(l2.bridge).isL1ActivationConfirmed());
        assertFalse(IMigrationBridge(l2.bridge).isActivated());
        _directCcipWithdrawal(false);
        _activate(l2);
        _directCcipWithdrawal(true);
    }

    function test_runbook_one_vote() public {
        _setUpMigrationForks();
        // ── Checkpoint, T_vote_L1 + minutes: both bridges on the new code in LEGACY ──────────
        // The pair started on the old implementations finalizes on the new ones.
        _finalizeOnL2(preUpgradeDeposit, preUpgradeDeposit_amount());
        _finalizeOnL1(preUpgradeWithdrawal, preUpgradeWithdrawal_amount());
        _assertConserved("after the pre-upgrade pair");

        // Nothing is activatable or closable yet: the timers have not elapsed.
        _expectStepRevert(l1, abi.encodeWithSelector(TOO_EARLY, l1.activateAt), false);
        _expectStepRevert(l2, abi.encodeWithSelector(TOO_EARLY, l2.activateAt), false);
        _expectStepRevert(l1, abi.encodeWithSelector(TOO_EARLY, l1.closeAt), true);
        _expectStepRevert(l2, abi.encodeWithSelector(TOO_EARLY, l2.closeAt), true);

        // Legacy transfers work both ways inside the checkpoint (d0, w0).
        _finalizeOnL2(_legacyDeposit(1e18), 1e18);
        _finalizeOnL1(_legacyWithdraw(1e18), 1e18);
        _assertConserved("after the checkpoint round trip");

        // Started while both sides are LEGACY, to finalize later at every stage.
        Sent memory d2 = _legacyDeposit(1e18);
        Sent memory d3 = _legacyDeposit(1e18);
        Sent memory d4 = _legacyDeposit(1e18);
        Sent memory w2 = _legacyWithdraw(1e18);
        Sent memory dLate = _legacyDeposit(1e18);
        Sent memory wLate = _legacyWithdraw(1e18);
        // d3's first delivery is gas-starved: the Base messenger records it as failed, replayable.
        assertFalse(_relayToL2WithGas(d3, STARVED_GAS), "starved relay executed");

        // ── T_activate_L1: activation of L1 ──────────────────────────────────────────────────
        _warpTo(l1.activateAt);
        // Vetoes: the Emergency Brakes flag, and a registry that does not bind the hub pool.
        _l1Veto(true);
        _expectStepRevert(l1, abi.encodeWithSelector(SENDS_DISABLED), false);
        _l1Veto(false);
        vm.mockCall(l1.tar, abi.encodeCall(ITarLike.getPool, (l1.token)), abi.encode(stranger));
        _expectStepRevert(l1, abi.encodeWithSelector(UNEXPECTED_POOL, stranger, l1.pool), false);
        vm.clearMockedCalls();

        vm.selectFork(l1.fork);
        uint256 escrowBefore = _escrow();
        uint256 lockBoxBefore = _lockBoxBalance();
        _activate(l1);
        assertEq(_escrow(), 0, "escrow not moved");
        assertEq(_lockBoxBalance(), lockBoxBefore + escrowBefore, "lockbox did not receive the escrow");
        _expectStepRevert(l1, abi.encodeWithSelector(ALREADY_ACTIVATED), false);
        _assertConserved("after the L1 activation");

        // L1 sends go through CCIP only; the deposit lands on Base while Base is still LEGACY,
        // because the pool mints it (the Base bridge is not on that path).
        _assertLegacyDepositImpossible();
        _ccipDeposit(1e18, recipient);
        _assertConserved("after the first CCIP deposit");

        // In flight across the L1 activation: w2 is paid from the lockbox (the escrow is empty),
        // d2 finalizes on the LEGACY Base bridge.
        vm.selectFork(l1.fork);
        lockBoxBefore = _lockBoxBalance();
        _finalizeOnL1(w2, 1e18);
        assertEq(_lockBoxBalance(), lockBoxBefore - 1e18, "legacy withdrawal not paid from the lockbox");
        assertEq(_escrow(), 0, "escrow should stay empty");
        _finalizeOnL2(d2, 1e18);
        _assertConserved("after d2 and w2");

        // Started while Base is still LEGACY (L1 already MIGRATING); its first L1 relay is starved.
        Sent memory w3 = _legacyWithdraw(1e18);
        assertFalse(_relayToL1WithGas(w3, STARVED_GAS), "starved relay executed");

        // ── T_activate_L2: activation of Base ────────────────────────────────────────────────
        _expectStepRevert(l2, abi.encodeWithSelector(TOO_EARLY, l2.activateAt), false);
        _warpTo(l2.activateAt);
        _l2Veto(true);
        _expectStepRevert(l2, abi.encodeWithSelector(SENDS_DISABLED), false);
        _l2Veto(false);
        assertTrue(_relayToL2(activationConfirmation), "L1 activation confirmation not delivered");
        _activate(l2);
        _expectStepRevert(l2, abi.encodeWithSelector(ALREADY_ACTIVATED), false);

        // No legacy transfer can be started in either direction any more; CCIP works both ways,
        // the withdrawal released from the lockbox the activation funded.
        _assertLegacyWithdrawalImpossible();
        _ccipWithdraw(1e18, recipient);
        _assertConserved("after the first CCIP withdrawal");

        // In flight across the Base activation: d4 finalizes on the MIGRATING Base bridge.
        _finalizeOnL2(d4, 1e18);
        _assertConserved("after d4");

        // Sweep inside the configured migration window, including shortened testnet windows.
        uint256 sweepAt = l2.activateAt + (l1.closeAt - l2.activateAt) / 2;
        assertGt(sweepAt, l2.activateAt, "no time for a sweep before close");
        assertLt(sweepAt, l1.closeAt, "sweep must precede close");
        _warpTo(sweepAt);
        _finalizeOnL2(d3, 1e18); // replay of the failed deposit relay on Base
        _finalizeOnL1(w3, 1e18); // replay of the failed withdrawal relay on L1
        _assertConserved("after the sweep");
        // dLate and wLate are deliberately left behind: the hazard the close-out must survive.
        _expectStepRevert(l1, abi.encodeWithSelector(TOO_EARLY, l1.closeAt), true);
        _expectStepRevert(l2, abi.encodeWithSelector(TOO_EARLY, l2.closeAt), true);
        // Once the timer has elapsed, close is MIGRATING → CCIP_ONLY only: a bridge the admin
        // rolled back to LEGACY cannot be closed by a stranger.
        _warpTo(l1.closeAt);
        _agent(l1.bridge, _switchMode(LEGACY));
        _expectStepRevert(l1, abi.encodeWithSelector(UNEXPECTED_MODE, LEGACY, MIGRATING), true);
        _agent(l1.bridge, _switchMode(MIGRATING));

        // ── T_close_L1L2: close on both chains ───────────────────────────────────────────────
        _warpTo(l1.closeAt);
        _l2Veto(true);
        _expectStepRevert(l2, abi.encodeWithSelector(SENDS_DISABLED), true);
        _l2Veto(false);
        _l1Veto(true);
        _expectStepRevert(l1, abi.encodeWithSelector(SENDS_DISABLED), true);
        _l1Veto(false);

        _close(l2);
        vm.selectFork(l2.fork);
        assertFalse(ITokenLike(l2.token).hasRole(MINTER_ROLE, l2.bridge), "bridge kept MINTER_ROLE");
        assertFalse(ITokenLike(l2.token).hasRole(BURNER_ROLE, l2.bridge), "bridge kept BURNER_ROLE");
        assertTrue(ITokenLike(l2.token).hasRole(MINTER_ROLE, l2.pool) && ITokenLike(l2.token).hasRole(BURNER_ROLE, l2.pool), "pool roles lost");
        _close(l1);
        _expectStepRevert(l1, abi.encodeWithSelector(ALREADY_CLOSED), true);
        _expectStepRevert(l2, abi.encodeWithSelector(ALREADY_CLOSED), true);
        _ccipDeposit(1e18, recipient);
        _ccipWithdraw(1e18, recipient);
        _assertConserved("after the close");

        // ── The hazard: legacy messages that arrive after the close ──────────────────────────
        // Not lost: they fail at the messengers and stay replayable.
        assertFalse(_relayToL2(dLate), "late deposit finalized in CCIP_ONLY");
        assertFalse(_relayToL1(wLate), "late withdrawal finalized in CCIP_ONLY");

        // Rollback B on Base: MIGRATING again and the roles back (vote), replay, then forward again (vote).
        address[] memory tr = new address[](3);
        bytes[] memory dr = new bytes[](3);
        (tr[0], dr[0]) = (l2.bridge, _switchMode(MIGRATING));
        (tr[1], dr[1]) = (l2.token, _role("grantRole", MINTER_ROLE, l2.bridge));
        (tr[2], dr[2]) = (l2.token, _role("grantRole", BURNER_ROLE, l2.bridge));
        _executorActionSet(tr, dr);
        _finalizeOnL2(dLate, 1e18);
        (tr[0], dr[0]) = (l2.bridge, _switchMode(CCIP_ONLY));
        (tr[1], dr[1]) = (l2.token, _role("revokeRole", MINTER_ROLE, l2.bridge));
        (tr[2], dr[2]) = (l2.token, _role("revokeRole", BURNER_ROLE, l2.bridge));
        _executorActionSet(tr, dr);
        _expectStepRevert(l2, abi.encodeWithSelector(ALREADY_ACTIVATED), false);

        // Rollback C on L1: MIGRATING again (vote) is enough, the bridge is still authorized on the
        // lockbox and pays the late withdrawal from it; then forward again (vote).
        _agent(l1.bridge, _switchMode(MIGRATING));
        vm.selectFork(l1.fork);
        lockBoxBefore = _lockBoxBalance();
        _finalizeOnL1(wLate, 1e18);
        assertEq(_lockBoxBalance(), lockBoxBefore - 1e18, "late withdrawal not paid from the lockbox");
        _agent(l1.bridge, _switchMode(CCIP_ONLY));
        _assertConserved("after the late-message recovery");

        // ── Hygiene: the lockbox owner drops the bridge's authorization ──────────────────────
        _dropLockBoxAuthorization();
        assertFalse(_authorizedOnLockBox(l1.bridge), "bridge still authorized on the lockbox");
        // After that a rollback alone no longer funds a legacy withdrawal: the authorization must
        // be restored first (section 2.C of the outline).
        _agent(l1.bridge, _switchMode(MIGRATING));
        assertFalse(_relayToL1(_syntheticWithdrawal(wLate)), "unauthorized bridge drew from the lockbox");
        _agent(l1.bridge, _switchMode(CCIP_ONLY));

        // ── End state ────────────────────────────────────────────────────────────────────────
        vm.selectFork(l1.fork);
        assertEq(IMigrationBridge(l1.bridge).getBridgeMode(), CCIP_ONLY);
        assertEq(_escrow(), 0, "escrow not empty at the end");
        vm.selectFork(l2.fork);
        assertEq(IMigrationBridge(l2.bridge).getBridgeMode(), CCIP_ONLY);
        assertFalse(ITokenLike(l2.token).hasRole(MINTER_ROLE, l2.bridge) || ITokenLike(l2.token).hasRole(BURNER_ROLE, l2.bridge));
        _ccipDeposit(1e18, recipient);
        _ccipWithdraw(1e18, recipient);
        _assertConserved("end state");
    }

    function preUpgradeDeposit_amount() internal view returns (uint256) {
        return vm.parseJsonUint(vm.readFile("state/migration.json"), ".inFlightDeposit.amount");
    }

    function preUpgradeWithdrawal_amount() internal view returns (uint256) {
        return vm.parseJsonUint(vm.readFile("state/migration.json"), ".inFlightWithdrawal.amount");
    }

    /// @dev A withdrawal message the Base bridge never sent (unused nonce, same version), relayed
    ///      through the portal path to probe the L1 bridge's funding after the hygiene step. It is
    ///      refused, so it never enters the conservation bookkeeping.
    function _syntheticWithdrawal(Sent memory template) internal pure returns (Sent memory s) {
        s = template;
        s.nonce = template.nonce + 1_000_000;
    }

    /// @dev The DAO, as the L1 timelock's admin, removes the bridge from the lockbox's callers.
    function _dropLockBoxAuthorization() internal {
        vm.selectFork(l1.fork);
        address[] memory removed = new address[](1);
        removed[0] = l1.bridge;
        ITimelockLike.Call[] memory calls = new ITimelockLike.Call[](1);
        calls[0] = ITimelockLike.Call(
            l1.lockBox,
            0,
            abi.encodeCall(
                ILockBoxLike.applyAuthorizedCallerUpdates,
                (ILockBoxLike.AuthorizedCallerArgs({addedCallers: new address[](0), removedCallers: removed}))
            )
        );
        vm.prank(l1.gov);
        ITimelockLike(l1.timelock).bypasserExecuteBatch(calls);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Levers on the finished lane
    // ─────────────────────────────────────────────────────────────────────────

    function test_levers_pause_halt_bypass_blocked() public {
        _setUpMigrationForks();
        _leversOn(l1);
        _leversOn(l2);
    }

    function _leversOn(Side storage c) internal {
        vm.selectFork(c.fork);
        ITimelockLike tl = ITimelockLike(c.timelock);
        // Emergency Brakes pause the hooks instantly; a CCIP send through the pool reverts.
        vm.prank(c.emergencyBrakes);
        IHooksLike(c.hooks).pauseCrossChainTransfers();
        assertTrue(IHooksLike(c.hooks).paused());
        // The DAO unpauses immediately as the timelock's admin (bypass); Chainlink could only propose.
        ITimelockLike.Call[] memory unpause = new ITimelockLike.Call[](1);
        unpause[0] = ITimelockLike.Call(c.hooks, 0, abi.encodeCall(IHooksLike.unpauseCrossChainTransfers, ()));
        vm.prank(c.gov);
        tl.bypasserExecuteBatch(unpause);
        assertFalse(IHooksLike(c.hooks).paused());

        // Chainlink proposes a routine change; the halt kills it; the DAO restarts the queue.
        bytes32 salt = keccak256(abi.encode(c.slug, "levers"));
        uint256 delay = tl.getMinDelay();
        ITimelockLike.Call[] memory routine = new ITimelockLike.Call[](1);
        routine[0] = ITimelockLike.Call(c.hooks, 0, abi.encodeCall(IHooksLike.pauseCrossChainTransfers, ()));
        vm.prank(c.chainlinkMcms);
        tl.scheduleBatch(routine, bytes32(0), salt, delay);
        bytes32 id = tl.hashOperationBatch(routine, bytes32(0), salt);
        assertTrue(tl.isOperationPending(id));
        uint248 epoch = tl.getEpoch();
        vm.prank(c.emergencyBrakes);
        tl.haltProposalQueue();
        assertTrue(tl.isProposalQueueHalted());
        assertEq(tl.getEpoch(), epoch + 1);
        assertFalse(tl.isOperationPending(id), "halted proposal still pending");
        vm.warp(vm.getBlockTimestamp() + delay + 1);
        assertFalse(tl.isOperationReady(id), "halted proposal became ready");
        vm.prank(c.chainlinkMcms);
        vm.expectRevert();
        tl.scheduleBatch(routine, bytes32(0), keccak256("other"), delay);
        vm.prank(c.gov);
        tl.restartProposalQueue();
        assertFalse(tl.isProposalQueueHalted());

        // A blocked selector cannot even be scheduled: ownership transfers stay with the DAO.
        ITimelockLike.Call[] memory blocked = new ITimelockLike.Call[](1);
        blocked[0] = ITimelockLike.Call(c.pool, 0, abi.encodeWithSignature("transferOwnership(address)", stranger));
        vm.prank(c.chainlinkMcms);
        vm.expectRevert();
        tl.scheduleBatch(blocked, bytes32(0), keccak256("blocked"), delay);

        // A new proposal after the restart runs through the full delay and anyone executes it.
        bytes32 salt2 = keccak256(abi.encode(c.slug, "after-restart"));
        vm.prank(c.chainlinkMcms);
        tl.scheduleBatch(routine, bytes32(0), salt2, delay);
        bytes32 id2 = tl.hashOperationBatch(routine, bytes32(0), salt2);
        vm.warp(vm.getBlockTimestamp() + delay + 1);
        assertTrue(tl.isOperationReady(id2));
        vm.prank(stranger);
        ITimelockLike(c.callProxy).executeBatch(routine, bytes32(0), salt2);
        assertTrue(IHooksLike(c.hooks).paused(), "proposal through the CallProxy did not execute");
        vm.prank(c.gov);
        tl.bypasserExecuteBatch(unpause);
    }
}

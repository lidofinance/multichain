// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {OnRamp} from "@chainlink/contracts-ccip/onRamp/OnRamp.sol";

interface IPom {
    function directCall(address target, uint256 value, bytes calldata data) external payable;
}

/// @notice PausableAdvancedPoolHooks.pauseCrossChainTransfers() — used type-safely (encodeCall) so a typo is a compile
/// error rather than a wrong selector that silently no-ops the negative test.
interface IPausableHooks {
    function pauseCrossChainTransfers() external;
}

/// @title BridgeScenarioBase — shared scaffolding for the fork scenario harnesses.
/// @notice Owns the pieces both CcvBridge and RealLaneBridge need identically: fork creation,
/// deploy-record loading (RECORD_DIR-selectable, same selector as script/_common.sh), and the loud
/// "deployment actually present on this fork" preconditions. Keeping these here means a record
/// schema change is made once, not once per harness (where the copies can silently drift).
abstract contract BridgeScenarioBase is Test {
    // Pinned revert selectors so the negative tests assert the *specific* gate, not "any revert".
    // OZ Pausable v5 (PausableAdvancedPoolHooks.whenNotPaused) reverts EnforcedPause().
    bytes4 internal constant ENFORCED_PAUSE_SELECTOR = bytes4(keccak256("EnforcedPause()"));
    // RateLimiter._consume reverts this when a single consume exceeds bucket capacity.
    bytes4 internal constant TOKEN_MAX_CAPACITY_EXCEEDED_SELECTOR =
        bytes4(keccak256("TokenMaxCapacityExceeded(uint256,uint256,address)"));

    uint256 internal l1Fork;
    uint256 internal l2Fork;

    /// @dev Per-chain context: the loaded section is shared; the trailing sections are each
    /// harness's own working set (unused fields simply stay zero in the other harness).
    struct Ctx {
        // loaded from the deploy record (already on the fork)
        address token;
        address pool;
        address hooks;
        address pom;
        address tar;
        address router;
        address arm; // RMN ARMProxy (.ccip.rmn_proxy); CcvBridge replaces it with its mock
        address govAdmin; // POM DEFAULT_ADMIN_ROLE holder: Agent (L1) / OpExec (L2)
        address lockBox; // SiloedLockRelease only (L1)
        uint64 selector;
        uint64 remoteSelector;
        // deployed by the CcvBridge harness (self-owned 2.0 ramp layer + mocks)
        address onRamp;
        address offRamp;
        address ccvA;
        address ccvB;
        address feeQuoter;
        // resolved by the RealLaneBridge harness from the real 1.2.0 Router + our pool
        address realOnRamp; // router.getOnRamp(remoteSelector)
        address realOffRamp; // getOffRamps() entry whose sourceChainSelector == remoteSelector
        bytes remotePool; // pool.getRemotePools(remoteSelector)[0]
    }

    Ctx internal l1;
    Ctx internal l2;

    address internal user = makeAddr("bridgeUser");
    address internal recipient = makeAddr("recipient");

    /// @dev L2 of the pair — selects config/chains/<slug>.json and the RPC env var
    /// RPC_<UPPERCASED SLUG>, same convention as script/_common.sh.
    string internal l2Chain;

    /// @dev Common front half of every harness's setUp: forks + record + preconditions.
    function _setUpForksAndRecord() internal {
        l2Chain = vm.envOr("L2_CHAIN", string("mantle_sepolia"));
        l1Fork = _createFork("RPC_SEPOLIA", "FORK_BLOCK_L1");
        // RPC resolution: explicit L2_RPC (set by the just recipes) > RPC_<UPPER(slug)>. No
        // committed default — the endpoint must come from the environment (forks tray / .env).
        string memory l2RpcVar = string.concat("RPC_", _upper(l2Chain));
        string memory l2Url = vm.envOr("L2_RPC", vm.envOr(l2RpcVar, string("")));
        require(bytes(l2Url).length != 0, string.concat("set L2_RPC or ", l2RpcVar));
        l2Fork = _createForkUrl(l2Url, "FORK_BLOCK_L2");
        _loadAddrs();
        _assertDeployed();
    }

    function _upper(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] >= 0x61 && b[i] <= 0x7a) b[i] = bytes1(uint8(b[i]) - 32);
        }
        return string(b);
    }

    /// @dev FORK_BLOCK_* (optional) pins the fork: Foundry's RPC disk cache is keyed by
    /// (endpoint, block), so an unpinned fork against a live archive endpoint re-downloads all
    /// touched state every run. Unset/0 keeps the latest-block behavior (fine on local anvil).
    function _createFork(string memory rpcVar, string memory blockVar) internal returns (uint256) {
        string memory url = vm.envOr(rpcVar, string(""));
        require(bytes(url).length != 0, string.concat("set ", rpcVar));
        return _createForkUrl(url, blockVar);
    }

    function _createForkUrl(string memory url, string memory blockVar) internal returns (uint256) {
        uint256 blk = vm.envOr(blockVar, uint256(0));
        return blk == 0 ? vm.createFork(url) : vm.createFork(url, blk);
    }

    function _loadAddrs() internal {
        // Deploy record dir is selectable so a live-network record and the anvil record can
        // coexist; defaults to the canonical config/chains. Same RECORD_DIR selector as script/_common.sh.
        string memory dir = vm.envOr("RECORD_DIR", string("config/chains"));

        string memory s = vm.readFile(string.concat(dir, "/sepolia.json"));
        _loadCommon(l1, s);
        l1.lockBox = vm.parseJsonAddress(s, ".deployed.lock_boxes[0].lock_box"); // siloed pool only

        _loadCommon(l2, vm.readFile(string.concat(dir, "/", l2Chain, ".json")));

        // Lane selectors come from the record itself (no hardcoded testnet constants), so a
        // RECORD_DIR swap can't silently pair a different record with stale selectors.
        l1.remoteSelector = l2.selector;
        l2.remoteSelector = l1.selector;
    }

    /// @dev Loads the per-chain CCIP config fields shared by both chains from a config JSON.
    function _loadCommon(Ctx storage c, string memory s) internal {
        c.token = vm.parseJsonAddress(s, ".addresses.token");
        c.pool = vm.parseJsonAddress(s, ".deployed.token_pool");
        c.hooks = vm.parseJsonAddress(s, ".deployed.advanced_pool_hooks");
        c.pom = vm.parseJsonAddress(s, ".deployed.pool_operation_manager");
        c.tar = vm.parseJsonAddress(s, ".ccip.token_admin_registry");
        c.router = vm.parseJsonAddress(s, ".ccip.router");
        c.arm = vm.parseJsonAddress(s, ".ccip.rmn_proxy");
        c.govAdmin = vm.parseJsonAddress(s, ".governance_addresses.lido_dao_agent");
        c.selector = uint64(vm.parseJsonUint(s, ".ccip.chain_selector"));
    }

    /// @dev Substrate-agnostic precondition: the loaded record must correspond to a deployment
    /// actually present on each fork (a live-testnet fork OR the persistent anvil fork). Fails
    /// loud and early — "run the deploy first / RPC↔record mismatch" — instead of a deep revert
    /// once a scenario starts calling into a non-existent contract.
    function _assertDeployed() internal {
        vm.selectFork(l1Fork);
        _requireCode(l1.token, "l1 token");
        _requireCode(l1.pool, "l1 pool");
        _requireCode(l1.hooks, "l1 hooks");
        _requireCode(l1.pom, "l1 POM");
        _requireCode(l1.router, "l1 router");
        _requireCode(l1.lockBox, "l1 lockBox");
        _assertDeployedExtraL1();

        vm.selectFork(l2Fork);
        _requireCode(l2.token, "l2 token");
        _requireCode(l2.pool, "l2 pool");
        _requireCode(l2.hooks, "l2 hooks");
        _requireCode(l2.pom, "l2 POM");
        _requireCode(l2.router, "l2 router");
        _assertDeployedExtraL2();
    }

    /// @dev Harness-specific preconditions, run with the respective fork selected.
    function _assertDeployedExtraL1() internal view virtual {}
    function _assertDeployedExtraL2() internal view virtual {}

    /// @dev The lane's CCV pair as configured by the harness (ccvA/ccvB), in hooks-config order.
    function _ccvs(Ctx storage c) internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = c.ccvA;
        a[1] = c.ccvB;
    }

    bytes32 internal constant CCIP_MESSAGE_SENT_SIG =
        keccak256("CCIPMessageSent(uint64,address,bytes32,address,uint256,bytes,(address,uint32,uint32,uint256,bytes)[],bytes[])");

    // NOTE: this log-scrape is coupled to OnRamp 2.0's CCIPMessageSent event shape in two places —
    // CCIP_MESSAGE_SENT_SIG (the topic-0 keccak) and the positional abi.decode below. A CCIP
    // upgrade that adds/removes/reorders a Receipt field or a non-indexed event arg will break
    // BOTH in lockstep: topic-0 stops matching (-> "log not found") or the tuple positions shift
    // (-> garbage encodedMessage -> opaque OffRamp revert). There is no compile-time link to the
    // event, so if a CCIP bump makes every send-based test fail, suspect this signature first.
    function _extractEncodedMessage(address onRamp) internal returns (bytes memory encodedMessage) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == onRamp && logs[i].topics.length > 0 && logs[i].topics[0] == CCIP_MESSAGE_SENT_SIG) {
                (,, encodedMessage,,) = abi.decode(logs[i].data, (address, uint256, bytes, OnRamp.Receipt[], bytes[]));
                return encodedMessage;
            }
        }
        revert("CCIPMessageSent log not found");
    }

    function _requireCode(address a, string memory label) internal view {
        require(
            a.code.length > 0,
            string.concat("no deployment at ", label, " (", vm.toString(a), ") on this fork -- deploy first / check RPC+record")
        );
    }
}

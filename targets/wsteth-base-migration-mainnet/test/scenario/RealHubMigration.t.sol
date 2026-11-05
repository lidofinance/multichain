// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pool} from "@chainlink/contracts-ccip/libraries/Pool.sol";

interface IRouterLike {
    struct OffRamp {
        uint64 sourceChainSelector;
        address offRamp;
    }

    function getOffRamps() external view returns (OffRamp[] memory);
    function getOnRamp(uint64 destChainSelector) external view returns (address);
}

interface IHubPoolLike {
    function lockOrBurn(Pool.LockOrBurnInV1 calldata input) external returns (Pool.LockOrBurnOutV1 memory);
    function releaseOrMint(Pool.ReleaseOrMintInV1 calldata input) external returns (Pool.ReleaseOrMintOutV1 memory);
    function getLockBox(uint64 remoteChainSelector) external view returns (address);
    function getRemotePools(uint64 remoteChainSelector) external view returns (bytes[] memory);
    function isSupportedChain(uint64 remoteChainSelector) external view returns (bool);
    function getSupportedChains() external view returns (uint64[] memory);
    function getRequiredCCVs(
        address localToken,
        uint64 remoteChainSelector,
        uint256 amount,
        bytes4 finality,
        bytes calldata extraData,
        uint8 direction
    ) external view returns (address[] memory);
}

interface IHooksLike {
    function getRequiredCCVs(
        address localToken,
        uint64 remoteChainSelector,
        uint256 amount,
        bytes4 finality,
        bytes calldata extraData,
        uint8 direction
    ) external view returns (address[] memory);
}

/// @dev The SiloedLockReleaseTokenPool 1.6.0 the hub replaced.
interface IOldPoolLike {
    struct TokenBucket {
        uint128 tokens;
        uint32 lastUpdated;
        bool isEnabled;
        uint128 capacity;
        uint128 rate;
    }

    function getUnsiloedLiquidity() external view returns (uint256);
    function getAvailableTokens(uint64 remoteChainSelector) external view returns (uint256);
    function getChainRebalancer(uint64 remoteChainSelector) external view returns (address);
    function getCurrentOutboundRateLimiterState(uint64 remoteChainSelector) external view returns (TokenBucket memory);
}

interface ITarLike {
    struct TokenConfig {
        address administrator;
        address pendingAdministrator;
        address tokenPool;
    }

    function getTokenConfig(address token) external view returns (TokenConfig memory);
}

interface IRbacTimelockLike {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    function executeBatch(Call[] calldata calls, bytes32 predecessor, bytes32 salt) external payable;
    function isOperationDone(bytes32 id) external view returns (bool);
    function ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title RealHubMigration — the nine existing CCIP lanes on the new Ethereum hub after Chainlink's cutover,
/// and the Base lane Chainlink connected afterwards.
/// @notice Starts where steps 01h, 04, 05, 05h, 05c and 07 left the Ethereum fork: the registry binds wstETH to
/// the new SiloedLockReleaseTokenPool 2.0.0 (administered by the LidoTimelock), the old pool is empty, and
/// each lane's custody sits in the lockbox of its group — one shared lockbox for the lanes that were
/// unsiloed in the old pool, one lockbox per lane that was siloed, the Base lane's lockbox apart.
/// Checks, per lane: the registered Router ramps can release from and lock into exactly that lockbox;
/// a siloed lane cannot draw on the shared lockbox and the Base lane cannot draw on either; the cutover
/// batch cannot run twice; the old pool's outbound limiters are the pause; the hooks require no CCVs on
/// the imported lanes while the Base lane keeps its resolver. Two Chainlink actions are told apart: the
/// cutover batch (Chainlink's own RBACTimelock) bound a hub that served exactly the old pool's lanes, and
/// the Base lane came by a separate LidoTimelock proposal that cannot run twice either.
///
/// Transport is simulated at the pool boundary: the registered OffRamp of each source and the OnRamp of
/// each destination are impersonated (the exact calls the real ramps make), no DON runs, and the spoke
/// chains are not forked (their pools still naming the old hub is outside this test).
contract RealHubMigrationTest is Test {
    uint8 internal constant OUTBOUND = 0;
    uint8 internal constant INBOUND = 1;
    bytes4 internal constant WAIT_FOR_FINALITY = 0x00000000;
    bytes4 internal constant INSUFFICIENT_BALANCE = bytes4(keccak256("InsufficientBalance(uint256,uint256)"));

    struct Lane {
        string slug;
        uint64 selector;
        bool siloed;
        string group;
        address lockBox;
        address remotePool;
        address offRamp;
        address onRamp;
        uint256 inboundCapacity;
        uint256 outboundCapacity;
        uint256 groupAmountAfterCutover;
    }

    bool internal hubOnly;
    uint256 internal fork;
    address internal token;
    address internal router;
    address internal tar;
    address internal hub;
    address internal hooks;
    address internal resolver;
    address internal lidoTimelock;
    address internal oldPool;
    address internal chainlinkTimelock;
    address internal executor;
    address internal baseLockBox;
    uint64 internal baseSelector;
    bytes32 internal pauseId;
    bytes32 internal cutoverId;
    bytes32 internal cutoverPredecessor;
    bytes32 internal cutoverSalt;
    IRbacTimelockLike.Call[] internal cutoverCalls;
    uint64[] internal supportedAtCutover; // the hub's lanes when the cutover batch bound it (step 05h)
    // The Base lane, connected after the cutover by a LidoTimelock proposal (step 05c)
    address internal baseSpokePool;
    address internal connectExecutor; // the LidoTimelock's CallProxy
    bytes32 internal connectId;
    bytes32 internal connectPredecessor;
    bytes32 internal connectSalt;
    IRbacTimelockLike.Call[] internal connectCalls;
    Lane[] internal lanes;
    address[] internal allLockBoxes; // every distinct lockbox of the hub, the Base lane's included
    address internal recipient = makeAddr("hub-migration-recipient");
    address internal stranger = makeAddr("hub-migration-stranger");

    function setUp() public {
        hubOnly = vm.envOr("HUB_CHECKPOINT", false);
        string memory l1 = vm.envOr("L1_CHAIN", string("ethereum"));
        string memory l2 = vm.envOr("L2_CHAIN", string("base"));
        fork = vm.createSelectFork(_rpc(l1, "L1_RPC"));
        string memory dir = vm.envOr("RECORD_DIR", string("config/chains"));
        string memory c1 = vm.readFile(string.concat(dir, "/", l1, ".json"));
        string memory c2 = vm.readFile(string.concat(dir, "/", l2, ".json"));
        string memory hm = vm.readFile("state/hub-migration.json");
        token = vm.parseJsonAddress(c1, ".addresses.token");
        router = vm.parseJsonAddress(c1, ".ccip.router");
        tar = vm.parseJsonAddress(c1, ".ccip.token_admin_registry");
        hub = vm.parseJsonAddress(c1, ".deployed.token_pool");
        hooks = vm.parseJsonAddress(c1, ".deployed.advanced_pool_hooks");
        resolver = vm.parseJsonAddress(c1, ".ccv.verifier_resolver");
        lidoTimelock = vm.parseJsonAddress(c1, ".deployed.timelock");
        baseSelector = uint64(vm.parseJsonUint(c2, ".ccip.chain_selector"));
        require(vm.parseJsonAddress(hm, ".newHub") == hub, "state/hub-migration.json describes another hub");
        require(vm.parseJsonAddress(hm, ".token") == token, "state/hub-migration.json describes another token");
        oldPool = vm.parseJsonAddress(hm, ".oldPool");
        chainlinkTimelock = vm.parseJsonAddress(hm, ".chainlinkTimelock");
        assertFalse(vm.parseJsonBool(hm, ".baseLockBoxDeployed"), "Base lockbox existed at cutover");
        assertEq(vm.parseJsonAddress(hm, ".baseLockBox"), address(0), "Base lockbox must be absent at cutover");
        if (!hubOnly) {
            for (uint256 i; vm.keyExistsJson(c1, string.concat(".deployed.lock_boxes[", vm.toString(i), "]")); ++i) {
                string memory key = string.concat(".deployed.lock_boxes[", vm.toString(i), "]");
                if (
                    keccak256(bytes(vm.parseJsonString(c1, string.concat(key, ".remote_chain_name"))))
                        == keccak256(bytes(l2))
                ) {
                    baseLockBox = vm.parseJsonAddress(c1, string.concat(key, ".lock_box"));
                }
            }
            require(baseLockBox != address(0), "Base lockbox missing after preparation");
        }
        pauseId = vm.parseJsonBytes32(hm, ".proposals[0].id");
        cutoverId = vm.parseJsonBytes32(hm, ".proposals[1].id");
        cutoverPredecessor = vm.parseJsonBytes32(hm, ".proposals[1].predecessor");
        cutoverSalt = vm.parseJsonBytes32(hm, ".proposals[1].salt");
        executor = vm.parseJsonAddress(hm, ".proposals[1].executor");
        for (uint256 i; vm.keyExistsJson(hm, string.concat(".proposals[1].calls[", vm.toString(i), "]")); ++i) {
            string memory k = string.concat(".proposals[1].calls[", vm.toString(i), "]");
            cutoverCalls.push(
                IRbacTimelockLike.Call({
                    target: vm.parseJsonAddress(hm, string.concat(k, ".target")),
                    value: vm.parseJsonUint(hm, string.concat(k, ".value")),
                    data: vm.parseJsonBytes(hm, string.concat(k, ".data"))
                })
            );
        }
        require(cutoverCalls.length > 0, "no cutover calls recorded");
        IRouterLike.OffRamp[] memory offRamps = IRouterLike(router).getOffRamps();
        for (uint256 i; vm.keyExistsJson(hm, string.concat(".lanes[", vm.toString(i), "]")); ++i) {
            string memory k = string.concat(".lanes[", vm.toString(i), "]");
            Lane memory lane;
            lane.slug = vm.parseJsonString(hm, string.concat(k, ".slug"));
            lane.selector = uint64(vm.parseJsonUint(hm, string.concat(k, ".selector")));
            lane.siloed = vm.parseJsonBool(hm, string.concat(k, ".siloed"));
            lane.group = vm.parseJsonString(hm, string.concat(k, ".lockBoxGroup"));
            lane.lockBox = vm.parseJsonAddress(hm, string.concat(k, ".lockBox"));
            lane.remotePool = vm.parseJsonAddress(hm, string.concat(k, ".remotePool"));
            lane.onRamp = vm.parseJsonAddress(hm, string.concat(k, ".onRamp"));
            lane.inboundCapacity = vm.parseJsonUint(hm, string.concat(k, ".inboundCapacity"));
            lane.outboundCapacity = vm.parseJsonUint(hm, string.concat(k, ".outboundCapacity"));
            lane.groupAmountAfterCutover =
                vm.parseJsonUint(hm, string.concat(".snapshots.after.lockBoxes.", lane.group));
            for (uint256 j; j < offRamps.length; ++j) {
                if (offRamps[j].sourceChainSelector == lane.selector) lane.offRamp = offRamps[j].offRamp;
            }
            require(lane.offRamp != address(0), string.concat(lane.slug, ": no OffRamp on the router"));
            require(
                lane.onRamp == IRouterLike(router).getOnRamp(lane.selector),
                string.concat(lane.slug, ": OnRamp changed")
            );
            lanes.push(lane);
            _rememberLockBox(lane.lockBox);
        }
        require(lanes.length > 0, "no imported lanes recorded");
        if (!hubOnly) _rememberLockBox(baseLockBox);
        // The hub's lanes at the moment the cutover batch bound it (schema 2 of state/hub-migration.json).
        for (
            uint256 i; vm.keyExistsJson(hm, string.concat(".hubAtCutover.supportedChains[", vm.toString(i), "]")); ++i) {
            supportedAtCutover.push(
                uint64(
                    vm.parseUint(
                        vm.parseJsonString(hm, string.concat(".hubAtCutover.supportedChains[", vm.toString(i), "]"))
                    )
                )
            );
        }
        require(
            supportedAtCutover.length > 0,
            "state/hub-migration.json records no hubAtCutover.supportedChains (re-run step 05h)"
        );
        if (hubOnly) {
            assertFalse(vm.keyExistsJson(c2, ".deployed"), "Base contracts deployed before hub checkpoint");
            assertEq(resolver, address(0), "Base resolver deployed before hub checkpoint");
            assertEq(_verifier(), address(0), "Base verifier deployed before hub checkpoint");
            assertEq(allLockBoxes.length, _expectedExistingLockBoxes(), "Unexpected existing-lane lockbox count");
            assertFalse(IHubPoolLike(hub).isSupportedChain(baseSelector), "Base already connected at checkpoint");
            return;
        }
        // The Base lane's connection (step 05c): the LidoTimelock proposal that gave the hub its tenth lane.
        string memory hlc = vm.readFile("state/hub-lane-connect.json");
        require(vm.parseJsonAddress(hlc, ".hub") == hub, "state/hub-lane-connect.json describes another hub");
        require(
            vm.parseJsonUint(hlc, ".selector") == baseSelector, "state/hub-lane-connect.json describes another lane"
        );
        require(
            vm.parseJsonAddress(hlc, ".lockBox") == baseLockBox,
            "state/hub-lane-connect.json names another Base lockbox"
        );
        require(
            vm.parseJsonAddress(hlc, ".lidoTimelock") == lidoTimelock,
            "state/hub-lane-connect.json names another timelock"
        );
        baseSpokePool = vm.parseJsonAddress(hlc, ".spokePool");
        connectExecutor = vm.parseJsonAddress(hlc, ".proposal.executor");
        connectId = vm.parseJsonBytes32(hlc, ".proposal.id");
        connectPredecessor = vm.parseJsonBytes32(hlc, ".proposal.predecessor");
        connectSalt = vm.parseJsonBytes32(hlc, ".proposal.salt");
        for (uint256 i; vm.keyExistsJson(hlc, string.concat(".proposal.calls[", vm.toString(i), "]")); ++i) {
            string memory k = string.concat(".proposal.calls[", vm.toString(i), "]");
            connectCalls.push(
                IRbacTimelockLike.Call({
                    target: vm.parseJsonAddress(hlc, string.concat(k, ".target")),
                    value: vm.parseJsonUint(hlc, string.concat(k, ".value")),
                    data: vm.parseJsonBytes(hlc, string.concat(k, ".data"))
                })
            );
        }
        require(connectCalls.length > 0, "no lane connection calls recorded");
    }

    function _expectedExistingLockBoxes() internal pure virtual returns (uint256) {
        return 4;
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

    function _rememberLockBox(address box) internal {
        for (uint256 i; i < allLockBoxes.length; ++i) {
            if (allLockBoxes[i] == box) return;
        }
        allLockBoxes.push(box);
    }

    function _balances() internal view returns (uint256[] memory out) {
        out = new uint256[](allLockBoxes.length);
        for (uint256 i; i < allLockBoxes.length; ++i) {
            out[i] = IERC20(token).balanceOf(allLockBoxes[i]);
        }
    }

    /// @dev Every lockbox but `except` holds what it held in `before`.
    function _assertOthersUnchanged(uint256[] memory before, address except, string memory where) internal view {
        for (uint256 i; i < allLockBoxes.length; ++i) {
            if (allLockBoxes[i] == except) continue;
            assertEq(
                IERC20(token).balanceOf(allLockBoxes[i]),
                before[i],
                string.concat(where, ": lockbox ", vm.toString(allLockBoxes[i]), " changed")
            );
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _release(Lane memory lane, uint256 amount) internal {
        vm.prank(lane.offRamp);
        IHubPoolLike(hub)
            .releaseOrMint(
                Pool.ReleaseOrMintInV1({
                    originalSender: abi.encode(stranger),
                    remoteChainSelector: lane.selector,
                    receiver: recipient,
                    sourceDenominatedAmount: amount,
                    localToken: token,
                    sourcePoolAddress: abi.encode(lane.remotePool),
                    sourcePoolData: "",
                    offchainTokenData: ""
                })
            );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // End state of the cutover
    // ─────────────────────────────────────────────────────────────────────────

    function test_cutover_end_state() public view {
        ITarLike.TokenConfig memory cfg = ITarLike(tar).getTokenConfig(token);
        assertEq(cfg.tokenPool, hub, "registry does not bind the new hub");
        assertEq(cfg.administrator, lidoTimelock, "registry administrator is not the LidoTimelock");
        assertEq(cfg.pendingAdministrator, address(0), "a registry administration is still pending");
        assertTrue(IRbacTimelockLike(chainlinkTimelock).isOperationDone(pauseId), "pause proposal not done");
        assertTrue(IRbacTimelockLike(chainlinkTimelock).isOperationDone(cutoverId), "cutover proposal not done");
        assertEq(IERC20(token).balanceOf(oldPool), 0, "old pool still holds wstETH");
        assertEq(IOldPoolLike(oldPool).getUnsiloedLiquidity(), 0, "old pool still accounts unsiloed liquidity");
        for (uint256 i; i < lanes.length; ++i) {
            Lane memory lane = lanes[i];
            if (lane.siloed) {
                assertEq(
                    IOldPoolLike(oldPool).getAvailableTokens(lane.selector),
                    0,
                    string.concat(lane.slug, ": old silo not empty")
                );
            }
            assertEq(
                IHubPoolLike(hub).getLockBox(lane.selector), lane.lockBox, string.concat(lane.slug, ": hub lockbox")
            );
            assertEq(
                IERC20(token).balanceOf(lane.lockBox),
                lane.groupAmountAfterCutover,
                string.concat(lane.slug, ": lockbox balance is not the recorded post-cutover amount")
            );
            bytes[] memory remotes = IHubPoolLike(hub).getRemotePools(lane.selector);
            bool listed;
            for (uint256 j; j < remotes.length; ++j) {
                if (keccak256(remotes[j]) == keccak256(abi.encode(lane.remotePool))) listed = true;
            }
            assertTrue(listed, string.concat(lane.slug, ": the spoke pool is not a remote pool of the hub"));
        }
        if (!hubOnly) assertEq(IHubPoolLike(hub).getLockBox(baseSelector), baseLockBox, "Base lane lockbox");
        for (uint256 i; i < lanes.length; ++i) {
            assertTrue(lanes[i].lockBox != baseLockBox, string.concat(lanes[i].slug, " shares the Base lockbox"));
            for (uint256 j; j < lanes.length; ++j) {
                bool sameBox = lanes[i].lockBox == lanes[j].lockBox;
                bool sameGroup = keccak256(bytes(lanes[i].group)) == keccak256(bytes(lanes[j].group));
                assertEq(
                    sameBox,
                    sameGroup,
                    string.concat(lanes[i].slug, "/", lanes[j].slug, ": lockbox sharing differs from the groups")
                );
            }
        }
    }

    function test_admin_accepted_by_mcms_and_deployer_cannot_bypass() public {
        string memory accepted = vm.readFile("state/hub-admin-accept.json");
        bytes32 id = vm.parseJsonBytes32(accepted, ".proposal.id");
        assertTrue(IRbacTimelockLike(lidoTimelock).isOperationDone(id), "admin acceptance proposal not executed");
        string memory dir = vm.envOr("RECORD_DIR", string("config/chains"));
        string memory c1 = vm.readFile(string.concat(dir, "/", vm.envOr("L1_CHAIN", string("ethereum")), ".json"));
        assertEq(
            vm.parseJsonAddress(accepted, ".proposal.proposer"),
            vm.parseJsonAddress(c1, ".governance_addresses.chainlink_mcms")
        );
        address deployer = vm.parseJsonAddress(c1, ".governance_addresses.deployer");
        assertFalse(IRbacTimelockLike(lidoTimelock).hasRole(IRbacTimelockLike(lidoTimelock).ADMIN_ROLE(), deployer));
        IRbacTimelockLike.Call[] memory calls = new IRbacTimelockLike.Call[](1);
        calls[0] = IRbacTimelockLike.Call(tar, 0, abi.encodeWithSignature("acceptAdminRole(address)", token));
        vm.prank(deployer);
        (bool success,) =
            lidoTimelock.call(abi.encodeWithSignature("bypasserExecuteBatch((address,uint256,bytes)[])", calls));
        assertFalse(success, "deployer still has bypass authority");
        vm.expectRevert(bytes("RBACTimelock: operation is not ready"));
        IRbacTimelockLike(vm.parseJsonAddress(accepted, ".proposal.executor"))
            .executeBatch(
                calls,
                vm.parseJsonBytes32(accepted, ".proposal.predecessor"),
                vm.parseJsonBytes32(accepted, ".proposal.salt")
            );
    }

    function test_old_pool_outbound_paused_on_every_lane() public view {
        for (uint256 i; i < lanes.length; ++i) {
            IOldPoolLike.TokenBucket memory b =
                IOldPoolLike(oldPool).getCurrentOutboundRateLimiterState(lanes[i].selector);
            assertTrue(b.isEnabled, string.concat(lanes[i].slug, ": outbound limiter disabled"));
            assertEq(b.capacity, 2, string.concat(lanes[i].slug, ": outbound capacity is not the pause (2 wei)"));
            assertEq(b.rate, 1, string.concat(lanes[i].slug, ": outbound rate is not the pause (1 wei/s)"));
        }
    }

    function test_no_required_ccvs_on_imported_lanes() public view {
        for (uint256 i; i < lanes.length; ++i) {
            uint64 sel = lanes[i].selector;
            assertEq(
                IHooksLike(hooks).getRequiredCCVs(token, sel, 1e18, WAIT_FOR_FINALITY, "", OUTBOUND).length,
                0,
                string.concat(lanes[i].slug, ": outbound CCVs required")
            );
            assertEq(
                IHooksLike(hooks).getRequiredCCVs(token, sel, 1e18, WAIT_FOR_FINALITY, "", INBOUND).length,
                0,
                string.concat(lanes[i].slug, ": inbound CCVs required")
            );
            assertEq(
                IHubPoolLike(hub).getRequiredCCVs(token, sel, 1e18, WAIT_FOR_FINALITY, "", OUTBOUND).length,
                0,
                string.concat(lanes[i].slug, ": pool requires outbound CCVs")
            );
        }
        if (hubOnly) return;
        address[] memory base =
            IHubPoolLike(hub).getRequiredCCVs(token, baseSelector, 1e18, WAIT_FOR_FINALITY, "", OUTBOUND);
        assertEq(base.length, 1, "Base lane lost its required CCV");
        assertEq(base[0], resolver, "Base lane CCV is not the resolver");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Custody per lane
    // ─────────────────────────────────────────────────────────────────────────

    function test_imported_lanes_release_from_their_lockboxes() public {
        for (uint256 i; i < lanes.length; ++i) {
            Lane memory lane = lanes[i];
            uint256 amount = _min(_min(1e18, lane.inboundCapacity), IERC20(token).balanceOf(lane.lockBox));
            assertGt(amount, 0, string.concat(lane.slug, ": nothing to release"));
            uint256[] memory before = _balances();
            uint256 toBefore = IERC20(token).balanceOf(recipient);
            _release(lane, amount);
            assertEq(IERC20(token).balanceOf(recipient), toBefore + amount, string.concat(lane.slug, ": not released"));
            assertEq(
                IERC20(token).balanceOf(lane.lockBox),
                before[_indexOf(lane.lockBox)] - amount,
                string.concat(lane.slug, ": released from another lockbox")
            );
            _assertOthersUnchanged(before, lane.lockBox, lane.slug);
        }
    }

    function test_imported_lanes_lock_into_their_lockboxes() public {
        for (uint256 i; i < lanes.length; ++i) {
            Lane memory lane = lanes[i];
            uint256 amount = _min(1e18, lane.outboundCapacity);
            if (amount == 0) continue; // outbound disabled on that lane today
            uint256[] memory before = _balances();
            deal(token, hub, amount); // what the OnRamp has moved into the pool before calling it
            vm.prank(lane.onRamp);
            IHubPoolLike(hub)
                .lockOrBurn(
                    Pool.LockOrBurnInV1({
                        receiver: abi.encode(recipient),
                        remoteChainSelector: lane.selector,
                        originalSender: stranger,
                        amount: amount,
                        localToken: token
                    })
                );
            assertEq(
                IERC20(token).balanceOf(lane.lockBox),
                before[_indexOf(lane.lockBox)] + amount,
                string.concat(lane.slug, ": not locked into its lockbox")
            );
            assertEq(IERC20(token).balanceOf(hub), 0, string.concat(lane.slug, ": the pool kept tokens"));
            _assertOthersUnchanged(before, lane.lockBox, lane.slug);
        }
    }

    function test_siloed_lanes_cannot_draw_from_the_shared_lockbox() public {
        uint256 checked;
        for (uint256 i; i < lanes.length; ++i) {
            Lane memory lane = lanes[i];
            if (!lane.siloed) continue;
            uint256 own = IERC20(token).balanceOf(lane.lockBox);
            uint256 amount = own + 1;
            if (amount > lane.inboundCapacity) continue; // the limiter would answer before the lockbox
            uint256[] memory before = _balances();
            vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE, amount, own));
            _release(lane, amount);
            _assertOthersUnchanged(before, address(0), lane.slug);
            ++checked;
        }
        assertGt(checked, 0, "no siloed lane could be checked");
    }

    function test_the_base_lane_is_isolated_from_the_imported_lanes() public {
        vm.skip(hubOnly);
        bytes[] memory remotes = IHubPoolLike(hub).getRemotePools(baseSelector);
        require(remotes.length > 0, "no Base remote pool");
        address baseOffRamp;
        IRouterLike.OffRamp[] memory offRamps = IRouterLike(router).getOffRamps();
        for (uint256 j; j < offRamps.length; ++j) {
            if (offRamps[j].sourceChainSelector == baseSelector) baseOffRamp = offRamps[j].offRamp;
        }
        require(baseOffRamp != address(0), "no Base OffRamp");
        uint256 own = IERC20(token).balanceOf(baseLockBox);
        uint256 amount = own + 1;
        uint256[] memory before = _balances();
        vm.prank(baseOffRamp);
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE, amount, own));
        IHubPoolLike(hub)
            .releaseOrMint(
                Pool.ReleaseOrMintInV1({
                    originalSender: abi.encode(stranger),
                    remoteChainSelector: baseSelector,
                    receiver: recipient,
                    sourceDenominatedAmount: amount,
                    localToken: token,
                    sourcePoolAddress: remotes[0],
                    sourcePoolData: "",
                    offchainTokenData: ""
                })
            );
        _assertOthersUnchanged(before, address(0), "base");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The batch cannot run twice
    // ─────────────────────────────────────────────────────────────────────────

    function test_cutover_batch_cannot_be_executed_again() public {
        IRbacTimelockLike.Call[] memory calls = cutoverCalls;
        uint256[] memory before = _balances();
        vm.expectRevert(bytes("RBACTimelock: operation is not ready"));
        IRbacTimelockLike(executor).executeBatch(calls, cutoverPredecessor, cutoverSalt);
        _assertOthersUnchanged(before, address(0), "replay");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Two Chainlink actions, two instruments: the cutover moved what existed; the Base lane came after
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The hub the registry was switched to served exactly the old pool's lanes: the Base lane was not among
    ///      them, so the cutover batch migrated the existing service and nothing else.
    function test_the_cutover_bound_a_hub_that_mirrored_the_old_pool() public view {
        assertEq(supportedAtCutover.length, lanes.length, "the hub served another number of lanes at the cutover");
        for (uint256 i; i < lanes.length; ++i) {
            bool found;
            for (uint256 j; j < supportedAtCutover.length; ++j) {
                if (supportedAtCutover[j] == lanes[i].selector) found = true;
            }
            assertTrue(found, string.concat(lanes[i].slug, ": not served by the hub at the cutover"));
        }
        for (uint256 j; j < supportedAtCutover.length; ++j) {
            assertTrue(supportedAtCutover[j] != baseSelector, "the Base lane was already on the hub at the cutover");
        }
        // Today the hub serves the old lanes and Base: one lane more than at the cutover.
        assertEq(
            IHubPoolLike(hub).getSupportedChains().length,
            supportedAtCutover.length + (hubOnly ? 0 : 1),
            "lanes on the hub today"
        );
    }

    /// @dev The Base lane was connected by the hub's owner, the LidoTimelock, through a proposal (Chainlink MCMS is
    ///      its proposer), not by the deployer and not by Chainlink's own timelock: the proposal is done, the lane
    ///      points at the Base spoke pool and draws on the Base lockbox, and its verification is the local resolver.
    function test_the_base_lane_was_connected_by_a_lido_timelock_proposal() public {
        vm.skip(hubOnly);
        assertTrue(IRbacTimelockLike(lidoTimelock).isOperationDone(connectId), "lane connection proposal not done");
        assertTrue(IHubPoolLike(hub).isSupportedChain(baseSelector), "Base lane not supported");
        if (!hubOnly) assertEq(IHubPoolLike(hub).getLockBox(baseSelector), baseLockBox, "Base lane lockbox");
        bytes[] memory remotes = IHubPoolLike(hub).getRemotePools(baseSelector);
        assertEq(remotes.length, 1, "Base lane remote pools");
        assertEq(
            keccak256(remotes[0]), keccak256(abi.encode(baseSpokePool)), "Base lane remote pool is not the spoke pool"
        );
        for (uint256 i; i < connectCalls.length; ++i) {
            address t = connectCalls[i].target;
            assertTrue(
                t == hub || t == hooks || t == resolver || t == _verifier(),
                "a connection call targets a contract outside the hub stack"
            );
        }
        address[] memory outbound =
            IHooksLike(hooks).getRequiredCCVs(token, baseSelector, 1e18, WAIT_FOR_FINALITY, "", OUTBOUND);
        address[] memory inbound =
            IHooksLike(hooks).getRequiredCCVs(token, baseSelector, 1e18, WAIT_FOR_FINALITY, "", INBOUND);
        assertEq(outbound.length, 1, "Base outbound CCVs");
        assertEq(inbound.length, 1, "Base inbound CCVs");
        assertEq(outbound[0], resolver, "Base outbound CCV is not the resolver");
        assertEq(inbound[0], resolver, "Base inbound CCV is not the resolver");
    }

    function test_lane_connection_batch_cannot_be_executed_again() public {
        vm.skip(hubOnly);
        IRbacTimelockLike.Call[] memory calls = connectCalls;
        uint256[] memory before = _balances();
        uint256 lanesBefore = IHubPoolLike(hub).getSupportedChains().length;
        vm.expectRevert(bytes("RBACTimelock: operation is not ready"));
        IRbacTimelockLike(connectExecutor).executeBatch(calls, connectPredecessor, connectSalt);
        assertEq(IHubPoolLike(hub).getSupportedChains().length, lanesBefore, "lanes changed on a replay");
        _assertOthersUnchanged(before, address(0), "connection replay");
    }

    /// @dev The verifier address the connection calls configured, read from the hub record.
    function _verifier() internal view returns (address) {
        string memory dir = vm.envOr("RECORD_DIR", string("config/chains"));
        string memory l1 = vm.envOr("L1_CHAIN", string("ethereum"));
        return vm.parseJsonAddress(vm.readFile(string.concat(dir, "/", l1, ".json")), ".ccv.message_id_verifier");
    }

    function _indexOf(address box) internal view returns (uint256) {
        for (uint256 i; i < allLockBoxes.length; ++i) {
            if (allLockBoxes[i] == box) return i;
        }
        revert("unknown lockbox");
    }
}

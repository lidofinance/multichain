// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {PoolOperationManager} from "@ccip-lido/PoolOperationManager.sol";

import {BridgeScenarioBase} from "./BridgeScenarioBase.sol";

/// @title RealPomUpgrade
/// @notice Rehearses the actual UUPS upgrade entry point against both freshly deployed POM proxies.
/// The forks are ephemeral: the deployment record remains the pre-upgrade baseline.
contract RealPomUpgrade is BridgeScenarioBase {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 internal constant UPGRADE_MARKER = keccak256("wsteth-2.0 POM UUPS fork rehearsal");
    bytes4 internal constant UPGRADE_SELECTOR = 0x4f1ef286;
    bytes4 internal constant TRANSFER_OWNERSHIP_SELECTOR = 0xf2fde38b;
    bytes4 internal constant HOOKS_UNPAUSE_SELECTOR = 0xa6cc6ef9;
    bytes4 internal constant TRANSFER_ADMIN_ROLE_SELECTOR = 0xddadfa8e;
    bytes4 internal constant SET_POOL_SELECTOR = 0x4e847fc7;
    bytes4 internal constant POOL_SET_DYNAMIC_CONFIG_SELECTOR = 0xae39a257;
    bytes4 internal constant CCV_SET_DYNAMIC_CONFIG_SELECTOR = 0x869b7f62;
    bytes4 internal constant UPDATE_HOOKS_SELECTOR = 0xbfeffd3f;
    bytes4 internal constant CONFIGURE_LOCKBOXES_SELECTOR = 0xefd07eec;

    function setUp() public {
        _setUpForksAndRecord();
    }

    function test_L1PomUupsUpgradePreservesState() public {
        vm.selectFork(l1Fork);
        _rehearseUpgrade(l1, "L1");
    }

    function test_L2PomUupsUpgradePreservesState() public {
        vm.selectFork(l2Fork);
        _rehearseUpgrade(l2, "L2");
    }

    function _rehearseUpgrade(Ctx storage c, string memory chainLabel) internal {
        PoolOperationManager manager = PoolOperationManager(payable(c.pom));
        address oldImplementation = _implementationOf(c.pom);
        require(oldImplementation.code.length > 0, string.concat(chainLabel, ": POM implementation has no code"));
        assertEq(manager.UPGRADE_INTERFACE_VERSION(), "5.0.0", string.concat(chainLabel, ": UUPS interface"));
        assertEq(
            PoolOperationManager(oldImplementation).proxiableUUID(),
            ERC1967Utils.IMPLEMENTATION_SLOT,
            string.concat(chainLabel, ": proxiable UUID")
        );
        assertEq(
            manager.isSelectorBlocked(UPGRADE_SELECTOR), true, string.concat(chainLabel, ": upgrade selector policy")
        );

        Snapshot memory before_ = _snapshot(manager);
        PomUpgradeRehearsalV2 next = new PomUpgradeRehearsalV2();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), DEFAULT_ADMIN_ROLE
            )
        );
        manager.upgradeToAndCall(address(next), "");

        vm.prank(c.govAdmin);
        vm.expectEmit(true, true, true, true, c.pom);
        emit IERC1967.Upgraded(address(next));
        manager.upgradeToAndCall(address(next), abi.encodeCall(PomUpgradeRehearsalV2.initializeV2, (UPGRADE_MARKER)));

        assertEq(_implementationOf(c.pom), address(next), string.concat(chainLabel, ": implementation slot"));
        PomUpgradeRehearsalV2 upgraded = PomUpgradeRehearsalV2(payable(c.pom));
        assertEq(
            upgraded.typeAndVersion(), "PoolOperationManager 2.0.0-rehearsal", string.concat(chainLabel, ": version")
        );
        assertEq(upgraded.upgradeMarker(), UPGRADE_MARKER, string.concat(chainLabel, ": reinitializer"));
        _assertSnapshot(manager, before_, chainLabel);
    }

    struct Snapshot {
        address tokenPool;
        address hooks;
        uint40 minDelay;
        uint40 expiryPeriod;
        uint24 epoch;
        bool upgradeMode;
        bool ownershipMode;
        bool hooksUnpauseMode;
        uint40 transferAdminRoleDelay;
        uint40 setPoolDelay;
        uint40 poolDynamicConfigDelay;
        uint40 ccvDynamicConfigDelay;
        uint40 updateHooksDelay;
        uint40 configureLockboxesDelay;
        bool paused;
        address[] admins;
        address[] proposers;
        address[] queueHalters;
        address[] transferPausers;
        address[] queueRestarters;
        address[] transferUnpausers;
        address[] executors;
    }

    function _snapshot(PoolOperationManager manager) internal view returns (Snapshot memory s) {
        s.tokenPool = manager.getTokenPool();
        s.hooks = manager.getAdvancedPoolHooks();
        s.minDelay = manager.getGlobalMinDelay();
        s.expiryPeriod = manager.getGlobalExpiryPeriod();
        s.epoch = manager.getEpoch();
        s.upgradeMode = manager.isSelectorBlocked(UPGRADE_SELECTOR);
        s.ownershipMode = manager.isSelectorBlocked(TRANSFER_OWNERSHIP_SELECTOR);
        s.hooksUnpauseMode = manager.isSelectorBlocked(HOOKS_UNPAUSE_SELECTOR);
        s.transferAdminRoleDelay = manager.getSelectorMinDelay(TRANSFER_ADMIN_ROLE_SELECTOR);
        s.setPoolDelay = manager.getSelectorMinDelay(SET_POOL_SELECTOR);
        s.poolDynamicConfigDelay = manager.getSelectorMinDelay(POOL_SET_DYNAMIC_CONFIG_SELECTOR);
        s.ccvDynamicConfigDelay = manager.getSelectorMinDelay(CCV_SET_DYNAMIC_CONFIG_SELECTOR);
        s.updateHooksDelay = manager.getSelectorMinDelay(UPDATE_HOOKS_SELECTOR);
        s.configureLockboxesDelay = manager.getSelectorMinDelay(CONFIGURE_LOCKBOXES_SELECTOR);
        s.paused = manager.paused();
        s.admins = manager.getRoleMembers(DEFAULT_ADMIN_ROLE);
        s.proposers = manager.getRoleMembers(manager.PROPOSER_ROLE());
        s.queueHalters = manager.getRoleMembers(manager.PROPOSAL_QUEUE_HALT_ROLE());
        s.transferPausers = manager.getRoleMembers(manager.CROSS_CHAIN_TRANSFERS_PAUSE_ROLE());
        s.queueRestarters = manager.getRoleMembers(manager.PROPOSAL_QUEUE_RESTART_ROLE());
        s.transferUnpausers = manager.getRoleMembers(manager.CROSS_CHAIN_TRANSFERS_UNPAUSE_ROLE());
        s.executors = manager.getRoleMembers(manager.EXECUTOR_ROLE());
    }

    function _assertSnapshot(PoolOperationManager manager, Snapshot memory before_, string memory chainLabel)
        internal
        view
    {
        Snapshot memory after_ = _snapshot(manager);
        assertEq(after_.tokenPool, before_.tokenPool, string.concat(chainLabel, ": token pool preserved"));
        assertEq(after_.hooks, before_.hooks, string.concat(chainLabel, ": hooks preserved"));
        assertEq(after_.minDelay, before_.minDelay, string.concat(chainLabel, ": min delay preserved"));
        assertEq(after_.expiryPeriod, before_.expiryPeriod, string.concat(chainLabel, ": expiry preserved"));
        assertEq(after_.epoch, before_.epoch, string.concat(chainLabel, ": epoch preserved"));
        assertEq(after_.upgradeMode, before_.upgradeMode, string.concat(chainLabel, ": UUPS mode preserved"));
        assertEq(after_.ownershipMode, before_.ownershipMode, string.concat(chainLabel, ": ownership mode preserved"));
        assertEq(
            after_.hooksUnpauseMode,
            before_.hooksUnpauseMode,
            string.concat(chainLabel, ": hooks unpause mode preserved")
        );
        assertEq(
            after_.transferAdminRoleDelay,
            before_.transferAdminRoleDelay,
            string.concat(chainLabel, ": TAR transfer-admin delay preserved")
        );
        assertEq(after_.setPoolDelay, before_.setPoolDelay, string.concat(chainLabel, ": TAR set-pool delay preserved"));
        assertEq(
            after_.poolDynamicConfigDelay,
            before_.poolDynamicConfigDelay,
            string.concat(chainLabel, ": pool dynamic-config delay preserved")
        );
        assertEq(
            after_.ccvDynamicConfigDelay,
            before_.ccvDynamicConfigDelay,
            string.concat(chainLabel, ": CCV dynamic-config delay preserved")
        );
        assertEq(
            after_.updateHooksDelay,
            before_.updateHooksDelay,
            string.concat(chainLabel, ": hooks update delay preserved")
        );
        assertEq(
            after_.configureLockboxesDelay,
            before_.configureLockboxesDelay,
            string.concat(chainLabel, ": lockbox config delay preserved")
        );
        assertEq(after_.paused, before_.paused, string.concat(chainLabel, ": pause state preserved"));
        assertEq(after_.admins, before_.admins, string.concat(chainLabel, ": admins preserved"));
        assertEq(after_.proposers, before_.proposers, string.concat(chainLabel, ": proposers preserved"));
        assertEq(after_.queueHalters, before_.queueHalters, string.concat(chainLabel, ": queue halters preserved"));
        assertEq(
            after_.transferPausers, before_.transferPausers, string.concat(chainLabel, ": transfer pausers preserved")
        );
        assertEq(
            after_.queueRestarters, before_.queueRestarters, string.concat(chainLabel, ": queue restarters preserved")
        );
        assertEq(
            after_.transferUnpausers,
            before_.transferUnpausers,
            string.concat(chainLabel, ": transfer unpausers preserved")
        );
        assertEq(after_.executors, before_.executors, string.concat(chainLabel, ": executors preserved"));
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }
}

/// @dev Disposable future implementation used only by the fork rehearsal.
contract PomUpgradeRehearsalV2 is PoolOperationManager {
    /// @custom:storage-location erc7201:wsteth-2.0.storage.PomUpgradeRehearsalV2
    struct RehearsalStorage {
        bytes32 marker;
    }

    bytes32 private constant REHEARSAL_STORAGE_LOCATION =
        0xddba8bc27d0ce9d08ac08cb0211a4bd49a88d3100152ffbf0538a3ad114f9400;

    function initializeV2(bytes32 marker) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        _getRehearsalStorage().marker = marker;
    }

    function upgradeMarker() external view returns (bytes32) {
        return _getRehearsalStorage().marker;
    }

    function typeAndVersion() external pure override returns (string memory) {
        return "PoolOperationManager 2.0.0-rehearsal";
    }

    function _getRehearsalStorage() private pure returns (RehearsalStorage storage s) {
        bytes32 location = REHEARSAL_STORAGE_LOCATION;
        assembly {
            s.slot := location
        }
    }
}

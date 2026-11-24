// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {HubMigrationBase} from "./HubMigrationBase.sol";
import {ILidoTimelock} from "@ccip-lido/interfaces/ILidoTimelock.sol";
import {IERC20Metadata} from "@openzeppelin/contracts@5.3.0/token/ERC20/extensions/IERC20Metadata.sol";

contract DeployHubForMigration is HubMigrationBase {
    function setUp() public {
        _loadMigration(false, false);
    }

    function run() public {
        _revertIfBroadcastingWithTestKey(s_deployerPrivateKey);
        _revertIfAlreadyDeployed(s_chainConfigPath);
        vm.startBroadcast(s_deployerPrivateKey);
        _deployLockBoxes();
        s_deployed.token_pool = _deployArtifact(
            "SiloedLockReleaseTokenPool",
            abi.encode(
                s_chainConfig.addresses.token,
                IERC20Metadata(s_chainConfig.addresses.token).decimals(),
                address(0),
                s_ccip.rmn_proxy,
                s_ccip.router
            )
        );
        address[] memory callers = new address[](1);
        callers[0] = s_deployed.token_pool;
        address[] memory pausers = new address[](1);
        pausers[0] = s_chainConfig.governance_addresses.emergency_brakes;
        s_deployed.advanced_pool_hooks = _deployArtifact(
            "PausableAdvancedPoolHooks",
            abi.encode(new address[](0), uint256(0), address(0), callers, pausers, new address[](0))
        );
        _deployTimelock();
        vm.stopBroadcast();
        _saveResults();
    }

    function _deployLockBoxes() internal {
        PoolType poolType = s_chainConfig.chain.pool_type;
        if (poolType == PoolType.SiloedLockRelease) {
            address sharedLockBox;

            for (uint256 i; i < s_chainConfig.remote_lanes.length; i++) {
                RemoteLane memory lane = s_chainConfig.remote_lanes[i];
                if (_isDeferredLane(lane.remote_chain_name)) continue;
                address lockBox;

                if (lane.is_siloed) {
                    lockBox = _deployLockBox();
                } else {
                    if (sharedLockBox == address(0)) {
                        sharedLockBox = _deployLockBox();
                    }
                    lockBox = sharedLockBox;
                }

                s_deployed.lock_boxes.push(LockBoxEntry({lock_box: lockBox, remote_chain_name: lane.remote_chain_name}));
            }
        }
    }

    function _deployTimelock() internal {
        GovernanceAddresses memory governance = s_chainConfig.governance_addresses;
        address[] memory proposers = new address[](1);
        proposers[0] = governance.chainlink_mcms;
        address[] memory cancellers = new address[](2);
        cancellers[0] = governance.emergency_brakes;
        cancellers[1] = governance.chainlink_mcms;
        address[] memory proposalQueueHalters = new address[](1);
        proposalQueueHalters[0] = governance.emergency_brakes;

        // There are no bypassers besides the admin.
        s_deployed.timelock = _deployArtifact(
            "LidoTimelock",
            abi.encode(
                uint256(s_defaultConfig.governance.min_delay_seconds),
                s_defaultConfig.governance.expiry_period_seconds,
                s_deployer,
                proposers,
                new address[](0),
                cancellers,
                new address[](0),
                proposalQueueHalters
            )
        );

        ILidoTimelock timelock = ILidoTimelock(s_deployed.timelock);
        s_deployed.call_proxy = _deployArtifact("CallProxy", abi.encode(address(timelock)));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), s_deployed.call_proxy);
    }
}

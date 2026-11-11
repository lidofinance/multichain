// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
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

import {HubMigrationBase} from "./HubMigrationBase.sol";
import {ISiloedLockReleaseTokenPool} from "@ccip-lido/script/lib/ISiloedLockReleaseTokenPool.sol";

import {PausableAdvancedPoolHooks} from "@ccip-lido/PausableAdvancedPoolHooks.sol";

import {DummyMessageIdVerifier} from "@ccip-lido/ccvs/DummyMessageIdVerifier.sol";
import {ILidoTimelock} from "@ccip-lido/interfaces/ILidoTimelock.sol";

contract ConfigureHubForMigration is HubMigrationBase {
    mapping(address => bool) internal s_configuredLockBoxes;
    mapping(address => bool) internal s_transferredLockBoxes;

    function setUp() public {
        _loadMigration(true, false);
    }

    function run() public {
        _revertIfBroadcastingWithTestKey(s_deployerPrivateKey);
        require(s_ccv.message_id_verifier == address(0) && s_ccv.verifier_resolver == address(0), "Premature hub CCVs");
        vm.startBroadcast(s_deployerPrivateKey);
        _configureTokenPool();
        _configureLockBoxes();
        PausableAdvancedPoolHooks(payable(s_deployed.advanced_pool_hooks))
            .setThresholdAmount(vm.envOr("CCV_THRESHOLD_AMOUNT", uint256(0)));
        _configureBlockedSelectors();
        _transferOwnershipToTimelock();
        vm.stopBroadcast();
    }

    function _configureTokenPool() internal {
        TokenPool(s_deployed.token_pool).updateAdvancedPoolHooks(IAdvancedPoolHooks(s_deployed.advanced_pool_hooks));

        uint256 count = _lanesConfiguredHere();
        TokenPool.ChainUpdate[] memory chainUpdates = new TokenPool.ChainUpdate[](count);
        TokenPool.TokenTransferFeeConfigArgs[] memory tokenTransferFeeConfigs =
            new TokenPool.TokenTransferFeeConfigArgs[](count);
        uint256 configured;

        for (uint256 i; i < s_chainConfig.remote_lanes.length; i++) {
            string memory remoteName = s_chainConfig.remote_lanes[i].remote_chain_name;
            if (_isDeferredLane(remoteName)) continue;
            chainUpdates[configured] = _chainUpdateFor(remoteName);
            tokenTransferFeeConfigs[configured++] = _feeConfigFor(remoteName);
        }

        if (count > 0) {
            TokenPool(s_deployed.token_pool).applyChainUpdates(new uint64[](0), chainUpdates);
            TokenPool(s_deployed.token_pool)
                .applyTokenTransferFeeConfigUpdates(tokenTransferFeeConfigs, new uint64[](0));
        }
    }

    function _configureLockBoxes() internal {
        if (s_chainConfig.chain.pool_type != PoolType.SiloedLockRelease || s_deployed.lock_boxes.length == 0) return;

        address[] memory callers = new address[](1);
        callers[0] = s_deployed.token_pool;

        uint256 bound;
        for (uint256 i; i < s_deployed.lock_boxes.length; i++) {
            if (!_isDeferredLane(s_deployed.lock_boxes[i].remote_chain_name)) bound++;
        }
        ISiloedLockReleaseTokenPool.LockBoxConfig[] memory lockBoxConfigs =
            new ISiloedLockReleaseTokenPool.LockBoxConfig[](bound);
        uint256 configured;

        for (uint256 i; i < s_deployed.lock_boxes.length; i++) {
            LockBoxEntry memory entry = s_deployed.lock_boxes[i];
            // Every lockbox authorizes the pool once, a deferred lane's included: when the owner binds that lane, its
            // lockbox is already the pool's.
            if (!s_configuredLockBoxes[entry.lock_box]) {
                s_configuredLockBoxes[entry.lock_box] = true;
                AuthorizedCallers(entry.lock_box)
                    .applyAuthorizedCallerUpdates(
                        AuthorizedCallers.AuthorizedCallerArgs({
                            addedCallers: callers, removedCallers: new address[](0)
                        })
                    );
            }
            if (_isDeferredLane(entry.remote_chain_name)) continue;
            lockBoxConfigs[configured++] = _lockBoxConfigFor(entry.remote_chain_name);
        }

        if (bound > 0) {
            ISiloedLockReleaseTokenPool(s_deployed.token_pool).configureLockBoxes(lockBoxConfigs);
        }
    }

    function _configureBlockedSelectors() internal {
        ILidoTimelock timelock = ILidoTimelock(s_deployed.timelock);
        for (uint256 i; i < s_defaultConfig.blocked_selectors.length; i++) {
            timelock.blockFunctionSelector(s_defaultConfig.blocked_selectors[i].selector);
        }
    }

    function _transferOwnershipToTimelock() internal {
        address timelock = s_deployed.timelock;
        uint256 count = 2;
        address[] memory owned = new address[](count + s_deployed.lock_boxes.length);
        owned[0] = s_deployed.token_pool;
        owned[1] = s_deployed.advanced_pool_hooks;
        for (uint256 i; i < s_deployed.lock_boxes.length; i++) {
            address lockBox = s_deployed.lock_boxes[i].lock_box;
            if (s_transferredLockBoxes[lockBox]) continue;
            s_transferredLockBoxes[lockBox] = true;
            owned[count++] = lockBox;
        }

        ILidoTimelock.Call[] memory accepts = new ILidoTimelock.Call[](count);
        for (uint256 i; i < count; i++) {
            Ownable2Step(owned[i]).transferOwnership(timelock);
            accepts[i] = ILidoTimelock.Call(owned[i], 0, abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        }
        ILidoTimelock(timelock).bypasserExecuteBatch(accepts);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DummyMessageIdVerifier} from "@ccip-lido/ccvs/DummyMessageIdVerifier.sol";
import {ILidoTimelock} from "@ccip-lido/interfaces/ILidoTimelock.sol";
import {HubMigrationBase} from "./HubMigrationBase.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/ccvs/VersionedVerifierResolver.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";
import {Ownable2Step} from "@chainlink/contracts/src/v0.8/shared/access/Ownable2Step.sol";

/// @notice Prepare an isolated deferred lane after an imported-only hub has been handed over.
/// Existing pool, hooks, lockboxes and governance are never reconfigured. The new contracts'
/// ownership is offered to the existing timelock; the emitted acceptOwnership calls need its proposal.
contract PrepareHubLane is HubMigrationBase {
    function setUp() public {
        _loadMigration(true, false);
    }

    function run() public {
        _revertIfBroadcastingWithTestKey(s_deployerPrivateKey);
        require(block.chainid == s_chainConfig.chain.chain_id, "Chain ID mismatch");
        require(s_chainConfig.chain.pool_type == PoolType.SiloedLockRelease, "Expected lock/release hub");
        string memory lane = vm.envString("LANE");
        require(_isDeferredLane(lane), "Lane must be deferred");
        bool isolated;
        for (uint256 i; i < s_chainConfig.remote_lanes.length; ++i) {
            if (keccak256(bytes(s_chainConfig.remote_lanes[i].remote_chain_name)) == keccak256(bytes(lane))) {
                isolated = s_chainConfig.remote_lanes[i].is_siloed;
            }
        }
        require(isolated, "This preparation requires isolated lane custody");
        require(
            s_ccv.message_id_verifier == address(0) && s_ccv.verifier_resolver == address(0), "CCV stack already exists"
        );
        for (uint256 i; i < s_deployed.lock_boxes.length; ++i) {
            require(
                keccak256(bytes(s_deployed.lock_boxes[i].remote_chain_name)) != keccak256(bytes(lane)),
                "Lockbox already exists"
            );
        }
        ILidoTimelock timelock = ILidoTimelock(s_deployed.timelock);
        require(!timelock.hasRole(timelock.ADMIN_ROLE(), s_deployer), "Deployer still administers the hub");
        require(
            timelock.hasRole(timelock.ADMIN_ROLE(), s_chainConfig.governance_addresses.lido_dao_agent),
            "DAO admin missing"
        );
        require(Ownable2Step(s_deployed.token_pool).owner() == address(timelock), "Hub ownership not handed over");

        vm.startBroadcast(s_deployerPrivateKey);
        address box = _deployLockBox();
        s_deployed.lock_boxes.push(LockBoxEntry({lock_box: box, remote_chain_name: lane}));
        address[] memory callers = new address[](1);
        callers[0] = s_deployed.token_pool;
        AuthorizedCallers(box)
            .applyAuthorizedCallerUpdates(
                AuthorizedCallers.AuthorizedCallerArgs({addedCallers: callers, removedCallers: new address[](0)})
            );
        _deployCCVStack();
        VersionedVerifierResolver.InboundImplementationArgs[] memory inbound =
            new VersionedVerifierResolver.InboundImplementationArgs[](1);
        inbound[0] = VersionedVerifierResolver.InboundImplementationArgs({
            version: DummyMessageIdVerifier(s_ccv.message_id_verifier).versionTag(), verifier: s_ccv.message_id_verifier
        });
        VersionedVerifierResolver(s_ccv.verifier_resolver).applyInboundImplementationUpdates(inbound);
        VersionedVerifierResolver(s_ccv.verifier_resolver)
            .setFeeAggregator(vm.envOr("FEE_AGGREGATOR", s_chainConfig.governance_addresses.lido_dao_agent));
        address[3] memory owned = [box, s_ccv.message_id_verifier, s_ccv.verifier_resolver];
        for (uint256 i; i < owned.length; ++i) {
            Ownable2Step(owned[i]).transferOwnership(address(timelock));
        }
        vm.stopBroadcast();

        _saveResults();
        string memory calls;
        for (uint256 i; i < owned.length; ++i) {
            calls = string.concat(
                calls,
                i == 0 ? "" : ",",
                '{"target":"',
                vm.toString(owned[i]),
                '","value":"0","data":"',
                vm.toString(abi.encodeCall(Ownable2Step.acceptOwnership, ())),
                '"}'
            );
        }
        _writeJsonUnlessDryRun(
            string.concat('{"calls":[', calls, "]}"),
            string.concat(_getDirectory(s_chainConfigPath), "/lane-preparation.json")
        );
    }
}

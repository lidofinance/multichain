// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {MessageV1Codec} from "@chainlink/contracts-ccip/libraries/MessageV1Codec.sol";

import {MockCCV} from "../mocks/MockCCV.sol";

import {
    DualCcvBase,
    DualCcvDeployment,
    IBalance,
    ICommitteeVerifier,
    IHooksCcv,
    IOffRampReplay,
    IOwned,
    IVerifierResolver
} from "./DualCcvBase.sol";
import {DualCcvFixtures} from "./DualCcvFixtures.sol";

/// @title Replay of four wstETH transfers with published Chainlink and Nethermind attestations
/// @notice Each fixture starts one block before its recorded destination delivery. Group A checks how
/// the deployed contracts handle the submitted message and proofs. Group F checks how later changes
/// to state or time affect delivery. Case IDs refer to docs/NETHERMIND-CCV-FORK-TEST-PLAN.md.
/// Set RPC_SEPOLIA, RPC_MANTLE_SEPOLIA and RPC_BASE_SEPOLIA to archive endpoints.
contract RealDualCcvReplayTest is DualCcvBase {
    address internal constant NM = DualCcvFixtures.NETHERMIND_RESOLVER;
    address internal constant CL = DualCcvFixtures.CHAINLINK_RESOLVER;

    // ═════════════════════════ A-1 … A-3: both proofs are needed ═════════════════════════

    function test_A01_both_proofs_execute() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            _executeBothAndAssertDelivered(f);
        }
    }

    function test_A02_chainlink_proof_alone_does_not_execute() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            (address[] memory ccvs, bytes[] memory proofs) = _single(CL, f.chainlinkProof);
            _assertRejected(f, f.encodedMessage, ccvs, proofs, REQUIRED_CCV_MISSING, "A-2");
            // Same fork, same message: the missing attestation was the only obstacle.
            _executeBothAndAssertDelivered(f);
        }
    }

    function test_A03_nethermind_proof_alone_does_not_execute() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            (address[] memory ccvs, bytes[] memory proofs) = _single(NM, f.nethermindProof);
            _assertRejected(f, f.encodedMessage, ccvs, proofs, REQUIRED_CCV_MISSING, "A-3");
            _executeBothAndAssertDelivered(f);
        }
    }

    // ═════════════════════════ A-4, A-5: a proof of another kind in the Nethermind slot ═════════════════════════

    /// @notice The retired dummy proof opens nothing: neither under the old resolver address nor under the
    /// Nethermind resolver address.
    function test_A04_dummy_proof_is_not_accepted() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            bytes memory dummy = abi.encodePacked(DualCcvDeployment.DUMMY_TAG, f.messageId);
            address oldResolver = DualCcvDeployment.byRpcEnv(f.rpcEnv).oldResolver;

            (address[] memory ccvs, bytes[] memory proofs) = _pair(CL, f.chainlinkProof, oldResolver, dummy);
            _assertRejected(f, f.encodedMessage, ccvs, proofs, REQUIRED_CCV_MISSING, "A-4 old resolver");
            _executeBothAndAssertDelivered(f);
        }
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            bytes memory dummy = abi.encodePacked(DualCcvDeployment.DUMMY_TAG, f.messageId);
            (address[] memory ccvs, bytes[] memory proofs) = _pair(CL, f.chainlinkProof, NM, dummy);
            _assertRejected(f, f.encodedMessage, ccvs, proofs, INBOUND_IMPL_NOT_FOUND, "A-4 dummy under Nethermind");
        }
    }

    /// @notice One provider's proof cannot stand in for the other's.
    function test_A05_one_providers_proof_in_both_slots() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            (address[] memory ccvs, bytes[] memory proofs) = _pair(CL, f.chainlinkProof, NM, f.chainlinkProof);
            _assertRejected(f, f.encodedMessage, ccvs, proofs, INBOUND_IMPL_NOT_FOUND, "A-5 Chainlink proof twice");
            _executeBothAndAssertDelivered(f);
        }
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            (address[] memory ccvs, bytes[] memory proofs) = _pair(CL, f.nethermindProof, NM, f.nethermindProof);
            _assertRejected(f, f.encodedMessage, ccvs, proofs, INBOUND_IMPL_NOT_FOUND, "A-5 Nethermind proof twice");
        }
        // The same resolver listed twice does not count as two CCVs.
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            (address[] memory ccvs, bytes[] memory proofs) = _pair(CL, f.chainlinkProof, CL, f.chainlinkProof);
            _assertRejected(f, f.encodedMessage, ccvs, proofs, REQUIRED_CCV_MISSING, "A-5 Chainlink resolver twice");
        }
    }

    // ═════════════════════════ A-6, A-7: a real proof of another message ═════════════════════════

    /// @notice A proof is bound to its message. Fixtures 0/1 are the two deposits (different destination chains),
    /// fixtures 2/3 the two withdrawals (same destination chain and OffRamp, different source lanes).
    function test_A06_A07_proof_of_another_message() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory other = DualCcvFixtures.get(i ^ 1);

            DualCcvFixtures.Fixture memory f = _fork(i);
            (address[] memory ccvs, bytes[] memory proofs) = _pair(CL, f.chainlinkProof, NM, other.nethermindProof);
            _assertRejected(f, f.encodedMessage, ccvs, proofs, UNAUTHORIZED_SIGNER, "A-6/7 foreign Nethermind proof");
            _executeBothAndAssertDelivered(f);

            f = _fork(i);
            (ccvs, proofs) = _pair(CL, other.chainlinkProof, NM, f.nethermindProof);
            _assertRejected(f, f.encodedMessage, ccvs, proofs, UNAUTHORIZED_SIGNER, "A-6/7 foreign Chainlink proof");
        }
    }

    // ═════════════════════════ A-8 … A-10: real proofs, altered message ═════════════════════════

    function test_A08_amount_changed() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            MessageV1Codec.MessageV1 memory m = _decode(f.encodedMessage);
            assertEq(keccak256(_encode(m)), f.messageId, "re-encoding must reproduce the message");
            assertEq(m.tokenTransfer[0].amount, f.amount, "fixture amount");
            m.tokenTransfer[0].amount = f.amount * 1000;
            _assertAlteredRejected(f, _encode(m), "A-8 amount x1000");
        }
    }

    function test_A09_receiver_changed() public {
        address thief = makeAddr("thief");
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            MessageV1Codec.MessageV1 memory m = _decode(f.encodedMessage);
            m.tokenTransfer[0].tokenReceiver = abi.encodePacked(thief);
            _assertAlteredRejected(f, _encode(m), "A-9 token receiver");
            assertEq(IBalance(f.token).balanceOf(thief), 0, "A-9: altered receiver got tokens");

            f = _fork(i);
            m = _decode(f.encodedMessage);
            m.receiver = abi.encodePacked(thief);
            _assertAlteredRejected(f, _encode(m), "A-9 message receiver");
        }
    }

    function test_A10_other_fields_changed() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            MessageV1Codec.MessageV1 memory m = _decode(f.encodedMessage);
            // A destination token without a pool: the CCV list then comes from the OffRamp defaults, not from the
            // wstETH hooks, so the outcome is recorded rather than pinned to one reason.
            m.tokenTransfer[0].destTokenAddress = abi.encodePacked(makeAddr("otherToken"));
            bytes memory altered = _encode(m);
            (address[] memory ccvs, bytes[] memory proofs) = _both(f);
            uint256 before = IBalance(f.token).balanceOf(f.recipient);
            Outcome memory o = _execute(f.offRamp, altered, ccvs, proofs);
            assertTrue(o.reverted || o.state == FAILURE, "A-10 destination token: executed");
            assertEq(IBalance(f.token).balanceOf(f.recipient), before, "A-10 destination token: tokens moved");

            f = _fork(i);
            m = _decode(f.encodedMessage);
            m.messageNumber += 1;
            _assertAlteredRejected(f, _encode(m), "A-10 message number");

            f = _fork(i);
            m = _decode(f.encodedMessage);
            m.sender = abi.encode(makeAddr("otherSender"));
            _assertAlteredRejected(f, _encode(m), "A-10 sender");

            f = _fork(i);
            m = _decode(f.encodedMessage);
            m.finality = bytes4(uint32(1));
            _assertAlteredRejected(f, _encode(m), "A-10 finality");
        }
    }

    // ═════════════════════════ A-11, A-12: damaged Nethermind proof ═════════════════════════

    function test_A11_signature_byte_flipped() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            // One byte in the first signature, then one in the second.
            for (uint256 at = 10; at <= 74; at += 64) {
                DualCcvFixtures.Fixture memory f = _fork(i);
                bytes memory damaged = bytes.concat(f.nethermindProof);
                damaged[at] = bytes1(uint8(damaged[at]) ^ 0x01);
                (address[] memory ccvs, bytes[] memory proofs) = _pair(CL, f.chainlinkProof, NM, damaged);
                _assertRejected(f, f.encodedMessage, ccvs, proofs, UNAUTHORIZED_SIGNER, "A-11 flipped byte");
            }
        }
    }

    function test_A12_signature_set_malformed() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = DualCcvFixtures.get(i);
            assertEq(f.nethermindProof.length, 4 + 2 + 128, "fixture: Nethermind proof is tag, length, two signatures");
            bytes memory head = abi.encodePacked(DualCcvDeployment.NETHERMIND_TAG, uint16(128));
            bytes memory sig1 = _slice(f.nethermindProof, 6, 64);
            bytes memory sig2 = _slice(f.nethermindProof, 70, 64);

            _damagedNethermind(i, bytes.concat(head, sig1, sig1), NON_ORDERED_SIGNATURES, "A-12 first signature twice");
            _damagedNethermind(i, bytes.concat(head, sig2, sig2), NON_ORDERED_SIGNATURES, "A-12 second signature twice");
            _damagedNethermind(i, bytes.concat(head, sig2, sig1), NON_ORDERED_SIGNATURES, "A-12 signatures swapped");
            _damagedNethermind(
                i,
                abi.encodePacked(DualCcvDeployment.NETHERMIND_TAG, uint16(64), sig1),
                WRONG_NUMBER_OF_SIGNATURES,
                "A-12 one signature of two"
            );
            _damagedNethermind(i, bytes.concat(head, sig1), INVALID_VERIFIER_RESULTS, "A-12 declared length too long");
            _damagedNethermind(
                i, abi.encodePacked(DualCcvDeployment.NETHERMIND_TAG, uint16(0)), WRONG_NUMBER_OF_SIGNATURES, "A-12 no signatures"
            );
            _damagedNethermind(i, abi.encodePacked(DualCcvDeployment.NETHERMIND_TAG), INVALID_VERIFIER_RESULTS, "A-12 tag only");
        }
    }

    /// @notice Recorded behaviour, not a defect by itself: bytes after the declared signatures are not checked, so
    /// one message has many acceptable proofs. Nothing may key on the proof bytes.
    function test_A12b_trailing_bytes_are_ignored() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            bytes memory padded = bytes.concat(f.nethermindProof, hex"deadbeef");
            (address[] memory ccvs, bytes[] memory proofs) = _pair(CL, f.chainlinkProof, NM, padded);
            uint256 before = IBalance(f.token).balanceOf(f.recipient);
            _assertSucceeded(_execute(f.offRamp, f.encodedMessage, ccvs, proofs), "A-12b trailing bytes");
            assertEq(IBalance(f.token).balanceOf(f.recipient) - before, f.amount, "A-12b: amount");
        }
    }

    // ═════════════════════════ A-13 … A-15: repetition, caller, wrong chain ═════════════════════════

    function test_A13_repeated_execution_reverts() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            _executeBothAndAssertDelivered(f);
            uint256 before = IBalance(f.token).balanceOf(f.recipient);
            (address[] memory ccvs, bytes[] memory proofs) = _both(f);
            Outcome memory o = _execute(f.offRamp, f.encodedMessage, ccvs, proofs);
            assertTrue(o.reverted, "A-13: second execution did not revert");
            assertEq(o.revertSelector, ALREADY_EXECUTED, "A-13: revert reason");
            assertEq(IBalance(f.token).balanceOf(f.recipient), before, "A-13: tokens delivered twice");
        }
    }

    /// @notice A message put into FAILURE by an incomplete call stays deliverable, and a second failing call
    /// reverts instead of recording anything.
    function test_A13b_failure_state_does_not_block_delivery() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            (address[] memory ccvs, bytes[] memory proofs) = _single(CL, f.chainlinkProof);
            vm.prank(makeAddr("griefer"));
            _assertFailed(_execute(f.offRamp, f.encodedMessage, ccvs, proofs), REQUIRED_CCV_MISSING, "A-13b first");
            Outcome memory o = _execute(f.offRamp, f.encodedMessage, ccvs, proofs);
            assertTrue(o.reverted, "A-13b: second failing call did not revert");
            assertEq(o.revertSelector, NO_STATE_PROGRESS, "A-13b: revert reason");
            assertEq(o.state, FAILURE, "A-13b: state");
            _executeBothAndAssertDelivered(f);
        }
    }

    function test_A14_any_caller_can_execute() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            uint256 before = IBalance(f.token).balanceOf(f.recipient);
            (address[] memory ccvs, bytes[] memory proofs) = _both(f);
            vm.prank(makeAddr("stranger"));
            IOffRampReplay(f.offRamp).execute(f.encodedMessage, ccvs, proofs, 0);
            assertEq(IOffRampReplay(f.offRamp).getExecutionState(f.messageId), SUCCESS, "A-14: state");
            assertEq(IBalance(f.token).balanceOf(f.recipient) - before, f.amount, "A-14: amount");
        }
    }

    /// @notice Each message, with its real proofs, handed to the OffRamps of the three other fixtures.
    function test_A15_message_on_another_offramp() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = DualCcvFixtures.get(i);
            for (uint256 j = 0; j < DualCcvFixtures.COUNT; ++j) {
                DualCcvFixtures.Fixture memory host = DualCcvFixtures.get(j);
                if (host.offRamp == f.offRamp) continue;
                vm.createSelectFork(vm.envString(host.rpcEnv), host.forkBlock);
                uint256 before = IBalance(host.token).balanceOf(f.recipient);
                (address[] memory ccvs, bytes[] memory proofs) = _both(f);
                Outcome memory o = _execute(host.offRamp, f.encodedMessage, ccvs, proofs);
                assertTrue(o.reverted, string.concat("A-15 ", f.name, " on ", host.name, ": did not revert"));
                assertEq(o.state, UNTOUCHED, "A-15: state");
                assertEq(IBalance(host.token).balanceOf(f.recipient), before, "A-15: tokens moved");
            }
        }
    }

    // ═════════════════════════ F: one owner action, then real proofs ═════════════════════════

    function test_F01_paused_hooks_block_execution_until_unpause() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            address hooks = DualCcvDeployment.byRpcEnv(f.rpcEnv).hooks;
            address owner = IOwned(hooks).owner();
            vm.prank(owner);
            IHooksCcv(hooks).pauseCrossChainTransfers();

            (address[] memory ccvs, bytes[] memory proofs) = _both(f);
            uint256 before = IBalance(f.token).balanceOf(f.recipient);
            Outcome memory o = _execute(f.offRamp, f.encodedMessage, ccvs, proofs);
            _assertFailed(o, TOKEN_HANDLING_ERROR, "F-1 paused");
            assertTrue(_contains(o.returnData, ENFORCED_PAUSE), "F-1: failure is not the pause");
            assertEq(IBalance(f.token).balanceOf(f.recipient), before, "F-1: tokens moved while paused");

            vm.prank(owner);
            IHooksCcv(hooks).unpauseCrossChainTransfers();
            _executeBothAndAssertDelivered(f);
        }
    }

    /// @notice Hooks returned to the previous policy while a message signed under the new one is in flight.
    function test_F02_list_returned_to_old_policy() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            DualCcvDeployment.Chain memory c = DualCcvDeployment.byRpcEnv(f.rpcEnv);
            _setInboundCcvs(c.hooks, _decode(f.encodedMessage).sourceChainSelector, _list(c.oldResolver, CL));

            // The two real proofs no longer satisfy the list…
            (address[] memory ccvs, bytes[] memory proofs) = _both(f);
            _assertRejected(f, f.encodedMessage, ccvs, proofs, REQUIRED_CCV_MISSING, "F-2 both real proofs");

            // …and the message completes with the Chainlink proof plus a dummy proof that anyone can build.
            (ccvs, proofs) = _pair(CL, f.chainlinkProof, c.oldResolver, abi.encodePacked(DualCcvDeployment.DUMMY_TAG, f.messageId));
            uint256 before = IBalance(f.token).balanceOf(f.recipient);
            vm.prank(makeAddr("stranger"));
            IOffRampReplay(f.offRamp).execute(f.encodedMessage, ccvs, proofs, 0);
            assertEq(IOffRampReplay(f.offRamp).getExecutionState(f.messageId), SUCCESS, "F-2: state");
            assertEq(IBalance(f.token).balanceOf(f.recipient) - before, f.amount, "F-2: amount");
        }
    }

    /// @notice The inbound list alone decides what is required: what the message was sent with does not matter.
    function test_F04_single_ccv_inbound_list() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            DualCcvDeployment.Chain memory c = DualCcvDeployment.byRpcEnv(f.rpcEnv);
            uint64 source = _decode(f.encodedMessage).sourceChainSelector;

            _setInboundCcvs(c.hooks, source, _list(CL));
            // Chainlink alone still binds the content…
            MessageV1Codec.MessageV1 memory m = _decode(f.encodedMessage);
            m.tokenTransfer[0].amount = f.amount * 1000;
            (address[] memory ccvs, bytes[] memory proofs) = _single(CL, f.chainlinkProof);
            _assertRejected(f, _encode(m), ccvs, proofs, UNAUTHORIZED_SIGNER, "F-4 Chainlink only, altered amount");
            // …and delivers the real message without Nethermind.
            uint256 before = IBalance(f.token).balanceOf(f.recipient);
            _assertSucceeded(_execute(f.offRamp, f.encodedMessage, ccvs, proofs), "F-4 Chainlink only");
            assertEq(IBalance(f.token).balanceOf(f.recipient) - before, f.amount, "F-4 Chainlink only: amount");

            f = _fork(i);
            _setInboundCcvs(c.hooks, source, _list(NM));
            m = _decode(f.encodedMessage);
            m.tokenTransfer[0].amount = f.amount * 1000;
            (ccvs, proofs) = _single(NM, f.nethermindProof);
            _assertRejected(f, _encode(m), ccvs, proofs, UNAUTHORIZED_SIGNER, "F-4 Nethermind only, altered amount");
            before = IBalance(f.token).balanceOf(f.recipient);
            _assertSucceeded(_execute(f.offRamp, f.encodedMessage, ccvs, proofs), "F-4 Nethermind only");
            assertEq(IBalance(f.token).balanceOf(f.recipient) - before, f.amount, "F-4 Nethermind only: amount");
        }
    }

    /// @notice Proofs carry no expiry: the same attestations deliver a month later.
    function test_F05_proofs_do_not_expire() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            vm.warp(block.timestamp + 30 days);
            vm.roll(block.number + 1_000_000);
            _executeBothAndAssertDelivered(f);
        }
    }

    /// @notice The Nethermind owner rotates the committee: attestations of the previous committee stop working,
    /// including for messages already signed.
    function test_F08_signer_rotation_invalidates_published_proofs() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            DualCcvDeployment.Chain memory c = DualCcvDeployment.byRpcEnv(f.rpcEnv);
            uint64 source = _decode(f.encodedMessage).sourceChainSelector;
            _setSigners(c.nethermindVerifier, source, _keys(0xA11CE, 0xB0B), 2);

            (address[] memory ccvs, bytes[] memory proofs) = _both(f);
            _assertRejected(f, f.encodedMessage, ccvs, proofs, UNAUTHORIZED_SIGNER, "F-8 rotated committee");
        }
    }

    /// @notice Demonstration, expected to pass: the single owner key of the Nethermind contracts satisfies the
    /// Nethermind side alone, without the committee. Shown two ways on a real message whose Nethermind
    /// attestation is not used: through the resolver, and through the verifier.
    function test_F09_nethermind_owner_alone_satisfies_the_nethermind_side() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            // (a) resolver owner points the tag at a verifier that accepts anything.
            DualCcvFixtures.Fixture memory f = _fork(i);
            assertEq(IOwned(NM).owner().code.length, 0, "F-9: resolver owner is expected to be a plain key");
            IVerifierResolver.InboundImplementationArgs[] memory args = new IVerifierResolver.InboundImplementationArgs[](1);
            args[0] = IVerifierResolver.InboundImplementationArgs({
                version: DualCcvDeployment.NETHERMIND_TAG,
                verifier: address(new MockCCV())
            });
            vm.prank(IOwned(NM).owner());
            IVerifierResolver(NM).applyInboundImplementationUpdates(args);

            (address[] memory ccvs, bytes[] memory proofs) =
                _pair(CL, f.chainlinkProof, NM, abi.encodePacked(DualCcvDeployment.NETHERMIND_TAG));
            uint256 before = IBalance(f.token).balanceOf(f.recipient);
            _assertSucceeded(_execute(f.offRamp, f.encodedMessage, ccvs, proofs), "F-9a resolver owner");
            assertEq(IBalance(f.token).balanceOf(f.recipient) - before, f.amount, "F-9a: amount");

            // (b) verifier owner installs a one-key committee and signs.
            f = _fork(i);
            DualCcvDeployment.Chain memory c = DualCcvDeployment.byRpcEnv(f.rpcEnv);
            assertEq(IOwned(c.nethermindVerifier).owner().code.length, 0, "F-9: verifier owner is expected to be a plain key");
            _setSigners(c.nethermindVerifier, _decode(f.encodedMessage).sourceChainSelector, _keys(0xBAD), 1);
            (ccvs, proofs) =
                _pair(CL, f.chainlinkProof, NM, _committeeProof(DualCcvDeployment.NETHERMIND_TAG, f.messageId, _keys(0xBAD)));
            before = IBalance(f.token).balanceOf(f.recipient);
            _assertSucceeded(_execute(f.offRamp, f.encodedMessage, ccvs, proofs), "F-9b verifier owner");
            assertEq(IBalance(f.token).balanceOf(f.recipient) - before, f.amount, "F-9b: amount");
        }
    }

    /// @notice The same owner key cannot move tokens alone: without a Chainlink attestation over the altered
    /// message the forged Nethermind side is not enough.
    function test_F09c_nethermind_owner_cannot_forge_a_transfer_alone() public {
        for (uint256 i = 0; i < DualCcvFixtures.COUNT; ++i) {
            DualCcvFixtures.Fixture memory f = _fork(i);
            DualCcvDeployment.Chain memory c = DualCcvDeployment.byRpcEnv(f.rpcEnv);
            MessageV1Codec.MessageV1 memory m = _decode(f.encodedMessage);
            _setSigners(c.nethermindVerifier, m.sourceChainSelector, _keys(0xBAD), 1);

            address thief = makeAddr("thief");
            m.tokenTransfer[0].amount = 100 ether;
            m.tokenTransfer[0].tokenReceiver = abi.encodePacked(thief);
            bytes memory forged = _encode(m);
            bytes memory forgedProof = _committeeProof(DualCcvDeployment.NETHERMIND_TAG, keccak256(forged), _keys(0xBAD));

            (address[] memory ccvs, bytes[] memory proofs) = _pair(NM, forgedProof, CL, f.chainlinkProof);
            Outcome memory o = _execute(f.offRamp, forged, ccvs, proofs);
            _assertFailed(o, UNAUTHORIZED_SIGNER, "F-9c forged message, real Chainlink proof of another message");
            (ccvs, proofs) = _single(NM, forgedProof);
            o = _execute(f.offRamp, forged, ccvs, proofs);
            assertTrue(o.reverted && o.revertSelector == NO_STATE_PROGRESS, "F-9c: Nethermind proof alone");
            assertEq(IBalance(f.token).balanceOf(thief), 0, "F-9c: forged transfer delivered");
        }
    }

    // ═════════════════════════ helpers ═════════════════════════

    function _fork(uint256 index) internal returns (DualCcvFixtures.Fixture memory f) {
        f = DualCcvFixtures.get(index);
        vm.createSelectFork(vm.envString(f.rpcEnv), f.forkBlock);
        assertEq(IOffRampReplay(f.offRamp).getExecutionState(f.messageId), UNTOUCHED, string.concat(f.name, ": not pending at fork block"));
    }

    /// @dev The call must return, record FAILURE with exactly `reason`, and move no token. For
    /// RequiredCCVMissing the event data is not compared further: which CCV is named follows from the list.
    function _assertRejected(
        DualCcvFixtures.Fixture memory f,
        bytes memory encodedMessage,
        address[] memory ccvs,
        bytes[] memory proofs,
        bytes4 reason,
        string memory label
    ) internal {
        uint256 balanceBefore = IBalance(f.token).balanceOf(f.recipient);
        uint256 supplyBefore = IBalance(f.token).totalSupply();
        Outcome memory o = _execute(f.offRamp, encodedMessage, ccvs, proofs);
        _assertFailed(o, reason, string.concat(f.name, " ", label));
        assertEq(IBalance(f.token).balanceOf(f.recipient), balanceBefore, string.concat(f.name, " ", label, ": tokens moved"));
        assertEq(IBalance(f.token).totalSupply(), supplyBefore, string.concat(f.name, " ", label, ": supply changed"));
    }

    /// @dev Real proofs over altered bytes: the Nethermind verifier is asked first and rejects; the original
    /// message stays untouched and still delivers.
    function _assertAlteredRejected(DualCcvFixtures.Fixture memory f, bytes memory altered, string memory label) internal {
        assertTrue(keccak256(altered) != f.messageId, string.concat(label, ": message was not altered"));
        (address[] memory ccvs, bytes[] memory proofs) = _both(f);
        _assertRejected(f, altered, ccvs, proofs, UNAUTHORIZED_SIGNER, label);
        assertEq(IOffRampReplay(f.offRamp).getExecutionState(f.messageId), UNTOUCHED, string.concat(label, ": original touched"));
        _executeBothAndAssertDelivered(f);
    }

    function _damagedNethermind(uint256 index, bytes memory proof, bytes4 reason, string memory label) internal {
        DualCcvFixtures.Fixture memory f = _fork(index);
        (address[] memory ccvs, bytes[] memory proofs) = _pair(CL, f.chainlinkProof, NM, proof);
        _assertRejected(f, f.encodedMessage, ccvs, proofs, reason, label);
    }

    function _executeBothAndAssertDelivered(DualCcvFixtures.Fixture memory f) internal {
        uint256 balanceBefore = IBalance(f.token).balanceOf(f.recipient);
        (address[] memory ccvs, bytes[] memory proofs) = _both(f);
        IOffRampReplay(f.offRamp).execute(f.encodedMessage, ccvs, proofs, 0);

        assertEq(IOffRampReplay(f.offRamp).getExecutionState(f.messageId), SUCCESS, string.concat(f.name, ": both proofs did not execute"));
        assertEq(
            IBalance(f.token).balanceOf(f.recipient) - balanceBefore,
            f.amount,
            string.concat(f.name, ": recipient did not receive the sent amount")
        );
    }

    function _slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            out[i] = data[start + i];
        }
    }
}

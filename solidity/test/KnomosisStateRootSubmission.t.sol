// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KnomosisStateRootSubmission} from "src/contracts/KnomosisStateRootSubmission.sol";

/// @title KnomosisStateRootSubmissionTest
/// @notice Forge tests for the state-root submission registry
///         (Workstream-H WUs H.7.1 – H.7.4).
contract KnomosisStateRootSubmissionTest is Test {
    KnomosisStateRootSubmission private registry;

    address private sequencer = address(0xBEEF);
    address private faultProofGame = address(0xC0DE);
    address private stranger = address(0xDEAD);

    bytes32 private constant DEPLOYMENT_ID = bytes32(uint256(0xCAFE));
    uint128 private constant BOND = 1 ether;
    uint64  private constant DISPUTE_WINDOW = 100;
    uint64  private constant MIN_INTERVAL = 10;
    uint64  private constant MAX_OUTSTANDING = 5;
    uint64  private constant WITHDRAWAL_WINDOW = 50;

    function setUp() public {
        registry = new KnomosisStateRootSubmission(
            BOND,
            DISPUTE_WINDOW,
            MIN_INTERVAL,
            MAX_OUTSTANDING,
            sequencer,
            faultProofGame,
            DEPLOYMENT_ID,
            WITHDRAWAL_WINDOW
        );
        vm.deal(sequencer, 100 ether);
        // Roll past the rate-limit window (lastSubmissionBlock starts
        // at 0; require block.number ≥ MIN_INTERVAL for the first
        // submission to clear).
        vm.roll(block.number + MIN_INTERVAL + 1);
    }

    /* -------- Constructor -------- */

    function test_constructor_sets_immutables() public view {
        assertEq(registry.STATE_ROOT_SUBMISSION_BOND(), BOND);
        assertEq(registry.FAULT_PROOF_DISPUTE_WINDOW(), DISPUTE_WINDOW);
        assertEq(registry.MIN_SUBMISSION_INTERVAL_BLOCKS(), MIN_INTERVAL);
        assertEq(registry.MAX_OUTSTANDING_ROOTS_PER_SEQUENCER(), MAX_OUTSTANDING);
        assertEq(registry.sequencer(), sequencer);
        assertEq(registry.faultProofGame(), faultProofGame);
        assertEq(registry.deploymentId(), DEPLOYMENT_ID);
    }

    function test_constructor_rejects_zero_sequencer() public {
        vm.expectRevert(KnomosisStateRootSubmission.ZeroAddress.selector);
        new KnomosisStateRootSubmission(
            BOND, DISPUTE_WINDOW, MIN_INTERVAL, MAX_OUTSTANDING,
            address(0), faultProofGame, DEPLOYMENT_ID, WITHDRAWAL_WINDOW);
    }

    function test_constructor_rejects_zero_faultProofGame() public {
        vm.expectRevert(KnomosisStateRootSubmission.ZeroAddress.selector);
        new KnomosisStateRootSubmission(
            BOND, DISPUTE_WINDOW, MIN_INTERVAL, MAX_OUTSTANDING,
            sequencer, address(0), DEPLOYMENT_ID, WITHDRAWAL_WINDOW);
    }

    function test_constructor_rejects_dispute_window_too_short() public {
        // Dispute window must be ≥ withdrawal-finalisation window.
        vm.expectRevert(KnomosisStateRootSubmission.WindowTooShort.selector);
        new KnomosisStateRootSubmission(
            BOND,
            10,  // dispute window
            MIN_INTERVAL, MAX_OUTSTANDING,
            sequencer, faultProofGame, DEPLOYMENT_ID,
            100);  // withdrawal window > dispute window
    }

    function test_constructor_rejects_zero_bond() public {
        vm.expectRevert(KnomosisStateRootSubmission.InvalidBond.selector);
        new KnomosisStateRootSubmission(
            0,  // zero bond — disabled slashing
            DISPUTE_WINDOW, MIN_INTERVAL, MAX_OUTSTANDING,
            sequencer, faultProofGame, DEPLOYMENT_ID, WITHDRAWAL_WINDOW);
    }

    function test_constructor_rejects_zero_dispute_window() public {
        vm.expectRevert(KnomosisStateRootSubmission.WindowTooShort.selector);
        new KnomosisStateRootSubmission(
            BOND,
            0,  // zero dispute window — instant finality breaks fault-proof
            MIN_INTERVAL, MAX_OUTSTANDING,
            sequencer, faultProofGame, DEPLOYMENT_ID, 0);
    }

    function test_constructor_rejects_zero_submission_interval() public {
        vm.expectRevert(KnomosisStateRootSubmission.SubmissionTooFrequent.selector);
        new KnomosisStateRootSubmission(
            BOND, DISPUTE_WINDOW,
            0,  // zero submission interval — unbounded spam
            MAX_OUTSTANDING,
            sequencer, faultProofGame, DEPLOYMENT_ID, WITHDRAWAL_WINDOW);
    }

    function test_constructor_rejects_zero_max_outstanding() public {
        vm.expectRevert(KnomosisStateRootSubmission.TooManyOutstandingRoots.selector);
        new KnomosisStateRootSubmission(
            BOND, DISPUTE_WINDOW, MIN_INTERVAL,
            0,  // zero max outstanding — no submissions possible
            sequencer, faultProofGame, DEPLOYMENT_ID, WITHDRAWAL_WINDOW);
    }

    /* -------- submitStateRoot -------- */

    function test_submitStateRoot_first_index_succeeds() public {
        vm.prank(sequencer);
        registry.submitStateRoot{value: BOND}(
            0, bytes32(uint256(0xAAA)), bytes32(0));
        // Verify the record was stored.
        (address seq, bytes32 commit, , , uint128 bond, uint64 atBlock, , )
          = registry.roots(0);
        assertEq(seq, sequencer);
        assertEq(commit, bytes32(uint256(0xAAA)));
        assertEq(bond, BOND);
        assertEq(atBlock, uint64(block.number));
    }

    function test_submitStateRoot_rejects_non_sequencer() public {
        vm.prank(stranger);
        vm.deal(stranger, 100 ether);
        vm.expectRevert(KnomosisStateRootSubmission.NotSequencer.selector);
        registry.submitStateRoot{value: BOND}(
            0, bytes32(uint256(0xAAA)), bytes32(0));
    }

    function test_submitStateRoot_rejects_wrong_bond() public {
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.InvalidBond.selector);
        registry.submitStateRoot{value: BOND - 1}(
            0, bytes32(uint256(0xAAA)), bytes32(0));
    }

    function test_submitStateRoot_rejects_duplicate_index() public {
        vm.prank(sequencer);
        registry.submitStateRoot{value: BOND}(
            0, bytes32(uint256(0xAAA)), bytes32(0));
        vm.roll(block.number + MIN_INTERVAL + 1);
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.AlreadyClaimed.selector);
        registry.submitStateRoot{value: BOND}(
            0, bytes32(uint256(0xBBB)), bytes32(0));
    }

    function test_submitStateRoot_enforces_rate_limit() public {
        vm.prank(sequencer);
        registry.submitStateRoot{value: BOND}(
            0, bytes32(uint256(0xAAA)), bytes32(0));
        // Try to submit a second root immediately.
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.SubmissionTooFrequent.selector);
        registry.submitStateRoot{value: BOND}(
            1, bytes32(uint256(0xBBB)),
            keccak256(abi.encode(bytes32(0), bytes32(uint256(0xAAA)))));
    }

    function test_submitStateRoot_hash_chain_break_rejected() public {
        vm.prank(sequencer);
        registry.submitStateRoot{value: BOND}(
            0, bytes32(uint256(0xAAA)), bytes32(0));
        vm.roll(block.number + MIN_INTERVAL + 1);
        vm.prank(sequencer);
        // Submit at idx 1 with WRONG prevLogEntryHash.
        vm.expectRevert(KnomosisStateRootSubmission.HashChainBroken.selector);
        registry.submitStateRoot{value: BOND}(
            1, bytes32(uint256(0xBBB)), bytes32(uint256(0xDEAD0FF)));
    }

    function test_submitStateRoot_rejects_idx1_without_idx0() public {
        vm.prank(sequencer);
        // Submit at idx 1 without idx 0 first.
        vm.expectRevert(KnomosisStateRootSubmission.PreviousRootMissing.selector);
        registry.submitStateRoot{value: BOND}(
            1, bytes32(uint256(0xBBB)), bytes32(0));
    }

    /* -------- finaliseStateRoot -------- */

    function test_finaliseStateRoot_after_dispute_window_succeeds() public {
        vm.prank(sequencer);
        registry.submitStateRoot{value: BOND}(
            0, bytes32(uint256(0xAAA)), bytes32(0));
        vm.roll(block.number + DISPUTE_WINDOW + 1);

        uint256 bondBefore = sequencer.balance;
        registry.finaliseStateRoot(0);
        // Bond is released back to sequencer.
        assertEq(sequencer.balance, bondBefore + BOND);
        (, , , , , , bool finalised, ) = registry.roots(0);
        assertTrue(finalised);
    }

    function test_finaliseStateRoot_rejects_within_window() public {
        vm.prank(sequencer);
        registry.submitStateRoot{value: BOND}(
            0, bytes32(uint256(0xAAA)), bytes32(0));
        vm.expectRevert(KnomosisStateRootSubmission.NotYetFinalisable.selector);
        registry.finaliseStateRoot(0);
    }

    function test_finaliseStateRoot_double_call_rejected() public {
        vm.prank(sequencer);
        registry.submitStateRoot{value: BOND}(
            0, bytes32(uint256(0xAAA)), bytes32(0));
        vm.roll(block.number + DISPUTE_WINDOW + 1);
        registry.finaliseStateRoot(0);
        vm.expectRevert(KnomosisStateRootSubmission.AlreadyFinalised.selector);
        registry.finaliseStateRoot(0);
    }

    function test_finaliseStateRoot_unknown_index_reverts() public {
        vm.expectRevert(KnomosisStateRootSubmission.PreviousRootMissing.selector);
        registry.finaliseStateRoot(999);
    }

    /* -------- revertStateRootsFrom -------- */

    function test_revertStateRootsFrom_only_faultProofGame() public {
        vm.prank(stranger);
        vm.expectRevert(KnomosisStateRootSubmission.NotFaultProofGame.selector);
        registry.revertStateRootsFrom(5);
    }

    /* -------- markDisputed (new audit-fix) -------- */

    function test_markDisputed_only_faultProofGame() public {
        vm.prank(stranger);
        vm.expectRevert(KnomosisStateRootSubmission.NotFaultProofGame.selector);
        registry.markDisputed(5);
    }

    function test_markDisputed_rejects_missing_root() public {
        vm.prank(faultProofGame);
        vm.expectRevert(KnomosisStateRootSubmission.RootMissing.selector);
        registry.markDisputed(999);
    }

    /* -------- clearDisputed (new audit-fix) -------- */

    function test_clearDisputed_only_faultProofGame() public {
        vm.prank(stranger);
        vm.expectRevert(KnomosisStateRootSubmission.NotFaultProofGame.selector);
        registry.clearDisputed(5);
    }

    function test_clearDisputed_rejects_missing_root() public {
        vm.prank(faultProofGame);
        vm.expectRevert(KnomosisStateRootSubmission.RootMissing.selector);
        registry.clearDisputed(999);
    }

    /* -------- slashSequencerBond (new audit-fix) -------- */

    function test_slashSequencerBond_only_faultProofGame() public {
        vm.prank(stranger);
        vm.expectRevert(KnomosisStateRootSubmission.NotFaultProofGame.selector);
        registry.slashSequencerBond(5, address(0xCAFE));
    }

    function test_slashSequencerBond_rejects_zero_recipient() public {
        vm.prank(faultProofGame);
        vm.expectRevert(KnomosisStateRootSubmission.NotSequencer.selector);
        registry.slashSequencerBond(5, address(0));
    }

    function test_slashSequencerBond_rejects_missing_root() public {
        vm.prank(faultProofGame);
        vm.expectRevert(KnomosisStateRootSubmission.RootMissing.selector);
        registry.slashSequencerBond(999, address(0xCAFE));
    }

    function test_revertStateRootsFrom_updates_range() public {
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(5);
        assertEq(registry.lowestRevertedLogIndex(), 5);
        assertEq(registry.highestRevertedLogIndex(), 5);
    }

    function test_isStateRootReverted_in_range() public {
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(5);
        assertTrue(registry.isStateRootReverted(5));
    }

    function test_isStateRootReverted_below_floor() public {
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(5);
        assertFalse(registry.isStateRootReverted(4));
    }

    function test_isStateRootReverted_default_floor_zero() public view {
        // No revert ever fired; floor = 0; isStateRootReverted(0) = false.
        assertFalse(registry.isStateRootReverted(0));
    }

    /* -------- assertConsistent -------- */

    function test_assertConsistent_does_not_revert() public view {
        registry.assertConsistent();
    }
}

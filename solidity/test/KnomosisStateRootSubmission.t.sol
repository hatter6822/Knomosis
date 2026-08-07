// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ActionsRoot} from "src/lib/ActionsRoot.sol";
import {KnomosisStateRootSubmission} from "src/contracts/KnomosisStateRootSubmission.sol";
import {LogChain} from "src/lib/LogChain.sol";

/// @title KnomosisStateRootSubmissionTest
/// @notice Forge tests for the BATCH submission registry
///         (Workstream-H WUs H.7.1 – H.7.4, re-cut by Workstream SB).
///
///         The revert-recovery suite is the load-bearing half: the
///         retired per-action registry's reverted range was a dead
///         end (reverted indices unresubmittable forever, the chain
///         extending straight through reverted entries), and these
///         tests FAIL on that behaviour — they drive a revert, then
///         resubmit the corrected chain and require it to be
///         canonical.
contract KnomosisStateRootSubmissionTest is Test {
    /// @dev The EG.2 submission-breaker role.  A literal distinct
    ///      from every sequencer in these fixtures: the constructor
    ///      refuses a breaker equal to the sequencer.
    address internal constant BREAKER = address(0xB4EA4E4);

    /// @dev The EG.2 operator flow after a revert.  `revertStateRootsFrom`
    ///      latches the submission breaker, so the R1 recovery path --
    ///      the sequencer re-extending from `canonicalTip` -- is now
    ///      gated on a human clearing the halt.  Asserts the latch
    ///      FIRED before clearing it, so a regression that stopped
    ///      latching fails here rather than passing quietly.
    function _clearHaltAfterRevert() internal {
        assertTrue(registry.submissionsHalted(), "a revert must latch the breaker");
        vm.prank(BREAKER);
        registry.resumeSubmissions();
        assertFalse(registry.submissionsHalted(), "the breaker clears it");
    }

    KnomosisStateRootSubmission private registry;

    address private sequencer = address(0xBEEF);
    address private faultProofGame = address(0xC0DE);
    address private stranger = address(0xDEAD);

    bytes32 private constant DEPLOYMENT_ID = bytes32(uint256(0xCAFE));
    /// An arbitrary but FIXED actions root.  The registry treats it
    /// opaquely — it folds the value into the chain and never opens
    /// it — so these tests need one stable value, not a realistic
    /// tree.  `KnomosisFaultProofGame.t.sol` is where a real
    /// `ActionsRoot.actionsRoot` is opened end-to-end.
    bytes32 private constant ACTIONS_ROOT = bytes32(uint256(0xAC7104));
    bytes32 private constant GENESIS_COMMIT = bytes32(uint256(0x6E0E515));
    uint128 private constant BOND = 1 ether;
    uint64  private constant DISPUTE_WINDOW = 100;
    uint64  private constant MIN_INTERVAL = 10;
    uint64  private constant MAX_OUTSTANDING = 5;
    uint64  private constant WITHDRAWAL_WINDOW = 50;
    uint64  private constant MAX_BATCH = 1000;

    function setUp() public {
        registry = _deploy(GENESIS_COMMIT, MAX_BATCH);
        vm.deal(sequencer, 100 ether);
        // Roll past the rate-limit window (lastSubmissionBlock starts
        // at 0; require block.number ≥ MIN_INTERVAL for the first
        // submission to clear).
        vm.roll(vm.getBlockNumber() + MIN_INTERVAL + 1);
    }

    function _deploy(bytes32 gsc, uint64 maxBatch)
        internal
        returns (KnomosisStateRootSubmission)
    {
        return new KnomosisStateRootSubmission(
            BOND,
            DISPUTE_WINDOW,
            MIN_INTERVAL,
            MAX_OUTSTANDING,
            sequencer,
            faultProofGame,
            DEPLOYMENT_ID,
            WITHDRAWAL_WINDOW,
            gsc,
            maxBatch,
            BREAKER);
    }

    /// Submit a batch as the sequencer, advancing past the rate
    /// limit first.
    function _submit(uint64 endIndex, uint64 prevEndIndex, bytes32 commit)
        internal
    {
        vm.roll(vm.getBlockNumber() + MIN_INTERVAL + 1);
        vm.prank(sequencer);
        registry.submitStateRoot{value: BOND}(
            endIndex, prevEndIndex, commit, ACTIONS_ROOT);
    }

    function _commitOf(uint64 endIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("state", endIndex));
    }

    function _expectedNextHashOf(uint64 endIndex)
        internal
        view
        returns (bytes32 h)
    {
        (, , , h, , , , , , ) = registry.roots(endIndex);
    }

    /* -------- Constructor + genesis anchor -------- */

    function test_constructor_sets_immutables() public view {
        assertEq(registry.STATE_ROOT_SUBMISSION_BOND(), BOND);
        assertEq(registry.FAULT_PROOF_DISPUTE_WINDOW(), DISPUTE_WINDOW);
        assertEq(registry.MIN_SUBMISSION_INTERVAL_BLOCKS(), MIN_INTERVAL);
        assertEq(registry.MAX_OUTSTANDING_ROOTS_PER_SEQUENCER(), MAX_OUTSTANDING);
        assertEq(registry.MAX_ACTIONS_PER_BATCH(), MAX_BATCH);
        assertEq(registry.sequencer(), sequencer);
        assertEq(registry.faultProofGame(), faultProofGame);
        assertEq(registry.deploymentId(), DEPLOYMENT_ID);
        registry.assertConsistent();
    }

    /// The constructor writes the genesis anchor: record 0,
    /// finalised, bondless, its chain value the genesis seed — so
    /// the first real submission has a structural parent.
    function test_genesis_anchor_written_by_constructor() public view {
        (
            address seq, bytes32 commit, bytes32 prevHash, bytes32 nextHash,
            uint128 bond, uint64 atBlock, bool finalised, bool disputed,
            uint64 prevEnd, bytes32 ar
        ) = registry.roots(0);
        assertEq(seq, address(0), "nobody submitted genesis");
        assertEq(commit, GENESIS_COMMIT, "genesis commit");
        assertEq(prevHash, bytes32(0), "all-zero predecessor");
        assertEq(
            nextHash, ActionsRoot.genesisChainSeed(GENESIS_COMMIT),
            "the genesis seed");
        assertEq(bond, 0, "bondless");
        assertGt(atBlock, 0, "anchor exists");
        assertTrue(finalised, "born finalised");
        assertFalse(disputed, "undisputed");
        assertEq(prevEnd, 0, "self-parented");
        assertEq(ar, bytes32(0), "empty actions root");
        assertEq(registry.canonicalTip(), 0, "tip starts at genesis");
    }

    function test_constructor_rejects_zero_genesis_commit() public {
        vm.expectRevert(KnomosisStateRootSubmission.ZeroGenesisCommit.selector);
        _deploy(bytes32(0), MAX_BATCH);
    }

    function test_constructor_rejects_zero_batch_cap() public {
        vm.expectRevert(KnomosisStateRootSubmission.BatchTooLarge.selector);
        _deploy(GENESIS_COMMIT, 0);
    }

    function test_constructor_rejects_zero_sequencer() public {
        vm.expectRevert(KnomosisStateRootSubmission.ZeroAddress.selector);
        new KnomosisStateRootSubmission(
            BOND, DISPUTE_WINDOW, MIN_INTERVAL, MAX_OUTSTANDING,
            address(0), faultProofGame, DEPLOYMENT_ID, WITHDRAWAL_WINDOW,
            GENESIS_COMMIT, MAX_BATCH,
            BREAKER);
    }

    function test_constructor_rejects_zero_faultProofGame() public {
        vm.expectRevert(KnomosisStateRootSubmission.ZeroAddress.selector);
        new KnomosisStateRootSubmission(
            BOND, DISPUTE_WINDOW, MIN_INTERVAL, MAX_OUTSTANDING,
            sequencer, address(0), DEPLOYMENT_ID, WITHDRAWAL_WINDOW,
            GENESIS_COMMIT, MAX_BATCH,
            BREAKER);
    }

    function test_constructor_rejects_dispute_window_too_short() public {
        // Dispute window must be ≥ withdrawal-finalisation window.
        vm.expectRevert(KnomosisStateRootSubmission.WindowTooShort.selector);
        new KnomosisStateRootSubmission(
            BOND,
            10,  // dispute window
            MIN_INTERVAL, MAX_OUTSTANDING,
            sequencer, faultProofGame, DEPLOYMENT_ID,
            100,  // withdrawal window > dispute window
            GENESIS_COMMIT, MAX_BATCH,
            BREAKER);
    }

    function test_constructor_rejects_zero_bond() public {
        vm.expectRevert(KnomosisStateRootSubmission.InvalidBond.selector);
        new KnomosisStateRootSubmission(
            0, DISPUTE_WINDOW, MIN_INTERVAL, MAX_OUTSTANDING,
            sequencer, faultProofGame, DEPLOYMENT_ID, WITHDRAWAL_WINDOW,
            GENESIS_COMMIT, MAX_BATCH,
            BREAKER);
    }

    /* -------- submitStateRoot: batch semantics -------- */

    /// One batch covers many entries: a (0 → 500) submission is ONE
    /// record, one bond, one chain link — the rollup economics the
    /// per-action registry could not express.
    function test_submit_batch_extends_the_tip() public {
        _submit(500, 0, _commitOf(500));
        assertEq(registry.canonicalTip(), 500, "tip advanced to end");
        assertEq(registry.latestSubmittedLogIndex(), 500);
        (
            address seq, bytes32 commit, bytes32 prevHash, bytes32 nextHash,
            uint128 bond, , bool finalised, , uint64 prevEnd, bytes32 ar
        ) = registry.roots(500);
        assertEq(seq, sequencer);
        assertEq(commit, _commitOf(500));
        assertEq(
            prevHash, ActionsRoot.genesisChainSeed(GENESIS_COMMIT),
            "structural link to the genesis anchor");
        assertEq(
            nextHash,
            LogChain.nextEntryHash(prevHash, commit, ACTIONS_ROOT),
            "chain folds the actions root");
        assertEq(bond, BOND);
        assertFalse(finalised);
        assertEq(prevEnd, 0);
        assertEq(ar, ACTIONS_ROOT);
    }

    function test_submit_chains_structurally() public {
        _submit(3, 0, _commitOf(3));
        bytes32 firstNext = _expectedNextHashOf(3);
        _submit(10, 3, _commitOf(10));
        (, , bytes32 prevHash, , , , , , , ) = registry.roots(10);
        assertEq(
            prevHash, firstNext,
            "the child's prev hash IS the parent's stored next hash");
    }

    function test_submit_rejects_non_sequencer() public {
        vm.deal(stranger, BOND);
        vm.prank(stranger);
        vm.expectRevert(KnomosisStateRootSubmission.NotSequencer.selector);
        registry.submitStateRoot{value: BOND}(1, 0, _commitOf(1), ACTIONS_ROOT);
    }

    function test_submit_rejects_wrong_bond() public {
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.InvalidBond.selector);
        registry.submitStateRoot{value: BOND - 1}(
            1, 0, _commitOf(1), ACTIONS_ROOT);
    }

    function test_submit_rejects_empty_batch() public {
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.EmptyBatch.selector);
        registry.submitStateRoot{value: BOND}(0, 0, _commitOf(0), ACTIONS_ROOT);
    }

    function test_submit_rejects_oversized_batch() public {
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.BatchTooLarge.selector);
        registry.submitStateRoot{value: BOND}(
            MAX_BATCH + 1, 0, _commitOf(1), ACTIONS_ROOT);
    }

    /// The chain is linear: a submission must extend the tip, so a
    /// second child of an already-extended parent — a FORK — is
    /// refused.
    function test_submit_rejects_fork() public {
        _submit(5, 0, _commitOf(5));
        vm.roll(vm.getBlockNumber() + MIN_INTERVAL + 1);
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.NotCanonicalTip.selector);
        registry.submitStateRoot{value: BOND}(7, 0, _commitOf(7), ACTIONS_ROOT);
    }

    function test_submit_rejects_gap() public {
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.NotCanonicalTip.selector);
        registry.submitStateRoot{value: BOND}(
            10, 5, _commitOf(10), ACTIONS_ROOT);
    }

    function test_submit_rate_limited() public {
        _submit(1, 0, _commitOf(1));
        // No roll: the second submission is inside the interval.
        vm.prank(sequencer);
        vm.expectRevert(
            KnomosisStateRootSubmission.SubmissionTooFrequent.selector);
        registry.submitStateRoot{value: BOND}(2, 1, _commitOf(2), ACTIONS_ROOT);
    }

    function test_submit_outstanding_cap() public {
        for (uint64 i = 1; i <= MAX_OUTSTANDING; i++) {
            _submit(i, i - 1, _commitOf(i));
        }
        vm.roll(vm.getBlockNumber() + MIN_INTERVAL + 1);
        vm.prank(sequencer);
        vm.expectRevert(
            KnomosisStateRootSubmission.TooManyOutstandingRoots.selector);
        registry.submitStateRoot{value: BOND}(
            MAX_OUTSTANDING + 1, MAX_OUTSTANDING,
            _commitOf(MAX_OUTSTANDING + 1), ACTIONS_ROOT);
    }

    /* -------- finalise -------- */

    function test_finalise_after_window_releases_bond() public {
        _submit(4, 0, _commitOf(4));
        vm.roll(vm.getBlockNumber() + DISPUTE_WINDOW + 1);
        uint256 before = sequencer.balance;
        registry.finaliseStateRoot(4);
        assertEq(sequencer.balance, before + BOND, "bond released");
        (, , , , uint128 bond, , bool finalised, , , ) = registry.roots(4);
        assertTrue(finalised);
        assertEq(bond, 0);
    }

    function test_finalise_rejects_before_window() public {
        _submit(4, 0, _commitOf(4));
        vm.expectRevert(KnomosisStateRootSubmission.NotYetFinalisable.selector);
        registry.finaliseStateRoot(4);
    }

    function test_finalise_rejects_missing() public {
        vm.expectRevert(KnomosisStateRootSubmission.RootMissing.selector);
        registry.finaliseStateRoot(77);
    }

    function test_finalise_rejects_genesis_anchor() public {
        vm.expectRevert(KnomosisStateRootSubmission.AlreadyFinalised.selector);
        registry.finaliseStateRoot(0);
    }

    function test_finalise_rejects_disputed() public {
        _submit(4, 0, _commitOf(4));
        vm.prank(faultProofGame);
        registry.markDisputed(4);
        vm.roll(vm.getBlockNumber() + DISPUTE_WINDOW + 1);
        vm.expectRevert(KnomosisStateRootSubmission.DisputeInProgress.selector);
        registry.finaliseStateRoot(4);
    }

    /* -------- Revert recovery (SB ruling R1) -------- */

    /// The whole recovery arc, which the retired registry could not
    /// perform at all: a revert lowers the tip to the disputed
    /// record's parent, the corrected chain resubmits THROUGH the old
    /// reverted range, and the resubmissions read canonical.
    function test_revert_recovery_resubmits_the_corrected_chain() public {
        _submit(5, 0, _commitOf(5));
        _submit(9, 5, _commitOf(9));
        _submit(14, 9, _commitOf(14));

        // The game reverts from record 9 (its parent is record 5).
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(9);
        _clearHaltAfterRevert();

        assertEq(registry.canonicalTip(), 5, "tip lowered to the parent");
        assertTrue(registry.isStateRootReverted(9), "disputed record reverted");
        assertTrue(registry.isStateRootReverted(14), "descendant reverted");
        assertFalse(registry.isStateRootReverted(5), "parent stays canonical");

        // The corrected chain re-extends from 5.  Its keys land
        // INSIDE the reverted index range — and must not be misread
        // as reverted (`submittedAtBlock > lastRevertAtBlock`).
        _submit(8, 5, _commitOf(8));
        assertEq(registry.canonicalTip(), 8);
        assertFalse(
            registry.isStateRootReverted(8),
            "post-revert resubmission is canonical");

        // ...and finalises normally.
        vm.roll(vm.getBlockNumber() + DISPUTE_WINDOW + 1);
        registry.finaliseStateRoot(8);
    }

    function test_reverted_descendant_cannot_finalise() public {
        _submit(5, 0, _commitOf(5));
        _submit(9, 5, _commitOf(9));
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(5);
        _clearHaltAfterRevert();
        vm.roll(vm.getBlockNumber() + DISPUTE_WINDOW + 1);
        // The DESCENDANT — which no game ever touched — is reverted
        // with its ancestor and must not finalise.  The retired
        // registry let it, which is the defect this line pins.
        vm.expectRevert(KnomosisStateRootSubmission.RootReverted.selector);
        registry.finaliseStateRoot(9);
    }

    /// A second revert deeper in the chain must not RAISE the tip.
    function test_tip_is_monotone_down_across_reverts() public {
        _submit(5, 0, _commitOf(5));
        _submit(9, 5, _commitOf(9));
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(9);
        _clearHaltAfterRevert();
        assertEq(registry.canonicalTip(), 5);
        // Now the ancestor at 5 loses its own game.
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(5);
        _clearHaltAfterRevert();
        assertEq(registry.canonicalTip(), 0, "tip fell to genesis");
        // And a stale revert of the higher record again cannot raise
        // it back onto the reverted suffix.
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(9);
        _clearHaltAfterRevert();
        assertEq(registry.canonicalTip(), 0, "monotone down");
    }

    function test_markDisputed_rejects_reverted() public {
        _submit(5, 0, _commitOf(5));
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(5);
        _clearHaltAfterRevert();
        vm.prank(faultProofGame);
        vm.expectRevert(KnomosisStateRootSubmission.RootReverted.selector);
        registry.markDisputed(5);
    }

    /* -------- reclaimRevertedBond (SB ruling R4) -------- */

    function test_reclaim_returns_a_reverted_records_bond() public {
        _submit(5, 0, _commitOf(5));
        _submit(9, 5, _commitOf(9));
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(5);
        _clearHaltAfterRevert();

        uint256 before = sequencer.balance;
        // Permissionless: a stranger can only ever RETURN the bond.
        vm.prank(stranger);
        registry.reclaimRevertedBond(9);
        assertEq(sequencer.balance, before + BOND, "bond back to sequencer");
        (, , , , uint128 bond, , , , , ) = registry.roots(9);
        assertEq(bond, 0);

        // Idempotence: a second reclaim refuses.
        vm.expectRevert(KnomosisStateRootSubmission.BondAlreadyZero.selector);
        registry.reclaimRevertedBond(9);
    }

    function test_reclaim_rejects_canonical_record() public {
        _submit(5, 0, _commitOf(5));
        vm.expectRevert(KnomosisStateRootSubmission.RootMissing.selector);
        registry.reclaimRevertedBond(5);
    }

    function test_reclaim_rejects_disputed_record() public {
        _submit(5, 0, _commitOf(5));
        _submit(9, 5, _commitOf(9));
        vm.prank(faultProofGame);
        registry.markDisputed(9);
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(5);
        _clearHaltAfterRevert();
        // The record's own game is still open: its bond stays locked
        // until that game settles (slash or clear).
        vm.expectRevert(KnomosisStateRootSubmission.DisputeInProgress.selector);
        registry.reclaimRevertedBond(9);
    }

    /* -------- Overwrite of a reverted record (SB ruling R3) ------ */

    function test_overwrite_requires_the_bond_out_first() public {
        _submit(5, 0, _commitOf(5));
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(5);
        _clearHaltAfterRevert();

        // Resubmitting the SAME key while the old bond is still in
        // the record: refused, so no ETH is orphaned.
        vm.roll(vm.getBlockNumber() + MIN_INTERVAL + 1);
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.BondNotReclaimed.selector);
        registry.submitStateRoot{value: BOND}(
            5, 0, _commitOf(555), ACTIONS_ROOT);

        // Reclaim, then the overwrite succeeds and is canonical.
        registry.reclaimRevertedBond(5);
        _submit(5, 0, _commitOf(555));
        (, bytes32 commit, , , , , , , , ) = registry.roots(5);
        assertEq(commit, _commitOf(555), "overwritten with the corrected root");
        assertFalse(registry.isStateRootReverted(5));
        assertEq(registry.canonicalTip(), 5);
    }

    function test_live_record_is_never_overwritten() public {
        _submit(5, 0, _commitOf(5));
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(5);
        _clearHaltAfterRevert();
        registry.reclaimRevertedBond(5);
        _submit(5, 0, _commitOf(555));
        // The resubmitted record is canonical again, and its key is
        // now UNREACHABLE by construction: a live record's key is
        // always at or below `canonicalTip`, while any submission at
        // key K must pass `prevEndIndex == canonicalTip` and
        // `K > prevEndIndex` — i.e. K > tip.  So a third submission
        // at the key dies on the structural chain (`NotCanonicalTip`)
        // before the occupied-key rule is even consulted; the
        // `AlreadyClaimed` branch behind it is defence-in-depth for a
        // tip-invariant break that has no external path.
        vm.roll(vm.getBlockNumber() + MIN_INTERVAL + 1);
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.NotCanonicalTip.selector);
        registry.submitStateRoot{value: BOND}(
            5, 0, _commitOf(556), ACTIONS_ROOT);
    }

    /* -------- slash / dispute plumbing (unchanged surface) ------- */

    function test_slash_forwards_bond() public {
        _submit(5, 0, _commitOf(5));
        vm.prank(faultProofGame);
        registry.markDisputed(5);
        uint256 before = faultProofGame.balance;
        vm.prank(faultProofGame);
        registry.slashSequencerBond(5, faultProofGame);
        assertEq(faultProofGame.balance, before + BOND);
    }

    function test_only_game_can_mark_slash_revert() public {
        _submit(5, 0, _commitOf(5));
        vm.startPrank(stranger);
        vm.expectRevert(KnomosisStateRootSubmission.NotFaultProofGame.selector);
        registry.markDisputed(5);
        vm.expectRevert(KnomosisStateRootSubmission.NotFaultProofGame.selector);
        registry.slashSequencerBond(5, stranger);
        vm.expectRevert(KnomosisStateRootSubmission.NotFaultProofGame.selector);
        registry.revertStateRootsFrom(5);
        // No `_clearHaltAfterRevert` here: the call above is expected to
        // REVERT (wrong caller), so nothing latched.
        vm.stopPrank();
    }

    /* -------- ETH conservation (fuzz) -------- */

    /// Across an arbitrary interleaving of submissions, a revert,
    /// reclaims, finalisations and a slash, every wei that entered
    /// as a bond is either held by the registry or was paid out —
    /// no orphaned and no minted ETH.
    function testFuzz_bond_eth_is_conserved(uint8 batchesRaw, uint8 revertAtRaw)
        public
    {
        uint64 batches = uint64(batchesRaw % 4) + 2;      // 2..5 records
        uint64 revertOrdinal = uint64(revertAtRaw % batches) + 1;

        uint256 paidIn = 0;
        uint64[] memory ends = new uint64[](batches);
        uint64 tip = 0;
        for (uint64 i = 0; i < batches; i++) {
            uint64 end = tip + 3 + i;
            _submit(end, tip, _commitOf(end));
            paidIn += BOND;
            ends[i] = end;
            tip = end;
        }

        uint64 revertFrom = ends[revertOrdinal - 1];
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(revertFrom);

        uint256 paidOut = 0;
        uint256 seqBefore = sequencer.balance;
        // Reclaim every reverted record's bond.
        for (uint64 i = revertOrdinal - 1; i < batches; i++) {
            registry.reclaimRevertedBond(ends[i]);
        }
        paidOut += sequencer.balance - seqBefore;

        // Finalise every surviving canonical record.
        vm.roll(vm.getBlockNumber() + DISPUTE_WINDOW + 1);
        seqBefore = sequencer.balance;
        for (uint64 i = 0; i + 1 < revertOrdinal; i++) {
            registry.finaliseStateRoot(ends[i]);
        }
        paidOut += sequencer.balance - seqBefore;

        assertEq(
            paidIn, paidOut + address(registry).balance,
            "every bonded wei is held or paid out");
        // And in this schedule everything was released, so the
        // registry holds nothing.
        assertEq(address(registry).balance, 0, "fully drained");
    }
    /* ---------------------------------------------------------- */
    /* EG.2: the submission breaker                               */
    /* ---------------------------------------------------------- */

    /// @notice A manual halt refuses submission; a resume restores it.
    function test_breaker_halts_and_resumes_submission() public {
        _submit(5, 0, _commitOf(5));
        vm.prank(BREAKER);
        registry.haltSubmissions();
        assertTrue(registry.submissionsHalted(), "halted");

        vm.roll(vm.getBlockNumber() + MIN_INTERVAL + 1);
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.SubmissionsAreHalted.selector);
        registry.submitStateRoot{value: BOND}(
            6, 5, _commitOf(6), ACTIONS_ROOT);

        vm.prank(BREAKER);
        registry.resumeSubmissions();
        _submit(6, 5, _commitOf(6));
    }

    /// @notice Only `submissionBreaker` may halt or resume — the
    ///         sequencer least of all, since the automatic latch fires
    ///         on its own proven misbehaviour.
    function test_breaker_role_is_exclusive() public {
        vm.prank(sequencer);
        vm.expectRevert(KnomosisStateRootSubmission.NotSubmissionBreaker.selector);
        registry.haltSubmissions();
        vm.prank(stranger);
        vm.expectRevert(KnomosisStateRootSubmission.NotSubmissionBreaker.selector);
        registry.haltSubmissions();
        vm.prank(faultProofGame);
        vm.expectRevert(KnomosisStateRootSubmission.NotSubmissionBreaker.selector);
        registry.resumeSubmissions();
    }

    /// @notice A no-op halt/resume is REFUSED rather than silently
    ///         accepted, so an operator cannot believe a halt took
    ///         effect when it was already in place.
    function test_breaker_refuses_a_no_op_transition() public {
        vm.prank(BREAKER);
        vm.expectRevert(KnomosisStateRootSubmission.HaltStateUnchanged.selector);
        registry.resumeSubmissions();

        vm.prank(BREAKER);
        registry.haltSubmissions();
        vm.prank(BREAKER);
        vm.expectRevert(KnomosisStateRootSubmission.HaltStateUnchanged.selector);
        registry.haltSubmissions();
    }

    /// @notice A halt freezes the FRONTIER only: finalisation,
    ///         disputing, slashing and reversion all stay open.
    /// @dev    The scoping claim the state variable's docstring makes.
    ///         Without this, a halt could strand the settlement of
    ///         everything already submitted — turning a safety brake
    ///         into a liveness failure for funds already in flight.
    function test_halt_does_not_strand_prior_settlement() public {
        _submit(5, 0, _commitOf(5));
        vm.prank(BREAKER);
        registry.haltSubmissions();

        // Disputing and slashing a halted registry still work.
        vm.prank(faultProofGame);
        registry.markDisputed(5);
        vm.prank(faultProofGame);
        registry.slashSequencerBond(5, stranger);
        // ...and so does reverting.
        vm.prank(faultProofGame);
        registry.revertStateRootsFrom(5);
        assertTrue(registry.isStateRootReverted(5), "reversion works while halted");
    }

}

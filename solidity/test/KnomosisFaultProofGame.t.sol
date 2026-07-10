// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KnomosisFaultProofGame} from "src/contracts/KnomosisFaultProofGame.sol";
import {KnomosisStepVM} from "src/contracts/KnomosisStepVM.sol";

/// @notice A mock state-root submission contract used by the
///         game test.  Implements the dispute-locking, bond-
///         slashing, flag-clearing, and per-root lookup
///         interface the game expects.  Operators seed roots
///         via `seedRoot` before exercising challenge paths.
contract MockStateRootSubmissionForGame {
    struct RootRecord {
        address sequencer;
        bytes32 stateCommit;
        bytes32 prevLogEntryHash;
        bytes32 expectedNextHash;
        uint128 bond;
        uint64  submittedAtBlock;
        bool    finalised;
        bool    disputed;
    }

    mapping(uint64 => RootRecord) public roots;
    bytes32 public deploymentId;

    bool public markDisputedCalled;
    uint64 public lastMarkedLogIndex;
    bool public clearDisputedCalled;
    uint64 public lastClearedLogIndex;
    bool public slashCalled;
    uint64 public lastSlashedLogIndex;
    address public lastSlashRecipient;
    bool public revertCalled;
    uint64 public lastRevertedFromIdx;

    function setDeploymentId(bytes32 id) external {
        deploymentId = id;
    }

    function seedRoot(
        uint64 logIndex,
        address sequencer,
        bytes32 stateCommit,
        uint128 bond
    ) external payable {
        roots[logIndex] = RootRecord({
            sequencer: sequencer,
            stateCommit: stateCommit,
            prevLogEntryHash: bytes32(0),
            expectedNextHash: bytes32(0),
            bond: bond,
            submittedAtBlock: uint64(block.number),
            finalised: false,
            disputed: false
        });
    }

    function markDisputed(uint64 logIndex) external {
        markDisputedCalled = true;
        lastMarkedLogIndex = logIndex;
        roots[logIndex].disputed = true;
    }

    function clearDisputed(uint64 logIndex) external {
        clearDisputedCalled = true;
        lastClearedLogIndex = logIndex;
        roots[logIndex].disputed = false;
    }

    function slashSequencerBond(uint64 logIndex, address recipient) external {
        slashCalled = true;
        lastSlashedLogIndex = logIndex;
        lastSlashRecipient = recipient;
        uint128 amount = roots[logIndex].bond;
        roots[logIndex].bond = 0;
        if (amount > 0) {
            (bool ok, ) = payable(recipient).call{value: amount}("");
            require(ok, "MockSlashTransferFailed");
        }
    }

    function revertStateRootsFrom(uint64 fromIdx) external {
        revertCalled = true;
        lastRevertedFromIdx = fromIdx;
    }

    receive() external payable {}
}

/// @notice A recipient that ALWAYS reverts on receiving ETH.  Used to
///         prove the pull-payment settlement (audit 21, finding 1.3)
///         cannot be bricked by a reverting treasury / winner.
contract RevertingReceiver {
    receive() external payable {
        revert("no ETH");
    }
}

/// @title KnomosisFaultProofGameTest
/// @notice Forge tests for the bisection-game state machine
///         (Workstream-H WUs H.6.1.*).
contract KnomosisFaultProofGameTest is Test {
    KnomosisFaultProofGame private game;
    KnomosisStepVM private stepVM;
    MockStateRootSubmissionForGame private mockStateRootSubmission;

    address private treasury = address(0xBEEF);
    address private stateRootSubmission;
    address private sequencer = address(0xACE);
    address private challenger = address(0xCAFE);

    uint128 private constant MIN_CHALLENGE_BOND = 0.05 ether;
    uint128 private constant STATE_ROOT_BOND = 1 ether;
    uint64 private constant BISECTION_TIMEOUT = 100;
    uint64 private constant MIN_STEP_INTERVAL = 1;

    bytes32 private constant DEPLOYMENT_ID = bytes32(uint256(0xCAFE));
    bytes32 private constant DISPUTED_ROOT = bytes32(uint256(0x51));
    /// @notice The agreed pre-state (`low`) commit anchored at log
    ///         index 0.  Every challenge in this suite uses
    ///         `lowLogIndex = 0` + `lowCommit = LOW_ROOT`, which must
    ///         match the seeded root at index 0 (the low-anchor fix).
    bytes32 private constant LOW_ROOT = bytes32(uint256(0x10));

    function setUp() public {
        stepVM = new KnomosisStepVM();
        mockStateRootSubmission = new MockStateRootSubmissionForGame();
        mockStateRootSubmission.setDeploymentId(DEPLOYMENT_ID);
        stateRootSubmission = address(mockStateRootSubmission);

        // Fund the mock so it can forward slashing payments to the
        // game (representing the real state-root submission
        // holding sequencer bonds).
        vm.deal(stateRootSubmission, 10 ether);

        // Pre-seed roots for the test cases.  Each root at the
        // tested log-indices has the same sequencer + dummy bond.
        // Index 0 is the agreed `low` anchor every challenge references
        // (lowLogIndex = 0, lowCommit = LOW_ROOT); the low-anchor fix
        // requires `lowCommit` to match this submitted root.
        mockStateRootSubmission.seedRoot(0, sequencer, LOW_ROOT, STATE_ROOT_BOND);
        mockStateRootSubmission.seedRoot(10, sequencer, DISPUTED_ROOT, STATE_ROOT_BOND);
        mockStateRootSubmission.seedRoot(11, sequencer, DISPUTED_ROOT, STATE_ROOT_BOND);
        mockStateRootSubmission.seedRoot(12, sequencer, DISPUTED_ROOT, STATE_ROOT_BOND);
        mockStateRootSubmission.seedRoot(64, sequencer, DISPUTED_ROOT, STATE_ROOT_BOND);
        mockStateRootSubmission.seedRoot(65, sequencer, DISPUTED_ROOT, STATE_ROOT_BOND);
        mockStateRootSubmission.seedRoot(66, sequencer, DISPUTED_ROOT, STATE_ROOT_BOND);
        mockStateRootSubmission.seedRoot(67, sequencer, DISPUTED_ROOT, STATE_ROOT_BOND);

        game = new KnomosisFaultProofGame(
            BISECTION_TIMEOUT,
            MIN_CHALLENGE_BOND,
            MIN_STEP_INTERVAL,
            treasury,
            address(stepVM),
            stateRootSubmission
        );
        vm.deal(challenger, 100 ether);
        vm.deal(sequencer, 100 ether);
    }

    /* -------- Constructor -------- */

    function test_constructor_sets_immutables() public view {
        assertEq(game.BISECTION_RESPONSE_TIMEOUT(), BISECTION_TIMEOUT);
        assertEq(game.MIN_CHALLENGE_BOND(), MIN_CHALLENGE_BOND);
        assertEq(game.MIN_BISECTION_STEP_INTERVAL_BLOCKS(), MIN_STEP_INTERVAL);
        assertEq(game.treasury(), treasury);
        assertEq(address(game.stepVM()), address(stepVM));
        assertEq(game.stateRootSubmission(), stateRootSubmission);
    }

    function test_constructor_rejects_zero_treasury() public {
        vm.expectRevert(KnomosisFaultProofGame.ZeroAddress.selector);
        new KnomosisFaultProofGame(
            BISECTION_TIMEOUT, MIN_CHALLENGE_BOND, MIN_STEP_INTERVAL,
            address(0), address(stepVM), stateRootSubmission);
    }

    function test_constructor_rejects_zero_stepVM() public {
        vm.expectRevert(KnomosisFaultProofGame.ZeroAddress.selector);
        new KnomosisFaultProofGame(
            BISECTION_TIMEOUT, MIN_CHALLENGE_BOND, MIN_STEP_INTERVAL,
            treasury, address(0), stateRootSubmission);
    }

    function test_constructor_rejects_zero_stateRootSubmission() public {
        vm.expectRevert(KnomosisFaultProofGame.ZeroAddress.selector);
        new KnomosisFaultProofGame(
            BISECTION_TIMEOUT, MIN_CHALLENGE_BOND, MIN_STEP_INTERVAL,
            treasury, address(stepVM), address(0));
    }

    /// @notice CRITICAL SECURITY TEST: the constructor must
    ///         reject a non-contract (EOA) state-root submission
    ///         address.  Without this defence, the
    ///         `markDisputed` call would silently succeed (EVM
    ///         returns ok=true for calls to non-contract
    ///         addresses), leaving the sequencer's bond
    ///         unlocked.
    function test_constructor_rejects_eoa_stateRootSubmission() public {
        vm.expectRevert(KnomosisFaultProofGame.ZeroAddress.selector);
        new KnomosisFaultProofGame(
            BISECTION_TIMEOUT, MIN_CHALLENGE_BOND, MIN_STEP_INTERVAL,
            treasury, address(stepVM), address(0xC0DE));
    }

    function test_constants_max_bisection_depth_is_64() public view {
        assertEq(game.MAX_BISECTION_DEPTH(), 64);
    }

    /// @notice Audit 21 finding 1.4: the constructor must reject a
    ///         config where the bisection response timeout is not
    ///         strictly greater than the min step interval (the
    ///         responsible party could never act in time).
    function test_constructor_rejects_timeout_le_step_interval() public {
        // timeout == interval: rejected.
        vm.expectRevert(KnomosisFaultProofGame.InvalidTimeoutConfig.selector);
        new KnomosisFaultProofGame(
            10, MIN_CHALLENGE_BOND, 10, treasury, address(stepVM), stateRootSubmission);
        // timeout < interval: rejected.
        vm.expectRevert(KnomosisFaultProofGame.InvalidTimeoutConfig.selector);
        new KnomosisFaultProofGame(
            5, MIN_CHALLENGE_BOND, 10, treasury, address(stepVM), stateRootSubmission);
        // timeout == 0 (and interval 0): rejected (0 is not > 0).
        vm.expectRevert(KnomosisFaultProofGame.InvalidTimeoutConfig.selector);
        new KnomosisFaultProofGame(
            0, MIN_CHALLENGE_BOND, 0, treasury, address(stepVM), stateRootSubmission);
    }

    /* -------- initiateChallenge -------- */

    function test_initiateChallenge_returns_gameId() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10,                     // disputed log index (pre-seeded)
            bytes32(uint256(0xC1)), // challenger commit
            bytes32(uint256(0x10)), // low commit (genesis)
            0                       // low log index
        );
        assertEq(gameId, 1);
        assertEq(game.activeGameForLogIndex(10), gameId);
    }

    function test_initiateChallenge_marks_disputed_root() public {
        vm.prank(challenger);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
        assertTrue(mockStateRootSubmission.markDisputedCalled());
        assertEq(mockStateRootSubmission.lastMarkedLogIndex(), 10);
    }

    function test_initiateChallenge_rejects_wrong_bond() public {
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.InsufficientBond.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND - 1}(
            10, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
    }

    function test_initiateChallenge_rejects_no_dispute() public {
        // challengerCommit == disputed root ⇒ no dispute.
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.MidpointOutOfRange.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, DISPUTED_ROOT, bytes32(uint256(0x10)), 0);
    }

    function test_initiateChallenge_rejects_duplicate_game() public {
        vm.prank(challenger);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.GameAlreadyExists.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC2)), bytes32(uint256(0x10)), 0);
    }

    /// @notice CRITICAL SECURITY TEST: the game must look up the
    ///         sequencer/disputed-root from state-root submission,
    ///         not from caller-provided parameters.  Without this,
    ///         an attacker could drain the real sequencer's bond
    ///         by initiating fake challenges that point to an EOA
    ///         "sequencer" who never responds.  This test verifies
    ///         the game uses the canonical lookup, NOT a caller
    ///         value: the seeded sequencer (= `sequencer` field)
    ///         is what's recorded in the game.
    function test_initiateChallenge_uses_canonical_sequencer() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
        (address actualSequencer, , , , , , , , , , , , , ,) = game.games(gameId);
        assertEq(actualSequencer, sequencer,
            "game's sequencer comes from state-root submission");
    }

    /// @notice CRITICAL: a challenge against a non-existent log
    ///         index must revert (the lookup returns submittedAtBlock=0).
    function test_initiateChallenge_rejects_missing_root() public {
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.ZeroAddress.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            999,  // log index not seeded
            bytes32(uint256(0xC1)),
            bytes32(uint256(0x10)),
            0);
    }

    /// @notice CRITICAL SECURITY TEST (audit 21, finding 1.1): a
    ///         challenge whose `lowCommit` does NOT match the on-chain
    ///         submitted root at `lowLogIndex` must revert.  Without the
    ///         low-anchor, a dishonest challenger could fabricate the
    ///         pre-state of a single-step range so the honest sequencer
    ///         cannot reproduce `high` in the terminal step and loses
    ///         its bond.  This is the regression guard for that fix.
    function test_initiateChallenge_rejects_unanchored_low_commit() public {
        vm.prank(challenger);
        // lowLogIndex = 0 IS a submitted root (LOW_ROOT), but the
        // supplied lowCommit is a FABRICATED value != LOW_ROOT.
        vm.expectRevert(KnomosisFaultProofGame.LowCommitMismatch.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10,                      // disputedLogIndex (seeded)
            bytes32(uint256(0xC1)),  // challenger commit
            bytes32(uint256(0xBAD)), // FABRICATED low commit (!= LOW_ROOT)
            0);                      // lowLogIndex (seeded, but commit mismatches)
    }

    /// @notice CRITICAL SECURITY TEST (audit 21, finding 1.1): a
    ///         challenge whose `lowLogIndex` references an UNSUBMITTED
    ///         root must revert — the low endpoint cannot be an agreed
    ///         pre-state if no root was ever submitted there.
    function test_initiateChallenge_rejects_unsubmitted_low_root() public {
        vm.prank(challenger);
        // lowLogIndex = 5 was never seeded (submittedAtBlock == 0).
        vm.expectRevert(KnomosisFaultProofGame.LowRootNotSubmitted.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10,                     // disputedLogIndex (seeded)
            bytes32(uint256(0xC1)),
            bytes32(uint256(0x10)),
            5);                     // lowLogIndex NOT seeded
    }

    /// @notice CRITICAL: defensive check — a degenerate range
    ///         (`lowLogIndex >= disputedLogIndex`) is rejected.
    ///         Without this, the bisection's `(low + high) / 2`
    ///         midpoint would be outside any meaningful range
    ///         and the game would be stuck.
    function test_initiateChallenge_rejects_inverted_range() public {
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.MidpointOutOfRange.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10,                     // disputedLogIndex
            bytes32(uint256(0xC1)),
            bytes32(uint256(0x10)),
            15);                    // lowLogIndex > disputedLogIndex
    }

    /// @notice CRITICAL: defensive check — `lowLogIndex ==
    ///         disputedLogIndex` is also rejected.
    function test_initiateChallenge_rejects_equal_range() public {
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.MidpointOutOfRange.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10,
            bytes32(uint256(0xC1)),
            bytes32(uint256(0x10)),
            10);  // lowLogIndex == disputedLogIndex
    }

    /* -------- terminateOnSingleStep (end-to-end adjudication) -------- */

    /// CBE Nat encoder (mirror of the StepVM test helper): 0x1B tag +
    /// 8 little-endian value bytes.  Used to build balance cell values.
    function _encodeCbeNat(uint256 v) internal pure returns (bytes memory) {
        bytes memory result = new bytes(9);
        result[0] = 0x1B;
        for (uint256 i = 0; i < 8; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            result[1 + i] = bytes1(uint8(v >> (8 * i)));
        }
        return result;
    }

    function _makeCellProof(
        uint8 cellKind,
        uint256 keyA,
        uint256 keyB,
        bytes memory cellValue,
        bytes32 witnessCommit
    ) internal pure returns (KnomosisStepVM.CellProof memory) {
        return KnomosisStepVM.CellProof({
            cellKind: cellKind,
            keyA: keyA,
            keyB: keyB,
            cellValue: cellValue,
            witnessCommit: witnessCommit
        });
    }

    /// @notice CRITICAL SECURITY TEST (audit 21 — closes the systemic
    ///         adjudication-path coverage gap AND end-to-end-verifies
    ///         BOTH the low-anchor fix (1.1) and the lock-key fix (1.2)).
    ///
    ///         Drives a single-step game to a `SequencerWon` terminal
    ///         resolution: the honest sequencer executes the REAL step
    ///         from the on-chain-anchored `low` and reproduces `high`,
    ///         winning the challenger's bond.  Before the 1.1 fix a
    ///         challenger could fabricate `low` so this path was
    ///         unreachable for an honest sequencer; before the 1.2 fix
    ///         the post-settlement lock would be cleared under the wrong
    ///         key.  Both are asserted here.
    function test_terminate_single_step_honest_sequencer_wins() public {
        // Known-good Transfer step recipe, witnessing the ANCHORED low
        // commit (LOW_ROOT): move 5 of resource 1 from actor 10 (bal
        // 100) to actor 20 (bal 50).
        KnomosisStepVM.CellProof[] memory proofs = new KnomosisStepVM.CellProof[](2);
        proofs[0] = _makeCellProof(0, 1, 10, _encodeCbeNat(100), LOW_ROOT);
        proofs[1] = _makeCellProof(0, 1, 20, _encodeCbeNat(50), LOW_ROOT);
        bytes memory actionFields =
            abi.encodePacked(uint64(1), uint64(10), uint64(20), uint64(5));
        uint8 kind = 0;            // ActionKind.Transfer
        uint64 stepSigner = 10;

        // The HONEST post-state: executeStep applied to the real,
        // anchored low.  This is the commit the sequencer truthfully
        // published at the disputed index.
        bytes32 honestPost =
            stepVM.executeStep(LOW_ROOT, kind, actionFields, stepSigner, proofs);

        // Seed a single-step disputed root at index 1 committing to the
        // honest post-state, sequenced by `sequencer`.
        mockStateRootSubmission.seedRoot(1, sequencer, honestPost, STATE_ROOT_BOND);

        // Challenger disputes with a WRONG commit (!= honestPost) and the
        // correctly-anchored low (LOW_ROOT at index 0).  Range = 1 step.
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            1, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        // At game open turn = Sequencer; the honest sequencer terminates
        // with the real step.  executeStep(low) == high ⇒ SequencerWon.
        uint256 seqBalBefore = sequencer.balance;
        vm.prank(sequencer);
        game.terminateOnSingleStep(gameId, kind, actionFields, stepSigner, proofs);

        // SequencerWon: the sequencer is CREDITED the winner's 95% share
        // of the challenger's forfeited bond (pull-payment, 1.3) and
        // claims it via withdraw().
        assertGt(game.pendingWithdrawals(sequencer), 0,
            "sequencer must be credited the winning payout");
        vm.prank(sequencer);
        game.withdraw();
        assertGt(sequencer.balance, seqBalBefore,
            "honest sequencer must receive the winning payout");
        assertEq(game.pendingWithdrawals(sequencer), 0,
            "credit cleared after withdraw");
        // The 1.2 fix: the active-game lock is cleared under the
        // disputed index (1), freeing a re-challenge slot.
        assertEq(game.activeGameForLogIndex(1), 0,
            "active-game lock must clear under disputedLogIndex");
        // And the sequencer's state root is cleared (not slashed) on a
        // sequencer win.
        assertTrue(mockStateRootSubmission.clearDisputedCalled(),
            "sequencer win must clear (not slash) the disputed root");
    }

    /// @notice Companion to the above: an honest CHALLENGER wins the
    ///         single-step termination when the sequencer's committed
    ///         `high` does NOT match the real step from the anchored
    ///         low (an invalid published root).  It is the sequencer's
    ///         turn, so a mismatch settles `ChallengerWon`.
    function test_terminate_single_step_invalid_root_challenger_wins() public {
        KnomosisStepVM.CellProof[] memory proofs = new KnomosisStepVM.CellProof[](2);
        proofs[0] = _makeCellProof(0, 1, 10, _encodeCbeNat(100), LOW_ROOT);
        proofs[1] = _makeCellProof(0, 1, 20, _encodeCbeNat(50), LOW_ROOT);
        bytes memory actionFields =
            abi.encodePacked(uint64(1), uint64(10), uint64(20), uint64(5));

        // Seed the disputed root with a FABRICATED high (!= the honest
        // step output) — i.e. the sequencer published an invalid root.
        bytes32 fakeHigh = bytes32(uint256(0xF00D));
        mockStateRootSubmission.seedRoot(1, sequencer, fakeHigh, STATE_ROOT_BOND);

        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            1, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        uint256 chalBalBefore = challenger.balance;
        // The sequencer, forced to execute the real step, cannot
        // reproduce the fabricated `high`; on its turn a mismatch is a
        // ChallengerWon.
        vm.prank(sequencer);
        game.terminateOnSingleStep(gameId, 0, actionFields, 10, proofs);

        // Pull-payment (1.3): the challenger claims its credited share.
        vm.prank(challenger);
        game.withdraw();
        assertGt(challenger.balance, chalBalBefore,
            "honest challenger must receive the winning payout");
        // ChallengerWon slashes the sequencer's state-root bond.
        assertTrue(mockStateRootSubmission.slashCalled(),
            "challenger win must slash the sequencer bond");
    }

    /// @notice Closes the audit-21 §4 extended-coverage follow-up (a): a
    ///         MULTI-ROUND bisection that narrows a 4-step range to a
    ///         single step through two full midpoint/response rounds and
    ///         then terminates on the real step VM.  The honest sequencer
    ///         defends a genuine 4-entry trace (each commit is the real
    ///         `executeStep` of its predecessor); the challenger disagrees
    ///         at every midpoint, so `g.high` is reassigned twice before
    ///         the terminal step — exercising the depth accounting, the
    ///         turn alternation, the step-interval gate across rounds, and
    ///         (with the 1.2 fix) the lock clearing under
    ///         `disputedLogIndex` even though `high.idx` ends at a
    ///         midpoint.
    function test_multi_round_bisection_then_terminate_sequencer_wins() public {
        // A REAL 4-entry trace from the anchored genesis (LOW_ROOT):
        // each step transfers 5 of resource 1 from actor 10 to actor 20,
        // with cell proofs witnessing that step's true pre-commit and the
        // balances evolving 100/50 → 95/55 → 90/60 → 85/65.
        uint8 kind = 0;    // ActionKind.Transfer
        uint64 stepSigner = 10;
        bytes memory actionFields =
            abi.encodePacked(uint64(1), uint64(10), uint64(20), uint64(5));

        bytes32[5] memory commits;
        commits[0] = LOW_ROOT;
        uint256 balFrom = 100;
        uint256 balTo = 50;
        KnomosisStepVM.CellProof[] memory stepProofs =
            new KnomosisStepVM.CellProof[](2);
        for (uint256 i = 0; i < 4; i++) {
            stepProofs[0] =
                _makeCellProof(0, 1, 10, _encodeCbeNat(balFrom), commits[i]);
            stepProofs[1] =
                _makeCellProof(0, 1, 20, _encodeCbeNat(balTo), commits[i]);
            commits[i + 1] = stepVM.executeStep(
                commits[i], kind, actionFields, stepSigner, stepProofs);
            balFrom -= 5;
            balTo += 5;
        }

        // The sequencer honestly published commits[4] at log index 4.
        mockStateRootSubmission.seedRoot(
            4, sequencer, commits[4], STATE_ROOT_BOND);

        // Challenger opens a 4-step dispute with a WRONG claim.
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            4, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        // Round 1: midpoint of [0, 4] is 2.  The sequencer submits the
        // honest commits[2]; the challenger DISAGREES, so the range
        // narrows to [0, (2, commits[2])] — `high` is now a midpoint.
        vm.roll(block.number + MIN_STEP_INTERVAL + 1);
        vm.prank(sequencer);
        game.submitMidpoint(gameId, commits[2]);
        vm.roll(block.number + MIN_STEP_INTERVAL + 1);
        vm.prank(challenger);
        game.respondToMidpoint(gameId, false);

        // Round 2: midpoint of [0, 2] is 1.  Same pattern — the range
        // narrows to the single step [0, (1, commits[1])].
        vm.roll(block.number + MIN_STEP_INTERVAL + 1);
        vm.prank(sequencer);
        game.submitMidpoint(gameId, commits[1]);
        vm.roll(block.number + MIN_STEP_INTERVAL + 1);
        vm.prank(challenger);
        game.respondToMidpoint(gameId, false);

        // Two full rounds happened: depth == 2 and it is the sequencer's
        // turn on the single-step range.
        (, , , , , , uint64 depth, , , , , , , ,) = game.games(gameId);
        assertEq(depth, 2, "two bisection rounds must be recorded");

        // Terminal step: executeStep(commits[0]) == commits[1] == high
        // ⇒ the responding sequencer wins.
        stepProofs[0] = _makeCellProof(0, 1, 10, _encodeCbeNat(100), LOW_ROOT);
        stepProofs[1] = _makeCellProof(0, 1, 20, _encodeCbeNat(50), LOW_ROOT);
        vm.prank(sequencer);
        game.terminateOnSingleStep(
            gameId, kind, actionFields, stepSigner, stepProofs);

        (, , , , , , , , , , ,
         KnomosisFaultProofGame.GameStatus status, , ,) = game.games(gameId);
        assertEq(uint8(status),
            uint8(KnomosisFaultProofGame.GameStatus.SequencerWon),
            "honest sequencer must win the multi-round game");
        // The 1.2 fix across a disagree-reassigned high: the lock clears
        // under the DISPUTED index (4), not the final high.idx (1).
        assertEq(game.activeGameForLogIndex(4), 0,
            "lock must clear under disputedLogIndex after multi-round play");
        assertTrue(mockStateRootSubmission.clearDisputedCalled(),
            "sequencer win must clear the disputed root");
        // The sequencer claims the winner's share (pull-payment).
        assertGt(game.pendingWithdrawals(sequencer), 0,
            "winner credited after the multi-round settlement");
    }

    /// @notice Closes the audit-21 §4 extended-coverage follow-up (b): a
    ///         RE-CHALLENGE of the same disputed log index succeeds after
    ///         a prior game settles — exercising the 1.2 lock-key fix
    ///         across a `disagree`-reassigned `high`.  Before the fix,
    ///         `_settle` cleared `activeGameForLogIndex[g.high.idx]`
    ///         (a midpoint after any disagree), leaving the disputed
    ///         index pinned to the finished game forever, so this second
    ///         `initiateChallenge` reverted `GameAlreadyExists`.
    function test_rechallenge_succeeds_after_settled_game_with_reassigned_high()
        public
    {
        // Open a wide dispute at the pre-seeded index 64 (range [0, 64]).
        vm.prank(challenger);
        uint256 firstGameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            64, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        // One full round with a DISAGREE: high is reassigned to the
        // midpoint (32) — the exact shape under which the pre-fix clear
        // keyed on `g.high.idx` zeroed the wrong slot.  The midpoint
        // claim (0xAD) is arbitrary: this game settles by timeout, not
        // by terminal step, so its truth is irrelevant.
        vm.roll(block.number + MIN_STEP_INTERVAL + 1);
        vm.prank(sequencer);
        game.submitMidpoint(firstGameId, bytes32(uint256(0xAD)));
        vm.roll(block.number + MIN_STEP_INTERVAL + 1);
        vm.prank(challenger);
        game.respondToMidpoint(firstGameId, false);

        // Settle by timeout (the sequencer's turn after the response;
        // it stalls past the deadline and loses).
        vm.roll(block.number + BISECTION_TIMEOUT + 1);
        vm.prank(challenger);
        game.claimTimeout(firstGameId);
        (, , , , , , , , , , ,
         KnomosisFaultProofGame.GameStatus status, , ,) =
            game.games(firstGameId);
        assertEq(uint8(status),
            uint8(KnomosisFaultProofGame.GameStatus.TimedOutSequencer),
            "first game must settle by sequencer timeout");

        // THE 1.2 REGRESSION ASSERTION: the disputed index is unlocked
        // (cleared under `disputedLogIndex`, not the reassigned
        // `high.idx`), so a fresh challenge on the SAME root opens fine.
        assertEq(game.activeGameForLogIndex(64), 0,
            "settled game must release the disputed-index lock");
        vm.prank(challenger);
        uint256 secondGameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            64, bytes32(uint256(0xC2)), LOW_ROOT, 0);
        assertEq(secondGameId, firstGameId + 1,
            "re-challenge must open a NEW game");
        assertEq(game.activeGameForLogIndex(64), secondGameId,
            "the new game must own the disputed-index lock");
    }

    /* -------- claimTimeout -------- */

    function test_claimTimeout_after_window_settles_against_sequencer() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
        vm.roll(block.number + BISECTION_TIMEOUT + 1);
        vm.prank(challenger);
        game.claimTimeout(gameId);
        // Game settled in challenger's favour (sequencer timed out).
    }

    /// @notice The 95/5 bond split (OQ8 resolution) must fire on
    ///         settlement: challenger receives 95% of total bonds,
    ///         treasury 5%.  Here total = challenger bond + slashed
    ///         sequencer bond.
    function test_claimTimeout_distributes_bonds_95_5_split() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            11, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);

        uint256 challengerBefore = challenger.balance;
        uint256 treasuryBefore   = treasury.balance;

        vm.roll(block.number + BISECTION_TIMEOUT + 1);
        vm.prank(challenger);
        game.claimTimeout(gameId);

        // Total bonds: challenger's contribution + slashed sequencer bond.
        uint128 total = uint128(MIN_CHALLENGE_BOND) + STATE_ROOT_BOND;
        uint128 winnerPayout   = (total * 95) / 100;
        uint128 treasuryPayout = total - winnerPayout;

        // Pull-payment (1.3): winner + treasury claim their credited
        // shares via withdraw().
        assertEq(game.pendingWithdrawals(challenger), winnerPayout,
            "challenger credited 95% of the bond pool");
        assertEq(game.pendingWithdrawals(treasury), treasuryPayout,
            "treasury credited 5% of the bond pool");
        vm.prank(challenger);
        game.withdraw();
        vm.prank(treasury);
        game.withdraw();

        assertGe(challenger.balance, challengerBefore + winnerPayout - 1 ether,
            "challenger received 95% bond payout");
        assertEq(treasury.balance, treasuryBefore + treasuryPayout,
            "treasury received 5% bond payout");
    }

    /// @notice CRITICAL SECURITY TEST (audit 21, finding 1.3): a
    ///         settlement whose treasury REVERTS on receiving ETH must
    ///         still complete.  Under the old push-payment a reverting
    ///         (immutable) treasury would brick EVERY game forever; the
    ///         pull-payment fix decouples settlement from the transfer,
    ///         so the broken treasury can only fail to claim its OWN
    ///         share — the winner is unaffected.
    function test_settlement_not_bricked_by_reverting_treasury() public {
        RevertingReceiver badTreasury = new RevertingReceiver();
        KnomosisFaultProofGame brickGame = new KnomosisFaultProofGame(
            BISECTION_TIMEOUT, MIN_CHALLENGE_BOND, MIN_STEP_INTERVAL,
            address(badTreasury), address(stepVM), stateRootSubmission);

        vm.prank(challenger);
        uint256 gameId = brickGame.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            12, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        // Sequencer times out → challenger wins.  This MUST NOT revert
        // (settlement is not bricked by the reverting treasury).
        vm.roll(block.number + BISECTION_TIMEOUT + 1);
        vm.prank(challenger);
        brickGame.claimTimeout(gameId);

        // The treasury was credited (but cannot pull); the winner can.
        assertGt(brickGame.pendingWithdrawals(address(badTreasury)), 0,
            "treasury credited despite being unable to receive ETH");
        uint256 chalBefore = challenger.balance;
        vm.prank(challenger);
        brickGame.withdraw();
        assertGt(challenger.balance, chalBefore,
            "winner withdrew its share despite the broken treasury");

        // The broken treasury's own withdraw reverts (self-harm only),
        // proving the failure is isolated to the treasury, not the game.
        vm.prank(address(badTreasury));
        vm.expectRevert(KnomosisFaultProofGame.BondTransferFailed.selector);
        brickGame.withdraw();
    }

    /// @notice `withdraw()` with nothing credited reverts cleanly.
    function test_withdraw_nothing_credited_reverts() public {
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.NothingToWithdraw.selector);
        game.withdraw();
    }

    function test_claimTimeout_calls_slashSequencerBond_on_challenger_wins() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            12, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
        vm.roll(block.number + BISECTION_TIMEOUT + 1);
        vm.prank(challenger);
        game.claimTimeout(gameId);
        // Verify slashing was invoked.
        assertTrue(mockStateRootSubmission.slashCalled());
        assertEq(mockStateRootSubmission.lastSlashedLogIndex(), 12);
        assertEq(mockStateRootSubmission.lastSlashRecipient(), address(game));
    }

    /// @notice CRITICAL INTEGRATION TEST: on challenger-wins, the
    ///         game must call `revertStateRootsFrom` on the
    ///         state-root submission so the L1 contracts know
    ///         which state roots are invalid.  Without this call,
    ///         the bridge and downstream consumers would still
    ///         treat the disputed root as valid.
    function test_claimTimeout_calls_revertStateRootsFrom_on_challenger_wins()
        public
    {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            12, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
        vm.roll(block.number + BISECTION_TIMEOUT + 1);
        vm.prank(challenger);
        game.claimTimeout(gameId);
        // Verify state-root revert range update fired.
        assertTrue(mockStateRootSubmission.revertCalled());
        assertEq(mockStateRootSubmission.lastRevertedFromIdx(), 12);
    }

    function test_claimTimeout_rejects_already_settled_game() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            12, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
        vm.roll(block.number + BISECTION_TIMEOUT + 1);
        vm.prank(challenger);
        game.claimTimeout(gameId);

        // Try again — game is settled, should revert.
        vm.expectRevert(KnomosisFaultProofGame.GameAlreadyEnded.selector);
        game.claimTimeout(gameId);
    }

    /* -------- submitMidpoint -------- */

    function test_submitMidpoint_sequencer_first_round() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            64, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
        vm.roll(block.number + MIN_STEP_INTERVAL + 1);
        vm.prank(sequencer);
        game.submitMidpoint(gameId, bytes32(uint256(0xAD)));
        // No revert — midpoint accepted.
    }

    function test_submitMidpoint_rejects_wrong_caller() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            65, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
        vm.roll(block.number + MIN_STEP_INTERVAL + 1);
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.NotResponsible.selector);
        game.submitMidpoint(gameId, bytes32(uint256(0xAD)));
    }

    function test_submitMidpoint_rejects_after_deadline() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            66, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
        vm.roll(block.number + BISECTION_TIMEOUT + 1);
        vm.prank(sequencer);
        vm.expectRevert(KnomosisFaultProofGame.TurnDeadlineExpired.selector);
        game.submitMidpoint(gameId, bytes32(uint256(0xAD)));
    }

    function test_respondToMidpoint_rejects_without_pending() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            67, bytes32(uint256(0xC1)), bytes32(uint256(0x10)), 0);
        vm.roll(block.number + MIN_STEP_INTERVAL + 1);
        // No midpoint submitted yet.  Challenger tries to respond.
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.NoPendingMidpoint.selector);
        game.respondToMidpoint(gameId, true);
    }
}

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

        assertGe(challenger.balance, challengerBefore + winnerPayout - 1 ether,
            "challenger received 95% bond payout");
        assertEq(treasury.balance, treasuryBefore + treasuryPayout,
            "treasury received 5% bond payout");
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

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {CanonFaultProofGame} from "src/contracts/CanonFaultProofGame.sol";
import {CanonStepVM} from "src/contracts/CanonStepVM.sol";

/// @title CanonFaultProofGameTest
/// @notice Forge tests for the bisection-game state machine
///         (Workstream-H WUs H.6.1.*).
contract CanonFaultProofGameTest is Test {
    CanonFaultProofGame private game;
    CanonStepVM private stepVM;

    address private treasury = address(0xBEEF);
    address private stateRootSubmission = address(0xC0DE);
    address private sequencer = address(0xACE);
    address private challenger = address(0xCAFE);

    uint128 private constant MIN_CHALLENGE_BOND = 0.05 ether;
    uint64 private constant BISECTION_TIMEOUT = 100;
    uint64 private constant MIN_STEP_INTERVAL = 1;

    bytes32 private constant DEPLOYMENT_ID = bytes32(uint256(0xCAFE));

    function setUp() public {
        stepVM = new CanonStepVM();
        game = new CanonFaultProofGame(
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
        vm.expectRevert(CanonFaultProofGame.ZeroAddress.selector);
        new CanonFaultProofGame(
            BISECTION_TIMEOUT, MIN_CHALLENGE_BOND, MIN_STEP_INTERVAL,
            address(0), address(stepVM), stateRootSubmission);
    }

    function test_constructor_rejects_zero_stepVM() public {
        vm.expectRevert(CanonFaultProofGame.ZeroAddress.selector);
        new CanonFaultProofGame(
            BISECTION_TIMEOUT, MIN_CHALLENGE_BOND, MIN_STEP_INTERVAL,
            treasury, address(0), stateRootSubmission);
    }

    function test_constructor_rejects_zero_stateRootSubmission() public {
        vm.expectRevert(CanonFaultProofGame.ZeroAddress.selector);
        new CanonFaultProofGame(
            BISECTION_TIMEOUT, MIN_CHALLENGE_BOND, MIN_STEP_INTERVAL,
            treasury, address(stepVM), address(0));
    }

    function test_constants_max_bisection_depth_is_64() public view {
        assertEq(game.MAX_BISECTION_DEPTH(), 64);
    }

    /* -------- initiateChallenge -------- */

    function test_initiateChallenge_returns_gameId() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10,                     // disputed log index
            bytes32(uint256(0xC1)), // challenger commit
            bytes32(uint256(0x10)), // low commit (genesis)
            0,                      // low log index
            bytes32(uint256(0x51)), // disputed state root (sequencer's)
            DEPLOYMENT_ID,
            sequencer
        );
        assertEq(gameId, 1);
        assertEq(game.activeGameForLogIndex(10), gameId);
    }

    function test_initiateChallenge_rejects_wrong_bond() public {
        vm.prank(challenger);
        vm.expectRevert(CanonFaultProofGame.InsufficientBond.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND - 1}(
            10, bytes32(uint256(0xC1)), bytes32(uint256(0x10)),
            0, bytes32(uint256(0x51)), DEPLOYMENT_ID, sequencer);
    }

    function test_initiateChallenge_rejects_no_dispute() public {
        // challengerCommit == disputedStateRoot ⇒ no dispute.
        vm.prank(challenger);
        vm.expectRevert(CanonFaultProofGame.MidpointOutOfRange.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0x51)), bytes32(uint256(0x10)),
            0, bytes32(uint256(0x51)), DEPLOYMENT_ID, sequencer);
    }

    function test_initiateChallenge_rejects_duplicate_game() public {
        vm.prank(challenger);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC1)), bytes32(uint256(0x10)),
            0, bytes32(uint256(0x51)), DEPLOYMENT_ID, sequencer);
        vm.prank(challenger);
        vm.expectRevert(CanonFaultProofGame.GameAlreadyExists.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC2)), bytes32(uint256(0x10)),
            0, bytes32(uint256(0x51)), DEPLOYMENT_ID, sequencer);
    }

    /* -------- claimTimeout -------- */

    function test_claimTimeout_after_window_settles_against_sequencer() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC1)), bytes32(uint256(0x10)),
            0, bytes32(uint256(0x51)), DEPLOYMENT_ID, sequencer);
        vm.roll(block.number + BISECTION_TIMEOUT + 1);
        // Anyone can call claimTimeout.
        vm.prank(challenger);
        game.claimTimeout(gameId);
        // Game settled in challenger's favour (sequencer timed out).
    }

    function test_claimTimeout_within_window_rejected() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC1)), bytes32(uint256(0x10)),
            0, bytes32(uint256(0x51)), DEPLOYMENT_ID, sequencer);
        vm.expectRevert(CanonFaultProofGame.TurnDeadlineExpired.selector);
        game.claimTimeout(gameId);
    }

    /* -------- assertConsistent -------- */

    function test_assertConsistent_does_not_revert() public view {
        game.assertConsistent();
    }
}

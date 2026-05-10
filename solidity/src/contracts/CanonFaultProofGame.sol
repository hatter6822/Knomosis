// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Canon  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {CanonStepVM} from "./CanonStepVM.sol";

/// @title CanonFaultProofGame
/// @notice The bisection game state machine on L1 (Workstream H
///         WUs H.6.1 – H.6.3).
///
/// Mirrors the Lean-side `LegalKernel.FaultProof.Game` module
/// line-for-line.  Cross-stack equivalence is established by
/// the WU H.10.2 fixture corpus.
contract CanonFaultProofGame is ReentrancyGuard {
    /* ---------------------------------------------------------- */
    /* Constants                                                  */
    /* ---------------------------------------------------------- */

    /// @notice Maximum bisection depth.  Per plan §2:
    ///         `MAX_BISECTION_DEPTH = 64`.
    uint64 public constant MAX_BISECTION_DEPTH = 64;

    /// @notice Per-round timeout in L1 blocks.
    uint64 public immutable BISECTION_RESPONSE_TIMEOUT;

    /// @notice Minimum challenger bond.
    uint128 public immutable MIN_CHALLENGE_BOND;

    /// @notice Minimum L1 blocks between two bisection steps in
    ///         the same game (anti-DoS).
    uint64 public immutable MIN_BISECTION_STEP_INTERVAL_BLOCKS;

    /// @notice The treasury address (receives the 5% bond
    ///         redistribution per OQ8 resolution).
    address public immutable treasury;

    /// @notice The step VM contract.
    CanonStepVM public immutable stepVM;

    /// @notice The state-root submission contract.
    address public immutable stateRootSubmission;

    /* ---------------------------------------------------------- */
    /* Game data structures (mirrors Lean's `GameState`)          */
    /* ---------------------------------------------------------- */

    /// @notice A state-root assertion: at log index `idx`, the
    ///         state root is `commit`.
    struct Claim {
        uint64  idx;
        bytes32 commit;
    }

    enum TurnSide { Sequencer, Challenger }
    enum GameStatus {
        InProgress,
        SequencerWon,
        ChallengerWon,
        TimedOutSequencer,
        TimedOutChallenger
    }

    struct Game {
        address     sequencer;
        address     challenger;
        Claim       low;
        Claim       high;
        bool        hasPendingMidpoint;
        Claim       pendingMidpoint;
        uint64      depth;
        TurnSide    turn;
        uint64      turnDeadline;
        uint128     sequencerBond;
        uint128     challengerBond;
        GameStatus  status;
        bytes32     deploymentId;
        uint64      lastStepBlock;
    }

    /// @notice Per-game state.
    mapping(uint256 => Game) public games;

    /// @notice Next-gameId counter.
    uint256 public nextGameId;

    /// @notice Per-disputed-log-index single-game-per-root
    ///         lock.  OQ7 resolution.
    mapping(uint64 => uint256) public activeGameForLogIndex;

    /* ---------------------------------------------------------- */
    /* Events                                                     */
    /* ---------------------------------------------------------- */

    event FaultProofGameOpened(
        uint256 indexed gameId,
        address indexed challenger,
        bytes32 disputedStateRoot,
        bytes32 challengerStateRoot
    );

    event BisectionMidpointSubmitted(
        uint256 indexed gameId,
        address indexed party,
        uint64  idx,
        bytes32 commit
    );

    event BisectionResponseSubmitted(
        uint256 indexed gameId,
        address indexed party,
        bool    agree
    );

    event FaultProofGameSettled(
        uint256 indexed gameId,
        GameStatus status,
        address indexed winner,
        uint128 winnerPayout
    );

    /* ---------------------------------------------------------- */
    /* Errors                                                     */
    /* ---------------------------------------------------------- */

    error ZeroAddress();
    error InsufficientBond();
    error WrongTurn();
    error TurnDeadlineExpired();
    error NoPendingMidpoint();
    error MidpointAlreadyPending();
    error MidpointOutOfRange();
    error RangeNotSingleStep();
    error GameAlreadyEnded();
    error NotResponsible();
    error BondTransferFailed();
    error BisectionStepTooFast();
    error GameAlreadyExists();
    error DepthCapExceeded();

    /* ---------------------------------------------------------- */
    /* Constructor                                                */
    /* ---------------------------------------------------------- */

    constructor(
        uint64  _bisectionResponseTimeout,
        uint128 _minChallengeBond,
        uint64  _minBisectionStepInterval,
        address _treasury,
        address _stepVM,
        address _stateRootSubmission
    ) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_stepVM == address(0)) revert ZeroAddress();
        if (_stateRootSubmission == address(0)) revert ZeroAddress();

        BISECTION_RESPONSE_TIMEOUT = _bisectionResponseTimeout;
        MIN_CHALLENGE_BOND = _minChallengeBond;
        MIN_BISECTION_STEP_INTERVAL_BLOCKS = _minBisectionStepInterval;
        treasury = _treasury;
        stepVM = CanonStepVM(_stepVM);
        stateRootSubmission = _stateRootSubmission;
    }

    /* ---------------------------------------------------------- */
    /* External: initiateChallenge (WU H.6.1b)                    */
    /* ---------------------------------------------------------- */

    function initiateChallenge(
        uint64  disputedLogIndex,
        bytes32 challengerCommit,
        bytes32 lowCommit,
        uint64  lowLogIndex,
        bytes32 disputedStateRoot,
        bytes32 deploymentId,
        address sequencer
    ) external payable nonReentrant returns (uint256 gameId) {
        if (msg.value != MIN_CHALLENGE_BOND) revert InsufficientBond();
        if (challengerCommit == disputedStateRoot)
            revert MidpointOutOfRange();  // no actual dispute
        if (activeGameForLogIndex[disputedLogIndex] != 0)
            revert GameAlreadyExists();

        gameId = ++nextGameId;
        Game storage g = games[gameId];
        g.sequencer       = sequencer;
        g.challenger      = msg.sender;
        g.low             = Claim({ idx: lowLogIndex, commit: lowCommit });
        g.high            = Claim({ idx: disputedLogIndex,
                                    commit: disputedStateRoot });
        g.hasPendingMidpoint = false;
        g.depth           = 0;
        g.turn            = TurnSide.Sequencer;
        g.turnDeadline    = uint64(block.number) + BISECTION_RESPONSE_TIMEOUT;
        g.sequencerBond   = 0;  // funded by stateRootSubmission contract
        g.challengerBond  = uint128(msg.value);
        g.status          = GameStatus.InProgress;
        g.deploymentId    = deploymentId;
        g.lastStepBlock   = uint64(block.number);

        activeGameForLogIndex[disputedLogIndex] = gameId;

        emit FaultProofGameOpened(
            gameId, msg.sender, disputedStateRoot, challengerCommit
        );
    }

    /* ---------------------------------------------------------- */
    /* External: submitMidpoint (WU H.6.1c)                       */
    /* ---------------------------------------------------------- */

    function submitMidpoint(
        uint256 gameId,
        bytes32 midpointCommit
    ) external nonReentrant {
        Game storage g = games[gameId];
        if (g.status != GameStatus.InProgress) revert GameAlreadyEnded();
        if (block.number > g.turnDeadline) revert TurnDeadlineExpired();
        if (g.hasPendingMidpoint) revert MidpointAlreadyPending();
        if (block.number <
            g.lastStepBlock + MIN_BISECTION_STEP_INTERVAL_BLOCKS)
            revert BisectionStepTooFast();

        address responsible = g.turn == TurnSide.Sequencer ?
                              g.sequencer : g.challenger;
        if (msg.sender != responsible) revert NotResponsible();

        uint64 mpIdx = (g.low.idx + g.high.idx) / 2;
        if (mpIdx <= g.low.idx || mpIdx >= g.high.idx)
            revert MidpointOutOfRange();

        g.pendingMidpoint = Claim({ idx: mpIdx, commit: midpointCommit });
        g.hasPendingMidpoint = true;
        g.turn = g.turn == TurnSide.Sequencer ?
                 TurnSide.Challenger : TurnSide.Sequencer;
        g.turnDeadline = uint64(block.number) + BISECTION_RESPONSE_TIMEOUT;
        g.lastStepBlock = uint64(block.number);

        emit BisectionMidpointSubmitted(gameId, msg.sender, mpIdx,
                                        midpointCommit);
    }

    /* ---------------------------------------------------------- */
    /* External: respondToMidpoint (WU H.6.1d)                    */
    /* ---------------------------------------------------------- */

    function respondToMidpoint(
        uint256 gameId,
        bool    agree
    ) external nonReentrant {
        Game storage g = games[gameId];
        if (g.status != GameStatus.InProgress) revert GameAlreadyEnded();
        if (block.number > g.turnDeadline) revert TurnDeadlineExpired();
        if (!g.hasPendingMidpoint) revert NoPendingMidpoint();
        if (block.number <
            g.lastStepBlock + MIN_BISECTION_STEP_INTERVAL_BLOCKS)
            revert BisectionStepTooFast();

        address responsible = g.turn == TurnSide.Sequencer ?
                              g.sequencer : g.challenger;
        if (msg.sender != responsible) revert NotResponsible();

        if (agree) {
            // Range narrows to [pending, high].
            g.low = g.pendingMidpoint;
        } else {
            // Range narrows to [low, pending].
            g.high = g.pendingMidpoint;
        }

        g.hasPendingMidpoint = false;
        g.depth++;
        if (g.depth > MAX_BISECTION_DEPTH) revert DepthCapExceeded();
        g.turn = g.turn == TurnSide.Sequencer ?
                 TurnSide.Challenger : TurnSide.Sequencer;
        g.turnDeadline = uint64(block.number) + BISECTION_RESPONSE_TIMEOUT;
        g.lastStepBlock = uint64(block.number);

        emit BisectionResponseSubmitted(gameId, msg.sender, agree);
    }

    /* ---------------------------------------------------------- */
    /* External: terminateOnSingleStep (WU H.6.1e)                */
    /* ---------------------------------------------------------- */

    function terminateOnSingleStep(
        uint256 gameId,
        bytes calldata signedActionBytes,
        CanonStepVM.CellProof[] calldata cellProofs,
        bytes32 claimedPostCommit
    ) external nonReentrant {
        Game storage g = games[gameId];
        if (g.status != GameStatus.InProgress) revert GameAlreadyEnded();
        if (g.high.idx - g.low.idx != 1) revert RangeNotSingleStep();
        if (g.hasPendingMidpoint) revert MidpointAlreadyPending();

        address responsible = g.turn == TurnSide.Sequencer ?
                              g.sequencer : g.challenger;
        if (msg.sender != responsible) revert NotResponsible();

        // Call the step VM.
        bytes32 computedPostCommit = stepVM.executeStep(
            g.low.commit, signedActionBytes, cellProofs);

        if (computedPostCommit == claimedPostCommit) {
            // Responding party wins.
            _settle(gameId,
              g.turn == TurnSide.Sequencer
              ? GameStatus.SequencerWon
              : GameStatus.ChallengerWon);
        } else {
            // Opposing party wins.
            _settle(gameId,
              g.turn == TurnSide.Sequencer
              ? GameStatus.ChallengerWon
              : GameStatus.SequencerWon);
        }
    }

    /* ---------------------------------------------------------- */
    /* External: claimTimeout (WU H.6.1f)                         */
    /* ---------------------------------------------------------- */

    function claimTimeout(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        if (g.status != GameStatus.InProgress) revert GameAlreadyEnded();
        if (block.number <= g.turnDeadline) revert TurnDeadlineExpired();

        // The non-responding party loses by timeout.
        if (g.turn == TurnSide.Sequencer) {
            _settle(gameId, GameStatus.TimedOutSequencer);
        } else {
            _settle(gameId, GameStatus.TimedOutChallenger);
        }
    }

    /* ---------------------------------------------------------- */
    /* Internal: _settle (WU H.6.1g)                              */
    /* ---------------------------------------------------------- */

    function _settle(uint256 gameId, GameStatus finalStatus) internal {
        Game storage g = games[gameId];
        uint128 totalBonds = g.sequencerBond + g.challengerBond;
        address payable winner;

        if (finalStatus == GameStatus.SequencerWon ||
            finalStatus == GameStatus.TimedOutChallenger) {
            winner = payable(g.sequencer);
        } else {
            winner = payable(g.challenger);
        }

        g.status = finalStatus;
        // Clear the active-game lock.
        activeGameForLogIndex[g.high.idx] = 0;

        // OQ8 resolution: 95% to winner, 5% to treasury.
        uint128 winnerPayout    = (totalBonds * 95) / 100;
        uint128 treasuryPayout  = totalBonds - winnerPayout;

        // CEI ordering: state mutation done; external calls last.
        if (winnerPayout > 0) {
            (bool ok, ) = winner.call{value: winnerPayout}("");
            if (!ok) revert BondTransferFailed();
        }
        if (treasuryPayout > 0) {
            (bool ok, ) = payable(treasury).call{value: treasuryPayout}("");
            if (!ok) revert BondTransferFailed();
        }

        emit FaultProofGameSettled(gameId, finalStatus, winner, winnerPayout);
    }

    /* ---------------------------------------------------------- */
    /* assertConsistent                                           */
    /* ---------------------------------------------------------- */

    function assertConsistent() external view {
        require(treasury != address(0), "ZeroTreasury");
        require(address(stepVM) != address(0), "ZeroStepVM");
        require(stateRootSubmission != address(0), "ZeroStateRootSubmission");
        require(MAX_BISECTION_DEPTH == 64, "DepthCapMustBe64");
    }
}

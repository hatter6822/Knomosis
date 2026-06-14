// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {KnomosisStepVM} from "./KnomosisStepVM.sol";

/// @notice Minimal interface for the state-root submission
///         contract's dispute-locking, bond-slashing, flag-
///         clearing, and per-root lookup entry points.  Used by
///         the fault-proof game to lock the sequencer's bond when
///         a challenge starts, to slash on challenger-wins, to
///         clear the disputed flag on sequencer-wins so the bond
///         can be released via `finaliseStateRoot`, and to
///         authoritatively look up the actual submitter / state
///         root for a disputed log index.
interface IStateRootSubmission {
    function markDisputed(uint64 logIndex) external;
    function clearDisputed(uint64 logIndex) external;
    function slashSequencerBond(uint64 logIndex, address recipient) external;
    function revertStateRootsFrom(uint64 fromIdx) external;
    /// @notice The canonical accessor for the per-root record.
    ///         Returns (sequencer, stateCommit, prevLogEntryHash,
    ///         expectedNextHash, bond, submittedAtBlock, finalised,
    ///         disputed).
    function roots(uint64 logIndex) external view returns (
        address sequencer,
        bytes32 stateCommit,
        bytes32 prevLogEntryHash,
        bytes32 expectedNextHash,
        uint128 bond,
        uint64  submittedAtBlock,
        bool    finalised,
        bool    disputed
    );
    /// @notice The deployment ID of the state-root submission
    ///         contract; the game inherits this binding to
    ///         prevent cross-deployment replay.
    function deploymentId() external view returns (bytes32);
}

/// @title KnomosisFaultProofGame
/// @notice The bisection game state machine on L1 (Workstream H
///         WUs H.6.1 – H.6.3).
///
/// Mirrors the Lean-side `LegalKernel.FaultProof.Game` module
/// line-for-line.  Cross-stack equivalence is established by
/// the WU H.10.2 fixture corpus.
contract KnomosisFaultProofGame is ReentrancyGuard {
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
    KnomosisStepVM public immutable stepVM;

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
        /// @notice The disputed log index — used to slash the
        ///         sequencer's state-root bond on settlement.
        uint64      disputedLogIndex;
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
    /// @notice The `low` interval endpoint references a log index with
    ///         no submitted state root, so it cannot be an agreed
    ///         (on-chain anchored) pre-state.
    error LowRootNotSubmitted();
    /// @notice The supplied `lowCommit` does not equal the on-chain
    ///         submitted state root at `lowLogIndex`.  The low endpoint
    ///         MUST be anchored to an agreed root (mirroring `high`),
    ///         else a dishonest challenger could fabricate a pre-state
    ///         and slash an honest sequencer in the terminal step.
    error LowCommitMismatch();

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
        // Defence-in-depth: require the state-root submission
        // address to be a contract.  Without this, a misconfigured
        // (EOA) address would silently accept the `markDisputed`
        // and `slashSequencerBond` raw-calls below (EVM returns
        // ok=true for calls to non-contract addresses), leaving
        // the sequencer's bond unlocked.
        if (_stateRootSubmission.code.length == 0) revert ZeroAddress();
        if (_stepVM.code.length == 0) revert ZeroAddress();

        BISECTION_RESPONSE_TIMEOUT = _bisectionResponseTimeout;
        MIN_CHALLENGE_BOND = _minChallengeBond;
        MIN_BISECTION_STEP_INTERVAL_BLOCKS = _minBisectionStepInterval;
        treasury = _treasury;
        stepVM = KnomosisStepVM(_stepVM);
        stateRootSubmission = _stateRootSubmission;
    }

    /* ---------------------------------------------------------- */
    /* External: initiateChallenge (WU H.6.1b)                    */
    /* ---------------------------------------------------------- */

    /// @notice Initiate a challenge against the disputed state
    ///         root at `disputedLogIndex`.  The challenger asserts
    ///         the canonical commit should be `challengerCommit`.
    ///
    ///         **Authoritative lookup**: the disputed state root,
    ///         the actual submitter (sequencer), and the
    ///         deployment ID are looked up from
    ///         `KnomosisStateRootSubmission` based on
    ///         `disputedLogIndex`.  Caller-provided values for
    ///         these fields would be a critical vulnerability:
    ///         an attacker could specify a non-existent address
    ///         as "sequencer" so the game's
    ///         `responsible`-party gating points to an EOA that
    ///         never responds, then time out the game and
    ///         siphon the real sequencer's slashed bond.
    function initiateChallenge(
        uint64  disputedLogIndex,
        bytes32 challengerCommit,
        bytes32 lowCommit,
        uint64  lowLogIndex
    ) external payable nonReentrant returns (uint256 gameId) {
        if (msg.value != MIN_CHALLENGE_BOND) revert InsufficientBond();
        if (activeGameForLogIndex[disputedLogIndex] != 0)
            revert GameAlreadyExists();
        // Sanity check: low must precede high.  Without this,
        // the bisection's `(low + high) / 2` midpoint could end
        // up outside any meaningful range, and the game would
        // be stuck.  Defensive: reject degenerate ranges.
        if (lowLogIndex >= disputedLogIndex) revert MidpointOutOfRange();

        // Authoritative lookup of the disputed state root + its
        // submitter from the state-root submission contract.
        IStateRootSubmission sub = IStateRootSubmission(stateRootSubmission);
        (
            address rootSequencer,
            bytes32 rootStateCommit,
            /* prevLogEntryHash */,
            /* expectedNextHash */,
            /* bond */,
            uint64  submittedAtBlock,
            bool    finalised,
            /* disputed */
        ) = sub.roots(disputedLogIndex);

        // Validate the disputed root exists and is challengeable.
        if (submittedAtBlock == 0) revert ZeroAddress();
        if (finalised) revert GameAlreadyEnded();
        if (challengerCommit == rootStateCommit)
            revert MidpointOutOfRange();  // no actual dispute

        // Anchor the LOW endpoint to the on-chain submitted root at
        // `lowLogIndex` — exactly as `high` is anchored to the disputed
        // root above.  WITHOUT this, `lowCommit` is attacker-controlled:
        // a dishonest challenger could open a single-step range with a
        // FABRICATED pre-state so the honest sequencer's terminal
        // `stepVM.executeStep(g.low.commit, …)` cannot reproduce the
        // real `high.commit`, losing the sequencer its bond.  The
        // bisection's soundness REQUIRES `low` be an agreed commit
        // (FaultProof/Game.lean: "both parties have agreed on the
        // commits at `low` and `high`").  We require `low` reference a
        // submitted root and match its committed state (option A — the
        // agreed-anchor floor; a deployment that additionally wants the
        // low root *finalised* layers that on at the submission level).
        (
            /* lowSequencer */,
            bytes32 lowStateCommit,
            /* prevLogEntryHash */,
            /* expectedNextHash */,
            /* bond */,
            uint64  lowSubmittedAtBlock,
            /* finalised */,
            /* disputed */
        ) = sub.roots(lowLogIndex);
        if (lowSubmittedAtBlock == 0) revert LowRootNotSubmitted();
        if (lowCommit != lowStateCommit) revert LowCommitMismatch();

        // Cache the deployment ID from the state-root submission
        // contract (the canonical source).  Caller cannot spoof
        // a different deploymentId for cross-deployment-replay
        // attacks.
        bytes32 rootDeploymentId = sub.deploymentId();

        gameId = ++nextGameId;
        Game storage g = games[gameId];
        g.sequencer       = rootSequencer;
        g.challenger      = msg.sender;
        g.low             = Claim({ idx: lowLogIndex, commit: lowCommit });
        g.high            = Claim({ idx: disputedLogIndex,
                                    commit: rootStateCommit });
        g.hasPendingMidpoint = false;
        g.depth           = 0;
        g.turn            = TurnSide.Sequencer;
        g.turnDeadline    = uint64(block.number) + BISECTION_RESPONSE_TIMEOUT;
        g.sequencerBond   = 0;  // funded by stateRootSubmission contract
        g.challengerBond  = uint128(msg.value);
        g.status          = GameStatus.InProgress;
        g.deploymentId    = rootDeploymentId;
        g.lastStepBlock   = uint64(block.number);
        g.disputedLogIndex = disputedLogIndex;

        activeGameForLogIndex[disputedLogIndex] = gameId;

        // Lock the sequencer's state-root bond by marking the
        // disputed root.  Without this, the sequencer's bond
        // could be released via `finaliseStateRoot` after the
        // dispute window expires while the game is still in
        // progress — a critical bond-locking bug.
        sub.markDisputed(disputedLogIndex);

        emit FaultProofGameOpened(
            gameId, msg.sender, rootStateCommit, challengerCommit
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
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        KnomosisStepVM.CellProof[] calldata cellProofs
    ) external nonReentrant {
        Game storage g = games[gameId];
        if (g.status != GameStatus.InProgress) revert GameAlreadyEnded();
        if (g.high.idx - g.low.idx != 1) revert RangeNotSingleStep();
        if (g.hasPendingMidpoint) revert MidpointAlreadyPending();

        address responsible = g.turn == TurnSide.Sequencer ?
                              g.sequencer : g.challenger;
        if (msg.sender != responsible) revert NotResponsible();

        // Call the step VM with the per-variant dispatch.
        bytes32 computedPostCommit = stepVM.executeStep(
            g.low.commit, actionKind, actionFields, signer, cellProofs);

        // The disputed endpoint is the committed transcript high point.
        if (computedPostCommit == g.high.commit) {
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
        address payable winner;
        bool challengerWins;

        if (finalStatus == GameStatus.SequencerWon ||
            finalStatus == GameStatus.TimedOutChallenger) {
            winner = payable(g.sequencer);
            challengerWins = false;
        } else {
            winner = payable(g.challenger);
            challengerWins = true;
        }

        g.status = finalStatus;
        // Clear the active-game lock so a re-challenge can open a new
        // game (per OQ7's re-challenge-window resolution).  MUST key on
        // `g.disputedLogIndex` — the value the lock was SET under at
        // `initiateChallenge` — NOT `g.high.idx`, which diverges from it
        // the moment a `respondToMidpoint(disagree)` reassigns
        // `g.high = g.pendingMidpoint` to a midpoint index.  Keying on
        // `g.high.idx` would zero an unrelated slot and leave
        // `activeGameForLogIndex[disputedLogIndex]` pinned to this
        // finished game forever, permanently bricking re-challenge of
        // that root (and, on a sequencer win, letting an invalid root
        // finalise unchallengeably).
        activeGameForLogIndex[g.disputedLogIndex] = 0;

        // If the challenger wins, slash the sequencer's state-root
        // bond.  The slashed bond is forwarded to THIS contract,
        // which then redistributes it alongside the game-level
        // bonds.  This is the missing-on-original "sequencer's
        // bond is slashed in full to challenger on
        // challengerWon" path.
        //
        // CEI: this external call happens BEFORE we redistribute
        // the (now-augmented) bond pool, but it doesn't allow
        // reentrancy into `_settle` itself because the game's
        // status is already updated and reentry would hit
        // `g.status != InProgress` checks elsewhere.
        // `nonReentrant` on the public entries provides
        // belt-and-suspenders.
        uint128 slashedSequencerBond = 0;
        if (challengerWins) {
            uint256 contractBalanceBefore = address(this).balance;
            // Use a typed interface + try-catch so a failure
            // (e.g. bond already zero / root missing) does NOT
            // revert settlement; the game still pays out the
            // challenger's bond.  The actual ETH delta is the
            // canonical slashed-amount measure.
            try IStateRootSubmission(stateRootSubmission)
                  .slashSequencerBond(g.disputedLogIndex, address(this))
            {
                uint256 contractBalanceAfter = address(this).balance;
                uint256 delta = contractBalanceAfter - contractBalanceBefore;
                // The slashed bond is bounded by
                // `STATE_ROOT_SUBMISSION_BOND` (≤ uint128) per the
                // state-root submission contract's invariants;
                // the cast is safe under that bound.
                // forge-lint: disable-next-line(unsafe-typecast)
                slashedSequencerBond = uint128(delta);
                g.sequencerBond = g.sequencerBond + slashedSequencerBond;
            } catch {
                // Slashing failed (e.g. already-zero bond, root
                // missing, transfer failed).  Settlement proceeds
                // with the bonds recorded in the game; the
                // sequencer's state-root bond stays where it was.
            }

            // Mark the state-root range as reverted from the
            // disputed log index.  Without this call, the L1
            // contracts (and downstream consumers like the
            // bridge) would not know which state roots are
            // invalid; `isStateRootReverted` would still return
            // false.  Try-catch so a failure (e.g. range already
            // updated by a concurrent settlement) doesn't block
            // bond redistribution.
            try IStateRootSubmission(stateRootSubmission)
                  .revertStateRootsFrom(g.disputedLogIndex)
            {
                // State-root range updated.
            } catch {
                // Revert call failed; bond redistribution
                // proceeds.  Operators must reconcile off-chain
                // (the game settlement event still emits).
            }
        } else {
            // Sequencer-wins path: clear the disputed flag on the
            // state-root submission so the bond can be released
            // via `finaliseStateRoot` after the dispute window.
            // Try-catch so a failure here doesn't block bond
            // redistribution to the challenger's losing bond
            // (which now goes to the sequencer).
            try IStateRootSubmission(stateRootSubmission)
                  .clearDisputed(g.disputedLogIndex)
            {
                // Cleared; sequencer can finalise the root
                // normally after the dispute window expires.
            } catch {
                // Clear failed (e.g. root missing); the disputed
                // flag stays set.  Operator-side intervention may
                // be needed to release the bond; settlement still
                // proceeds.
            }
        }

        // Recompute the total-bonds pool after possible slashing.
        uint128 totalBonds = g.sequencerBond + g.challengerBond;

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

    /// @notice Receive function so `slashSequencerBond` can
    ///         forward the slashed ETH to this contract.  The
    ///         only legitimate source of inbound ETH is the
    ///         state-root submission contract's slashing call;
    ///         off-band ETH transfers are accepted but have no
    ///         effect on game state.
    receive() external payable {}

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

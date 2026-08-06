// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {KnomosisStepVMRoot} from "./KnomosisStepVMRoot.sol";

import {ActionsRoot} from "../lib/ActionsRoot.sol";
import {CBEEncode} from "../lib/CBEEncode.sol";
import {Secp256k1} from "../lib/Secp256k1.sol";
import {SignInput} from "../lib/SignInput.sol";
import {SmtCellVerifier} from "../lib/SmtCellVerifier.sol";
import {StepVMMerkle} from "../lib/StepVMMerkle.sol";

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
    /// @notice The canonical accessor for the per-batch record.
    ///         Returns (sequencer, stateCommit, prevLogEntryHash,
    ///         expectedNextHash, bond, submittedAtBlock, finalised,
    ///         disputed, prevEndIndex, actionsRoot) — the two batch
    ///         fields APPENDED last (SB risk-register item 1), so
    ///         every pre-existing positional destructuring keeps its
    ///         slots.
    function roots(uint64 logIndex) external view returns (
        address sequencer,
        bytes32 stateCommit,
        bytes32 prevLogEntryHash,
        bytes32 expectedNextHash,
        uint128 bond,
        uint64  submittedAtBlock,
        bool    finalised,
        bool    disputed,
        uint64  prevEndIndex,
        bytes32 actionsRoot
    );
    /// @notice Record-level reverted test (SB ruling R1); the game
    ///         refuses to open on a reverted record (ruling R2).
    function isStateRootReverted(uint64 logIndex)
        external view returns (bool);
    /// @notice The deployment ID of the state-root submission
    ///         contract; the game inherits this binding to
    ///         prevent cross-deployment replay.
    function deploymentId() external view returns (bytes32);
}

/// @notice Minimal interface for the V2 dispute verifier's
///         fault-proof leg (SB ruling R6): on a challenger win the
///         game calls this, and the verifier — the bridge's
///         `faultProofRollbackAuthority` — drives the revert
///         through to the bridge's fund-safety gates.
interface IDisputeVerifierV2 {
    function finaliseFromFaultProof(uint256 gameId, uint64 revertFromIdx) external;
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
    KnomosisStepVMRoot public immutable stepVM;

    /// @notice The state-root submission contract.
    address public immutable stateRootSubmission;

    /// @notice The V2 dispute verifier (SB ruling R6): on a
    ///         challenger win, `_settle` calls its
    ///         `finaliseFromFaultProof`, which drives the revert
    ///         through to the BRIDGE's fund-safety gates — the leg
    ///         the registry-only revert never reached.  Zero =
    ///         disabled (a deployment without the bridge wiring).
    ///         Forward reference (V2 takes this game's address in
    ///         its own constructor), so no code-existence check is
    ///         possible; the deploy scripts require-check the
    ///         predicted address.
    address public immutable disputeVerifier;

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

    /// @notice Pull-payment ledger (audit 21, finding 1.3): settlement
    ///         CREDITS the winner's and treasury's bond shares here
    ///         instead of pushing ETH, so a reverting recipient can
    ///         never brick `_settle`.  Recipients claim via `withdraw()`.
    mapping(address => uint256) public pendingWithdrawals;

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
    /// @notice The constructor's `bisectionResponseTimeout` is not
    ///         strictly greater than `minBisectionStepInterval`, so the
    ///         responsible party could be unable to act before the
    ///         deadline and would always lose by timeout (audit 21, 1.4).
    error InvalidTimeoutConfig();
    /// @notice A pull-payment withdrawal was attempted with nothing
    ///         credited, or its transfer failed.
    error NothingToWithdraw();
    /// @notice The `(actionKind, actionFields, signer, sig)` tuple
    ///         supplied to `terminateOnSingleStep` does not open at
    ///         the disputed step's log index under the batch's
    ///         actions root (SB ruling R7).
    ///
    ///         Without this check the terminal step executed WHATEVER
    ///         action the responding party submitted, and the L1 had no
    ///         record of which action the L2 actually ran — so a party
    ///         about to lose could search for a different action whose
    ///         step reproduces the disputed root and settle in its
    ///         favour on a step that never happened.  The retired
    ///         per-action registry authenticated by re-deriving one
    ///         chain link; a batch record commits to its actions as an
    ///         SMT root, so the authentication is an inclusion proof.
    error ActionNotInBatch();
    /// @notice `initiateChallenge`'s `lowLogIndex` is not the disputed
    ///         record's `prevEndIndex` (SB ruling R2).  The game
    ///         bisects INSIDE one batch: its low anchor is the batch's
    ///         start — the parent record's agreed commit — and nothing
    ///         else is on-chain-agreed within the range.
    error LowNotBatchStart();
    /// @notice The disputed record is reverted (SB ruling R2): it is
    ///         already judged, and a game on it would re-litigate a
    ///         range the chain no longer stands on.
    error DisputedRootReverted();
    /// @notice The constructor's `_minChallengeBond` is zero.  A zero
    ///         minimum bond lets a challenger open a game with nothing at
    ///         risk (`initiateChallenge` accepts `msg.value == 0`) while
    ///         still `markDisputed`-locking the honest sequencer's bond —
    ///         making frivolous challenges free.  Reject it at deploy time.
    error InvalidBondConfig();

    /* ---------------------------------------------------------- */
    /* Constructor                                                */
    /* ---------------------------------------------------------- */

    constructor(
        uint64  _bisectionResponseTimeout,
        uint128 _minChallengeBond,
        uint64  _minBisectionStepInterval,
        address _treasury,
        address _stepVM,
        address _stateRootSubmission,
        address _disputeVerifier
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
        // Finding 1.4 (audit 21): the responsible party must be able to
        // act before its deadline.  `submitMidpoint` / `respondToMidpoint`
        // gate on `block.number >= lastStepBlock + MIN_BISECTION_STEP_
        // INTERVAL_BLOCKS` while the deadline is `lastStepBlock +
        // BISECTION_RESPONSE_TIMEOUT`; if the interval >= the timeout the
        // responsible party can NEVER respond in time and always loses by
        // `claimTimeout`.  Reject that configuration footgun (this also
        // forces `_bisectionResponseTimeout > 0`).
        if (_bisectionResponseTimeout <= _minBisectionStepInterval)
            revert InvalidTimeoutConfig();
        // The challenge bond exists to make opening a dispute costly; a zero
        // minimum would make frivolous challenges free.
        if (_minChallengeBond == 0) revert InvalidBondConfig();

        BISECTION_RESPONSE_TIMEOUT = _bisectionResponseTimeout;
        MIN_CHALLENGE_BOND = _minChallengeBond;
        MIN_BISECTION_STEP_INTERVAL_BLOCKS = _minBisectionStepInterval;
        treasury = _treasury;
        stepVM = KnomosisStepVMRoot(_stepVM);
        stateRootSubmission = _stateRootSubmission;
        // Zero = disabled; non-zero is a forward reference the
        // deploy scripts require-check (see the immutable's doc).
        disputeVerifier = _disputeVerifier;
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

        // Authoritative lookup of the disputed batch record + its
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
            /* disputed */,
            uint64  prevEndIndex,
            /* actionsRoot */
        ) = sub.roots(disputedLogIndex);

        // Validate the disputed record exists and is challengeable.
        if (submittedAtBlock == 0) revert ZeroAddress();
        if (finalised) revert GameAlreadyEnded();
        // A reverted record is already judged (SB ruling R2).
        if (sub.isStateRootReverted(disputedLogIndex))
            revert DisputedRootReverted();
        if (challengerCommit == rootStateCommit)
            revert MidpointOutOfRange();  // no actual dispute

        // The game bisects INSIDE the disputed batch: the low anchor
        // is the batch's start (SB ruling R2) — the parent record's
        // key — because that is the one index below `disputedLogIndex`
        // whose commit is on-chain-agreed.
        if (lowLogIndex != prevEndIndex) revert LowNotBatchStart();

        // Anchor the LOW endpoint to the on-chain submitted root at
        // `lowLogIndex` — exactly as `high` is anchored to the disputed
        // root above.  WITHOUT this, `lowCommit` is attacker-controlled:
        // a dishonest challenger could open a single-step range with a
        // FABRICATED pre-state so the honest sequencer's terminal
        // `stepVM.executeStepToRoot(g.low.commit, …)` cannot reproduce the
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
            /* disputed */,
            /* prevEndIndex */,
            /* actionsRoot */
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
        // Depth PRE-check (SB riding-along item): refuse the midpoint
        // that would take the game past the cap, rather than
        // accepting it and refusing the RESPONSE.  The Lean and Rust
        // mirrors already gate here; without this the L1 charged the
        // responder for a move the game could never absorb.
        if (g.depth >= MAX_BISECTION_DEPTH) revert DepthCapExceeded();
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
        bytes calldata actionSig,
        bytes calldata actionProof,
        KnomosisStepVMRoot.OpenedCell[] calldata opened,
        bytes calldata gapMask,
        bytes calldata siblings,
        bytes calldata registryValue,
        bytes calldata registryProof
    ) external nonReentrant {
        Game storage g = games[gameId];
        if (g.status != GameStatus.InProgress) revert GameAlreadyEnded();
        if (g.high.idx - g.low.idx != 1) revert RangeNotSingleStep();
        if (g.hasPendingMidpoint) revert MidpointAlreadyPending();

        address responsible = g.turn == TurnSide.Sequencer ?
                              g.sequencer : g.challenger;
        if (msg.sender != responsible) revert NotResponsible();

        // Authenticate the action against the disputed batch's
        // actions root BEFORE executing it (SB ruling R7).  Under the
        // entry-count convention the single step carries state
        // `g.low.idx` to `g.low.idx + 1`, so the disputed action's
        // absolute log index is `g.low.idx`; its leaf under the
        // batch's actions root is the SIGNATURE-BOUND commit
        // `keccak256(kind ‖ uint64BE signer ‖ fields ‖ sig)`, and the
        // inclusion proof walks it to the root the sequencer folded
        // into the chain when it published the record.  The signature
        // is hashed here and VERIFIED below (Workstream F-A): this
        // check answers "is this the action the batch committed?",
        // the signature gate answers "was it authorised?".
        //
        // The batch is read via the game's own immutable
        // `g.disputedLogIndex` (SB ruling R2) — never a
        // caller-supplied batch id — and read at terminate rather
        // than cached at challenge time: a submitted record is
        // immutable at its key while a game is open (`markDisputed`
        // blocks reclaim, so the R3 overwrite path cannot fire), so
        // the value cannot have moved.
        _requireActionInBatch(
            g.disputedLogIndex, g.low.idx,
            actionKind, actionFields, signer, actionSig, actionProof);

        // Run the step VM.  It returns a state ROOT — computed by
        // folding the step's DERIVED cell writes into `g.low.commit` —
        // so the comparison below is between two values of the same
        // construction.  It was not: `executeStep` returned a bespoke
        // per-variant hash, so the comparison never succeeded and an
        // honest sequencer lost every game it correctly defended.
        //
        // The bundle is a DEDUPLICATING PRE-ROOT MULTIPROOF: every cell
        // opened once against `g.low.commit`, sharing one sibling list,
        // rather than one opening per write against a running root.
        // Four consequences the game relies on.  The pre-root is
        // checked ONCE, against `g.low.commit`, so no intermediate root
        // is materialised or trusted.  A cell written twice — a
        // self-transfer, which anyone can submit — is opened once, so
        // the responsible party is not charged for a second walk that
        // lands the value the first already did.  Order carries no
        // information, so a permuted bundle settles identically and the
        // responsible party cannot lose on a formatting question.  And
        // the wire's length is derived from the cell set, so a
        // truncated proof reverts rather than being padded out and
        // walked to some other root.
        //
        // `g.high.idx` is the log index the disputed action produced,
        // and `withdraw`'s pending-withdrawal record carries it — so
        // the game supplies the index it is adjudicating rather than
        // the step VM guessing one.
        bytes32 computedPostCommit = stepVM.executeStepToRootMulti(
            g.low.commit, actionKind, actionFields, signer,
            g.high.idx, opened, gapMask, siblings);

        // F-A: the SIGNATURE gate.  The batch leaf binds the 65-byte
        // signature (ruling R7) and the check above authenticates it;
        // this verifies it.  The signer's registered key is resolved
        // by a single-cell opening against `g.low.commit`, the nonce
        // comes off the frontier the step VM has just VERIFIED against
        // the same root (so a sequencer cannot sign over a nonce of
        // its choosing), the digest is the canonical §8.8.5 sign-input
        // recomputed on-chain, and `ecrecover` must land on the
        // registered key's address.  An INVALID signature makes the
        // disputed entry inadmissible: the truthful post-state of an
        // entry the L2 kernel would have refused is the PRE-state, so
        // the adjudicated root becomes `g.low.commit` — the full
        // no-op, nonce included — and a sequencer defending a forged
        // entry loses to any endpoint that claims a state change.
        if (!_signatureValid(
                g.low.commit, g.deploymentId, actionKind, actionFields,
                signer, actionSig, opened, registryValue, registryProof)) {
            computedPostCommit = g.low.commit;
        }

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

    /// @notice Revert unless the submitted signed action opens at
    ///         `stepIndex` under the disputed batch's actions root.
    ///
    /// @dev    Extracted from `terminateOnSingleStep` to keep that
    ///         function's stack shallow under `via_ir`.  The SMT key
    ///         is DERIVED from `stepIndex` inside
    ///         `ActionsRoot.verifyActionInclusion`, so the proof can
    ///         only speak about the disputed step's own slot.
    function _requireActionInBatch(
        uint64 disputedEndIndex,
        uint64 stepIndex,
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        bytes calldata actionSig,
        bytes calldata actionProof
    ) internal view {
        (
            /* sequencer */,
            /* stateCommit */,
            /* prevLogEntryHash */,
            /* expectedNextHash */,
            /* bond */,
            /* submittedAtBlock */,
            /* finalised */,
            /* disputed */,
            /* prevEndIndex */,
            bytes32 batchActionsRoot
        ) = IStateRootSubmission(stateRootSubmission).roots(disputedEndIndex);

        bytes32 commit = ActionsRoot.actionLeafCommit(
            actionKind, signer, actionFields, actionSig);
        if (!ActionsRoot.verifyActionInclusion(
                batchActionsRoot, stepIndex, commit, actionProof)) {
            revert ActionNotInBatch();
        }
    }

    /// @notice The registry cell kind — `CellTag.registry` on the
    ///         Lean side, `StepWrites.CELL_REGISTRY` on the step VM.
    uint8 internal constant CELL_REGISTRY = 2;

    /// @notice The nonce cell kind — `CellTag.nonce` on the Lean
    ///         side; in every adjudicable frontier, keyed by signer.
    uint8 internal constant CELL_NONCE = 1;

    /// @notice The supplied registry opening does not verify against
    ///         the disputed range's pre-state root.  Retryable — the
    ///         true opening exists for both a present and an absent
    ///         registry cell, so the responsible party resubmits with
    ///         it rather than losing on a malformed proof.
    error RegistryOpeningInvalid();

    /// @dev The F-A signature verdict.  `true` iff the committed
    ///      65-byte `(r ‖ s ‖ v)` signature verifies — low-s,
    ///      `v ∈ {27, 28}`, `ecrecover` of the recomputed §8.8.5
    ///      digest equal to the address of the signer's REGISTERED
    ///      key.  Everything uninterpretable is `false`, never a
    ///      revert: an unregistered signer, a key that is not a
    ///      33-byte SEC1-compressed secp256k1 point, a mis-width or
    ///      malleable signature — each is a state of the world the
    ///      game must ADJUDICATE (the entry was inadmissible), not a
    ///      calldata defect the caller can fix.  The single revert is
    ///      a registry opening that fails to verify against the
    ///      pre-root, which IS a calldata defect.
    ///
    ///      The nonce is read from the `opened` frontier, which the
    ///      step VM has already verified against the same pre-root
    ///      (its call precedes this one and reverts on any frontier
    ///      forgery), so the digest is over the pre-state's expected
    ///      nonce — the only value the L2 admission gate would have
    ///      accepted a signature for.
    function _signatureValid(
        bytes32 preRoot,
        bytes32 deploymentId,
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        bytes calldata actionSig,
        KnomosisStepVMRoot.OpenedCell[] calldata opened,
        bytes calldata registryValue,
        bytes calldata registryProof
    ) internal view returns (bool) {
        // 1. Authenticate the registry opening against the pre-root.
        //    An absent cell (the unregistered signer) opens from the
        //    canonical empty leaf; a present one from
        //    `keccak256(cbe(key) ‖ cbe(value))`.
        {
            bytes memory smtKey = abi.encodePacked(
                StepVMMerkle.deriveCellSmtKey(
                    CELL_REGISTRY, uint256(signer), 0));
            bool isAbsent = registryValue.length == 0;
            bytes32 leaf = StepVMMerkle.cellLeafHash(
                isAbsent,
                isAbsent
                    ? bytes("")
                    : bytes.concat(
                        CBEEncode.bytesValue(smtKey),
                        CBEEncode.bytesValue(registryValue)));
            if (SmtCellVerifier.recomputeRootFromLeaf(
                    smtKey, leaf, registryProof) != preRoot) {
                revert RegistryOpeningInvalid();
            }
            if (isAbsent) {
                // Unregistered signer: no key can have authorised the
                // entry.
                return false;
            }
        }

        // 2. Decode the registered key from its CBE byte-string cell
        //    value: `0x02` tag + 8-byte LE length + payload.  The
        //    value is root-verified, so a malformed shape means the
        //    L2 state genuinely holds bytes this gate cannot
        //    interpret — fail closed.
        if (registryValue.length < 9 || uint8(registryValue[0]) != 0x02) {
            return false;
        }
        uint256 pkLen = 0;
        for (uint256 i = 0; i < 8; i++) {
            pkLen |= uint256(uint8(registryValue[1 + i])) << (8 * i);
        }
        if (pkLen != registryValue.length - 9 || pkLen != 33) {
            return false;
        }
        (bool pkOk, address keyAddr) =
            Secp256k1.tryToAddress(registryValue[9:]);
        if (!pkOk) {
            return false;
        }

        // 3. The wire signature: 65 bytes, `v ∈ {27, 28}`, low-s
        //    (EIP-2 — `ecrecover` itself accepts high-s, and the L1
        //    must not defend a signature the L2 adaptor refuses).
        if (actionSig.length != 65) {
            return false;
        }
        uint8 v = uint8(actionSig[64]);
        if (v != 27 && v != 28) {
            return false;
        }
        bytes32 r = bytes32(actionSig[0:32]);
        bytes32 s = bytes32(actionSig[32:64]);
        if (uint256(s) > Secp256k1.N_HALF) {
            return false;
        }

        // 4. The nonce, off the step-VM-verified frontier: the
        //    9-byte CBE uint cell (`0x00` tag + 8-byte LE).
        (bool nonceOk, uint64 nonce) = _frontierNonce(opened, signer);
        if (!nonceOk) {
            return false;
        }

        // 5. Recompute the §8.8.5 digest and recover.
        bytes32 digest = SignInput.signingDigest(
            actionKind, actionFields, signer, nonce,
            abi.encodePacked(deploymentId));
        address recovered = ecrecover(digest, v, r, s);
        return recovered != address(0) && recovered == keyAddr;
    }

    /// @dev Read the signer's nonce cell pre-value from the frontier.
    ///      The frontier reaching this point has been verified by the
    ///      step VM against the pre-root, and every adjudicable
    ///      variant's derived cell set includes the signer's nonce —
    ///      so a miss or a malformed value is fail-closed rather than
    ///      reachable on an honest call.
    function _frontierNonce(
        KnomosisStepVMRoot.OpenedCell[] calldata opened,
        uint64 signer
    ) private pure returns (bool ok, uint64 nonce) {
        for (uint256 i = 0; i < opened.length; i++) {
            KnomosisStepVMRoot.OpenedCell calldata c = opened[i];
            if (c.cellKind == CELL_NONCE && c.keyA == uint256(signer)
                    && c.keyB == 0) {
                bytes calldata v = c.preValue;
                if (v.length != 9 || uint8(v[0]) != 0x00) {
                    return (false, 0);
                }
                uint256 n = 0;
                for (uint256 j = 0; j < 8; j++) {
                    n |= uint256(uint8(v[1 + j])) << (8 * j);
                }
                // casting to 'uint64' is exact: the 8-byte LE payload
                // is by construction below 2^64.
                // forge-lint: disable-next-line(unsafe-typecast)
                return (true, uint64(n));
            }
        }
        return (false, 0);
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

            // Drive the revert THROUGH to the bridge (SB ruling
            // R6): the registry rollback above never reached the
            // bridge's fund-safety gates (withdrawals,
            // redemptions), so `bridge.isStateRootReverted` stayed
            // false after a challenger win — one of the two
            // pre-existing defects this workstream closes.  The
            // path is game → V2 verifier (the bridge's
            // `faultProofRollbackAuthority`) → bridge.  Try/catch
            // like the other settlement legs: a mis-wired verifier
            // must not block bond redistribution, and the operator
            // reconciles off-chain from the settlement event.
            if (disputeVerifier != address(0)) {
                try IDisputeVerifierV2(disputeVerifier)
                      .finaliseFromFaultProof(gameId, g.disputedLogIndex)
                {
                    // Bridge-side reverted range updated.
                } catch {
                    // Bridge leg failed; settlement proceeds.
                }
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

        // Finding 1.3 (audit 21): PULL-payment, not push.  Crediting the
        // payouts here (no external call) means settlement can NEVER be
        // bricked by a recipient that reverts on receive — in
        // particular a misconfigured / reverting `treasury` (immutable)
        // could otherwise brick EVERY game globally, and a
        // contract-`winner`/`loser` could deny the opposing party their
        // win.  Recipients pull via `withdraw()`.  CEI is preserved
        // (`g.status` was set above; no external call occurs in `_settle`).
        if (winnerPayout > 0) {
            pendingWithdrawals[winner] += winnerPayout;
        }
        if (treasuryPayout > 0) {
            pendingWithdrawals[treasury] += treasuryPayout;
        }

        emit FaultProofGameSettled(gameId, finalStatus, winner, winnerPayout);
    }

    /// @notice Pull-payment withdrawal (audit 21, finding 1.3).  A
    ///         settled game's winner and the treasury claim their
    ///         credited bond shares here.  `nonReentrant` + strict CEI
    ///         (zero the credit BEFORE the transfer); a failed transfer
    ///         reverts the whole call leaving the credit intact, so a
    ///         caller can always retry.  Decoupling the transfer from
    ///         `_settle` means a recipient that reverts on receive can
    ///         only ever fail to claim its OWN funds — it can no longer
    ///         brick settlement for everyone.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert BondTransferFailed();
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
        // **The linked step VM is the MULTIPROOF build.**  Probed
        // through the game's own reference rather than asserted about
        // the address the deploy script happens to hold, so a game
        // wired to a stale step VM fails at DEPLOY time.
        //
        // Without this the failure is invisible until the first
        // terminate: `terminateOnSingleStep` would call a selector the
        // linked contract does not implement, hit its fallback and
        // revert — and a reverting terminal step costs the responsible
        // party the game by timeout, on a step it correctly defended.
        //
        // `widestFrontier` is the probe because it exists only on the
        // multiproof build and its answer is checkable: the widest
        // adjudicable write set plus the read-only policy cell, which
        // must fit the opening cap the same contract publishes.  The
        // probe buffer carries slack over the step VM's own
        // `PROBE_FIELD_BYTES` floor (160 since the Workstream SB
        // 136-byte kind-19 layout) so a future layout widening moves
        // the floor without silently breaking this deploy-time check.
        uint256 widest = stepVM.widestFrontier(new bytes(256));
        require(widest > 0, "StepVMNotMultiproof");
        require(widest <= stepVM.MAX_CELL_OPENINGS(), "StepVMFrontierExceedsCap");
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
//  This program comes with ABSOLUTELY NO WARRANTY.
//  This is free software, and you are welcome to redistribute it
//  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
pragma solidity 0.8.20;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title KnomosisStateRootSubmission
/// @notice Sequencer state-root submission registry for the
///         Workstream-H fault-proof game (per WUs H.7.1 – H.7.4).
///
/// Each submission posts `STATE_ROOT_SUBMISSION_BOND` ETH and
/// starts the `FAULT_PROOF_DISPUTE_WINDOW` countdown.  Roots are
/// finalised after the window expires with no successful challenge.
///
/// Following Workstream-E §20 immutability discipline: no admin
/// roles, no upgrade proxies, no `pause()` functions.  Recovery
/// from bugs is via `KnomosisFaultProofMigration`.
///
/// **Hash-chain integrity** (WU H.7.4): each submission's
/// `prevLogEntryHash` must match the previous submission's
/// `expectedNextHash`, preventing out-of-order or skipped indices.
///
/// **Anti-DoS** (WU H.7.3): immutable rate-limit constants
/// (submission interval, outstanding cap) set at construction.
contract KnomosisStateRootSubmission is ReentrancyGuard {
    /* ---------------------------------------------------------- */
    /* Immutables                                                 */
    /* ---------------------------------------------------------- */

    /// @notice The required bond per state-root submission.
    uint128 public immutable STATE_ROOT_SUBMISSION_BOND;
    /// @notice The dispute window in L1 blocks.
    uint64  public immutable FAULT_PROOF_DISPUTE_WINDOW;
    /// @notice Minimum L1 blocks between two submissions by the
    ///         same sequencer.
    uint64  public immutable MIN_SUBMISSION_INTERVAL_BLOCKS;
    /// @notice Maximum unfinalised roots per sequencer.
    uint64  public immutable MAX_OUTSTANDING_ROOTS_PER_SEQUENCER;
    /// @notice The pre-approved sequencer.  Single-sequencer
    ///         model per Workstream-H plan §3.3 (multi-sequencer
    ///         is OQ3, deferred).
    address public immutable sequencer;
    /// @notice The fault-proof game contract address.  Used for
    ///         cross-validation.
    address public immutable faultProofGame;
    /// @notice The deployment ID for cross-deployment-replay
    ///         protection.
    bytes32 public immutable deploymentId;

    /* ---------------------------------------------------------- */
    /* Storage                                                    */
    /* ---------------------------------------------------------- */

    /// @notice Submitted state-root record.
    struct SubmittedRoot {
        address sequencer;
        bytes32 stateCommit;
        bytes32 prevLogEntryHash;
        bytes32 expectedNextHash;
        uint128 bond;
        uint64  submittedAtBlock;
        bool    finalised;
        bool    disputed;
    }

    /// @notice Per-log-index submission record.
    mapping(uint64 => SubmittedRoot) public roots;

    /// @notice Last-submission-block per sequencer (for rate
    ///         limiting).
    mapping(address => uint64) public lastSubmissionBlock;

    /// @notice Outstanding-roots counter per sequencer.
    mapping(address => uint64) public outstandingRootsCount;

    /// @notice Range of revoked log indices using the
    ///         (floor, ceiling) pair mechanism from `KnomosisBridge`.
    ///         `floor` is `lowestRevertedLogIndex`; `ceiling` is
    ///         `highestRevertedLogIndex`.  A root at `idx ∈ [floor,
    ///         ceiling]` is considered reverted; this avoids the
    ///         per-index iteration that a simple "is-reverted"
    ///         boolean map would require.
    ///
    ///         `lowestRevertedLogIndex` is initialised to
    ///         `NO_REVERTED_FLOOR` (`type(uint64).max`) rather than to
    ///         zero, so "no floor set" is distinguishable from "the
    ///         floor is index 0".  With a zero sentinel, reverting from
    ///         index 0 — the genesis root — was indistinguishable from
    ///         never having reverted anything, and
    ///         `isStateRootReverted` returned `false` for every index.
    uint64 public lowestRevertedLogIndex = NO_REVERTED_FLOOR;
    uint64 public highestRevertedLogIndex;

    /// @notice Sentinel for "no reverted floor has been set".  Chosen as
    ///         `type(uint64).max` because it is above every reachable
    ///         log index, so the `idx >= floor` half of the range test
    ///         is false for all of them without a separate guard.
    uint64 public constant NO_REVERTED_FLOOR = type(uint64).max;

    /// @notice Highest log index ever passed to `submitStateRoot`.
    ///         Maintained with a `max` because submission is NOT
    ///         monotone: the hash-chain check only requires the
    ///         PREDECESSOR to exist, so indices can be filled in an
    ///         order that revisits a lower one.  This is the ceiling
    ///         `revertStateRootsFrom` reverts up to.
    uint64 public latestSubmittedLogIndex;

    /* ---------------------------------------------------------- */
    /* Events                                                     */
    /* ---------------------------------------------------------- */

    event StateRootSubmitted(
        uint64  indexed logIndex,
        bytes32 stateCommit,
        address indexed sequencer
    );

    event StateRootFinalised(
        uint64  indexed logIndex,
        address indexed sequencer
    );

    event StateRootRangeReverted(
        uint64  indexed floor,
        uint64  indexed ceiling
    );

    /// @notice Emitted when a state root is marked disputed by the
    ///         fault-proof game.  The bond is locked until the
    ///         dispute resolves.
    event StateRootDisputed(
        uint64  indexed logIndex,
        address indexed sequencer
    );

    /// @notice Emitted when a sequencer's bond is slashed on a
    ///         successful challenge.  The slashed amount is
    ///         forwarded to the recipient address.
    event SequencerBondSlashed(
        uint64  indexed logIndex,
        address indexed sequencer,
        address indexed recipient,
        uint128 amount
    );

    /* ---------------------------------------------------------- */
    /* Errors                                                     */
    /* ---------------------------------------------------------- */

    error NotSequencer();
    error NotFaultProofGame();
    error SubmissionTooFrequent();
    error TooManyOutstandingRoots();
    error AlreadyClaimed();
    error InvalidBond();
    error HashChainBroken();
    error RootMissing();
    error AlreadyDisputed();
    error AlreadySlashed();
    error BondAlreadyZero();
    error SlashTransferFailed();
    error PreviousRootMissing();
    error NotYetFinalisable();
    error AlreadyFinalised();
    error DisputeInProgress();
    error ZeroAddress();
    error WindowTooShort();
    /// @notice Constructor guard: the `sequencer` (posts roots) and the
    ///         `faultProofGame` (privileged `markDisputed` caller) must be
    ///         distinct principals; collapsing them would let one address
    ///         both submit and adjudicate its own roots.
    error SequencerIsFaultProofGame();

    /* ---------------------------------------------------------- */
    /* Constructor                                                */
    /* ---------------------------------------------------------- */

    constructor(
        uint128 _bond,
        uint64  _disputeWindow,
        uint64  _minSubmissionInterval,
        uint64  _maxOutstandingRoots,
        address _sequencer,
        address _faultProofGame,
        bytes32 _deploymentId,
        uint64  _withdrawalFinalisationWindow
    ) {
        if (_sequencer == address(0)) revert ZeroAddress();
        if (_faultProofGame == address(0)) revert ZeroAddress();
        // Privilege separation: the sequencer and the fault-proof game are
        // distinct principals (one submits roots, the other adjudicates).
        if (_sequencer == _faultProofGame) revert SequencerIsFaultProofGame();
        // Bond must be > 0 — otherwise slashing is meaningless and
        // a misbehaving sequencer pays no cost on detection.
        if (_bond == 0) revert InvalidBond();
        // Dispute window must be > 0 — otherwise instant finality
        // bypasses the fault-proof game entirely.
        if (_disputeWindow == 0) revert WindowTooShort();
        if (_disputeWindow < _withdrawalFinalisationWindow)
            revert WindowTooShort();
        // Submission cadence must be > 0 — otherwise a sequencer
        // can spam state roots with no rate limit.
        if (_minSubmissionInterval == 0) revert SubmissionTooFrequent();
        // Outstanding-roots cap must be > 0 — otherwise no roots
        // can be submitted (the first submission would already
        // hit `>= 0`).
        if (_maxOutstandingRoots == 0) revert TooManyOutstandingRoots();

        STATE_ROOT_SUBMISSION_BOND = _bond;
        FAULT_PROOF_DISPUTE_WINDOW = _disputeWindow;
        MIN_SUBMISSION_INTERVAL_BLOCKS = _minSubmissionInterval;
        MAX_OUTSTANDING_ROOTS_PER_SEQUENCER = _maxOutstandingRoots;
        sequencer = _sequencer;
        faultProofGame = _faultProofGame;
        deploymentId = _deploymentId;
    }

    /* ---------------------------------------------------------- */
    /* External: submitStateRoot (WU H.7.1 + H.7.4)               */
    /* ---------------------------------------------------------- */

    /// @notice Submit a new state root.  Only the registered
    ///         sequencer can call.
    function submitStateRoot(
        uint64  logIndex,
        bytes32 stateCommit,
        bytes32 prevLogEntryHash
    ) external payable nonReentrant {
        if (msg.sender != sequencer) revert NotSequencer();
        if (msg.value != STATE_ROOT_SUBMISSION_BOND) revert InvalidBond();
        if (roots[logIndex].submittedAtBlock != 0) revert AlreadyClaimed();

        // Rate limit (WU H.7.3).
        if (block.number <
            lastSubmissionBlock[msg.sender] + MIN_SUBMISSION_INTERVAL_BLOCKS)
            revert SubmissionTooFrequent();
        if (outstandingRootsCount[msg.sender] >=
            MAX_OUTSTANDING_ROOTS_PER_SEQUENCER)
            revert TooManyOutstandingRoots();

        // Hash-chain integrity check (WU H.7.4).
        if (logIndex > 0) {
            SubmittedRoot memory prev = roots[logIndex - 1];
            if (prev.submittedAtBlock == 0) revert PreviousRootMissing();
            if (prev.expectedNextHash != prevLogEntryHash)
                revert HashChainBroken();
        }

        // Compute this root's expected-next-hash.
        bytes32 expectedNextHash =
            keccak256(abi.encode(prevLogEntryHash, stateCommit));

        roots[logIndex] = SubmittedRoot({
            sequencer:        msg.sender,
            stateCommit:      stateCommit,
            prevLogEntryHash: prevLogEntryHash,
            expectedNextHash: expectedNextHash,
            bond:             uint128(msg.value),
            submittedAtBlock: uint64(block.number),
            finalised:        false,
            disputed:         false
        });

        lastSubmissionBlock[msg.sender] = uint64(block.number);
        outstandingRootsCount[msg.sender]++;
        if (logIndex > latestSubmittedLogIndex) {
            latestSubmittedLogIndex = logIndex;
        }

        emit StateRootSubmitted(logIndex, stateCommit, msg.sender);
    }

    /* ---------------------------------------------------------- */
    /* External: finaliseStateRoot (WU H.7.2)                     */
    /* ---------------------------------------------------------- */

    /// @notice Finalise a state root after the dispute window
    ///         expires.  Releases the sequencer's bond.
    ///
    ///         Zeros out the bond before transfer so a subsequent
    ///         `slashSequencerBond` call (if any racing path
    ///         exists) cannot double-spend the bond.
    function finaliseStateRoot(uint64 logIndex) external nonReentrant {
        SubmittedRoot storage r = roots[logIndex];
        if (r.submittedAtBlock == 0) revert PreviousRootMissing();
        if (r.finalised) revert AlreadyFinalised();
        if (r.disputed) revert DisputeInProgress();
        if (block.number <
            r.submittedAtBlock + FAULT_PROOF_DISPUTE_WINDOW)
            revert NotYetFinalisable();

        uint128 amount = r.bond;
        address sequencerAddr = r.sequencer;

        // Effects first (CEI).
        r.finalised = true;
        r.bond = 0;
        if (outstandingRootsCount[sequencerAddr] > 0) {
            outstandingRootsCount[sequencerAddr]--;
        }

        // Release the bond.  Skipping the call when amount is
        // zero (already-slashed roots have a zero bond) avoids
        // the no-op call.
        if (amount > 0) {
            (bool ok, ) = payable(sequencerAddr).call{value: amount}("");
            require(ok, "BondReleaseFailed");
        }

        emit StateRootFinalised(logIndex, sequencerAddr);
    }

    /* ---------------------------------------------------------- */
    /* External: markDisputed (called by faultProofGame)          */
    /* ---------------------------------------------------------- */

    /// @notice Mark a state root as under active dispute.  Called
    ///         by `KnomosisFaultProofGame.initiateChallenge` at
    ///         dispute-game creation.  Once marked, the root
    ///         cannot be finalised until the dispute resolves.
    ///
    ///         Without this gate, the sequencer's bond could be
    ///         released via `finaliseStateRoot` after the dispute
    ///         window expires even while a challenge game is
    ///         still in progress — a critical bond-locking bug
    ///         that this function fixes.
    function markDisputed(uint64 logIndex) external nonReentrant {
        if (msg.sender != faultProofGame) revert NotFaultProofGame();

        SubmittedRoot storage r = roots[logIndex];
        if (r.submittedAtBlock == 0) revert RootMissing();
        if (r.finalised) revert AlreadyFinalised();
        if (r.disputed) revert AlreadyDisputed();

        r.disputed = true;
        emit StateRootDisputed(logIndex, r.sequencer);
    }

    /* ---------------------------------------------------------- */
    /* External: clearDisputed (called by faultProofGame)         */
    /* ---------------------------------------------------------- */

    /// @notice Clear the `disputed` flag for a state root.  Called
    ///         by the fault-proof game when a game settles in the
    ///         sequencer's favour (no challenger-wins outcome),
    ///         so the root can subsequently be finalised normally
    ///         and the sequencer's bond released.
    ///
    ///         Without this, a sequencer who wins a dispute would
    ///         have their bond locked forever (the disputed flag
    ///         stays true, blocking `finaliseStateRoot`).
    function clearDisputed(uint64 logIndex) external nonReentrant {
        if (msg.sender != faultProofGame) revert NotFaultProofGame();

        SubmittedRoot storage r = roots[logIndex];
        if (r.submittedAtBlock == 0) revert RootMissing();
        r.disputed = false;
        // No event for the cleared case — it's the normal path
        // after a sequencer-wins dispute; finalisation emits its
        // own event.
    }

    /* ---------------------------------------------------------- */
    /* External: slashSequencerBond (called by faultProofGame)    */
    /* ---------------------------------------------------------- */

    /// @notice Slash the sequencer's bond on a successful
    ///         challenge.  Called by the fault-proof game contract
    ///         when a game settles `ChallengerWon` /
    ///         `TimedOutSequencer`.  The bond is forwarded to the
    ///         `recipient` address (typically the game contract,
    ///         which then redistributes to challenger + treasury
    ///         via its `_settle` flow).
    ///
    ///         CEI ordering: state mutation first, then external
    ///         call.  Idempotent: a second call on the same
    ///         logIndex reverts with `AlreadySlashed`.
    function slashSequencerBond(uint64 logIndex, address recipient)
        external nonReentrant
    {
        if (msg.sender != faultProofGame) revert NotFaultProofGame();
        if (recipient == address(0)) revert NotSequencer();

        SubmittedRoot storage r = roots[logIndex];
        if (r.submittedAtBlock == 0) revert RootMissing();
        // Defence-in-depth: a finalised root has already released
        // its bond to the sequencer.  Slashing afterwards would
        // double-spend (the contract no longer holds the ETH).
        if (r.finalised) revert AlreadyFinalised();
        if (r.bond == 0) revert BondAlreadyZero();

        uint128 amount = r.bond;
        address sequencerAddr = r.sequencer;

        // Effects first.
        r.bond = 0;
        if (outstandingRootsCount[sequencerAddr] > 0) {
            outstandingRootsCount[sequencerAddr]--;
        }

        // Interaction: forward the slashed bond.
        (bool ok, ) = payable(recipient).call{value: amount}("");
        if (!ok) revert SlashTransferFailed();

        emit SequencerBondSlashed(logIndex, sequencerAddr, recipient, amount);
    }

    /* ---------------------------------------------------------- */
    /* External: revertToPriorRoot (called by faultProofGame)     */
    /* ---------------------------------------------------------- */

    /// @notice Revert the state-root range from `fromIdx` onwards.
    ///         Only callable by the fault-proof game contract.
    ///
    ///         "Onwards" is the point: a root proven invalid at
    ///         `fromIdx` invalidates every root that descends from it,
    ///         because each root's `prevLogEntryHash` chains to its
    ///         predecessor's `expectedNextHash`.  The ceiling is
    ///         therefore `latestSubmittedLogIndex`, not `fromIdx` —
    ///         raising the ceiling only to `fromIdx` marked the single
    ///         disputed index and left its descendants finalisable.
    ///
    ///         A later submission above the ceiling is NOT retroactively
    ///         reverted: it chains onto a reverted predecessor and so
    ///         fails the hash-chain check in `submitStateRoot` unless
    ///         the sequencer re-submits the corrected range, which is
    ///         the intended recovery path.
    function revertStateRootsFrom(uint64 fromIdx) external nonReentrant {
        if (msg.sender != faultProofGame) revert NotFaultProofGame();

        // Update the floor (no-op if a lower floor is already in
        // place).  The `NO_REVERTED_FLOOR` sentinel makes `fromIdx = 0`
        // an ordinary case rather than an unrepresentable one.
        if (fromIdx < lowestRevertedLogIndex) {
            lowestRevertedLogIndex = fromIdx;
        }
        // Raise the ceiling to cover every root that descends from
        // `fromIdx`, i.e. everything submitted so far.
        uint64 ceiling = latestSubmittedLogIndex;
        if (ceiling < fromIdx) {
            // Reverting an index at or above anything yet submitted:
            // the range is the single index, which is all there is.
            ceiling = fromIdx;
        }
        if (ceiling > highestRevertedLogIndex) {
            highestRevertedLogIndex = ceiling;
        }

        emit StateRootRangeReverted(lowestRevertedLogIndex,
                                    highestRevertedLogIndex);
    }

    /* ---------------------------------------------------------- */
    /* View: isStateRootReverted                                  */
    /* ---------------------------------------------------------- */

    /// @notice Returns `true` iff the state root at `logIndex`
    ///         is in the reverted range.
    function isStateRootReverted(uint64 logIndex)
        external
        view
        returns (bool)
    {
        // No `> 0` guard: the floor's sentinel is `NO_REVERTED_FLOOR`,
        // which is above every reachable index, so an unset floor makes
        // the first comparison false on its own — and a floor of 0 (the
        // genesis root reverted) is now a representable state rather
        // than one the guard silently erased.
        return logIndex >= lowestRevertedLogIndex &&
               logIndex <= highestRevertedLogIndex;
    }

    /* ---------------------------------------------------------- */
    /* View: assertConsistent (Workstream-E discipline)           */
    /* ---------------------------------------------------------- */

    /// @notice Cross-cutting structural-invariant check.  Used by
    ///         deployment scripts at deploy-time.  Reverts if any
    ///         construction-time invariant is violated.
    function assertConsistent() external view {
        require(sequencer != address(0), "ZeroSequencer");
        require(faultProofGame != address(0), "ZeroFaultProofGame");
        require(STATE_ROOT_SUBMISSION_BOND > 0, "ZeroBond");
        require(FAULT_PROOF_DISPUTE_WINDOW > 0, "ZeroWindow");
    }
}

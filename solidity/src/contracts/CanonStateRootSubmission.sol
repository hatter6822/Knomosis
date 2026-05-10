// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Canon  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
//  This program comes with ABSOLUTELY NO WARRANTY.
//  This is free software, and you are welcome to redistribute it
//  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
pragma solidity 0.8.20;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title CanonStateRootSubmission
/// @notice Sequencer state-root submission registry for the
///         Workstream-H fault-proof game (per WUs H.7.1 – H.7.4).
///
/// Each submission posts `STATE_ROOT_SUBMISSION_BOND` ETH and
/// starts the `FAULT_PROOF_DISPUTE_WINDOW` countdown.  Roots are
/// finalised after the window expires with no successful challenge.
///
/// Following Workstream-E §20 immutability discipline: no admin
/// roles, no upgrade proxies, no `pause()` functions.  Recovery
/// from bugs is via `CanonFaultProofMigration`.
///
/// **Hash-chain integrity** (WU H.7.4): each submission's
/// `prevLogEntryHash` must match the previous submission's
/// `expectedNextHash`, preventing out-of-order or skipped indices.
///
/// **Anti-DoS** (WU H.7.3): immutable rate-limit constants
/// (submission interval, outstanding cap) set at construction.
contract CanonStateRootSubmission is ReentrancyGuard {
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

    /// @notice Range of revoked log indices (audit-2 floor +
    ///         ceiling).  `floor` is `lowestRevertedLogIndex`;
    ///         `ceiling` is `highestRevertedLogIndex`.  A root at
    ///         `idx ∈ [floor, ceiling]` is considered reverted.
    uint64 public lowestRevertedLogIndex;
    uint64 public highestRevertedLogIndex;

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

    /* ---------------------------------------------------------- */
    /* Errors                                                     */
    /* ---------------------------------------------------------- */

    error NotSequencer();
    error SubmissionTooFrequent();
    error TooManyOutstandingRoots();
    error AlreadyClaimed();
    error InvalidBond();
    error HashChainBroken();
    error PreviousRootMissing();
    error NotYetFinalisable();
    error AlreadyFinalised();
    error DisputeInProgress();
    error ZeroAddress();
    error WindowTooShort();

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
        if (_disputeWindow < _withdrawalFinalisationWindow)
            revert WindowTooShort();

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

        emit StateRootSubmitted(logIndex, stateCommit, msg.sender);
    }

    /* ---------------------------------------------------------- */
    /* External: finaliseStateRoot (WU H.7.2)                     */
    /* ---------------------------------------------------------- */

    /// @notice Finalise a state root after the dispute window
    ///         expires.  Releases the sequencer's bond.
    function finaliseStateRoot(uint64 logIndex) external nonReentrant {
        SubmittedRoot storage r = roots[logIndex];
        if (r.submittedAtBlock == 0) revert PreviousRootMissing();
        if (r.finalised) revert AlreadyFinalised();
        if (r.disputed) revert DisputeInProgress();
        if (block.number <
            r.submittedAtBlock + FAULT_PROOF_DISPUTE_WINDOW)
            revert NotYetFinalisable();

        r.finalised = true;
        outstandingRootsCount[r.sequencer]--;

        // Release the bond.
        (bool ok, ) = payable(r.sequencer).call{value: r.bond}("");
        require(ok, "BondReleaseFailed");

        emit StateRootFinalised(logIndex, r.sequencer);
    }

    /* ---------------------------------------------------------- */
    /* External: revertToPriorRoot (called by faultProofGame)     */
    /* ---------------------------------------------------------- */

    /// @notice Revert the state-root range from `fromIdx`
    ///         onwards.  Only callable by the fault-proof game
    ///         contract.
    function revertStateRootsFrom(uint64 fromIdx) external nonReentrant {
        if (msg.sender != faultProofGame) revert NotSequencer();

        // Update the floor (no-op if a lower floor is already in
        // place).
        if (lowestRevertedLogIndex == 0 || fromIdx < lowestRevertedLogIndex) {
            lowestRevertedLogIndex = fromIdx;
        }
        // Update the ceiling.
        if (fromIdx > highestRevertedLogIndex) {
            highestRevertedLogIndex = fromIdx;
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
        return logIndex >= lowestRevertedLogIndex &&
               logIndex <= highestRevertedLogIndex &&
               lowestRevertedLogIndex > 0;
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

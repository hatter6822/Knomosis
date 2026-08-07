// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
//  This program comes with ABSOLUTELY NO WARRANTY.
//  This is free software, and you are welcome to redistribute it
//  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
pragma solidity 0.8.36;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {ActionsRoot} from "../lib/ActionsRoot.sol";
import {LogChain} from "../lib/LogChain.sol";

/// @title KnomosisStateRootSubmission
/// @notice Sequencer BATCH submission registry for the Workstream-H
///         fault-proof game (WUs H.7.1 – H.7.4, re-cut by Workstream
///         SB to batched submission).
///
/// **One record per batch, not per action.**  A record keyed by
/// `endIndex` covers L2 log entries `[prevEndIndex, endIndex)` (the
/// entry-count convention: the state commit is the root after
/// `endIndex` entries).  This is what gives the L2 rollup economics —
/// the per-action L1 cost is this contract's submission cost DIVIDED
/// by the batch size, where the retired per-action registry pinned it
/// at one full submission each.
///
/// Each submission posts `STATE_ROOT_SUBMISSION_BOND` ETH and starts
/// the `FAULT_PROOF_DISPUTE_WINDOW` countdown.  Records are finalised
/// after the window expires with no successful challenge.
///
/// Following Workstream-E §20 immutability discipline: no admin
/// roles, no upgrade proxies, no `pause()` functions.  Recovery
/// from bugs is via `KnomosisFaultProofMigration`.
///
/// **Hash-chain integrity** (WU H.7.4 as amended by SB ruling R5/R8):
/// the chain is STRUCTURAL — each record's `prevLogEntryHash` is READ
/// from its parent's stored `expectedNextHash`, never accepted from
/// calldata, and the parent is always the canonical tip, so the chain
/// is linear by construction and the old `PreviousRootMissing` /
/// `HashChainBroken` refusals are unreachable rather than checked.
/// Each link folds the batch's `actionsRoot` — the SMT root over the
/// batch's per-action signature-bound commitments — in the chain
/// word the retired registry spent on ONE action's commitment, which
/// is what lets `KnomosisFaultProofGame.terminateOnSingleStep`
/// authenticate the disputed action by INCLUSION PROOF.
///
/// **Revert recovery** (SB ruling R1, fixing a pre-existing defect):
/// the retired registry's reverted range was a dead end — reverted
/// indices could never be resubmitted, and the chain extended
/// straight through reverted entries.  Here `revertStateRootsFrom`
/// stamps `lastRevertAtBlock` and lowers `canonicalTip` to the
/// disputed record's OWN `prevEndIndex` (monotone-down), so the
/// sequencer re-extends from the last good record; a record is
/// reverted iff its key is in range AND it was submitted at or
/// before the last revert, so the recovery resubmissions are not
/// misread as reverted.
///
/// **Anti-DoS** (WU H.7.3): immutable rate-limit constants
/// (submission interval, outstanding cap, and the SB ruling R10
/// per-batch size cap) set at construction.
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

    /// @notice Address authorised to halt and resume state-root
    ///         submission (`haltSubmissions` / `resumeSubmissions`).
    ///         Set in the constructor; immutable.
    ///
    /// @dev    Modelled on `KnomosisBridge.boldCircuitBreaker`, and
    ///         deliberately as narrow: this role can ONLY pause and
    ///         unpause `submitStateRoot`.  It cannot move funds, slash
    ///         a bond, revert or finalise a root, alter any immutable,
    ///         or touch the fault-proof game.
    ///
    ///         Required non-zero, and required DISTINCT from
    ///         `sequencer`.  The distinctness is the load-bearing
    ///         part: a halt is most often reached for the sequencer's
    ///         benefit or on suspicion of it, so a sequencer able to
    ///         clear its own halt would make the breaker decorative.
    address public immutable submissionBreaker;

    /// @notice When true, `submitStateRoot` is refused.
    ///
    /// @dev    Set and cleared ONLY by `submissionBreaker`.  There is
    ///         deliberately no automatic trip.
    ///
    ///         An earlier arrangement latched this inside
    ///         `revertStateRootsFrom`, on the reasoning that a
    ///         challenger win is the strongest evidence a sequencer is
    ///         faulty.  The reasoning was right and the mechanism was
    ///         wrong, because it collided with the thing that has to
    ///         happen next: the SB ruling-R1 recovery path IS the
    ///         sequencer resubmitting the corrected batch after
    ///         exactly that revert.  Latching on the revert therefore
    ///         did not gate a suspicious submission — it gated the
    ///         REPAIR, turning every challenger win into a manual
    ///         intervention and leaving the chain stalled whenever the
    ///         breaker key was not immediately to hand.  Automatic
    ///         halting and automatic recovery cannot both be had here;
    ///         recovery wins, and the breaker stays a deliberate act.
    ///
    ///         Scoped to new submissions only.  Finalisation,
    ///         slashing, reversion and bond reclamation stay open
    ///         while halted, so a halt freezes the frontier without
    ///         stranding the settlement of what came before it.
    bool public submissionsHalted;
    /// @notice The deployment ID for cross-deployment-replay
    ///         protection.
    bytes32 public immutable deploymentId;

    /// @notice The maximum batch size (`endIndex − prevEndIndex`)
    ///         one submission may cover.  Operational sanity only
    ///         (SB ruling R10): the game bisects any range, so
    ///         correctness does not depend on the cap — it bounds
    ///         how much work one dispute window can put at stake.
    uint64 public immutable MAX_ACTIONS_PER_BATCH;

    /* ---------------------------------------------------------- */
    /* Storage                                                    */
    /* ---------------------------------------------------------- */

    /// @notice Submitted batch record, keyed by its `endIndex`.
    ///
    /// @dev    The two batching fields are APPENDED (SB risk-register
    ///         item 1): every pre-existing positional destructuring of
    ///         `roots(...)` — the game holds three — keeps its slots,
    ///         and the cross-decode test pins the layout.
    struct SubmittedRoot {
        address sequencer;
        bytes32 stateCommit;
        bytes32 prevLogEntryHash;
        bytes32 expectedNextHash;
        uint128 bond;
        uint64  submittedAtBlock;
        bool    finalised;
        bool    disputed;
        /// @notice The parent record's key: this batch covers log
        ///         entries `[prevEndIndex, endIndex)`.
        uint64  prevEndIndex;
        /// @notice The batch's actions root — the SMT root over its
        ///         per-action signature-bound leaf commitments
        ///         (`ActionsRoot`), folded into the chain link.
        bytes32 actionsRoot;
    }

    /// @notice Per-batch submission record, keyed by `endIndex`.
    mapping(uint64 => SubmittedRoot) public roots;

    /// @notice The canonical chain's tip: the `endIndex` of the last
    ///         record on the canonical (non-reverted) chain.  Every
    ///         submission must extend it, which is what makes the
    ///         chain linear; `revertStateRootsFrom` lowers it
    ///         (monotone-down within one call) to the disputed
    ///         record's `prevEndIndex` so recovery re-extends from
    ///         the last good record.
    uint64 public canonicalTip;

    /// @notice The L1 block of the most recent revert.  A record is
    ///         reverted only if it was submitted AT OR BEFORE this
    ///         block (SB ruling R1), so post-revert resubmissions in
    ///         the reverted index range are not misread as reverted.
    uint64 public lastRevertAtBlock;

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

    /// @notice Highest `endIndex` ever passed to `submitStateRoot`.
    ///         Submission itself is monotone (every batch extends the
    ///         canonical tip), but the tip DROPS on a revert while
    ///         reverted records keep their keys — so this survives as
    ///         the ceiling `revertStateRootsFrom` reverts up to.
    uint64 public latestSubmittedLogIndex;

    /* ---------------------------------------------------------- */
    /* Events                                                     */
    /* ---------------------------------------------------------- */

    /// @notice One batch submitted.  The two batch fields are
    ///         appended after the retired event's data layout (SB
    ///         ruling R9): the observer reads a batch's bounds and
    ///         actions root from this event alone.
    event StateRootSubmitted(
        uint64  indexed logIndex,
        bytes32 stateCommit,
        address indexed sequencer,
        uint64  prevEndIndex,
        bytes32 actionsRoot
    );

    /// @notice Emitted when state-root submission is halted.
    /// @param  by  the `submissionBreaker` — the only caller that can.
    event SubmissionsHalted(address indexed by);

    /// @notice Emitted when state-root submission is resumed.
    /// @param  by  the `submissionBreaker` — the only caller that can.
    event SubmissionsResumed(address indexed by);

    /// @notice A reverted, undisputed record's bond returned to its
    ///         sequencer (SB ruling R4).  Without this path a
    ///         reverted DESCENDANT record — one nobody disputed,
    ///         invalidated only because its ancestor lost a game —
    ///         would strand its bond forever.
    event StateRootBondReclaimed(
        uint64  indexed logIndex,
        address indexed sequencer,
        uint128 amount
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
    error RootMissing();
    error AlreadyDisputed();
    error AlreadySlashed();
    error BondAlreadyZero();
    error SlashTransferFailed();
    error NotYetFinalisable();
    error AlreadyFinalised();
    error DisputeInProgress();
    error ZeroAddress();
    error WindowTooShort();
    /// @notice The batch does not extend the canonical tip
    ///         (`prevEndIndex != canonicalTip`).  The structural
    ///         chain admits exactly one child per tip, which is what
    ///         replaced the retired caller-supplied-hash checks
    ///         (`PreviousRootMissing` / `HashChainBroken`) — under a
    ///         tip-anchored parent those conditions are unreachable.
    error NotCanonicalTip();
    /// @notice `endIndex <= prevEndIndex`: a batch must cover at
    ///         least one entry.
    error EmptyBatch();
    /// @notice The batch covers more entries than
    ///         `MAX_ACTIONS_PER_BATCH` (SB ruling R10).
    error BatchTooLarge();
    /// @notice Overwriting a reverted record whose bond is still
    ///         outstanding (SB ruling R3): reclaim (or slash) must
    ///         empty the old record's bond first, so no ETH is ever
    ///         orphaned by an overwrite.
    error BondNotReclaimed();
    /// @notice The record is in the reverted range: it cannot be
    ///         finalised, disputed, or used as a game anchor.
    error RootReverted();
    /// @notice The genesis anchor's state commit is zero — an
    ///         all-zero genesis commit is no commitment at all, and
    ///         every deployment has a real genesis state to anchor.
    error ZeroGenesisCommit();
    /// @notice Constructor guard: the `sequencer` (posts roots) and the
    ///         `faultProofGame` (privileged `markDisputed` caller) must be
    ///         distinct principals; collapsing them would let one address
    ///         both submit and adjudicate its own roots.
    error SequencerIsFaultProofGame();

    /// @notice The constructor was handed a `submissionBreaker` equal
    ///         to the `sequencer`.  Refused: the breaker latches on a
    ///         proven-faulty sequencer, so that sequencer must not be
    ///         able to clear its own halt.
    error BreakerIsSequencer();

    /// @notice `submitStateRoot` was called while submissions are
    ///         halted.  Clearable only by `submissionBreaker` via
    ///         `resumeSubmissions`.
    error SubmissionsAreHalted();

    /// @notice A halt/resume call came from an address other than
    ///         `submissionBreaker`.
    error NotSubmissionBreaker();

    /// @notice `resumeSubmissions` was called while not halted, or
    ///         `haltSubmissions` while already halted.  Refused rather
    ///         than treated as a no-op so an operator cannot believe a
    ///         halt took effect when it was already in place (or was
    ///         cleared when it was never set).
    error HaltStateUnchanged();

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
        uint64  _withdrawalFinalisationWindow,
        bytes32 _genesisStateCommit,
        uint64  _maxActionsPerBatch,
        address _submissionBreaker
    ) {
        if (_sequencer == address(0)) revert ZeroAddress();
        if (_faultProofGame == address(0)) revert ZeroAddress();
        if (_submissionBreaker == address(0)) revert ZeroAddress();
        // The breaker latches exactly when a challenger proves the
        // sequencer wrong, so a sequencer able to clear its own halt
        // would make it decorative.
        if (_submissionBreaker == _sequencer) revert BreakerIsSequencer();
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
        // The genesis anchor commits to a real state, and a batch
        // must be able to hold at least one entry.
        if (_genesisStateCommit == bytes32(0)) revert ZeroGenesisCommit();
        if (_maxActionsPerBatch == 0) revert BatchTooLarge();

        STATE_ROOT_SUBMISSION_BOND = _bond;
        FAULT_PROOF_DISPUTE_WINDOW = _disputeWindow;
        MIN_SUBMISSION_INTERVAL_BLOCKS = _minSubmissionInterval;
        MAX_OUTSTANDING_ROOTS_PER_SEQUENCER = _maxOutstandingRoots;
        sequencer = _sequencer;
        faultProofGame = _faultProofGame;
        submissionBreaker = _submissionBreaker;
        deploymentId = _deploymentId;
        MAX_ACTIONS_PER_BATCH = _maxActionsPerBatch;

        // The genesis anchor (SB ruling R5): record 0 is written by
        // the CONSTRUCTOR — already finalised, carrying no bond, its
        // chain value the genesis seed (`nextEntryHash(0, gsc, 0)` —
        // the ordinary chain step at the all-zero predecessor and the
        // empty actions root; mirrored by Lean `genesisChainSeed` and
        // pinned by the `batch_chain.json` corpus).  Every first
        // submission extends it structurally, so no submission ever
        // lacks a parent.  `sequencer` stays zero — nobody submitted
        // the genesis record and nothing may pay out on it (it is
        // born finalised, so finalise / slash / dispute all refuse).
        roots[0] = SubmittedRoot({
            sequencer:        address(0),
            stateCommit:      _genesisStateCommit,
            prevLogEntryHash: bytes32(0),
            expectedNextHash: ActionsRoot.genesisChainSeed(_genesisStateCommit),
            bond:             0,
            submittedAtBlock: uint64(block.number),
            finalised:        true,
            disputed:         false,
            prevEndIndex:     0,
            actionsRoot:      bytes32(0)
        });
        // `canonicalTip` starts at 0 — the genesis record's key.
    }

    /* ---------------------------------------------------------- */
    /* External: submitStateRoot (WU H.7.1 + H.7.4, batched)      */
    /* ---------------------------------------------------------- */

    /// @notice Submit one BATCH: the state root after `endIndex` L2
    ///         log entries, covering entries `[prevEndIndex,
    ///         endIndex)`.  Only the registered sequencer can call.
    ///
    ///         The chain link is structural: `prevLogEntryHash` is
    ///         read from the canonical tip's stored
    ///         `expectedNextHash`, so a submission cannot chain onto
    ///         anything but the tip, and the tip is never a reverted
    ///         record (`revertStateRootsFrom` lowers it to the last
    ///         good parent).  Overwriting is allowed at exactly one
    ///         kind of key: a REVERTED record whose bond has been
    ///         emptied (SB ruling R3) — that is the recovery path the
    ///         retired registry lacked.
    ///
    /// @param endIndex     the batch's end: the L2 entry count this
    ///                     root publishes (state after `endIndex`
    ///                     entries).
    /// @param prevEndIndex the parent record's key; must equal
    ///                     `canonicalTip`.
    /// @param stateCommit  the state root after `endIndex` entries.
    /// @param actionsRoot  the batch's actions root
    ///                     (`ActionsRoot.actionsRoot` over entries
    ///                     `[prevEndIndex, endIndex)`) — the word the
    ///                     fault-proof game authenticates the disputed
    ///                     action against by inclusion proof.
    function submitStateRoot(
        uint64  endIndex,
        uint64  prevEndIndex,
        bytes32 stateCommit,
        bytes32 actionsRoot
    ) external payable nonReentrant {
        // The breaker.  Checked FIRST, before any bond accounting or
        // cadence arithmetic, so a halted registry refuses on the
        // halt rather than on whichever incidental guard happens to
        // trip next -- an operator reading the revert should learn
        // that submissions are stopped, not that the interval was
        // short.
        if (submissionsHalted) revert SubmissionsAreHalted();
        if (msg.sender != sequencer) revert NotSequencer();
        if (msg.value != STATE_ROOT_SUBMISSION_BOND) revert InvalidBond();
        if (endIndex <= prevEndIndex) revert EmptyBatch();
        if (endIndex - prevEndIndex > MAX_ACTIONS_PER_BATCH)
            revert BatchTooLarge();
        if (prevEndIndex != canonicalTip) revert NotCanonicalTip();

        // Occupied-key rule: a live record is never overwritten; a
        // reverted one is, once its bond is out (reclaimed to the
        // sequencer or slashed by the game) so no ETH is orphaned.
        // The live arm is defence-in-depth: a live record's key is
        // always at or below `canonicalTip` (the live prefix ends at
        // the tip), while this submission's key already passed
        // `endIndex > prevEndIndex == canonicalTip` — so an occupied
        // live key cannot be reached unless the tip invariant itself
        // is broken.
        SubmittedRoot storage existing = roots[endIndex];
        if (existing.submittedAtBlock != 0) {
            if (!_isRecordReverted(endIndex)) revert AlreadyClaimed();
            if (existing.bond != 0) revert BondNotReclaimed();
        }

        // Rate limit (WU H.7.3).
        if (block.number <
            lastSubmissionBlock[msg.sender] + MIN_SUBMISSION_INTERVAL_BLOCKS)
            revert SubmissionTooFrequent();
        if (outstandingRootsCount[msg.sender] >=
            MAX_OUTSTANDING_ROOTS_PER_SEQUENCER)
            revert TooManyOutstandingRoots();

        // The structural chain link (SB ruling R5): the parent is the
        // canonical tip, whose record always exists (the constructor
        // wrote the genesis anchor at key 0), so the retired
        // existence/equality refusals have nothing to check.
        bytes32 prevLogEntryHash = roots[prevEndIndex].expectedNextHash;
        bytes32 expectedNextHash =
            LogChain.nextEntryHash(prevLogEntryHash, stateCommit, actionsRoot);

        roots[endIndex] = SubmittedRoot({
            sequencer:        msg.sender,
            stateCommit:      stateCommit,
            prevLogEntryHash: prevLogEntryHash,
            expectedNextHash: expectedNextHash,
            bond:             uint128(msg.value),
            submittedAtBlock: uint64(block.number),
            finalised:        false,
            disputed:         false,
            prevEndIndex:     prevEndIndex,
            actionsRoot:      actionsRoot
        });

        lastSubmissionBlock[msg.sender] = uint64(block.number);
        outstandingRootsCount[msg.sender]++;
        canonicalTip = endIndex;
        if (endIndex > latestSubmittedLogIndex) {
            latestSubmittedLogIndex = endIndex;
        }

        emit StateRootSubmitted(
            endIndex, stateCommit, msg.sender, prevEndIndex, actionsRoot);
    }

    /* ---------------------------------------------------------- */
    /* External: finaliseStateRoot (WU H.7.2)                     */
    /* ---------------------------------------------------------- */

    /// @notice Finalise a batch record after the dispute window
    ///         expires.  Releases the sequencer's bond.
    ///
    ///         Zeros out the bond before transfer so a subsequent
    ///         `slashSequencerBond` call (if any racing path
    ///         exists) cannot double-spend the bond.
    ///
    ///         A REVERTED record is refused: the retired registry
    ///         let a reverted root's untouched descendants finalise
    ///         (one of the two pre-existing defects this workstream
    ///         closes); their bonds now exit via
    ///         `reclaimRevertedBond` instead.
    function finaliseStateRoot(uint64 logIndex) external nonReentrant {
        SubmittedRoot storage r = roots[logIndex];
        if (r.submittedAtBlock == 0) revert RootMissing();
        if (_isRecordReverted(logIndex)) revert RootReverted();
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
        // Defence-in-depth behind the game's own R2 refusal: a
        // reverted record is already judged, and a game on it could
        // only re-litigate a range the chain no longer stands on.
        if (_isRecordReverted(logIndex)) revert RootReverted();
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
    /* External: the submission breaker                           */
    /* ---------------------------------------------------------- */

    /// @notice Halt state-root submission.  Only `submissionBreaker`.
    ///
    /// @dev    The manual arm of the breaker, for the emergencies a
    ///         fault proof does not cover — a sequencer key suspected
    ///         compromised, an upstream dependency found unsound, a
    ///         planned migration.  There is no automatic arm: see
    ///         `submissionsHalted` for why a revert deliberately does
    ///         NOT latch this.
    function haltSubmissions() external {
        if (msg.sender != submissionBreaker) revert NotSubmissionBreaker();
        if (submissionsHalted) revert HaltStateUnchanged();
        submissionsHalted = true;
        emit SubmissionsHalted(msg.sender);
    }

    /// @notice Resume state-root submission.  Only `submissionBreaker`.
    ///
    /// @dev    Nothing about resuming un-reverts a root — the
    ///         reverted range and its floor/ceiling are untouched, so
    ///         the sequencer still re-extends from `canonicalTip`.
    function resumeSubmissions() external {
        if (msg.sender != submissionBreaker) revert NotSubmissionBreaker();
        if (!submissionsHalted) revert HaltStateUnchanged();
        submissionsHalted = false;
        emit SubmissionsResumed(msg.sender);
    }

    /* ---------------------------------------------------------- */
    /* External: revertToPriorRoot (called by faultProofGame)     */
    /* ---------------------------------------------------------- */

    /// @notice Revert the state-root range from `fromIdx` onwards.
    ///         Only callable by the fault-proof game contract.
    ///
    ///         "Onwards" is the point: a record proven invalid at
    ///         `fromIdx` invalidates every record that descends from
    ///         it, because each record's `prevLogEntryHash` chains to
    ///         its parent's `expectedNextHash`.  The ceiling is
    ///         therefore `latestSubmittedLogIndex`, not `fromIdx` —
    ///         raising the ceiling only to `fromIdx` marked the single
    ///         disputed index and left its descendants finalisable.
    ///
    ///         **Recovery** (SB ruling R1): stamp `lastRevertAtBlock`
    ///         and lower `canonicalTip` to the disputed record's own
    ///         `prevEndIndex` — the last good parent — so the
    ///         sequencer re-extends the chain from there.  The stamp
    ///         is what keeps the recovery honest: a record is
    ///         reverted only if submitted at or before it, so the
    ///         corrected resubmissions inside the old range read as
    ///         canonical, where the retired registry read them as
    ///         reverted forever (its recovery path was a dead end).
    function revertStateRootsFrom(uint64 fromIdx) external nonReentrant {
        if (msg.sender != faultProofGame) revert NotFaultProofGame();

        // Update the floor (no-op if a lower floor is already in
        // place).  The `NO_REVERTED_FLOOR` sentinel makes `fromIdx = 0`
        // an ordinary case rather than an unrepresentable one.
        if (fromIdx < lowestRevertedLogIndex) {
            lowestRevertedLogIndex = fromIdx;
        }
        // Raise the ceiling to cover every record that descends from
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

        lastRevertAtBlock = uint64(block.number);
        // Lower the tip to the disputed record's parent — monotone
        // down, so a second revert deeper in the chain (an ancestor
        // of `fromIdx` losing its own game) cannot RAISE the tip back
        // onto a reverted suffix.
        uint64 recoveredTip = roots[fromIdx].prevEndIndex;
        if (recoveredTip < canonicalTip) {
            canonicalTip = recoveredTip;
        }

        emit StateRootRangeReverted(lowestRevertedLogIndex,
                                    highestRevertedLogIndex);
    }

    /* ---------------------------------------------------------- */
    /* External: reclaimRevertedBond (SB ruling R4)               */
    /* ---------------------------------------------------------- */

    /// @notice Return a reverted, undisputed, unfinalised record's
    ///         bond to its sequencer.  The record itself stays in
    ///         storage (its key can then be overwritten by a
    ///         corrected resubmission, which requires the bond to be
    ///         out first).
    ///
    ///         Permissionless on purpose: the payout target is fixed
    ///         to the record's own sequencer, so a third-party call
    ///         can only ever RETURN funds, never move them.
    function reclaimRevertedBond(uint64 logIndex) external nonReentrant {
        SubmittedRoot storage r = roots[logIndex];
        if (r.submittedAtBlock == 0) revert RootMissing();
        if (!_isRecordReverted(logIndex)) revert RootMissing();
        if (r.finalised) revert AlreadyFinalised();
        // An active game's record keeps its bond locked: if the game
        // settles challenger-won the bond is slashed, and if
        // sequencer-won the game clears the flag and the reclaim
        // proceeds then.
        if (r.disputed) revert DisputeInProgress();
        if (r.bond == 0) revert BondAlreadyZero();

        uint128 amount = r.bond;
        address sequencerAddr = r.sequencer;

        // Effects first (CEI).
        r.bond = 0;
        if (outstandingRootsCount[sequencerAddr] > 0) {
            outstandingRootsCount[sequencerAddr]--;
        }

        (bool ok, ) = payable(sequencerAddr).call{value: amount}("");
        if (!ok) revert SlashTransferFailed();

        emit StateRootBondReclaimed(logIndex, sequencerAddr, amount);
    }

    /* ---------------------------------------------------------- */
    /* View: isStateRootReverted                                  */
    /* ---------------------------------------------------------- */

    /// @notice Returns `true` iff the record at `logIndex` is
    ///         reverted: its key is in the reverted range AND it was
    ///         submitted at or before the most recent revert (SB
    ///         ruling R1).  A corrected resubmission at a key inside
    ///         the old range carries a later submission block, so it
    ///         reads canonical.
    function isStateRootReverted(uint64 logIndex)
        external
        view
        returns (bool)
    {
        return _isRecordReverted(logIndex);
    }

    /// @dev The record-level reverted test.  No `submittedAtBlock !=
    ///      0` guard is needed for the callers that already checked
    ///      existence; for the bare view an absent record inside the
    ///      range reads `0 <= lastRevertAtBlock` = reverted, which is
    ///      the right answer for a key the revert swept before
    ///      anything occupied it.
    function _isRecordReverted(uint64 logIndex)
        internal
        view
        returns (bool)
    {
        // The floor's sentinel is `NO_REVERTED_FLOOR`, above every
        // reachable index, so an unset floor fails the first
        // comparison on its own — and a floor of 0 stays
        // representable.
        return logIndex >= lowestRevertedLogIndex &&
               logIndex <= highestRevertedLogIndex &&
               roots[logIndex].submittedAtBlock <= lastRevertAtBlock;
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
        require(MAX_ACTIONS_PER_BATCH > 0, "ZeroBatchCap");
        // The genesis anchor is in place: born finalised, bondless,
        // and carrying the seed chain value every first submission
        // extends.
        require(roots[0].finalised, "GenesisAnchorMissing");
        require(roots[0].submittedAtBlock != 0, "GenesisAnchorMissing");
        require(
            roots[0].expectedNextHash
                == ActionsRoot.genesisChainSeed(roots[0].stateCommit),
            "GenesisSeedMismatch"
        );
    }
}

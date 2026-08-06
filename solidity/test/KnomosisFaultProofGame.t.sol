// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {KnomosisFaultProofGame} from "src/contracts/KnomosisFaultProofGame.sol";
import {CrossCheckFramework} from "./CrossCheck/Framework.t.sol";
import {KnomosisStepVMRoot} from "src/contracts/KnomosisStepVMRoot.sol";
import {ActionsRoot} from "src/lib/ActionsRoot.sol";
import {CBEEncode} from "src/lib/CBEEncode.sol";
import {LogChain} from "src/lib/LogChain.sol";
import {SmtCellVerifier} from "src/lib/SmtCellVerifier.sol";

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
        // The two batch fields are APPENDED (SB risk-register item 1)
        // so the auto-getter's tuple matches the game's
        // `IStateRootSubmission.roots` 10-slot destructurings.
        uint64  prevEndIndex;
        bytes32 actionsRoot;
    }

    mapping(uint64 => RootRecord) public roots;
    bytes32 public deploymentId;

    /// @notice Record-level reverted flags (SB ruling R1).  The real
    ///         registry derives this from its revert range + stamp;
    ///         the mock lets a test flip it directly to exercise the
    ///         game's R2 refusal.
    mapping(uint64 => bool) public revertedRecords;

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

    function setReverted(uint64 logIndex, bool value) external {
        revertedRecords[logIndex] = value;
    }

    function isStateRootReverted(uint64 logIndex)
        external
        view
        returns (bool)
    {
        return revertedRecords[logIndex];
    }

    /// @notice Seed a batch record, computing its chain value the way
    ///         the real registry does — one `nextEntryHash` fold per
    ///         batch, with the batch's ACTIONS ROOT in the third word
    ///         (SB ruling R8).
    ///
    /// @dev    The load-bearing field is `actionsRoot`: it is what
    ///         `terminateOnSingleStep` authenticates the disputed
    ///         action against, by inclusion proof.  A mock that seeded
    ///         it as a stub zero would make every terminate-path test
    ///         prove the binding cannot be satisfied rather than that
    ///         it works — which is exactly what
    ///         `test_terminate_rejects_an_action_absent_from_the_batch`
    ///         asserts on purpose, using an explicitly zero root.
    function seedRoot(
        uint64 endIndex,
        address sequencer,
        bytes32 stateCommit,
        uint128 bond,
        bytes32 prevLogEntryHash,
        bytes32 actionsRoot,
        uint64 prevEndIndex
    ) external payable {
        roots[endIndex] = RootRecord({
            sequencer: sequencer,
            stateCommit: stateCommit,
            prevLogEntryHash: prevLogEntryHash,
            expectedNextHash: LogChain.nextEntryHash(
                prevLogEntryHash, stateCommit, actionsRoot),
            bond: bond,
            submittedAtBlock: uint64(block.number),
            finalised: false,
            disputed: false,
            prevEndIndex: prevEndIndex,
            actionsRoot: actionsRoot
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
contract KnomosisFaultProofGameTest is CrossCheckFramework {
    KnomosisFaultProofGame private game;
    KnomosisStepVMRoot private stepVM;
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
    ///
    ///         Loaded from the cross-stack corpus rather than invented.
    ///         The terminal step now returns a state ROOT computed by
    ///         folding proven cell writes into `low`, so a FABRICATED
    ///         `low` has no openings that verify against it and the
    ///         honest path would be unreachable — which is the very
    ///         failure this suite's headline test exists to rule out.
    bytes32 private LOW_ROOT;

    /// @dev The corpus probe this suite adjudicates:
    ///      `multiProofGoldens[0]`, a `transfer`.  Its `l2LogIndex` is
    ///      0 while the game passes `g.high.idx` (at least 1, since
    ///      `lowLogIndex < disputedLogIndex`); that is sound for every
    ///      variant except `withdraw`, whose pending-withdrawal record
    ///      is the only thing that reads the index.  `withdraw` is
    ///      adjudicated by `CrossCheck/StepVMRootMulti.t.sol`, which
    ///      drives the step VM directly and uses the probe's own index.
    uint8 private probeKind;
    bytes private probeFields;
    uint64 private probeSigner;
    bytes32 private probePostRoot;
    KnomosisStepVMRoot.OpenedCell[] private probeCells;
    bytes private probeGapMask;
    bytes private probeSiblings;

    /// @dev Load the probe from the MULTIPROOF column.  A real pre-root
    ///      with a real wire is the only way the honest terminal step
    ///      can succeed: the fold checks its aggregate against
    ///      `g.low.commit`, so a fabricated low has no wire that
    ///      reproduces it.
    function _loadProbe() private {
        string memory raw = readFixture("step_vm.json");
        string memory base = ".multiProofGoldens[0]";
        LOW_ROOT = vm.parseJsonBytes32(raw, string.concat(base, ".preStateRootHex"));
        probePostRoot =
            vm.parseJsonBytes32(raw, string.concat(base, ".postStateRootHex"));
        probeKind =
            uint8(vm.parseJsonUint(raw, string.concat(base, ".actionKindByte")));
        probeFields = vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex"));
        probeSigner =
            uint64(vm.parseJsonUint(raw, string.concat(base, ".signerNat")));
        probeGapMask = vm.parseJsonBytes(raw, string.concat(base, ".gapMaskHex"));
        probeSiblings = vm.parseJsonBytes(raw, string.concat(base, ".siblingsHex"));
        uint256 n = vm.parseJsonUint(raw, string.concat(base, ".cellCount"));
        for (uint256 i = 0; i < n; i++) {
            string memory c = string.concat(base, ".cells[", vm.toString(i), "]");
            probeCells.push(KnomosisStepVMRoot.OpenedCell({
                cellKind: uint8(vm.parseJsonUint(raw, string.concat(c, ".cellKind"))),
                keyA: vm.parseJsonUint(raw, string.concat(c, ".keyA")),
                keyB: vm.parseJsonUint(raw, string.concat(c, ".keyB")),
                preValue: vm.parseJsonBytes(raw, string.concat(c, ".preValueHex"))
            }));
        }
    }

    /// @dev The probe's frontier, as a memory array for the call.
    function _cells()
        private
        view
        returns (KnomosisStepVMRoot.OpenedCell[] memory out)
    {
        out = new KnomosisStepVMRoot.OpenedCell[](probeCells.length);
        for (uint256 i = 0; i < out.length; i++) out[i] = probeCells[i];
    }

    /// @dev All but the last byte of `b`.  Used to perturb one field of
    ///      a canonical action-field layout without re-deriving it.
    function _sliceHead(bytes memory b, uint256 n)
        private
        pure
        returns (bytes memory out)
    {
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) out[i] = b[i];
    }

    function setUp() public {
        stepVM = new KnomosisStepVMRoot();
        _loadProbe();
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
        _seedUnboundRoot(0, LOW_ROOT);
        _seedUnboundRoot(10, DISPUTED_ROOT);
        _seedUnboundRoot(11, DISPUTED_ROOT);
        _seedUnboundRoot(12, DISPUTED_ROOT);
        _seedUnboundRoot(64, DISPUTED_ROOT);
        _seedUnboundRoot(65, DISPUTED_ROOT);
        _seedUnboundRoot(66, DISPUTED_ROOT);
        _seedUnboundRoot(67, DISPUTED_ROOT);

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

    /// @notice Seed a batch record with an EMPTY (all-zero) actions
    ///         root — no action opens under it.
    ///
    /// @dev    For indices the test never TERMINATES on — challenge,
    ///         bisection, and timeout paths only read the sequencer,
    ///         the commit, the bond, and `prevEndIndex`.  A terminate
    ///         against one of these reverts `ActionNotInBatch` (every
    ///         inclusion walk lands on a keccak output, never the zero
    ///         word), which is the correct outcome for a batch whose
    ///         actions were never committed, and is asserted directly
    ///         by `test_terminate_rejects_an_action_absent_from_the_batch`.
    ///
    ///         `prevEndIndex` is 0, so every challenge in this suite
    ///         anchors at the genesis record (`lowLogIndex = 0`) per
    ///         SB ruling R2.
    function _seedUnboundRoot(uint64 logIndex, bytes32 commit) internal {
        mockStateRootSubmission.seedRoot(
            logIndex, sequencer, commit, STATE_ROOT_BOND,
            bytes32(0), bytes32(0), 0);
    }

    /// @notice Seed a batch record and bind the action that produced
    ///         it, the way a real `submitStateRoot` would: the actions
    ///         root is the single-leaf SMT holding the action's
    ///         SIGNATURE-BOUND leaf commit at absolute index 0.
    ///
    /// @dev    Index 0 because every batch this suite terminates on
    ///         starts at `prevEndIndex = 0`, and the terminal range is
    ///         always `[0, 1]` — so the disputed step's absolute index
    ///         (`g.low.idx`) is 0.
    function _seedRootForAction(
        uint64 endIndex,
        bytes32 commit,
        uint8 actionKind,
        uint64 signer,
        bytes memory actionFields
    ) internal {
        mockStateRootSubmission.seedRoot(
            endIndex,
            sequencer,
            commit,
            STATE_ROOT_BOND,
            bytes32(0),
            _singleLeafActionsRoot(
                0,
                _actionLeafCommit(actionKind, signer, actionFields, _testSig())),
            0);
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
            LOW_ROOT, // low commit (genesis)
            0                       // low log index
        );
        assertEq(gameId, 1);
        assertEq(game.activeGameForLogIndex(10), gameId);
    }

    function test_initiateChallenge_marks_disputed_root() public {
        vm.prank(challenger);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC1)), LOW_ROOT, 0);
        assertTrue(mockStateRootSubmission.markDisputedCalled());
        assertEq(mockStateRootSubmission.lastMarkedLogIndex(), 10);
    }

    function test_initiateChallenge_rejects_wrong_bond() public {
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.InsufficientBond.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND - 1}(
            10, bytes32(uint256(0xC1)), LOW_ROOT, 0);
    }

    function test_initiateChallenge_rejects_no_dispute() public {
        // challengerCommit == disputed root ⇒ no dispute.
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.MidpointOutOfRange.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, DISPUTED_ROOT, LOW_ROOT, 0);
    }

    function test_initiateChallenge_rejects_duplicate_game() public {
        vm.prank(challenger);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC1)), LOW_ROOT, 0);
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.GameAlreadyExists.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC2)), LOW_ROOT, 0);
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
            10, bytes32(uint256(0xC1)), LOW_ROOT, 0);
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
            LOW_ROOT,
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
    ///         challenge whose batch-start anchor references an
    ///         UNSUBMITTED root must revert — the low endpoint cannot
    ///         be an agreed pre-state if no root was ever submitted
    ///         there.  Under batching the anchor is the disputed
    ///         record's `prevEndIndex`, so the shape is a record whose
    ///         PARENT key holds no record.  The mock can seed one; the
    ///         real registry cannot reach this shape (its structural
    ///         chain only extends the existing canonical tip), so the
    ///         guard is defence-in-depth there.
    function test_initiateChallenge_rejects_unsubmitted_low_root() public {
        // A record at end 300 claiming parent 250 — never seeded
        // (submittedAtBlock == 0).
        mockStateRootSubmission.seedRoot(
            300, sequencer, DISPUTED_ROOT, STATE_ROOT_BOND,
            bytes32(0), bytes32(0), 250);
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.LowRootNotSubmitted.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            300,                    // disputedLogIndex (seeded)
            bytes32(uint256(0xC1)),
            LOW_ROOT,
            250);                   // == prevEndIndex, but NOT seeded
    }

    /// @notice SB ruling R2: the game bisects INSIDE one batch, so the
    ///         low anchor must be the disputed record's own
    ///         `prevEndIndex` — the one index below the dispute whose
    ///         commit is on-chain-agreed.  Any other anchor is refused,
    ///         even one referencing a perfectly good submitted root.
    function test_initiateChallenge_anchors_low_to_the_batch_start() public {
        // A second batch [10, 120) whose parent is the record at 10.
        mockStateRootSubmission.seedRoot(
            120, sequencer, DISPUTED_ROOT, STATE_ROOT_BOND,
            bytes32(0), bytes32(0), 10);

        // Anchoring at 0 — a submitted root, but not THIS batch's
        // start — is refused before the low record is even read.
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.LowNotBatchStart.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            120, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        // Anchoring at the batch start (10) with its committed root
        // opens the game.
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            120, bytes32(uint256(0xC1)), DISPUTED_ROOT, 10);
        assertEq(game.activeGameForLogIndex(120), gameId,
            "the batch-start-anchored challenge must open");
    }

    /// @notice SB ruling R2: a REVERTED disputed record is already
    ///         judged — a game on it would re-litigate a range the
    ///         chain no longer stands on.
    function test_initiateChallenge_rejects_a_reverted_disputed_record()
        public
    {
        mockStateRootSubmission.setReverted(10, true);
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.DisputedRootReverted.selector);
        game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            10, bytes32(uint256(0xC1)), LOW_ROOT, 0);
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
            LOW_ROOT,
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
            LOW_ROOT,
            10);  // lowLogIndex == disputedLogIndex
    }

    /* -------- terminateOnSingleStep (end-to-end adjudication) -------- */

    /// @notice The suite's fixed 65-byte action signature (the
    ///         `r ‖ s ‖ v` wire shape).
    ///
    /// @dev    The leaf HASHES the signature (SB ruling R7); nothing
    ///         verifies it on-chain yet, so any fixed 65-byte value
    ///         works — but it must be the SAME bytes at seed time and
    ///         terminate time, which is exactly the binding
    ///         `test_terminate_rejects_a_substituted_signature`
    ///         exercises.
    function _testSig() internal pure returns (bytes memory sig) {
        sig = new bytes(65);
        for (uint256 i = 0; i < 65; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            sig[i] = bytes1(uint8(i + 1));
        }
    }

    /// @notice The signature-bound leaf commit
    ///         `keccak256(kind ‖ uint64BE signer ‖ fields ‖ sig)` —
    ///         the test's own spelling of
    ///         `ActionsRoot.actionLeafCommit`, which takes calldata
    ///         and cannot be handed memory bytes.
    function _actionLeafCommit(
        uint8 actionKind,
        uint64 signer,
        bytes memory actionFields,
        bytes memory actionSig
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(actionKind, signer, actionFields, actionSig));
    }

    /// @notice The actions root of a SINGLE-entry batch: the cell-SMT
    ///         family tree with exactly one leaf, at
    ///         `actionKey(actionIdx)`.  Every sibling on the path is
    ///         the canonical empty sub-tree, so the matching inclusion
    ///         proof is `_singleEntryProof()`.
    ///
    /// @dev    A deliberate second spelling of the walk
    ///         `ActionsRoot.verifyActionInclusion` performs, so the
    ///         seeded root cross-checks the library rather than being
    ///         produced by it.
    function _singleLeafActionsRoot(uint64 actionIdx, bytes32 leafCommit)
        internal
        pure
        returns (bytes32 root)
    {
        bytes memory keyBytes =
            abi.encodePacked(ActionsRoot.actionKey(actionIdx));
        root = keccak256(bytes.concat(
            CBEEncode.bytesValue(keyBytes),
            CBEEncode.bytesValue(abi.encodePacked(leafCommit))));
        bytes32[256] memory empties =
            SmtCellVerifier.precomputeEmptySubtreeHashes();
        for (uint256 d = 0; d < 256; d++) {
            root = SmtCellVerifier.readKeyBitMSBFirst(keyBytes, d) == 1
                ? keccak256(abi.encodePacked(empties[d], root))
                : keccak256(abi.encodePacked(root, empties[d]));
        }
    }

    /// @notice The inclusion proof of the only entry in a single-leaf
    ///         batch tree: a 32-byte all-zero bitmask and no siblings —
    ///         every level's sibling is the canonical empty sub-tree.
    function _singleEntryProof() internal pure returns (bytes memory) {
        return new bytes(32);
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
        bytes memory actionFields = probeFields;
        uint8 kind = probeKind;
        uint64 stepSigner = probeSigner;

        // The HONEST post-state: the step VM's FOLD from the real,
        // anchored low.  Unlike the bespoke hash the old step VM
        // returned, this is a value in state-root space, so the
        // terminal comparison can succeed at all.
        bytes32 honestPost = stepVM.executeStepToRootMulti(
            LOW_ROOT, kind, actionFields, stepSigner, 1,
            _cells(), probeGapMask, probeSiblings);
        assertEq(honestPost, probePostRoot,
            "the step VM must reach the corpus's post-root");

        // Seed a single-step disputed root at index 1 committing to the
        // honest post-state, sequenced by `sequencer`.
        _seedRootForAction(1, honestPost, kind, stepSigner, actionFields);

        // Challenger disputes with a WRONG commit (!= honestPost) and the
        // correctly-anchored low (LOW_ROOT at index 0).  Range = 1 step.
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            1, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        // At game open turn = Sequencer; the honest sequencer terminates
        // with the real step, naming the batch-bound signed action and
        // its inclusion proof.  executeStep(low) == high ⇒ SequencerWon.
        uint256 seqBalBefore = sequencer.balance;
        vm.prank(sequencer);
        game.terminateOnSingleStep(
            gameId, kind, actionFields, stepSigner,
            _testSig(), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings);

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

    /// @notice **The terminal step adjudicates the action the L2
    ///         published, not one the responding party picks.**
    ///
    ///         Without the batch binding, `terminateOnSingleStep`
    ///         executed whatever `(actionKind, actionFields, signer)`
    ///         it was handed and compared the result to `g.high.commit`.
    ///         Nothing on L1 recorded which action carried the pre-root
    ///         to the disputed root, so a party about to lose could
    ///         search for a DIFFERENT action whose step happens to
    ///         reproduce the disputed root and settle in its favour on
    ///         a step that never ran.
    ///
    ///         Here the sequencer publishes a batch bound to a transfer
    ///         of 5, then tries to terminate naming a transfer of 7.
    ///         The inclusion check rejects it before the step VM runs:
    ///         the substituted action's leaf does not open at the
    ///         disputed step's index under the batch's actions root.
    function test_terminate_rejects_a_substituted_action() public {
        uint8 kind = probeKind;
        uint64 stepSigner = probeSigner;
        bytes memory boundFields = probeFields;
        // The SAME layout with its last field perturbed: a transfer of a
        // different amount is a different step, and the substitution is
        // rejected before the step VM ever runs.
        bytes memory substitutedFields = bytes.concat(
            _sliceHead(boundFields, boundFields.length - 1),
            bytes1(uint8(boundFields[boundFields.length - 1]) ^ 0xFF));

        _seedRootForAction(1, probePostRoot, kind, stepSigner, boundFields);

        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            1, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        vm.prank(sequencer);
        vm.expectRevert(KnomosisFaultProofGame.ActionNotInBatch.selector);
        game.terminateOnSingleStep(
            gameId, kind, substitutedFields, stepSigner,
            _testSig(), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings);

        // ...and the bound action still terminates, so the rejection is
        // the substitution and not the binding refusing everything.
        vm.prank(sequencer);
        game.terminateOnSingleStep(
            gameId, kind, boundFields, stepSigner,
            _testSig(), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings);
        (, , , , , , , , , , ,
         KnomosisFaultProofGame.GameStatus status, , ,) = game.games(gameId);
        assertEq(uint8(status), uint8(KnomosisFaultProofGame.GameStatus.SequencerWon),
            "the BOUND action must still win the game");
    }

    /// @notice The signer is bound too, not just the fields.  A step
    ///         signed by a different actor is a different step, and the
    ///         leaf commit covers all four components.
    function test_terminate_rejects_a_substituted_signer() public {
        bytes memory actionFields = probeFields;
        _seedRootForAction(1, probePostRoot, probeKind, probeSigner, actionFields);

        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            1, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        vm.prank(sequencer);
        vm.expectRevert(KnomosisFaultProofGame.ActionNotInBatch.selector);
        game.terminateOnSingleStep(
            gameId, probeKind, actionFields, probeSigner + 1,
            _testSig(), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings);
    }

    /// @notice The action KIND is bound: naming a different variant
    ///         over the same field bytes is rejected.
    function test_terminate_rejects_a_substituted_action_kind() public {
        bytes memory actionFields = probeFields;
        _seedRootForAction(1, probePostRoot, probeKind, probeSigner, actionFields);

        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            1, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        vm.prank(sequencer);
        vm.expectRevert(KnomosisFaultProofGame.ActionNotInBatch.selector);
        game.terminateOnSingleStep(
            gameId, 1 /* Mint */, actionFields, probeSigner,
            _testSig(), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings);
    }

    /// @notice **The signature is bound in the leaf** (SB ruling R7,
    ///         user decision "bind signature in leaf"): the leaf
    ///         commit is `hash(kind ‖ signer ‖ fields ‖ sig)`, so
    ///         naming the bound action under a DIFFERENT signature is
    ///         refused exactly like a different action.  Nothing
    ///         verifies the signature on-chain yet — binding it now is
    ///         what makes that recorded follow-up a drop-in instead of
    ///         another chain-shape migration.
    function test_terminate_rejects_a_substituted_signature() public {
        bytes memory actionFields = probeFields;
        _seedRootForAction(1, probePostRoot, probeKind, probeSigner, actionFields);

        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            1, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        // The same 65-byte width with one flipped byte: a different
        // signature is a different leaf.
        bytes memory otherSig = _testSig();
        otherSig[0] = otherSig[0] ^ bytes1(uint8(0xFF));
        vm.prank(sequencer);
        vm.expectRevert(KnomosisFaultProofGame.ActionNotInBatch.selector);
        game.terminateOnSingleStep(
            gameId, probeKind, actionFields, probeSigner,
            otherSig, _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings);

        // ...and the BOUND signature still terminates.
        vm.prank(sequencer);
        game.terminateOnSingleStep(
            gameId, probeKind, actionFields, probeSigner,
            _testSig(), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings);
        (, , , , , , , , , , ,
         KnomosisFaultProofGame.GameStatus status, , ,) = game.games(gameId);
        assertEq(uint8(status), uint8(KnomosisFaultProofGame.GameStatus.SequencerWon),
            "the bound signature must still win the game");
    }

    /// @notice A signature of any width but the fixed 65 bytes REVERTS
    ///         with the library's own error before any walk: the fixed
    ///         width is what keeps the leaf pre-image's `fields ‖ sig`
    ///         split injective.
    function test_terminate_rejects_a_malformed_signature_width() public {
        bytes memory actionFields = probeFields;
        _seedRootForAction(1, probePostRoot, probeKind, probeSigner, actionFields);

        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            1, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(
            ActionsRoot.ActionSigWrongLength.selector, uint256(64)));
        game.terminateOnSingleStep(
            gameId, probeKind, actionFields, probeSigner,
            new bytes(64), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings);
    }

    /// @notice A batch published with NO actions committed cannot be
    ///         terminated on at all.  This is the pre-binding world
    ///         made explicit: an all-zero actions root is one under
    ///         which no action opens, and the game refuses to
    ///         adjudicate a step it cannot authenticate rather than
    ///         executing a caller-chosen one.
    function test_terminate_rejects_an_action_absent_from_the_batch() public {
        bytes memory actionFields = probeFields;
        _seedUnboundRoot(1, probePostRoot);

        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            1, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        vm.prank(sequencer);
        vm.expectRevert(KnomosisFaultProofGame.ActionNotInBatch.selector);
        game.terminateOnSingleStep(
            gameId, probeKind, actionFields, probeSigner,
            _testSig(), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings);
    }

    /// @notice Companion to the above: an honest CHALLENGER wins the
    ///         single-step termination when the sequencer's committed
    ///         `high` does NOT match the real step from the anchored
    ///         low (an invalid published root).  It is the sequencer's
    ///         turn, so a mismatch settles `ChallengerWon`.
    function test_terminate_single_step_invalid_root_challenger_wins() public {
        bytes memory actionFields = probeFields;

        // Seed the disputed root with a FABRICATED high (!= the honest
        // step output) — i.e. the sequencer published an invalid root.
        bytes32 fakeHigh = bytes32(uint256(0xF00D));
        _seedRootForAction(1, fakeHigh, probeKind, probeSigner, actionFields);

        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            1, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        uint256 chalBalBefore = challenger.balance;
        // The sequencer, forced to execute the batch-bound step, cannot
        // reproduce the fabricated `high`; on its turn a mismatch is a
        // ChallengerWon.
        vm.prank(sequencer);
        game.terminateOnSingleStep(
            gameId, probeKind, actionFields, probeSigner,
            _testSig(), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings);

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
        uint8 kind = probeKind;
        uint64 stepSigner = probeSigner;
        bytes memory actionFields = probeFields;

        // Only the TERMINAL step is ever executed, so only `commits[0]`
        // and `commits[1]` have to be a real (pre-root, post-root) pair.
        // The later three are the bisection's scaffolding — midpoint
        // claims the challenger disagrees with, on which no step VM
        // runs.  Deriving them keeps this test about the GAME and
        // leaves the step VM's arithmetic to the cross-stack corpus.
        bytes32[5] memory commits;
        commits[0] = LOW_ROOT;
        commits[1] = probePostRoot;
        for (uint8 i = 2; i < 5; i++) {
            commits[i] = keccak256(abi.encodePacked(commits[i - 1], i));
        }

        // The sequencer honestly published each commit at its end
        // index, every record binding the transfer at absolute index 0.
        // Index 4 is the one that matters at terminate time: the game
        // reads the DISPUTED record's actions root (via its immutable
        // `g.disputedLogIndex`), and after two disagreeing bisection
        // rounds the terminal range is [0, 1], so the authenticated
        // step is entry 0 of THAT batch.
        for (uint64 i = 1; i <= 4; i++) {
            _seedRootForAction(i, commits[i], kind, stepSigner, actionFields);
        }

        // Challenger opens a 4-step dispute with a WRONG claim.
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            4, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        // Round 1: midpoint of [0, 4] is 2.  The sequencer submits the
        // honest commits[2]; the challenger DISAGREES, so the range
        // narrows to [0, (2, commits[2])] — `high` is now a midpoint.
        vm.roll(vm.getBlockNumber() + MIN_STEP_INTERVAL + 1);
        vm.prank(sequencer);
        game.submitMidpoint(gameId, commits[2]);
        vm.roll(vm.getBlockNumber() + MIN_STEP_INTERVAL + 1);
        vm.prank(challenger);
        game.respondToMidpoint(gameId, false);

        // Round 2: midpoint of [0, 2] is 1.  Same pattern — the range
        // narrows to the single step [0, (1, commits[1])].
        vm.roll(vm.getBlockNumber() + MIN_STEP_INTERVAL + 1);
        vm.prank(sequencer);
        game.submitMidpoint(gameId, commits[1]);
        vm.roll(vm.getBlockNumber() + MIN_STEP_INTERVAL + 1);
        vm.prank(challenger);
        game.respondToMidpoint(gameId, false);

        // Two full rounds happened: depth == 2 and it is the sequencer's
        // turn on the single-step range.
        (, , , , , , uint64 depth, , , , , , , ,) = game.games(gameId);
        assertEq(depth, 2, "two bisection rounds must be recorded");

        // Terminal step: the fold from commits[0] reaches commits[1],
        // which is `high` ⇒ the responding sequencer wins.  The
        // authenticated action is the one bound in the DISPUTED batch's
        // actions root (read via `g.disputedLogIndex` = 4) at absolute
        // index `g.low.idx` = 0.
        vm.prank(sequencer);
        game.terminateOnSingleStep(
            gameId, kind, actionFields, stepSigner,
            _testSig(), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings);

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
        vm.roll(vm.getBlockNumber() + MIN_STEP_INTERVAL + 1);
        vm.prank(sequencer);
        game.submitMidpoint(firstGameId, bytes32(uint256(0xAD)));
        vm.roll(vm.getBlockNumber() + MIN_STEP_INTERVAL + 1);
        vm.prank(challenger);
        game.respondToMidpoint(firstGameId, false);

        // Settle by timeout (the sequencer's turn after the response;
        // it stalls past the deadline and loses).
        vm.roll(vm.getBlockNumber() + BISECTION_TIMEOUT + 1);
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
            10, bytes32(uint256(0xC1)), LOW_ROOT, 0);
        vm.roll(vm.getBlockNumber() + BISECTION_TIMEOUT + 1);
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
            11, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        uint256 challengerBefore = challenger.balance;
        uint256 treasuryBefore   = treasury.balance;

        vm.roll(vm.getBlockNumber() + BISECTION_TIMEOUT + 1);
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
        vm.roll(vm.getBlockNumber() + BISECTION_TIMEOUT + 1);
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
            12, bytes32(uint256(0xC1)), LOW_ROOT, 0);
        vm.roll(vm.getBlockNumber() + BISECTION_TIMEOUT + 1);
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
            12, bytes32(uint256(0xC1)), LOW_ROOT, 0);
        vm.roll(vm.getBlockNumber() + BISECTION_TIMEOUT + 1);
        vm.prank(challenger);
        game.claimTimeout(gameId);
        // Verify state-root revert range update fired.
        assertTrue(mockStateRootSubmission.revertCalled());
        assertEq(mockStateRootSubmission.lastRevertedFromIdx(), 12);
    }

    function test_claimTimeout_rejects_already_settled_game() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            12, bytes32(uint256(0xC1)), LOW_ROOT, 0);
        vm.roll(vm.getBlockNumber() + BISECTION_TIMEOUT + 1);
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
            64, bytes32(uint256(0xC1)), LOW_ROOT, 0);
        vm.roll(vm.getBlockNumber() + MIN_STEP_INTERVAL + 1);
        vm.prank(sequencer);
        game.submitMidpoint(gameId, bytes32(uint256(0xAD)));
        // No revert — midpoint accepted.
    }

    function test_submitMidpoint_rejects_wrong_caller() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            65, bytes32(uint256(0xC1)), LOW_ROOT, 0);
        vm.roll(vm.getBlockNumber() + MIN_STEP_INTERVAL + 1);
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.NotResponsible.selector);
        game.submitMidpoint(gameId, bytes32(uint256(0xAD)));
    }

    function test_submitMidpoint_rejects_after_deadline() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            66, bytes32(uint256(0xC1)), LOW_ROOT, 0);
        vm.roll(vm.getBlockNumber() + BISECTION_TIMEOUT + 1);
        vm.prank(sequencer);
        vm.expectRevert(KnomosisFaultProofGame.TurnDeadlineExpired.selector);
        game.submitMidpoint(gameId, bytes32(uint256(0xAD)));
    }

    function test_respondToMidpoint_rejects_without_pending() public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            67, bytes32(uint256(0xC1)), LOW_ROOT, 0);
        vm.roll(vm.getBlockNumber() + MIN_STEP_INTERVAL + 1);
        // No midpoint submitted yet.  Challenger tries to respond.
        vm.prank(challenger);
        vm.expectRevert(KnomosisFaultProofGame.NoPendingMidpoint.selector);
        game.respondToMidpoint(gameId, true);
    }

    /* -------- Turn parity (SB riding-along item) -------- */

    /// @dev The in-progress game facts the parity invariant is stated
    ///      over, pulled out of the 15-slot `games()` tuple.
    function _gameView(uint256 gameId)
        private
        view
        returns (
            bool pending,
            KnomosisFaultProofGame.TurnSide turn,
            uint64 lowIdx,
            uint64 highIdx,
            KnomosisFaultProofGame.GameStatus status
        )
    {
        (
            ,
            ,
            KnomosisFaultProofGame.Claim memory low,
            KnomosisFaultProofGame.Claim memory high,
            bool hasPending,
            ,
            ,
            KnomosisFaultProofGame.TurnSide t,
            ,
            ,
            ,
            KnomosisFaultProofGame.GameStatus s,
            ,
            ,
        ) = game.games(gameId);
        return (hasPending, t, low.idx, high.idx, s);
    }

    /// @dev The parity invariant: an in-progress game is always in one
    ///      of exactly two shapes — (Sequencer's turn, no pending
    ///      midpoint) or (Challenger's turn, pending midpoint).  Lean:
    ///      `turnAlignedWithPending` (the iff form) preserved by
    ///      `turn_aligned_preserved`.
    function _assertTurnParity(uint256 gameId) private view {
        (bool pending, KnomosisFaultProofGame.TurnSide turn, , ,
         KnomosisFaultProofGame.GameStatus status) = _gameView(gameId);
        if (status != KnomosisFaultProofGame.GameStatus.InProgress) return;
        assertEq(pending,
            turn == KnomosisFaultProofGame.TurnSide.Challenger,
            "turn parity: a midpoint is pending iff it is the challenger's turn");
    }

    /// @notice **The challenger is never terminate-obligated.**  Drive
    ///         a random move sequence (the seed's bits pick each
    ///         response) from a 64-step dispute down to the single-step
    ///         range, asserting after every move that the game is in
    ///         the parity-reachable set {(Sequencer, no pending),
    ///         (Challenger, pending)} — and, when the range reaches one
    ///         step with no midpoint pending (the ONLY shape
    ///         `terminateOnSingleStep` accepts), that the responsible
    ///         party is the SEQUENCER.
    ///
    ///         Lean mirrors: `turnAlignedWithPending` /
    ///         `turn_aligned_preserved` /
    ///         `terminate_owner_is_sequencer` and the Settlement
    ///         corollary.  This is the assertion the audit-19 narrative
    ///         got backwards (it claimed a challenger could be forced
    ///         to terminate); the fuzz pins the truth on the deployed
    ///         bytecode across move sequences rather than one worked
    ///         example.
    function testFuzz_turn_parity_challenger_never_terminate_obligated(
        uint256 seed
    ) public {
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            64, bytes32(uint256(0xC1)), LOW_ROOT, 0);
        _assertTurnParity(gameId);

        // [0, 64] narrows to a single step in at most 6 disagree
        // rounds (12 moves); 32 move slots is comfortably past every
        // reachable sequence.
        bool reachedSingleStep = false;
        for (uint256 i = 0; i < 32; i++) {
            (bool pending, , uint64 lowIdx, uint64 highIdx,
             KnomosisFaultProofGame.GameStatus status) = _gameView(gameId);
            if (status != KnomosisFaultProofGame.GameStatus.InProgress) break;
            if (highIdx - lowIdx == 1 && !pending) {
                // THE CLAIM: the single-step obligation falls on the
                // sequencer.  By parity no midpoint is pending, so the
                // responsible party is the turn-holder — assert it is
                // the sequencer, whatever path the seed drove.
                (, KnomosisFaultProofGame.TurnSide turn, , ,) =
                    _gameView(gameId);
                assertEq(uint8(turn),
                    uint8(KnomosisFaultProofGame.TurnSide.Sequencer),
                    "the terminate obligation must fall on the sequencer");
                reachedSingleStep = true;
                break;
            }
            vm.roll(vm.getBlockNumber() + MIN_STEP_INTERVAL + 1);
            if (!pending) {
                // By parity it is the sequencer's move: submit a
                // midpoint claim (its value is irrelevant to parity).
                vm.prank(sequencer);
                game.submitMidpoint(gameId, bytes32(uint256(0xAD00) + i));
            } else {
                // By parity it is the challenger's move: agree or
                // disagree per the seed's next bit.
                vm.prank(challenger);
                game.respondToMidpoint(gameId, (seed >> i) & 1 == 1);
            }
            _assertTurnParity(gameId);
        }
        assertTrue(reachedSingleStep,
            "every move sequence must reach the single-step range");
    }
}

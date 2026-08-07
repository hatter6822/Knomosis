// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {ActionsRoot} from "src/lib/ActionsRoot.sol";
import {CBEEncode} from "src/lib/CBEEncode.sol";
import {SmtCellVerifier} from "src/lib/SmtCellVerifier.sol";
import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisDisputeVerifierV2} from "src/contracts/KnomosisDisputeVerifierV2.sol";
import {KnomosisFaultProofGame} from "src/contracts/KnomosisFaultProofGame.sol";
import {KnomosisStateRootSubmission} from "src/contracts/KnomosisStateRootSubmission.sol";
import {KnomosisStepVMRoot} from "src/contracts/KnomosisStepVMRoot.sol";
import {SignedActionProbe} from "../utils/SignedActionProbe.sol";
import {WithdrawalFlowHarness} from "../utils/WithdrawalFlowHarness.sol";
import {CrossCheckFramework} from "./Framework.t.sol";

/// @title BatchGameCrossCheck
/// @notice **The batched fault-proof pipeline end-to-end, on the real
///         contracts** (Workstream SB).  Every other game suite mocks
///         the registry; this one deploys the REAL
///         `KnomosisStateRootSubmission` + `KnomosisFaultProofGame` +
///         `KnomosisStepVMRoot` triple and drives a corpus probe
///         (`step_vm.json` `multiProofGoldens[0]`) through the whole
///         lifecycle:
///
///           * the sequencer SUBMITS a batch — one record covering
///             several L2 entries, its chain link folded from the
///             batch's actions root (rulings R5/R8);
///           * the challenger opens a game on the record, anchored at
///             the batch's start (ruling R2);
///           * bisection narrows the range INSIDE the batch;
///           * the terminal step authenticates the disputed action by
///             INCLUSION PROOF against the submitted actions root
///             (ruling R7) and adjudicates it on the step VM;
///           * the settlement lands back on the registry — cleared and
///             finalisable on a sequencer win; slashed, reverted, and
///             RECOVERABLE (rulings R1/R3/R4) on a challenger win.
///
///         The recovery half is the regression guard for one of the
///         two pre-existing defects Workstream SB closes: the retired
///         registry's reverted range was a dead end (reverted indices
///         could never be resubmitted), so no test could ever drive a
///         real challenger win THROUGH to a corrected chain.
contract BatchGameCrossCheck is
    CrossCheckFramework, WithdrawalFlowHarness, SignedActionProbe {
    /// @dev The EG.2 submission-breaker role.  Distinct from every
    ///      sequencer here: the constructor refuses a breaker equal
    ///      to the sequencer.
    address internal constant BREAKER = address(0xB4EA4E4);

    KnomosisStepVMRoot private stepVM;
    KnomosisStateRootSubmission private registry;
    KnomosisFaultProofGame private game;
    KnomosisBridge private bridge;
    KnomosisDisputeVerifierV2 private verifierV2;

    address private treasury = address(0xBEEF);
    address private sequencer = address(0xACE);
    address private challenger = address(0xCAFE);
    /// @dev A keyed attestor, so the test can drive the bridge's own
    ///      attested state-root lane (its reverted-range ceiling only
    ///      covers indices its lane has seen).
    uint256 private constant ATTESTOR_PK = 0xA77E5;

    uint128 private constant STATE_ROOT_BOND = 1 ether;
    uint128 private constant MIN_CHALLENGE_BOND = 0.05 ether;
    uint64 private constant DISPUTE_WINDOW = 100;
    uint64 private constant BISECTION_TIMEOUT = 100;
    uint64 private constant MIN_STEP_INTERVAL = 1;
    bytes32 private constant DEPLOYMENT_ID = bytes32(uint256(0xBA7C4));

    /// @notice The corpus probe's pre-state root — also the
    ///         registry's GENESIS state commit, so the probe's step is
    ///         entry 0 of the first batch.
    bytes32 private LOW_ROOT;

    uint8 private probeKind;
    bytes private probeFields;
    uint64 private probeSigner;
    bytes32 private probePostRoot;
    KnomosisStepVMRoot.OpenedCell[] private probeCells;
    bytes private probeGapMask;
    bytes private probeSiblings;
    /// @dev F-A: the signer's pre-state nonce and registry cell +
    ///      opening, which terminate resolves the public key from.
    uint64 private probeSignerNonce;
    bytes private probeRegistryValue;
    bytes private probeRegistryProof;

    /// @dev Load `multiProofGoldens[0]` (a `transfer`): a real
    ///      (pre-root, action, frontier, wire, post-root) quintuple.
    ///      Only a REAL probe can drive the honest path — the terminal
    ///      fold checks its aggregate against the game's anchored low,
    ///      so fabricated roots have no wire that reproduces them.
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
        probeSignerNonce = uint64(
            vm.parseJsonUint(raw, string.concat(base, ".signerNonceNat")));
        probeRegistryValue =
            vm.parseJsonBytes(raw, string.concat(base, ".registryValueHex"));
        probeRegistryProof =
            vm.parseJsonBytes(raw, string.concat(base, ".registryProofHex"));
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

    function setUp() public {
        stepVM = new KnomosisStepVMRoot();
        _loadProbe();

        // The FULL R6 wiring, with the same forward-reference
        // predictions the deploy scripts use.  Deployment order from
        // here: bridge(n), registry(n+1), game(n+2), verifierV2(n+3)
        // — the bridge's rollback authority and the game's dispute
        // verifier both point at the PREDICTED V2, which is then
        // require-checked once it exists.
        uint64 n = vm.getNonce(address(this));
        address predictedGame = vm.computeCreateAddress(address(this), n + 2);
        address predictedV2 = vm.computeCreateAddress(address(this), n + 3);

        bridge = new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("batchgame-test"),
                attestor: vm.addr(ATTESTOR_PK),
                disputeVerifier: address(0xDE),
                sequencerStake: address(0x5E),
                migration: address(0),
                disputeWindowBlocks: 100,
                maxRedemptionWindowBlocks: 50,
                maxAttestationStaleBlocks: 200,
                cooldownBlocks: 50,
                tvlCap: type(uint256).max,
                minFeeBps: 0,
                maxFeeBps: 5000,
                weiPerBudgetUnitEth: 1,
                weiPerBudgetUnitBold: 0,
                boldTokenAddress: address(0),
                boldTvlCap: 0,
                boldCircuitBreaker: address(0),
                boldAdmin: address(0),
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: 0,
                ammDisasterRecovery: address(0),
                faultProofRollbackAuthority: predictedV2,
                erc20ResourceIds: new uint64[](0),
                erc20TokenAddrs: new address[](0)
            })
        );
        registry = new KnomosisStateRootSubmission(
            STATE_ROOT_BOND,
            DISPUTE_WINDOW,
            MIN_STEP_INTERVAL,      // min submission interval
            10,                     // max outstanding roots
            sequencer,
            predictedGame,
            DEPLOYMENT_ID,
            DISPUTE_WINDOW,         // withdrawal finalisation window
            LOW_ROOT,               // genesis state commit = probe pre-root
            16,                     // max actions per batch
            BREAKER);
        game = new KnomosisFaultProofGame(
            BISECTION_TIMEOUT,
            MIN_CHALLENGE_BOND,
            MIN_STEP_INTERVAL,
            treasury,
            address(stepVM),
            address(registry),
            predictedV2
        );
        assertEq(address(game), predictedGame,
            "game address prediction must hold");
        address[] memory adjudicators = new address[](1);
        adjudicators[0] = address(0xAD1);
        verifierV2 = new KnomosisDisputeVerifierV2(
            address(game),
            address(registry),
            adjudicators,
            1,
            address(bridge),
            address(0x5E),          // sequencerStake
            address(0xA11CE),       // attestor
            DEPLOYMENT_ID
        );
        assertEq(address(verifierV2), predictedV2,
            "verifier address prediction must hold");
        assertEq(bridge.faultProofRollbackAuthority(), address(verifierV2),
            "the bridge's rollback authority is the V2 verifier");
        registry.assertConsistent();

        vm.deal(sequencer, 100 ether);
        vm.deal(challenger, 100 ether);
    }

    /* ---------------------------------------------------------- */
    /* Helpers                                                    */
    /* ---------------------------------------------------------- */

    /// @dev The probe's frontier, as a memory array for the call.
    function _cells()
        private
        view
        returns (KnomosisStepVMRoot.OpenedCell[] memory out)
    {
        out = new KnomosisStepVMRoot.OpenedCell[](probeCells.length);
        for (uint256 i = 0; i < out.length; i++) out[i] = probeCells[i];
    }

    /// @dev The probe action's REAL 65-byte wire signature
    ///      `(r ‖ s ‖ v)` — hashed into the leaf per ruling R7 AND
    ///      verified by the F-A gate at terminate, under the key the
    ///      corpus's pre-state registers for the probe signer.
    function _testSig() private view returns (bytes memory) {
        return signAction(
            probeKind, probeFields, probeSigner, probeSignerNonce,
            DEPLOYMENT_ID);
    }

    /// @dev `keccak256(kind ‖ uint64BE signer ‖ fields ‖ sig)` — the
    ///      test's own spelling of `ActionsRoot.actionLeafCommit`
    ///      (which takes calldata and cannot be handed memory bytes).
    function _actionLeafCommit(
        uint8 actionKind,
        uint64 signer,
        bytes memory actionFields,
        bytes memory actionSig
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(actionKind, signer, actionFields, actionSig));
    }

    /// @dev The actions root of a batch holding ONE action, at
    ///      absolute index `actionIdx` — the cell-SMT with a single
    ///      leaf, every path sibling the canonical empty sub-tree.
    ///      Its matching inclusion proof is `_singleEntryProof()`.
    function _singleLeafActionsRoot(uint64 actionIdx, bytes32 leafCommit)
        private
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

    /// @dev The single-leaf tree's inclusion proof: an all-zero
    ///      32-byte bitmask and no siblings.
    function _singleEntryProof() private pure returns (bytes memory) {
        return new bytes(32);
    }

    /// @dev The probe action's actions root: a batch whose entry 0 is
    ///      the probe's signed action.
    function _probeActionsRoot() private view returns (bytes32) {
        return _singleLeafActionsRoot(
            0,
            _actionLeafCommit(probeKind, probeSigner, probeFields, _testSig()));
    }

    /// @dev Roll past the per-move step interval.
    function _rollPastInterval() private {
        vm.roll(vm.getBlockNumber() + MIN_STEP_INTERVAL + 1);
    }

    /* ---------------------------------------------------------- */
    /* End-to-end: honest sequencer defends a batch               */
    /* ---------------------------------------------------------- */

    /// @notice A 4-entry batch is submitted, challenged, bisected down
    ///         to its first step, and defended: the terminal step is
    ///         authenticated by inclusion against the SUBMITTED actions
    ///         root and adjudicated on the step VM, the game settles
    ///         `SequencerWon`, and the record — cleared on the real
    ///         registry — finalises and releases its bond after the
    ///         window.
    ///
    /// @dev    Only the terminal pair (`commits[0]`, `commits[1]`) must
    ///         be a real (pre-root, post-root) step; the later commits
    ///         are bisection scaffolding the challenger disagrees with,
    ///         on which no step VM ever runs.  The intermediate roots
    ///         are never submitted to L1 — that is the batching point.
    function test_honest_sequencer_defends_a_batch_end_to_end() public {
        if (!fixtureExists("step_vm.json")) {
            _skipWithReason("fixture missing");
            return;
        }
        bytes32[5] memory commits;
        commits[0] = LOW_ROOT;
        commits[1] = probePostRoot;
        for (uint8 i = 2; i < 5; i++) {
            commits[i] = keccak256(abi.encodePacked(commits[i - 1], i));
        }
        bytes32 actionsRoot = _probeActionsRoot();

        // One record covers entries [0, 4).
        vm.prank(sequencer);
        registry.submitStateRoot{value: STATE_ROOT_BOND}(
            4, 0, commits[4], actionsRoot);
        assertEq(registry.canonicalTip(), 4, "tip extends to the batch end");

        // The challenger disputes the batch, anchored at its start.
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            4, bytes32(uint256(0xC1)), LOW_ROOT, 0);

        // Bisection INSIDE the batch: [0,4] → [0,2] → [0,1].
        _rollPastInterval();
        vm.prank(sequencer);
        game.submitMidpoint(gameId, commits[2]);
        _rollPastInterval();
        vm.prank(challenger);
        game.respondToMidpoint(gameId, false);
        _rollPastInterval();
        vm.prank(sequencer);
        game.submitMidpoint(gameId, commits[1]);
        _rollPastInterval();
        vm.prank(challenger);
        game.respondToMidpoint(gameId, false);

        // The terminate is INCLUSION-AUTHENTICATED: the bound action
        // under a different signature does not open in the batch.
        bytes memory otherSig = _testSig();
        otherSig[64] = otherSig[64] ^ bytes1(uint8(0xFF));
        vm.prank(sequencer);
        vm.expectRevert(KnomosisFaultProofGame.ActionNotInBatch.selector);
        game.terminateOnSingleStep(
            gameId, probeKind, probeFields, probeSigner,
            otherSig, _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings,
            probeRegistryValue, probeRegistryProof);

        // The batch-bound signed action adjudicates and wins.
        vm.prank(sequencer);
        game.terminateOnSingleStep(
            gameId, probeKind, probeFields, probeSigner,
            _testSig(), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings,
            probeRegistryValue, probeRegistryProof);

        // Registry effects of the sequencer win: cleared (not
        // slashed), bond intact, tip unmoved, nothing reverted.
        (, , , , uint128 bond, , bool finalised, bool disputed, ,) =
            registry.roots(4);
        assertEq(bond, STATE_ROOT_BOND, "bond stays until finalisation");
        assertFalse(disputed, "sequencer win clears the disputed flag");
        assertFalse(finalised, "not yet finalised");
        assertFalse(registry.isStateRootReverted(4), "nothing reverted");
        assertFalse(bridge.isStateRootReverted(4),
            "a sequencer win must not touch the bridge's reverted range");
        assertEq(registry.canonicalTip(), 4, "tip unmoved");
        assertGt(game.pendingWithdrawals(sequencer), 0,
            "winner credited the challenger's forfeited bond share");

        // Past the window the record finalises and the bond releases.
        vm.roll(vm.getBlockNumber() + DISPUTE_WINDOW + 1);
        uint256 balBefore = sequencer.balance;
        registry.finaliseStateRoot(4);
        assertEq(sequencer.balance, balBefore + STATE_ROOT_BOND,
            "finalisation releases the batch bond");
    }

    /* ---------------------------------------------------------- */
    /* End-to-end: challenger win reverts + recovery resubmits    */
    /* ---------------------------------------------------------- */

    /// @notice A batch publishing an INVALID root is challenged and
    ///         loses on the adjudicated step; the settlement lands on
    ///         the real registry — slashed, reverted, tip lowered to
    ///         the batch start — and the RECOVERY path (rulings R1/R3)
    ///         resubmits the corrected batch at the same key, which
    ///         reads canonical.
    ///
    /// @dev    The sequencer is FORCED onto the honest step: the
    ///         terminal action is inclusion-bound to what it published,
    ///         so the fold reaches the REAL post-root, which differs
    ///         from the fabricated commit — `ChallengerWon` on the
    ///         sequencer's own turn.
    function test_challenger_win_reverts_the_batch_then_recovery_resubmits()
        public
    {
        if (!fixtureExists("step_vm.json")) {
            _skipWithReason("fixture missing");
            return;
        }
        bytes32 actionsRoot = _probeActionsRoot();
        bytes32 fabricated = keccak256("not the step's post-root");

        // A single-entry batch [0, 1) committing a WRONG post-state.
        vm.prank(sequencer);
        registry.submitStateRoot{value: STATE_ROOT_BOND}(
            1, 0, fabricated, actionsRoot);

        // The bridge's own attested state-root lane sees the same
        // height, so its reverted-range ceiling can cover index 1
        // once the revert lands (the ceiling rises only to the
        // lane's latest submitted index).
        bridge.submitStateRoot(
            fabricated, 1, _signStateRootAs(ATTESTOR_PK, bridge, fabricated, 1));

        // The challenger claims the TRUE root.
        vm.prank(challenger);
        uint256 gameId = game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
            1, probePostRoot, LOW_ROOT, 0);

        // Range [0,1] is already single-step and it is the sequencer's
        // turn.  Executing the batch-bound step reaches the real
        // post-root ≠ the fabricated high ⇒ ChallengerWon.
        vm.prank(sequencer);
        game.terminateOnSingleStep(
            gameId, probeKind, probeFields, probeSigner,
            _testSig(), _singleEntryProof(),
            _cells(), probeGapMask, probeSiblings,
            probeRegistryValue, probeRegistryProof);

        // Registry effects of the challenger win: slashed, reverted,
        // tip lowered to the batch start.
        assertTrue(registry.isStateRootReverted(1), "record reverted");
        assertEq(registry.canonicalTip(), 0, "tip lowered to the batch start");
        // THE R6 WIRING, end-to-end on the real contracts: the
        // settlement drove game → V2 verifier (the bridge's
        // `faultProofRollbackAuthority`) → bridge, so the BRIDGE's
        // own reverted range — the one its fund-safety gates consult
        // — covers the invalid root.  This is the leg the shipped
        // wiring lacked: `revertStateRootsFrom` marked the registry
        // and nothing ever told the bridge.
        assertTrue(bridge.isStateRootReverted(1),
            "the challenger win must reach the bridge's reverted range");
        (, , , , uint128 bond, , , , ,) = registry.roots(1);
        assertEq(bond, 0, "sequencer bond slashed");
        uint256 pot = uint256(MIN_CHALLENGE_BOND) + uint256(STATE_ROOT_BOND);
        assertEq(game.pendingWithdrawals(challenger), (pot * 95) / 100,
            "challenger credited 95% of both bonds");
        vm.prank(challenger);
        game.withdraw();

        // THE BREAKER (EG.2) DOES NOT FIRE HERE, and that is the
        // point.  An earlier arrangement latched it inside
        // `revertStateRootsFrom`, which gated the repair rather than a
        // suspicious submission: the R1 recovery below is the
        // sequencer resubmitting after exactly this revert, so
        // latching turned every challenger win into a manual
        // intervention.  Pinned so a reintroduction fails here.
        assertFalse(registry.submissionsHalted(),
            "a challenger win must NOT halt submission -- R1 recovery is unattended");

        // RECOVERY (the path the retired registry lacked): the
        // corrected batch resubmits at the SAME key — allowed because
        // the record is reverted and its bond is out (ruling R3) —
        // and reads canonical, because it was submitted after the
        // revert stamp (ruling R1).
        _rollPastInterval();
        vm.prank(sequencer);
        registry.submitStateRoot{value: STATE_ROOT_BOND}(
            1, 0, probePostRoot, actionsRoot);
        assertEq(registry.canonicalTip(), 1, "corrected chain re-extends");
        assertFalse(registry.isStateRootReverted(1),
            "the corrected resubmission reads canonical");
    }
}

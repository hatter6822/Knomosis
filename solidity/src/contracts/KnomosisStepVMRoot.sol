// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {CBEEncode} from "../lib/CBEEncode.sol";
import {StepPlan} from "../lib/StepPlan.sol";
import {StepVMMerkle} from "../lib/StepVMMerkle.sol";
import {StepWrites} from "../lib/StepWrites.sol";

/// @title KnomosisStepVMRoot
/// @notice **The step VM that returns a state ROOT** — the fault
///         proof's terminal adjudicator.
///
/// @dev    This replaced `KnomosisStepVM`, whose `executeStep`
///         returned a bespoke per-variant hash — its own header said
///         the value "is NOT byte-identical to" a
///         `commitExtendedState` one.  The game fed it a state root
///         and compared the result to another state root, so the
///         comparison never succeeded and an honest sequencer lost
///         every game it correctly defended.  This contract computes
///         the other side: a post-state root, by folding the step's
///         proven cell writes into the pre-state root.
///
///         **The verifier derives the write list; it does not accept
///         one.**  Lean's `stepWriteBundle` reads its `newValue` column
///         off `productionApplyBudget` — the SEQUENCER's computation.
///         A verifier holding only the pre-root and a submitted bundle
///         has neither the post-state nor a reason to trust the values,
///         so folding what it is handed would let a responder choose
///         the resulting root.  Here every value is re-derived:
///
///           * the cell LIST from `StepWrites.deriveWriteSet`, checked
///             against the submitted openings position by position, so
///             a responder cannot omit a write and fold to a root where
///             that cell never moved;
///           * each cell's VALUE from `StepWrites` / `StepPlan`, which
///             are `productionApplyBudget` re-expressed cell-locally
///             and pinned cross-stack per kind.
///
///         **Openings are CHAINED.**  Proof `i` opens against the root
///         write `i-1` produced, not against the pre-root: an opening
///         goes stale the moment a write lands, and the self-transfer
///         (two writes at the SAME cell) is reachable by anyone. A fold
///         verifying every opening against the pre-root would accept
///         that bundle and reach a root no state has.
///
///         **A failing precondition is a no-op, not a revert.**  Every
///         derivation evaluates the law's precondition and returns the
///         pre-values when it fails, because `step_impl` is
///         `if pre then apply_impl else id`.  Reverting would not be a
///         verdict: the terminal step is callable only by whoever's
///         turn it is, so any reverting input costs the responsible
///         party the game by timeout — and the turn can land on the
///         challenger.  Reverts here are reserved for a MALFORMED
///         submission (a bundle naming the wrong cells, an opening that
///         does not verify), which is a submission failure rather than
///         a state-transition outcome.
///
///         Mirrors Lean's `stepPostRoot`; pinned cross-stack by the
///         corpus's `writeBundleGoldens` and `stepPostRootGoldens`.
contract KnomosisStepVMRoot {
    /// @notice One cell opening in the step's bundle.
    ///
    /// @dev    `preValue` is the cell's value in the state this opening
    ///         is against — the PRE-state for the first write to a
    ///         cell, and the running state for a later one.  It is not
    ///         trusted: the opening must verify against the running
    ///         root with a leaf built from exactly these bytes, so a
    ///         lie is caught by the walk rather than by a check.
    struct CellOpening {
        /// @dev The cell-kind discriminator (0..14).
        uint8 cellKind;
        /// @dev First key: resource / actor / depositId / withdrawal id.
        uint256 keyA;
        /// @dev Second key; balance cells only, where it is the actor.
        uint256 keyB;
        /// @dev The cell's value in the state this opening is against.
        bytes preValue;
        /// @dev The SMT opening: a 32-byte bitmask then the siblings.
        bytes proofData;
    }

    /// @notice The budget-policy cell kind.  Read-only, and the one
    ///         cell every step reads without writing.
    uint8 internal constant CELL_BUDGET_POLICY = 14;
    /// @notice The nonce cell kind.
    uint8 internal constant CELL_NONCE = 1;
    /// @notice The balance cell kind.
    uint8 internal constant CELL_BALANCE = 0;
    /// @notice The registry cell kind.
    uint8 internal constant CELL_REGISTRY = 2;
    /// @notice The local-policy cell kind.
    uint8 internal constant CELL_LOCAL_POLICY = 3;
    /// @notice The consumed-deposit cell kind.
    uint8 internal constant CELL_BRIDGE_CONSUMED = 4;
    /// @notice The pending-withdrawal cell kind.
    uint8 internal constant CELL_BRIDGE_PENDING = 5;
    /// @notice The withdrawal-counter cell kind.
    uint8 internal constant CELL_BRIDGE_NEXT_WD_ID = 6;
    /// @notice The epoch-budget cell kind.
    uint8 internal constant CELL_EPOCH_BUDGET = 13;

    /// @notice Maximum `proofData` length: a 32-byte bitmask plus one
    ///         32-byte sibling per set bit over a 256-deep tree.
    uint256 public constant MAX_PROOF_DATA_BYTES = 32 * (1 + 256);

    /// @notice Maximum openings in one step's bundle.
    /// @dev    The largest write set any adjudicable variant produces
    ///         is `depositWithFee`'s six; the cap is far above it so a
    ///         future variant does not silently hit a ceiling, while
    ///         still bounding the calldata a single call can carry.
    uint256 public constant MAX_CELL_OPENINGS = 32;

    /// @notice The read-only policy opening does not name the
    ///         budget-policy cell.
    error PolicyCellMismatch();

    /// @notice An opening did not verify against the running root.
    /// @param  index the opening's position; `type(uint256).max` for
    ///         the read-only policy opening, which has no position.
    error BadCellOpening(uint256 index);

    /// @notice The bundle names a different cell from the one the
    ///         action's write set declares at that position.
    error WriteSetMismatch(uint256 index);

    /// @notice The bundle's length is not the write set's.
    error WriteSetLengthMismatch(uint256 expected, uint256 got);

    /// @notice An opening's `proofData` is not a bitmask plus whole
    ///         32-byte siblings, or exceeds the depth bound.
    error MalformedProofData(uint256 length);

    /// @notice The bundle exceeds `MAX_CELL_OPENINGS`.
    error TooManyCellOpenings(uint256 count);

    /* ---------------------------------------------------------- */
    /* External: assertConsistent                                 */
    /* ---------------------------------------------------------- */

    /// @notice Deploy-time self-check, called by the deploy scripts.
    ///
    /// @dev    The two constants a bundle is bounded by, asserted
    ///         against their derivations rather than restated: the
    ///         opening cap is the tree's exact geometry (a bitmask plus
    ///         one sibling per level), and the bundle cap has to exceed
    ///         the largest write set any adjudicable variant produces —
    ///         `depositWithFee`'s six.  A build whose caps drifted
    ///         below either would reject honest bundles, which on a
    ///         terminal step costs the responsible party the game.
    function assertConsistent() external pure {
        require(
            MAX_PROOF_DATA_BYTES == 32 * (1 + 256), "ProofDataCapMismatch"
        );
        require(MAX_CELL_OPENINGS >= 6, "CellOpeningCapTooLow");
    }

    /* ---------------------------------------------------------- */
    /* External: executeStepToRoot                                */
    /* ---------------------------------------------------------- */

    /// @notice Execute one kernel step and return the POST-STATE ROOT.
    ///
    /// @param preStateRoot   the pre-state's published root.
    /// @param actionKind     the frozen `Action` dispatcher index.
    /// @param actionFields   the variant's L1 field bytes
    ///                       (`actionFieldsForL1`).
    /// @param signer         the action's signer.
    /// @param l2LogIndex     the log index this step produces.  Not a
    ///                       field: `withdraw`'s pending-withdrawal
    ///                       record carries it, so the game must supply
    ///                       the index it is adjudicating.
    /// @param policyOpening  the read-only budget-policy cell, opened
    ///                       against `preStateRoot`.
    /// @param writeOpenings  the written cells in `writeCellsAt` order,
    ///                       with CHAINED openings.
    /// @return postStateRoot the root the fold reaches.
    function executeStepToRoot(
        bytes32 preStateRoot,
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        uint256 l2LogIndex,
        CellOpening calldata policyOpening,
        CellOpening[] calldata writeOpenings
    ) external pure returns (bytes32 postStateRoot) {
        if (writeOpenings.length > MAX_CELL_OPENINGS) {
            revert TooManyCellOpenings(writeOpenings.length);
        }
        // 0. Refuse a non-adjudicable action before doing any work.
        //    The two bulk variants' write set is the actor set at a
        //    resource, which an L1 holding only the pre-root cannot
        //    enumerate — a complete bundle and one missing a recipient
        //    are indistinguishable to it.
        if (!StepWrites.isAdjudicable(actionKind)) {
            revert StepWrites.ActionNotAdjudicable(actionKind);
        }

        // 1. The policy cell, read-only against the PRE-root.  Verified
        //    first because `deriveEpochBudget` selects its branch on the
        //    policy, and every one of the twenty-five variants writes an
        //    epoch-budget cell.
        _requirePolicyOpening(preStateRoot, policyOpening);

        // 2. The write set, re-derived.  `nextWdIdPre` is read from the
        //    bundle because `withdraw`'s pending cell is keyed by the
        //    PRE-state counter — the one place a verifier reads a cell
        //    to learn WHICH cell to write.  A lie about it is caught by
        //    the fold: that opening must verify against the running
        //    root with a leaf built from exactly those bytes.
        StepWrites.Cell[] memory cells = StepWrites.deriveWriteSet(
            actionKind, actionFields, signer, _nextWdIdPre(writeOpenings));
        if (cells.length != writeOpenings.length) {
            revert WriteSetLengthMismatch(cells.length, writeOpenings.length);
        }
        for (uint256 i = 0; i < cells.length; i++) {
            _requireProofDataShape(writeOpenings[i].proofData.length);
            if (writeOpenings[i].cellKind != cells[i].kind
                || writeOpenings[i].keyA != cells[i].keyA
                || writeOpenings[i].keyB != cells[i].keyB) {
                revert WriteSetMismatch(i);
            }
        }

        // 3. The per-variant plan, from PRE-STATE values.
        StepPlan.Plan memory plan =
            _plan(actionKind, actionFields, signer, cells, writeOpenings);

        // 4. The fold.
        postStateRoot = preStateRoot;
        for (uint256 i = 0; i < cells.length; i++) {
            postStateRoot = _applyWrite(
                postStateRoot, i, cells, writeOpenings,
                actionKind, actionFields, signer, l2LogIndex,
                policyOpening.preValue, plan
            );
        }
    }

    /* ---------------------------------------------------------- */
    /* Internals                                                  */
    /* ---------------------------------------------------------- */

    /// @dev Verify the read-only policy opening against the pre-root.
    ///      Its cell identity is fixed (`(14, 0, 0)`) rather than
    ///      submitted, so a responder cannot open some OTHER cell and
    ///      pass its bytes off as the deployment's policy.
    function _requirePolicyOpening(
        bytes32 preStateRoot,
        CellOpening calldata policyOpening
    ) private pure {
        if (policyOpening.cellKind != CELL_BUDGET_POLICY
            || policyOpening.keyA != 0 || policyOpening.keyB != 0) {
            revert PolicyCellMismatch();
        }
        _requireProofDataShape(policyOpening.proofData.length);
        bytes32 smtKey =
            StepVMMerkle.deriveCellSmtKey(CELL_BUDGET_POLICY, 0, 0);
        // A read is a write of the same value, so it goes through the
        // SAME primitive the fold uses — one code path, one absence
        // branch.  An absent policy cell is a real state (a deployment
        // that has not ratified one reads the canonical zero policy),
        // and its leaf is the canonical empty one rather than a hash of
        // these bytes; a second verification path would be the place
        // that divergence hid.
        bool isAbsent =
            StepWrites.isCanonicallyAbsent(CELL_BUDGET_POLICY, policyOpening.preValue);
        bytes memory preimage = _leafPreimage(smtKey, policyOpening.preValue);
        (bool ok, bytes32 unchangedRoot) = StepVMMerkle.applyCellWrite(
            preStateRoot, abi.encodePacked(smtKey),
            isAbsent, preimage, isAbsent, preimage,
            policyOpening.proofData
        );
        if (!ok || unchangedRoot != preStateRoot) {
            revert BadCellOpening(type(uint256).max);
        }
    }

    /// @dev The leaf preimage Lean hashes:
    ///      `encodeAsBytes key ++ encodeAsBytes value`, which is two
    ///      CBE byte-strings.  Both heads are present even for an empty
    ///      payload, so a present-empty value stays distinguishable
    ///      from an absent one.
    function _leafPreimage(bytes32 smtKey, bytes memory value)
        private
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            CBEEncode.bytesValue(abi.encodePacked(smtKey)),
            CBEEncode.bytesValue(value)
        );
    }

    /// @dev A well-formed opening is a 32-byte bitmask followed by
    ///      whole 32-byte siblings, within the depth bound.
    function _requireProofDataShape(uint256 length) private pure {
        if (length == 0 || length % 32 != 0 || length > MAX_PROOF_DATA_BYTES) {
            revert MalformedProofData(length);
        }
    }

    /// @dev The proven `.bridgeNextWdId` pre-value, or zero when the
    ///      variant does not write that cell.  Scanned rather than
    ///      positional because only `withdraw` carries it.
    function _nextWdIdPre(CellOpening[] calldata writeOpenings)
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < writeOpenings.length; i++) {
            if (writeOpenings[i].cellKind == CELL_BRIDGE_NEXT_WD_ID) {
                return StepWrites.decodeNonce(writeOpenings[i].preValue);
            }
        }
        return 0;
    }

    /// @dev The PRE-STATE value of write-set cell `i`: the opening of
    ///      the FIRST write naming that cell.
    ///
    ///      A later write to the same cell opens against the running
    ///      state, so its `preValue` is the earlier write's result, not
    ///      the pre-state's.  Derivations are functions of the
    ///      pre-state, so they must read the first.  Duplicates are
    ///      reachable — a self-transfer, a `depositWithFee` whose
    ///      recipient is the signer — and every derivation is
    ///      idempotent on them, so the second write lands the same
    ///      value and leaves the root alone.
    function _preStateValue(
        StepWrites.Cell[] memory cells,
        CellOpening[] calldata writeOpenings,
        uint256 i
    ) private pure returns (bytes calldata) {
        for (uint256 j = 0; j < i; j++) {
            if (cells[j].kind == cells[i].kind
                && cells[j].keyA == cells[i].keyA
                && cells[j].keyB == cells[i].keyB) {
                return writeOpenings[j].preValue;
            }
        }
        return writeOpenings[i].preValue;
    }

    /// @dev The signer's epoch-budget PRE-value.  Its consume gates the
    ///      write to EVERY actor's budget cell, so a derivation reading
    ///      only the target's cell would credit a grant recipient on a
    ///      step the signer could not afford.
    function _signerBudgetPre(
        StepWrites.Cell[] memory cells,
        CellOpening[] calldata writeOpenings,
        uint64 signer
    ) private pure returns (bytes calldata) {
        for (uint256 i = 0; i < cells.length; i++) {
            if (cells[i].kind == CELL_EPOCH_BUDGET && cells[i].keyA == signer) {
                return _preStateValue(cells, writeOpenings, i);
            }
        }
        // Unreachable: `_appendUniform` puts the signer's budget cell in
        // every write set, and the bundle was checked against it.
        revert WriteSetMismatch(cells.length);
    }

    /// @dev The per-variant plan, over PRE-STATE balance values.
    function _plan(
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        StepWrites.Cell[] memory cells,
        CellOpening[] calldata writeOpenings
    ) private pure returns (StepPlan.Plan memory plan) {
        uint256 pre0 = cells.length > 0 && cells[0].kind == CELL_BALANCE
            ? StepWrites.decodeAmount(_preStateValue(cells, writeOpenings, 0))
            : 0;
        uint256 pre1 = cells.length > 1 && cells[1].kind == CELL_BALANCE
            ? StepWrites.decodeAmount(_preStateValue(cells, writeOpenings, 1))
            : 0;
        (plan.newBal0, plan.newBal1) =
            StepPlan.planBalances(actionKind, actionFields, signer, pre0, pre1);
        (plan.grantRecipient, plan.grantAmount, plan.refundExtra) =
            StepPlan.planGrant(actionKind, actionFields, signer);
    }

    /// @dev One write folded into the running root: derive the cell's
    ///      new value, verify the opening against the running root with
    ///      the OLD leaf, then re-walk the same opening from the NEW
    ///      one.
    function _applyWrite(
        bytes32 root,
        uint256 i,
        StepWrites.Cell[] memory cells,
        CellOpening[] calldata writeOpenings,
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        uint256 l2LogIndex,
        bytes calldata policyValue,
        StepPlan.Plan memory plan
    ) private pure returns (bytes32) {
        bytes memory newValue = _deriveValue(
            i, cells, writeOpenings, actionKind, actionFields,
            signer, l2LogIndex, policyValue, plan);
        bytes32 smtKey = StepVMMerkle.deriveCellSmtKey(
            cells[i].kind, cells[i].keyA, cells[i].keyB);
        bytes memory oldValue = writeOpenings[i].preValue;
        (bool ok, bytes32 next) = StepVMMerkle.applyCellWrite(
            root,
            abi.encodePacked(smtKey),
            StepWrites.isCanonicallyAbsent(cells[i].kind, oldValue),
            _leafPreimage(smtKey, oldValue),
            StepWrites.isCanonicallyAbsent(cells[i].kind, newValue),
            _leafPreimage(smtKey, newValue),
            writeOpenings[i].proofData
        );
        // Fatal, never skipped: a fold that dropped an unverified write
        // would reach a root for a state where that cell never moved,
        // which is precisely the forgery the fold exists to prevent.
        if (!ok) revert BadCellOpening(i);
        return next;
    }

    /// @dev Cell `i`'s post-value, derived from proven pre-values and
    ///      the action's own fields.
    function _deriveValue(
        uint256 i,
        StepWrites.Cell[] memory cells,
        CellOpening[] calldata writeOpenings,
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        uint256 l2LogIndex,
        bytes calldata policyValue,
        StepPlan.Plan memory plan
    ) private pure returns (bytes memory) {
        uint8 kind = cells[i].kind;
        if (kind == CELL_BALANCE) {
            // Positions 0 and 1 by construction of `deriveWriteSet`:
            // a variant's own cells precede the uniform pair, and every
            // balance-writing variant leads with them.  Asserted rather
            // than assumed — the plan is two scalars, so a third
            // balance cell would silently take the second one's value.
            if (i > 1) revert WriteSetMismatch(i);
            return CBEEncode.amountValue(i == 0 ? plan.newBal0 : plan.newBal1);
        }
        if (kind == CELL_NONCE) {
            return StepWrites.deriveNonce(_preStateValue(cells, writeOpenings, i));
        }
        if (kind == CELL_EPOCH_BUDGET) {
            return StepWrites.deriveEpochBudgetCellValue(
                policyValue,
                _signerBudgetPre(cells, writeOpenings, signer),
                _preStateValue(cells, writeOpenings, i),
                signer, uint64(cells[i].keyA),
                plan.grantRecipient, plan.grantAmount, plan.refundExtra
            );
        }
        if (kind == CELL_REGISTRY) {
            return StepWrites.deriveRegistryFromFields(actionFields);
        }
        if (kind == CELL_LOCAL_POLICY) {
            // 15 = declareLocalPolicy, whose cell value IS the action
            // fields; 16 = revokeLocalPolicy, which ERASES the entry
            // rather than storing an empty policy.
            return actionKind == 15
                ? StepWrites.deriveDeclaredPolicyCellValue(actionFields)
                : StepWrites.deriveRevokedPolicyCellValue();
        }
        if (kind == CELL_BRIDGE_CONSUMED) {
            return _deriveConsumed(actionKind, actionFields);
        }
        if (kind == CELL_BRIDGE_PENDING) {
            // withdraw: r @0, amount @16 (16), recipientL1 @32 (20).
            // The recipient is a SLICE, so its bound is checked here —
            // `readFieldUint` guards only its own reads.
            if (actionFields.length < 52) {
                revert StepWrites.ActionFieldsTooShort(
                    actionKind, actionFields.length);
            }
            return StepWrites.derivePendingCellValue(
                StepWrites.readFieldUint(actionFields, 0, 8),
                actionFields[32:52],
                StepWrites.readFieldUint(actionFields, 16, 16),
                l2LogIndex
            );
        }
        // `CELL_BRIDGE_NEXT_WD_ID` — the nonce's shape.  A reset
        // counter would let a later withdrawal overwrite an earlier
        // one's pending cell.
        return StepWrites.deriveNextWdIdCellValue(
            _preStateValue(cells, writeOpenings, i));
    }

    /// @dev The consumed-deposit record.  `deposit` is the degenerate
    ///      case with no fee split; writing it as explicit zeroes
    ///      rather than sharing `depositWithFee`'s field reads keeps
    ///      the two layouts visibly distinct.
    function _deriveConsumed(uint8 actionKind, bytes calldata fields)
        private
        pure
        returns (bytes memory)
    {
        if (actionKind == 13) {
            // deposit: r @0, amount @16 (16).
            return StepWrites.deriveConsumedCellValue(
                StepWrites.readFieldUint(fields, 0, 8),
                StepWrites.readFieldUint(fields, 16, 16),
                0, 0
            );
        }
        // depositWithFee: r @0, userAmount @24 (16), poolAmount @40
        // (16), budgetGrant @56.
        return StepWrites.deriveConsumedCellValue(
            StepWrites.readFieldUint(fields, 0, 8),
            StepWrites.readFieldUint(fields, 24, 16),
            StepWrites.readFieldUint(fields, 40, 16),
            StepWrites.readFieldUint(fields, 56, 8)
        );
    }
}

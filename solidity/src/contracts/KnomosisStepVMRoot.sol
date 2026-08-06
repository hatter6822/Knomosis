// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {CBEEncode} from "../lib/CBEEncode.sol";
import {SmtCellVerifier} from "../lib/SmtCellVerifier.sol";
import {SmtMultiVerifier} from "../lib/SmtMultiVerifier.sol";
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
///         one.**  Lean's honest bundle reads its post-values off
///         `productionApplyBudget` — the SEQUENCER's computation.  A
///         verifier holding only the pre-root and a submitted bundle
///         has neither the post-state nor a reason to trust the values,
///         so folding what it is handed would let a responder choose
///         the resulting root.  Here every value is re-derived:
///
///           * the cell LIST from `StepWrites.deriveWriteSet`, whose
///             frontier is checked against the submitted one as a SET,
///             so a responder cannot omit a write and fold to a root
///             where that cell never moved;
///           * each cell's VALUE from `StepWrites` / `StepPlan`, which
///             are `productionApplyBudget` re-expressed cell-locally
///             and pinned cross-stack per kind.
///
///         **The bundle is a DEDUPLICATING PRE-ROOT MULTIPROOF.**  Every
///         cell is opened once against the pre-root, sharing one
///         sibling list; the aggregate is compared to the pre-root
///         once.  A chained arrangement shipped first — one opening per
///         WRITE, each against the running root — and was retired here:
///         it cost a full second walk for a cell written twice (a
///         self-transfer, which anyone can submit), made bundle ORDER
///         part of consensus, and padded a short proof rather than
///         refusing it.
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
///         Mirrors Lean's `stepMultiPostRoot` / `verifierPostRootMulti`;
///         pinned cross-stack by the corpus's `multiProofGoldens`.
contract KnomosisStepVMRoot {
    /// @notice One opened cell in a MULTIPROOF bundle: its identity and
    ///         its PRE-state value, and no proof of its own.
    ///
    /// @dev    The whole difference from the retired `CellOpening` is
    ///         the missing `proofData`.  Under a multiproof every cell is opened
    ///         against the SAME root, so the openings share one sibling
    ///         list and a per-cell path would be redundant; and because
    ///         a cell appears exactly once, `preValue` is unambiguously
    ///         the pre-state's rather than "the running state's, which
    ///         is the pre-state's only for the first write".
    ///
    ///         `preValue` is no more trusted here than there: it enters
    ///         the PRE-side fold, which must reproduce the submitted
    ///         pre-root, so a lie moves the aggregate off it.
    struct OpenedCell {
        /// @dev The cell-kind discriminator (0..14).
        uint8 cellKind;
        /// @dev First key: resource / actor / depositId / withdrawal id.
        uint256 keyA;
        /// @dev Second key; balance cells only, where it is the actor.
        uint256 keyB;
        /// @dev The cell's PRE-state value.
        bytes preValue;
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

    /// @notice Maximum opened cells in one step's frontier.
    /// @dev    Checked against the write set itself by
    ///         [`widestFrontier`] rather than restated: the cap must
    ///         exceed the widest write set any adjudicable variant
    ///         produces, plus the read-only policy cell.
    uint256 public constant MAX_CELL_OPENINGS = 32;

    /// @notice The highest frozen `Action` dispatcher index.
    ///
    /// @dev    Typed `uint8` because that is the width the action kind
    ///         has on the wire (`actionKindByte`) and the width both
    ///         consumers — `StepWrites.isAdjudicable` and
    ///         `StepWrites.deriveWriteSet` — accept.  Declaring it
    ///         `uint256` forced a truncating `uint8(k)` cast at every
    ///         call site; typing it here removes the cast rather than
    ///         annotating it as safe.
    uint8 internal constant MAX_ACTION_KIND = 24;

    /// @notice Field-buffer length `widestFrontier` probes with —
    ///         comfortably past the longest layout `actionFieldsForL1`
    ///         produces (`depositWithFee`'s 64 bytes).
    uint256 internal constant PROBE_FIELD_BYTES = 128;

    /// @notice The frontier names a cell the write set does not, at a
    ///         position where only a write set cell can appear.
    error WriteSetMismatch(uint256 index);

    /// @notice The frontier exceeds `MAX_CELL_OPENINGS`.
    error TooManyCellOpenings(uint256 count);

    /// @notice A cell the step's frontier requires is not opened.
    /// @param  index the write-set position, or `type(uint256).max`
    ///         for the read-only budget-policy cell.
    error FrontierMissingCell(uint256 index);

    /// @notice The frontier's size is not the one the key set implies.
    error FrontierLengthMismatch(uint256 expected, uint256 got);

    /// @notice The multiproof's PRE side does not reproduce the
    ///         submitted pre-state root.
    error PreRootMismatch(bytes32 expected, bytes32 got);

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
    function assertConsistent() external view {
        // Re-derived, not restated.  The bound used to be the literal
        // `>= 6`, which is a claim about `deriveWriteSet` written down
        // somewhere `deriveWriteSet` cannot contradict — so a variant
        // whose write set grew would pass the check and reject honest
        // bundles at runtime, which on a terminal step costs the
        // responsible party the game by timeout.  This asks the write
        // set itself, over every adjudicable kind.
        require(
            MAX_CELL_OPENINGS >= this.widestFrontier(new bytes(PROBE_FIELD_BYTES)),
            "CellOpeningCapTooLow"
        );
    }

    /// @notice The widest frontier any adjudicable action can produce:
    ///         the largest write set over the frozen kinds, plus the
    ///         read-only budget-policy cell.
    ///
    /// @dev    `probeFields` is a zero buffer long enough to satisfy
    ///         every variant's field-length requirement.  Only the
    ///         write set's LENGTH is read, and that is a function of
    ///         the action kind alone — the field bytes determine which
    ///         cells, never how many — so degenerate values are exactly
    ///         as informative as real ones here.
    ///
    ///         Separate from `assertConsistent` because `deriveWriteSet`
    ///         takes `calldata` and a no-argument `pure` function has
    ///         none to give it; `assertConsistent` reaches this through
    ///         a `staticcall` on itself.
    ///
    /// @param  probeFields a zero buffer of at least `PROBE_FIELD_BYTES`.
    /// @return widest      the largest frontier size.
    function widestFrontier(bytes calldata probeFields)
        external
        pure
        returns (uint256 widest)
    {
        require(probeFields.length >= PROBE_FIELD_BYTES, "ProbeFieldsTooShort");
        for (uint8 k = 0; k <= MAX_ACTION_KIND; k++) {
            if (!StepWrites.isAdjudicable(k)) continue;
            uint256 n =
                StepWrites.deriveWriteSet(k, probeFields, 0, 0).length + 1;
            if (n > widest) widest = n;
        }
    }

    /* ---------------------------------------------------------- */
    /* External: executeStepToRootMulti                            */
    /* ---------------------------------------------------------- */

    /// @notice Execute one kernel step against a DEDUPLICATING PRE-ROOT
    ///         MULTIPROOF and return the post-state root.
    ///
    /// @dev    The same adjudication as `executeStepToRoot`, opened the
    ///         other way.  Four differences, each a property rather
    ///         than an optimisation:
    ///
    ///           * **One root check, not `m`.**  Every cell is opened
    ///             against the pre-root, and the aggregate PRE fold is
    ///             compared to it once.  No intermediate root is
    ///             materialised, so none is trusted.
    ///           * **Order carries no information.**  The verifier
    ///             sorts by path index, so a permuted bundle yields the
    ///             identical root and `_preStateValue`'s
    ///             first-occurrence rule has nothing left to
    ///             disambiguate — lookup is by cell identity, which is
    ///             what it always meant.
    ///           * **A duplicate is not representable.**  Strict
    ///             ascent after the sort is the distinctness check, so
    ///             a bundle carrying one cell twice fails before any
    ///             hashing.
    ///           * **The wire's shape is derived from the key set**
    ///             (`SmtMultiVerifier.requireShape`), so a short proof
    ///             is refused rather than padded out with a placeholder
    ///             hash and walked to some other root.
    ///
    ///         The read-only policy cell stops being special: it joins
    ///         the frontier as a cell written to its own value, so it
    ///         needs no separate opening and no separate 256-level
    ///         walk.  A read is a write of the same value.
    ///
    ///         Mirrors Lean's `verifierPostRootMulti` / `stepMultiPostRoot`;
    ///         pinned cross-stack by the corpus's `multiProofGoldens`.
    ///
    /// @param preStateRoot the pre-state's published root.
    /// @param actionKind   the frozen `Action` dispatcher index.
    /// @param actionFields the variant's L1 field bytes.
    /// @param signer       the action's signer.
    /// @param l2LogIndex   the log index this step produces.
    /// @param opened       the frontier: the written cells plus the
    ///                     budget policy, deduplicated, in ANY order.
    /// @param gapMask      one bit per gap, LSB-first within each byte.
    /// @param siblings     the packed non-canonical-empty siblings.
    /// @return postStateRoot the root the merged fold reaches.
    function executeStepToRootMulti(
        bytes32 preStateRoot,
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        uint256 l2LogIndex,
        OpenedCell[] calldata opened,
        bytes calldata gapMask,
        bytes calldata siblings
    ) external pure returns (bytes32 postStateRoot) {
        if (opened.length > MAX_CELL_OPENINGS) {
            revert TooManyCellOpenings(opened.length);
        }
        if (!StepWrites.isAdjudicable(actionKind)) {
            revert StepWrites.ActionNotAdjudicable(actionKind);
        }

        // 1. The write set, re-derived.  `nextWdIdPre` comes from the
        //    bundle for the same reason as in the chained path — it
        //    names WHICH pending cell `withdraw` writes — and a lie
        //    about it is caught the same way: `.bridgeNextWdId` is
        //    itself opened, so its claimed pre-value enters the PRE
        //    fold and a wrong one moves the aggregate off the root.
        StepWrites.Cell[] memory cells = StepWrites.deriveWriteSet(
            actionKind, actionFields, signer, _nextWdIdPreMulti(opened));

        // 2. The frontier: the write set plus the policy cell,
        //    deduplicated.  Checked as a SET — every required cell is
        //    opened, and the counts agree — which with the strict
        //    ascent enforced inside the walk is set equality.
        _requireFrontier(cells, opened);

        // 3. Path order, and the leaves on both sides.
        (uint256[] memory sorted, bytes32[] memory preLeaves,
         bytes32[] memory postLeaves) =
            _multiLeaves(cells, opened, actionKind, actionFields, signer, l2LogIndex);

        // 4. One merged walk producing both roots: the siblings are
        //    sub-trees holding no opened cell, so the writes cannot
        //    move them and both folds share them.
        bytes32 preRoot;
        (preRoot, postStateRoot) = SmtMultiVerifier.multiWalkPair(
            sorted, preLeaves, postLeaves, gapMask, siblings,
            SmtCellVerifier.precomputeEmptySubtreeHashes()
        );
        if (preRoot != preStateRoot) revert PreRootMismatch(preStateRoot, preRoot);
    }

    /* ---------------------------------------------------------- */
    /* Internals — the multiproof path                            */
    /* ---------------------------------------------------------- */

    /// @dev The proven `.bridgeNextWdId` pre-value, or zero when the
    ///      frontier does not open that cell.
    function _nextWdIdPreMulti(OpenedCell[] calldata opened)
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < opened.length; i++) {
            if (opened[i].cellKind == CELL_BRIDGE_NEXT_WD_ID) {
                return StepWrites.decodeNonce(opened[i].preValue);
            }
        }
        return 0;
    }

    /// @dev The position of a cell in the opened set, or
    ///      `type(uint256).max`.
    function _findOpened(
        OpenedCell[] calldata opened,
        uint8 kind,
        uint256 keyA,
        uint256 keyB
    ) private pure returns (uint256) {
        for (uint256 i = 0; i < opened.length; i++) {
            if (opened[i].cellKind == kind && opened[i].keyA == keyA
                && opened[i].keyB == keyB) {
                return i;
            }
        }
        return type(uint256).max;
    }

    /// @dev A cell's proven PRE-value, looked up by identity.  Reverts
    ///      rather than defaulting: `_requireFrontier` has already
    ///      established the cell is opened, so a miss here is a bug in
    ///      this contract and not a submission a responder can make.
    function _openedValue(
        OpenedCell[] calldata opened,
        uint8 kind,
        uint256 keyA,
        uint256 keyB
    ) private pure returns (bytes calldata) {
        uint256 i = _findOpened(opened, kind, keyA, keyB);
        if (i == type(uint256).max) revert FrontierMissingCell(i);
        return opened[i].preValue;
    }

    /// @dev How many DISTINCT cells the step's frontier holds: the
    ///      write set deduplicated, plus the budget policy.
    ///
    ///      The policy never collides with a write — no adjudicable
    ///      action writes cell kind 14 — so it contributes exactly one.
    function _frontierSize(StepWrites.Cell[] memory cells)
        private
        pure
        returns (uint256 n)
    {
        n = 1;
        for (uint256 i = 0; i < cells.length; i++) {
            bool dup = false;
            for (uint256 j = 0; j < i; j++) {
                if (cells[j].kind == cells[i].kind && cells[j].keyA == cells[i].keyA
                    && cells[j].keyB == cells[i].keyB) {
                    dup = true;
                    break;
                }
            }
            if (!dup) n++;
        }
    }

    /// @dev The opened set is exactly the step's frontier.
    ///
    ///      Membership plus equal cardinality gives set equality once
    ///      the opened cells are known distinct — which the walk
    ///      enforces by requiring strict ascent.  Checking membership
    ///      alone would let a responder pad the bundle with an extra
    ///      cell; checking the count alone would let them swap one.
    function _requireFrontier(
        StepWrites.Cell[] memory cells,
        OpenedCell[] calldata opened
    ) private pure {
        uint256 want = _frontierSize(cells);
        if (opened.length != want) {
            revert FrontierLengthMismatch(want, opened.length);
        }
        if (_findOpened(opened, CELL_BUDGET_POLICY, 0, 0) == type(uint256).max) {
            revert FrontierMissingCell(type(uint256).max);
        }
        for (uint256 i = 0; i < cells.length; i++) {
            if (_findOpened(opened, cells[i].kind, cells[i].keyA, cells[i].keyB)
                == type(uint256).max) {
                revert FrontierMissingCell(i);
            }
        }
    }

    /// @dev Sort the opened cells into path order and build both sides'
    ///      leaves.
    ///
    ///      An insertion sort over the path indices: `m <= 8` on every
    ///      adjudicable variant, so it is ~28 comparisons at the
    ///      realistic size and bounded by `MAX_CELL_OPENINGS` above.
    ///      The sort is what makes the wire order-free — the caller may
    ///      submit the frontier however it likes, and the walk still
    ///      sees the one order the tree defines.
    function _multiLeaves(
        StepWrites.Cell[] memory cells,
        OpenedCell[] calldata opened,
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        uint256 l2LogIndex
    )
        private
        pure
        returns (
            uint256[] memory sorted,
            bytes32[] memory preLeaves,
            bytes32[] memory postLeaves
        )
    {
        uint256 m = opened.length;
        sorted = new uint256[](m);
        preLeaves = new bytes32[](m);
        postLeaves = new bytes32[](m);
        uint256[] memory order = new uint256[](m);

        for (uint256 i = 0; i < m; i++) {
            sorted[i] = SmtMultiVerifier.pathIndex(
                StepVMMerkle.deriveCellSmtKey(
                    opened[i].cellKind, opened[i].keyA, opened[i].keyB));
            order[i] = i;
        }
        for (uint256 i = 1; i < m; i++) {
            uint256 key = sorted[i];
            uint256 pos = order[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1] > key) {
                sorted[j] = sorted[j - 1];
                order[j] = order[j - 1];
                j--;
            }
            sorted[j] = key;
            order[j] = pos;
        }

        bytes memory policyValue =
            _openedValue(opened, CELL_BUDGET_POLICY, 0, 0);
        StepPlan.Plan memory plan =
            _planMulti(actionKind, actionFields, signer, cells, opened);

        for (uint256 p = 0; p < m; p++) {
            uint256 i = order[p];
            bytes32 smtKey = StepVMMerkle.deriveCellSmtKey(
                opened[i].cellKind, opened[i].keyA, opened[i].keyB);
            preLeaves[p] = StepVMMerkle.cellLeafHash(
                StepWrites.isCanonicallyAbsent(opened[i].cellKind, opened[i].preValue),
                _leafPreimage(smtKey, opened[i].preValue)
            );
            // The policy cell is a READ: its post-value is its
            // pre-value, so its leaf is unchanged and it contributes to
            // both folds identically.
            bytes memory newValue = opened[i].cellKind == CELL_BUDGET_POLICY
                ? opened[i].preValue
                : _deriveValueMulti(
                    i, cells, opened, actionKind, actionFields,
                    signer, l2LogIndex, policyValue, plan);
            postLeaves[p] = StepVMMerkle.cellLeafHash(
                StepWrites.isCanonicallyAbsent(opened[i].cellKind, newValue),
                _leafPreimage(smtKey, newValue)
            );
        }
    }

    /// @dev The per-variant plan, over PRE-STATE balance values read BY
    ///      CELL.  Positions 0..3 of the WRITE SET are the balance
    ///      cells the plan's four slots belong to — positions 2 and 3
    ///      exist only for `reserveSwap` (kind 25), the first
    ///      four-balance-cell variant; every other kind's plan is the
    ///      familiar pair plus pass-through.
    function _planMulti(
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        StepWrites.Cell[] memory cells,
        OpenedCell[] calldata opened
    ) private pure returns (StepPlan.Plan memory plan) {
        uint256 pre0 = _balancePreAt(cells, opened, 0);
        uint256 pre1 = _balancePreAt(cells, opened, 1);
        uint256 pre2 = _balancePreAt(cells, opened, 2);
        uint256 pre3 = _balancePreAt(cells, opened, 3);
        (plan.newBal0, plan.newBal1, plan.newBal2, plan.newBal3) =
            StepPlan.planBalances4(
                actionKind, actionFields, signer, pre0, pre1, pre2, pre3);
        (plan.grants, plan.grantRecipient, plan.grantAmount, plan.refundExtra) =
            StepPlan.planGrant(actionKind, actionFields, signer);
    }

    /// @dev Write-set position `i`'s proven pre-value when it is a
    ///      balance cell, else zero (the plan ignores that slot).
    function _balancePreAt(
        StepWrites.Cell[] memory cells,
        OpenedCell[] calldata opened,
        uint256 i
    ) private pure returns (uint256) {
        return cells.length > i && cells[i].kind == CELL_BALANCE
            ? StepWrites.decodeAmount(
                _openedValue(opened, CELL_BALANCE, cells[i].keyA, cells[i].keyB))
            : 0;
    }

    /// @dev Opened cell `i`'s post-value, derived from proven
    ///      pre-values and the action's own fields.
    ///
    ///      The chained twin selects the balance slot by the write
    ///      set's POSITION; here the cell arrives by identity, so the
    ///      slot is found by matching against `cells[0]` / `cells[1]`.
    ///      Those are the same two cells the plan was computed from,
    ///      which is what keeps the two paths' arithmetic identical
    ///      even at an alias, where both positions name one cell and
    ///      the plan's two slots hold the same value.
    function _deriveValueMulti(
        uint256 i,
        StepWrites.Cell[] memory cells,
        OpenedCell[] calldata opened,
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        uint256 l2LogIndex,
        bytes memory policyValue,
        StepPlan.Plan memory plan
    ) private pure returns (bytes memory) {
        uint8 kind = opened[i].cellKind;
        if (kind == CELL_BALANCE) {
            if (cells.length > 0 && cells[0].kind == CELL_BALANCE
                && cells[0].keyA == opened[i].keyA && cells[0].keyB == opened[i].keyB) {
                return CBEEncode.amountValue(plan.newBal0);
            }
            if (cells.length > 1 && cells[1].kind == CELL_BALANCE
                && cells[1].keyA == opened[i].keyA && cells[1].keyB == opened[i].keyB) {
                return CBEEncode.amountValue(plan.newBal1);
            }
            if (cells.length > 2 && cells[2].kind == CELL_BALANCE
                && cells[2].keyA == opened[i].keyA && cells[2].keyB == opened[i].keyB) {
                return CBEEncode.amountValue(plan.newBal2);
            }
            if (cells.length > 3 && cells[3].kind == CELL_BALANCE
                && cells[3].keyA == opened[i].keyA && cells[3].keyB == opened[i].keyB) {
                return CBEEncode.amountValue(plan.newBal3);
            }
            // Unreachable: `_requireFrontier` admitted this cell, so it
            // is in the write set, and only positions 0..3 are
            // balances.
            revert WriteSetMismatch(i);
        }
        if (kind == CELL_NONCE) {
            return StepWrites.deriveNonce(opened[i].preValue);
        }
        if (kind == CELL_EPOCH_BUDGET) {
            return StepWrites.deriveEpochBudgetCellValue(
                policyValue,
                _openedValue(opened, CELL_EPOCH_BUDGET, signer, 0),
                opened[i].preValue,
                signer, uint64(opened[i].keyA),
                plan.grants, plan.grantRecipient, plan.grantAmount,
                plan.refundExtra
            );
        }
        if (kind == CELL_REGISTRY) {
            return StepWrites.deriveRegistryFromFields(actionFields);
        }
        if (kind == CELL_LOCAL_POLICY) {
            return actionKind == 15
                ? StepWrites.deriveDeclaredPolicyCellValue(actionFields)
                : StepWrites.deriveRevokedPolicyCellValue();
        }
        if (kind == CELL_BRIDGE_CONSUMED) {
            return _deriveConsumed(actionKind, actionFields);
        }
        if (kind == CELL_BRIDGE_PENDING) {
            // withdraw: r @0, sender @8, amount @16 (32), then the
            // 20-byte L1 address at @48 — the address moved with the
            // amount, so the length floor moves from 52 to 68.
            if (actionFields.length < 68) {
                revert StepWrites.ActionFieldsTooShort(
                    actionKind, actionFields.length);
            }
            // The withdrawal id is the CELL KEY.  It is the
            // verifier's own — `deriveWriteSet` builds this cell from
            // the proven `.bridgeNextWdId` value, and the frontier is
            // checked against that write set — so binding the leaf's
            // claimed id to it cannot be steered by the responder.
            return StepWrites.derivePendingCellValue(
                StepWrites.readFieldUint(actionFields, 0, 8),
                actionFields[48:68],
                StepWrites.readFieldUint(actionFields, 16, 32),
                l2LogIndex,
                opened[i].keyA
            );
        }
        return StepWrites.deriveNextWdIdCellValue(opened[i].preValue);
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
            // deposit: r @0, amount @16 (32).
            return StepWrites.deriveConsumedCellValue(
                StepWrites.readFieldUint(fields, 0, 8),
                StepWrites.readFieldUint(fields, 16, 32),
                0, 0
            );
        }
        // depositWithFee: r @0, userAmount @24 (32), poolAmount @56
        // (32), budgetGrant @88.
        return StepWrites.deriveConsumedCellValue(
            StepWrites.readFieldUint(fields, 0, 8),
            StepWrites.readFieldUint(fields, 24, 32),
            StepWrites.readFieldUint(fields, 56, 32),
            StepWrites.readFieldUint(fields, 88, 8)
        );
    }
}

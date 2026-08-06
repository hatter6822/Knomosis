// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {StepWrites} from "./StepWrites.sol";

/// @title StepPlan
/// @notice The per-variant scalars a step's cell derivations need,
///         read off the action fields.
///
/// @dev    **Why the balances cannot be derived cell-by-cell.**  Five
///         variants write two balance cells that are CHAINED: the
///         second read sees the first write.  A dispatch that derived
///         each cell independently from its own pre-value would
///         double-count whenever the two actors coincide — and that
///         case is reachable in every one of them (a self-transfer, a
///         signer who IS the pool actor), cheaply, by anyone.  So the
///         pair is planned once, up front, from BOTH pre-values.
///
///         The balance cells are always write-set positions 0 and 1:
///         `StepWrites.deriveWriteSet` emits a variant's own cells
///         before the uniform nonce/budget pair, and every
///         balance-writing variant leads with them.  That is what lets
///         the plan be a pair of scalars rather than a map.
///
///         **Field offsets are the silent-failure surface.**  Every
///         layout is big-endian with mixed widths (`uint64BE`
///         identifiers, `uint128BE` amounts), so a one-field slip
///         still decodes to a plausible actor id and a plausible
///         amount.  They are pinned cross-stack by the corpus's
///         `writeSetGoldens` (the cell identities) and
///         `balanceWriteGoldens` (the arithmetic) over the ACTUAL
///         field bytes, not reasoned about here.
library StepPlan {
    /// @notice The scalars one step's derivations need beyond its
    ///         proven cells.
    ///
    /// @dev    A struct rather than a return tuple because the fold
    ///         threads it through every write, and Solidity's stack
    ///         does not survive passing five loose values plus the
    ///         openings under `via_ir`.
    struct Plan {
        /// @dev Post-value of write-set cell 0 when it is a balance.
        uint256 newBal0;
        /// @dev ...and of cell 1.
        uint256 newBal1;
        /// @dev ...and of cells 2 and 3 — used only by `reserveSwap`
        ///      (kind 25), the first FOUR-balance-cell variant (the
        ///      user and the reserve each move at both swap
        ///      resources).  Every other variant leaves them at their
        ///      pre-values via `planBalances4`'s pass-through.
        uint256 newBal2;
        /// @dev See `newBal2`.
        uint256 newBal3;
        /// @dev Whether this variant grants budget AT ALL.
        ///
        ///      Carried separately from `grantAmount` because a zero
        ///      amount is NOT the same condition.  `ActorBudget.topUp`
        ///      normalises before it adds, so a grant of zero still
        ///      refreshes a stale cell to the free tier — and
        ///      `grantRecipient` is `0` for the twenty-two variants
        ///      that grant nothing, which collides with the real actor
        ///      id `0`.  Inferring "no grant" from `grantAmount == 0`
        ///      conflated the two and skipped the normalisation Lean
        ///      performs, forking the state root.
        bool grants;
        /// @dev The actor an action grants budget to, if any.
        uint64 grantRecipient;
        /// @dev The granted units.  May legitimately be zero on a
        ///      granting variant — see `grants`.
        uint256 grantAmount;
        /// @dev The extra budget consume a refund claim carries.
        uint256 refundExtra;
    }

    /// @notice The grant and the refund's extra consume, per variant.
    ///
    /// @dev    Mirrors `ProductionApply.budgetGrant` and
    ///         `Authority.refundConsumeExtra`.  The recipient differs
    ///         per variant — `depositWithFee` grants to the deposit's
    ///         recipient, `topUpActionBudget` to the SIGNER,
    ///         `topUpActionBudgetFor` to the named recipient — which is
    ///         why this cannot collapse into "top up the signer".
    ///
    /// @param  actionKind the frozen dispatcher index.
    /// @param  fields     the action's L1 field bytes.
    /// @param  signer     the action's signer.
    function planGrant(uint8 actionKind, bytes calldata fields, uint64 signer)
        internal
        pure
        returns (
            bool grants,
            uint64 grantRecipient,
            uint256 grantAmount,
            uint256 refundExtra
        )
    {
        if (actionKind == 19) {
            // depositWithFee: recipient @8, budgetGrant @88 — it
            // follows BOTH 32-byte amounts.
            return (
                true,
                uint64(StepWrites.readFieldUint(fields, 8, 8)),
                StepWrites.readFieldUint(fields, 88, 8),
                0
            );
        }
        if (actionKind == 20) {
            // topUpActionBudget: the SIGNER, budgetIncrement @40 —
            // it follows the 32-byte gasAmount at 8.
            return (true, signer, StepWrites.readFieldUint(fields, 40, 8), 0);
        }
        if (actionKind == 21) {
            // topUpActionBudgetFor: recipient @0, budgetIncrement @48
            // — it follows the 32-byte gasAmount at 16.
            return (
                true,
                uint64(StepWrites.readFieldUint(fields, 0, 8)),
                StepWrites.readFieldUint(fields, 48, 8),
                0
            );
        }
        if (actionKind == 22) {
            // claimBudgetRefund burns the units it cashes out, on top
            // of the action cost — which is what stops a refund from
            // being a free round trip.  budgetUnits @8 — UNCHANGED by
            // the amount widening: it PRECEDES `weiPerBudgetUnit`,
            // which is the field that widened.  It grants nothing.
            return (false, 0, 0, StepWrites.readFieldUint(fields, 8, 8));
        }
        return (false, 0, 0, 0);
    }

    /// @notice The post-values of a step's balance cells.
    ///
    /// @dev    Every branch EVALUATES the law's precondition rather
    ///         than asserting it: `step_impl` is
    ///         `if pre then apply_impl else id`, so an action whose
    ///         precondition fails advances no balance and its cells
    ///         keep their pre-values.  Reverting instead would not be a
    ///         verdict — the terminal step is callable only by whoever's
    ///         turn it is, so any reverting input costs the responsible
    ///         party the game by timeout, and the turn can land on the
    ///         challenger.
    ///
    /// @param  pre0 the PRE-STATE value of write-set cell 0.
    /// @param  pre1 the PRE-STATE value of write-set cell 1 (zero when
    ///         the variant writes only one balance).
    function planBalances(
        uint8 actionKind,
        bytes calldata fields,
        uint64 signer,
        uint256 pre0,
        uint256 pre1
    ) internal pure returns (uint256 new0, uint256 new1) {
        if (actionKind == 0) {
            // transfer: r @0, sender @8, receiver @16, amount @24 (32).
            return StepWrites.deriveTransferBalances(
                pre0, pre1,
                uint64(StepWrites.readFieldUint(fields, 8, 8)),
                uint64(StepWrites.readFieldUint(fields, 16, 8)),
                StepWrites.readFieldUint(fields, 24, 32)
            );
        }
        if (actionKind == 1 || actionKind == 5) {
            // mint / reward: one credit under a positivity check
            // and the C-3 ceiling.  amount @16 (32).
            return (
                StepWrites.deriveCreditBalance(
                    pre0, StepWrites.readFieldUint(fields, 16, 32)),
                pre1
            );
        }
        if (actionKind == 2 || actionKind == 14) {
            // burn / withdraw: one debit under a sufficiency check.
            // A debit needs no ceiling conjunct — subtraction only
            // shrinks.  amount @16 (32).
            return (
                StepWrites.deriveDebitBalance(
                    pre0, StepWrites.readFieldUint(fields, 16, 32)),
                pre1
            );
        }
        if (actionKind == 13) {
            // deposit: an unconditional credit apart from the C-3
            // ceiling — `Laws.deposit.pre` carries no positivity
            // clause, so a legitimate ZERO deposit must not no-op.
            // (It WAS literally `True` until the ceiling landed.)
            // amount @16 (32).
            return (
                StepWrites.deriveDepositBalance(
                    pre0, StepWrites.readFieldUint(fields, 16, 32)),
                pre1
            );
        }
        if (actionKind == 19) {
            // depositWithFee: recipient @8, poolActor @16,
            // userAmount @24 (32), poolAmount @56 (32).
            return StepWrites.deriveDepositWithFeeBalances(
                pre0, pre1,
                uint64(StepWrites.readFieldUint(fields, 8, 8)),
                uint64(StepWrites.readFieldUint(fields, 16, 8)),
                StepWrites.readFieldUint(fields, 24, 32),
                StepWrites.readFieldUint(fields, 56, 32)
            );
        }
        if (actionKind == 20) {
            // topUpActionBudget: gasAmount @8 (32), poolActor @48.
            // Sufficiency only — there is NO positivity conjunct, so a
            // zero top-up is an admissible no-op.
            uint256 gasAmount = StepWrites.readFieldUint(fields, 8, 32);
            return StepWrites.deriveTopUpBalances(
                pre0, pre1, signer,
                uint64(StepWrites.readFieldUint(fields, 48, 8)),
                gasAmount, gasAmount <= pre0
            );
        }
        if (actionKind == 21) {
            // topUpActionBudgetFor: recipient @0, gasAmount @16 (32),
            // poolActor @56.  The delegated form's precondition carries
            // `recipient != signer` — a self-delegation is a NO-OP
            // rather than a top-up, and a derivation blind to that
            // would move balances the advance leaves alone.
            uint256 gasAmount = StepWrites.readFieldUint(fields, 16, 32);
            return StepWrites.deriveTopUpBalances(
                pre0, pre1, signer,
                uint64(StepWrites.readFieldUint(fields, 56, 8)),
                gasAmount,
                gasAmount <= pre0
                    && uint64(StepWrites.readFieldUint(fields, 0, 8)) != signer
            );
        }
        if (actionKind == 22) {
            return _planRefundBalances(fields, signer, pre0, pre1);
        }
        if (actionKind == 23) {
            // ammSwap: fromResource @0, toResource @8, amountIn @16
            // (32), amountOut @48 (32).  The one variant touching two
            // DIFFERENT resources, so the cells are independent.
            return StepWrites.deriveAmmSwapBalances(
                pre0, pre1,
                uint64(StepWrites.readFieldUint(fields, 0, 8)),
                uint64(StepWrites.readFieldUint(fields, 8, 8)),
                StepWrites.readFieldUint(fields, 16, 32),
                StepWrites.readFieldUint(fields, 48, 32)
            );
        }
        if (actionKind == 24) {
            // reclaimAmmReserves: amount @8 (32), reserveActor @40,
            // poolActor @48.  The precondition is an EQUALITY, not a
            // sufficiency, so a partial reclaim is a no-op.
            return StepWrites.deriveReclaimBalances(
                pre0, pre1,
                uint64(StepWrites.readFieldUint(fields, 40, 8)),
                uint64(StepWrites.readFieldUint(fields, 48, 8)),
                StepWrites.readFieldUint(fields, 8, 32)
            );
        }
        // The variants that write no balance cell at all.
        return (pre0, pre1);
    }

    /// @notice The four-cell plan (Workstream SB): `reserveSwap` is
    ///         the first variant whose balance write set is a QUAD —
    ///         the user and the reserve each at both swap resources,
    ///         in the law's write order (user debit at `from`, reserve
    ///         credit at `from`, reserve debit at `to`, user credit at
    ///         `to`).
    ///
    /// @dev    Every other kind delegates to the two-slot
    ///         `planBalances` and passes cells 2 and 3 through at
    ///         their pre-values, so a caller can hold ONE plan shape
    ///         for every variant.
    function planBalances4(
        uint8 actionKind,
        bytes calldata fields,
        uint64 signer,
        uint256 pre0,
        uint256 pre1,
        uint256 pre2,
        uint256 pre3
    )
        internal
        pure
        returns (uint256 new0, uint256 new1, uint256 new2, uint256 new3)
    {
        if (actionKind == 25) {
            // reserveSwap: fromResource @0, toResource @8, user @16,
            // amountIn @24 (32), minAmountOut @56 (32),
            // reserveActor @88.  The quote is re-derived inside from
            // the two proven reserve pre-values (cells 1 and 2).
            (new0, new1, new2, new3) = StepWrites.deriveReserveSwapBalances(
                pre0, pre1, pre2, pre3,
                uint64(StepWrites.readFieldUint(fields, 0, 8)),
                uint64(StepWrites.readFieldUint(fields, 8, 8)),
                uint64(StepWrites.readFieldUint(fields, 16, 8)),
                uint64(StepWrites.readFieldUint(fields, 88, 8)),
                StepWrites.readFieldUint(fields, 24, 32),
                StepWrites.readFieldUint(fields, 56, 32)
            );
            return (new0, new1, new2, new3);
        }
        (new0, new1) = planBalances(actionKind, fields, signer, pre0, pre1);
        return (new0, new1, pre2, pre3);
    }

    /// @dev `claimBudgetRefund`, split out because its two cells are
    ///      the write set's in the OPPOSITE order to the chain's.
    ///
    ///      The write set is `[.balance gr signer, .balance gr pa, …]`
    ///      — the claimant first — while the law debits the POOL and
    ///      then credits the claimant from the debited state.  Feeding
    ///      the pair to the chain in write-set order would compute the
    ///      mirror of the law.  The fold order is unaffected: each
    ///      write lands its cell's FINAL value, so only same-cell
    ///      writes are order-sensitive and those write the same value
    ///      twice.
    ///
    ///      **The product can exceed a `uint256`, and must not
    ///      revert.**  `budgetUnits` is bounded below `2^64` and
    ///      `weiPerBudgetUnit` now rides the 32-byte amount field, so
    ///      the payout can reach ~`2^320`.  Lean computes it as a
    ///      `Nat`, which does not overflow; checked `uint256`
    ///      arithmetic here would REVERT, and a revert is not a no-op
    ///      — the two stacks would disagree on a step an honest
    ///      sequencer can be handed.
    ///
    ///      An overflowing product is instead treated as a failed
    ///      precondition, which is exactly what it is: the payout
    ///      exceeds `2^256`, no pool balance can cover it (every
    ///      balance is under `Laws.maxAmount = 2^256` by
    ///      `FaultProof.canonicalBounds_base_amt_of_reachable`), so
    ///      `getBalance pool >= refundAmount` is false on the Lean
    ///      side too and the law no-ops on both.
    ///
    ///      Before the widening `weiPerBudgetUnit` was capped below
    ///      `2^128`, so the product topped out at ~`2^192` and fitted;
    ///      the overflow path is new with the wider field.
    function _planRefundBalances(
        bytes calldata fields,
        uint64 signer,
        uint256 claimantPre,
        uint256 poolPre
    ) private pure returns (uint256 newClaimant, uint256 newPool) {
        uint256 units = StepWrites.readFieldUint(fields, 8, 8);
        uint256 rate = StepWrites.readFieldUint(fields, 16, 32);
        uint256 refundAmount;
        bool fits;
        unchecked {
            refundAmount = units * rate;
            // `units == 0` makes the product zero and the division
            // guard undefined, so it is admitted directly.
            fits = units == 0 || refundAmount / units == rate;
        }
        (newPool, newClaimant) = StepWrites.deriveTopUpBalances(
            poolPre, claimantPre,
            uint64(StepWrites.readFieldUint(fields, 48, 8)), signer,
            refundAmount, fits && refundAmount <= poolPre
        );
    }
}

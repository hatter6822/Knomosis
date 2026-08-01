// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {CBEEncode} from "./CBEEncode.sol";

/// @title StepWrites
/// @notice The L1 mirror of `LegalKernel.FaultProof.VerifierWrites` —
///         each written cell's new value DERIVED from the proven
///         pre-values, in canonical CBE bytes.
///
/// @dev    **Why derived and not supplied.**  Once `executeStep`
///         returns a state root, it folds a list of writes into the
///         pre-root.  A fold over writes the RESPONDER supplies is not
///         adjudication — a party free to choose the `newValue` column
///         folds to a root of their choosing and wins every game.  The
///         fold is sound only over a write list the verifier derived
///         itself, which is what these functions are.
///
///         **Scope: the two cells every action writes.**  The nonce
///         and the epoch budget are declared by `Action.writeCells` on
///         all twenty-five variants, and `stepVMHash` reads and emits
///         BALANCE cells only — so these are exactly the cells the
///         current step VM is silent about, and the ones its output
///         would be wrong about for every action the moment it is
///         compared against a state root.  The per-variant balance
///         derivations follow.
///
///         Lean mirrors, each with a `*_correct` theorem against
///         `getCellValue (productionApplyBudget es st idx)`:
///         `deriveNonceCellValue`, `deriveEpochBudget` /
///         `deriveEpochBudgetCellValue`,
///         `productionApplyBudget_epochBudgets_eq`.
library StepWrites {
    /// @notice An actor's budget, as the epoch-budget cell carries it.
    /// @dev    Both components in ONE cell, so a proof cannot open the
    ///         balance without also fixing the epoch it belongs to —
    ///         reading them apart would let a stale-epoch balance be
    ///         presented as current.
    struct ActorBudget {
        uint256 lastSeenEpoch;
        uint256 budgetBalance;
    }

    /// @notice The deployment's budget policy, as its cell carries it.
    struct BudgetPolicy {
        uint256 freeTier;
        uint256 actionCost;
        uint256 currentEpoch;
    }

    /// @notice A cell value did not decode as the shape its kind
    ///         requires.
    /// @dev    Fail-closed, and deliberately not a default: a nonce
    ///         defaulting to zero is a replay, and a budget defaulting
    ///         to a fresh free tier is minting.
    error MalformedCellValue();

    /// @notice The bridge actor, exempt from the budget consume.
    ///         Mirrors `LegalKernel.Bridge.bridgeActor`.
    uint64 internal constant BRIDGE_ACTOR = 0;

    /// @notice CBE uint head width: tag + 8 little-endian bytes.
    uint256 internal constant CBE_UINT_LEN = 9;

    /* ---------------------------------------------------------- */
    /* Decoding                                                   */
    /* ---------------------------------------------------------- */

    /// @dev Read one CBE uint at `offset`.  Reverts on a wrong tag or
    ///      a short buffer rather than reading past the end.
    function _readUint(bytes memory data, uint256 offset)
        private
        pure
        returns (uint256 v)
    {
        if (data.length < offset + CBE_UINT_LEN) revert MalformedCellValue();
        if (uint8(data[offset]) != CBEEncode.CBE_TAG_UINT) revert MalformedCellValue();
        // Little-endian, matching `CBEEncode` and `CBEDecode.readUint64LE`.
        for (uint256 i = 0; i < 8; i++) {
            v |= uint256(uint8(data[offset + 1 + i])) << (8 * i);
        }
    }

    /// @notice Decode a nonce cell.
    /// @dev    The residual must be EMPTY: a cell holds exactly one
    ///         encoded value, so trailing bytes mean the responder
    ///         appended something, and accepting them would let two
    ///         distinct bundles derive the same write.
    function decodeNonce(bytes memory value) internal pure returns (uint256) {
        if (value.length != CBE_UINT_LEN) revert MalformedCellValue();
        return _readUint(value, 0);
    }

    /// @notice Decode an epoch-budget cell: two uints in sequence.
    function decodeActorBudget(bytes memory value)
        internal
        pure
        returns (ActorBudget memory)
    {
        if (value.length != 2 * CBE_UINT_LEN) revert MalformedCellValue();
        return ActorBudget({
            lastSeenEpoch: _readUint(value, 0),
            budgetBalance: _readUint(value, CBE_UINT_LEN)
        });
    }

    /// @notice Decode a budget-policy cell.
    /// @dev    Four uints: a constructor tag (always `0`, since
    ///         `BudgetPolicy` has one constructor) then the three
    ///         fields.  The tag is CHECKED rather than skipped — an
    ///         unknown one means a policy this verifier does not model,
    ///         and guessing at it would adjudicate under the wrong
    ///         rules.
    function decodeBudgetPolicy(bytes memory value)
        internal
        pure
        returns (BudgetPolicy memory)
    {
        if (value.length != 4 * CBE_UINT_LEN) revert MalformedCellValue();
        if (_readUint(value, 0) != 0) revert MalformedCellValue();
        return BudgetPolicy({
            freeTier: _readUint(value, CBE_UINT_LEN),
            actionCost: _readUint(value, 2 * CBE_UINT_LEN),
            currentEpoch: _readUint(value, 3 * CBE_UINT_LEN)
        });
    }

    /* ---------------------------------------------------------- */
    /* The nonce cell                                             */
    /* ---------------------------------------------------------- */

    /// @notice The nonce cell's post-value: `pre + 1`, on every action.
    ///
    /// @dev    Uniform across all twenty-five variants because
    ///         `kernelOnlyApply` advances the signer's nonce BEFORE it
    ///         dispatches on the action at all.  Mirrors
    ///         `VerifierWrites.deriveNonceCellValue`.
    ///
    /// @param  preValue the proven pre-state nonce cell.
    /// @return the canonical post-state cell bytes.
    function deriveNonce(bytes memory preValue)
        internal
        pure
        returns (bytes memory)
    {
        return CBEEncode.uintValue(decodeNonce(preValue) + 1);
    }

    /* ---------------------------------------------------------- */
    /* The epoch-budget cell                                      */
    /* ---------------------------------------------------------- */

    /// @dev `ActorBudget.normalise`: crossing into a later epoch
    ///      refreshes the balance to at least the free tier.
    function _normalise(ActorBudget memory b, uint256 now_, uint256 freeTier)
        private
        pure
        returns (ActorBudget memory)
    {
        if (b.lastSeenEpoch < now_) {
            return ActorBudget({
                lastSeenEpoch: now_,
                budgetBalance: b.budgetBalance > freeTier ? b.budgetBalance : freeTier
            });
        }
        return b;
    }

    /// @dev `ActorBudget.topUp`: normalise, then credit.
    function _topUp(
        ActorBudget memory b,
        uint256 now_,
        uint256 freeTier,
        uint256 amount
    ) private pure returns (ActorBudget memory) {
        ActorBudget memory bn = _normalise(b, now_, freeTier);
        return ActorBudget({
            lastSeenEpoch: bn.lastSeenEpoch,
            budgetBalance: bn.budgetBalance + amount
        });
    }

    /// @dev `ActorBudget.consume`: normalise, then debit if affordable.
    ///      `ok = false` means the consume was REFUSED, which freezes
    ///      every actor's budget for this step — not just the signer's.
    function _consume(
        ActorBudget memory b,
        uint256 now_,
        uint256 freeTier,
        uint256 cost
    ) private pure returns (bool ok, ActorBudget memory out) {
        ActorBudget memory bn = _normalise(b, now_, freeTier);
        if (cost <= bn.budgetBalance) {
            return (true, ActorBudget({
                lastSeenEpoch: bn.lastSeenEpoch,
                budgetBalance: bn.budgetBalance - cost
            }));
        }
        return (false, b);
    }

    /// @notice The extra consume a refund claim carries.
    ///         Mirrors `Authority.refundConsumeExtra`.
    /// @dev    `claimBudgetRefund` burns the budget units it is
    ///         cashing out, on top of the action cost, which is what
    ///         stops a refund from being a free round trip.
    /// @param  actionKind the frozen dispatcher index.
    /// @param  budgetUnits the claim's unit count (0 for other kinds).
    function refundConsumeExtra(uint8 actionKind, uint256 budgetUnits)
        internal
        pure
        returns (uint256)
    {
        // 22 = claimBudgetRefund.
        return actionKind == 22 ? budgetUnits : 0;
    }

    /// @notice The grant's effect on ONE actor's budget.
    ///         Mirrors `VerifierWrites.applyGrantAt`.
    ///
    /// @dev    The recipient differs per variant — `depositWithFee`
    ///         grants to the deposit's recipient, `topUpActionBudget`
    ///         to the SIGNER, `topUpActionBudgetFor` to the named
    ///         recipient — which is why this cannot collapse into "top
    ///         up the signer".
    ///
    /// @param  grantRecipient the actor the action grants to; ignored
    ///         when `grantAmount` is zero.
    /// @param  grantAmount    the granted units, or zero for the
    ///         twenty-two variants that grant nothing.
    function applyGrantAt(
        uint64 target,
        uint64 grantRecipient,
        uint256 grantAmount,
        uint256 freeTier,
        uint256 currentEpoch,
        ActorBudget memory pre
    ) internal pure returns (ActorBudget memory) {
        if (grantAmount == 0 || target != grantRecipient) return pre;
        return _topUp(pre, currentEpoch, freeTier, grantAmount);
    }

    /// @notice **One actor's epoch budget after the advance, derived
    ///         from proven cells alone.**
    ///
    /// @dev    Mirrors `VerifierWrites.deriveEpochBudget`.  Three
    ///         branches, each a real case rather than bookkeeping:
    ///
    ///           * the bridge actor is exempt from the consume, so a
    ///             bridge-credited deposit cannot be starved by a
    ///             budget it never had;
    ///           * a REFUSED consume leaves the budgets entirely alone
    ///             — grant included — so a step the actor could not
    ///             afford grants nothing;
    ///           * otherwise the grant lands on the CONSUMED state, in
    ///             that order.  A grant applied to the pre-consume
    ///             budget would let a top-up pay for itself.
    ///
    ///         Takes THREE cells, and each is load-bearing: the policy
    ///         selects the branch, the SIGNER's budget decides whether
    ///         the consume succeeds (which gates the write to EVERY
    ///         actor), and the target's own supplies the value.  A
    ///         derivation reading only the target's cell would credit a
    ///         grant recipient on a step the signer could not afford.
    function deriveEpochBudget(
        BudgetPolicy memory policy,
        ActorBudget memory signerPre,
        ActorBudget memory targetPre,
        uint64 signer,
        uint64 target,
        uint64 grantRecipient,
        uint256 grantAmount,
        uint256 refundExtra
    ) internal pure returns (ActorBudget memory) {
        if (signer == BRIDGE_ACTOR) {
            return applyGrantAt(
                target, grantRecipient, grantAmount,
                policy.freeTier, policy.currentEpoch, targetPre
            );
        }
        (bool ok, ActorBudget memory consumed) = _consume(
            signerPre, policy.currentEpoch, policy.freeTier,
            policy.actionCost + refundExtra
        );
        if (!ok) return targetPre;
        ActorBudget memory afterConsume = target == signer ? consumed : targetPre;
        return applyGrantAt(
            target, grantRecipient, grantAmount,
            policy.freeTier, policy.currentEpoch, afterConsume
        );
    }

    /// @notice The epoch-budget cell's post-value, in canonical bytes.
    /// @dev    The byte-level counterpart, mirroring
    ///         `VerifierWrites.deriveEpochBudgetCellValue`.
    function deriveEpochBudgetCellValue(
        bytes memory policyValue,
        bytes memory signerValue,
        bytes memory targetValue,
        uint64 signer,
        uint64 target,
        uint64 grantRecipient,
        uint256 grantAmount,
        uint256 refundExtra
    ) internal pure returns (bytes memory) {
        ActorBudget memory out = deriveEpochBudget(
            decodeBudgetPolicy(policyValue),
            decodeActorBudget(signerValue),
            decodeActorBudget(targetValue),
            signer, target, grantRecipient, grantAmount, refundExtra
        );
        return CBEEncode.epochBudgetValue(out.lastSeenEpoch, out.budgetBalance);
    }
}

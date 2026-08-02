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

    /// @notice CBE amount head width: tag + 16 little-endian bytes.
    uint256 internal constant CBE_AMOUNT_LEN = 17;

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

    /// @dev Read one CBE amount at `offset`.  The 17-byte sibling of
    ///      `_readUint`, and a SEPARATE tag: a balance and a counter
    ///      holding the same number are different cell values, which is
    ///      what stops a proof opening one from being replayed as the
    ///      other.
    function _readAmount(bytes memory data, uint256 offset)
        private
        pure
        returns (uint256 v)
    {
        if (data.length < offset + CBE_AMOUNT_LEN) revert MalformedCellValue();
        if (uint8(data[offset]) != CBEEncode.CBE_TAG_AMOUNT) revert MalformedCellValue();
        for (uint256 i = 0; i < 16; i++) {
            v |= uint256(uint8(data[offset + 1 + i])) << (8 * i);
        }
    }

    /// @notice Decode a balance cell.
    ///
    /// @dev    The canonically-ABSENT balance decodes here too — it is
    ///         the amount head over zero, not an empty buffer — so a
    ///         step crediting a fresh actor reads its pre-value through
    ///         this function like any other.  That is why absence is a
    ///         VALUE rather than a missing cell: the alternative would
    ///         need a second read path exercised on the first line of
    ///         the first handler.
    function decodeAmount(bytes memory value) internal pure returns (uint256) {
        if (value.length != CBE_AMOUNT_LEN) revert MalformedCellValue();
        return _readAmount(value, 0);
    }

    /// @notice Read a big-endian unsigned integer of `width` bytes from
    ///         the action fields.
    ///
    /// @dev    The action-field reader, BIG-endian — the CBE heads are
    ///         little-endian and both orders live in this library, so
    ///         the two are named apart rather than sharing one.  Widths
    ///         are 8 for identifiers and 16 for amounts, per
    ///         `actionFieldsForL1`; a caller passing the wrong one
    ///         still decodes to a plausible number, which is why the
    ///         offsets are pinned by `writeSetGoldens` over the ACTUAL
    ///         field bytes rather than reasoned about.
    function readFieldUint(bytes calldata fields, uint256 offset, uint256 width)
        internal
        pure
        returns (uint256 v)
    {
        if (fields.length < offset + width) {
            revert ActionFieldsTooShort(0, fields.length);
        }
        for (uint256 i = 0; i < width; i++) {
            v = (v << 8) | uint256(uint8(fields[offset + i]));
        }
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

    /* ---------------------------------------------------------- */
    /* Balance cells                                              */
    /* ---------------------------------------------------------- */

    /// @dev Two things every balance derivation below does that the
    ///      current `_step<Variant>` handlers do not.
    ///
    ///      **The precondition is EVALUATED, not asserted.**
    ///      `step_impl` is `if pre then apply_impl else id`, so an
    ///      action whose precondition fails advances no balance and its
    ///      cells keep their pre-values.  The handlers REVERT
    ///      (`InsufficientBalance`), and a revert is not a verdict: the
    ///      terminal step is callable only by whoever's turn it is, so
    ///      any reverting input costs the responsible party the game by
    ///      timeout — and the turn can land on the challenger.
    ///
    ///      **The chained pair reads the already-written state.**  Five
    ///      variants write `x` then write `y` reading the DEBITED
    ///      state; when `x == y` the second read sees the first write,
    ///      and that case is reachable in every one of them (a
    ///      self-transfer, a signer who is the pool actor).

    /// @notice `transfer`: debit the sender, credit the receiver.
    /// @dev    Mirrors `VerifierWrites.deriveTransferBalances`.  The
    ///         self-transfer branch is §4.11's read-after-debit: the
    ///         law debits then reads the receiver from the debited
    ///         state, so when the two coincide the net change is zero.
    ///         Debiting and crediting independently would move the root
    ///         on a self-transfer, which any actor can submit cheaply.
    function deriveTransferBalances(
        uint256 senderBal,
        uint256 receiverBal,
        uint64 sender,
        uint64 receiver,
        uint256 amount
    ) internal pure returns (uint256 newSender, uint256 newReceiver) {
        if (amount > 0 && amount <= senderBal) {
            if (sender == receiver) return (senderBal, senderBal);
            return (senderBal - amount, receiverBal + amount);
        }
        return (senderBal, receiverBal);
    }

    /// @notice `mint` / `reward`: credit under a positivity check.
    /// @dev    One function for both because the two laws have the
    ///         same cell effect; they differ in conservation
    ///         classification, which is not an L1 concern.
    function deriveCreditBalance(uint256 bal, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        return amount > 0 ? bal + amount : bal;
    }

    /// @notice `burn` / `withdraw`: debit under a sufficiency check.
    function deriveDebitBalance(uint256 bal, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        return (amount > 0 && amount <= bal) ? bal - amount : bal;
    }

    /// @notice `deposit`: an UNCONDITIONAL credit.
    /// @dev    `Laws.deposit.pre` is `True` — a bridge deposit's
    ///         admissibility is settled by the bridge gate (the
    ///         consumed-deposit cell, the attested receipt), not by the
    ///         kernel transition.  Separate from `deriveCreditBalance`
    ///         for exactly that reason: reusing the positivity-guarded
    ///         one would silently no-op a legitimate zero deposit.
    function deriveDepositBalance(uint256 bal, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        return bal + amount;
    }

    /// @notice The chained same-resource pair: write `x`, then write
    ///         `y` reading the already-written state.
    ///
    /// @dev    Mirrors `VerifierWrites.deriveChainPair`.  `debit` is
    ///         taken from `x` and `credit` given to `y`; when the two
    ///         actors coincide the credit sees the debited value, so
    ///         the pair nets out rather than double-counting.  Used by
    ///         `topUpActionBudget`, `topUpActionBudgetFor`,
    ///         `claimBudgetRefund` (the mirror) and — with `debit = 0`
    ///         — `depositWithFee`.
    function deriveChainPair(
        uint256 xBal,
        uint256 yBal,
        uint64 x,
        uint64 y,
        uint256 debit,
        uint256 credit
    ) internal pure returns (uint256 newX, uint256 newY) {
        uint256 nx = xBal - debit;
        uint256 ny = (x == y ? nx : yBal) + credit;
        return (x == y ? ny : nx, ny);
    }

    /// @notice `topUpActionBudget` / `topUpActionBudgetFor`: the payer
    ///         is debited, the pool credited.
    /// @dev    `sufficient` carries the whole precondition, which for
    ///         the delegated form includes `recipient != payer` — a
    ///         self-delegation is a no-op rather than a top-up, and a
    ///         derivation blind to that would move balances the advance
    ///         leaves alone.  There is NO positivity conjunct, so a
    ///         zero top-up is an admissible no-op.
    function deriveTopUpBalances(
        uint256 payerBal,
        uint256 poolBal,
        uint64 payer,
        uint64 poolActor,
        uint256 gasAmount,
        bool sufficient
    ) internal pure returns (uint256 newPayer, uint256 newPool) {
        if (!sufficient) return (payerBal, poolBal);
        return deriveChainPair(payerBal, poolBal, payer, poolActor, gasAmount, gasAmount);
    }

    /// @notice `depositWithFee`: credit the recipient, then the pool.
    /// @dev    Mirrors `VerifierWrites.deriveDepositWithFeeBalances`.
    ///         The chained pair with TWO credits rather than a
    ///         debit/credit, so it cannot route through
    ///         `deriveChainPair` (whose `x` leg subtracts).
    ///         `Laws.depositWithFee.pre` is `True`, like `deposit`'s —
    ///         a bridge deposit's admissibility is settled by the
    ///         bridge gate — so there is no branch, and the `x == y`
    ///         case (a recipient who IS the pool actor) still has to
    ///         net both credits onto one cell.
    function deriveDepositWithFeeBalances(
        uint256 recipientBal,
        uint256 poolBal,
        uint64 recipient,
        uint64 poolActor,
        uint256 userAmount,
        uint256 poolAmount
    ) internal pure returns (uint256 newRecipient, uint256 newPool) {
        uint256 nx = recipientBal + userAmount;
        uint256 ny = (recipient == poolActor ? nx : poolBal) + poolAmount;
        return (recipient == poolActor ? ny : nx, ny);
    }

    /// @notice `ammSwap`: credit the reserve at `fromResource`, debit
    ///         it at `toResource`.
    /// @dev    The one variant touching two DIFFERENT resources, so the
    ///         cells are independent and `deriveChainPair` does not
    ///         apply.  That is sound only because
    ///         `fromResource != toResource` is a precondition conjunct
    ///         rather than an assumption — it is checked here.
    function deriveAmmSwapBalances(
        uint256 fromBal,
        uint256 toBal,
        uint64 fromResource,
        uint64 toResource,
        uint256 amountIn,
        uint256 amountOut
    ) internal pure returns (uint256 newFrom, uint256 newTo) {
        if (toBal >= amountOut && fromResource != toResource && amountIn > 0) {
            return (fromBal + amountIn, toBal - amountOut);
        }
        return (fromBal, toBal);
    }

    /// @notice `reclaimAmmReserves`: the post-disable exact sweep.
    /// @dev    The precondition is an EQUALITY (`balance == amount`),
    ///         not a sufficiency, so a partial reclaim is a no-op.
    function deriveReclaimBalances(
        uint256 reserveBal,
        uint256 poolBal,
        uint64 reserveActor,
        uint64 poolActor,
        uint256 amount
    ) internal pure returns (uint256 newReserve, uint256 newPool) {
        if (reserveBal == amount && reserveActor != poolActor && amount > 0) {
            return deriveChainPair(
                reserveBal, poolBal, reserveActor, poolActor, amount, amount);
        }
        return (reserveBal, poolBal);
    }

    /* ---------------------------------------------------------- */
    /* Registry, local-policy and bridge cells                    */
    /* ---------------------------------------------------------- */

    /// @dev These are the cheap ones, and the reason is structural:
    ///      their post-values come from the ACTION's own fields, so a
    ///      verifier reads them off the calldata and needs no proven
    ///      cell.  That also makes them the cells an L1 ignoring its
    ///      declared writes is most obviously wrong about.

    /// @notice `replaceKey` / `registerIdentity`'s registry write.
    /// @dev    Routed through the CBE byte-string encoder, NOT emitted
    ///         raw.  `PublicKey` is a bare byte array and
    ///         `registerIdentity` accepts any value, so a registration
    ///         with the EMPTY key would otherwise read exactly like an
    ///         absent one — and registration is an admissibility gate,
    ///         so those are different states.  The 9-byte head is
    ///         present even for a zero-length payload.
    function deriveRegistryCellValue(bytes memory key)
        internal
        pure
        returns (bytes memory)
    {
        return CBEEncode.bytesValue(key);
    }

    /// @notice `declareLocalPolicy`'s local-policy write: the action
    ///         fields, VERBATIM.
    ///
    /// @dev    `actionFieldsForL1 (.declareLocalPolicy policy)` and the
    ///         cell value are both
    ///         `Encodable.encode (T := LocalPolicy) policy`, so an L1
    ///         holding the calldata already holds the cell value.  That
    ///         removes the single largest encoder the step VM would
    ///         otherwise carry — a policy is an ARRAY of clauses, not a
    ///         fixed-width record.
    ///
    ///         Pinned in Lean by
    ///         `deriveDeclaredPolicyCellValue_eq_actionFields`, so a
    ///         future change to either the field layout or the cell
    ///         encoding fails to compile rather than silently breaking
    ///         this shortcut.
    function deriveDeclaredPolicyCellValue(bytes calldata actionFields)
        internal
        pure
        returns (bytes memory)
    {
        return actionFields;
    }

    /// @notice `replaceKey` / `registerIdentity`'s registry write, from
    ///         the action fields.
    ///
    /// @dev    The key is the fields' TAIL, after the 8-byte actor id
    ///         (`registry_key_is_action_fields_tail`), so this is
    ///         `CBEEncode.bytesValue` over a calldata slice — no key
    ///         encoder either.
    function deriveRegistryFromFields(bytes calldata actionFields)
        internal
        pure
        returns (bytes memory)
    {
        if (actionFields.length < 8) {
            revert ActionFieldsTooShort(0, actionFields.length);
        }
        return CBEEncode.bytesValue(actionFields[8:]);
    }

    /// @notice `revokeLocalPolicy`'s local-policy write: the canonical
    ///         ABSENT value.
    /// @dev    `revoke` ERASES the map entry rather than storing an
    ///         empty policy, and the cell value keys off the map — so
    ///         "declared a policy with no clauses" and "declared
    ///         nothing" are different cell values.  Emitting an encoded
    ///         empty policy here would move the root to a state the
    ///         advance never reaches.
    function deriveRevokedPolicyCellValue()
        internal
        pure
        returns (bytes memory)
    {
        return "";
    }

    /// @notice `deposit` / `depositWithFee`'s consumed-deposit write.
    /// @dev    Mirrors `Encoding.Bridge.DepositRecord.encode`:
    ///         `uint resource || amount userAmount || amount poolAmount
    ///         || uint budgetGrant`.  `deposit` is the degenerate case
    ///         with `poolAmount = budgetGrant = 0`.
    function deriveConsumedCellValue(
        uint256 resource,
        uint256 userAmount,
        uint256 poolAmount,
        uint256 budgetGrant
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            CBEEncode.uintValue(resource),
            CBEEncode.amountValue(userAmount),
            CBEEncode.amountValue(poolAmount),
            CBEEncode.uintValue(budgetGrant)
        );
    }

    /// @notice `withdraw`'s pending-withdrawal write.
    /// @dev    Mirrors `Encoding.Bridge.PendingWithdrawal.encode`:
    ///         `uint resource || bytes recipient || amount amount ||
    ///         uint l2LogIndex`.  The recipient rides the byte-string
    ///         encoder, not a raw 20-byte splat.
    function derivePendingCellValue(
        uint256 resource,
        bytes memory recipientL1,
        uint256 amount,
        uint256 l2LogIndex
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            CBEEncode.uintValue(resource),
            CBEEncode.bytesValue(recipientL1),
            CBEEncode.amountValue(amount),
            CBEEncode.uintValue(l2LogIndex)
        );
    }

    /// @notice `withdraw`'s counter write: `pre + 1`.
    /// @dev    The nonce's shape, and for the same class of reason — a
    ///         reset counter would let a later withdrawal overwrite an
    ///         earlier one's pending cell.  The pending cell is keyed
    ///         by this counter's PRE-value, which is the one place a
    ///         verifier reads a cell to learn WHICH cell to write.
    function deriveNextWdIdCellValue(bytes memory preValue)
        internal
        pure
        returns (bytes memory)
    {
        return CBEEncode.uintValue(decodeNonce(preValue) + 1);
    }

    /* ---------------------------------------------------------- */
    /* The write SET                                              */
    /* ---------------------------------------------------------- */

    /// @notice One declared cell write.
    struct Cell {
        uint8 kind;
        uint256 keyA;
        uint256 keyB;
    }

    /// @notice The action's write set is not derivable from the
    ///         pre-root.
    /// @dev    True only for the two bulk variants, whose set is the
    ///         actor set at a resource; `smtCellKey` hashes the cell
    ///         identity, so balance cells at one resource share no key
    ///         prefix and no subtree argument enumerates them.  A
    ///         deployment leaning on the fault proof must not authorise
    ///         them — mirrors `FaultProof.FaultProofAdjudicable`.
    error ActionNotAdjudicable(uint8 actionKind);

    /// @notice Whether the fault proof can adjudicate a step of this
    ///         kind.  Mirrors `FaultProof.FaultProofAdjudicable`.
    ///
    /// @dev    A DECIDABLE predicate rather than a property implicit in
    ///         `deriveWriteSet`'s arms, so a caller can refuse before
    ///         doing any work and a deployment can express the
    ///         restriction in its `AuthorityPolicy`.
    ///
    ///         False on exactly the two bulk variants — whose write set
    ///         is the actor set at a resource, which an L1 holding only
    ///         the pre-root cannot enumerate — and on unknown kinds.
    function isAdjudicable(uint8 actionKind) internal pure returns (bool) {
        return actionKind <= 24 && actionKind != 6 && actionKind != 7;
    }

    /// @notice The action fields are shorter than the variant's layout.
    error ActionFieldsTooShort(uint8 actionKind, uint256 length);

    /// @dev Read a big-endian `uint64` from the action fields.
    ///      Big-endian here, LITTLE-endian in the CBE heads — both
    ///      orders live in this library, so the two readers are named
    ///      apart rather than sharing one.
    function _fieldUint64(bytes calldata fields, uint256 offset)
        private
        pure
        returns (uint64 v)
    {
        for (uint256 i = 0; i < 8; i++) {
            v = (v << 8) | uint64(uint8(fields[offset + i]));
        }
    }

    /// @dev The nonce + epoch-budget pair every action writes, appended
    ///      after the variant's own cells.  `CellKind.Nonce = 1`,
    ///      `CellKind.EpochBudget = 13`.
    function _appendUniform(Cell[] memory out, uint256 at, uint64 signer)
        private
        pure
    {
        out[at] = Cell({kind: 1, keyA: signer, keyB: 0});
        out[at + 1] = Cell({kind: 13, keyA: signer, keyB: 0});
    }

    /// @notice **The cells an action writes**, mirroring
    ///         `Authority.Action.writeCellsAt`.
    ///
    /// @dev    A verifier re-derives this list and rejects a bundle
    ///         naming different cells.  Without it a responder could
    ///         omit a write and fold to a root where that cell never
    ///         moved — which the corpus's `writeSetGoldens` column pins
    ///         per variant, with the ACTUAL field bytes, so a
    ///         field-offset slip fails there rather than being reasoned
    ///         about.  Offsets are where a mirror goes silently wrong:
    ///         the layouts are big-endian with mixed widths
    ///         (`uint64BE` identifiers, `uint128BE` amounts), so a
    ///         one-field slip still decodes to a plausible actor id.
    ///
    /// @param  nextWdIdPre the proven `.bridgeNextWdId` pre-value; the
    ///         ONLY variant that uses it is `withdraw`, whose pending
    ///         cell it keys — the one place a verifier reads a cell to
    ///         learn WHICH cell to write.
    function deriveWriteSet(
        uint8 actionKind,
        bytes calldata fields,
        uint64 signer,
        uint256 nextWdIdPre
    ) internal pure returns (Cell[] memory out) {
        // Balance cells are kind 0; registry 2; localPolicy 3;
        // bridgeConsumed 4; bridgePending 5; bridgeNextWdId 6.
        if (actionKind == 0) {                          // transfer
            _need(actionKind, fields, 40);
            out = new Cell[](4);
            uint64 r = _fieldUint64(fields, 0);
            out[0] = Cell({kind: 0, keyA: r, keyB: _fieldUint64(fields, 8)});
            out[1] = Cell({kind: 0, keyA: r, keyB: _fieldUint64(fields, 16)});
            _appendUniform(out, 2, signer);
        } else if (actionKind == 1 || actionKind == 2 || actionKind == 5) {
            // mint / burn / reward: `r || actor || amount`.
            _need(actionKind, fields, 32);
            out = new Cell[](3);
            out[0] = Cell({
                kind: 0, keyA: _fieldUint64(fields, 0), keyB: _fieldUint64(fields, 8)});
            _appendUniform(out, 1, signer);
        } else if (actionKind == 4 || actionKind == 12) {
            // replaceKey / registerIdentity: `actor || key-bytes`.
            _need(actionKind, fields, 8);
            out = new Cell[](3);
            out[0] = Cell({kind: 2, keyA: _fieldUint64(fields, 0), keyB: 0});
            _appendUniform(out, 1, signer);
        } else if (actionKind == 15 || actionKind == 16) {
            // declareLocalPolicy / revokeLocalPolicy: the SIGNER's cell.
            out = new Cell[](3);
            out[0] = Cell({kind: 3, keyA: signer, keyB: 0});
            _appendUniform(out, 1, signer);
        } else if (actionKind == 13) {                  // deposit
            _need(actionKind, fields, 40);
            out = new Cell[](4);
            out[0] = Cell({
                kind: 0, keyA: _fieldUint64(fields, 0), keyB: _fieldUint64(fields, 8)});
            _appendUniform(out, 1, signer);
            out[3] = Cell({kind: 4, keyA: _fieldUint64(fields, 32), keyB: 0});
        } else if (actionKind == 14) {                  // withdraw
            _need(actionKind, fields, 32);
            out = new Cell[](5);
            out[0] = Cell({
                kind: 0, keyA: _fieldUint64(fields, 0), keyB: _fieldUint64(fields, 8)});
            _appendUniform(out, 1, signer);
            out[3] = Cell({kind: 6, keyA: 0, keyB: 0});
            // The state-keyed cell: `Action.writeCells` cannot name it,
            // which is why `Action.stateWriteCells` exists.
            out[4] = Cell({kind: 5, keyA: nextWdIdPre, keyB: 0});
        } else if (actionKind == 19) {                  // depositWithFee
            _need(actionKind, fields, 72);
            out = new Cell[](6);
            uint64 r = _fieldUint64(fields, 0);
            uint64 recipient = _fieldUint64(fields, 8);
            out[0] = Cell({kind: 0, keyA: r, keyB: recipient});
            out[1] = Cell({kind: 0, keyA: r, keyB: _fieldUint64(fields, 16)});
            out[2] = Cell({kind: 4, keyA: _fieldUint64(fields, 64), keyB: 0});
            _appendUniform(out, 3, signer);
            out[5] = Cell({kind: 13, keyA: recipient, keyB: 0});
        } else if (actionKind == 20 || actionKind == 22) {
            // topUpActionBudget / claimBudgetRefund: `gr || _ || _ || pa`.
            _need(actionKind, fields, 40);
            out = new Cell[](4);
            uint64 gr = _fieldUint64(fields, 0);
            out[0] = Cell({kind: 0, keyA: gr, keyB: signer});
            out[1] = Cell({kind: 0, keyA: gr, keyB: _fieldUint64(fields, 32)});
            _appendUniform(out, 2, signer);
        } else if (actionKind == 21) {                  // topUpActionBudgetFor
            _need(actionKind, fields, 48);
            out = new Cell[](5);
            uint64 gr = _fieldUint64(fields, 8);
            out[0] = Cell({kind: 0, keyA: gr, keyB: signer});
            out[1] = Cell({kind: 0, keyA: gr, keyB: _fieldUint64(fields, 40)});
            _appendUniform(out, 2, signer);
            out[4] = Cell({kind: 13, keyA: _fieldUint64(fields, 0), keyB: 0});
        } else if (actionKind == 23) {                  // ammSwap
            _need(actionKind, fields, 56);
            out = new Cell[](4);
            uint64 reserveActor = _fieldUint64(fields, 48);
            out[0] = Cell({kind: 0, keyA: _fieldUint64(fields, 0), keyB: reserveActor});
            out[1] = Cell({kind: 0, keyA: _fieldUint64(fields, 8), keyB: reserveActor});
            _appendUniform(out, 2, signer);
        } else if (actionKind == 24) {                  // reclaimAmmReserves
            _need(actionKind, fields, 40);
            out = new Cell[](4);
            uint64 r = _fieldUint64(fields, 0);
            out[0] = Cell({kind: 0, keyA: r, keyB: _fieldUint64(fields, 24)});
            out[1] = Cell({kind: 0, keyA: r, keyB: _fieldUint64(fields, 32)});
            _appendUniform(out, 2, signer);
        } else {
            // The kernel-identity family (3, 8, 9, 10, 11, 17, 18):
            // nothing but the uniform pair.  Enumerated by exclusion
            // rather than listed, since every one has the same set.
            //
            // The bulk pair and unknown kinds fall here too and are
            // refused: their write set is complete but not VERIFIABLE.
            if (!isAdjudicable(actionKind)) revert ActionNotAdjudicable(actionKind);
            out = new Cell[](2);
            _appendUniform(out, 0, signer);
        }
    }

    /// @dev Length guard, extracted so each arm reads as one line.
    function _need(uint8 actionKind, bytes calldata fields, uint256 n)
        private
        pure
    {
        if (fields.length < n) revert ActionFieldsTooShort(actionKind, fields.length);
    }

    /* ---------------------------------------------------------- */
    /* Canonical absence                                          */
    /* ---------------------------------------------------------- */

    /// @notice The value a cell reads as when the state holds no entry
    ///         for it.  Mirrors `FaultProof.canonicalAbsentValue`.
    ///
    /// @dev    The last primitive the fold needs, and it is not
    ///         cosmetic: `stateCellEntries` DROPS canonically-absent
    ///         cells, so "value is canonically absent" and "key is
    ///         absent from the tree" are the same condition.  A cell at
    ///         this value has an EMPTY sub-tree beneath its key, so its
    ///         leaf is the canonical empty one rather than a hash of
    ///         the preimage — which is what makes an absent cell
    ///         openable at all, and a step crediting a fresh actor
    ///         opens one on its first line.
    ///
    ///         Without the check, `setBalance s r a 0` and "no entry
    ///         for `a`" would be indistinguishable to the verifier
    ///         while producing different leaves, and the fold would
    ///         reach a root the sequencer never published.
    ///
    /// @param  cellKind the cell-kind discriminator (0..14).
    /// @return the canonical absent bytes for that kind.
    function canonicalAbsentValue(uint8 cellKind)
        internal
        pure
        returns (bytes memory)
    {
        // Balances and the four bridge amount scalars ride the amount
        // head; nonces, the withdrawal counter and the two 0/1 flags
        // ride the uint head.
        if (cellKind == 0 || cellKind == 7 || cellKind == 8
            || cellKind == 10 || cellKind == 11) {
            return CBEEncode.amountValue(0);
        }
        if (cellKind == 1 || cellKind == 6 || cellKind == 9 || cellKind == 12) {
            return CBEEncode.uintValue(0);
        }
        // Registry, local policy and the two bridge records read as
        // genuinely EMPTY when absent — which is why their present
        // values go through the byte-string encoder, whose 9-byte head
        // is there even for a zero-length payload.  Without that a
        // registration with the empty key would be indistinguishable
        // from an absent one, and registration is an admissibility
        // gate.
        if (cellKind == 2 || cellKind == 3 || cellKind == 4 || cellKind == 5) {
            return "";
        }
        if (cellKind == 13) {                       // epochBudget
            return CBEEncode.epochBudgetValue(0, 0);
        }
        if (cellKind == 14) {                       // budgetPolicy
            // `BudgetPolicy.bounded 0 0 0`: the constructor tag then
            // three zero fields.
            return bytes.concat(
                CBEEncode.uintValue(0), CBEEncode.uintValue(0),
                CBEEncode.uintValue(0), CBEEncode.uintValue(0)
            );
        }
        revert ActionNotAdjudicable(cellKind);
    }

    /// @notice Whether a cell value is the canonical absent one.
    /// @dev    The predicate the leaf branch turns on.
    function isCanonicallyAbsent(uint8 cellKind, bytes memory value)
        internal
        pure
        returns (bool)
    {
        return keccak256(value) == keccak256(canonicalAbsentValue(cellKind));
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

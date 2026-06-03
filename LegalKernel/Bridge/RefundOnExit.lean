-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.RefundOnExit — Workstream GP.9.1 (refund-on-exit).

The unified-gas-pool plan's §GP.9.1 deliverable: a withdrawing user may
reclaim a *time-decayed* portion of the gas-pool fee they paid on
deposit.  A deposit that paid `poolAmount` into the gas pool at L2 log
index `depositTime` (the `DepositRecord.depositTime` GP.9.1 widening
records) earns a refund, claimed at log index `now` over an
amortisation window `T`, of

    refund = poolAmount × max(0, 1 − (now − depositTime) / T)

— the fee linearly decays to zero over `T` log steps of dwell time.
The refund is realised as a single `gasPoolActor → user` `transfer`
(`Laws.transfer`, already proven conservative), so:

  * **Conservation** (plan: "fully provable") — the refund moves units
    between two actors at one resource; total supply is invariant
    (`refundTransition_conserves` / `applyRefund_conserves`).
  * **Bounded above by the original fee** (plan: "the user cannot
    reclaim more than they paid in") — the refund is at most the
    deposit's recorded `poolAmount`
    (`refundForDeposit_le_poolAmount`).

`refundAmount` is the pure arithmetic kernel; the integer formulation
`fee * (window − elapsed) / window` matches the decay (`window`-floored
to zero once `elapsed ≥ window`, `0` for a degenerate `window = 0`).
`refundForDeposit` reads the `(poolAmount, depositTime)` pair off a
`DepositRecord`; `refundTransition` is the `gasPoolActor → recipient`
transfer of the computed amount; `applyRefund` looks the deposit up in
the bridge ledger and applies the transfer to an `ExtendedState`'s base.

**Scope / integration boundary.**  This module ships the *mechanism*
and its soundness proofs — the refund arithmetic, the conservative
bounded transfer, and the per-deposit computation off real bridge
state.  The *authorisation* layer (an `Action.claimRefund` constructor;
the admission-time check that the claimant was the original depositor;
the once-per-deposit replay guard) is a deployment-integration concern
layered on top, exactly as `depositWithFee`'s replay protection lives in
`BridgeAdmissibleWith` rather than in `Laws.depositWithFee`.  Every
theorem here holds for an arbitrary `recipient`; conservation and the
fee bound are independent of *who* claims, so the mechanism is sound
regardless of how a deployment wires the claim.

This module is **not** part of the kernel TCB.  A bug here could weaken
the refund's economic guarantees but cannot violate any kernel
invariant: the refund bottoms out at `Laws.transfer`, whose
conservation, locality, and refinement proofs the kernel already owns.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Laws.Transfer
import LegalKernel.Bridge.State
import LegalKernel.Bridge.BridgeActor
import LegalKernel.Authority.Nonce

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority (ExtendedState)

/-! ## The refund-amount arithmetic kernel

`refundAmount fee elapsed window` is the time-decayed fee
`fee × max(0, 1 − elapsed / window)` in integer (`Nat`) form.  The
`window`-floored Nat subtraction `window − elapsed` makes the factor
exactly `0` once `elapsed ≥ window` (fully amortised), and Nat division
by zero (`/ 0 = 0`) makes a degenerate `window = 0` refund nothing.  Its
two load-bearing properties — bounded above by `fee`, and antitone in
`elapsed` — are proven directly from Nat division monotonicity, with no
`omega` (which cannot reason about division). -/

/-- The time-decayed refund: `fee × max(0, 1 − elapsed / window)` in
    integer form, `fee * (window − elapsed) / window`.

    * `elapsed ≥ window` ⇒ `window − elapsed = 0` ⇒ refund `0`
      (the fee has fully amortised over the window).
    * `elapsed = 0` ⇒ `window − 0 = window` ⇒ refund `fee`
      (no dwell time, the full fee is returned — see
      `refundAmount_eq_fee_of_elapsed_zero`).
    * `window = 0` ⇒ Nat `/ 0 = 0` ⇒ refund `0`
      (a degenerate window refunds nothing).

    The refund is always at most `fee` (`refundAmount_le_fee`). -/
def refundAmount (fee elapsed window : Nat) : Nat :=
  fee * (window - elapsed) / window

/-- **Bounded above by the fee** (the plan's "cannot reclaim more than
    they paid in").  For any `elapsed` and `window`, the refund never
    exceeds the original `fee`.  Unconditional — covers the degenerate
    `window = 0` (where the refund is `0`) too.

    Proof: `window − elapsed ≤ window`, so the numerator
    `fee * (window − elapsed) ≤ fee * window = window * fee`, and
    `Nat.div_le_of_le_mul` turns the `≤ window * fee` bound on the
    numerator into the `≤ fee` bound on the quotient. -/
theorem refundAmount_le_fee (fee elapsed window : Nat) :
    refundAmount fee elapsed window ≤ fee := by
  unfold refundAmount
  apply Nat.div_le_of_le_mul
  calc fee * (window - elapsed) ≤ fee * window :=
        Nat.mul_le_mul (Nat.le_refl fee) (Nat.sub_le window elapsed)
    _ = window * fee := Nat.mul_comm fee window

/-- A degenerate amortisation window (`0`) refunds nothing: with `/ 0 =
    0` in `Nat`, the refund is `0` regardless of `fee` / `elapsed`.  A
    deployment must therefore configure `window ≥ 1` for refunds to be
    meaningful (mirrors the `epochLength ≥ 1` discipline). -/
@[simp] theorem refundAmount_zero_window (fee elapsed : Nat) :
    refundAmount fee elapsed 0 = 0 := by
  unfold refundAmount
  simp

/-- A zero fee refunds nothing — there is nothing to reclaim. -/
@[simp] theorem refundAmount_zero_fee (elapsed window : Nat) :
    refundAmount 0 elapsed window = 0 := by
  unfold refundAmount
  simp

/-- **Fully amortised after the window.**  Once the dwell time `elapsed`
    reaches the amortisation window `window`, the fee has fully
    amortised and the refund is `0`.  Proof: `window − elapsed = 0`
    (Nat subtraction at/below the subtrahend), so the numerator is `0`. -/
theorem refundAmount_zero_of_elapsed_ge_window
    (fee elapsed window : Nat) (h : window ≤ elapsed) :
    refundAmount fee elapsed window = 0 := by
  unfold refundAmount
  rw [Nat.sub_eq_zero_of_le h]
  simp

/-- **Full refund at deposit time.**  With no dwell time (`elapsed = 0`)
    and a non-degenerate window (`0 < window`), the entire fee is
    returned.  Proof: `window − 0 = window`, then
    `fee * window / window = fee` (`Nat.mul_div_cancel_left` after
    commuting). -/
theorem refundAmount_eq_fee_of_elapsed_zero
    (fee window : Nat) (hw : 0 < window) :
    refundAmount fee 0 window = fee := by
  unfold refundAmount
  rw [Nat.sub_zero, Nat.mul_comm fee window]
  exact Nat.mul_div_cancel_left fee hw

/-- **Antitone in dwell time.**  Longer dwell ⇒ smaller refund: for a
    fixed `fee` and `window`, more elapsed time never *increases* the
    refund.  This is the monotone-decay guarantee that makes the
    amortisation schedule well-behaved.  Proof: `window − e₂ ≤
    window − e₁` (Nat subtraction is antitone in the subtrahend), lifted
    through `fee *` and `/ window`. -/
theorem refundAmount_antitone_in_elapsed
    (fee window e₁ e₂ : Nat) (h : e₁ ≤ e₂) :
    refundAmount fee e₂ window ≤ refundAmount fee e₁ window := by
  unfold refundAmount
  exact Nat.div_le_div_right
    (Nat.mul_le_mul (Nat.le_refl fee) (Nat.sub_le_sub_left h window))

/-- **Monotone in the fee.**  A larger fee earns a (weakly) larger
    refund at the same dwell time and window — the refund schedule is
    proportional, not regressive.  Proof: lift `f₁ ≤ f₂` through
    `* (window − elapsed)` and `/ window`. -/
theorem refundAmount_monotone_in_fee
    (f₁ f₂ elapsed window : Nat) (h : f₁ ≤ f₂) :
    refundAmount f₁ elapsed window ≤ refundAmount f₂ elapsed window := by
  unfold refundAmount
  exact Nat.div_le_div_right
    (Nat.mul_le_mul h (Nat.le_refl (window - elapsed)))

/-! ## Per-deposit refund computation

`refundForDeposit` reads the `(poolAmount, depositTime)` pair off a
recorded `DepositRecord` and applies `refundAmount`, using the deposit's
own `depositTime` as the dwell-time anchor.  Because `refundAmount` is
bounded by its `fee` argument, the per-deposit refund is bounded by the
deposit's recorded `poolAmount` — the user can never reclaim more than
the fee they actually paid. -/

/-- The refund owed for a recorded deposit, claimed at L2 log index
    `now` over amortisation window `window`.  The dwell time is the Nat
    difference `now − rec.depositTime` (floored to `0` if a refund were
    somehow claimed before the deposit's own log index, which yields the
    full fee — a safe over-approximation that cannot exceed `poolAmount`). -/
def refundForDeposit (rec : DepositRecord) (now window : Nat) : Amount :=
  refundAmount rec.poolAmount (now - rec.depositTime) window

/-- **The per-deposit refund is bounded by the recorded pool fee.**  The
    headline GP.9.1 economic guarantee: a refund for a deposit can never
    exceed the `poolAmount` that deposit actually paid into the gas pool
    — independent of `now`, `window`, and (crucially) whether the user
    ever spent the budget grant the fee bought.  Direct specialisation
    of `refundAmount_le_fee` at `fee := rec.poolAmount`. -/
theorem refundForDeposit_le_poolAmount
    (rec : DepositRecord) (now window : Nat) :
    refundForDeposit rec now window ≤ rec.poolAmount :=
  refundAmount_le_fee rec.poolAmount (now - rec.depositTime) window

/-- A deposit that carried no pool fee (a fee-less `Action.deposit`,
    `poolAmount = 0`) refunds nothing — there is no fee to reclaim. -/
theorem refundForDeposit_zero_of_no_fee
    (rec : DepositRecord) (now window : Nat) (h : rec.poolAmount = 0) :
    refundForDeposit rec now window = 0 := by
  unfold refundForDeposit
  rw [h]
  exact refundAmount_zero_fee _ _

/-- Past the amortisation window, a deposit refunds nothing.  If the
    dwell time `now − depositTime` reaches `window`, the fee has fully
    amortised. -/
theorem refundForDeposit_zero_of_fully_amortised
    (rec : DepositRecord) (now window : Nat)
    (h : window ≤ now - rec.depositTime) :
    refundForDeposit rec now window = 0 :=
  refundAmount_zero_of_elapsed_ge_window rec.poolAmount (now - rec.depositTime) window h

/-! ## The refund as a `gasPoolActor → user` transfer

The refund moves `refundForDeposit rec now window` units of the
deposit's resource from the pool actor to the recipient.  It IS a
`Laws.transfer`, so it inherits every transfer guarantee verbatim:
conservation of total supply, locality at the deposit's resource, and
freeze-preservation.  In production the `poolActor` is the reserved
`gasPoolActor` (GP.7.1 / `ActorId 1`) and the `recipient` is the
withdrawing user; the theorems are stated for an arbitrary `poolActor` /
`recipient` because conservation and the fee bound do not depend on
their identities. -/

/-- The refund transition: a `transfer` of the time-decayed refund from
    `poolActor` to `recipient` at the deposit's resource.  Definitionally
    a `Laws.transfer`, so it carries every transfer guarantee.  When the
    refund is `0` (fully amortised) or exceeds the pool's balance, the
    transfer precondition fails and `step_impl` is a no-op — the safe
    default. -/
def refundTransition (rec : DepositRecord) (poolActor recipient : ActorId)
    (now window : Nat) : Transition :=
  Laws.transfer rec.resource poolActor recipient (refundForDeposit rec now window)

/-- **Conservation at the refunded resource** (the plan's "the refund is
    a `gasPoolActor → user` transfer, fully provable").  When the refund
    is applied, total supply of the deposit's resource is invariant —
    the units the recipient gains are exactly the units the pool loses.
    Direct lift of `Laws.transfer_conserves`. -/
theorem refundTransition_conserves
    (rec : DepositRecord) (poolActor recipient : ActorId) (now window : Nat)
    (s : State)
    (hpre : (refundTransition rec poolActor recipient now window).pre s) :
    TotalSupply (step_impl s (refundTransition rec poolActor recipient now window))
        rec.resource =
    TotalSupply s rec.resource :=
  Laws.transfer_conserves rec.resource poolActor recipient
    (refundForDeposit rec now window) s hpre

/-- Conservation at *every* resource: the refund touches only the
    deposit's resource, so total supply at any resource is invariant.
    Lift of the `Laws.transfer` `IsConservative` instance. -/
theorem refundTransition_conserves_all
    (rec : DepositRecord) (poolActor recipient : ActorId) (now window : Nat)
    (r : ResourceId) (s : State)
    (hpre : (refundTransition rec poolActor recipient now window).pre s) :
    TotalSupply (step_impl s (refundTransition rec poolActor recipient now window)) r =
    TotalSupply s r :=
  (Laws.transfer_isConservative rec.resource poolActor recipient
    (refundForDeposit rec now window)).conserves r s hpre

/-- `refundTransition` is conservative (inherited from `Laws.transfer`):
    a `ConservativeLawSet` accepts it without further proof. -/
instance refundTransition_isConservative
    (rec : DepositRecord) (poolActor recipient : ActorId) (now window : Nat) :
    IsConservative (refundTransition rec poolActor recipient now window) :=
  Laws.transfer_isConservative rec.resource poolActor recipient
    (refundForDeposit rec now window)

/-- `refundTransition` is `LocalTo [rec.resource]` (inherited from
    `Laws.transfer`): it touches no balance outside the deposit's
    resource. -/
instance refundTransition_localTo
    (rec : DepositRecord) (poolActor recipient : ActorId) (now window : Nat) :
    LocalTo [rec.resource] (refundTransition rec poolActor recipient now window) :=
  Laws.transfer_localTo rec.resource poolActor recipient
    (refundForDeposit rec now window)

/-- `refundTransition` preserves freeze for any resource set `S` not
    containing the deposit's resource (inherited from
    `Laws.transfer_freezePreserving`). -/
theorem refundTransition_freezePreserving
    (rec : DepositRecord) (poolActor recipient : ActorId) (now window : Nat)
    (S : List ResourceId) (h : rec.resource ∉ S) :
    FreezePreserving S (refundTransition rec poolActor recipient now window) :=
  Laws.transfer_freezePreserving rec.resource poolActor recipient
    (refundForDeposit rec now window) S h

/-! ## Credit / debit accounting for the refund transfer

The two helper lemmas below pin the `transfer` law's per-actor balance
deltas (the receiver gains `amount`; the sender loses `amount`) under
the distinct-actor, precondition-holding case.  They are general
`Laws.transfer` facts proven locally (the canonical law module ships the
*conservation* and *locality* theorems but not the per-actor deltas);
the refund specialisations consume them to show the pool loses, and the
user gains, exactly the time-decayed refund. -/

/-- A precondition-holding transfer between distinct actors credits the
    receiver by exactly `amount`. -/
theorem transfer_credits_receiver
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount) (s : State)
    (hpre : (Laws.transfer r sender receiver amount).pre s)
    (hne : sender ≠ receiver) :
    getBalance (step_impl s (Laws.transfer r sender receiver amount)) r receiver =
    getBalance s r receiver + amount := by
  rw [step_impl, if_pos hpre]
  show getBalance ((Laws.transfer r sender receiver amount).apply_impl s) r receiver = _
  simp only [Laws.transfer]
  rw [getBalance_setBalance_same]
  congr 1
  exact getBalance_setBalance_other s r r sender receiver
    (getBalance s r sender - amount) (Or.inr hne)

/-- A precondition-holding transfer between distinct actors debits the
    sender by exactly `amount` (Nat subtraction; the precondition's
    sufficient-balance clause guarantees no underflow truncation). -/
theorem transfer_debits_sender
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount) (s : State)
    (hpre : (Laws.transfer r sender receiver amount).pre s)
    (hne : sender ≠ receiver) :
    getBalance (step_impl s (Laws.transfer r sender receiver amount)) r sender =
    getBalance s r sender - amount := by
  rw [step_impl, if_pos hpre]
  show getBalance ((Laws.transfer r sender receiver amount).apply_impl s) r sender = _
  simp only [Laws.transfer]
  rw [getBalance_setBalance_other _ r r receiver sender _ (Or.inr (Ne.symm hne))]
  exact getBalance_setBalance_same s r sender (getBalance s r sender - amount)

/-- **The user is credited exactly the refund.**  When the refund
    transfer's precondition holds and the pool actor differs from the
    recipient, the recipient's balance at the deposit's resource
    increases by exactly `refundForDeposit rec now window`. -/
theorem refund_credits_recipient
    (rec : DepositRecord) (poolActor recipient : ActorId) (now window : Nat)
    (s : State)
    (hpre : (refundTransition rec poolActor recipient now window).pre s)
    (hne : poolActor ≠ recipient) :
    getBalance (step_impl s (refundTransition rec poolActor recipient now window))
        rec.resource recipient =
    getBalance s rec.resource recipient + refundForDeposit rec now window :=
  transfer_credits_receiver rec.resource poolActor recipient
    (refundForDeposit rec now window) s hpre hne

/-- **The pool is debited exactly the refund.**  When the refund
    transfer's precondition holds and the pool actor differs from the
    recipient, the pool's balance at the deposit's resource decreases by
    exactly `refundForDeposit rec now window` — which, by
    `refundForDeposit_le_poolAmount`, is at most the fee the deposit
    originally paid. -/
theorem refund_debits_pool
    (rec : DepositRecord) (poolActor recipient : ActorId) (now window : Nat)
    (s : State)
    (hpre : (refundTransition rec poolActor recipient now window).pre s)
    (hne : poolActor ≠ recipient) :
    getBalance (step_impl s (refundTransition rec poolActor recipient now window))
        rec.resource poolActor =
    getBalance s rec.resource poolActor - refundForDeposit rec now window :=
  transfer_debits_sender rec.resource poolActor recipient
    (refundForDeposit rec now window) s hpre hne

/-! ## `ExtendedState`-level refund application

`applyRefund` is the bridge-aware entry: it looks the deposit up in the
bridge ledger's `consumed` map, computes the refund off the *recorded*
`(poolAmount, depositTime)`, and applies the `gasPoolActor → recipient`
transfer to the kernel base state.  An unknown deposit id is a no-op (no
deposit, no refund).  Conservation holds unconditionally: every branch
either leaves the state untouched (unknown id, or a failed-precondition
transfer) or applies a conservative transfer. -/

/-- Apply a refund for `depositId` to an `ExtendedState`'s base state:
    look the deposit up in `es.bridge.consumed`, and if present, transfer
    the time-decayed refund from `poolActor` to `recipient` at the
    deposit's resource.  An unknown deposit id (or a refund the pool
    cannot cover, or a fully-amortised zero refund) is a no-op via the
    transfer precondition.  Only `base` is touched; the nonce ledger,
    registry, local policies, bridge ledger, and budget state are left
    exactly as they were (the caller's admission / replay machinery owns
    those).  In production `poolActor` is the reserved `gasPoolActor`. -/
def applyRefund (es : ExtendedState) (depositId : DepositId)
    (poolActor recipient : ActorId) (now window : Nat) : ExtendedState :=
  match es.bridge.consumed[depositId]? with
  | none     => es
  | some rec =>
      { es with base :=
          step_impl es.base (refundTransition rec poolActor recipient now window) }

/-- An unknown deposit id refunds nothing — `applyRefund` is the
    identity. -/
theorem applyRefund_unknown_deposit
    (es : ExtendedState) (depositId : DepositId)
    (poolActor recipient : ActorId) (now window : Nat)
    (h : es.bridge.consumed[depositId]? = none) :
    applyRefund es depositId poolActor recipient now window = es := by
  unfold applyRefund
  rw [h]

/-- **Conservation across `applyRefund`** (unconditional, at every
    resource).  Applying a refund never changes the total supply of any
    resource: an unknown deposit id leaves the state untouched; a known
    deposit applies a conservative transfer (or, if its precondition
    fails — zero refund or insufficient pool balance — a no-op).  This is
    the `ExtendedState`-level form of the plan's conservation guarantee. -/
theorem applyRefund_conserves
    (es : ExtendedState) (depositId : DepositId)
    (poolActor recipient : ActorId) (now window : Nat) (r : ResourceId) :
    TotalSupply (applyRefund es depositId poolActor recipient now window).base r =
    TotalSupply es.base r := by
  unfold applyRefund
  cases h : es.bridge.consumed[depositId]? with
  | none => rfl
  | some rec =>
      show TotalSupply
          (step_impl es.base (refundTransition rec poolActor recipient now window)) r =
        TotalSupply es.base r
      by_cases hpre : (refundTransition rec poolActor recipient now window).pre es.base
      · exact refundTransition_conserves_all rec poolActor recipient now window r es.base hpre
      · rw [impl_noop_if_not_pre es.base _ hpre]

/-- **The user is credited the refund by `applyRefund`.**  For a known
    deposit, when the pool can cover the (positive) refund and the pool
    actor differs from the recipient, the recipient's balance at the
    deposit's resource increases by exactly the time-decayed refund. -/
theorem applyRefund_credits_recipient
    (es : ExtendedState) (depositId : DepositId)
    (poolActor recipient : ActorId) (now window : Nat)
    (rec : DepositRecord)
    (h : es.bridge.consumed[depositId]? = some rec)
    (hpre : (refundTransition rec poolActor recipient now window).pre es.base)
    (hne : poolActor ≠ recipient) :
    getBalance (applyRefund es depositId poolActor recipient now window).base
        rec.resource recipient =
    getBalance es.base rec.resource recipient + refundForDeposit rec now window := by
  unfold applyRefund
  rw [h]
  exact refund_credits_recipient rec poolActor recipient now window es.base hpre hne

/-- **The pool never loses more than the recorded fee** (the
    `ExtendedState`-level form of "the user cannot reclaim more than they
    paid in").  For a known deposit with a distinct pool actor and
    recipient, the pool's post-refund balance is at least its pre-refund
    balance minus the deposit's recorded `poolAmount` — *unconditionally*
    on whether the transfer's precondition holds (a zero / unaffordable
    refund is a no-op, losing nothing; an applied refund loses exactly
    `refundForDeposit ≤ poolAmount`).  This bounds the pool drain a single
    refund can cause to the fee that deposit actually paid in. -/
theorem applyRefund_pool_balance_lower_bound
    (es : ExtendedState) (depositId : DepositId)
    (poolActor recipient : ActorId) (now window : Nat)
    (rec : DepositRecord)
    (h : es.bridge.consumed[depositId]? = some rec)
    (hne : poolActor ≠ recipient) :
    getBalance es.base rec.resource poolActor - rec.poolAmount ≤
    getBalance (applyRefund es depositId poolActor recipient now window).base
      rec.resource poolActor := by
  unfold applyRefund
  rw [h]
  show getBalance es.base rec.resource poolActor - rec.poolAmount ≤
    getBalance (step_impl es.base (refundTransition rec poolActor recipient now window))
      rec.resource poolActor
  by_cases hpre : (refundTransition rec poolActor recipient now window).pre es.base
  · rw [refund_debits_pool rec poolActor recipient now window es.base hpre hne]
    -- goal: pool_before − poolAmount ≤ pool_before − refund, with refund ≤ poolAmount.
    exact Nat.sub_le_sub_left (refundForDeposit_le_poolAmount rec now window)
      (getBalance es.base rec.resource poolActor)
  · rw [impl_noop_if_not_pre es.base _ hpre]
    -- goal: pool_before − poolAmount ≤ pool_before (the no-op branch loses nothing).
    exact Nat.sub_le _ _

end Bridge
end LegalKernel

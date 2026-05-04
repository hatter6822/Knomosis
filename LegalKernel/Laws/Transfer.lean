/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Laws.Transfer — the canonical balance-moving law.

This is the §4.11 worked example.  Phase 0 shipped the *law itself*
(the `Transition` value) and the precondition's decidability witness.
Phase 2 (Economic Invariants) adds:

* §4.11.1 / WU 2.2 + 2.3 — `transfer_conserves`: per-resource
  conservation of `TotalSupply` for the transferred resource, in both
  the distinct-actors and self-transfer cases.  The proof unifies the
  two cases by chaining two applications of the master accounting
  lemma `LegalKernel.totalSupply_setBalance` and discharging the
  resulting linear system with `omega`.
* §4.11.2 — `transfer_does_not_touch_other_resources`: pointwise
  per-actor balance preservation at any unrelated resource.  The
  state-level companion `transfer_other_resource_untouched` lifts the
  pointwise statement to the per-resource `BalanceMap` so that
  conservation at unrelated resources follows mechanically.
* §5.3 / WU 2.4 — `instance : IsConservative (transfer …)`:
  combines `transfer_conserves` (for the transferred resource) with
  `transfer_other_resource_untouched` (for every other resource) to
  derive the typeclass instance that downstream `ConservativeLawSet`
  proofs consume.

The self-transfer bug fix (§4.11) is preserved verbatim: the
receiver's pre-credit balance is read from `s1` (the post-debit
intermediate state), not from `s` (the original).
-/

import LegalKernel.Kernel
import LegalKernel.Conservation

namespace LegalKernel
namespace Laws

/-- Transfer `amount` units of resource `r` from `sender` to
    `receiver`.

    * Precondition: the sender holds at least `amount`, and `amount`
      is strictly positive.  The positivity clause excludes vacuous
      transfers; it is policy, not correctness, and can be relaxed
      without breaking any kernel proof.
    * Effect: a debit at `sender` followed by a credit at `receiver`,
      reading the receiver's pre-credit balance from the post-debit
      intermediate state.  This sequencing is what makes
      self-transfers conserve total supply (see §4.11 for the proof
      sketch).

    `decPre` is inferred: the precondition is a conjunction of two
    decidable arithmetic comparisons over `Nat`. -/
def transfer (r : ResourceId)
    (sender receiver : ActorId) (amount : Amount) : Transition where
  pre        := fun s => getBalance s r sender ≥ amount ∧ amount > 0
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    let fromBal := getBalance s r sender
    let s1      := setBalance s r sender (fromBal - amount)
    -- Crucial: read receiver's balance from s1, not s.
    -- When sender = receiver, this preserves the actor's total
    -- balance; reading from `s` would over-credit by `amount`.
    let toBal   := getBalance s1 r receiver
    setBalance s1 r receiver (toBal + amount)

/-- Sanity restatement of the precondition: `transfer.pre s` is exactly
    "sender holds at least `amount`, and `amount > 0`".  Also serves
    as a smoke test that the precondition is decidable (the typeclass
    resolution below would fail otherwise). -/
example (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (s : State) :
    Decidable ((transfer r sender receiver amount).pre s) :=
  inferInstance

/-! ## Per-resource conservation (§4.11.1 / WU 2.2 + 2.3)

The conservation argument unfolds in three steps:

1. Open `step_impl` to `apply_impl` via the precondition.
2. Apply the master `setBalance`-on-`TotalSupply` accounting lemma
   (`LegalKernel.totalSupply_setBalance`) at each of the two
   `setBalance` writes — debit, then credit.
3. Solve the resulting linear system with `omega`, which absorbs the
   `Nat`-subtraction asymmetries arising from the debit step.

Note that the proof is uniform over the two §4.11 cases: it does
*not* split on whether `sender = receiver`.  The §4.11 self-transfer
fix lives in `transfer.apply_impl` (read receiver's balance from the
post-debit state, not the original); given that fix, the master
lemma's additive identity covers both cases without further
case-splitting. -/

/-- Pure-arithmetic kernel of `transfer_conserves`.  Abstracts the
    five `Nat` variables omega needs to reason about (initial supply
    `T0`, intermediate supply `T1`, final supply `T2`, sender balance
    `B`, receiver-side intermediate balance `R1`) along with the
    transferred `amount`, plus the two master-lemma equations and the
    precondition's balance bound.  Concludes `T2 = T0`.

    This decomposition is a workaround for an `omega` parsing
    limitation: when the four `Nat`-valued sub-terms are deeply
    nested `TotalSupply (setBalance (setBalance …))` expressions,
    omega's atom discovery fails to surface them as variables and
    the linear system cannot be closed.  Lifting to plain `Nat`
    parameters here gives omega a clean three-equation, six-variable
    instance it solves trivially. -/
private theorem transfer_arithmetic
    (T0 T1 T2 B R1 amount : Nat)
    (h1   : T1 + B = T0 + (B - amount))
    (h2   : T2 + R1 = T1 + (R1 + amount))
    (hbal : amount ≤ B) :
    T2 = T0 := by
  omega

/-- §4.11.1 / WU 2.2 + 2.3: `transfer` preserves per-resource total
    supply at the transferred resource.  Applies to both the
    distinct-actor case and the self-transfer case (the §4.11 fix
    inside `transfer.apply_impl` is what makes the self-case work).

    Proof: chain two `totalSupply_setBalance` applications (debit at
    sender, credit at receiver) and feed the resulting Nat equations
    to the `transfer_arithmetic` helper, which discharges the linear
    system with a single `omega` call. -/
theorem transfer_conserves
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (s : State) (hpre : (transfer r sender receiver amount).pre s) :
    TotalSupply (step_impl s (transfer r sender receiver amount)) r =
    TotalSupply s r := by
  -- Reduce step_impl to apply_impl, then unfold transfer so the goal
  -- exposes the two literal `setBalance` writes.
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((transfer r sender receiver amount).apply_impl s) r
       = TotalSupply s r
  simp only [transfer]
  -- Apply the two master-lemma instances and the precondition, then
  -- delegate the linear arithmetic to `transfer_arithmetic`.
  exact transfer_arithmetic
    (TotalSupply s r)
    (TotalSupply (setBalance s r sender (getBalance s r sender - amount)) r)
    (TotalSupply (setBalance
      (setBalance s r sender (getBalance s r sender - amount)) r receiver
      (getBalance (setBalance s r sender (getBalance s r sender - amount))
        r receiver + amount)) r)
    (getBalance s r sender)
    (getBalance (setBalance s r sender (getBalance s r sender - amount))
      r receiver)
    amount
    (totalSupply_setBalance s r sender (getBalance s r sender - amount))
    (totalSupply_setBalance
      (setBalance s r sender (getBalance s r sender - amount)) r receiver
      (getBalance (setBalance s r sender (getBalance s r sender - amount))
        r receiver + amount))
    hpre.left

/-! ## Cross-resource independence (§4.11.2)

`transfer` only writes at the transferred resource `r`, so any
unrelated resource `r' ≠ r` is left untouched at every level: per
actor (the §4.11.2 statement) *and* per per-resource `BalanceMap`
(the state-level form needed for `IsConservative`). -/

/-- State-level companion to `transfer_does_not_touch_other_resources`:
    the per-resource `BalanceMap` at `r' ≠ r` is identical before and
    after a (legal or rejected) transfer at `r`.  Used to derive
    `transfer_conserves_other_resource` by reducing both sides of the
    `TotalSupply` equation to the same fold. -/
theorem transfer_other_resource_untouched
    (r r' : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (s : State) (h : r ≠ r') :
    (step_impl s (transfer r sender receiver amount)).balances[r']? =
    s.balances[r']? := by
  rw [step_impl]
  -- Two cases: precondition holds (apply_impl runs) or fails (no-op).
  by_cases hpre : (transfer r sender receiver amount).pre s
  · simp only [if_pos hpre]
    -- Both setBalance writes go through `s.balances.insert r ...`; reading
    -- at r' ≠ r passes through unchanged via `find?_insert_other`.
    show ((setBalance
      (setBalance s r sender (getBalance s r sender - amount)) r receiver
      _).balances)[r']? = s.balances[r']?
    unfold setBalance
    -- Outer-level: two nested `s.balances.insert r ...` calls; both invisible at r'.
    rw [RBMap.find?_insert_other _ r r' _ h, RBMap.find?_insert_other _ r r' _ h]
  · simp only [if_neg hpre]

/-- §4.11.2: per-actor balance is preserved at any resource `r' ≠ r`
    after a transfer at `r`.  Cross-resource independence is what
    makes `transfer` a "local" law: it can be reasoned about at the
    granularity of a single resource without considering the rest of
    the State. -/
theorem transfer_does_not_touch_other_resources
    (r r' : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (a : ActorId) (s : State) (h : r ≠ r') :
    getBalance (step_impl s (transfer r sender receiver amount)) r' a =
    getBalance s r' a := by
  -- Both sides of `getBalance` go through `s.balances[r']?`; the
  -- state-level untouched lemma collapses them to the same lookup.
  unfold getBalance
  rw [transfer_other_resource_untouched r r' sender receiver amount s h]

/-- Conservation extends to any resource `r' ≠ r`: transfer doesn't
    touch the per-resource map there, so `TotalSupply` reduces to the
    same fold on both sides. -/
theorem transfer_conserves_other_resource
    (r r' : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (s : State) (h : r ≠ r') :
    TotalSupply (step_impl s (transfer r sender receiver amount)) r' =
    TotalSupply s r' := by
  unfold TotalSupply
  rw [transfer_other_resource_untouched r r' sender receiver amount s h]

/-! ## `IsConservative` instance (§5.3 / WU 2.4) -/

/-- `transfer` is conservative at *every* resource: at the transferred
    resource `r` by `transfer_conserves`, and at every other resource
    by `transfer_conserves_other_resource`.  This instance is what
    lets a `ConservativeLawSet` accept `transfer …` without further
    proof obligations. -/
instance transfer_isConservative
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    IsConservative (transfer r sender receiver amount) where
  conserves := by
    intro r' s hpre
    by_cases hr : r = r'
    · subst hr; exact transfer_conserves r sender receiver amount s hpre
    · exact transfer_conserves_other_resource r r' sender receiver amount s hr

/-- `transfer` is monotonic at every resource.  Conservative laws are
    automatically monotonic (via `monotonic_of_conservative`); this
    explicit instance ships for stable identifier resolution and clearer
    error messages at use sites. -/
instance transfer_isMonotonic
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    IsMonotonic (transfer r sender receiver amount) where
  monotone := fun r' s hpre =>
    Nat.le_of_eq
      ((transfer_isConservative r sender receiver amount).conserves r' s hpre).symm

end Laws
end LegalKernel

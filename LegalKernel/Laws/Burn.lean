/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Laws.Burn — non-conservative balance destruction.

Phase 2 WU 2.5 / WU 2.6.  Defines the `burn` law (a single-actor
debit at a specified resource) and proves explicitly that it is
*not* `IsConservative`: under any positive `amount` and a state in
which the burned actor holds at least `amount`, `burn`'s application
strictly decreases the per-resource total supply.

`burn` is the dual of `mint`.  Together they exhaust the canonical
non-conservative laws of an asset accounting system; both are
excluded from `ConservativeLawSet` by typing.

This module is **not** part of the trusted computing base.  It is
imported by `LegalKernel.lean` for re-export and by
`LegalKernel.Test.Laws.Burn` for runtime spot-checking.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation

namespace LegalKernel
namespace Laws

/-- Burn `amount` units of resource `r` from actor `fromActor`'s balance.

    * Precondition: `fromActor` holds at least `amount`, and `amount > 0`.
      Burn-of-zero is excluded by policy (mirroring `transfer` and
      `mint`); the balance lower bound is what makes `burn` total on
      `Nat` (no truncated-subtraction surprises at the value level).
    * Effect: decreases `fromActor`'s balance under `r` by `amount`,
      leaving every other balance untouched.

    `decPre` is inferred: the precondition is a conjunction of two
    decidable arithmetic comparisons over `Nat`. -/
def burn (r : ResourceId) (fromActor : ActorId) (amount : Amount) : Transition where
  pre        := fun s => getBalance s r fromActor ≥ amount ∧ amount > 0
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    setBalance s r fromActor (getBalance s r fromActor - amount)

/-- Sanity decidability witness for `burn`'s precondition. -/
example (r : ResourceId) (fromActor : ActorId) (amount : Amount) (s : State) :
    Decidable ((burn r fromActor amount).pre s) :=
  inferInstance

/-! ## Effect on `TotalSupply` (negative change) -/

/-- Pure-arithmetic kernel of `totalSupply_after_burn`.  Same omega
    workaround as in `Laws/Transfer.lean`: lift the deeply nested
    `TotalSupply (setBalance …)` and `getBalance` sub-terms to plain
    `Nat` parameters so that omega's atom discovery succeeds. -/
private theorem burn_arithmetic
    (T0 T1 B amount : Nat)
    (h    : T1 + B = T0 + (B - amount))
    (hbal : amount ≤ B) :
    T1 + amount = T0 := by
  omega

/-- Master-lemma corollary specialised to `burn`: when the precondition
    holds, the post-burn supply at the burned resource plus `amount`
    equals the pre-burn supply.  Stated in additive form to avoid
    `Nat`-subtraction asymmetry. -/
theorem totalSupply_after_burn
    (r : ResourceId) (fromActor : ActorId) (amount : Amount) (s : State)
    (hpre : (burn r fromActor amount).pre s) :
    TotalSupply (step_impl s (burn r fromActor amount)) r + amount =
    TotalSupply s r := by
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((burn r fromActor amount).apply_impl s) r + amount =
       TotalSupply s r
  simp only [burn]
  exact burn_arithmetic
    (TotalSupply s r)
    (TotalSupply (setBalance s r fromActor (getBalance s r fromActor - amount)) r)
    (getBalance s r fromActor)
    amount
    (totalSupply_setBalance s r fromActor (getBalance s r fromActor - amount))
    hpre.left

/-! ## Cross-resource independence

`burn` only writes at the burned resource `r`, so any other resource
`r' ≠ r` is left untouched.  Symmetric to the mint cross-resource
lemmas in `Laws/Mint.lean`. -/

/-- State-level: the per-resource `BalanceMap` at `r' ≠ r` is unchanged
    by a (legal or rejected) burn at `r`. -/
theorem burn_other_resource_untouched
    (r r' : ResourceId) (fromActor : ActorId) (amount : Amount)
    (s : State) (h : r ≠ r') :
    (step_impl s (burn r fromActor amount)).balances[r']? =
    s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (burn r fromActor amount).pre s
  · simp only [if_pos hpre]
    show ((burn r fromActor amount).apply_impl s).balances[r']? = s.balances[r']?
    simp only [burn, setBalance]
    rw [RBMap.find?_insert_other _ r r' _ h]
  · simp only [if_neg hpre]

/-- Pointwise per-actor balance preservation at any `r' ≠ r`. -/
theorem burn_does_not_touch_other_resources
    (r r' : ResourceId) (fromActor : ActorId) (amount : Amount)
    (a : ActorId) (s : State) (h : r ≠ r') :
    getBalance (step_impl s (burn r fromActor amount)) r' a =
    getBalance s r' a := by
  unfold getBalance
  rw [burn_other_resource_untouched r r' fromActor amount s h]

/-- Conservation at any `r' ≠ r`: burn doesn't touch the per-resource
    map there, so `TotalSupply` reduces to the same fold on both sides. -/
theorem burn_conserves_other_resource
    (r r' : ResourceId) (fromActor : ActorId) (amount : Amount)
    (s : State) (h : r ≠ r') :
    TotalSupply (step_impl s (burn r fromActor amount)) r' =
    TotalSupply s r' := by
  unfold TotalSupply
  rw [burn_other_resource_untouched r r' fromActor amount s h]

/-! ## Non-conservation (§5.6 / WU 2.6) -/

/-- §5.6 / WU 2.6: `burn` is *not* an `IsConservative` law.  Witness:
    a state with `fromActor`'s balance at exactly `amount` (so the burn
    precondition holds and the post-burn supply at `r` is `0`); the
    pre-burn supply is `amount > 0`, contradicting conservation.

    Following the construction used by `mint_not_conservative`: take
    `s := setBalance genesisState r fromActor amount`.  At `s`, both the
    pre- and post-burn supplies are computable and the
    burn-then-conservation chain gives `0 = amount`. -/
theorem burn_not_conservative
    (r : ResourceId) (fromActor : ActorId) (amount : Amount)
    (hpos : amount > 0) :
    ¬ IsConservative (burn r fromActor amount) := by
  intro hcons
  -- A state in which `fromActor` holds exactly `amount` at resource `r`.
  let s : State := setBalance genesisState r fromActor amount
  have hread : getBalance s r fromActor = amount := by
    show getBalance (setBalance genesisState r fromActor amount) r fromActor = amount
    exact getBalance_setBalance_same genesisState r fromActor amount
  have hpre : (burn r fromActor amount).pre s := by
    refine ⟨?_, hpos⟩
    rw [hread]
    -- Goal after rewrite: amount ≥ amount.
    exact Nat.le_refl amount
  have hcons_r := hcons.conserves r s hpre
  -- Pre-burn supply at r: TotalSupply s r = amount (write at fresh genesis).
  have hT0 : TotalSupply s r = amount := by
    show TotalSupply (setBalance genesisState r fromActor amount) r = amount
    have h := totalSupply_setBalance genesisState r fromActor amount
    -- h : TotalSupply (setBalance ...) r + getBalance genesisState r fromActor
    --   = TotalSupply genesisState r + amount
    rw [totalSupply_genesis_eq_zero r] at h
    -- h : TotalSupply (setBalance ...) r + getBalance genesisState r fromActor = 0 + amount
    -- and getBalance genesisState r fromActor = 0 (genesis is empty)
    have hgen : getBalance genesisState r fromActor = 0 := by
      show getBalance ({ balances := ∅ } : State) r fromActor = 0
      simp [getBalance]
    rw [hgen] at h
    omega
  -- Post-burn supply at r: TotalSupply (step_impl s (burn …)) r + amount = TotalSupply s r = amount.
  have hpost := totalSupply_after_burn r fromActor amount s hpre
  -- hpost : TotalSupply (step_impl …) r + amount = TotalSupply s r
  rw [hT0] at hpost
  -- hpost : TotalSupply (step_impl …) r + amount = amount
  -- hcons_r : TotalSupply (step_impl …) r = TotalSupply s r = amount
  rw [hT0] at hcons_r
  -- hcons_r : TotalSupply (step_impl …) r = amount
  -- Combining: amount + amount = amount, which forces amount = 0.
  rw [hcons_r] at hpost
  -- hpost : amount + amount = amount
  simp at hpost
  exact absurd hpost (Nat.pos_iff_ne_zero.mp hpos)

/-! ## Non-monotonicity (positive-incentive tier negative witness) -/

/-- `burn` is *not* an `IsMonotonic` law: applied at a state in which
    the burned actor holds exactly `amount`, post-supply is `0` while
    pre-supply is `amount > 0`, so supply strictly *decreases* (which
    contradicts `IsMonotonic.monotone : pre ≤ post`).

    Same fixture as `burn_not_conservative`: `s := setBalance
    genesisState r fromActor amount`.  This is the formal type-level
    firewall between the conservative / monotonic tiers and `burn`:
    deployments that want either guarantee cannot include `burn` in
    their law set. -/
theorem burn_not_monotonic
    (r : ResourceId) (fromActor : ActorId) (amount : Amount)
    (hpos : amount > 0) :
    ¬ IsMonotonic (burn r fromActor amount) := by
  intro hmon
  -- Same fixture as burn_not_conservative.
  let s : State := setBalance genesisState r fromActor amount
  have hread : getBalance s r fromActor = amount :=
    getBalance_setBalance_same genesisState r fromActor amount
  have hpre : (burn r fromActor amount).pre s := by
    refine ⟨?_, hpos⟩
    rw [hread]
    exact Nat.le_refl amount
  have hT0 : TotalSupply s r = amount := by
    show TotalSupply (setBalance genesisState r fromActor amount) r = amount
    have h := totalSupply_setBalance genesisState r fromActor amount
    rw [totalSupply_genesis_eq_zero r] at h
    have hgen : getBalance genesisState r fromActor = 0 := by
      show getBalance ({ balances := ∅ } : State) r fromActor = 0
      simp [getBalance]
    rw [hgen] at h
    omega
  -- Monotonicity hypothesis: TotalSupply s r ≤ TotalSupply (step_impl …) r.
  have hmon_r := hmon.monotone r s hpre
  -- Supply equation: post + amount = pre.
  have hpost := totalSupply_after_burn r fromActor amount s hpre
  rw [hT0] at hpost hmon_r
  -- hpost  : TotalSupply (step_impl …) r + amount = amount
  -- hmon_r : amount ≤ TotalSupply (step_impl …) r
  -- Derive post = 0 from hpost using Nat additive cancellation, then
  -- contradict the monotonicity claim amount ≤ 0.
  have h_post_zero :
      TotalSupply (step_impl s (burn r fromActor amount)) r = 0 := by
    have h := hpost
    -- h : x + amount = amount  ⟹  x = 0  (Nat additive cancellation).
    omega
  rw [h_post_zero] at hmon_r
  -- hmon_r : amount ≤ 0; combined with hpos : amount > 0, contradiction.
  exact absurd hmon_r (Nat.not_le.mpr hpos)

/-! ## Workstream LX (LX.3) — `LocalTo` instance + freeze-preservation theorem -/

/-- `burn r …` is `LocalTo [r]`.  Direct consequence of
    `burn_does_not_touch_other_resources`. -/
instance burn_localTo
    (r : ResourceId) (fromActor : ActorId) (amount : Amount) :
    LocalTo [r] (burn r fromActor amount) where
  local_to := by
    intro r' a s hr_not_in _
    have hne : r ≠ r' := by
      intro heq
      apply hr_not_in
      rw [← heq]
      exact List.mem_singleton.mpr rfl
    exact burn_does_not_touch_other_resources r r' fromActor amount a s hne

/-- `burn r …` preserves freeze for any resource set `S` not
    containing `r`. -/
theorem burn_freezePreserving
    (r : ResourceId) (fromActor : ActorId) (amount : Amount)
    (S : List ResourceId) (h : r ∉ S) :
    FreezePreserving S (burn r fromActor amount) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne : r' ≠ r := by
      intro heq
      apply h
      rw [← heq]
      exact hr'
    rw [burn_other_resource_untouched r r' fromActor amount s (Ne.symm hne)]
    exact h_init

end Laws
end LegalKernel

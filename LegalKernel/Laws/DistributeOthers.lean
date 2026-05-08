/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Laws.DistributeOthers — uniform reward of all non-excluded
actors at a resource.

Phase-4-prelude WU R.8 / R.9.  Defines `distributeOthers` (the
uniform-distribution analogue of "fining one actor"): every actor
present in the resource's `BalanceMap` *except* an explicitly excluded
one receives `+ amount` to their balance.  Total supply increases by
`amount * sizeExcludingKey`.

Compared to `mint`, `distributeOthers` is a *fold-based* law
(touching `O(k)` actors per invocation, where `k` is the number of
non-excluded entries), but it carries the same monotonicity
classification: `IsMonotonic`, *not* `IsConservative`.

Implementation strategy: instead of rebuilding the `BalanceMap` from
scratch, the apply_impl iterates `setBalance` over the pre-filtered
list of non-excluded entries.  Each step is a known kernel operation
whose effect on `TotalSupply` is captured by `totalSupply_setBalance`,
so the inductive supply argument is short.

Determinism note: the iteration order is fixed by
`Std.TreeMap.toList`, which yields entries in key order (per
`docs/std_dependencies.md`).

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.DSL.LexLaw

open Std
open scoped Std.TreeMap

namespace LegalKernel
namespace Laws

/-! ## Definition (WU R.8) -/

/-- Distribute `amount` units of `r` to every actor in `r`'s
    `BalanceMap` *except* `excluded`.  Actors absent from the
    `BalanceMap` (zero-balance actors) receive nothing — to reach them,
    a deployment must mint to them first.

    * Precondition: `amount > 0`.
    * Effect: for each `(actor, balance)` in `bm := s.balances[r]?.getD
      ∅` with `actor ≠ excluded`, replace the balance with `balance +
      amount`.  Other resources, the excluded actor, and absent actors
      are unchanged.

    `decPre` is inferred: the precondition is a single decidable
    arithmetic comparison over `Nat`. -/
def distributeOthers
    (r : ResourceId) (excluded : ActorId) (amount : Amount) : Transition where
  pre        := fun _ => amount > 0
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    let bm := s.balances[r]?.getD ∅
    let toReward := bm.toList.filter (fun kv => kv.1 != excluded)
    toReward.foldl
      (fun s' kv => setBalance s' r kv.1 (getBalance s' r kv.1 + amount))
      s

/-! ## LX-M2 (LX.29) Lex re-expression of `distributeOthers` -/

set_option linter.missingDocs false in
lexlaw legalkernel_distributeOthers where
  lex_id              legalkernel.distributeOthers
  lex_version         "1.0.0"
  lex_action_index    6
  lex_intent          "Distribute `amount` to every actor in `r`'s `BalanceMap` except `excluded`.  Substitute for 'fining excluded by amount * k' without removing tokens.  Classified `IsMonotonic` (positive-incentive tier)."
  lex_signed_by       deployer
  lex_authorized_by   (fun _ _ => True)
  lex_params          (r : ResourceId) (excluded : ActorId) (amount : Amount)
  lex_pre             := fun _ => amount > 0
  lex_impl            :=
    fun s =>
      let bm := s.balances[r]?.getD ∅
      let toReward := bm.toList.filter (fun kv => kv.1 != excluded)
      toReward.foldl
        (fun s' kv => setBalance s' r kv.1 (getBalance s' r kv.1 + amount))
        s
  -- Per plan §19.4 LX.29: `distributeOthers` claims `monotonic`
  -- (positive-incentive tier — every actor's balance can only
  -- increase via the foldl-of-setBalance pattern), `local`,
  -- `freeze_preserving`, `nonce_advances`, `registry_preserving`.
  -- NOT `conservative` (additive — distributes new tokens).
  -- The plan calls for `proof monotonic := by exact
  -- distributeOthers_isMonotonic ...` override since the
  -- synthesizer would fail on the for-loop impl shape; in M2
  -- the synthesizer skeleton emits placeholder bodies (M3
  -- integration), so the override is metadata-only.
  lex_satisfies       := [monotonic, «local», freeze_preserving,
                          nonce_advances, registry_preserving]
  lex_events          := []

/-- LX-M2 LX.29 byte-equivalence regression for `distributeOthers`. -/
example (r : ResourceId) (excluded : ActorId) (amount : Amount) :
    legalkernel_distributeOthers_transition r excluded amount =
    distributeOthers r excluded amount := rfl

/-- Sanity decidability witness for `distributeOthers`'s precondition. -/
example (r : ResourceId) (excluded : ActorId) (amount : Amount) (s : State) :
    Decidable ((distributeOthers r excluded amount).pre s) :=
  inferInstance

/-! ## Inductive helpers for the foldl-of-setBalance pattern

Each of `distributeOthers`'s locality and arithmetic lemmas reduces to
an inductive statement about `xs.foldl setBalance s`, where each step
applies `setBalance s' r k (getBalance s' r k + amount)` at a fresh
key `k`.  These private helpers carry the inductive proofs once. -/

/-- A `foldl` of `setBalance` calls at resource `r` does not touch the
    `BalanceMap` at any other resource `r' ≠ r`.  Proof: each
    `setBalance` is a `s.balances.insert r …`, invisible at `r'` by
    `RBMap.find?_insert_other`. -/
private theorem foldl_setBalance_other_resource_untouched
    (xs : List (ActorId × Nat)) (s : State)
    (r r' : ResourceId) (amount : Nat) (h : r ≠ r') :
    (xs.foldl
        (fun s' kv => setBalance s' r kv.1 (getBalance s' r kv.1 + amount)) s
      ).balances[r']? = s.balances[r']? := by
  induction xs generalizing s with
  | nil => rfl
  | cons hd tl ih =>
      simp only [List.foldl]
      rw [ih (setBalance s r hd.1 (getBalance s r hd.1 + amount))]
      -- (setBalance s r hd.1 _).balances[r']? = s.balances[r']?
      show (s.balances.insert r
              ((s.balances[r]?.getD ∅).insert hd.1
                (getBalance s r hd.1 + amount)))[r']? = s.balances[r']?
      exact RBMap.find?_insert_other _ r r' _ h

/-- A `foldl` of `setBalance` calls at resource `r` and a list of
    distinct keys none of which equals `excluded` preserves
    `getBalance s r excluded`.  Proof: each step is at a key
    different from `excluded`, so the inner-map insert at that key
    leaves the (r, excluded) entry alone. -/
private theorem foldl_setBalance_excluded_untouched
    (xs : List (ActorId × Nat)) (s : State)
    (r : ResourceId) (excluded : ActorId) (amount : Nat)
    (h : ∀ kv ∈ xs, kv.1 ≠ excluded) :
    getBalance
      (xs.foldl
        (fun s' kv => setBalance s' r kv.1 (getBalance s' r kv.1 + amount)) s)
      r excluded = getBalance s r excluded := by
  induction xs generalizing s with
  | nil => rfl
  | cons hd tl ih =>
      simp only [List.foldl]
      have h_hd : hd.1 ≠ excluded := h hd (List.mem_cons.mpr (Or.inl rfl))
      have h_tl : ∀ kv ∈ tl, kv.1 ≠ excluded :=
        fun kv hkv => h kv (List.mem_cons.mpr (Or.inr hkv))
      rw [ih (setBalance s r hd.1 (getBalance s r hd.1 + amount)) h_tl]
      -- Reduce both sides: setBalance only modifies the (r, hd.1) entry,
      -- so the (r, excluded) entry is unchanged because hd.1 ≠ excluded.
      unfold getBalance setBalance
      rw [RBMap.find?_insert_self s.balances r _]
      -- LHS: match some (insert hd.1 _) → bm[excluded]?.getD 0 with bm := insert hd.1 _.
      simp only []
      rw [RBMap.find?_insert_other _ hd.1 excluded _ h_hd]
      -- LHS now: (s.balances[r]?.getD ∅)[excluded]?.getD 0
      -- RHS: match s.balances[r]? with | none => 0 | some bm => bm[excluded]?.getD 0
      cases s.balances[r]? <;> rfl

/-! ## Cross-resource locality (WU R.8) -/

/-- State-level: the per-resource `BalanceMap` at `r' ≠ r` is unchanged
    by a (legal or rejected) `distributeOthers` at `r`.  Mirrors
    `mint_other_resource_untouched`; the legal branch reduces via the
    `foldl_setBalance_other_resource_untouched` helper. -/
theorem distributeOthers_other_resource_untouched
    (r r' : ResourceId) (excluded : ActorId) (amount : Amount)
    (s : State) (h : r ≠ r') :
    (step_impl s (distributeOthers r excluded amount)).balances[r']? =
    s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (distributeOthers r excluded amount).pre s
  · simp only [if_pos hpre]
    show (((distributeOthers r excluded amount).apply_impl s)).balances[r']?
       = s.balances[r']?
    simp only [distributeOthers]
    exact foldl_setBalance_other_resource_untouched _ s r r' amount h
  · simp only [if_neg hpre]

/-- Pointwise per-actor balance preservation at any `r' ≠ r`. -/
theorem distributeOthers_does_not_touch_other_resources
    (r r' : ResourceId) (excluded : ActorId) (amount : Amount)
    (a : ActorId) (s : State) (h : r ≠ r') :
    getBalance (step_impl s (distributeOthers r excluded amount)) r' a =
    getBalance s r' a := by
  unfold getBalance
  rw [distributeOthers_other_resource_untouched r r' excluded amount s h]

/-- Conservation at any `r' ≠ r`: the per-resource map at `r'` is
    untouched, so `TotalSupply` reduces to the same fold on both sides. -/
theorem distributeOthers_conserves_other_resource
    (r r' : ResourceId) (excluded : ActorId) (amount : Amount)
    (s : State) (h : r ≠ r') :
    TotalSupply (step_impl s (distributeOthers r excluded amount)) r' =
    TotalSupply s r' := by
  unfold TotalSupply
  rw [distributeOthers_other_resource_untouched r r' excluded amount s h]

/-- The headline "excluded actor is preserved" property: at the
    distributed resource, the excluded actor's balance is unchanged.

    Proof: the apply_impl filters out `excluded` before the foldl, so
    no `setBalance` at `(r, excluded, _)` is ever invoked. -/
theorem distributeOthers_excluded_unchanged
    (r : ResourceId) (excluded : ActorId) (amount : Amount) (s : State)
    (hpre : (distributeOthers r excluded amount).pre s) :
    getBalance (step_impl s (distributeOthers r excluded amount)) r excluded =
    getBalance s r excluded := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((distributeOthers r excluded amount).apply_impl s) r excluded
     = getBalance s r excluded
  simp only [distributeOthers]
  apply foldl_setBalance_excluded_untouched
  intro kv hkv
  -- kv ∈ filter (·.1 != excluded) bm.toList, so kv.1 != excluded.
  have := List.mem_filter.mp hkv
  intro heq
  have h_neq : (kv.1 != excluded) = true := this.2
  rw [heq] at h_neq
  simp at h_neq

/-! ## Arithmetic + monotonicity classification (WU R.9) -/

/-- A `foldl` of `setBalance s' r k (getBalance s' r k + amount)` over
    a list of length `n` increases `TotalSupply` at `r` by exactly
    `amount * n`.  Each step adds `amount` because
    `totalSupply_setBalance` collapses the new-balance term against
    the old. -/
private theorem foldl_setBalance_totalSupply
    (xs : List (ActorId × Nat)) (s : State) (r : ResourceId) (amount : Nat) :
    TotalSupply
      (xs.foldl
        (fun s' kv => setBalance s' r kv.1 (getBalance s' r kv.1 + amount)) s)
      r = TotalSupply s r + amount * xs.length := by
  induction xs generalizing s with
  | nil => simp
  | cons hd tl ih =>
      simp only [List.foldl, List.length]
      rw [ih (setBalance s r hd.1 (getBalance s r hd.1 + amount))]
      -- Each step adds amount: totalSupply_setBalance gives the algebraic identity.
      have h_step :
          TotalSupply (setBalance s r hd.1 (getBalance s r hd.1 + amount)) r
            = TotalSupply s r + amount := by
        have h := totalSupply_setBalance s r hd.1 (getBalance s r hd.1 + amount)
        omega
      rw [h_step, Nat.mul_succ]
      -- Goal: TotalSupply s r + amount + amount * tl.length = TotalSupply s r + (amount * tl.length + amount)
      omega

/-- The supply equation for `distributeOthers`: post-distribution
    supply at `r` equals pre-distribution supply plus `amount`
    multiplied by the number of non-excluded actors in the resource's
    `BalanceMap`.

    Equivalently: each non-excluded actor receives `+ amount`, and the
    total supply growth is the per-actor amount times the number of
    such actors. -/
theorem totalSupply_after_distributeOthers
    (r : ResourceId) (excluded : ActorId) (amount : Amount) (s : State)
    (hpre : (distributeOthers r excluded amount).pre s) :
    TotalSupply (step_impl s (distributeOthers r excluded amount)) r =
    TotalSupply s r +
    amount *
      ((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)).length := by
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((distributeOthers r excluded amount).apply_impl s) r = _
  simp only [distributeOthers]
  exact foldl_setBalance_totalSupply _ s r amount

/-- `distributeOthers` is monotonic at every resource.  At the
    distributed resource, the supply equation gives
    `post = pre + amount * k` with `k ≥ 0`, so `pre ≤ post`.  At any
    other resource, the BalanceMap is untouched and the supply is
    equal. -/
instance distributeOthers_isMonotonic
    (r : ResourceId) (excluded : ActorId) (amount : Amount) :
    IsMonotonic (distributeOthers r excluded amount) where
  monotone := by
    intro r' s hpre
    by_cases hr : r = r'
    · subst hr
      have h := totalSupply_after_distributeOthers r excluded amount s hpre
      omega
    · have h := distributeOthers_conserves_other_resource r r' excluded amount s hr
      omega

/-- `distributeOthers` is *not* an `IsConservative` law.  Witness:
    `s := setBalance genesisState r non_excluded amount` for
    `non_excluded := excluded + 1` (always distinct from `excluded`).
    At `s`, the resource `r`'s `BalanceMap` has at least one
    non-excluded entry, so the supply equation forces a strict
    increase, contradicting conservation when `amount > 0`.

    Proof structure: bound the filter length below by `1` via
    membership of `(non_excluded, amount)` in the filtered list, then
    combine with the supply equation and conservation hypothesis. -/
theorem distributeOthers_not_conservative
    (r : ResourceId) (excluded : ActorId) (amount : Amount)
    (hpos : amount > 0) :
    ¬ IsConservative (distributeOthers r excluded amount) := by
  intro hcons
  -- Pick a non-excluded actor.  ActorId is UInt64 (modular arithmetic),
  -- so `excluded + 1 ≠ excluded` doesn't follow from omega.  Use the
  -- "swap 0 ↔ 1" trick: if `excluded = 0`, the witness is `1`;
  -- otherwise it's `0`.  Both branches give a distinct actor.
  let non_excluded : ActorId := if excluded = 0 then 1 else 0
  have h_neq : non_excluded ≠ excluded := by
    show (if excluded = 0 then (1 : ActorId) else (0 : ActorId)) ≠ excluded
    by_cases h : excluded = 0
    · rw [if_pos h, h]; decide
    · rw [if_neg h]; exact Ne.symm h
  let s : State := setBalance genesisState r non_excluded amount
  have hpre : (distributeOthers r excluded amount).pre s := hpos
  have hcons_r := hcons.conserves r s hpre
  have hpost := totalSupply_after_distributeOthers r excluded amount s hpre
  -- Show the filtered-toList length is ≥ 1 by exhibiting an element.
  -- s.balances[r]? = some (∅.insert non_excluded amount), so
  -- (s.balances[r]?.getD ∅)[non_excluded]? = some amount.
  have h_lookup :
      (s.balances[r]?.getD ∅)[non_excluded]? = some amount := by
    show ((((∅ : Std.TreeMap ResourceId BalanceMap _).insert r
              (((∅ : Std.TreeMap ResourceId BalanceMap _)[r]?.getD ∅).insert
                non_excluded amount)))[r]?.getD ∅)[non_excluded]? = some amount
    rw [RBMap.find?_insert_self]
    simp only [Option.getD_some]
    exact RBMap.find?_insert_self _ _ _
  have h_mem : (non_excluded, amount) ∈ (s.balances[r]?.getD ∅).toList :=
    Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h_lookup
  have h_in_filter :
      (non_excluded, amount) ∈
        (s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded) := by
    apply List.mem_filter.mpr
    refine ⟨h_mem, ?_⟩
    simp [h_neq]
  have h_len_pos :
      1 ≤ ((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)).length := by
    -- Membership ⇒ list is non-empty ⇒ length ≥ 1.
    cases h_eq : (s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded) with
    | nil => rw [h_eq] at h_in_filter; cases h_in_filter
    | cons _ _ => simp
  -- Combine: hcons_r + hpost give amount * len = 0; h_len_pos + hpos
  -- give amount * len ≥ amount > 0; contradiction.
  rw [hcons_r] at hpost
  -- hpost : TotalSupply s r = TotalSupply s r + amount * len.
  -- From hpost: amount * len = 0 by Nat additive cancellation.
  have h_zero :
      amount *
        ((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)).length = 0 := by
    have h : TotalSupply s r + 0 = TotalSupply s r +
        amount *
          ((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)).length := by
      rw [Nat.add_zero]; exact hpost
    exact (Nat.add_left_cancel h).symm
  -- amount * len = 0 with len ≥ 1 forces amount = 0 (in Nat).
  have h_amt_zero : amount = 0 := by
    have h_amt_le :
        amount ≤ amount *
          ((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)).length :=
      Nat.le_mul_of_pos_right amount h_len_pos
    rw [h_zero] at h_amt_le
    exact Nat.le_zero.mp h_amt_le
  -- amount = 0 contradicts hpos : amount > 0.
  exact absurd h_amt_zero (Nat.pos_iff_ne_zero.mp hpos)

/-! ## Workstream LX (LX.3) — `LocalTo` instance + freeze-preservation theorem -/

/-- `distributeOthers r …` is `LocalTo [r]`. -/
instance distributeOthers_localTo
    (r : ResourceId) (excluded : ActorId) (amount : Amount) :
    LocalTo [r] (distributeOthers r excluded amount) where
  local_to := by
    intro r' a s hr_not_in _
    have hne : r ≠ r' := by
      intro heq
      apply hr_not_in
      rw [← heq]
      exact List.mem_singleton.mpr rfl
    exact distributeOthers_does_not_touch_other_resources r r' excluded amount a s hne

/-- `distributeOthers r …` preserves freeze for any resource set
    `S` not containing `r`. -/
theorem distributeOthers_freezePreserving
    (r : ResourceId) (excluded : ActorId) (amount : Amount)
    (S : List ResourceId) (h : r ∉ S) :
    FreezePreserving S (distributeOthers r excluded amount) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne : r' ≠ r := by
      intro heq
      apply h
      rw [← heq]
      exact hr'
    rw [distributeOthers_other_resource_untouched r r' excluded amount s
          (Ne.symm hne)]
    exact h_init

/-- Vacuous-case `FreezePreserving []` instance for `distributeOthers`. -/
instance distributeOthers_freezePreserving_empty
    (r : ResourceId) (excluded : ActorId) (amount : Amount) :
    FreezePreserving [] (distributeOthers r excluded amount) :=
  distributeOthers_freezePreserving r excluded amount [] (by simp)

end Laws
end LegalKernel

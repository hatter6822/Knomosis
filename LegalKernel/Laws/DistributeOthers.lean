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

end Laws
end LegalKernel

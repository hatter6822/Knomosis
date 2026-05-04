/-
LegalKernel.Laws.ProportionalDilute — proportional positive-incentive
distribution.

Phase-4-prelude WU R.12 / R.13 / R.14 / R.15.  Defines
`proportionalDilute`: the strongest analogue of "fining one actor"
that operates by reward only.  Every non-excluded actor `k` with
balance `v_k` receives `+ totalReward * v_k / sumOthers` (Nat floor
division), so larger holders gain more in absolute terms — the
relative-wealth penalty on `excluded` is the proportional analogue of
burning their balance share.

Rounding policy (D5 in the plan): floor division with **dust
discarded**.  The total amount distributed is bounded above by
`totalReward` (proved as `_distributed_le_totalReward` in WU R.14);
the rounding shortfall is not minted to anyone.  Deployments needing
different rounding (last-actor-gets-dust, dust-collector-actor) supply
their own variant.

Determinism note: relies on `Std.TreeMap.foldl`'s key-order iteration
(documented in `docs/std_dependencies.md`).

Classified `IsMonotonic` (each actor's balance non-decreases);
explicitly *not* `IsConservative` (when at least one non-excluded
actor has positive balance).

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation

open Std
open scoped Std.TreeMap

namespace LegalKernel
namespace Laws

/-! ## Definition (WU R.12) -/

/-- Proportional dilution at resource `r`, sparing `excluded`.

    * Precondition: `totalReward > 0 ∧ sumOthers s r excluded > 0`.
      The second conjunct rules out divide-by-zero in the proportional
      computation.
    * Effect: for each `(actor, balance)` in `bm := s.balances[r]?.getD
      ∅` with `actor ≠ excluded`, replace the balance with `balance +
      totalReward * balance / sumOthers s r excluded` (Nat floor).
      The excluded actor and absent actors are unchanged.

    Note: `S := sumOthers s r excluded` is captured *before* the foldl
    starts, so it remains constant across the iteration even though
    individual balances change. -/
def proportionalDilute
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) : Transition where
  pre        := fun s => totalReward > 0 ∧ sumOthers s r excluded > 0
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    let bm := s.balances[r]?.getD ∅
    let S  := sumOthers s r excluded
    let toReward := bm.toList.filter (fun kv => kv.1 != excluded)
    toReward.foldl
      (fun s' kv =>
        setBalance s' r kv.1 (getBalance s' r kv.1 + totalReward * kv.2 / S))
      s

/-- Sanity decidability witness for `proportionalDilute`'s precondition. -/
example (r : ResourceId) (excluded : ActorId) (totalReward : Amount) (s : State) :
    Decidable ((proportionalDilute r excluded totalReward).pre s) :=
  inferInstance

/-! ## Inductive helpers for the foldl-of-setBalance pattern

Mirror `Laws/DistributeOthers.lean`'s helpers but parametrised over an
*arbitrary per-step new-value function* `f : State → ActorId × Nat →
Nat` (since proportionalDilute's per-step new value is data-dependent
on the snapshotted balance, not a constant). -/

/-- A `foldl` of `setBalance s' r kv.1 (f s' kv)` calls at resource `r`
    does not touch the `BalanceMap` at any other resource `r' ≠ r`,
    regardless of `f`.  Same proof shape as
    `foldl_setBalance_other_resource_untouched` in DistributeOthers
    but generic over the per-step value. -/
private theorem foldl_setBalance_at_r_other_resource_untouched
    (xs : List (ActorId × Nat)) (s : State)
    (r r' : ResourceId) (f : State → (ActorId × Nat) → Nat) (h : r ≠ r') :
    (xs.foldl (fun s' kv => setBalance s' r kv.1 (f s' kv)) s).balances[r']?
      = s.balances[r']? := by
  induction xs generalizing s with
  | nil => rfl
  | cons hd tl ih =>
      simp only [List.foldl]
      rw [ih (setBalance s r hd.1 (f s hd))]
      show (s.balances.insert r ((s.balances[r]?.getD ∅).insert hd.1 (f s hd)))[r']?
         = s.balances[r']?
      exact RBMap.find?_insert_other _ r r' _ h

/-- A `foldl` of `setBalance s' r kv.1 (f s' kv)` calls preserves the
    excluded actor's balance, provided every key in the list differs
    from `excluded` (which the apply_impl guarantees by filtering). -/
private theorem foldl_setBalance_at_r_excluded_untouched
    (xs : List (ActorId × Nat)) (s : State)
    (r : ResourceId) (excluded : ActorId)
    (f : State → (ActorId × Nat) → Nat)
    (h : ∀ kv ∈ xs, kv.1 ≠ excluded) :
    getBalance (xs.foldl (fun s' kv => setBalance s' r kv.1 (f s' kv)) s) r excluded
      = getBalance s r excluded := by
  induction xs generalizing s with
  | nil => rfl
  | cons hd tl ih =>
      simp only [List.foldl]
      have h_hd : hd.1 ≠ excluded := h hd (List.mem_cons.mpr (Or.inl rfl))
      have h_tl : ∀ kv ∈ tl, kv.1 ≠ excluded :=
        fun kv hkv => h kv (List.mem_cons.mpr (Or.inr hkv))
      rw [ih (setBalance s r hd.1 (f s hd)) h_tl]
      -- Reduce both sides via getBalance/setBalance unfolds + insert lemmas.
      simp only [getBalance, setBalance,
                 RBMap.find?_insert_self,
                 RBMap.find?_insert_other _ hd.1 excluded _ h_hd]
      cases s.balances[r]? <;> rfl

/-! ## Cross-resource locality (WU R.12) -/

/-- State-level: the per-resource `BalanceMap` at `r' ≠ r` is unchanged
    by a (legal or rejected) `proportionalDilute` at `r`. -/
theorem proportionalDilute_other_resource_untouched
    (r r' : ResourceId) (excluded : ActorId) (totalReward : Amount)
    (s : State) (h : r ≠ r') :
    (step_impl s (proportionalDilute r excluded totalReward)).balances[r']? =
    s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (proportionalDilute r excluded totalReward).pre s
  · simp only [if_pos hpre]
    show (((proportionalDilute r excluded totalReward).apply_impl s)).balances[r']?
       = s.balances[r']?
    simp only [proportionalDilute]
    exact foldl_setBalance_at_r_other_resource_untouched _ s r r' _ h
  · simp only [if_neg hpre]

/-- Pointwise per-actor balance preservation at any `r' ≠ r`. -/
theorem proportionalDilute_does_not_touch_other_resources
    (r r' : ResourceId) (excluded : ActorId) (totalReward : Amount)
    (a : ActorId) (s : State) (h : r ≠ r') :
    getBalance (step_impl s (proportionalDilute r excluded totalReward)) r' a =
    getBalance s r' a := by
  unfold getBalance
  rw [proportionalDilute_other_resource_untouched r r' excluded totalReward s h]

/-- Conservation at any `r' ≠ r`. -/
theorem proportionalDilute_conserves_other_resource
    (r r' : ResourceId) (excluded : ActorId) (totalReward : Amount)
    (s : State) (h : r ≠ r') :
    TotalSupply (step_impl s (proportionalDilute r excluded totalReward)) r' =
    TotalSupply s r' := by
  unfold TotalSupply
  rw [proportionalDilute_other_resource_untouched r r' excluded totalReward s h]

/-- The headline "excluded actor is preserved" property at the diluted
    resource: even though every other actor's balance grows, the
    excluded actor's balance is exactly preserved. -/
theorem proportionalDilute_excluded_unchanged
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) (s : State)
    (hpre : (proportionalDilute r excluded totalReward).pre s) :
    getBalance (step_impl s (proportionalDilute r excluded totalReward)) r excluded =
    getBalance s r excluded := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((proportionalDilute r excluded totalReward).apply_impl s) r excluded
     = getBalance s r excluded
  simp only [proportionalDilute]
  apply foldl_setBalance_at_r_excluded_untouched
  intro kv hkv
  have := List.mem_filter.mp hkv
  intro heq
  have h_neq : (kv.1 != excluded) = true := this.2
  rw [heq] at h_neq
  simp at h_neq

/-! ## Supply equation (WU R.13) -/

/-- A `foldl` of `setBalance s' r kv.1 (getBalance s' r kv.1 + per-step
    increment)` increases `TotalSupply r` by the sum of the per-step
    increments.  Each step adds its own increment by
    `totalSupply_setBalance`; the sum unfolds via `Nat`-arithmetic. -/
private theorem foldl_setBalance_proportional_totalSupply
    (xs : List (ActorId × Nat)) (s : State) (r : ResourceId)
    (totalReward S : Nat) :
    TotalSupply
      (xs.foldl
        (fun s' kv =>
          setBalance s' r kv.1 (getBalance s' r kv.1 + totalReward * kv.2 / S)) s)
      r = TotalSupply s r + (xs.map (fun kv => totalReward * kv.2 / S)).sum := by
  induction xs generalizing s with
  | nil => simp
  | cons hd tl ih =>
      simp only [List.foldl, List.map, List.sum_cons]
      rw [ih (setBalance s r hd.1 (getBalance s r hd.1 + totalReward * hd.2 / S))]
      have h_step :
          TotalSupply
              (setBalance s r hd.1 (getBalance s r hd.1 + totalReward * hd.2 / S)) r
            = TotalSupply s r + totalReward * hd.2 / S := by
        have h := totalSupply_setBalance s r hd.1
                    (getBalance s r hd.1 + totalReward * hd.2 / S)
        omega
      rw [h_step]
      omega

/-- The supply equation for `proportionalDilute`: post-dilution supply
    at `r` equals pre-dilution supply plus the sum of floor-distributed
    amounts over non-excluded actors.

    The sum is bounded above by `totalReward` — the discarded "dust"
    accounts for the difference (proved as `_distributed_le_totalReward`
    in WU R.14). -/
theorem totalSupply_after_proportionalDilute
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) (s : State)
    (hpre : (proportionalDilute r excluded totalReward).pre s) :
    TotalSupply (step_impl s (proportionalDilute r excluded totalReward)) r =
    TotalSupply s r +
    ((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)
      |>.map (fun kv => totalReward * kv.2 / sumOthers s r excluded)).sum := by
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((proportionalDilute r excluded totalReward).apply_impl s) r = _
  simp only [proportionalDilute]
  exact foldl_setBalance_proportional_totalSupply _ s r totalReward _

end Laws
end LegalKernel

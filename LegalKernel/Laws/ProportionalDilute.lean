/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

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
import LegalKernel.DSL.LexLaw

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

/-! ## LX-M2 (LX.29) Lex re-expression of `proportionalDilute` -/

set_option linter.missingDocs false in
lexlaw legalkernel_proportionalDilute where
  lex_id              legalkernel.proportionalDilute
  lex_version         "1.0.0"
  lex_action_index    7
  lex_intent          "Proportionally dilute `excluded` by minting `totalReward * v_k / sumOthers` (Nat floor; dust discarded) to each non-excluded actor `k`.  The strongest analogue of 'burning excluded's balance share' available without removing tokens.  Classified `IsMonotonic`."
  lex_signed_by       deployer
  lex_authorized_by   (fun _ _ => True)
  lex_params          (r : ResourceId) (excluded : ActorId) (totalReward : Amount)
  lex_pre             := fun s => totalReward > 0 ∧ sumOthers s r excluded > 0
  lex_impl            :=
    fun s =>
      let bm := s.balances[r]?.getD ∅
      let S  := sumOthers s r excluded
      let toReward := bm.toList.filter (fun kv => kv.1 != excluded)
      toReward.foldl
        (fun s' kv =>
          setBalance s' r kv.1 (getBalance s' r kv.1 + totalReward * kv.2 / S))
        s
  -- Per plan §19.4 LX.29: `proportionalDilute` claims
  -- `monotonic` (every actor's balance can only increase or stay
  -- the same — Nat floor never decreases), `local`,
  -- `freeze_preserving`, `nonce_advances`, `registry_preserving`.
  -- NOT `conservative` (additive — distributes new tokens, with
  -- floor-division dust discarded per the
  -- `proportionalDilute_distributed_le_totalReward` dust bound).
  lex_satisfies       := [monotonic, «local», freeze_preserving,
                          nonce_advances, registry_preserving]
  lex_events          := []

/-- LX-M2 LX.29 byte-equivalence regression for `proportionalDilute`. -/
example (r : ResourceId) (excluded : ActorId) (totalReward : Amount) :
    legalkernel_proportionalDilute_transition r excluded totalReward =
    proportionalDilute r excluded totalReward := rfl

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
    amounts over non-excluded actors. -/
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

/-! ## Supply non-decrease bound (WU R.14: weak form) -/

/-- Supply at the diluted resource is non-decreasing.  Direct
    consequence of `totalSupply_after_proportionalDilute` plus the
    fact that the summed quantity is a sum of `Nat`s, hence ≥ 0.

    Subsumed by the stronger dust bound below
    (`_distributed_le_totalReward`), but kept as a stable identifier
    for `proportionalDilute_isMonotonic` consumers and for code that
    only needs the non-decrease direction. -/
theorem proportionalDilute_supply_nondecreasing
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) (s : State)
    (hpre : (proportionalDilute r excluded totalReward).pre s) :
    TotalSupply s r ≤
    TotalSupply (step_impl s (proportionalDilute r excluded totalReward)) r := by
  rw [totalSupply_after_proportionalDilute r excluded totalReward s hpre]
  exact Nat.le_add_right _ _

/-! ## Dust bound (WU R.14: full form) -/

/-- The per-element floor bound chained over a list: the sum of
    floor-divided quantities multiplied by the divisor is bounded
    above by the sum of the dividends.

    Per-element: `(totalReward * kv.2 / S) * S ≤ totalReward * kv.2`
    by `Nat.div_mul_le_self`.  Summing over the list (with `(a + b) *
    S = a * S + b * S` distributivity) and `(a + b) = totalReward * a'
    + totalReward * b'` distributivity gives the chain bound. -/
private theorem list_div_sum_mul_le
    (xs : List (ActorId × Nat)) (totalReward S : Nat) :
    ((xs.map (fun kv => totalReward * kv.2 / S)).sum) * S ≤
    totalReward * (xs.map (·.2)).sum := by
  induction xs with
  | nil => simp
  | cons hd tl ih =>
      simp only [List.map_cons, List.sum_cons]
      -- LHS: (totalReward * hd.2 / S + sum_tl) * S
      --     = totalReward * hd.2 / S * S + sum_tl * S
      -- RHS: totalReward * (hd.2 + tl_sum)
      --     = totalReward * hd.2 + totalReward * tl_sum
      have h_div : totalReward * hd.2 / S * S ≤ totalReward * hd.2 :=
        Nat.div_mul_le_self _ _
      rw [Nat.add_mul, Nat.mul_add]
      -- Goal: totalReward * hd.2 / S * S + sum_tl * S
      --     ≤ totalReward * hd.2 + totalReward * sum_tl
      -- by h_div and ih.
      omega

/-- The dust bound: `proportionalDilute`'s supply increase is bounded
    above by `totalReward`.  Together with
    `_supply_nondecreasing` this pins the increment to `[0,
    totalReward]`; the discarded dust accounts for the gap between the
    actual increment and `totalReward`.

    Proof structure:
    1. By `totalSupply_after_proportionalDilute` (R.13), reduce to
       `dist_sum ≤ totalReward`, where `dist_sum := sum_{kv ∈ filter}
       (totalReward * kv.2 / S)` and `S := sumOthers`.
    2. By `list_div_sum_mul_le`: `dist_sum * S ≤ totalReward *
       filter_sum_balances`.
    3. By `state_filter_sum_eq_sumOthers` (in `Conservation.lean`):
       `filter_sum_balances = S`.
    4. Substitute: `dist_sum * S ≤ totalReward * S`.
    5. Divide by `S > 0` (precondition): `dist_sum ≤ totalReward`. -/
theorem proportionalDilute_distributed_le_totalReward
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) (s : State)
    (hpre : (proportionalDilute r excluded totalReward).pre s) :
    TotalSupply (step_impl s (proportionalDilute r excluded totalReward)) r ≤
    TotalSupply s r + totalReward := by
  rw [totalSupply_after_proportionalDilute r excluded totalReward s hpre]
  apply Nat.add_le_add_left
  -- Goal: sum_{kv ∈ filter} (totalReward * kv.2 / sumOthers) ≤ totalReward
  have hS : sumOthers s r excluded > 0 := hpre.2
  have h_filter_sum := state_filter_sum_eq_sumOthers s r excluded
  have h_chain_bound :=
    list_div_sum_mul_le
      ((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded))
      totalReward (sumOthers s r excluded)
  -- h_chain_bound : dist_sum * S ≤ totalReward * filter_sum_balances
  rw [h_filter_sum] at h_chain_bound
  -- h_chain_bound : dist_sum * S ≤ totalReward * S
  exact Nat.le_of_mul_le_mul_right h_chain_bound hS

/-! ## Monotonicity classification (WU R.15) -/

/-- `proportionalDilute` is monotonic at every resource.  At the
    diluted resource, `proportionalDilute_supply_nondecreasing` (R.14)
    gives the result directly.  At any other resource, the
    `BalanceMap` is untouched and the supply is unchanged. -/
instance proportionalDilute_isMonotonic
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) :
    IsMonotonic (proportionalDilute r excluded totalReward) where
  monotone := by
    intro r' s hpre
    by_cases hr : r = r'
    · subst hr
      exact proportionalDilute_supply_nondecreasing r excluded totalReward s hpre
    · have h := proportionalDilute_conserves_other_resource r r' excluded totalReward s hr
      omega

/-! ## Non-conservation (WU R.15) -/

/-- `proportionalDilute` is *not* an `IsConservative` law.  Witness:
    `s := setBalance genesisState r non_excluded totalReward` for
    `non_excluded := if excluded = 0 then 1 else 0` (always distinct
    from `excluded`).  At `s`, the precondition holds (totalReward > 0
    and sumOthers = totalReward > 0), and the supply equation gives a
    strict increase.

    Concretely: the singleton filter `[(non_excluded, totalReward)]`
    contributes `totalReward * totalReward / totalReward = totalReward`
    to the post-supply, so post = pre + totalReward, contradicting
    conservation when `totalReward > 0`. -/
theorem proportionalDilute_not_conservative
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount)
    (hpos : totalReward > 0) :
    ¬ IsConservative (proportionalDilute r excluded totalReward) := by
  intro hcons
  let non_excluded : ActorId := if excluded = 0 then 1 else 0
  have h_neq : non_excluded ≠ excluded := by
    show (if excluded = 0 then (1 : ActorId) else (0 : ActorId)) ≠ excluded
    by_cases h : excluded = 0
    · rw [if_pos h, h]; decide
    · rw [if_neg h]; exact Ne.symm h
  -- Fixture: actor non_excluded holds totalReward at resource r.
  let s : State := setBalance genesisState r non_excluded totalReward
  have hT0 : TotalSupply s r = totalReward := by
    show TotalSupply (setBalance genesisState r non_excluded totalReward) r = totalReward
    have h := totalSupply_setBalance genesisState r non_excluded totalReward
    rw [totalSupply_genesis_eq_zero r] at h
    have hgen : getBalance genesisState r non_excluded = 0 := by
      show getBalance ({ balances := ∅ } : State) r non_excluded = 0
      simp [getBalance]
    rw [hgen] at h
    omega
  have h_get_excluded : getBalance s r excluded = 0 := by
    show getBalance (setBalance genesisState r non_excluded totalReward) r excluded = 0
    rw [getBalance_setBalance_other genesisState r r non_excluded excluded totalReward
          (Or.inr h_neq)]
    show getBalance ({ balances := ∅ } : State) r excluded = 0
    simp [getBalance]
  have h_sumOthers : sumOthers s r excluded = totalReward := by
    unfold sumOthers
    rw [hT0, h_get_excluded]
    simp
  have hpre : (proportionalDilute r excluded totalReward).pre s := by
    refine ⟨hpos, ?_⟩
    rw [h_sumOthers]
    exact hpos
  have hcons_r := hcons.conserves r s hpre
  have hpost := totalSupply_after_proportionalDilute r excluded totalReward s hpre
  -- Compute the filter explicitly: bm.toList = [(non_excluded, totalReward)],
  -- filter keeps the entry, and the per-step increment is totalReward * totalReward / totalReward = totalReward.
  -- This exact computation is delicate; instead, use the supply-nondecreasing bound to argue
  -- post ≥ pre + (something positive), and use the supply equation to make the "something" precise enough.
  -- The cleanest path: show the filter sum ≥ totalReward, then conclude post > pre.
  have h_lookup : (s.balances[r]?.getD ∅)[non_excluded]? = some totalReward := by
    show ((((∅ : Std.TreeMap ResourceId BalanceMap _).insert r
              (((∅ : Std.TreeMap ResourceId BalanceMap _)[r]?.getD ∅).insert
                non_excluded totalReward)))[r]?.getD ∅)[non_excluded]? = some totalReward
    rw [RBMap.find?_insert_self]
    simp only [Option.getD_some]
    exact RBMap.find?_insert_self _ _ _
  have h_mem : (non_excluded, totalReward) ∈ (s.balances[r]?.getD ∅).toList :=
    Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h_lookup
  have h_in_filter :
      (non_excluded, totalReward) ∈
        (s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded) := by
    apply List.mem_filter.mpr
    refine ⟨h_mem, ?_⟩
    simp [h_neq]
  -- (non_excluded, totalReward) contributes totalReward * totalReward / sumOthers = totalReward * totalReward / totalReward = totalReward to the sum.
  have h_increment_value :
      totalReward * totalReward / sumOthers s r excluded = totalReward := by
    rw [h_sumOthers]
    rw [Nat.mul_div_cancel _ hpos]
  -- Use h_in_filter and h_increment_value to bound the sum below by totalReward.
  -- The mapped list contains "totalReward" as one of its elements, so its sum ≥ totalReward.
  have h_mem_mapped :
      totalReward ∈
        ((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)).map
          (fun kv => totalReward * kv.2 / sumOthers s r excluded) := by
    apply List.mem_map.mpr
    refine ⟨(non_excluded, totalReward), h_in_filter, ?_⟩
    exact h_increment_value
  -- Length-positive ⟹ sum ≥ element ≥ totalReward.
  have h_sum_ge :
      totalReward ≤
        (((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)).map
          (fun kv => totalReward * kv.2 / sumOthers s r excluded)).sum :=
    LegalKernel.nat_le_sum_of_mem _ totalReward h_mem_mapped
  -- Now combine: hpost gives post = pre + sum; hcons_r gives post = pre.
  -- So sum = 0, contradicting h_sum_ge ≥ totalReward > 0.
  rw [hcons_r] at hpost
  -- hpost : pre = pre + sum, so sum = 0.
  have h_sum_zero :
      (((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)).map
          (fun kv => totalReward * kv.2 / sumOthers s r excluded)).sum = 0 := by
    have h : TotalSupply s r + 0 = TotalSupply s r +
        (((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)).map
          (fun kv => totalReward * kv.2 / sumOthers s r excluded)).sum := by
      rw [Nat.add_zero]; exact hpost
    exact (Nat.add_left_cancel h).symm
  -- totalReward ≤ sum = 0 ⟹ totalReward = 0, contradicting hpos.
  rw [h_sum_zero] at h_sum_ge
  exact absurd (Nat.le_zero.mp h_sum_ge) (Nat.pos_iff_ne_zero.mp hpos)

/-! ## Workstream LX (LX.3) — `LocalTo` instance + freeze-preservation theorem -/

/-- `proportionalDilute r …` is `LocalTo [r]`. -/
instance proportionalDilute_localTo
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) :
    LocalTo [r] (proportionalDilute r excluded totalReward) where
  local_to := by
    intro r' a s hr_not_in _
    have hne : r ≠ r' := by
      intro heq
      apply hr_not_in
      rw [← heq]
      exact List.mem_singleton.mpr rfl
    exact proportionalDilute_does_not_touch_other_resources r r' excluded
            totalReward a s hne

/-- `proportionalDilute r …` preserves freeze for any resource set
    `S` not containing `r`. -/
theorem proportionalDilute_freezePreserving
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount)
    (S : List ResourceId) (h : r ∉ S) :
    FreezePreserving S (proportionalDilute r excluded totalReward) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne : r' ≠ r := by
      intro heq
      apply h
      rw [← heq]
      exact hr'
    rw [proportionalDilute_other_resource_untouched r r' excluded totalReward s
          (Ne.symm hne)]
    exact h_init

/-- Vacuous-case `FreezePreserving []` instance for
    `proportionalDilute`. -/
instance proportionalDilute_freezePreserving_empty
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) :
    FreezePreserving [] (proportionalDilute r excluded totalReward) :=
  proportionalDilute_freezePreserving r excluded totalReward [] (by simp)

end Laws
end LegalKernel

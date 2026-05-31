-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.RBMapLemmas — the §8.3 ordered-map proof library.

Genesis Plan §8.3 ("RBMap Proof Library") records a small library of
TreeMap lemmas that the kernel and laws rely on for stating and proving
balance lemmas (§4.3) and conservation theorems (§5.3, §5.6).  The
section title preserves the original `RBMap` name from the std4 era;
the underlying data structure in this codebase is `Std.Data.TreeMap`
from Lean core.

This module is **part of the trusted computing base**: the kernel
imports it (so its statements and proofs are part of every kernel proof
that uses them), and laws import it (so their conservation arguments
chain through these lemmas).  The two-reviewer rule of Genesis Plan
§13.6 / CLAUDE.md "Two reviewer rule" therefore covers any change to
this file.

Imports: `Std.Data.TreeMap` only.  Adding any other dependency expands
the TCB and triggers the §13.6 amendment process.

Coverage map (Phase 1 work units):

  * WU 1.1 — `find?_insert_self`, `find?_insert_other`
  * WU 1.2 — `sumValues_insert_absent` (k ∉ m case)
  * WU 1.3 — `sumValues_insert_present` (m[k]? = some v_old case, additive
              form to avoid `Nat`-subtraction asymmetry)
  * WU 1.4 — `sumValues_eq_values_sum` (canonical "sum-of-values" form,
              order-independent because `m.values` is determined by `m`)

The fold lemmas are stated for the specific `Nat`-summing fold
(`fun acc _ v => acc + v`).  This is the only fold the Phase-2
`TotalSupply` invariant uses (Genesis Plan §8.1, §5.3); a more general
treatment of arbitrary commutative monoids is deferred until a
non-`Nat` quantity functional first appears in a law.
-/

import Std.Data.TreeMap

open Std
-- Bring the scoped `~m` notation (defined in `namespace Std.TreeMap`) into
-- scope.  We do *not* `open Std.TreeMap` because that would also import all
-- of the non-`scoped` definitions and shadow names like `insert`.
open scoped Std.TreeMap

namespace LegalKernel
namespace RBMap

universe u v

/-! ## Pointwise insert lemmas (§8.3 / WU 1.1)

The two `insert` accessor lemmas below are the gateway to the §4.3
balance lemmas.  Both are direct re-exports of `Std.TreeMap` lemmas,
matching the §8.3 spec's note that "in practice these may already be
in `Std`; if so, this WU becomes a re-export plus a small audit". -/

variable {κ : Type u} {α : Type v} {cmp : κ → κ → Ordering}

/-- After inserting `v` at `k`, the lookup at `k` is `some v`.

    §8.3 spec: `(m.insert k v).find? k = some v`.  Re-exported from
    `Std.TreeMap.getElem?_insert_self`; the Genesis-Plan name
    `find?_insert_self` is preserved for continuity with the spec. -/
theorem find?_insert_self [TransCmp cmp]
    (m : TreeMap κ α cmp) (k : κ) (v : α) :
    (m.insert k v)[k]? = some v :=
  TreeMap.getElem?_insert_self

/-- After inserting `v` at `k`, the lookup at any other key `k'` is
    unchanged.

    §8.3 spec: `(m.insert k v).find? k' = m.find? k'` when `k ≠ k'`.
    Reduces `Std.TreeMap.getElem?_insert` (which case-splits on
    `cmp k k' = .eq`) to the `else` branch via the
    `LawfulEqCmp.compare_eq_iff_eq` characterisation. -/
theorem find?_insert_other [TransCmp cmp] [LawfulEqCmp cmp]
    (m : TreeMap κ α cmp) (k k' : κ) (v : α) (h : k ≠ k') :
    (m.insert k v)[k']? = m[k']? := by
  rw [TreeMap.getElem?_insert]
  have : cmp k k' ≠ .eq := fun he => h (LawfulEqCmp.eq_of_compare he)
  simp [this]

/-! ## Sum aggregator (helper for §8.3 fold lemmas)

`sumValues` is the canonical `Nat`-summing fold over a `TreeMap` value
column.  Phase 2's `TotalSupply` (Genesis Plan §8.1) is exactly
`sumValues` applied to a per-resource `BalanceMap`.  Defining it once
here lets the fold lemmas (WU 1.2 – 1.4) refer to a stable name rather
than re-stating the fold expression at every call site. -/

/-- Sum of all values in a `TreeMap`-keyed `Nat` column, ignoring keys.

    Equivalent to `(m.toList.map (·.snd)).foldl (· + ·) 0` (see
    `sumValues_eq_values_sum` below) and to the multiset of values. -/
def sumValues (m : TreeMap κ Nat cmp) : Nat :=
  m.foldl (fun acc _ v => acc + v) 0

/-! ### Bridge to list level (helpers for the §8.3 fold lemmas)

Every fold lemma below proceeds by reducing `sumValues` to a `List`
expression, manipulating the list, then folding back.  The helpers
below are the only places where we touch `Std.TreeMap.foldl_eq_foldl_toList`
and `Std.TreeMap.toList_insert_perm`. -/

/-- `sumValues` factors through `toList`.  This is `foldl_eq_foldl_toList`
    specialised to the `Nat`-sum aggregator, with the unused key projection
    discarded. -/
theorem sumValues_eq_toList_sum (m : TreeMap κ Nat cmp) :
    sumValues m = (m.toList.map (·.snd)).foldl (· + ·) 0 := by
  unfold sumValues
  rw [TreeMap.foldl_eq_foldl_toList]
  -- Both sides fold the same list; the LHS reads the value via `b.snd`,
  -- the RHS via the projected value list.  Generalising the accumulator
  -- makes the IH apply at every step.
  generalize m.toList = l
  suffices h : ∀ (acc : Nat),
      l.foldl (fun a b => a + b.snd) acc =
      (l.map (·.snd)).foldl (· + ·) acc by
    exact h 0
  intro acc
  induction l generalizing acc with
  | nil      => rfl
  | cons _ _ ih =>
      simp only [List.foldl, List.map_cons]
      exact ih _

/-- §8.3 / WU 1.4: `sumValues` equals the natural-number `List.sum` of
    the value column.  This is the canonical "sum-over-values" form
    that downstream conservation arguments rely on; because
    `m.toList` is uniquely determined by `m` (under `[TransCmp cmp]`),
    the right-hand side is order-independent.

    Reduces to `Std.List.sum_eq_foldl_nat` (Lean core's
    `Init.Data.List.Nat.Sum`) once the kernel-level fold has been
    bridged to `List.foldl` via `foldl_eq_foldl_toList`. -/
theorem sumValues_eq_values_sum (m : TreeMap κ Nat cmp) :
    sumValues m = (m.toList.map (·.snd)).sum := by
  rw [sumValues_eq_toList_sum, ← List.sum_eq_foldl_nat]

/-! ## Fold-after-insert lemmas (§8.3 / WU 1.2 – 1.3)

The two fold-after-insert lemmas reduce the post-insert sum to the pre-insert
sum plus (or minus) an "old value" contribution.  Their proofs:

1. Apply `Std.TreeMap.toList_insert_perm` to rewrite
   `(m.insert k v).toList` as a permutation of
   `⟨k, v⟩ :: m.toList.filter (¬ k == ·.1)`.
2. Sum-of-values is permutation-invariant for `Nat` (`List.Perm.sum_nat`).
3. The remaining task is to relate
   `((m.toList.filter (¬ k == ·.1)).map (·.snd)).sum`
   to `(m.toList.map (·.snd)).sum` under the appropriate hypothesis.

The `[BEq κ]` and `[LawfulBEq κ]` constraints are what `toList_insert_perm`
needs at the list level (the filter predicate is `(¬k == ·.1)`); together
with `[LawfulEqCmp cmp]` they let us convert between `cmp k k' = .eq`,
`k == k'`, and `k = k'` freely.  For the kernel's `BalanceMap` (with
`UInt64` keys), all four classes are derivable from Lean core. -/

/-- §8.3 / WU 1.2: when `k ∉ m`, the post-insert sum exceeds the
    pre-insert sum by exactly `v`. -/
theorem sumValues_insert_absent
    [BEq κ] [LawfulBEq κ] [TransCmp cmp] [LawfulEqCmp cmp]
    (m : TreeMap κ Nat cmp) (k : κ) (v : Nat) (h : ¬ k ∈ m) :
    sumValues (m.insert k v) = sumValues m + v := by
  rw [sumValues_eq_values_sum, sumValues_eq_values_sum]
  have hperm :
      (m.insert k v).toList.Perm
        (⟨k, v⟩ :: m.toList.filter (fun x => decide ¬(k == x.fst) = true)) :=
    TreeMap.toList_insert_perm
  have hfilter :
      m.toList.filter (fun x => decide ¬(k == x.fst) = true) = m.toList := by
    apply List.filter_eq_self.mpr
    intro p hp
    simp only [decide_eq_true_eq]
    intro hbeq
    apply h
    rcases p with ⟨pk, pv⟩
    have hk : k = pk := LawfulBEq.eq_of_beq hbeq
    rw [hk, TreeMap.mem_iff_isSome_getElem?,
        TreeMap.mem_toList_iff_getElem?_eq_some.mp hp]
    rfl
  rw [hfilter] at hperm
  have hperm_vals :
      ((m.insert k v).toList.map (·.snd)).Perm (v :: m.toList.map (·.snd)) := by
    have := hperm.map (·.snd)
    simpa using this
  rw [hperm_vals.sum_nat]
  simp [List.sum_cons]
  omega

/-! ### WU 1.3 prep: equivalence-based machinery

The "key already present" fold lemma is reduced to WU 1.2 by an
equivalence argument: when `m[k]? = some v_old`, `m` agrees pointwise
with `(m.erase k).insert k v_old`, so they are `~m`-equivalent and
fold to the same value.  Likewise `m.insert k v_new` agrees pointwise
with `(m.erase k).insert k v_new`.  Both right-hand sides are insertions
into `m.erase k`, where `k` is *absent*, so `sumValues_insert_absent`
applies. -/

/-- Two TreeMaps that agree on every `getElem?` query are `~m`-equivalent.
    Built on `Std.DTreeMap.Equiv.of_forall_constGet?_eq`: once we lift the
    pointwise lookup equality to the underlying `DTreeMap`, the
    `TreeMap.Equiv` constructor wraps the inner equivalence. -/
private theorem equiv_of_getElem_eq [TransCmp cmp] [LawfulEqCmp cmp]
    (m₁ m₂ : TreeMap κ α cmp)
    (h : ∀ k : κ, m₁[k]? = m₂[k]?) :
    m₁ ~m m₂ :=
  ⟨DTreeMap.Equiv.of_forall_constGet?_eq h⟩

/-- `sumValues` is invariant under TreeMap equivalence.  This is just
    `Std.TreeMap.Equiv.foldl_eq` specialised to the `Nat`-sum aggregator. -/
theorem sumValues_of_equiv [TransCmp cmp]
    {m₁ m₂ : TreeMap κ Nat cmp} (h : m₁ ~m m₂) :
    sumValues m₁ = sumValues m₂ := by
  unfold sumValues
  exact TreeMap.Equiv.foldl_eq h

/-- Inserting at a key that is already present is equivalent to erasing
    that key first and then inserting.  Pointwise check: at `k`, both
    sides give `some v`; at `k' ≠ k`, both sides give `m[k']?`. -/
private theorem insert_equiv_erase_insert [TransCmp cmp] [LawfulEqCmp cmp]
    (m : TreeMap κ α cmp) (k : κ) (v : α) :
    m.insert k v ~m (m.erase k).insert k v := by
  apply equiv_of_getElem_eq
  intro k'
  by_cases hk : cmp k k' = .eq
  · -- Both sides are `some v` at k = k'.
    rw [TreeMap.getElem?_insert, TreeMap.getElem?_insert]
    simp [hk]
  · -- Both sides reduce to `m[k']?` because cmp k k' ≠ .eq.
    rw [TreeMap.getElem?_insert, TreeMap.getElem?_insert,
        TreeMap.getElem?_erase]
    simp [hk]

/-- When `m[k]? = some v_old`, `m` is equivalent to `(m.erase k).insert k v_old`.
    Pointwise check: at `k`, LHS = some v_old, RHS = some v_old; at
    `k' ≠ k`, both sides give `m[k']?`. -/
private theorem self_equiv_erase_insert [TransCmp cmp] [LawfulEqCmp cmp]
    (m : TreeMap κ α cmp) (k : κ) (v_old : α) (h : m[k]? = some v_old) :
    m ~m (m.erase k).insert k v_old := by
  apply equiv_of_getElem_eq
  intro k'
  by_cases hk : cmp k k' = .eq
  · -- LHS: m[k']?.  Since cmp k k' = .eq, by getElem?_congr, m[k']? = m[k]? = some v_old.
    -- RHS: ((m.erase k).insert k v_old)[k']? = some v_old (insert at the same equiv key).
    rw [TreeMap.getElem?_insert]
    simp [hk]
    rw [TreeMap.getElem?_congr (a := k) (b := k') hk] at h
    exact h
  · -- LHS: m[k']?.
    -- RHS: ((m.erase k).insert k v_old)[k']? = (m.erase k)[k']? = m[k']? (k' not erased).
    rw [TreeMap.getElem?_insert, TreeMap.getElem?_erase]
    simp [hk]

/-- After erasing `k`, the key `k` is no longer present.  Used to
    discharge the `k ∉ m'` precondition of `sumValues_insert_absent`
    when `m' = m.erase k`. -/
private theorem not_mem_erase_self [TransCmp cmp]
    (m : TreeMap κ α cmp) (k : κ) :
    ¬ k ∈ m.erase k := by
  rw [TreeMap.mem_iff_isSome_getElem?, TreeMap.getElem?_erase_self]
  simp

/-- §8.3 / WU 1.3: when `m[k]? = some v_old`, the new sum plus the *old*
    contribution at `k` equals the old sum plus the *new* contribution.
    This additive form avoids `Nat`-subtraction asymmetries while
    capturing the same accounting identity as the §8.3 spec's
    "differs by `v_new - v_old`" formulation.

    Special case `v_new = 0`, `v_old > 0`: an "erase-then-set-to-zero"
    decreases the sum by exactly `v_old`. -/
theorem sumValues_insert_present
    [BEq κ] [LawfulBEq κ] [TransCmp cmp] [LawfulEqCmp cmp]
    (m : TreeMap κ Nat cmp) (k : κ) (v_old v_new : Nat)
    (h : m[k]? = some v_old) :
    sumValues (m.insert k v_new) + v_old = sumValues m + v_new := by
  -- Reduce both sides to insertions on `m.erase k`, where k is absent.
  have hm := self_equiv_erase_insert m k v_old h
  have hi := insert_equiv_erase_insert m k v_new
  rw [sumValues_of_equiv hm, sumValues_of_equiv hi]
  -- Both sides now insert at k into (m.erase k); k ∉ m.erase k.
  rw [sumValues_insert_absent (m.erase k) k v_new (not_mem_erase_self m k),
      sumValues_insert_absent (m.erase k) k v_old (not_mem_erase_self m k)]
  -- Goal: sumValues (m.erase k) + v_new + v_old = sumValues (m.erase k) + v_old + v_new
  omega

end RBMap
end LegalKernel

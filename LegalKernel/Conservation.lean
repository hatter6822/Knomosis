/-
LegalKernel.Conservation — the §8.1 / §5.3 economic-invariants framework.

This module is the load-bearing part of Phase 2 (Economic Invariants).
It defines the per-resource `TotalSupply` quantity functional (§8.1),
the `IsConservative` typeclass that classifies a `Transition` as
supply-preserving (§5.3 / §5.6), the `ConservativeLawSet` structure
that lifts that classification to deployment-level law sets, and the
`total_supply_global` theorem that concludes per-resource conservation
for every state reachable through such a law set.

The module is **not** part of the trusted computing base.  Its
definitions and theorems are stated against the kernel's TCB primitives
(`State`, `setBalance`, `step_impl`, `ReachableViaLaws`,
`invariant_preservation_via_laws`) and the §8.3 RBMap library
(`sumValues`, `sumValues_insert_absent`, `sumValues_insert_present`).
A bug in this file could only invalidate a *deployment-level* claim
about supply conservation; it cannot violate any kernel invariant.
The §13.6 two-reviewer rule therefore does not apply (one reviewer
suffices); CI still runs `count_sorries` over this file because it
sits under `LegalKernel/`.

Coverage map (Phase 2 work units):

  * WU 2.1 — `TotalSupply` definition + `totalSupply_genesis_eq_zero`
              and `totalSupply_eq_zero_of_no_resource` sanity lemmas.
  * WU 2.4 — `IsConservative` typeclass.
  * WU 2.7 — `ConservativeLawSet` structure; `Mint`/`Burn` excluded by
              typing because no `IsConservative` instance exists.
  * WU 2.8 — `total_supply_global` (§5.3 verbatim) and
              `total_supply_global_via_law_set` (typeclass-driven form).

The master `setBalance`-on-`TotalSupply` accounting lemma
(`totalSupply_setBalance`) lives here too because every law that
mutates a balance-shaped State chains through it; isolating it here
keeps each per-law conservation proof short.
-/

import LegalKernel.Kernel
import LegalKernel.RBMapLemmas

open Std
open scoped Std.TreeMap

namespace LegalKernel

/-! ## Genesis state (§8.6) -/

/-- The canonical genesis state: no resource carries any actor balance.
    Every `getBalance _ _` query against `genesisState` returns `0`.
    Identical in content to the `LegalKernel.Test.emptyState` fixture
    used by the test suites; defined here so non-test code (notably the
    Phase-2 non-conservation witnesses for `mint` and `burn`) can
    reference a fully-determined initial state without depending on the
    test framework. -/
def genesisState : State := { balances := ∅ }

/-! ## Total supply (§8.1) -/

/-- Per-resource total supply: the sum of every actor's balance for a
    fixed resource.  Defined as a fold over the per-resource
    `BalanceMap`; the fold is order-independent because `RBMap.sumValues`
    factors through `toList` (see `RBMap.sumValues_eq_values_sum` in
    the §8.3 library).

    Returns `0` when the resource has no entry at all.  This matches
    the convention that "an actor not in the map" reads as zero
    balance (§4.3): the per-actor `0`-balance and the per-resource
    `0`-supply are both consequences of the same finite-map convention. -/
def TotalSupply (s : State) (r : ResourceId) : Nat :=
  match s.balances[r]? with
  | none    => 0
  | some bm => RBMap.sumValues bm

/-! ### Sanity lemmas (§8.1 / WU 2.1) -/

/-- WU 2.1 acceptance criterion: the genesis state has zero supply at
    every resource.  Direct consequence of `genesisState.balances` being
    `∅`; the outer-level lookup returns `none`, which is the `0`
    branch of `TotalSupply`. -/
theorem totalSupply_genesis_eq_zero (r : ResourceId) :
    TotalSupply genesisState r = 0 := by
  unfold TotalSupply genesisState
  simp

/-- More general companion to the genesis lemma: any state that has no
    entry for `r` at the outer-map level has `0` total supply for `r`.
    Used by `transfer_conserves` to discharge the "fresh resource"
    boundary case. -/
theorem totalSupply_eq_zero_of_no_resource
    (s : State) (r : ResourceId) (h : s.balances[r]? = none) :
    TotalSupply s r = 0 := by
  unfold TotalSupply
  rw [h]

/-! ## The master `setBalance` accounting lemma (§4.3 ↔ §8.1)

`setBalance` is the only operation in the kernel that mutates a
balance, so every conservation proof reduces to a chain of
`setBalance` rewrites.  The master lemma below states the *exact*
quantity the per-resource sum changes by, in additive form (to
sidestep `Nat`-subtraction asymmetries):

    TotalSupply (setBalance s r a v) r + getBalance s r a
  = TotalSupply s r + v

i.e. the new sum plus the *old* balance at `(r, a)` equals the old
sum plus the *new* balance.  Specialising to `v = old + amount` gives
"sum increases by amount"; specialising to `v = old - amount` gives
"sum decreases by amount" (under `amount ≤ old`).  Both `transfer`
(debit + credit) and `mint` / `burn` (single delta) reduce to this
identity by application of `omega` to a small linear system.

The proof case-splits on the four combinations of "resource present /
absent" and "actor present / absent", deferring the heavy lifting to
the §8.3 fold-after-insert lemmas. -/

private theorem sumValues_emptyc :
    RBMap.sumValues (∅ : BalanceMap) = 0 := by
  unfold RBMap.sumValues
  rw [TreeMap.foldl_eq_foldl_toList]
  -- (∅).toList.isEmpty = (∅).isEmpty = true ⇒ (∅).toList = []
  have hempty : ((∅ : BalanceMap).toList).isEmpty = true := by
    rw [TreeMap.isEmpty_toList]; exact TreeMap.isEmpty_emptyc
  have hnil : (∅ : BalanceMap).toList = [] := List.isEmpty_iff.mp hempty
  rw [hnil]
  rfl

/-- §4.3 / §8.1 master lemma: `setBalance` shifts the per-resource sum
    by exactly `v - getBalance s r a`, in the additive form
    `new_sum + old_balance = old_sum + new_balance`.

    Proof outline.  Unfold `setBalance` and `getBalance`; the outer
    `s.balances.insert r bm'` resolves at `r` to `some bm'` via
    `RBMap.find?_insert_self`.  Then case-split on whether `s` already
    had a per-resource map at `r`:

    1. `s.balances[r]? = none`: the inner map is `∅`, the new map is a
       singleton, `getBalance s r a = 0`, `TotalSupply s r = 0`, and
       the equation reduces to `v = v`.
    2. `s.balances[r]? = some bm`: case-split on `bm[a]?`:
       - `none`: `getBalance s r a = 0`; `sumValues_insert_absent`
         gives the post-insert sum as `sumValues bm + v`.
       - `some v_old`: `getBalance s r a = v_old`;
         `sumValues_insert_present` gives the additive identity
         `sumValues (bm.insert a v) + v_old = sumValues bm + v`. -/
theorem totalSupply_setBalance
    (s : State) (r : ResourceId) (a : ActorId) (v : Nat) :
    TotalSupply (setBalance s r a v) r + getBalance s r a =
    TotalSupply s r + v := by
  unfold TotalSupply setBalance getBalance
  -- Reduce the outer-level lookup at r in the inserted map to `some bm'`.
  rw [show (s.balances.insert r ((s.balances[r]?.getD ∅).insert a v))[r]?
        = some ((s.balances[r]?.getD ∅).insert a v)
      from RBMap.find?_insert_self s.balances r _]
  -- Case-split on the original outer-level lookup at r.
  cases hr : s.balances[r]? with
  | none =>
      -- bm = ∅; bm[a]? = none.  sumValues (∅.insert a v) = v.
      simp only [Option.getD_none]
      have hmem : ¬ a ∈ (∅ : BalanceMap) := by simp
      rw [RBMap.sumValues_insert_absent (∅ : BalanceMap) a v hmem,
          sumValues_emptyc]
      omega
  | some bm =>
      -- bm = the existing map.  Case on bm[a]?.
      simp only [Option.getD_some]
      cases ha : bm[a]? with
      | none =>
          -- getBalance reads as 0; sumValues_insert_absent applies.
          have hmem : ¬ a ∈ bm := by
            rw [TreeMap.mem_iff_isSome_getElem?, ha]; simp
          rw [RBMap.sumValues_insert_absent bm a v hmem]
          simp
      | some v_old =>
          -- getBalance reads as v_old; sumValues_insert_present applies.
          have hpresent := RBMap.sumValues_insert_present bm a v_old v ha
          simp only [Option.getD_some]
          omega

/-! ## `IsConservative` typeclass (§5.3 / WU 2.4) -/

/-- A transition that preserves total supply for every resource at
    every state where its precondition holds.

    The typeclass shape (rather than a plain predicate) lets law
    instances be discovered automatically when constructing
    `ConservativeLawSet` values: a deployment that adds a new
    conservative law need only provide the `IsConservative` instance
    once and the typeclass will resolve it in every later use site.

    By contrast, mint / burn cannot be promoted to `IsConservative`
    instances because no such instance exists (and `mint_not_conservative`
    / `burn_not_conservative` prove the negation explicitly), so the
    typeclass also serves as a *type-level firewall* against accidental
    mixing of supply-preserving and supply-changing laws. -/
class IsConservative (t : Transition) : Prop where
  /-- The conservation obligation: for every resource `r` and every
      state `s` in which `t.pre` holds, applying `t` leaves
      `TotalSupply` at `r` unchanged. -/
  conserves : ∀ (r : ResourceId) (s : State),
              t.pre s →
              TotalSupply (step_impl s t) r = TotalSupply s r

/-! ## `sumOthers` (positive-incentive helper) -/

/-- Total supply at `r` excluding actor `excluded`'s holding.  Used by
    `proportionalDilute` precondition reasoning (`pre := totalReward >
    0 ∧ sumOthers > 0`) and by the dust-bound theorem.

    Truncated `Nat` subtraction is safe because `getBalance s r
    excluded ≤ TotalSupply s r` (proved by `getBalance_le_totalSupply`
    below). -/
def sumOthers (s : State) (r : ResourceId) (excluded : ActorId) : Nat :=
  TotalSupply s r - getBalance s r excluded

/-! ## `getBalance` is bounded by `TotalSupply` (positive-incentive
    helper) -/

/-- A single element of a `Nat` list is bounded by the list's sum.
    Standard inductive lemma; not in Lean core under this name (the
    closest core lemma is `min_mul_length_le_sum_nat`), so we prove it
    directly.

    Public because `Laws/DistributeOthers.lean` and
    `Laws/ProportionalDilute.lean` both consume it for their
    not-conservative witnesses. -/
theorem nat_le_sum_of_mem (xs : List Nat) (n : Nat) (h : n ∈ xs) :
    n ≤ xs.sum := by
  induction xs with
  | nil => simp at h
  | cons hd tl ih =>
      cases h with
      | head _ =>
          rw [List.sum_cons]
          exact Nat.le_add_right _ _
      | tail _ h' =>
          have := ih h'
          rw [List.sum_cons]
          exact Nat.le_trans this (Nat.le_add_left _ _)

/-- Any single actor's balance at resource `r` is bounded by the total
    supply at `r`.  Used by `proportionalDilute` precondition reasoning
    and by the dust-bound theorem (`_distributed_le_totalReward`).

    Proof: reduce both sides to operations on `s.balances[r]?.getD ∅`,
    case-split on whether the actor has an entry, and either `0 ≤ _` or
    appeal to `nat_le_sum_of_mem` via `RBMap.sumValues_eq_values_sum`. -/
theorem getBalance_le_totalSupply
    (s : State) (r : ResourceId) (a : ActorId) :
    getBalance s r a ≤ TotalSupply s r := by
  unfold TotalSupply getBalance
  cases hbm : s.balances[r]? with
  | none =>
      -- `getBalance` reads as `0`; `TotalSupply` reads as `0`.  `0 ≤ 0`.
      simp
  | some bm =>
      -- Case-split on whether the actor's entry exists.
      simp
      cases ha : bm[a]? with
      | none =>
          -- `getBalance` reads as `0`; `0 ≤ anything`.
          simp
      | some v =>
          -- `getBalance` reads as `v`; need `v ≤ sumValues bm`.
          simp
          rw [RBMap.sumValues_eq_values_sum]
          have h_mem : (a, v) ∈ bm.toList :=
            (Std.TreeMap.mem_toList_iff_getElem?_eq_some).mpr ha
          have h_v_in : v ∈ bm.toList.map (·.snd) := by
            apply List.mem_map.mpr
            exact ⟨(a, v), h_mem, rfl⟩
          exact nat_le_sum_of_mem _ v h_v_in

/-! ## Filter-sum lemmas for the `proportionalDilute` dust bound -/

/-- Partition lemma: for any predicate `p`, the sum of values in
    `xs.filter p` plus the sum of values in `xs.filter (¬p)` equals
    the sum of values in `xs`.

    Used by `filter_sum_plus_lookup_eq_sumValues` to split a
    `BalanceMap`'s sum into "non-excluded" and "excluded" portions. -/
private theorem list_partition_sum_by_key
    (xs : List (ActorId × Nat)) (k : ActorId) :
    ((xs.filter (fun kv => kv.1 != k)).map (·.2)).sum +
    ((xs.filter (fun kv => kv.1 == k)).map (·.2)).sum =
    (xs.map (·.2)).sum := by
  induction xs with
  | nil => simp
  | cons hd tl ih =>
      cases h : (hd.1 == k) with
      | true =>
          -- hd matches k: filter (== k) keeps hd, filter (!= k) drops hd.
          have h_neq : (hd.1 != k) = false := by unfold bne; rw [h]; rfl
          have h_filt_eq : (hd :: tl).filter (fun kv => kv.1 == k) =
                           hd :: tl.filter (fun kv => kv.1 == k) :=
            @List.filter_cons_of_pos (ActorId × Nat) (fun kv => kv.1 == k) hd tl h
          have h_filt_neq : (hd :: tl).filter (fun kv => kv.1 != k) =
                            tl.filter (fun kv => kv.1 != k) :=
            @List.filter_cons_of_neg (ActorId × Nat) (fun kv => kv.1 != k) hd tl
              (by simp [h_neq])
          rw [h_filt_eq, h_filt_neq]
          simp only [List.map_cons, List.sum_cons]
          omega
      | false =>
          -- hd doesn't match: filter (!= k) keeps hd, filter (== k) drops hd.
          have h_neq : (hd.1 != k) = true := by unfold bne; rw [h]; rfl
          have h_filt_eq : (hd :: tl).filter (fun kv => kv.1 == k) =
                           tl.filter (fun kv => kv.1 == k) :=
            @List.filter_cons_of_neg (ActorId × Nat) (fun kv => kv.1 == k) hd tl
              (by simp [h])
          have h_filt_neq : (hd :: tl).filter (fun kv => kv.1 != k) =
                            hd :: tl.filter (fun kv => kv.1 != k) :=
            @List.filter_cons_of_pos (ActorId × Nat) (fun kv => kv.1 != k) hd tl h_neq
          rw [h_filt_eq, h_filt_neq]
          simp only [List.map_cons, List.sum_cons]
          omega

/-- List-level helper: a list with distinct keys (Pairwise non-equal
    by `.1`) and a known member `(k, v)` has its `(.1 == k)`-filter
    equal to the singleton `[(k, v)]`.

    Proof by induction on the list, using the pairwise-distinctness
    hypothesis at each step.  Used by
    `balanceMap_filter_eq_sum_eq_lookup` after converting TreeMap's
    `compare`-based distinctness to `≠`-based distinctness. -/
private theorem list_filter_eq_singleton_of_distinct
    (xs : List (ActorId × Nat)) (k : ActorId) (v : Nat)
    (h_mem : (k, v) ∈ xs)
    (h_distinct : xs.Pairwise (fun a b => a.1 ≠ b.1)) :
    xs.filter (fun kv => kv.1 == k) = [(k, v)] := by
  induction xs with
  | nil => simp at h_mem
  | cons hd tl ih =>
      cases h_hd : (hd.1 == k) with
      | true =>
          -- hd has key k.
          have h_hd_key : hd.1 = k := by simpa using h_hd
          rcases List.mem_cons.mp h_mem with h_kv_eq_hd | h_kv_in_tl
          · -- (k, v) = hd.  Show filter (·.1 == k) keeps only hd; tl contributes [].
            -- After rw, hd becomes (k, v).
            rw [← h_kv_eq_hd]
            have h_filt : ((k, v) :: tl).filter (fun kv => kv.1 == k) =
                          (k, v) :: tl.filter (fun kv => kv.1 == k) :=
              @List.filter_cons_of_pos (ActorId × Nat) (fun kv => kv.1 == k) (k, v) tl
                (by simp)
            rw [h_filt]
            congr 1
            -- tl.filter (·.1 == k) = []
            apply List.filter_eq_nil_iff.mpr
            intro kv hkv hbeq
            have h_kv_key : kv.1 = k := by simpa using hbeq
            have h_pw : ∀ b ∈ tl, ((k, v) : ActorId × Nat).1 ≠ b.1 := by
              have h_pw_orig : ∀ b ∈ tl, hd.1 ≠ b.1 :=
                (List.pairwise_cons.mp h_distinct).1
              rw [← h_kv_eq_hd] at h_pw_orig
              exact h_pw_orig
            apply h_pw kv hkv
            show k = kv.1
            exact h_kv_key.symm
          · -- (k, v) ∈ tl AND hd has key k: distinctness contradiction.
            exfalso
            have h_pw : ∀ b ∈ tl, hd.1 ≠ b.1 :=
              (List.pairwise_cons.mp h_distinct).1
            exact h_pw (k, v) h_kv_in_tl h_hd_key
      | false =>
          -- hd doesn't have key k.  Must have (k, v) ∈ tl; recurse.
          have h_filt : (hd :: tl).filter (fun kv => kv.1 == k) =
                        tl.filter (fun kv => kv.1 == k) :=
            @List.filter_cons_of_neg (ActorId × Nat) (fun kv => kv.1 == k) hd tl
              (by simp [h_hd])
          rw [h_filt]
          have h_kv_in_tl : (k, v) ∈ tl := by
            rcases List.mem_cons.mp h_mem with h_kv_eq_hd | h_in_tl
            · exfalso
              -- (k, v) = hd ⟹ hd.1 = k, contradicting h_hd : (hd.1 == k) = false.
              have : hd.1 = k := by rw [← h_kv_eq_hd]
              rw [this] at h_hd
              exact Bool.noConfusion (h_hd.symm.trans (beq_self_eq_true k))
            · exact h_in_tl
          exact ih h_kv_in_tl (List.pairwise_cons.mp h_distinct).2

/-- TreeMap's `distinct_keys_toList` is stated in terms of `compare ≠
    .eq`; convert to the `≠`-based form for the list helper above.
    For `LawfulEqCmp` types (which `ActorId = UInt64` satisfies),
    `compare a b = .eq ↔ a = b`, so the two formulations are
    equivalent. -/
private theorem balanceMap_toList_distinct (bm : BalanceMap) :
    bm.toList.Pairwise (fun a b => a.1 ≠ b.1) := by
  have h := Std.TreeMap.distinct_keys_toList (t := bm)
  apply List.Pairwise.imp _ h
  intro a b h_cmp h_eq
  apply h_cmp
  rw [h_eq]
  exact Std.ReflCmp.compare_self

/-- For a `TreeMap`-derived list (with distinct keys), the sum of
    values whose key equals `k` equals the lookup at `k` (or `0` if
    absent).  Proof:
    * `none`: no entry has key `k`, so the filter is empty.
    * `some v`: distinctness + membership give that the filter is
      exactly `[(k, v)]` via `list_filter_eq_singleton_of_distinct`. -/
private theorem balanceMap_filter_eq_sum_eq_lookup
    (bm : BalanceMap) (k : ActorId) :
    ((bm.toList.filter (fun kv => kv.1 == k)).map (·.2)).sum =
    bm[k]?.getD 0 := by
  cases h : bm[k]? with
  | none =>
      -- bm[k]? = none ⟹ no entry in toList has key k ⟹ filter is empty.
      simp only [Option.getD_none]
      have h_no_mem : ∀ kv ∈ bm.toList, kv.1 ≠ k := by
        intro kv hkv heq
        have h_kv_lookup : bm[kv.1]? = some kv.2 :=
          Std.TreeMap.mem_toList_iff_getElem?_eq_some.mp hkv
        rw [heq, h] at h_kv_lookup
        -- h_kv_lookup : none = some kv.2; impossible.
        cases h_kv_lookup
      have h_filter_nil :
          bm.toList.filter (fun kv => kv.1 == k) = [] := by
        apply List.filter_eq_nil_iff.mpr
        intro kv hkv hbeq
        exact h_no_mem kv hkv (by simpa using hbeq)
      rw [h_filter_nil]; simp
  | some v =>
      simp only [Option.getD_some]
      have h_mem : (k, v) ∈ bm.toList :=
        Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h
      have h_distinct := balanceMap_toList_distinct bm
      have h_filter_singleton :
          bm.toList.filter (fun kv => kv.1 == k) = [(k, v)] :=
        list_filter_eq_singleton_of_distinct bm.toList k v h_mem h_distinct
      rw [h_filter_singleton]
      simp

/-- The headline filter-sum identity: for any `BalanceMap` and any key
    `k`, the sum of values at non-`k` keys plus the lookup at `k`
    equals `sumValues bm`.  Combines the partition lemma with the
    "filter (·.1 == k) sum equals lookup" lemma above.

    When applied to `bm := s.balances[r]?.getD ∅`, this gives the
    bridge from the `proportionalDilute` filter to `sumOthers`:
    filter_sum + getBalance s r excluded = TotalSupply s r. -/
private theorem balanceMap_filter_sum_plus_lookup
    (bm : BalanceMap) (k : ActorId) :
    ((bm.toList.filter (fun kv => kv.1 != k)).map (·.2)).sum + bm[k]?.getD 0 =
    RBMap.sumValues bm := by
  rw [RBMap.sumValues_eq_values_sum]
  rw [← balanceMap_filter_eq_sum_eq_lookup bm k]
  exact list_partition_sum_by_key bm.toList k

/-- State-level form of `balanceMap_filter_sum_plus_lookup`: the sum
    of non-excluded balances at `r` equals `sumOthers s r excluded`.

    Bridges the `proportionalDilute` apply_impl's `bm.toList.filter`
    expression to `sumOthers s r excluded` (the precondition's
    divisor), via the per-`bm` filter-sum identity above plus
    case-split on the resource's outer-map presence. -/
theorem state_filter_sum_eq_sumOthers
    (s : State) (r : ResourceId) (excluded : ActorId) :
    (((s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)).map (·.2)).sum =
    sumOthers s r excluded := by
  -- Apply the per-bm identity to bm := s.balances[r]?.getD ∅.
  have h_id := balanceMap_filter_sum_plus_lookup (s.balances[r]?.getD ∅) excluded
  -- Bridge: sumValues (s.balances[r]?.getD ∅) = TotalSupply s r.
  have h_sv : RBMap.sumValues (s.balances[r]?.getD ∅) = TotalSupply s r := by
    unfold TotalSupply
    cases s.balances[r]? with
    | none =>
        -- LHS: sumValues (none.getD ∅) = sumValues ∅ = 0.  RHS: 0.
        unfold RBMap.sumValues
        rfl
    | some bm =>
        -- LHS: sumValues (some bm).getD ∅ = sumValues bm.  RHS: sumValues bm.
        rfl
  -- Bridge: (s.balances[r]?.getD ∅)[excluded]?.getD 0 = getBalance s r excluded.
  have h_get : (s.balances[r]?.getD ∅)[excluded]?.getD 0 = getBalance s r excluded := by
    unfold getBalance
    cases s.balances[r]? with
    | none => rfl
    | some bm => rfl
  rw [h_sv, h_get] at h_id
  -- h_id : filter_sum + getBalance s r excluded = TotalSupply s r.
  -- Goal (after unfold sumOthers) : filter_sum = TotalSupply s r - getBalance s r excluded.
  -- `Nat.eq_sub_of_add_eq` applies directly; the truncated-subtraction safety condition
  -- (`getBalance s r excluded ≤ TotalSupply s r`, witnessed by
  -- `getBalance_le_totalSupply`) is implicit in `h_id`'s additive form.
  unfold sumOthers
  exact Nat.eq_sub_of_add_eq h_id

/-! ## `IsMonotonic` typeclass (positive-incentive tier) -/

/-- A transition that *never decreases* the total supply at any
    resource where its precondition holds.  Strictly weaker than
    `IsConservative`: every conservative law is monotonic (witnessed by
    `monotonic_of_conservative` below), but the converse fails (mint /
    reward / distributeOthers / proportionalDilute all produce strict
    increases).

    The typeclass shape, mirroring `IsConservative`, lets law instances
    be discovered automatically when constructing `MonotonicLawSet`
    values, and serves as a *type-level firewall* against accidental
    inclusion of strictly-decreasing laws (`burn` cannot inhabit
    `IsMonotonic`; `burn_not_monotonic` proves the negation
    explicitly). -/
class IsMonotonic (t : Transition) : Prop where
  /-- The monotonicity obligation: for every resource `r` and every
      state `s` in which `t.pre` holds, applying `t` does not decrease
      `TotalSupply` at `r`. -/
  monotone : ∀ (r : ResourceId) (s : State),
             t.pre s →
             TotalSupply s r ≤ TotalSupply (step_impl s t) r

/-- Every conservative law is automatically monotonic: equality is a
    special case of `≤`.

    Declared at low priority so that per-law explicit `IsMonotonic`
    instances (e.g. `transfer_isMonotonic`, `mint_isMonotonic`) win
    typeclass resolution unambiguously when both options exist.  The
    explicit instances ship for two reasons: (i) clearer error
    messages at use sites, (ii) deployments that drop `IsConservative`
    for a law without losing monotonicity get a stable identifier. -/
instance (priority := low) monotonic_of_conservative
    {t : Transition} [hc : IsConservative t] : IsMonotonic t where
  monotone := fun r s hpre => Nat.le_of_eq (hc.conserves r s hpre).symm

/-! ## Conservation invariants and law-set machinery -/

/-- Closure-form of "the supply at `r₀` equals `target`"; matches the
    Genesis Plan §5.3 style of stating an *equality* as the quantity
    that the inductive step preserves. -/
def TotalSupplyEquals (r₀ : ResourceId) (target : Nat) (s : State) : Prop :=
  TotalSupply s r₀ = target

/-- A law set restricted to conservative transitions.  Structure rather
    than `Subtype` so that the membership-witness field is easy to
    reference in proofs (`cls.isConservative t htL`).

    Mint / burn cannot inhabit this structure: constructing a
    `ConservativeLawSet` requires an `IsConservative` instance for
    every list element, and no such instance exists for `mint` / `burn`
    (proved by `mint_not_conservative` / `burn_not_conservative` in
    `Laws/Mint.lean` and `Laws/Burn.lean`). -/
structure ConservativeLawSet where
  /-- The transitions admitted by the deployment. -/
  laws : List Transition
  /-- Per-element conservation witness.  The deployment must surrender
      an `IsConservative` instance for every law it admits; mint / burn
      cannot satisfy this. -/
  isConservative : ∀ t ∈ laws, IsConservative t

/-! ## The `total_supply_global` theorem (§5.3 / WU 2.8) -/

/-- §5.3 verbatim: per-resource total supply is preserved across every
    state reachable through a law set whose every element preserves
    supply at the resource of interest.

    The hypothesis `h_conservative` is *per-resource*: a deployment can
    instantiate this theorem with a partially-conservative law set, as
    long as the law set conserves the *specific* resource `r₀` named
    by the invariant.  Phase 2 is mostly interested in the
    fully-conservative case, captured by the
    `total_supply_global_via_law_set` corollary below. -/
theorem total_supply_global
    (r₀ : ResourceId) (target : Nat)
    (s0 : State) (h_init : TotalSupplyEquals r₀ target s0)
    (laws : List Transition)
    (h_conservative :
      ∀ t ∈ laws, ∀ s, t.pre s →
        TotalSupply (step_impl s t) r₀ = TotalSupply s r₀) :
    ∀ s, ReachableViaLaws laws s0 s → TotalSupplyEquals r₀ target s := by
  apply invariant_preservation_via_laws (TotalSupplyEquals r₀ target) laws s0 h_init
  intro t htL s hI hpre
  unfold TotalSupplyEquals at *
  rw [h_conservative t htL s hpre]
  exact hI

/-- Typeclass-driven corollary of `total_supply_global`: a deployment
    that supplies a `ConservativeLawSet` gets per-resource conservation
    for every resource and every reachable state, "for free".

    This is the form a §13.7 deployment proof typically uses: discharge
    the local `IsConservative` instances per-law (already done for
    `transfer`), assemble them into a `ConservativeLawSet`, then
    invoke this theorem at every relevant resource. -/
theorem total_supply_global_via_law_set
    (r₀ : ResourceId) (target : Nat)
    (s0 : State) (h_init : TotalSupplyEquals r₀ target s0)
    (cls : ConservativeLawSet) :
    ∀ s, ReachableViaLaws cls.laws s0 s → TotalSupplyEquals r₀ target s := by
  apply total_supply_global r₀ target s0 h_init cls.laws
  intro t htL s hpre
  exact (cls.isConservative t htL).conserves r₀ s hpre

/-! ## Monotonic law-set machinery (positive-incentive tier) -/

/-- A law set restricted to monotonic transitions.  Strictly larger
    than `ConservativeLawSet`: every conservative law is also monotonic
    (via `monotonic_of_conservative`), but laws that strictly increase
    supply (`mint`, `reward`, `distributeOthers`, `proportionalDilute`)
    can also inhabit `MonotonicLawSet` while being excluded from
    `ConservativeLawSet`.

    `burn` cannot inhabit this structure: `burn_not_monotonic` (in
    `Laws/Burn.lean`) proves no `IsMonotonic` instance for `burn`
    exists. This is the type-level firewall for "positive-only"
    deployments. -/
structure MonotonicLawSet where
  /-- The transitions admitted by the deployment. -/
  laws : List Transition
  /-- Per-element monotonicity witness.  Every law surrenders an
      `IsMonotonic` instance; `burn` cannot. -/
  isMonotonic : ∀ t ∈ laws, IsMonotonic t

/-- Per-resource non-decrease across reachable states under a per-law
    monotonicity hypothesis.  The headline guarantee of the
    positive-incentive tier: if every law in a deployment leaves
    `TotalSupply` at `r₀` non-decreasing, then no reachable state has
    less supply at `r₀` than the initial state.

    The hypothesis is *per-resource*: a deployment can instantiate this
    theorem with a partially-monotonic law set, as long as the law set
    leaves the *specific* resource `r₀` non-decreasing.  Most
    deployments will use the typeclass-driven
    `total_supply_globally_nondecreasing_via_law_set` corollary below. -/
theorem total_supply_globally_nondecreasing
    (r₀ : ResourceId) (s0 : State)
    (laws : List Transition)
    (h_monotone :
      ∀ t ∈ laws, ∀ s, t.pre s →
        TotalSupply s r₀ ≤ TotalSupply (step_impl s t) r₀) :
    ∀ s, ReachableViaLaws laws s0 s →
         TotalSupply s0 r₀ ≤ TotalSupply s r₀ := by
  apply invariant_preservation_via_laws
    (fun s => TotalSupply s0 r₀ ≤ TotalSupply s r₀) laws s0
  · exact Nat.le_refl _
  · intro t htL s hI hpre
    exact Nat.le_trans hI (h_monotone t htL s hpre)

/-- Typeclass-driven corollary of `total_supply_globally_nondecreasing`:
    a deployment that supplies a `MonotonicLawSet` gets per-resource
    non-decrease for every resource and every reachable state, "for
    free".  Parallels `total_supply_global_via_law_set` exactly. -/
theorem total_supply_globally_nondecreasing_via_law_set
    (r₀ : ResourceId) (s0 : State) (mls : MonotonicLawSet) :
    ∀ s, ReachableViaLaws mls.laws s0 s →
         TotalSupply s0 r₀ ≤ TotalSupply s r₀ := by
  apply total_supply_globally_nondecreasing r₀ s0 mls.laws
  intro t htL s hpre
  exact (mls.isMonotonic t htL).monotone r₀ s hpre

end LegalKernel

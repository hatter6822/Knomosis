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

end LegalKernel

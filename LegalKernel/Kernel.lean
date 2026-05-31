-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Kernel — the trusted core.

This module is the literal Section 4.12 listing of the Genesis Plan
(`docs/GENESIS_PLAN.md`), augmented with the §4.3 balance lemmas
(Phase 1 WU 1.5) and the §4.9 multi-step / law-set reachability
extensions (Phase 1 WU 1.7 – 1.9).  Every line in this file is part
of the trusted computing base (TCB) of every deployment that uses
Knomosis, so changes here MUST come with a Genesis-Plan amendment and
the two-reviewer gate described in §13.6 / §14.4.

Imports: `Std.Data.TreeMap` (the canonical ordered finite-map in
Lean core ≥ 4.10) and `LegalKernel.RBMapLemmas` (the §8.3 RBMap
proof library, also part of the TCB).  The Genesis Plan was written
when std4 still exposed `Std.Data.RBMap`; the modern equivalent in
Lean core is the `TreeMap` family in the same `Std` namespace, with
a red-black tree backing and the same API surface used by §4.3 and
§4.11 (insert, get?, foldl, getD).  The plan's "kernel uses `Std`
only" rule is preserved verbatim; the only deviation is the
project-internal `RBMapLemmas` import, itself bounded to Std-core
imports and therefore not a TCB expansion beyond Lean core.

No `sorry` may appear in this file.  The two balance lemmas of §4.3
(`getBalance_setBalance_same`, `getBalance_setBalance_other`) are
proved here in Phase 1 (WU 1.5) using the §8.3 insert lemmas from
`LegalKernel.RBMapLemmas` (WU 1.1).

Non-TCB definitions (build identification strings, runtime helpers)
live in adjacent modules — see `LegalKernel.lean` for the umbrella
that re-exports the trusted core.
-/

import Std.Data.TreeMap
import LegalKernel.RBMapLemmas

open Std

namespace LegalKernel

/-! ## Type universe (§4.1) -/

/-- Opaque identifier for an actor (key, account, principal). -/
abbrev ActorId    : Type := UInt64

/-- Opaque identifier for a resource (asset, currency, registry). -/
abbrev ResourceId : Type := UInt64

/-- Non-negative balance.  Using `Nat` makes overflow absence a
    theorem (rather than an audit), at the cost of unbounded
    serialised width — see §8.8 for the canonical encoding. -/
abbrev Amount     : Type := Nat

/-! ## State (§4.2) -/

/-- Per-resource map from actor → balance.  Empty entries denote zero
    balance. -/
abbrev BalanceMap : Type := TreeMap ActorId Amount compare

/-- Global state: a two-level finite map from resource → actor →
    amount.  See §4.2 for the rationale (per-resource reasoning,
    deterministic fold for hashing). -/
structure State where
  /-- Outer map: resource → per-resource balance map.  Missing
      resources have empty balance maps; missing actors within an
      existing resource have zero balance. -/
  balances : TreeMap ResourceId BalanceMap compare
  deriving Repr

/-! ## Balance operations (§4.3) -/

/-- Read a balance.  Missing entries at either level return `0`. -/
def getBalance (s : State) (r : ResourceId) (a : ActorId) : Amount :=
  match s.balances[r]? with
  | none    => 0
  | some bm => bm[a]?.getD 0

/-- Write a balance, allocating an empty per-resource map if needed.
    `setBalance` is deliberately total: partiality lives in the
    transition's precondition, never in the state-transformer. -/
def setBalance (s : State) (r : ResourceId) (a : ActorId) (v : Amount) :
    State :=
  let bm  := s.balances[r]?.getD ∅
  let bm' := bm.insert a v
  { balances := s.balances.insert r bm' }

/-! ### Balance lemmas (§4.3 / Phase 1 WU 1.5)

Reading back the balance you just wrote yields exactly the value you
wrote (`..._same`); reading back any *other* balance — by either
resource or actor — leaves the source state unchanged
(`..._other`).  Together these are the two equations §4.3 calls "the
gateway to all higher-level invariants": every conservation,
non-negativity, and isolation argument in laws and downstream
invariants is a consequence of these two facts plus the transition
shape.

The proofs proceed by direct application of the §8.3 insert lemmas
(`RBMap.find?_insert_self` and `RBMap.find?_insert_other`) at the
appropriate level of the two-level `BalanceMap` structure. -/

/-- §4.3 / WU 1.5: writing then reading at the same `(r, a)` returns
    the value written.  Proof: the outer `s.balances.insert r bm'`
    makes `(s.balances.insert r bm')[r]? = some bm'`; the inner
    `bm.insert a v` makes `bm'[a]? = some v`.

    Both reductions go through `RBMap.find?_insert_self` (WU 1.1);
    the `simp` call locates the `getElem?_insert_self` lemma it
    re-exports automatically because that lemma is `@[simp]`. -/
theorem getBalance_setBalance_same
    (s : State) (r : ResourceId) (a : ActorId) (v : Amount) :
    getBalance (setBalance s r a v) r a = v := by
  -- Both accessors unfold; both `insert` lookups simplify by Std's
  -- `getElem?_insert_self` (the lemma `RBMap.find?_insert_self` exports).
  simp [getBalance, setBalance]

/-- §4.3 / WU 1.5: writing at `(r, a)` leaves `(r', a')` unchanged
    whenever the two pairs differ in *some* coordinate.  The
    disjunctive hypothesis matches the §4.3 statement exactly: equal
    pairs are forbidden by `r ≠ r' ∨ a ≠ a'`, and the proof
    case-splits on which coordinate provides the inequality. -/
theorem getBalance_setBalance_other
    (s : State) (r r' : ResourceId) (a a' : ActorId) (v : Amount)
    (h : r ≠ r' ∨ a ≠ a') :
    getBalance (setBalance s r a v) r' a' = getBalance s r' a' := by
  unfold getBalance setBalance
  rcases h with hr | ha
  · -- Different resource: outer insert at `r` doesn't touch `r'`.
    rw [RBMap.find?_insert_other s.balances r r' _ hr]
  · -- Same resource (possibly), different actor.
    by_cases hr : r = r'
    · -- `r = r'`: the outer match enters the `some` branch with the freshly
      --   inserted `bm'`; the inner insert at `a` doesn't touch `a' ≠ a`.
      subst hr
      simp only [RBMap.find?_insert_self, RBMap.find?_insert_other _ a a' _ ha]
      -- Goal: (s.balances[r]?.getD ∅)[a']?.getD 0
      --     = match s.balances[r]? with | none => 0 | some bm => bm[a']?.getD 0
      cases hr : s.balances[r]? <;> simp
    · -- `r ≠ r'`: outer insert at `r` is invisible to a lookup at `r'`.
      rw [RBMap.find?_insert_other s.balances r r' _ hr]

/-! ## Transitions (§4.4) -/

/-- A transition is a precondition, a per-state decision procedure for
    that precondition, and a total state transformer.

    * `pre` is in `Prop` so that quantifiers, implications, and
      existence statements compose without `Bool`-coding artefacts.
    * `decPre` is the *constructive* witness that `pre` is effectively
      decidable on every state — without it, `step_impl` could not
      reduce.  For all laws built from arithmetic comparisons and
      finite conjunctions, `decPre := fun _ => inferInstance` is a
      one-liner; see §13.6 for the discipline.
    * `apply_impl` is total.  Pre-image filtering is the
      precondition's job, not the transformer's. -/
structure Transition where
  /-- The precondition under which the transition is admissible.
      Lives in `Prop` so that quantifiers and propositional connectives
      compose naturally. -/
  pre        : State → Prop
  /-- A per-state decision procedure for the precondition.  Without
      this field the executable path of the kernel cannot reduce; with
      it, `step_impl` is definable without ambient classical logic. -/
  decPre     : (s : State) → Decidable (pre s)
  /-- The state transformer.  Total by construction; partiality is
      reified in `pre`. -/
  apply_impl : State → State

/-- Re-export the per-state decidability witness as a typeclass
    instance so that ordinary `if t.pre s then ... else ...` notation
    elaborates without explicit annotations.  This is a *definition*,
    not a trusted axiom; deleting it would only make `if`-elaboration
    fail at the call site. -/
instance (t : Transition) (s : State) : Decidable (t.pre s) :=
  t.decPre s

/-! ## Specification and implementation (§4.5) -/

/-- Relational specification: `s'` is an admissible successor of `s`
    under `t` exactly when `t.pre` holds in `s` and `s'` matches the
    transformer's output. -/
def step_spec (s s' : State) (t : Transition) : Prop :=
  t.pre s ∧ s' = t.apply_impl s

/-- Executable implementation.  Decidability of `t.pre s` flows from
    the typeclass instance registered above, so the `if` reduces with
    no recourse to ambient classical logic. -/
def step_impl (s : State) (t : Transition) : State :=
  if t.pre s then t.apply_impl s else s

/-! ## Refinement theorems (§4.6) -/

/-- Implementation refines specification when the precondition holds:
    every step we actually take is one the spec permits. -/
theorem impl_refines_spec
    (s : State) (t : Transition) (h : t.pre s) :
    step_spec s (step_impl s t) t := by
  unfold step_impl step_spec
  simp [h]

/-- Implementation is the identity when the precondition fails: no
    silent partial-state corruption is possible. -/
theorem impl_noop_if_not_pre
    (s : State) (t : Transition) (h : ¬ t.pre s) :
    step_impl s t = s := by
  unfold step_impl
  simp [h]

/-! ## Proof-carrying legality (§4.7) -/

/-- A proof that `t` is legal in `s`.  Single-field by design: by
    proof-irrelevance, any two `Legal s t` values are definitionally
    equal once `t.pre s` holds. -/
structure Legal (s : State) (t : Transition) where
  /-- The proof witness that `t.pre s` holds in this state.  Erased
      at extraction; carrying it costs zero runtime bytes. -/
  proof : t.pre s

/-- A transition together with a proof of legality in a fixed state.
    The dependent index `s` prevents the obvious mistake of carrying
    a certificate across an unrelated state change. -/
structure CertifiedTransition (s : State) where
  /-- The transition being certified. -/
  t    : Transition
  /-- The legality witness for `t` at the indexed state `s`. -/
  cert : Legal s t

/-! ## Certified execution (§4.8) -/

/-- Trusted execution: takes the dependent witness and applies the
    transformer directly, with no runtime check. -/
def apply_certified (s : State) (ct : CertifiedTransition s) : State :=
  ct.t.apply_impl s

/-- The certified path agrees with the executable path in every state
    where the latter would have applied the transition.  This means
    `apply_certified` is an *optimisation* of `step_impl`, not a
    separate semantics. -/
theorem apply_certified_eq_step_impl
    (s : State) (ct : CertifiedTransition s) :
    apply_certified s ct = step_impl s ct.t := by
  unfold apply_certified step_impl
  simp [ct.cert.proof]

/-! ## Reachability (§4.9) -/

/-- States reachable from `s0` via a finite sequence of legal steps.
    The `step` constructor builds on `step_impl` (not `apply_impl`),
    so even hypothetical illegal applications cannot extend the
    reachable set. -/
inductive Reachable (s0 : State) : State → Prop
  /-- The initial state is reachable from itself. -/
  | base : Reachable s0 s0
  /-- If `s` is reachable from `s0` and `t.pre s` holds, then the
      executable step `step_impl s t` is also reachable from `s0`. -/
  | step (s : State) (t : Transition)
      (hreach : Reachable s0 s)
      (hpre   : t.pre s) :
      Reachable s0 (step_impl s t)

/-! ## Invariant preservation (§4.10) -/

/-- The central theorem of the kernel: any predicate that holds in the
    initial state and is preserved by every legal step holds in every
    reachable state.  Proving a global property reduces to proving
    *local* preservation, which scales linearly with `(laws ×
    invariants)` rather than combinatorially. -/
theorem invariant_preservation
    (I : State → Prop) (s0 : State)
    (h_init : I s0)
    (h_step : ∀ s t, I s → t.pre s → I (step_impl s t)) :
    ∀ s, Reachable s0 s → I s := by
  intro s h
  induction h with
  | base                       => exact h_init
  | step s t _hreach hpre ih   => exact h_step s t ih hpre

/-- Conjunction of invariants is itself an invariant; deployments can
    reason about a *list* of invariants without re-proving each
    pairwise combination. -/
theorem invariants_compose
    (I₁ I₂ : State → Prop) (s0 : State)
    (hi₁ : I₁ s0) (hi₂ : I₂ s0)
    (hs₁ : ∀ s t, I₁ s → t.pre s → I₁ (step_impl s t))
    (hs₂ : ∀ s t, I₂ s → t.pre s → I₂ (step_impl s t)) :
    ∀ s, Reachable s0 s → (I₁ s ∧ I₂ s) := by
  apply invariant_preservation (fun s => I₁ s ∧ I₂ s) s0
  · exact ⟨hi₁, hi₂⟩
  · intro s t ⟨h₁, h₂⟩ hpre
    exact ⟨hs₁ s t h₁ hpre, hs₂ s t h₂ hpre⟩

/-! ## Multi-step reachability properties (§4.9 / Phase 1 WU 1.7)

The `Reachable` relation defined above is *already* the
reflexive-transitive closure of single-step reachability — `base`
gives reflexivity, and `step` extends an existing reachability
witness by one legal transition.  WU 1.7 records the two derived
properties that downstream proofs rely on: reflexivity (a state is
reachable from itself with no transitions) and transitivity
(reachability composes across an intermediate state). -/

/-- §4.9 / WU 1.7: every state is reachable from itself.  Identical
    in content to `Reachable.base`; provided here under a more
    suggestive name for use in chains and for symmetry with the
    transitivity statement below. -/
theorem Reachable.refl (s : State) : Reachable s s :=
  Reachable.base

/-- §4.9 / WU 1.7: reachability composes.  If `s'` is reachable from
    `s` and `s''` is reachable from `s'`, then `s''` is reachable from
    `s`.  Proof: induct on the second hypothesis; the base case
    returns the first hypothesis, and the step case extends the
    inductive witness by one transition. -/
theorem Reachable.trans {s s' s'' : State}
    (h₁ : Reachable s s') (h₂ : Reachable s' s'') :
    Reachable s s'' := by
  induction h₂ with
  | base                              => exact h₁
  | step s_mid t _hreach hpre ih      =>
      exact Reachable.step s_mid t ih hpre

/-! ## Per-law-set reachability (§4.9 / Phase 1 WU 1.8 – 1.9)

`ReachableViaLaws L` restricts the executable step to transitions
drawn from a specific law set `L : List Transition`.  Together with
`invariant_preservation_via_laws`, this lets a deployment reason
*specifically* about the laws it admits: properties that fail under
the unrestricted `Reachable` relation may still hold under
`ReachableViaLaws`, as long as the offending laws aren't in the
deployed set.

The §5.3 conservation argument is the canonical example: `transfer`
preserves total supply, but `mint` does not — the
`total_supply_global` theorem (Genesis Plan §5.3) is therefore
parametrised on a `ReachableViaLaws conservativeLaws` rather than
the unrestricted `Reachable`. -/

/-- States reachable from `s0` using only transitions in `L`.
    Strict subset (in general) of `Reachable s0`: a state is
    `ReachableViaLaws L`-reachable iff it has a witness whose every
    `step` invokes a transition in `L`. -/
inductive ReachableViaLaws (L : List Transition) (s0 : State) : State → Prop
  /-- The initial state is reachable via the empty execution. -/
  | base : ReachableViaLaws L s0 s0
  /-- If `s` is reachable via `L`, `t ∈ L`, and `t.pre s` holds, then
      `step_impl s t` is also reachable via `L`. -/
  | step (s : State) (t : Transition)
      (htL : t ∈ L)
      (hreach : ReachableViaLaws L s0 s)
      (hpre   : t.pre s) :
      ReachableViaLaws L s0 (step_impl s t)

/-- §4.9 / WU 1.8: `ReachableViaLaws L` is a strict-subset version of
    the unrestricted `Reachable` relation: any state reachable via the
    law set `L` is reachable simpliciter.  Proof: induct on the
    `ReachableViaLaws` witness, mapping each constructor to the
    corresponding `Reachable` constructor (and discarding the `t ∈ L`
    premise the unrestricted form does not need). -/
theorem reachable_of_reachable_via_laws
    {L : List Transition} {s0 s : State}
    (h : ReachableViaLaws L s0 s) :
    Reachable s0 s := by
  induction h with
  | base                              => exact Reachable.base
  | step s t _htL _hreach hpre ih    =>
      exact Reachable.step s t ih hpre

/-- §4.10 / Phase 1 WU 1.9: invariant preservation indexed by a law
    set.  The hypothesis `h_step` need only consider transitions in
    `L`, which is exactly the scope a deployment of `L` requires.
    Combined with `total_supply_global` (Genesis Plan §5.3), this is
    what lets conservation arguments range over the *deployed* laws
    rather than every conceivable transition. -/
theorem invariant_preservation_via_laws
    (I : State → Prop) (L : List Transition) (s0 : State)
    (h_init : I s0)
    (h_step : ∀ t ∈ L, ∀ s, I s → t.pre s → I (step_impl s t)) :
    ∀ s, ReachableViaLaws L s0 s → I s := by
  intro s h
  induction h with
  | base                              => exact h_init
  | step s t htL _hreach hpre ih      =>
      exact h_step t htL s ih hpre

end LegalKernel

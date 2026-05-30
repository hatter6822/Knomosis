-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.StateInjective — Encoder injectivity (EI.2) for the
`State` / `BalanceMap` codec.

Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.2).  The
load-bearing nested-map sub-state of the project's canonical encoding
discipline: `State.balances : TreeMap ResourceId BalanceMap` is the
*only* two-level map in the codec, and EI.2 establishes the
framing-then-outer-map proof pattern that EI.3 – EI.7 specialise to
flat-map carriers.

This file ships:

  * **EI.2.a** `BalanceMap.encode_injective` — inner-map injectivity
    (equal bytes ⇒ extensional `TreeMap.Equiv` on the inner map).
    Specialises `encodeSortedPairs_injective_bounded` to `(Nat,
    Amount)` and lifts the projected-key equality through
    `UInt64.toNat_inj`.

  * **EI.2.b** `BalanceMap.encode_injective_to_equiv` — explicit
    `Equiv`-shaped alias.  EI.2.a already concludes `Equiv` directly,
    so EI.2.b collapses to a documentation-only re-export of the
    headline name.

  * **EI.2.c** `BalanceMap.encodeAsBytes_injective` — framing
    injectivity for the byte-wrapped inner encoder.  Direct
    application of the byte-level structure-injection argument
    (mirrors `encodeAsBytes_equiv_injective_of_encode_equiv_injective`
    in `Encoding/State.lean`).

  * **EI.2.d** `State.Equiv` + `State.encode_injective` — the
    headline nested theorem.  Equal `State.encode` bytes imply
    `State.Equiv s₁ s₂`, a custom relation that captures
    "outer-key sets agree AND per-resource inner `BalanceMap`s are
    `Equiv`-equivalent".  The custom relation is necessary because
    the inner `BalanceMap`s are themselves only extensionally —
    not structurally — equal (`Std.TreeMap.Equiv` on the outer
    `balances` map would require structural `Eq` on inner
    `BalanceMap`s, which is strictly stronger than what byte-
    equality of the canonical encoding implies).

All theorems are **conditional** on canonical-encoding bounds
(`< 2^64`) on list lengths and `Nat`-valued payload sizes — the
underlying `nat_encode_injective` / `byteArray_encode_injective`
primitives are themselves conditional, because the CBE head's
8-byte LE length field forces a `< 2^64` discipline.  Deployments
enforce these bounds at the runtime boundary (§8.5).

**Visibility decision (OQ-EI-2 option (a)).**  `BalanceMap.encodeAsBytes`
was promoted from `private` to non-private in the same PR so the
framing-injectivity lemma can live in this file rather than inside
`Encoding/State.lean`.  See the docstring on `BalanceMap.encodeAsBytes`
in `Encoding/State.lean` for the rationale.

This module is **not** part of the trusted computing base — `lake exe
tcb_audit` already partitions `Kernel.lean` and `RBMapLemmas.lean`
from every other module.  `#print axioms` on every theorem here
must remain ⊆ `[propext, Classical.choice, Quot.sound]`.
-/

import LegalKernel.Encoding.State

open Std

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority

/-! ## EI.2.a — `BalanceMap.encode_injective`

The inner-map injectivity theorem.  Specialises
`encodeSortedPairs_injective_bounded` (`Encoding/State.lean`) to
the `(Nat, Amount)` pair-list shape of the inner balance map, then
lifts the projected-key equality (`a.toNat = b.toNat`) back to
`a = b` via `UInt64.toNat_inj` and `List.map_inj_right`.

The conclusion is `Std.TreeMap.Equiv`-shaped, not raw structural
`Eq` — two `BalanceMap`s that differ only in RB-tree shape (e.g.
distinct insertion orders that produce the same final
`(actor, amount)` set) are *extensionally* equal but not
structurally equal, and the encoder produces identical bytes for
both (by `balanceMap_encode_deterministic_of_equiv`).  Injectivity
in the other direction recovers exactly the same `Equiv`-shaped
notion. -/

/-- Internal helper: `(a.toNat, v) = (b.toNat, w)` implies `(a, v) =
    (b, w)`.  The `Nat`-projection on the key is injective by
    `UInt64.toNat_inj`; the value position is structurally equal.

    Used as the `proj`-injectivity hypothesis fed to
    `List.map_inj_right` in `BalanceMap.encode_injective`. -/
private theorem balanceMap_pair_proj_injective :
    ∀ x y : ActorId × Amount,
      ((fun (p : ActorId × Amount) => (p.1.toNat, p.2)) x =
       (fun (p : ActorId × Amount) => (p.1.toNat, p.2)) y) →
      x = y := by
  intro ⟨a₁, v₁⟩ ⟨a₂, v₂⟩ h
  -- Beta-reduce the lambda applications via `simp` so that
  -- `congrArg` can unify the projected positions.  After `simp`,
  -- `h : a₁.toNat = a₂.toNat ∧ v₁ = v₂`.
  simp only [Prod.mk.injEq] at h
  obtain ⟨hk, hv⟩ := h
  have : a₁ = a₂ := UInt64.toNat_inj.mp hk
  subst this; subst hv; rfl

/-- EI.2.a — `BalanceMap.encode_injective`.  Equal canonical encodings
    of two `BalanceMap`s imply extensional equality of the maps.

    **Hypotheses.**

      * `h_len₁ / h_len₂` — canonical-encoding length bounds on the
        underlying pair lists.  The CBE map head encodes the pair
        count in 8 bytes LE; counts ≥ `2^64` are silently truncated
        and would let an attacker collide two distinct maps.
        Deployment-level constraint (§8.8.6).
      * `h_amt₁ / h_amt₂` — per-amount canonical-encoding bounds.
        `Amount := Nat` with the same 8-byte LE discipline;
        amounts ≥ `2^64` collide on the encoder.  Phase-5 runtime
        gate (§8.5).

    The actor-key side has no hypothesis: every `a : ActorId =
    UInt64` automatically satisfies `a.toNat < 2^64`.

    Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.2
    EI.2.a).  Conclusion is `Std.TreeMap.Equiv` — the appropriate
    relation since two structurally-distinct extensionally-equal
    `BalanceMap`s encode to identical bytes (per
    `balanceMap_encode_deterministic_of_equiv`). -/
theorem BalanceMap.encode_injective
    (bm₁ bm₂ : BalanceMap)
    (h_len₁ : bm₁.toList.length < 256 ^ 8)
    (h_len₂ : bm₂.toList.length < 256 ^ 8)
    (h_amt₁ : ∀ p ∈ bm₁.toList, p.2 < 256 ^ 8)
    (h_amt₂ : ∀ p ∈ bm₂.toList, p.2 < 256 ^ 8)
    (h : BalanceMap.encode bm₁ = BalanceMap.encode bm₂) :
    bm₁.Equiv bm₂ := by
  -- Step A: unfold the encoder to expose the pair-list shape.
  unfold BalanceMap.encode at h
  -- `h : encodeSortedPairs (bm₁.toList.map proj) =
  --      encodeSortedPairs (bm₂.toList.map proj)`
  -- where `proj := fun p : ActorId × Amount => (p.1.toNat, p.2)`.
  -- (Lean elaborates `fun (a, v) => (a.toNat, v)` as this anonymous
  --  projection-pattern, definitionally equal to our explicit `proj`.)
  -- Step B: apply `encodeSortedPairs_injective_bounded` at `(Nat, Amount)`.
  -- Length-after-map equals original length.
  have h_plen₁ : (bm₁.toList.map (fun (a, v) => (a.toNat, v))).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₁
  have h_plen₂ : (bm₂.toList.map (fun (a, v) => (a.toNat, v))).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₂
  -- Conversion lemma so we can lift `UInt64.toNat_lt` (which gives
  -- `< 2^64`) to the canonical `< 256^8` form expected by the
  -- pair-level round-trip hypotheses.
  have h_uint64_pow : (256 : Nat) ^ 8 = 2 ^ 64 := by decide
  -- Per-pair round-trip hypotheses for the key carrier (`Nat`).
  -- Each `p` in the projected list comes from some `q ∈ bm.toList`
  -- with `p.1 = q.1.toNat`; `q.1 : ActorId = UInt64` so
  -- `q.1.toNat < 2^64` automatically.
  have hK₁ : ∀ p ∈ bm₁.toList.map (fun (a, v) => (a.toNat, v)),
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, _, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      -- `(fun (a, v) => (a.toNat, v)) q = p` ⇒ `p.1 = q.1.toNat`.
      have : p.1 = q.1.toNat := by rw [← hq_eq]
      rw [this, h_uint64_pow]; exact UInt64.toNat_lt q.1
    exact nat_roundtrip p.1 rest hp_bound
  have hK₂ : ∀ p ∈ bm₂.toList.map (fun (a, v) => (a.toNat, v)),
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, _, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have : p.1 = q.1.toNat := by rw [← hq_eq]
      rw [this, h_uint64_pow]; exact UInt64.toNat_lt q.1
    exact nat_roundtrip p.1 rest hp_bound
  -- Per-pair round-trip hypotheses for the value carrier (`Amount`
  -- = `Nat`).  Each `p` in the projected list satisfies `p.2 = q.2`
  -- for some `q ∈ bm.toList`; the amount bound `h_amt` supplies the
  -- `< 2^64` requirement.
  have hV₁ : ∀ p ∈ bm₁.toList.map (fun (a, v) => (a.toNat, v)),
              ∀ (rest : Stream),
                Encodable.decode (T := Amount) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.2 < 256 ^ 8 := by
      have : p.2 = q.2 := by rw [← hq_eq]
      rw [this]; exact h_amt₁ q hq_mem
    exact nat_roundtrip p.2 rest hp_bound
  have hV₂ : ∀ p ∈ bm₂.toList.map (fun (a, v) => (a.toNat, v)),
              ∀ (rest : Stream),
                Encodable.decode (T := Amount) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.2 < 256 ^ 8 := by
      have : p.2 = q.2 := by rw [← hq_eq]
      rw [this]; exact h_amt₂ q hq_mem
    exact nat_roundtrip p.2 rest hp_bound
  -- Invoke `encodeSortedPairs_injective_bounded` to get pair-list equality.
  have h_pairs : bm₁.toList.map (fun (a, v) => (a.toNat, v))
                 = bm₂.toList.map (fun (a, v) => (a.toNat, v)) :=
    encodeSortedPairs_injective_bounded
      (bm₁.toList.map (fun (a, v) => (a.toNat, v)))
      (bm₂.toList.map (fun (a, v) => (a.toNat, v)))
      h_plen₁ h_plen₂ hK₁ hV₁ hK₂ hV₂ h
  -- Step C: lift pair-list equality through `proj` to `bm.toList` equality.
  -- `proj := fun (a, v) => (a.toNat, v)` is injective via
  -- `balanceMap_pair_proj_injective` (which uses `UInt64.toNat_inj`).
  have h_toList : bm₁.toList = bm₂.toList := by
    have h_pairs' :
        bm₁.toList.map (fun p : ActorId × Amount => (p.1.toNat, p.2))
        = bm₂.toList.map (fun p : ActorId × Amount => (p.1.toNat, p.2)) :=
      h_pairs
    exact (List.map_inj_right balanceMap_pair_proj_injective).mp h_pairs'
  -- Step D: lift `toList` equality to `Equiv` via Std.
  exact Std.TreeMap.equiv_iff_toList_eq.mpr h_toList

/-! ## EI.2.b — `BalanceMap.encode_injective_to_equiv`

EI.2.a already concludes `Std.TreeMap.Equiv` directly (we apply
`Std.TreeMap.equiv_iff_toList_eq.mpr` as the last step of the
proof), so this sub-unit collapses to a documentation-only alias.
We ship the alias explicitly so consumers searching for the
"`_to_equiv`" suffix find the headline name as well. -/

/-- EI.2.b alias for EI.2.a.  The headline `BalanceMap.encode_injective`
    already returns `Equiv`-shaped; this alias is shipped for
    callers searching for the `_to_equiv` suffix used elsewhere in
    the encoder-injectivity stack. -/
theorem BalanceMap.encode_injective_to_equiv
    (bm₁ bm₂ : BalanceMap)
    (h_len₁ : bm₁.toList.length < 256 ^ 8)
    (h_len₂ : bm₂.toList.length < 256 ^ 8)
    (h_amt₁ : ∀ p ∈ bm₁.toList, p.2 < 256 ^ 8)
    (h_amt₂ : ∀ p ∈ bm₂.toList, p.2 < 256 ^ 8)
    (h : BalanceMap.encode bm₁ = BalanceMap.encode bm₂) :
    bm₁.Equiv bm₂ :=
  BalanceMap.encode_injective bm₁ bm₂ h_len₁ h_len₂ h_amt₁ h_amt₂ h

/-! ## EI.2.c — `BalanceMap.encodeAsBytes_injective`

The framing-injectivity lemma for the inner-map byte wrapper.
Lifts an `encodeAsBytes`-equality through the `ByteArray.mk` /
`Array.toList` framing to recover `BalanceMap.encode`-equality,
which then chains into EI.2.a's `Equiv` conclusion.

Mirrors the byte-level argument of
`encodeAsBytes_equiv_injective_of_encode_equiv_injective`
(`Encoding/State.lean`) but threads the conditional bounds that
the inner injectivity proof requires. -/

/-- EI.2.c — `BalanceMap.encodeAsBytes_injective`.  The framing
    wrapper preserves injectivity through to `Equiv` on the inner
    `BalanceMap`s.

    **Proof.**  The `BalanceMap.encodeAsBytes` framing is the
    composition `ByteArray.mk ∘ List.toArray ∘ BalanceMap.encode`.
    Each step is injective (modulo the inner-encoder's bounds for
    the last step): `ByteArray.mk` is a single-field constructor;
    `List.toArray` round-trips via `List.toList_toArray`.
    Composition with `BalanceMap.encode_injective` (EI.2.a) gives
    the `Equiv` conclusion.

    Same hypotheses as EI.2.a — see that theorem's docstring for the
    canonical-encoding bound rationale. -/
theorem BalanceMap.encodeAsBytes_injective
    (bm₁ bm₂ : BalanceMap)
    (h_len₁ : bm₁.toList.length < 256 ^ 8)
    (h_len₂ : bm₂.toList.length < 256 ^ 8)
    (h_amt₁ : ∀ p ∈ bm₁.toList, p.2 < 256 ^ 8)
    (h_amt₂ : ∀ p ∈ bm₂.toList, p.2 < 256 ^ 8)
    (h : BalanceMap.encodeAsBytes bm₁ = BalanceMap.encodeAsBytes bm₂) :
    bm₁.Equiv bm₂ := by
  -- Strip the framing wrapper.
  unfold BalanceMap.encodeAsBytes at h
  -- `h : ByteArray.mk (BalanceMap.encode bm₁).toArray =
  --      ByteArray.mk (BalanceMap.encode bm₂).toArray`.
  -- Structure injection: extract the underlying `Array` equality.
  have h_arr : (BalanceMap.encode bm₁).toArray = (BalanceMap.encode bm₂).toArray := by
    injection h
  -- Round-trip back to `List UInt8` via `List.toList_toArray`.
  have h_list :
      (BalanceMap.encode bm₁).toArray.toList = (BalanceMap.encode bm₂).toArray.toList := by
    rw [h_arr]
  rw [List.toList_toArray, List.toList_toArray] at h_list
  -- Apply EI.2.a to lift inner-encoder equality to `Equiv`.
  exact BalanceMap.encode_injective bm₁ bm₂ h_len₁ h_len₂ h_amt₁ h_amt₂ h_list

/-! ## EI.2.d — `State.Equiv` + `State.encode_injective`

The nested-state extensional-equivalence relation and the headline
injectivity theorem for `State.encode`.

`State.Equiv` is *not* `Std.TreeMap.Equiv` on the outer `balances`
map.  The outer-map `Equiv` would require structural `Eq` on the
inner `BalanceMap` values (since `Std.TreeMap.Equiv` compares
values by `Eq` at each key), which is strictly stronger than what
byte-equality of the canonical encoding implies (two
structurally-distinct extensionally-equal inner `BalanceMap`s
encode identically).  The nested form below uses
`Std.TreeMap.Equiv` only on the per-resource inner maps, with the
outer-key-set agreement spelled out separately. -/

/-- Extensional equivalence on `State`: outer-key sets agree, and
    for every resource present in both states the inner per-actor
    `BalanceMap`s are `Std.TreeMap.Equiv`-equivalent (not
    necessarily structurally equal).

    This is the appropriate strength for "two `State`s encode to
    the same canonical bytes": the encoder canonicalises away
    RB-tree shape, so injectivity recovers exactly extensional
    state equality.

    The outer-key conjunct is phrased as an `Iff` (rather than a
    `Bool`-`Eq`) so it composes cleanly with `Std.TreeMap.mem_keys`
    and `mem_iff_isSome_getElem?`.  The `Bool`-`Eq` form is
    derivable as a corollary (`State.Equiv.outer_isSome_eq`).

    Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.2
    EI.2.d). -/
def State.Equiv (s₁ s₂ : State) : Prop :=
  (∀ r : ResourceId, r ∈ s₁.balances ↔ r ∈ s₂.balances) ∧
  (∀ (r : ResourceId) (bm₁ bm₂ : BalanceMap),
     s₁.balances[r]? = some bm₁ → s₂.balances[r]? = some bm₂ →
     bm₁.Equiv bm₂)

/-- Outer-key part of `State.Equiv`.  Surface helper so consumers
    of the headline theorem can access the key-agreement assertion
    without destructuring the `And`. -/
theorem State.Equiv.outer_keys_agree {s₁ s₂ : State} (h : State.Equiv s₁ s₂) :
    ∀ r : ResourceId, r ∈ s₁.balances ↔ r ∈ s₂.balances := h.1

/-- Inner-map part of `State.Equiv`.  Surface helper paired with
    `outer_keys_agree`. -/
theorem State.Equiv.inner_equiv {s₁ s₂ : State} (h : State.Equiv s₁ s₂) :
    ∀ (r : ResourceId) (bm₁ bm₂ : BalanceMap),
      s₁.balances[r]? = some bm₁ → s₂.balances[r]? = some bm₂ →
      bm₁.Equiv bm₂ := h.2

/-- Outer-key part of `State.Equiv` in `Bool`-`Eq` form (the variant
    actually returned by `Option.isSome`).  Derived from the `Iff`
    form via `isSome_getElem?_iff_mem`. -/
theorem State.Equiv.outer_isSome_eq {s₁ s₂ : State} (h : State.Equiv s₁ s₂) :
    ∀ r : ResourceId, s₁.balances[r]?.isSome = s₂.balances[r]?.isSome := by
  intro r
  -- `s_i.balances[r]?.isSome` ↔ `r ∈ s_i.balances` ↔ outer-key
  -- agreement → both `isSome`s agree.  Convert `Iff` to `Bool` `Eq`
  -- by case-splitting on the `Bool` value.
  have h_iff : s₁.balances[r]?.isSome ↔ s₂.balances[r]?.isSome := by
    rw [Std.TreeMap.isSome_getElem?_iff_mem, Std.TreeMap.isSome_getElem?_iff_mem]
    exact h.1 r
  by_cases hr : s₁.balances[r]?.isSome
  · have hr₂ : s₂.balances[r]?.isSome := h_iff.mp hr
    rw [hr, hr₂]
  · have hr₂ : ¬ s₂.balances[r]?.isSome := fun hh => hr (h_iff.mpr hh)
    have hr' : s₁.balances[r]?.isSome = false := by
      cases hs : s₁.balances[r]?.isSome
      · rfl
      · exact (hr hs).elim
    have hr₂' : s₂.balances[r]?.isSome = false := by
      cases hs : s₂.balances[r]?.isSome
      · rfl
      · exact (hr₂ hs).elim
    rw [hr', hr₂']

/-- `State.Equiv` is reflexive: every `State` is extensionally equal
    to itself.  Discharges the outer-key side by `Iff.rfl` and the
    inner-map side by `Std.TreeMap.Equiv.rfl` after unifying both
    `bm` witnesses (`s.balances[r]? = some bm₁` and `s.balances[r]? =
    some bm₂` jointly force `bm₁ = bm₂`). -/
theorem State.Equiv.refl (s : State) : State.Equiv s s :=
  ⟨fun _ => Iff.rfl, fun _ _ _ h₁ h₂ => by
    rw [h₁] at h₂
    -- `h₂ : some bm₁ = some bm₂`; extract `bm₁ = bm₂` and discharge.
    have h_eq := Option.some.inj h₂
    subst h_eq
    exact Std.TreeMap.Equiv.rfl⟩

/-- `State.Equiv` is symmetric.  Both parts of the conjunction are
    closed under swap (the outer side by `Iff.symm`; the inner side
    by `Std.TreeMap.Equiv.symm` after swapping the membership
    witnesses). -/
theorem State.Equiv.symm {s₁ s₂ : State} (h : State.Equiv s₁ s₂) :
    State.Equiv s₂ s₁ :=
  ⟨fun r => (h.1 r).symm,
   fun r bm₁ bm₂ h₁ h₂ => Std.TreeMap.Equiv.symm (h.2 r bm₂ bm₁ h₂ h₁)⟩

/-! ### EI.2.d — `State.encode_injective`

The headline nested theorem.  Equal `State.encode` bytes imply
`State.Equiv`.  Proof structure:

  1. Unfold `State.encode` to expose the outer `encodeSortedPairs`
     applied to `(Nat, ByteArray)` pairs.
  2. Apply `encodeSortedPairs_injective_bounded` to get pair-list
     equality.
  3. Extract index-wise outer-key and inner-bytes equality from
     the list equality.
  4. Lift outer-key equality through `UInt64.toNat_inj`.
  5. Lift inner-bytes equality through EI.2.c to inner `Equiv`.
  6. Assemble into `State.Equiv` via outer-key-set agreement and
     per-key inner-map `Equiv`.

The proof bundles the bounds via per-pair hypotheses on the outer
list of `(resource, balanceMap)` pairs. -/

/-- Internal helper: outer pair projection used by `State.encode`.
    Captures the `(r.toNat, BalanceMap.encodeAsBytes bm)` map. -/
private def State.outerProj (p : ResourceId × BalanceMap) : Nat × ByteArray :=
  (p.1.toNat, BalanceMap.encodeAsBytes p.2)

/-- Internal helper: the outer-projection rewriting of `State.encode`.
    Restated so the lemma can take an explicit `proj` rather than
    inlining the anonymous pattern-lambda from `State.encode`.

    Both sides are pointwise-equal under `Prod` structural eta:
    `(fun (r, bm) => (r.toNat, encodeAsBytes bm)) p = State.outerProj p`
    for every `p : ResourceId × BalanceMap`.  The pattern-lambda
    `fun (r, bm) => ...` desugars to `fun p => p.1.toNat , ...` after
    `Prod` eta on `p`, which is definitionally `State.outerProj p`. -/
private theorem state_encode_eq_via_outerProj (s : State) :
    State.encode s =
    encodeSortedPairs (s.balances.toList.map State.outerProj) := by
  -- After unfolding `State.encode`, both sides are definitionally
  -- equal: the inline `fun (r, bm) => (r.toNat, encodeAsBytes bm)`
  -- and `State.outerProj` produce the same pair on every input
  -- after `Prod` structural eta.
  rfl

/-- EI.2.d — `State.encode_injective`.  Equal canonical encodings of
    two `State` values imply `State.Equiv` (the nested extensional
    relation defined above).

    **Hypotheses.**

      * `h_outer_len₁ / h_outer_len₂` — outer pair-list count bound.
      * `h_inner_len₁ / h_inner_len₂` — per-resource inner pair-list
        count bound.
      * `h_amt₁ / h_amt₂` — per-amount canonical-encoding bound.
      * `h_size₁ / h_size₂` — per-resource framed-bytes size bound
        (the size of `BalanceMap.encodeAsBytes bm` for each inner
        `bm`; bounded above by `9 + 18 * bm.toList.length` per the
        CBE head + per-pair widths).

    All five hypothesis families are deployment-level canonical-
    encoding constraints (§8.5 / §8.8.6); the runtime adaptor
    (Phase 5) gates inputs at the boundary.

    Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.2
    EI.2.d). -/
theorem State.encode_injective
    (s₁ s₂ : State)
    (h_outer_len₁ : s₁.balances.toList.length < 256 ^ 8)
    (h_outer_len₂ : s₂.balances.toList.length < 256 ^ 8)
    (h_inner_len₁ : ∀ p ∈ s₁.balances.toList, p.2.toList.length < 256 ^ 8)
    (h_inner_len₂ : ∀ p ∈ s₂.balances.toList, p.2.toList.length < 256 ^ 8)
    (h_amt₁ : ∀ p ∈ s₁.balances.toList,
              ∀ q ∈ p.2.toList, q.2 < 256 ^ 8)
    (h_amt₂ : ∀ p ∈ s₂.balances.toList,
              ∀ q ∈ p.2.toList, q.2 < 256 ^ 8)
    (h_size₁ : ∀ p ∈ s₁.balances.toList,
                (BalanceMap.encodeAsBytes p.2).size < 256 ^ 8)
    (h_size₂ : ∀ p ∈ s₂.balances.toList,
                (BalanceMap.encodeAsBytes p.2).size < 256 ^ 8)
    (h : State.encode s₁ = State.encode s₂) :
    State.Equiv s₁ s₂ := by
  -- Step A: rewrite both sides via the `outerProj` form so we can
  -- reason about pair-list `map`s without pattern-lambda noise.
  rw [state_encode_eq_via_outerProj, state_encode_eq_via_outerProj] at h
  -- Step B: pair-list length bounds (length-after-map = length).
  have h_plen₁ : (s₁.balances.toList.map State.outerProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_outer_len₁
  have h_plen₂ : (s₂.balances.toList.map State.outerProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_outer_len₂
  -- Step C: conversion fact.
  have h_uint64_pow : (256 : Nat) ^ 8 = 2 ^ 64 := by decide
  -- Step D: per-pair round-trip hypotheses for the outer key carrier
  -- (`Nat`).  Each `p.1` in the projected list is `r.toNat` for some
  -- `r : ResourceId = UInt64`, so `p.1 < 2^64` automatically.
  have hK₁ : ∀ p ∈ s₁.balances.toList.map State.outerProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, _, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      -- `p = outerProj q = (q.1.toNat, encodeAsBytes q.2)`, so `p.1 = q.1.toNat`.
      have h_proj : p = (q.1.toNat, BalanceMap.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj, h_uint64_pow]; exact UInt64.toNat_lt q.1
    exact nat_roundtrip p.1 rest hp_bound
  have hK₂ : ∀ p ∈ s₂.balances.toList.map State.outerProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, _, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have h_proj : p = (q.1.toNat, BalanceMap.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj, h_uint64_pow]; exact UInt64.toNat_lt q.1
    exact nat_roundtrip p.1 rest hp_bound
  -- Step E: per-pair round-trip hypotheses for the outer value
  -- carrier (`ByteArray`).  Each `p.2` is `BalanceMap.encodeAsBytes
  -- q.2`; the per-pair size bound `h_size` supplies the `< 2^64`
  -- precondition for `byteArray_roundtrip`.
  have hV₁ : ∀ p ∈ s₁.balances.toList.map State.outerProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1.toNat, BalanceMap.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_size₁ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  have hV₂ : ∀ p ∈ s₂.balances.toList.map State.outerProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1.toNat, BalanceMap.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_size₂ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  -- Step F: apply `encodeSortedPairs_injective_bounded`.
  have h_pairs : s₁.balances.toList.map State.outerProj
                 = s₂.balances.toList.map State.outerProj :=
    encodeSortedPairs_injective_bounded
      (s₁.balances.toList.map State.outerProj)
      (s₂.balances.toList.map State.outerProj)
      h_plen₁ h_plen₂ hK₁ hV₁ hK₂ hV₂ h
  -- Step G: extract inner equivalence at each outer-key occurrence
  -- from `h_pairs`.  Because `outerProj` is *not* injective on its
  -- second component (we only get `Equiv` from `encodeAsBytes` byte-
  -- equality), we cannot lift `h_pairs` to `s₁.balances.toList =
  -- s₂.balances.toList`.  Instead, we extract the index-wise
  -- information and reassemble.
  -- First: index-wise outer-key equality and inner-bytes equality.
  -- The two `toList`s are sorted ascendingly by `r` (since `toList`
  -- on a `TreeMap compare` returns sorted pairs).  After
  -- `outerProj`, the key is `r.toNat`; sorting on `r` and on
  -- `r.toNat` coincide because `r.toNat` is monotone in `r`.
  -- (`r₁ < r₂ ↔ r₁.toNat < r₂.toNat` for UInt64.)
  -- We bypass the sorting machinery and work directly with
  -- `List.map_inj_left`-style pointwise equality on the two
  -- `toList`s, then use `Prod.mk.injEq` to extract per-key results.
  -- Show that the original `toList`s have the same length.
  have h_outer_len : s₁.balances.toList.length = s₂.balances.toList.length := by
    have := congrArg List.length h_pairs
    rw [List.length_map, List.length_map] at this
    exact this
  -- Index-wise lookup helper: at index `i`, the projected lists
  -- agree, hence the components agree.
  have h_index_eq : ∀ (i : Nat) (hi₁ : i < s₁.balances.toList.length)
                      (hi₂ : i < s₂.balances.toList.length),
      s₁.balances.toList[i].1 = s₂.balances.toList[i].1 ∧
      BalanceMap.encodeAsBytes s₁.balances.toList[i].2
        = BalanceMap.encodeAsBytes s₂.balances.toList[i].2 := by
    intro i hi₁ hi₂
    -- Index `i` into the mapped lists.  Pose the dependent-eq
    -- `_a.length = _` shape explicitly so the bound-coercions match.
    have h_len₁_map : (s₁.balances.toList.map State.outerProj).length
                    = s₁.balances.toList.length := List.length_map _
    have h_len₂_map : (s₂.balances.toList.map State.outerProj).length
                    = s₂.balances.toList.length := List.length_map _
    -- The `getElem` of a `map` is the function applied to the
    -- underlying `getElem`.
    have h_get_map₁ : (s₁.balances.toList.map State.outerProj)[i]'(by
        rw [h_len₁_map]; exact hi₁)
      = State.outerProj s₁.balances.toList[i] := List.getElem_map _
    have h_get_map₂ : (s₂.balances.toList.map State.outerProj)[i]'(by
        rw [h_len₂_map]; exact hi₂)
      = State.outerProj s₂.balances.toList[i] := List.getElem_map _
    -- The mapped lists agree at index `i` (by `h_pairs`).
    -- Derive index-wise projection equality directly.
    have h_proj_idx : State.outerProj s₁.balances.toList[i]
                    = State.outerProj s₂.balances.toList[i] := by
      rw [← h_get_map₁, ← h_get_map₂]
      -- Now both sides are `(... .map outerProj)[i]'`.  After
      -- substituting `h_pairs`, both sides become syntactically equal.
      simp only [h_pairs]
    -- `h_proj_idx : State.outerProj s₁.balances.toList[i] =
    --              State.outerProj s₂.balances.toList[i]`.
    unfold State.outerProj at h_proj_idx
    -- Apply `Prod.mk.injEq` to extract the components.
    have h_key_nat : s₁.balances.toList[i].1.toNat
                   = s₂.balances.toList[i].1.toNat :=
      congrArg Prod.fst h_proj_idx
    have h_val_bytes : BalanceMap.encodeAsBytes s₁.balances.toList[i].2
                     = BalanceMap.encodeAsBytes s₂.balances.toList[i].2 :=
      congrArg Prod.snd h_proj_idx
    exact ⟨UInt64.toNat_inj.mp h_key_nat, h_val_bytes⟩
  -- Step H: assemble `State.Equiv` from `h_index_eq`.
  -- First, an intermediate: `s₁.balances.keys = s₂.balances.keys` as
  -- lists.  Both are `s_i.balances.toList.map Prod.fst`, and the
  -- outer-key conjunct of `h_index_eq` gives index-wise equality
  -- of the two `map Prod.fst` lists.
  have h_keys_eq : s₁.balances.keys = s₂.balances.keys := by
    rw [← Std.TreeMap.map_fst_toList_eq_keys, ← Std.TreeMap.map_fst_toList_eq_keys]
    apply List.ext_getElem
    · rw [List.length_map, List.length_map]; exact h_outer_len
    · intro i hi₁ _
      rw [List.length_map] at hi₁
      have hi₂ : i < s₂.balances.toList.length := h_outer_len ▸ hi₁
      rw [List.getElem_map, List.getElem_map]
      exact (h_index_eq i hi₁ hi₂).1
  refine ⟨?_, ?_⟩
  · -- Outer-key agreement: `r ∈ s₁.balances ↔ r ∈ s₂.balances`.
    -- Route through `mem_keys`: `r ∈ s_i.balances ↔ r ∈ s_i.balances.keys`,
    -- then use `h_keys_eq` to flip the list.
    intro r
    rw [← Std.TreeMap.mem_keys, ← Std.TreeMap.mem_keys, h_keys_eq]
  · -- Inner-map agreement: for any `r` with `s_i.balances[r]? = some
    -- bm_i`, the inner maps are `Equiv`.
    intro r bm₁ bm₂ h₁ h₂
    -- Bridge `getElem? = some` to `toList` membership.
    have h_mem₁ : (r, bm₁) ∈ s₁.balances.toList :=
      Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h₁
    have h_mem₂ : (r, bm₂) ∈ s₂.balances.toList :=
      Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h₂
    -- Locate `(r, bm₁)` at index `i` in `s₁.balances.toList`.
    obtain ⟨i, hi₁, hi_eq₁⟩ := List.mem_iff_getElem.mp h_mem₁
    -- `i < s₂.balances.toList.length` by outer-length agreement.
    have hi₂ : i < s₂.balances.toList.length := h_outer_len ▸ hi₁
    -- Pose the per-index outer-key and inner-bytes equalities.
    have h_idx := h_index_eq i hi₁ hi₂
    -- From `hi_eq₁ : s₁.balances.toList[i] = (r, bm₁)`, extract the
    -- components.  (No `.symm` needed: `List.mem_iff_getElem.mp`
    -- already returns `l[i] = a`.)
    have h_key₁ : s₁.balances.toList[i].1 = r := by rw [hi_eq₁]
    have h_val₁ : s₁.balances.toList[i].2 = bm₁ := by rw [hi_eq₁]
    -- Therefore `s₂.balances.toList[i].1 = r` (by `h_idx.1` + transport).
    have h_key₂ : s₂.balances.toList[i].1 = r := by rw [← h_idx.1, h_key₁]
    -- Now derive `s₂.balances.toList[i].2 = bm₂`.  Approach: from
    -- `(s₂.balances.toList[i].1, s₂.balances.toList[i].2) ∈
    -- s₂.balances.toList`, apply `mem_toList_iff_getElem?_eq_some.mp`
    -- to get `s₂.balances[s₂.balances.toList[i].1]? = some
    -- s₂.balances.toList[i].2`.  Rewrite the lookup-key by `h_key₂`
    -- and compare against `h₂`.
    have h_mem_at_i : s₂.balances.toList[i] ∈ s₂.balances.toList :=
      List.getElem_mem hi₂
    -- Reshape `s₂.balances.toList[i]` as `(s₂.balances.toList[i].1,
    -- s₂.balances.toList[i].2)` and rewrite by `h_key₂`.
    have h_lookup_at_i :
        s₂.balances[s₂.balances.toList[i].1]? = some s₂.balances.toList[i].2 := by
      apply Std.TreeMap.mem_toList_iff_getElem?_eq_some.mp
      -- `(s₂.balances.toList[i].1, s₂.balances.toList[i].2) =
      --  s₂.balances.toList[i]` by `Prod` structural eta.
      exact (by cases h_eq : s₂.balances.toList[i]; exact h_eq ▸ h_mem_at_i :
        (s₂.balances.toList[i].1, s₂.balances.toList[i].2) ∈ s₂.balances.toList)
    rw [h_key₂] at h_lookup_at_i
    -- `h_lookup_at_i : s₂.balances[r]? = some s₂.balances.toList[i].2`.
    -- Combine with `h₂ : s₂.balances[r]? = some bm₂` to derive
    -- `s₂.balances.toList[i].2 = bm₂`.
    have h_val₂ : s₂.balances.toList[i].2 = bm₂ := by
      have : some s₂.balances.toList[i].2 = some bm₂ := by
        rw [← h_lookup_at_i]; exact h₂
      exact Option.some.inj this
    -- Apply index-wise bytes equality and rewrite via h_val₁ / h_val₂.
    have h_bytes_eq : BalanceMap.encodeAsBytes bm₁ = BalanceMap.encodeAsBytes bm₂ := by
      have := h_idx.2
      rw [h_val₁, h_val₂] at this; exact this
    -- Apply EI.2.c with bounds drawn from the per-pair hypothesis bundles.
    exact BalanceMap.encodeAsBytes_injective bm₁ bm₂
      (h_inner_len₁ (r, bm₁) h_mem₁)
      (h_inner_len₂ (r, bm₂) h_mem₂)
      (fun p hp => h_amt₁ (r, bm₁) h_mem₁ p hp)
      (fun p hp => h_amt₂ (r, bm₂) h_mem₂ p hp)
      h_bytes_eq

/-! ## EI.3 — `NonceState.encode_injective`

The flat-map injectivity theorem for the per-actor nonce ledger.
`NonceState.next : TreeMap ActorId Nonce compare`, encoded as a
sorted-pair list of `(ActorId.toNat, Nonce)` pairs.  Specialises
`encodeSortedPairs_injective_bounded` at `K := Nat, V := Nat`
(since `Nonce` is `abbrev`-aliased to `Nat`) and lifts the
projected-key equality through `UInt64.toNat_inj`.

Conditional on canonical-encoding bounds: list length < 2^64
(CBE head's 8-byte LE pair-count field) and per-nonce value
< 2^64 (CBE Nat head's 8-byte LE payload).  Actor-key bound is
automatic (UInt64.toNat is always < 2^64). -/

/-- Internal helper: the `(a.toNat, n)`-projection on `(ActorId, Nonce)`
    pairs is injective.  Mirrors `balanceMap_pair_proj_injective` but
    on `Nonce`-valued pairs (also `Nat`-typed at the value position
    via `Nonce := Nat`). -/
private theorem nonceState_pair_proj_injective :
    ∀ x y : ActorId × Nonce,
      ((fun (p : ActorId × Nonce) => (p.1.toNat, p.2)) x =
       (fun (p : ActorId × Nonce) => (p.1.toNat, p.2)) y) →
      x = y := by
  intro ⟨a₁, v₁⟩ ⟨a₂, v₂⟩ h
  simp only [Prod.mk.injEq] at h
  obtain ⟨hk, hv⟩ := h
  have : a₁ = a₂ := UInt64.toNat_inj.mp hk
  subst this; subst hv; rfl

/-- EI.3.a — `NonceState.encode_injective`.  Equal canonical encodings
    of two `NonceState`s imply extensional equality of the underlying
    nonce ledger maps.

    **Hypotheses.**  Canonical-encoding bounds on (1) the pair-list
    length (CBE map-head 8-byte LE count field) and (2) each per-actor
    nonce value (CBE Nat head's 8-byte LE payload).  The actor-key
    side has no hypothesis: every `a : ActorId = UInt64` automatically
    satisfies `a.toNat < 2^64`.

    The conclusion is on the underlying `next` field rather than on
    `NonceState` itself; `NonceState` is a single-field struct so the
    distinction is mostly cosmetic, but downstream consumers may
    want the flat `expectedNonce`-equality form (derivable below).

    Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.3
    EI.3.a). -/
theorem NonceState.encode_injective
    (n₁ n₂ : NonceState)
    (h_len₁ : n₁.next.toList.length < 256 ^ 8)
    (h_len₂ : n₂.next.toList.length < 256 ^ 8)
    (h_nonce₁ : ∀ p ∈ n₁.next.toList, p.2 < 256 ^ 8)
    (h_nonce₂ : ∀ p ∈ n₂.next.toList, p.2 < 256 ^ 8)
    (h : NonceState.encode n₁ = NonceState.encode n₂) :
    n₁.next.Equiv n₂.next := by
  -- Step A: unfold the encoder to expose the pair-list shape.
  unfold NonceState.encode at h
  -- Step B: pair-list length bounds (length-after-map = length).
  have h_plen₁ : (n₁.next.toList.map (fun (a, n) => (a.toNat, n))).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₁
  have h_plen₂ : (n₂.next.toList.map (fun (a, n) => (a.toNat, n))).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₂
  -- Step C: 256^8 = 2^64 conversion fact.
  have h_uint64_pow : (256 : Nat) ^ 8 = 2 ^ 64 := by decide
  -- Step D: per-pair round-trip hypotheses for the key carrier (Nat).
  have hK₁ : ∀ p ∈ n₁.next.toList.map (fun (a, n) => (a.toNat, n)),
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, _, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have : p.1 = q.1.toNat := by rw [← hq_eq]
      rw [this, h_uint64_pow]; exact UInt64.toNat_lt q.1
    exact nat_roundtrip p.1 rest hp_bound
  have hK₂ : ∀ p ∈ n₂.next.toList.map (fun (a, n) => (a.toNat, n)),
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, _, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have : p.1 = q.1.toNat := by rw [← hq_eq]
      rw [this, h_uint64_pow]; exact UInt64.toNat_lt q.1
    exact nat_roundtrip p.1 rest hp_bound
  -- Step E: per-pair round-trip hypotheses for the value carrier (Nonce = Nat).
  have hV₁ : ∀ p ∈ n₁.next.toList.map (fun (a, n) => (a.toNat, n)),
              ∀ (rest : Stream),
                Encodable.decode (T := Nonce) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.2 < 256 ^ 8 := by
      have : p.2 = q.2 := by rw [← hq_eq]
      rw [this]; exact h_nonce₁ q hq_mem
    exact nat_roundtrip p.2 rest hp_bound
  have hV₂ : ∀ p ∈ n₂.next.toList.map (fun (a, n) => (a.toNat, n)),
              ∀ (rest : Stream),
                Encodable.decode (T := Nonce) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.2 < 256 ^ 8 := by
      have : p.2 = q.2 := by rw [← hq_eq]
      rw [this]; exact h_nonce₂ q hq_mem
    exact nat_roundtrip p.2 rest hp_bound
  -- Step F: invoke `encodeSortedPairs_injective_bounded`.
  have h_pairs : n₁.next.toList.map (fun (a, n) => (a.toNat, n))
                 = n₂.next.toList.map (fun (a, n) => (a.toNat, n)) :=
    encodeSortedPairs_injective_bounded
      (n₁.next.toList.map (fun (a, n) => (a.toNat, n)))
      (n₂.next.toList.map (fun (a, n) => (a.toNat, n)))
      h_plen₁ h_plen₂ hK₁ hV₁ hK₂ hV₂ h
  -- Step G: lift pair-list equality through the `(a.toNat, n)` projection.
  have h_toList : n₁.next.toList = n₂.next.toList := by
    have h_pairs' :
        n₁.next.toList.map (fun p : ActorId × Nonce => (p.1.toNat, p.2))
        = n₂.next.toList.map (fun p : ActorId × Nonce => (p.1.toNat, p.2)) :=
      h_pairs
    exact (List.map_inj_right nonceState_pair_proj_injective).mp h_pairs'
  -- Step H: lift toList equality to Equiv via Std.
  exact Std.TreeMap.equiv_iff_toList_eq.mpr h_toList

/-- Corollary: `NonceState.encode_injective` lifts to pointwise
    `expectedNonce`-equality on the parent `ExtendedState`.  Useful
    for downstream consumers that read nonces via the high-level
    accessor rather than the underlying `TreeMap.getElem?` call.

    Note: shipped as a direct corollary of EI.3.a; the
    `expectedNonce` definition lives in `Authority/Nonce.lean`. -/
theorem NonceState.expectedNonce_eq_of_encode_eq
    (n₁ n₂ : NonceState)
    (h_len₁ : n₁.next.toList.length < 256 ^ 8)
    (h_len₂ : n₂.next.toList.length < 256 ^ 8)
    (h_nonce₁ : ∀ p ∈ n₁.next.toList, p.2 < 256 ^ 8)
    (h_nonce₂ : ∀ p ∈ n₂.next.toList, p.2 < 256 ^ 8)
    (h : NonceState.encode n₁ = NonceState.encode n₂) :
    ∀ a : ActorId, n₁.next[a]? = n₂.next[a]? := by
  intro a
  have h_equiv : n₁.next.Equiv n₂.next :=
    NonceState.encode_injective n₁ n₂ h_len₁ h_len₂ h_nonce₁ h_nonce₂ h
  exact Std.TreeMap.Equiv.getElem?_eq h_equiv

/-! ## EI.4 — `KeyRegistry.encodeMap_injective`

The flat-map injectivity theorem for the per-actor public-key
registry.  `KeyRegistry := TreeMap ActorId PublicKey compare`,
encoded as a sorted-pair list of `(ActorId.toNat, PublicKey)`
pairs.  Specialises `encodeSortedPairs_injective_bounded` at
`K := Nat, V := ByteArray` (since `PublicKey` is `abbrev`-aliased
to `ByteArray`).

Conditional on canonical-encoding bounds: list length < 2^64 and
per-key byte-size < 2^64.  Production `PublicKey` widths
(secp256k1 33-byte compressed, Ed25519 32-byte) all satisfy the
size bound trivially. -/

/-- Internal helper: the `(a.toNat, pk)`-projection on
    `(ActorId, PublicKey)` pairs is injective. -/
private theorem keyRegistry_pair_proj_injective :
    ∀ x y : ActorId × PublicKey,
      ((fun (p : ActorId × PublicKey) => (p.1.toNat, p.2)) x =
       (fun (p : ActorId × PublicKey) => (p.1.toNat, p.2)) y) →
      x = y := by
  intro ⟨a₁, v₁⟩ ⟨a₂, v₂⟩ h
  simp only [Prod.mk.injEq] at h
  obtain ⟨hk, hv⟩ := h
  have : a₁ = a₂ := UInt64.toNat_inj.mp hk
  subst this; subst hv; rfl

/-- EI.4.a — `KeyRegistry.encodeMap_injective`.  Equal canonical
    encodings of two `KeyRegistry`s imply extensional equality of the
    underlying maps.

    **Hypotheses.**  Canonical-encoding bounds on (1) the pair-list
    length and (2) each per-actor public-key byte size.  Public-key
    widths in practice are fixed (32 or 33 or 65 bytes); the bound
    is a deployment-level invariant maintained at the runtime
    boundary.

    Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.4
    EI.4.a). -/
theorem KeyRegistry.encodeMap_injective
    (kr₁ kr₂ : KeyRegistry)
    (h_len₁ : kr₁.toList.length < 256 ^ 8)
    (h_len₂ : kr₂.toList.length < 256 ^ 8)
    (h_size₁ : ∀ p ∈ kr₁.toList, p.2.size < 256 ^ 8)
    (h_size₂ : ∀ p ∈ kr₂.toList, p.2.size < 256 ^ 8)
    (h : KeyRegistry.encodeMap kr₁ = KeyRegistry.encodeMap kr₂) :
    kr₁.Equiv kr₂ := by
  unfold KeyRegistry.encodeMap at h
  have h_plen₁ : (kr₁.toList.map (fun (a, pk) => (a.toNat, pk))).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₁
  have h_plen₂ : (kr₂.toList.map (fun (a, pk) => (a.toNat, pk))).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₂
  have h_uint64_pow : (256 : Nat) ^ 8 = 2 ^ 64 := by decide
  -- Per-pair round-trip hypotheses for the key carrier (Nat).
  have hK₁ : ∀ p ∈ kr₁.toList.map (fun (a, pk) => (a.toNat, pk)),
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, _, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have : p.1 = q.1.toNat := by rw [← hq_eq]
      rw [this, h_uint64_pow]; exact UInt64.toNat_lt q.1
    exact nat_roundtrip p.1 rest hp_bound
  have hK₂ : ∀ p ∈ kr₂.toList.map (fun (a, pk) => (a.toNat, pk)),
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, _, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have : p.1 = q.1.toNat := by rw [← hq_eq]
      rw [this, h_uint64_pow]; exact UInt64.toNat_lt q.1
    exact nat_roundtrip p.1 rest hp_bound
  -- Per-pair round-trip hypotheses for the value carrier (PublicKey = ByteArray).
  have hV₁ : ∀ p ∈ kr₁.toList.map (fun (a, pk) => (a.toNat, pk)),
              ∀ (rest : Stream),
                Encodable.decode (T := PublicKey) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have : p.2 = q.2 := by rw [← hq_eq]
      rw [this]; exact h_size₁ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  have hV₂ : ∀ p ∈ kr₂.toList.map (fun (a, pk) => (a.toNat, pk)),
              ∀ (rest : Stream),
                Encodable.decode (T := PublicKey) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have : p.2 = q.2 := by rw [← hq_eq]
      rw [this]; exact h_size₂ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  have h_pairs : kr₁.toList.map (fun (a, pk) => (a.toNat, pk))
                 = kr₂.toList.map (fun (a, pk) => (a.toNat, pk)) :=
    encodeSortedPairs_injective_bounded
      (kr₁.toList.map (fun (a, pk) => (a.toNat, pk)))
      (kr₂.toList.map (fun (a, pk) => (a.toNat, pk)))
      h_plen₁ h_plen₂ hK₁ hV₁ hK₂ hV₂ h
  have h_toList : kr₁.toList = kr₂.toList := by
    have h_pairs' :
        kr₁.toList.map (fun p : ActorId × PublicKey => (p.1.toNat, p.2))
        = kr₂.toList.map (fun p : ActorId × PublicKey => (p.1.toNat, p.2)) :=
      h_pairs
    exact (List.map_inj_right keyRegistry_pair_proj_injective).mp h_pairs'
  exact Std.TreeMap.equiv_iff_toList_eq.mpr h_toList

/-! ### Corollary: pointwise `getBalance` equality

`State.Equiv` is exactly what the kernel-level `getBalance` query
needs: two `State`s with `State.Equiv` agree at every
`(resource, actor)` lookup.  This corollary is shipped for
downstream consumers (e.g. the FaultProof chain) that prefer the
flat `getBalance`-equality form over the nested `Equiv`. -/

/-- `State.Equiv` implies pointwise `getBalance` equality.  This
    corollary phrases the relation in the form most consumers
    (kernel callers, FaultProof chain) actually use. -/
theorem State.Equiv.getBalance_eq {s₁ s₂ : State} (h : State.Equiv s₁ s₂) :
    ∀ (r : ResourceId) (a : ActorId), getBalance s₁ r a = getBalance s₂ r a := by
  intro r a
  unfold getBalance
  -- Case-split on `s_i.balances[r]?`.  Outer-key agreement (via the
  -- `Iff`) forces the two `Option`s to be both `none` or both
  -- `some _`.
  have h_iff_isSome := h.outer_isSome_eq r
  -- `h_iff_isSome : s₁.balances[r]?.isSome = s₂.balances[r]?.isSome`.
  cases h₁ : s₁.balances[r]? with
  | none =>
    cases h₂ : s₂.balances[r]? with
    | none => rfl
    | some bm₂ =>
      -- Contradiction: `s₁` has no key but `s₂` does.
      rw [h₁, h₂] at h_iff_isSome
      simp at h_iff_isSome
  | some bm₁ =>
    cases h₂ : s₂.balances[r]? with
    | none =>
      rw [h₁, h₂] at h_iff_isSome
      simp at h_iff_isSome
    | some bm₂ =>
      -- Apply the inner equivalence at `(r, bm₁, bm₂)` and pull
      -- pointwise lookup equality straight from `Std.TreeMap.Equiv`.
      have h_inner : bm₁.Equiv bm₂ := h.2 r bm₁ bm₂ h₁ h₂
      have h_pt : bm₁[a]? = bm₂[a]? := Std.TreeMap.Equiv.getElem?_eq h_inner
      -- Reduce the matches manually to expose `bm.getD 0`-style RHS.
      show bm₁[a]?.getD 0 = bm₂[a]?.getD 0
      rw [h_pt]

end Encoding
end LegalKernel

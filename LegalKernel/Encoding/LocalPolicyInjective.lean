/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.LocalPolicyInjective — Encoder injectivity (EI.5)
for the `LocalPolicies` codec.

Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.5).
Closes the per-sub-state injectivity obligation for the per-actor
local-policies map `LocalPolicies := TreeMap ActorId LocalPolicy
compare`.  The inner `LocalPolicy` (and its `LocalPolicyClause`)
already have shipped injectivity lemmas in `Encoding/LocalPolicy.lean`
(`localPolicyClause_encode_injective` / `localPolicy_encode_injective`)
under the project's `lower_snake_case` convention; this file ships
two new lemmas:

  * **EI.5.c** `LocalPolicy.encodeAsBytes_injective` — framing
    injectivity for the byte-wrapped inner encoder.  Mirrors EI.2.c
    (`BalanceMap.encodeAsBytes_injective`).

  * **EI.5.d** `LocalPolicies.encodeMap_injective` — the headline
    map-level theorem.  Equal canonical encodings of two
    `LocalPolicies` tables imply `Std.TreeMap.Equiv` on the
    underlying actor → policy maps.

Per OQ-EI-2's resolution, `LocalPolicy.encodeAsBytes` was promoted
from `private` to non-private in `Encoding/LocalPolicy.lean` so the
framing-injectivity lemma can co-locate with the headline theorem
here rather than living inside the encoder file.

This module is **not** part of the trusted computing base — `lake
exe tcb_audit` already partitions `Kernel.lean` and `RBMapLemmas.lean`
from every other module.  `#print axioms` on every theorem here
must remain ⊆ `[propext, Classical.choice, Quot.sound]`.
-/

import LegalKernel.Encoding.State
import LegalKernel.Encoding.LocalPolicy

open Std

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority

/-! ## EI.5.c — `LocalPolicy.encodeAsBytes_injective`

The framing-injectivity lemma for the policy-bytes wrapper.  Lifts
an `encodeAsBytes`-equality through the `ByteArray.mk` / `Array.toList`
framing to recover `LocalPolicy.encode`-equality, which then chains
into the existing `localPolicy_encode_injective` (the `Eq`
conclusion of EI.5.b).

Mirrors the byte-level argument of EI.2.c
(`BalanceMap.encodeAsBytes_injective`) but routes through the
`Eq`-shaped inner injectivity rather than the `Equiv`-shaped one
that `BalanceMap` requires. -/

/-- EI.5.c — `LocalPolicy.encodeAsBytes_injective`.  The framing
    wrapper preserves structural injectivity through to `Eq` on the
    inner `LocalPolicy`s.

    **Hypotheses.**  Both inputs satisfy `LocalPolicy.fieldsBounded`
    — the §3.0 canonical-encoding bound on clause count and per-clause
    sub-bounds.  Inherited from `localPolicy_encode_injective`. -/
theorem LocalPolicy.encodeAsBytes_injective
    (p₁ p₂ : LocalPolicy)
    (h₁ : LocalPolicy.fieldsBounded p₁) (h₂ : LocalPolicy.fieldsBounded p₂)
    (h : LocalPolicy.encodeAsBytes p₁ = LocalPolicy.encodeAsBytes p₂) :
    p₁ = p₂ := by
  -- Strip the framing wrapper.
  unfold LocalPolicy.encodeAsBytes at h
  -- Structure injection: extract the underlying Array equality.
  have h_arr : (LocalPolicy.encode p₁).toArray = (LocalPolicy.encode p₂).toArray := by
    injection h
  -- Round-trip back to List UInt8 via List.toList_toArray.
  have h_list :
      (LocalPolicy.encode p₁).toArray.toList = (LocalPolicy.encode p₂).toArray.toList := by
    rw [h_arr]
  rw [List.toList_toArray, List.toList_toArray] at h_list
  -- Apply the inner injectivity (Eq-shaped).
  exact localPolicy_encode_injective p₁ p₂ h₁ h₂ h_list

/-! ## EI.5.d — `LocalPolicies.encodeMap_injective`

The headline outer-map injectivity theorem.  `LocalPolicies :=
TreeMap ActorId LocalPolicy compare`, encoded as a sorted-pair list
of `(ActorId.toNat, LocalPolicy.encodeAsBytes)` pairs.  Specialises
`encodeSortedPairs_injective_bounded` at `K := Nat, V := ByteArray`
and lifts the projected-key equality through `UInt64.toNat_inj`,
then lifts the inner `ByteArray`-equality at each key through
`LocalPolicy.encodeAsBytes_injective` (EI.5.c).

Conditional on canonical-encoding bounds: outer list length < 2^64
(CBE map-head 8-byte LE pair-count), per-policy framed-bytes size
< 2^64, and per-policy `fieldsBounded` for the inner-encoder
injectivity. -/

/-- Internal helper: named outer-projection used by `LocalPolicies.encodeMap`.
    Captures the `(a.toNat, LocalPolicy.encodeAsBytes p)` map.  Naming
    the projection lets the proof avoid pattern-lambda shadowing and
    use clean `rw`-style rewrites. -/
private def LocalPolicies.outerProj
    (p : ActorId × LocalPolicy) : Nat × ByteArray :=
  (p.1.toNat, LocalPolicy.encodeAsBytes p.2)

/-- Internal helper: the outer-projection rewriting of
    `LocalPolicies.encodeMap`.  Mirrors `state_encode_eq_via_outerProj`
    in `StateInjective.lean`. -/
private theorem localPolicies_encodeMap_eq_via_outerProj (lp : LocalPolicies) :
    LocalPolicies.encodeMap lp =
    encodeSortedPairs (lp.toList.map LocalPolicies.outerProj) := rfl

/-- EI.5.d — `LocalPolicies.encodeMap_injective`.  Equal canonical
    encodings of two `LocalPolicies` tables imply extensional
    equality of the underlying maps.

    **Hypotheses.**  Canonical-encoding bounds on (1) the outer
    pair-list length, (2) each framed-policy byte-size, and (3) the
    per-policy `LocalPolicy.fieldsBounded` invariant that backs the
    inner-encoder injectivity.

    The conclusion is `Std.TreeMap.Equiv` — the canonical
    extensional-equality relation for `TreeMap`s.  Two LocalPolicies
    with the same logical (actor → policy) map but different RB-tree
    shapes (from distinct insertion orders) are not structurally `Eq`
    but are `Equiv`-equivalent, and the encoder produces identical
    bytes for both (by `localPolicies_encodeMap_deterministic_of_equiv`).
    Injectivity in the reverse direction recovers exactly the same
    `Equiv` relation.

    Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.5
    EI.5.d). -/
theorem LocalPolicies.encodeMap_injective
    (lp₁ lp₂ : LocalPolicies)
    (h_len₁ : lp₁.toList.length < 256 ^ 8)
    (h_len₂ : lp₂.toList.length < 256 ^ 8)
    (h_size₁ : ∀ p ∈ lp₁.toList, (LocalPolicy.encodeAsBytes p.2).size < 256 ^ 8)
    (h_size₂ : ∀ p ∈ lp₂.toList, (LocalPolicy.encodeAsBytes p.2).size < 256 ^ 8)
    (h_pol₁ : ∀ p ∈ lp₁.toList, LocalPolicy.fieldsBounded p.2)
    (h_pol₂ : ∀ p ∈ lp₂.toList, LocalPolicy.fieldsBounded p.2)
    (h : LocalPolicies.encodeMap lp₁ = LocalPolicies.encodeMap lp₂) :
    lp₁.Equiv lp₂ := by
  -- Step A: rewrite via the named outer-projection form.
  rw [localPolicies_encodeMap_eq_via_outerProj,
      localPolicies_encodeMap_eq_via_outerProj] at h
  -- Step B: pair-list length bounds (length-after-map = length).
  have h_plen₁ : (lp₁.toList.map LocalPolicies.outerProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₁
  have h_plen₂ : (lp₂.toList.map LocalPolicies.outerProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₂
  -- Step C: 256^8 = 2^64 conversion fact.
  have h_uint64_pow : (256 : Nat) ^ 8 = 2 ^ 64 := by decide
  -- Step D: per-pair round-trip hypotheses for the key carrier (Nat).
  have hK₁ : ∀ p ∈ lp₁.toList.map LocalPolicies.outerProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, _, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have h_proj : p = (q.1.toNat, LocalPolicy.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj, h_uint64_pow]; exact UInt64.toNat_lt q.1
    exact nat_roundtrip p.1 rest hp_bound
  have hK₂ : ∀ p ∈ lp₂.toList.map LocalPolicies.outerProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, _, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have h_proj : p = (q.1.toNat, LocalPolicy.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj, h_uint64_pow]; exact UInt64.toNat_lt q.1
    exact nat_roundtrip p.1 rest hp_bound
  -- Step E: per-pair round-trip hypotheses for the value carrier
  -- (ByteArray, from `LocalPolicy.encodeAsBytes`).
  have hV₁ : ∀ p ∈ lp₁.toList.map LocalPolicies.outerProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1.toNat, LocalPolicy.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_size₁ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  have hV₂ : ∀ p ∈ lp₂.toList.map LocalPolicies.outerProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1.toNat, LocalPolicy.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_size₂ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  -- Step F: invoke encodeSortedPairs_injective_bounded.
  have h_pairs : lp₁.toList.map LocalPolicies.outerProj
               = lp₂.toList.map LocalPolicies.outerProj :=
    encodeSortedPairs_injective_bounded
      (lp₁.toList.map LocalPolicies.outerProj)
      (lp₂.toList.map LocalPolicies.outerProj)
      h_plen₁ h_plen₂ hK₁ hV₁ hK₂ hV₂ h
  -- Step G: lift pair-list equality through the named outer projection.
  -- `outerProj` is *not* injective on its second component (we get
  -- only `Eq` on `encodeAsBytes p₁ = encodeAsBytes p₂`, which gives
  -- `Eq` on the underlying policies via EI.5.c).  We extract per-index
  -- equality and rebuild via List.ext_getElem.
  have h_outer_len : lp₁.toList.length = lp₂.toList.length := by
    have := congrArg List.length h_pairs
    rw [List.length_map, List.length_map] at this
    exact this
  have h_toList : lp₁.toList = lp₂.toList := by
    apply List.ext_getElem
    · exact h_outer_len
    · intro i hi₁ _
      have hi₂ : i < lp₂.toList.length := h_outer_len ▸ hi₁
      -- The mapped lists agree at index i.
      have h_get_map₁ :
          (lp₁.toList.map LocalPolicies.outerProj)[i]'(by
              rw [List.length_map]; exact hi₁)
          = LocalPolicies.outerProj (lp₁.toList[i]'hi₁) := List.getElem_map _
      have h_get_map₂ :
          (lp₂.toList.map LocalPolicies.outerProj)[i]'(by
              rw [List.length_map]; exact hi₂)
          = LocalPolicies.outerProj (lp₂.toList[i]'hi₂) := List.getElem_map _
      have h_proj_idx :
          LocalPolicies.outerProj (lp₁.toList[i]'hi₁)
          = LocalPolicies.outerProj (lp₂.toList[i]'hi₂) := by
        rw [← h_get_map₁, ← h_get_map₂]
        simp only [h_pairs]
      -- Extract (1) actor-id equality and (2) framed-bytes equality.
      unfold LocalPolicies.outerProj at h_proj_idx
      have h_actor_nat : lp₁.toList[i].1.toNat = lp₂.toList[i].1.toNat :=
        congrArg Prod.fst h_proj_idx
      have h_actor : lp₁.toList[i].1 = lp₂.toList[i].1 :=
        UInt64.toNat_inj.mp h_actor_nat
      have h_bytes : LocalPolicy.encodeAsBytes lp₁.toList[i].2
                   = LocalPolicy.encodeAsBytes lp₂.toList[i].2 :=
        congrArg Prod.snd h_proj_idx
      -- Lift the framed-bytes equality to inner-policy equality via EI.5.c.
      have hp_mem₁ : lp₁.toList[i] ∈ lp₁.toList := List.getElem_mem hi₁
      have hp_mem₂ : lp₂.toList[i] ∈ lp₂.toList := List.getElem_mem hi₂
      have h_policy : lp₁.toList[i].2 = lp₂.toList[i].2 :=
        LocalPolicy.encodeAsBytes_injective
          lp₁.toList[i].2 lp₂.toList[i].2
          (h_pol₁ _ hp_mem₁) (h_pol₂ _ hp_mem₂) h_bytes
      -- Reconstruct the index-wise `Prod` equality.
      have : (lp₁.toList[i].1, lp₁.toList[i].2) = (lp₂.toList[i].1, lp₂.toList[i].2) := by
        rw [h_actor, h_policy]
      cases h_lhs : lp₁.toList[i] with
      | mk a₁ p₁ =>
        cases h_rhs : lp₂.toList[i] with
        | mk a₂ p₂ =>
          rw [h_lhs, h_rhs] at this
          exact this
  -- Step H: lift toList equality to Equiv via Std.
  exact Std.TreeMap.equiv_iff_toList_eq.mpr h_toList

/-- Corollary: `LocalPolicies.encodeMap_injective` lifts to pointwise
    `LocalPolicies.lookup`-equality, the form most kernel-level
    consumers actually use (`lookup a := lp[a]?.getD LocalPolicy.empty`). -/
theorem LocalPolicies.lookup_eq_of_encode_eq
    (lp₁ lp₂ : LocalPolicies)
    (h_len₁ : lp₁.toList.length < 256 ^ 8)
    (h_len₂ : lp₂.toList.length < 256 ^ 8)
    (h_size₁ : ∀ p ∈ lp₁.toList, (LocalPolicy.encodeAsBytes p.2).size < 256 ^ 8)
    (h_size₂ : ∀ p ∈ lp₂.toList, (LocalPolicy.encodeAsBytes p.2).size < 256 ^ 8)
    (h_pol₁ : ∀ p ∈ lp₁.toList, LocalPolicy.fieldsBounded p.2)
    (h_pol₂ : ∀ p ∈ lp₂.toList, LocalPolicy.fieldsBounded p.2)
    (h : LocalPolicies.encodeMap lp₁ = LocalPolicies.encodeMap lp₂) :
    ∀ a : ActorId, lp₁.lookup a = lp₂.lookup a := by
  intro a
  have h_equiv : lp₁.Equiv lp₂ :=
    LocalPolicies.encodeMap_injective lp₁ lp₂
      h_len₁ h_len₂ h_size₁ h_size₂ h_pol₁ h_pol₂ h
  unfold LocalPolicies.lookup
  rw [Std.TreeMap.Equiv.getElem?_eq h_equiv]

end Encoding
end LegalKernel

-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.BridgeInjective — Encoder injectivity (EI.6 + EI.7)
for the `BridgeState` codec.

Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.6 + §4.7).
Closes the per-sub-state injectivity obligation for the two map-backed
sub-fields of `BridgeState` plus the concatenation-form headline
theorem for `BridgeState.encode`.

This file ships nine theorems:

  * **EI.6.a** `Bridge.DepositRecord.encode_injective` — inner-record
    injectivity (structural `Eq` on the 2-field record).  Routes
    through `depositRecord_roundtrip` (already shipped).

  * **EI.6.b** `Bridge.DepositRecord.encodeAsBytes_injective` — framing
    injectivity for the byte-wrapped record encoder.

  * **EI.6.c** `Bridge.BridgeState.encodeConsumed_injective` — outer-map
    injectivity for the `consumed : TreeMap DepositId DepositRecord
    compare` sub-state.  Conclusion is `Std.TreeMap.Equiv` on the
    underlying maps.

  * **EI.7.a** `Bridge.EthAddress.toBytes_injective` — direct
    application of the existing `EthAddress.ofBytes_toBytes` round-trip.

  * **EI.7.b** `Bridge.PendingWithdrawal.encode_injective` — inner-record
    injectivity for the 4-field `PendingWithdrawal` struct.  Routes
    through the `pendingWithdrawal_roundtrip` precursor (also shipped
    in this workstream).

  * **EI.7.c** `Bridge.PendingWithdrawal.encodeAsBytes_injective` —
    framing injectivity for the byte-wrapped withdrawal encoder.

  * **EI.7.d** `Bridge.BridgeState.encodePending_injective` — outer-map
    injectivity for the `pending : TreeMap WithdrawalId
    PendingWithdrawal compare` sub-state.

  * **EI.7.e** `Bridge.BridgeState.encode_injective` — the
    three-segment concatenation injectivity.  Decomposes the bytes
    via `encodeSortedPairs_self_delim_split` (a new helper in
    `Encoding/State.lean`) plus `nat_encode_injective` for the
    final `nextWdId` segment.  Concludes
    `consumed.Equiv ∧ pending.Equiv ∧ nextWdId.Eq`.

Per OQ-EI-2's resolution (mirroring EI.2's), the `*.encodeAsBytes`
framing helpers were promoted from `private` to non-private so the
framing-injectivity lemmas can co-locate with their headline siblings
here rather than living inside `Encoding/State.lean`.

This module is **not** part of the trusted computing base.  `#print
axioms` on every theorem must remain ⊆
`[propext, Classical.choice, Quot.sound]`.
-/

import LegalKernel.Encoding.State

open Std

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority

/-! ## EI.6.a — `Bridge.DepositRecord.encode_injective`

The inner-record injectivity theorem.  `DepositRecord` is the 4-field
record `{ resource, userAmount, poolAmount, budgetGrant }` (GP.4.1
widening); equal canonical encodings imply structural equality.

Routes through `depositRecord_roundtrip` (`Encoding/State.lean`):
both records decode to `.ok (rec_i, [])`; transitivity through the
shared byte stream forces the decoded records to coincide. -/

/-- EI.6.a — `Bridge.DepositRecord.encode_injective`.  Equal canonical
    encodings imply structural equality on the 4-field record.

    **Hypotheses.**  Canonical-encoding bounds on all four fields of
    both inputs.  `resource.toNat < 2^64` is automatic (UInt64), but is
    propagated through the per-pair list-element bounds in the outer
    `BridgeState.encodeConsumed` proof.  The `userAmount` / `poolAmount`
    / `budgetGrant` bounds are deployment-level constraints enforced at
    the runtime boundary (§8.5). -/
theorem Bridge.DepositRecord.encode_injective
    (rec₁ rec₂ : Bridge.DepositRecord)
    (h₁ : rec₁.resource.toNat < 256 ^ 8 ∧ rec₁.userAmount < 256 ^ 8 ∧
          rec₁.poolAmount < 256 ^ 8 ∧ rec₁.budgetGrant < 256 ^ 8)
    (h₂ : rec₂.resource.toNat < 256 ^ 8 ∧ rec₂.userAmount < 256 ^ 8 ∧
          rec₂.poolAmount < 256 ^ 8 ∧ rec₂.budgetGrant < 256 ^ 8)
    (h : Bridge.DepositRecord.encode rec₁ = Bridge.DepositRecord.encode rec₂) :
    rec₁ = rec₂ := by
  have r₁ := depositRecord_roundtrip rec₁ [] h₁
  have r₂ := depositRecord_roundtrip rec₂ [] h₂
  simp at r₁ r₂
  rw [h] at r₁
  have heq : (Except.ok (rec₁, ([] : Stream))
            : Except DecodeError (Bridge.DepositRecord × Stream))
           = Except.ok (rec₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-! ## EI.6.b — `Bridge.DepositRecord.encodeAsBytes_injective`

Framing injectivity for the byte-wrapped DepositRecord encoder.
Direct application of `encodeAsBytes_eq_injective_of_encode_eq_injective`
(EI.1.d Eq-variant) with EI.6.a as the inner injectivity. -/

/-- EI.6.b — `Bridge.DepositRecord.encodeAsBytes_injective`.  The
    framing wrapper preserves structural injectivity through to `Eq`
    on the inner record.  Same bounds hypotheses as EI.6.a. -/
theorem Bridge.DepositRecord.encodeAsBytes_injective
    (rec₁ rec₂ : Bridge.DepositRecord)
    (h₁ : rec₁.resource.toNat < 256 ^ 8 ∧ rec₁.userAmount < 256 ^ 8 ∧
          rec₁.poolAmount < 256 ^ 8 ∧ rec₁.budgetGrant < 256 ^ 8)
    (h₂ : rec₂.resource.toNat < 256 ^ 8 ∧ rec₂.userAmount < 256 ^ 8 ∧
          rec₂.poolAmount < 256 ^ 8 ∧ rec₂.budgetGrant < 256 ^ 8)
    (h : Bridge.DepositRecord.encodeAsBytes rec₁ = Bridge.DepositRecord.encodeAsBytes rec₂) :
    rec₁ = rec₂ := by
  unfold Bridge.DepositRecord.encodeAsBytes at h
  have h_arr : (Bridge.DepositRecord.encode rec₁).toArray
             = (Bridge.DepositRecord.encode rec₂).toArray := by
    injection h
  have h_list : (Bridge.DepositRecord.encode rec₁).toArray.toList
              = (Bridge.DepositRecord.encode rec₂).toArray.toList := by
    rw [h_arr]
  rw [List.toList_toArray, List.toList_toArray] at h_list
  exact Bridge.DepositRecord.encode_injective rec₁ rec₂ h₁ h₂ h_list

/-! ## EI.6.c — `Bridge.BridgeState.encodeConsumed_injective`

The outer-map injectivity theorem.  Mirrors EI.5.d's structure (flat
map with `K := Nat, V := ByteArray` via framed inner-record encoding)
but routes through EI.6.b for the inner `DepositRecord` extraction. -/

/-- Internal helper: named outer-projection used by
    `Bridge.BridgeState.encodeConsumed`. -/
private def Bridge.BridgeState.consumedProj
    (p : Bridge.DepositId × Bridge.DepositRecord) : Nat × ByteArray :=
  (p.1, Bridge.DepositRecord.encodeAsBytes p.2)

/-- Internal helper: outer-projection rewriting of
    `Bridge.BridgeState.encodeConsumed`. -/
private theorem bridgeState_encodeConsumed_eq_via_consumedProj
    (bs : Bridge.BridgeState) :
    Bridge.BridgeState.encodeConsumed bs =
    encodeSortedPairs (bs.consumed.toList.map Bridge.BridgeState.consumedProj) := rfl

/-- EI.6.c — `Bridge.BridgeState.encodeConsumed_injective`.  Equal
    canonical encodings of two `consumed`-segment encodings imply
    `Std.TreeMap.Equiv` on the underlying consumed maps.

    **Hypotheses.**  Canonical-encoding bounds on the pair-list
    length, per-deposit-id < 2^64 (automatic — `DepositId := Nat` is
    used as a key, and the encoded count is bounded by the head),
    per-record framed-bytes-size < 2^64, and per-record canonical
    bounds (the resource, userAmount, poolAmount, and budgetGrant
    fields).

    Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.6
    EI.6.c). -/
theorem Bridge.BridgeState.encodeConsumed_injective
    (bs₁ bs₂ : Bridge.BridgeState)
    (h_len₁ : bs₁.consumed.toList.length < 256 ^ 8)
    (h_len₂ : bs₂.consumed.toList.length < 256 ^ 8)
    (h_id₁ : ∀ p ∈ bs₁.consumed.toList, p.1 < 256 ^ 8)
    (h_id₂ : ∀ p ∈ bs₂.consumed.toList, p.1 < 256 ^ 8)
    (h_size₁ : ∀ p ∈ bs₁.consumed.toList,
                (Bridge.DepositRecord.encodeAsBytes p.2).size < 256 ^ 8)
    (h_size₂ : ∀ p ∈ bs₂.consumed.toList,
                (Bridge.DepositRecord.encodeAsBytes p.2).size < 256 ^ 8)
    (h_rec₁ : ∀ p ∈ bs₁.consumed.toList,
                p.2.resource.toNat < 256 ^ 8 ∧ p.2.userAmount < 256 ^ 8 ∧
                p.2.poolAmount < 256 ^ 8 ∧ p.2.budgetGrant < 256 ^ 8)
    (h_rec₂ : ∀ p ∈ bs₂.consumed.toList,
                p.2.resource.toNat < 256 ^ 8 ∧ p.2.userAmount < 256 ^ 8 ∧
                p.2.poolAmount < 256 ^ 8 ∧ p.2.budgetGrant < 256 ^ 8)
    (h : Bridge.BridgeState.encodeConsumed bs₁ =
         Bridge.BridgeState.encodeConsumed bs₂) :
    bs₁.consumed.Equiv bs₂.consumed := by
  -- Step A: rewrite via the named outer-projection form.
  rw [bridgeState_encodeConsumed_eq_via_consumedProj,
      bridgeState_encodeConsumed_eq_via_consumedProj] at h
  -- Step B: pair-list length bounds.
  have h_plen₁ : (bs₁.consumed.toList.map Bridge.BridgeState.consumedProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₁
  have h_plen₂ : (bs₂.consumed.toList.map Bridge.BridgeState.consumedProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₂
  -- Step C: per-pair round-trip hypotheses for the key carrier (Nat).
  have hK₁ : ∀ p ∈ bs₁.consumed.toList.map Bridge.BridgeState.consumedProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.DepositRecord.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_id₁ q hq_mem
    exact nat_roundtrip p.1 rest hp_bound
  have hK₂ : ∀ p ∈ bs₂.consumed.toList.map Bridge.BridgeState.consumedProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.DepositRecord.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_id₂ q hq_mem
    exact nat_roundtrip p.1 rest hp_bound
  -- Step D: per-pair round-trip hypotheses for the value carrier (ByteArray).
  have hV₁ : ∀ p ∈ bs₁.consumed.toList.map Bridge.BridgeState.consumedProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.DepositRecord.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_size₁ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  have hV₂ : ∀ p ∈ bs₂.consumed.toList.map Bridge.BridgeState.consumedProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.DepositRecord.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_size₂ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  -- Step E: invoke encodeSortedPairs_injective_bounded.
  have h_pairs : bs₁.consumed.toList.map Bridge.BridgeState.consumedProj
               = bs₂.consumed.toList.map Bridge.BridgeState.consumedProj :=
    encodeSortedPairs_injective_bounded
      (bs₁.consumed.toList.map Bridge.BridgeState.consumedProj)
      (bs₂.consumed.toList.map Bridge.BridgeState.consumedProj)
      h_plen₁ h_plen₂ hK₁ hV₁ hK₂ hV₂ h
  -- Step F: extract per-index actor-id and inner-bytes equality,
  -- then lift the inner-bytes equality to record equality via EI.6.b.
  have h_outer_len : bs₁.consumed.toList.length = bs₂.consumed.toList.length := by
    have := congrArg List.length h_pairs
    rw [List.length_map, List.length_map] at this
    exact this
  have h_toList : bs₁.consumed.toList = bs₂.consumed.toList := by
    apply List.ext_getElem
    · exact h_outer_len
    · intro i hi₁ _
      have hi₂ : i < bs₂.consumed.toList.length := h_outer_len ▸ hi₁
      have h_get_map₁ :
          (bs₁.consumed.toList.map Bridge.BridgeState.consumedProj)[i]'(by
              rw [List.length_map]; exact hi₁)
          = Bridge.BridgeState.consumedProj (bs₁.consumed.toList[i]'hi₁) := List.getElem_map _
      have h_get_map₂ :
          (bs₂.consumed.toList.map Bridge.BridgeState.consumedProj)[i]'(by
              rw [List.length_map]; exact hi₂)
          = Bridge.BridgeState.consumedProj (bs₂.consumed.toList[i]'hi₂) := List.getElem_map _
      have h_proj_idx :
          Bridge.BridgeState.consumedProj (bs₁.consumed.toList[i]'hi₁)
          = Bridge.BridgeState.consumedProj (bs₂.consumed.toList[i]'hi₂) := by
        rw [← h_get_map₁, ← h_get_map₂]
        simp only [h_pairs]
      unfold Bridge.BridgeState.consumedProj at h_proj_idx
      -- Extract the per-component equalities via Prod.mk.injEq.
      have h_components := (Prod.mk.injEq _ _ _ _).mp h_proj_idx
      have h_id : bs₁.consumed.toList[i].1 = bs₂.consumed.toList[i].1 := h_components.1
      have h_bytes :
          Bridge.DepositRecord.encodeAsBytes bs₁.consumed.toList[i].2
        = Bridge.DepositRecord.encodeAsBytes bs₂.consumed.toList[i].2 := h_components.2
      have hp_mem₁ : bs₁.consumed.toList[i] ∈ bs₁.consumed.toList := List.getElem_mem hi₁
      have hp_mem₂ : bs₂.consumed.toList[i] ∈ bs₂.consumed.toList := List.getElem_mem hi₂
      have h_rec : bs₁.consumed.toList[i].2 = bs₂.consumed.toList[i].2 :=
        Bridge.DepositRecord.encodeAsBytes_injective
          bs₁.consumed.toList[i].2 bs₂.consumed.toList[i].2
          (h_rec₁ _ hp_mem₁) (h_rec₂ _ hp_mem₂) h_bytes
      have : (bs₁.consumed.toList[i].1, bs₁.consumed.toList[i].2)
           = (bs₂.consumed.toList[i].1, bs₂.consumed.toList[i].2) := by
        rw [h_id, h_rec]
      cases h_lhs : bs₁.consumed.toList[i] with
      | mk d₁ r₁ =>
        cases h_rhs : bs₂.consumed.toList[i] with
        | mk d₂ r₂ =>
          rw [h_lhs, h_rhs] at this
          exact this
  exact Std.TreeMap.equiv_iff_toList_eq.mpr h_toList

/-! ## EI.7.a — `Bridge.EthAddress.toBytes_injective`

The L1-address byte-serialisation injectivity.  Direct corollary of
the existing `EthAddress.ofBytes_toBytes` round-trip lemma. -/

/-- EI.7.a — `Bridge.EthAddress.toBytes_injective`.  Two `EthAddress`
    values with equal byte serialisations are equal.

    **Proof.**  `EthAddress.ofBytes` is a left-inverse of `toBytes`
    (`EthAddress.ofBytes_toBytes`).  Two equal byte serialisations
    apply the same `ofBytes` decoder, yielding `some a₁ = some a₂`
    which gives `a₁ = a₂` via `Option.some.inj`. -/
theorem Bridge.EthAddress.toBytes_injective
    (e₁ e₂ : Bridge.EthAddress)
    (h : Bridge.EthAddress.toBytes e₁ = Bridge.EthAddress.toBytes e₂) :
    e₁ = e₂ := by
  have r₁ : Bridge.EthAddress.ofBytes (Bridge.EthAddress.toBytes e₁) = some e₁ :=
    Bridge.EthAddress.ofBytes_toBytes e₁
  have r₂ : Bridge.EthAddress.ofBytes (Bridge.EthAddress.toBytes e₂) = some e₂ :=
    Bridge.EthAddress.ofBytes_toBytes e₂
  rw [h] at r₁
  -- r₁ : ofBytes (toBytes e₂) = some e₁
  -- r₂ : ofBytes (toBytes e₂) = some e₂
  have : some e₁ = some e₂ := r₁.symm.trans r₂
  exact Option.some.inj this

/-! ## EI.7.b — `Bridge.PendingWithdrawal.encode_injective`

The inner-record injectivity theorem for the 4-field
`PendingWithdrawal` struct.  Routes through `pendingWithdrawal_roundtrip`
(shipped as part of this workstream's EI.7.b precursor in
`Encoding/State.lean`). -/

/-- EI.7.b — `Bridge.PendingWithdrawal.encode_injective`.  Equal
    canonical encodings imply structural equality on the 4-field
    record.

    **Hypotheses.**  Canonical-encoding bounds on the three `Nat`
    fields (resource, amount, l2LogIndex).  The recipient
    (`EthAddress`) has no explicit bound: `toBytes` always produces
    a fixed 20-byte payload that satisfies the underlying
    `byteArray_roundtrip`'s size bound unconditionally. -/
theorem Bridge.PendingWithdrawal.encode_injective
    (wd₁ wd₂ : Bridge.PendingWithdrawal)
    (h_res₁ : wd₁.resource.toNat < 256 ^ 8)
    (h_amt₁ : wd₁.amount < 256 ^ 8)
    (h_idx₁ : wd₁.l2LogIndex < 256 ^ 8)
    (h_res₂ : wd₂.resource.toNat < 256 ^ 8)
    (h_amt₂ : wd₂.amount < 256 ^ 8)
    (h_idx₂ : wd₂.l2LogIndex < 256 ^ 8)
    (h : Bridge.PendingWithdrawal.encode wd₁ = Bridge.PendingWithdrawal.encode wd₂) :
    wd₁ = wd₂ := by
  have r₁ := pendingWithdrawal_roundtrip wd₁ [] h_res₁ h_amt₁ h_idx₁
  have r₂ := pendingWithdrawal_roundtrip wd₂ [] h_res₂ h_amt₂ h_idx₂
  simp at r₁ r₂
  rw [h] at r₁
  have heq : (Except.ok (wd₁, ([] : Stream))
            : Except DecodeError (Bridge.PendingWithdrawal × Stream))
           = Except.ok (wd₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-! ## EI.7.c — `Bridge.PendingWithdrawal.encodeAsBytes_injective`

Framing injectivity for the byte-wrapped withdrawal encoder.  Direct
application of the byte-level structure-injection argument with
EI.7.b as the inner injectivity. -/

/-- EI.7.c — `Bridge.PendingWithdrawal.encodeAsBytes_injective`.
    Same bound hypotheses as EI.7.b. -/
theorem Bridge.PendingWithdrawal.encodeAsBytes_injective
    (wd₁ wd₂ : Bridge.PendingWithdrawal)
    (h_res₁ : wd₁.resource.toNat < 256 ^ 8)
    (h_amt₁ : wd₁.amount < 256 ^ 8)
    (h_idx₁ : wd₁.l2LogIndex < 256 ^ 8)
    (h_res₂ : wd₂.resource.toNat < 256 ^ 8)
    (h_amt₂ : wd₂.amount < 256 ^ 8)
    (h_idx₂ : wd₂.l2LogIndex < 256 ^ 8)
    (h : Bridge.PendingWithdrawal.encodeAsBytes wd₁ =
         Bridge.PendingWithdrawal.encodeAsBytes wd₂) :
    wd₁ = wd₂ := by
  unfold Bridge.PendingWithdrawal.encodeAsBytes at h
  have h_arr : (Bridge.PendingWithdrawal.encode wd₁).toArray
             = (Bridge.PendingWithdrawal.encode wd₂).toArray := by
    injection h
  have h_list : (Bridge.PendingWithdrawal.encode wd₁).toArray.toList
              = (Bridge.PendingWithdrawal.encode wd₂).toArray.toList := by
    rw [h_arr]
  rw [List.toList_toArray, List.toList_toArray] at h_list
  exact Bridge.PendingWithdrawal.encode_injective wd₁ wd₂
    h_res₁ h_amt₁ h_idx₁ h_res₂ h_amt₂ h_idx₂ h_list

/-! ## EI.7.d — `Bridge.BridgeState.encodePending_injective`

Outer-map injectivity for the pending-withdrawals map.  Mirrors EI.6.c
in structure but routes through EI.7.c for the inner record extraction. -/

/-- Internal helper: named outer-projection used by
    `Bridge.BridgeState.encodePending`. -/
private def Bridge.BridgeState.pendingProj
    (p : Bridge.WithdrawalId × Bridge.PendingWithdrawal) : Nat × ByteArray :=
  (p.1, Bridge.PendingWithdrawal.encodeAsBytes p.2)

/-- Internal helper: outer-projection rewriting of
    `Bridge.BridgeState.encodePending`. -/
private theorem bridgeState_encodePending_eq_via_pendingProj
    (bs : Bridge.BridgeState) :
    Bridge.BridgeState.encodePending bs =
    encodeSortedPairs (bs.pending.toList.map Bridge.BridgeState.pendingProj) := rfl

/-- EI.7.d — `Bridge.BridgeState.encodePending_injective`.  Same shape
    as EI.6.c but for the pending-withdrawals sub-state. -/
theorem Bridge.BridgeState.encodePending_injective
    (bs₁ bs₂ : Bridge.BridgeState)
    (h_len₁ : bs₁.pending.toList.length < 256 ^ 8)
    (h_len₂ : bs₂.pending.toList.length < 256 ^ 8)
    (h_id₁ : ∀ p ∈ bs₁.pending.toList, p.1 < 256 ^ 8)
    (h_id₂ : ∀ p ∈ bs₂.pending.toList, p.1 < 256 ^ 8)
    (h_size₁ : ∀ p ∈ bs₁.pending.toList,
                (Bridge.PendingWithdrawal.encodeAsBytes p.2).size < 256 ^ 8)
    (h_size₂ : ∀ p ∈ bs₂.pending.toList,
                (Bridge.PendingWithdrawal.encodeAsBytes p.2).size < 256 ^ 8)
    (h_wd₁ : ∀ p ∈ bs₁.pending.toList,
              p.2.resource.toNat < 256 ^ 8 ∧
              p.2.amount < 256 ^ 8 ∧
              p.2.l2LogIndex < 256 ^ 8)
    (h_wd₂ : ∀ p ∈ bs₂.pending.toList,
              p.2.resource.toNat < 256 ^ 8 ∧
              p.2.amount < 256 ^ 8 ∧
              p.2.l2LogIndex < 256 ^ 8)
    (h : Bridge.BridgeState.encodePending bs₁ =
         Bridge.BridgeState.encodePending bs₂) :
    bs₁.pending.Equiv bs₂.pending := by
  rw [bridgeState_encodePending_eq_via_pendingProj,
      bridgeState_encodePending_eq_via_pendingProj] at h
  have h_plen₁ : (bs₁.pending.toList.map Bridge.BridgeState.pendingProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₁
  have h_plen₂ : (bs₂.pending.toList.map Bridge.BridgeState.pendingProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_len₂
  have hK₁ : ∀ p ∈ bs₁.pending.toList.map Bridge.BridgeState.pendingProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.PendingWithdrawal.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_id₁ q hq_mem
    exact nat_roundtrip p.1 rest hp_bound
  have hK₂ : ∀ p ∈ bs₂.pending.toList.map Bridge.BridgeState.pendingProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.PendingWithdrawal.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_id₂ q hq_mem
    exact nat_roundtrip p.1 rest hp_bound
  have hV₁ : ∀ p ∈ bs₁.pending.toList.map Bridge.BridgeState.pendingProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.PendingWithdrawal.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_size₁ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  have hV₂ : ∀ p ∈ bs₂.pending.toList.map Bridge.BridgeState.pendingProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.PendingWithdrawal.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_size₂ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  have h_pairs : bs₁.pending.toList.map Bridge.BridgeState.pendingProj
               = bs₂.pending.toList.map Bridge.BridgeState.pendingProj :=
    encodeSortedPairs_injective_bounded
      (bs₁.pending.toList.map Bridge.BridgeState.pendingProj)
      (bs₂.pending.toList.map Bridge.BridgeState.pendingProj)
      h_plen₁ h_plen₂ hK₁ hV₁ hK₂ hV₂ h
  have h_outer_len : bs₁.pending.toList.length = bs₂.pending.toList.length := by
    have := congrArg List.length h_pairs
    rw [List.length_map, List.length_map] at this
    exact this
  have h_toList : bs₁.pending.toList = bs₂.pending.toList := by
    apply List.ext_getElem
    · exact h_outer_len
    · intro i hi₁ _
      have hi₂ : i < bs₂.pending.toList.length := h_outer_len ▸ hi₁
      have h_get_map₁ :
          (bs₁.pending.toList.map Bridge.BridgeState.pendingProj)[i]'(by
              rw [List.length_map]; exact hi₁)
          = Bridge.BridgeState.pendingProj (bs₁.pending.toList[i]'hi₁) := List.getElem_map _
      have h_get_map₂ :
          (bs₂.pending.toList.map Bridge.BridgeState.pendingProj)[i]'(by
              rw [List.length_map]; exact hi₂)
          = Bridge.BridgeState.pendingProj (bs₂.pending.toList[i]'hi₂) := List.getElem_map _
      have h_proj_idx :
          Bridge.BridgeState.pendingProj (bs₁.pending.toList[i]'hi₁)
          = Bridge.BridgeState.pendingProj (bs₂.pending.toList[i]'hi₂) := by
        rw [← h_get_map₁, ← h_get_map₂]
        simp only [h_pairs]
      unfold Bridge.BridgeState.pendingProj at h_proj_idx
      have h_components := (Prod.mk.injEq _ _ _ _).mp h_proj_idx
      have h_id : bs₁.pending.toList[i].1 = bs₂.pending.toList[i].1 := h_components.1
      have h_bytes :
          Bridge.PendingWithdrawal.encodeAsBytes bs₁.pending.toList[i].2
        = Bridge.PendingWithdrawal.encodeAsBytes bs₂.pending.toList[i].2 := h_components.2
      have hp_mem₁ : bs₁.pending.toList[i] ∈ bs₁.pending.toList := List.getElem_mem hi₁
      have hp_mem₂ : bs₂.pending.toList[i] ∈ bs₂.pending.toList := List.getElem_mem hi₂
      have h_wd_bounds₁ := h_wd₁ _ hp_mem₁
      have h_wd_bounds₂ := h_wd₂ _ hp_mem₂
      have h_wd : bs₁.pending.toList[i].2 = bs₂.pending.toList[i].2 :=
        Bridge.PendingWithdrawal.encodeAsBytes_injective
          bs₁.pending.toList[i].2 bs₂.pending.toList[i].2
          h_wd_bounds₁.1 h_wd_bounds₁.2.1 h_wd_bounds₁.2.2
          h_wd_bounds₂.1 h_wd_bounds₂.2.1 h_wd_bounds₂.2.2
          h_bytes
      have : (bs₁.pending.toList[i].1, bs₁.pending.toList[i].2)
           = (bs₂.pending.toList[i].1, bs₂.pending.toList[i].2) := by
        rw [h_id, h_wd]
      cases h_lhs : bs₁.pending.toList[i] with
      | mk d₁ r₁ =>
        cases h_rhs : bs₂.pending.toList[i] with
        | mk d₂ r₂ =>
          rw [h_lhs, h_rhs] at this
          exact this
  exact Std.TreeMap.equiv_iff_toList_eq.mpr h_toList

/-! ## Helper: self-delimiting Nat split

    Given `enc(n₁) ++ rest₁ = enc(n₂) ++ rest₂` where both Nats are
    in the CBE canonical range, recover `n₁ = n₂ ∧ rest₁ = rest₂`.
    Used to split the 6-Nat tail of the GP.11.8 extended encoding. -/

/-- Self-delimiting split for a single CBE-encoded `Nat` prefix.
    Under the canonical `< 2^64` bound, equal concatenations of
    an encoded Nat followed by arbitrary trailing bytes imply the
    Nat values agree and the suffixes agree. -/
private theorem nat_encode_suffix_split
    (n₁ n₂ : Nat) (rest₁ rest₂ : Stream)
    (h₁ : n₁ < 256 ^ 8) (h₂ : n₂ < 256 ^ 8)
    (h : Encodable.encode (T := Nat) n₁ ++ rest₁ =
         Encodable.encode (T := Nat) n₂ ++ rest₂) :
    n₁ = n₂ ∧ rest₁ = rest₂ := by
  have r₁ := nat_roundtrip n₁ rest₁ h₁
  have r₂ := nat_roundtrip n₂ rest₂ h₂
  rw [h] at r₁
  have heq : (Except.ok (n₁, rest₁) : Except DecodeError (Nat × Stream))
           = Except.ok (n₂, rest₂) := r₁.symm.trans r₂
  have hprod := Prod.mk.injEq n₁ rest₁ n₂ rest₂ |>.mp (Except.ok.inj heq)
  exact ⟨hprod.1, hprod.2⟩

/-! ## Bool-as-Nat injectivity

    `boldCircuitClosed` is encoded as `if b then 1 else 0`.  Equal
    Nat images imply equal Bools. -/

/-- If `(if b₁ then 1 else 0) = (if b₂ then 1 else 0)` then `b₁ = b₂`. -/
private theorem bool_as_nat_injective (b₁ b₂ : Bool)
    (h : (if b₁ then 1 else 0 : Nat) = (if b₂ then 1 else 0 : Nat)) :
    b₁ = b₂ := by
  cases b₁ <;> cases b₂ <;> simp_all

/-! ## EI.7.e — `Bridge.BridgeState.encode_injective`

The eight-segment concatenation injectivity headline theorem (GP.11.8).
`Bridge.BridgeState.encode bs = encodeConsumed bs ++ encodePending bs
++ encode_nat bs.nextWdId ++ encode_nat bs.ammReserveEth ++
encode_nat bs.ammReserveBold ++ encode_nat (boolToNat bs.boldCircuitClosed)
++ encode_nat bs.boldTvlCap ++ encode_nat bs.boldTotalLockedValue`
is a flat concatenation of two CBE maps plus six CBE Nat segments.

Proof structure:

  1. Apply `encodeSortedPairs_self_delim_split` to the `encodeConsumed`
     prefix to extract consumed-equality and the trailing suffix.
  2. Apply EI.6.c to derive `bs₁.consumed.Equiv bs₂.consumed`.
  3. Repeat step 1 on the pending segment.
  4. Apply EI.7.d to derive `bs₁.pending.Equiv bs₂.pending`.
  5. Apply `nat_encode_suffix_split` six times to extract the
     remaining Nat fields.
  6. Apply `bool_as_nat_injective` for `boldCircuitClosed`.
-/

/-- EI.7.e — `Bridge.BridgeState.encode_injective`.  Equal canonical
    encodings of two `BridgeState`s imply (1) `Equiv` on the consumed
    map, (2) `Equiv` on the pending map, (3) `Eq` on `nextWdId`, and
    (4–8) `Eq` on the five GP.11.8 AMM/BOLD state fields.

    **Hypotheses.**  Inherits the bounds from EI.6.c (consumed map)
    and EI.7.d (pending map) plus per-field `< 2^64` bounds for the
    six trailing CBE Nats (the Bool field's bound is discharged
    inline since `if b then 1 else 0 < 256^8` is trivial). -/
theorem Bridge.BridgeState.encode_injective
    (bs₁ bs₂ : Bridge.BridgeState)
    (h_cons_len₁ : bs₁.consumed.toList.length < 256 ^ 8)
    (h_cons_len₂ : bs₂.consumed.toList.length < 256 ^ 8)
    (h_cons_id₁ : ∀ p ∈ bs₁.consumed.toList, p.1 < 256 ^ 8)
    (h_cons_id₂ : ∀ p ∈ bs₂.consumed.toList, p.1 < 256 ^ 8)
    (h_cons_size₁ : ∀ p ∈ bs₁.consumed.toList,
                  (Bridge.DepositRecord.encodeAsBytes p.2).size < 256 ^ 8)
    (h_cons_size₂ : ∀ p ∈ bs₂.consumed.toList,
                  (Bridge.DepositRecord.encodeAsBytes p.2).size < 256 ^ 8)
    (h_cons_rec₁ : ∀ p ∈ bs₁.consumed.toList,
                  p.2.resource.toNat < 256 ^ 8 ∧ p.2.userAmount < 256 ^ 8 ∧
                  p.2.poolAmount < 256 ^ 8 ∧ p.2.budgetGrant < 256 ^ 8)
    (h_cons_rec₂ : ∀ p ∈ bs₂.consumed.toList,
                  p.2.resource.toNat < 256 ^ 8 ∧ p.2.userAmount < 256 ^ 8 ∧
                  p.2.poolAmount < 256 ^ 8 ∧ p.2.budgetGrant < 256 ^ 8)
    (h_pend_len₁ : bs₁.pending.toList.length < 256 ^ 8)
    (h_pend_len₂ : bs₂.pending.toList.length < 256 ^ 8)
    (h_pend_id₁ : ∀ p ∈ bs₁.pending.toList, p.1 < 256 ^ 8)
    (h_pend_id₂ : ∀ p ∈ bs₂.pending.toList, p.1 < 256 ^ 8)
    (h_pend_size₁ : ∀ p ∈ bs₁.pending.toList,
                  (Bridge.PendingWithdrawal.encodeAsBytes p.2).size < 256 ^ 8)
    (h_pend_size₂ : ∀ p ∈ bs₂.pending.toList,
                  (Bridge.PendingWithdrawal.encodeAsBytes p.2).size < 256 ^ 8)
    (h_pend_wd₁ : ∀ p ∈ bs₁.pending.toList,
                  p.2.resource.toNat < 256 ^ 8 ∧
                  p.2.amount < 256 ^ 8 ∧
                  p.2.l2LogIndex < 256 ^ 8)
    (h_pend_wd₂ : ∀ p ∈ bs₂.pending.toList,
                  p.2.resource.toNat < 256 ^ 8 ∧
                  p.2.amount < 256 ^ 8 ∧
                  p.2.l2LogIndex < 256 ^ 8)
    (h_nxt₁ : bs₁.nextWdId < 256 ^ 8)
    (h_nxt₂ : bs₂.nextWdId < 256 ^ 8)
    (h_ammEth₁ : bs₁.ammReserveEth < 256 ^ 8)
    (h_ammEth₂ : bs₂.ammReserveEth < 256 ^ 8)
    (h_ammBold₁ : bs₁.ammReserveBold < 256 ^ 8)
    (h_ammBold₂ : bs₂.ammReserveBold < 256 ^ 8)
    (h_tvlCap₁ : bs₁.boldTvlCap < 256 ^ 8)
    (h_tvlCap₂ : bs₂.boldTvlCap < 256 ^ 8)
    (h_totalLocked₁ : bs₁.boldTotalLockedValue < 256 ^ 8)
    (h_totalLocked₂ : bs₂.boldTotalLockedValue < 256 ^ 8)
    (h : Bridge.BridgeState.encode bs₁ = Bridge.BridgeState.encode bs₂) :
    bs₁.consumed.Equiv bs₂.consumed ∧
    bs₁.pending.Equiv bs₂.pending ∧
    bs₁.nextWdId = bs₂.nextWdId ∧
    bs₁.ammReserveEth = bs₂.ammReserveEth ∧
    bs₁.ammReserveBold = bs₂.ammReserveBold ∧
    bs₁.boldCircuitClosed = bs₂.boldCircuitClosed ∧
    bs₁.boldTvlCap = bs₂.boldTvlCap ∧
    bs₁.boldTotalLockedValue = bs₂.boldTotalLockedValue := by
  -- Unfold encode to expose the eight-segment concatenation.
  unfold Bridge.BridgeState.encode at h
  -- Step 1: Split the consumed prefix from the rest.
  rw [bridgeState_encodeConsumed_eq_via_consumedProj,
      bridgeState_encodeConsumed_eq_via_consumedProj] at h
  have h_cons_plen₁ : (bs₁.consumed.toList.map Bridge.BridgeState.consumedProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_cons_len₁
  have h_cons_plen₂ : (bs₂.consumed.toList.map Bridge.BridgeState.consumedProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_cons_len₂
  have h_cons_hK₁ : ∀ p ∈ bs₁.consumed.toList.map Bridge.BridgeState.consumedProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.DepositRecord.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_cons_id₁ q hq_mem
    exact nat_roundtrip p.1 rest hp_bound
  have h_cons_hK₂ : ∀ p ∈ bs₂.consumed.toList.map Bridge.BridgeState.consumedProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.DepositRecord.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_cons_id₂ q hq_mem
    exact nat_roundtrip p.1 rest hp_bound
  have h_cons_hV₁ : ∀ p ∈ bs₁.consumed.toList.map Bridge.BridgeState.consumedProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.DepositRecord.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_cons_size₁ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  have h_cons_hV₂ : ∀ p ∈ bs₂.consumed.toList.map Bridge.BridgeState.consumedProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.DepositRecord.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_cons_size₂ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  -- Re-associate so the consumed prefix is followed by one suffix.
  simp only [List.append_assoc] at h
  have h_split_cons :=
    encodeSortedPairs_self_delim_split
      (bs₁.consumed.toList.map Bridge.BridgeState.consumedProj)
      (bs₂.consumed.toList.map Bridge.BridgeState.consumedProj)
      h_cons_plen₁ h_cons_plen₂
      h_cons_hK₁ h_cons_hV₁ h_cons_hK₂ h_cons_hV₂
      _ _ h
  have h_cons_bytes : Bridge.BridgeState.encodeConsumed bs₁
                   = Bridge.BridgeState.encodeConsumed bs₂ := by
    rw [bridgeState_encodeConsumed_eq_via_consumedProj,
        bridgeState_encodeConsumed_eq_via_consumedProj]
    rw [h_split_cons.1]
  have h_consumed : bs₁.consumed.Equiv bs₂.consumed :=
    Bridge.BridgeState.encodeConsumed_injective bs₁ bs₂
      h_cons_len₁ h_cons_len₂ h_cons_id₁ h_cons_id₂
      h_cons_size₁ h_cons_size₂ h_cons_rec₁ h_cons_rec₂ h_cons_bytes
  -- Step 2: Split the pending prefix from the trailing Nat tail.
  have h_suffix := h_split_cons.2
  rw [bridgeState_encodePending_eq_via_pendingProj,
      bridgeState_encodePending_eq_via_pendingProj] at h_suffix
  have h_pend_plen₁ : (bs₁.pending.toList.map Bridge.BridgeState.pendingProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_pend_len₁
  have h_pend_plen₂ : (bs₂.pending.toList.map Bridge.BridgeState.pendingProj).length < 256 ^ 8 := by
    rw [List.length_map]; exact h_pend_len₂
  have h_pend_hK₁ : ∀ p ∈ bs₁.pending.toList.map Bridge.BridgeState.pendingProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.PendingWithdrawal.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_pend_id₁ q hq_mem
    exact nat_roundtrip p.1 rest hp_bound
  have h_pend_hK₂ : ∀ p ∈ bs₂.pending.toList.map Bridge.BridgeState.pendingProj,
              ∀ (rest : Stream),
                Encodable.decode (T := Nat) (Encodable.encode p.1 ++ rest) =
                  .ok (p.1, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_bound : p.1 < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.PendingWithdrawal.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_pend_id₂ q hq_mem
    exact nat_roundtrip p.1 rest hp_bound
  have h_pend_hV₁ : ∀ p ∈ bs₁.pending.toList.map Bridge.BridgeState.pendingProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.PendingWithdrawal.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_pend_size₁ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  have h_pend_hV₂ : ∀ p ∈ bs₂.pending.toList.map Bridge.BridgeState.pendingProj,
              ∀ (rest : Stream),
                Encodable.decode (T := ByteArray) (Encodable.encode p.2 ++ rest) =
                  .ok (p.2, rest) := by
    intro p hp_mem rest
    obtain ⟨q, hq_mem, hq_eq⟩ := List.mem_map.mp hp_mem
    have hp_size : p.2.size < 256 ^ 8 := by
      have h_proj : p = (q.1, Bridge.PendingWithdrawal.encodeAsBytes q.2) := by
        rw [← hq_eq]; rfl
      rw [h_proj]; exact h_pend_size₂ q hq_mem
    exact byteArray_roundtrip p.2 rest hp_size
  have h_split_pend :=
    encodeSortedPairs_self_delim_split
      (bs₁.pending.toList.map Bridge.BridgeState.pendingProj)
      (bs₂.pending.toList.map Bridge.BridgeState.pendingProj)
      h_pend_plen₁ h_pend_plen₂
      h_pend_hK₁ h_pend_hV₁ h_pend_hK₂ h_pend_hV₂
      _ _ h_suffix
  have h_pend_bytes : Bridge.BridgeState.encodePending bs₁
                   = Bridge.BridgeState.encodePending bs₂ := by
    rw [bridgeState_encodePending_eq_via_pendingProj,
        bridgeState_encodePending_eq_via_pendingProj]
    rw [h_split_pend.1]
  have h_pending : bs₁.pending.Equiv bs₂.pending :=
    Bridge.BridgeState.encodePending_injective bs₁ bs₂
      h_pend_len₁ h_pend_len₂ h_pend_id₁ h_pend_id₂
      h_pend_size₁ h_pend_size₂ h_pend_wd₁ h_pend_wd₂ h_pend_bytes
  -- Step 3: Chain-split the six trailing Nat encodings via
  -- `nat_encode_suffix_split`.  Each application extracts one
  -- Nat equality and advances to the next segment.
  have h_nat_tail := h_split_pend.2
  -- Split nextWdId.
  have ⟨h_nxt, h_after_nxt⟩ :=
    nat_encode_suffix_split bs₁.nextWdId bs₂.nextWdId _ _ h_nxt₁ h_nxt₂ h_nat_tail
  -- Split ammReserveEth.
  have ⟨h_ammEth, h_after_ammEth⟩ :=
    nat_encode_suffix_split bs₁.ammReserveEth bs₂.ammReserveEth _ _
      h_ammEth₁ h_ammEth₂ h_after_nxt
  -- Split ammReserveBold.
  have ⟨h_ammBold, h_after_ammBold⟩ :=
    nat_encode_suffix_split bs₁.ammReserveBold bs₂.ammReserveBold _ _
      h_ammBold₁ h_ammBold₂ h_after_ammEth
  -- Split boldCircuitClosed (encoded as Nat 0/1).
  have h_circuitBound₁ : (if bs₁.boldCircuitClosed then 1 else 0 : Nat) < 256 ^ 8 := by
    have : (1 : Nat) < 256 ^ 8 := by decide
    split <;> omega
  have h_circuitBound₂ : (if bs₂.boldCircuitClosed then 1 else 0 : Nat) < 256 ^ 8 := by
    have : (1 : Nat) < 256 ^ 8 := by decide
    split <;> omega
  have ⟨h_circuitNat, h_after_circuit⟩ :=
    nat_encode_suffix_split
      (if bs₁.boldCircuitClosed then 1 else 0)
      (if bs₂.boldCircuitClosed then 1 else 0)
      _ _ h_circuitBound₁ h_circuitBound₂ h_after_ammBold
  have h_circuit : bs₁.boldCircuitClosed = bs₂.boldCircuitClosed :=
    bool_as_nat_injective _ _ h_circuitNat
  -- Split boldTvlCap.
  have ⟨h_tvlCap, h_after_tvlCap⟩ :=
    nat_encode_suffix_split bs₁.boldTvlCap bs₂.boldTvlCap _ _
      h_tvlCap₁ h_tvlCap₂ h_after_circuit
  -- Split boldTotalLockedValue (final segment — suffix must be []).
  have h_totalLocked : bs₁.boldTotalLockedValue = bs₂.boldTotalLockedValue :=
    nat_encode_injective bs₁.boldTotalLockedValue bs₂.boldTotalLockedValue
      h_totalLocked₁ h_totalLocked₂ h_after_tvlCap
  exact ⟨h_consumed, h_pending, h_nxt, h_ammEth, h_ammBold, h_circuit,
         h_tvlCap, h_totalLocked⟩

end Encoding
end LegalKernel

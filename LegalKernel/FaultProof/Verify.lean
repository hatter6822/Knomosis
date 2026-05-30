-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Verify — `verifyCellProof` and friends
(Workstream H §12 / WUs H.3.3 + H.3.4).

The L1 step VM consumes cell proofs (`CellProof`s) for every
cell the step reads or writes.  This module specifies how those
proofs are *verified* against the committed state root.

**Witness-state-based verification** (first-pass design,
mathematically sound, optimisable to SMT for L1 gas).

A `CellProof` carries a witness `ExtendedState` plus the cell
tag and value.  Verification:
  1. Recommit the witness state.
  2. Check the recommit equals the public state root.
  3. Check the witness state has the claimed cell value at the
     claimed tag.

Under `CollisionFree hashBytes`, condition 1 plus
`commitExtendedState`'s injectivity (theorem #220) makes the
witness state unique up to extensional equality.  Condition 3
then authoritatively binds the cell value to the underlying
state.

**Helper functions for the L1 step VM (WU H.1.2 contract):**

  * `getCellValue es tag` — read a single cell from a state.
  * `setCell es tag value` — write a single cell to a state.
  * `isCellAbsent es tag` — decidable predicate detecting an
    absent cell.
  * `canonicalAbsentValue tag` — canonical "absent" marker.
  * `buildCellProof es tag` — construct the canonical proof
    for a cell at a state.

**Headline theorems (#221 + #222 + #223):**

  * `verifyCellProof_complete` — the canonical proof for any
    cell at any state always verifies against the state's
    commit.  Unconditional.
  * `verifyCellProof_sound_under_collision_free` — under
    `CollisionFree hashBytes`, a verifying proof's witness state
    has the claimed cell value at the claimed tag.
  * `updateCommitment_agrees_with_setCell` — recomputing the
    commit after writing one cell agrees with `commitExtendedState`
    on the post-state.

This module is **not** part of the trusted computing base.
Theorems hold without `sorry` and depend only on the standard
Lean built-ins (`propext`, `Quot.sound`, `Classical.choice`).
-/

import LegalKernel.Authority.LocalPolicy
import LegalKernel.Bridge.Eip712
import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.Commit

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding

/-! ## Canonical absent values (§12.3.4 / WU H.3.4)

The canonical "absent" value for each cell type is the value
that `getCellValue` returns when the underlying sub-state has no
entry for the cell key. -/

/-- The canonical "absent" value for each cell type:
    * `balance`, `nonce`, `bridgeNextWdId`: CBE-encoded `0`.
    * `registry`, `localPolicy`, `bridgeConsumed`, `bridgePending`:
      empty bytes. -/
def canonicalAbsentValue : CellTag → ByteArray
  | .balance _ _      => ByteArray.mk (Encodable.encode (T := Nat) 0).toArray
  | .nonce _          => ByteArray.mk (Encodable.encode (T := Nat) 0).toArray
  | .registry _       => ByteArray.empty
  | .localPolicy _    => ByteArray.empty
  | .bridgeConsumed _ => ByteArray.empty
  | .bridgePending _  => ByteArray.empty
  | .bridgeNextWdId   => ByteArray.mk (Encodable.encode (T := Nat) 0).toArray

/-! ## `getCellValue` (§12.1.2 helper) -/

/-- Read a single cell's CBE-encoded value from an
    `ExtendedState`.  Total: absent cells return
    `canonicalAbsentValue tag`.

    The byte form matches the encoder's per-cell value layout
    (CBE uint for amounts/nonces; CBE byte string for keys
    /policies/etc.). -/
def getCellValue (es : ExtendedState) (tag : CellTag) : ByteArray :=
  match tag with
  | .balance r a =>
    ByteArray.mk
      (Encodable.encode (T := Nat) (LegalKernel.getBalance es.base r a)).toArray
  | .nonce a =>
    ByteArray.mk
      (Encodable.encode (T := Nat) (Authority.expectsNonce es a)).toArray
  | .registry a =>
    match es.registry[a]? with
    | some pk => pk
    | none    => ByteArray.empty
  | .localPolicy a =>
    -- Encode the policy via its CBE byte string; absent ⇒ empty.
    let p := es.localPolicies.lookup a
    if p.clauses.isEmpty then ByteArray.empty
    else ByteArray.mk
           (Encodable.encode (T := Authority.LocalPolicy) p).toArray
  | .bridgeConsumed d =>
    if es.bridge.consumed.contains d then
      -- Encode the deposit-record bytes (an opaque marker is enough
      -- for cell-value comparison; canonical is the encoded record).
      match es.bridge.consumed[d]? with
      | some rec => ByteArray.mk (Bridge.DepositRecord.encode rec).toArray
      | none     => ByteArray.empty
    else ByteArray.empty
  | .bridgePending wd =>
    match es.bridge.pending[wd]? with
    | some pw => ByteArray.mk (Bridge.PendingWithdrawal.encode pw).toArray
    | none    => ByteArray.empty
  | .bridgeNextWdId =>
    ByteArray.mk
      (Encodable.encode (T := Nat) es.bridge.nextWdId).toArray

/-- Determinism of `getCellValue`: equal states + equal tags
    produce equal cell values.  Mechanical via `rfl`. -/
theorem getCellValue_deterministic
    (es₁ es₂ : ExtendedState) (tag₁ tag₂ : CellTag)
    (h_es : es₁ = es₂) (h_tag : tag₁ = tag₂) :
    getCellValue es₁ tag₁ = getCellValue es₂ tag₂ := by rw [h_es, h_tag]

/-! ## `isCellAbsent` (§12.3.4 helper) -/

/-- Decidable predicate: a cell is "absent" iff its current
    value at the state equals `canonicalAbsentValue tag`. -/
def isCellAbsent (es : ExtendedState) (tag : CellTag) : Prop :=
  getCellValue es tag = canonicalAbsentValue tag

/-- Decidability of `isCellAbsent`.  Reduces to `ByteArray`
    equality (decidable). -/
instance instDecidableIsCellAbsent
    (es : ExtendedState) (tag : CellTag) :
    Decidable (isCellAbsent es tag) := by
  unfold isCellAbsent
  exact inferInstance

/-! ## `setCell` (§12.1.2 helper) -/

/-- Write a single cell's value into an `ExtendedState`.  The
    `value` argument is the CBE-encoded post-cell value.  The
    function decodes the bytes and inserts the result; on a
    decode failure (which shouldn't happen if the verifier is
    composed correctly), returns the original state unchanged.

    This is the L1 step VM's per-cell write primitive.  The
    semantic-correctness theorem `updateCommitment_agrees_with_setCell`
    establishes the agreement with `commitExtendedState`. -/
def setCell (es : ExtendedState) (tag : CellTag) (value : ByteArray) :
    ExtendedState :=
  match tag with
  | .balance r a =>
    -- Decode the value as a Nat; on failure leave the cell unchanged.
    match Encodable.decode (T := Nat) value.data.toList with
    | .ok (v, _) => { es with base := LegalKernel.setBalance es.base r a v }
    | .error _   => es
  | .nonce _a =>
    -- Nonces are bumped by `advanceNonce`, not arbitrarily set.
    -- For verifier-driven write, treat as no-op (the kernel-side
    -- `apply_admissible` is the canonical way to bump nonces).
    es
  | .registry a =>
    -- The bytes ARE the public key (registry stores pk as ByteArray).
    if value.size = 0 then es  -- empty bytes ⇒ no change
    else { es with registry := es.registry.insert a value }
  | .localPolicy a =>
    if value.size = 0 then
      -- Empty bytes ⇒ revoke the policy.
      { es with localPolicies := es.localPolicies.revoke a }
    else
      -- Decode the policy bytes; on success, declare; on failure no-op.
      match Encodable.decode (T := Authority.LocalPolicy) value.data.toList with
      | .ok (p, _) => { es with localPolicies := es.localPolicies.declare a p }
      | .error _   => es
  | .bridgeConsumed d =>
    if value.size = 0 then es  -- empty ⇒ no change
    else
      match Bridge.DepositRecord.decode value.data.toList with
      | .ok (rec, _) => { es with bridge := es.bridge.markConsumed d rec }
      | .error _     => es
  | .bridgePending _wd =>
    -- Pending withdrawals are appended via `appendWithdrawal` (which
    -- assigns a fresh id); arbitrary key writes are a runtime-layer
    -- concern.  No-op at the cell-write level.
    es
  | .bridgeNextWdId =>
    match Encodable.decode (T := Nat) value.data.toList with
    | .ok (n, _) =>
      { es with bridge := { es.bridge with nextWdId := n } }
    | .error _   => es

/-- Determinism of `setCell`. -/
theorem setCell_deterministic
    (es₁ es₂ : ExtendedState) (tag₁ tag₂ : CellTag) (v₁ v₂ : ByteArray)
    (h_es : es₁ = es₂) (h_tag : tag₁ = tag₂) (h_v : v₁ = v₂) :
    setCell es₁ tag₁ v₁ = setCell es₂ tag₂ v₂ := by
  rw [h_es, h_tag, h_v]

/-! ## `buildCellProof` (§12.1.2 helper) -/

/-- Build the canonical cell proof for a given cell of an
    `ExtendedState`.  Total function; the witness state IS the
    state itself (see the witness-state design rationale in
    `Cell.lean`). -/
def buildCellProof (es : ExtendedState) (tag : CellTag) : CellProof where
  cellTag      := tag
  cellValue    := getCellValue es tag
  witnessState := es

/-! ## `verifyCellProof` (§12.3.3) -/

/-- Verify a single cell proof against the committed state root.
    Two checks:
      1. The witness state's recommit equals the public commit.
      2. The witness state's cell at the proof's tag equals the
         proof's claimed value.

    Both checks are decidable; the conjunction is decidable. -/
def verifyCellProof (commit : StateCommit) (proof : CellProof) : Bool :=
  decide (commitExtendedState proof.witnessState = commit) &&
  decide (getCellValue proof.witnessState proof.cellTag = proof.cellValue)

/-- Verify every cell proof in a bundle against the committed
    state root.  All proofs must verify. -/
def verifyCellProofs (commit : StateCommit) (bundle : CellProofBundle) :
    Bool :=
  bundle.proofs.all (fun p => verifyCellProof commit p)

/-- Named decidable instance for `verifyCellProof`. -/
instance instDecidableVerifyCellProof
    (commit : StateCommit) (proof : CellProof) :
    Decidable (verifyCellProof commit proof = true) :=
  inferInstance

/-- Named decidable instance for `verifyCellProofs`. -/
instance instDecidableVerifyCellProofs
    (commit : StateCommit) (bundle : CellProofBundle) :
    Decidable (verifyCellProofs commit bundle = true) :=
  inferInstance

/-! ## Determinism -/

theorem verifyCellProof_deterministic
    (c₁ c₂ : StateCommit) (p₁ p₂ : CellProof)
    (h_c : c₁ = c₂) (h_p : p₁ = p₂) :
    verifyCellProof c₁ p₁ = verifyCellProof c₂ p₂ := by rw [h_c, h_p]

theorem verifyCellProofs_deterministic
    (c₁ c₂ : StateCommit) (b₁ b₂ : CellProofBundle)
    (h_c : c₁ = c₂) (h_b : b₁ = b₂) :
    verifyCellProofs c₁ b₁ = verifyCellProofs c₂ b₂ := by rw [h_c, h_b]

/-! ## #221 — Verifier completeness (unconditional) -/

/-- The canonical cell proof for any cell at any state always
    verifies against that state's commit.  Unconditional —
    no `CollisionFree` hypothesis needed for completeness. -/
theorem verifyCellProof_complete (es : ExtendedState) (tag : CellTag) :
    verifyCellProof (commitExtendedState es) (buildCellProof es tag) = true := by
  unfold verifyCellProof buildCellProof
  -- The two `decide` checks reduce by definitional equality.
  simp

/-- Empty-bundle verification trivially succeeds. -/
theorem verifyCellProofs_empty (commit : StateCommit) :
    verifyCellProofs commit CellProofBundle.empty = true := rfl

/-- Singleton-bundle verification reduces to per-proof. -/
theorem verifyCellProofs_singleton
    (commit : StateCommit) (p : CellProof) :
    verifyCellProofs commit { proofs := [p] } =
    verifyCellProof commit p := by
  unfold verifyCellProofs
  simp

/-- Bundle-level completeness corollary: every bundle of canonical
    proofs at the same state verifies. -/
theorem verifyCellProofs_complete_for_canonical_bundle
    (es : ExtendedState) (tags : List CellTag) :
    verifyCellProofs (commitExtendedState es)
      { proofs := tags.map (fun t => buildCellProof es t) } = true := by
  unfold verifyCellProofs
  simp only [List.all_eq_true, List.mem_map]
  intro p hp
  obtain ⟨t, _, rfl⟩ := hp
  exact verifyCellProof_complete es t

/-! ## #222 — Verifier soundness under `CollisionFree` -/

/-- A verifying proof's witness state recommits to the public
    commit.  Direct from the verifier's first check. -/
theorem verifyCellProof_witness_recommits
    (commit : StateCommit) (proof : CellProof)
    (h : verifyCellProof commit proof = true) :
    commitExtendedState proof.witnessState = commit := by
  unfold verifyCellProof at h
  -- `h : decide (...) && decide (...) = true`
  rw [Bool.and_eq_true] at h
  obtain ⟨h₁, _⟩ := h
  exact decide_eq_true_eq.mp h₁

/-- A verifying proof's witness state has the claimed cell value
    at the claimed tag.  Direct from the verifier's second
    check. -/
theorem verifyCellProof_witness_has_cell_value
    (commit : StateCommit) (proof : CellProof)
    (h : verifyCellProof commit proof = true) :
    getCellValue proof.witnessState proof.cellTag = proof.cellValue := by
  unfold verifyCellProof at h
  rw [Bool.and_eq_true] at h
  obtain ⟨_, h₂⟩ := h
  exact decide_eq_true_eq.mp h₂

/-- #222 — Soundness: under `CollisionFree hashBytes`, a verifying
    proof witnesses an existing state whose cell at the claimed
    tag has the claimed value.

    The witness state is the proof's `witnessState` field;
    `CollisionFree` plus `commitExtendedState`'s injectivity
    (theorem #220) makes the witness state unique up to
    extensional equality. -/
theorem verifyCellProof_sound_under_collision_free
    (commit : StateCommit) (proof : CellProof)
    (_h_cf : Bridge.CollisionFree LegalKernel.Runtime.hashBytes)
    (h_verify : verifyCellProof commit proof = true) :
    ∃ es, commitExtendedState es = commit ∧
          getCellValue es proof.cellTag = proof.cellValue :=
  ⟨proof.witnessState,
   verifyCellProof_witness_recommits commit proof h_verify,
   verifyCellProof_witness_has_cell_value commit proof h_verify⟩

/-! ## #223 — Update commitment agrees with setCell

The recompute-commitment-after-cell-write operation must agree
with `commitExtendedState` on the post-state.  We establish this
via a definitional reduction: `updateCommitment` is just
`commitExtendedState ∘ setCell`. -/

/-- Compute the new commitment after writing one cell.  Defined
    directly via `setCell` + `commitExtendedState`; the
    agreement theorem is `rfl`. -/
def updateCommitment (proof : CellProof) (newValue : ByteArray) :
    StateCommit :=
  commitExtendedState (setCell proof.witnessState proof.cellTag newValue)

/-- #223 — `updateCommitment` agrees with `commitExtendedState`
    on the post-cell-write state.  By construction. -/
theorem updateCommitment_agrees_with_setCell
    (es : ExtendedState) (tag : CellTag) (newValue : ByteArray) :
    updateCommitment (buildCellProof es tag) newValue =
    commitExtendedState (setCell es tag newValue) := rfl

/-! ## Non-membership cell proofs (#260, H.3.4) -/

/-- A canonical-absent cell proof verifies against any state's
    commit at a tag where the state has no cell.  The witness is
    the state itself; the proof's value matches the canonical
    absent marker by `isCellAbsent`. -/
theorem verifyCellProof_complete_for_absent_cell
    (es : ExtendedState) (tag : CellTag)
    (h_absent : isCellAbsent es tag) :
    verifyCellProof (commitExtendedState es)
      { cellTag := tag,
        cellValue := canonicalAbsentValue tag,
        witnessState := es } = true := by
  unfold verifyCellProof
  -- (1) commitExtendedState witness = commit: rfl
  -- (2) getCellValue witness tag = canonicalAbsentValue tag: from h_absent
  unfold isCellAbsent at h_absent
  simp [h_absent]

/-! ## Smoke checks -/

/-- Spot-check: an empty state's commit verifies the canonical
    proof for any tag. -/
example (tag : CellTag) :
    verifyCellProof (commitExtendedState ExtendedState.empty)
      (buildCellProof ExtendedState.empty tag) = true :=
  verifyCellProof_complete _ _

end FaultProof
end LegalKernel

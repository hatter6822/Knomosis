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

Under collision-freeness of `hashBytes` on the pre-images below, condition 1 plus
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
  * `verifyCellProof_sound` — a verifying proof's witness state
    has the claimed cell value at the claimed tag.  Unconditional:
    the verifier's own two checks establish it.
  * `verifyCellProof_witness_unique_under_collision_free` — under
    collision-freeness on the commitment chain's hash pre-images,
    that witness is the ONLY state behind the published root, so a
    responder cannot substitute a different cell value.
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
    * `balance`: a CBE `0` on the 17-byte amount head — the same
      head a present balance uses, so absent and present cells are
      read by one decoder path.
    * `nonce`, `bridgeNextWdId`: a CBE `0` on the 9-byte uint head
      (counters, not wei).
    * `registry`, `localPolicy`, `bridgeConsumed`, `bridgePending`:
      empty bytes.
    * The bridge scalars, the budget-policy scalars and the flags:
      a CBE `0` on the head their present form uses (amount head for
      the value-carrying ones, uint head for counters and flags), so
      absent and present are read by one decoder path.
    * `epochBudget`: two CBE `0`s, matching the present form's
      `lastSeenEpoch ++ budgetBalance` pair. -/
def canonicalAbsentValue : CellTag → ByteArray
  | .balance _ _                => ByteArray.mk (Encoding.encodeAmount 0).toArray
  | .nonce _                    => ByteArray.mk (Encodable.encode (T := Nat) 0).toArray
  | .registry _                 => ByteArray.empty
  | .localPolicy _              => ByteArray.empty
  | .bridgeConsumed _           => ByteArray.empty
  | .bridgePending _            => ByteArray.empty
  | .bridgeNextWdId             => ByteArray.mk (Encodable.encode (T := Nat) 0).toArray
  | .bridgeAmmReserveEth        => ByteArray.mk (Encoding.encodeAmount 0).toArray
  | .bridgeAmmReserveBold       => ByteArray.mk (Encoding.encodeAmount 0).toArray
  | .bridgeBoldCircuitClosed    => ByteArray.mk (Encodable.encode (T := Nat) 0).toArray
  | .bridgeBoldTvlCap           => ByteArray.mk (Encoding.encodeAmount 0).toArray
  | .bridgeBoldTotalLockedValue => ByteArray.mk (Encoding.encodeAmount 0).toArray
  | .bridgeAmmDisabled          => ByteArray.mk (Encodable.encode (T := Nat) 0).toArray
  | .epochBudget _              =>
    ByteArray.mk
      ((Encodable.encode (T := Nat) 0) ++ (Encodable.encode (T := Nat) 0)).toArray
  | .budgetPolicyFreeTier       => ByteArray.mk (Encodable.encode (T := Nat) 0).toArray
  | .budgetPolicyActionCost     => ByteArray.mk (Encodable.encode (T := Nat) 0).toArray
  | .budgetPolicyCurrentEpoch   => ByteArray.mk (Encodable.encode (T := Nat) 0).toArray

/-! ## `getCellValue` (§12.1.2 helper) -/

/-- Read a single cell's CBE-encoded value from an
    `ExtendedState`.  Total: absent cells return
    `canonicalAbsentValue tag`.

    The byte form matches the encoder's per-cell value layout: the
    CBE amount head for balances, the CBE uint head for nonces and
    the next-withdrawal id, a CBE byte string for keys / policies /
    bridge records. -/
def getCellValue (es : ExtendedState) (tag : CellTag) : ByteArray :=
  match tag with
  | .balance r a =>
    -- A balance is value-carrying, so it rides the 17-byte amount
    -- head rather than the 9-byte identifier head.  The nonce and
    -- next-withdrawal-id cells below keep the narrow head: they are
    -- counters, not wei.
    ByteArray.mk
      (Encoding.encodeAmount (LegalKernel.getBalance es.base r a)).toArray
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
  -- GP.11.8 / GP.11.10 bridge scalars.  `commitExtendedState` binds
  -- all of `BridgeState`, but until these tags existed there was no
  -- cell to *prove* them against, so a dispute that turned on the AMM
  -- mirror or the kill switch had nothing to open.  Reserves and the
  -- TVL figures are value-carrying, so they ride the 17-byte amount
  -- head; the two flags ride the uint head as 0/1.
  | .bridgeAmmReserveEth =>
    ByteArray.mk (Encoding.encodeAmount es.bridge.ammReserveEth).toArray
  | .bridgeAmmReserveBold =>
    ByteArray.mk (Encoding.encodeAmount es.bridge.ammReserveBold).toArray
  | .bridgeBoldCircuitClosed =>
    ByteArray.mk
      (Encodable.encode (T := Nat) (if es.bridge.boldCircuitClosed then 1 else 0)).toArray
  | .bridgeBoldTvlCap =>
    ByteArray.mk (Encoding.encodeAmount es.bridge.boldTvlCap).toArray
  | .bridgeBoldTotalLockedValue =>
    ByteArray.mk (Encoding.encodeAmount es.bridge.boldTotalLockedValue).toArray
  | .bridgeAmmDisabled =>
    ByteArray.mk
      (Encodable.encode (T := Nat) (if es.bridge.ammDisabled then 1 else 0)).toArray
  -- Per-actor epoch budget.  Both components in one cell, so a proof
  -- cannot open the balance without also fixing the epoch it belongs
  -- to — reading them apart would let a stale-epoch balance be
  -- presented as current.
  | .epochBudget a =>
    let b := es.epochBudgets[a]?.getD Authority.ActorBudget.empty
    ByteArray.mk
      ((Encodable.encode (T := Nat) b.lastSeenEpoch) ++
       (Encodable.encode (T := Nat) b.budgetBalance)).toArray
  -- Budget-policy scalars, one cell each: a dispute normally turns on
  -- exactly one of them, and a single packed cell would force the
  -- responder to open all three.
  | .budgetPolicyFreeTier =>
    match es.budgetPolicy with
    | .bounded freeTier _ _ =>
      ByteArray.mk (Encodable.encode (T := Nat) freeTier).toArray
  | .budgetPolicyActionCost =>
    match es.budgetPolicy with
    | .bounded _ actionCost _ =>
      ByteArray.mk (Encodable.encode (T := Nat) actionCost).toArray
  | .budgetPolicyCurrentEpoch =>
    match es.budgetPolicy with
    | .bounded _ _ currentEpoch =>
      ByteArray.mk (Encodable.encode (T := Nat) currentEpoch).toArray

/-- Determinism of `getCellValue`: equal states + equal tags
    produce equal cell values.  Mechanical via `rfl`. -/
theorem getCellValue_deterministic
    (es₁ es₂ : ExtendedState) (tag₁ tag₂ : CellTag)
    (h_es : es₁ = es₂) (h_tag : tag₁ = tag₂) :
    getCellValue es₁ tag₁ = getCellValue es₂ tag₂ := by rw [h_es, h_tag]

/-! ## Cell-space coverage

`commitExtendedState` binds all seven `ExtendedState` fields, but
the cell space only ever covered part of them.  Concretely: the
GP.11.8 AMM mirror, the GP.11.10 kill switch, the per-actor epoch
budgets and the budget policy were all inside the published state
root and had **no cell tag**, so a fault proof could not open them.
A dispute that turned on "the sequencer forged `ammDisabled`" or
"the sequencer inflated an actor's budget" had nothing to prove
against — the step VM could not be shown a value it could check.

The lemmas below are the coverage obligation, one per field the
extension added: each says the field is *readable through a cell*,
so a cell proof can bind it.  They are `rfl`-class by construction;
the point is that they could not be stated at all before, and that
a future field added to `ExtendedState` without a matching tag
leaves an obvious hole here. -/

/-- The AMM ETH reserve is readable through its cell. -/
theorem getCellValue_ammReserveEth (es : ExtendedState) :
    getCellValue es .bridgeAmmReserveEth =
      ByteArray.mk (Encoding.encodeAmount es.bridge.ammReserveEth).toArray := rfl

/-- The AMM BOLD reserve is readable through its cell. -/
theorem getCellValue_ammReserveBold (es : ExtendedState) :
    getCellValue es .bridgeAmmReserveBold =
      ByteArray.mk (Encoding.encodeAmount es.bridge.ammReserveBold).toArray := rfl

/-- The BOLD circuit-breaker flag is readable through its cell. -/
theorem getCellValue_boldCircuitClosed (es : ExtendedState) :
    getCellValue es .bridgeBoldCircuitClosed =
      ByteArray.mk
        (Encodable.encode (T := Nat)
          (if es.bridge.boldCircuitClosed then 1 else 0)).toArray := rfl

/-- The BOLD TVL cap is readable through its cell. -/
theorem getCellValue_boldTvlCap (es : ExtendedState) :
    getCellValue es .bridgeBoldTvlCap =
      ByteArray.mk (Encoding.encodeAmount es.bridge.boldTvlCap).toArray := rfl

/-- The BOLD total-locked-value figure is readable through its
    cell. -/
theorem getCellValue_boldTotalLockedValue (es : ExtendedState) :
    getCellValue es .bridgeBoldTotalLockedValue =
      ByteArray.mk (Encoding.encodeAmount es.bridge.boldTotalLockedValue).toArray :=
  rfl

/-- The GP.11.10 AMM kill switch is readable through its cell.

    This is the one the GP.11.10 workstream most needs: `ammDisabled`
    was committed to the state root precisely so the fault-proof game
    could adjudicate disputes about it, and until this tag existed
    that was not possible. -/
theorem getCellValue_ammDisabled (es : ExtendedState) :
    getCellValue es .bridgeAmmDisabled =
      ByteArray.mk
        (Encodable.encode (T := Nat)
          (if es.bridge.ammDisabled then 1 else 0)).toArray := rfl

/-- The kill switch's two states produce different cell values, so
    the cell genuinely distinguishes them.  A "coverage" lemma that
    only exhibited a formula would not rule out a constant. -/
theorem getCellValue_ammDisabled_distinguishes
    (es : ExtendedState) (h : es.bridge.ammDisabled = true) :
    getCellValue es .bridgeAmmDisabled ≠
      getCellValue { es with bridge := { es.bridge with ammDisabled := false } }
        .bridgeAmmDisabled := by
  simp [getCellValue, h]
  decide

/-- An actor's epoch budget is readable through its cell, with the
    epoch and the balance in one value. -/
theorem getCellValue_epochBudget (es : ExtendedState) (a : ActorId) :
    getCellValue es (.epochBudget a) =
      (let b := es.epochBudgets[a]?.getD Authority.ActorBudget.empty
       ByteArray.mk
         ((Encodable.encode (T := Nat) b.lastSeenEpoch) ++
          (Encodable.encode (T := Nat) b.budgetBalance)).toArray) := rfl

/-- The budget policy's three scalars are readable through their
    cells. -/
theorem getCellValue_budgetPolicy_scalars
    (es : ExtendedState) (freeTier actionCost currentEpoch : Nat)
    (h : es.budgetPolicy = .bounded freeTier actionCost currentEpoch) :
    getCellValue es .budgetPolicyFreeTier =
        ByteArray.mk (Encodable.encode (T := Nat) freeTier).toArray ∧
    getCellValue es .budgetPolicyActionCost =
        ByteArray.mk (Encodable.encode (T := Nat) actionCost).toArray ∧
    getCellValue es .budgetPolicyCurrentEpoch =
        ByteArray.mk (Encodable.encode (T := Nat) currentEpoch).toArray := by
  refine ⟨?_, ?_, ?_⟩ <;> simp [getCellValue, h]

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
    -- Decode the value off the amount head — the symmetric inverse of
    -- `getCellValue`'s balance arm.  Reading it on the narrow uint
    -- head would fail closed on the tag rather than silently truncate,
    -- but it would still leave every balance write a no-op.
    match Encoding.decodeAmount value.data.toList with
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
  -- The bridge scalars decode off the head their `getCellValue` arm
  -- writes: the amount head for the value-carrying ones, the uint
  -- head for the flags.  A decode failure is a no-op, matching every
  -- arm above — the cell-write primitive never fails, so a malformed
  -- value cannot corrupt the state.
  | .bridgeAmmReserveEth =>
    match Encoding.decodeAmount value.data.toList with
    | .ok (v, _) => { es with bridge := { es.bridge with ammReserveEth := v } }
    | .error _   => es
  | .bridgeAmmReserveBold =>
    match Encoding.decodeAmount value.data.toList with
    | .ok (v, _) => { es with bridge := { es.bridge with ammReserveBold := v } }
    | .error _   => es
  | .bridgeBoldCircuitClosed =>
    match Encodable.decode (T := Nat) value.data.toList with
    | .ok (n, _) =>
      { es with bridge := { es.bridge with boldCircuitClosed := n != 0 } }
    | .error _   => es
  | .bridgeBoldTvlCap =>
    match Encoding.decodeAmount value.data.toList with
    | .ok (v, _) => { es with bridge := { es.bridge with boldTvlCap := v } }
    | .error _   => es
  | .bridgeBoldTotalLockedValue =>
    match Encoding.decodeAmount value.data.toList with
    | .ok (v, _) =>
      { es with bridge := { es.bridge with boldTotalLockedValue := v } }
    | .error _   => es
  | .bridgeAmmDisabled =>
    match Encodable.decode (T := Nat) value.data.toList with
    | .ok (n, _) =>
      { es with bridge := { es.bridge with ammDisabled := n != 0 } }
    | .error _   => es
  | .epochBudget a =>
    -- Both components in one cell, decoded in sequence: the epoch
    -- must travel with the balance it belongs to.
    match Encodable.decode (T := Nat) value.data.toList with
    | .ok (epoch, rest) =>
      match Encodable.decode (T := Nat) rest with
      | .ok (bal, _) =>
        { es with
            epochBudgets :=
              es.epochBudgets.insert a
                { lastSeenEpoch := epoch, budgetBalance := bal } }
      | .error _ => es
    | .error _ => es
  -- The policy is a single `bounded` constructor, so each scalar
  -- write rebuilds it with the other two preserved.
  | .budgetPolicyFreeTier =>
    match Encodable.decode (T := Nat) value.data.toList, es.budgetPolicy with
    | .ok (v, _), .bounded _ actionCost currentEpoch =>
      { es with budgetPolicy := .bounded v actionCost currentEpoch }
    | .error _, _ => es
  | .budgetPolicyActionCost =>
    match Encodable.decode (T := Nat) value.data.toList, es.budgetPolicy with
    | .ok (v, _), .bounded freeTier _ currentEpoch =>
      { es with budgetPolicy := .bounded freeTier v currentEpoch }
    | .error _, _ => es
  | .budgetPolicyCurrentEpoch =>
    match Encodable.decode (T := Nat) value.data.toList, es.budgetPolicy with
    | .ok (v, _), .bounded freeTier actionCost _ =>
      { es with budgetPolicy := .bounded freeTier actionCost v }
    | .error _, _ => es

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
    no collision-freeness hypothesis needed for completeness. -/
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

/-! ## #222 — Verifier soundness under collision-freeness on the level's pre-images -/

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

/-- #222 — Existence: a verifying proof witnesses a state whose
    cell at the claimed tag has the claimed value.

    The witness state is the proof's `witnessState` field, and the
    verifier's own two checks establish both conjuncts, so this
    direction needs no collision-resistance hypothesis at all.  The
    hypothesis that makes the witness *unique* is stated separately
    by `verifyCellProof_witness_unique_under_collision_free` below —
    that is the property a fault-proof consumer actually relies on,
    and carrying it as an unused argument here stated nothing. -/
theorem verifyCellProof_sound
    (commit : StateCommit) (proof : CellProof)
    (h_verify : verifyCellProof commit proof = true) :
    ∃ es, commitExtendedState es = commit ∧
          getCellValue es proof.cellTag = proof.cellValue :=
  ⟨proof.witnessState,
   verifyCellProof_witness_recommits commit proof h_verify,
   verifyCellProof_witness_has_cell_value commit proof h_verify⟩

/-- #222 — Uniqueness: any state that commits to the same root as a
    verifying proof is extensionally equal to that proof's witness.

    This is the operational content of cell-proof soundness: an
    adversarial responder cannot exhibit a *different* state behind
    the same published root and thereby claim a different cell
    value.  It rests on `commitExtendedState`'s injectivity
    (theorem #220 / EI.8), which is where the collision-resistance
    hypothesis genuinely does work — scoped, as everywhere else, to
    the pre-images the commitment chain actually hashes. -/
theorem verifyCellProof_witness_unique_under_collision_free
    (commit : StateCommit) (proof : CellProof) (es : ExtendedState)
    (h_cf : Bridge.CollisionFreeOn
      (extendedStateCommitPreimages es proof.witnessState)
      LegalKernel.Runtime.hashBytes)
    (h_b₁ : ExtendedState.CanonicalBounds es)
    (h_b₂ : ExtendedState.CanonicalBounds proof.witnessState)
    (h_verify : verifyCellProof commit proof = true)
    (h_commit : commitExtendedState es = commit) :
    ExtendedState.extEq es proof.witnessState :=
  commitExtendedState_subcommits_extensional_eq_under_collision_free
    es proof.witnessState h_cf h_b₁ h_b₂
    (h_commit.trans
      (verifyCellProof_witness_recommits commit proof h_verify).symm)

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

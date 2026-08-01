-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.CellValue — reading and writing one cell of
an `ExtendedState`.

## Why this is its own module

`getCellValue` and `canonicalAbsentValue` lived in `Verify.lean`,
which imports `Commit.lean` for `commitExtendedState`.  That
ordering is fine for a root that hashes seven sub-state ENCODINGS,
and impossible for a root over CELLS: the cell root is built from
`getCellValue`, so defining `commitExtendedState` that way with the
reader above it is a cycle.

Splitting the reader/writer out below `Commit.lean` removes the
obstacle without moving a single value — `verifyCellProof` and
everything that needs the commit stay in `Verify.lean`, which now
imports this.  Nothing here depends on how the state root is
computed, which is exactly the property that makes the split
possible and the swap tractable.

`docs/planning/state_root_merkleisation_plan.md` §3.
-/

import LegalKernel.Authority.LocalPolicy
import LegalKernel.Bridge.Eip712
import LegalKernel.Encoding.State
import LegalKernel.FaultProof.Cell

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
  | .budgetPolicy               =>
    ByteArray.mk (Encodable.encode (T := Authority.BudgetPolicy)
      (.bounded 0 0 0)).toArray

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
    -- Routed through the CBE byte-string encoder, NOT emitted raw.
    -- `PublicKey` is a bare `ByteArray` and `registerIdentity`
    -- accepts any value, so a registration with the EMPTY key would
    -- otherwise read exactly like an absent one — and registration
    -- is an admissibility gate, so those are different states.  The
    -- CBE head is 9 bytes even for a zero-length payload, so
    -- present-empty and absent are now distinguishable.
    match es.registry[a]? with
    | some pk => ByteArray.mk (Encodable.encode (T := ByteArray) pk).toArray
    | none    => ByteArray.empty
  | .localPolicy a =>
    -- Keyed off the MAP, not `lookup`.  `lookup` defaults an absent
    -- actor to `LocalPolicy.empty`, so the old `if p.clauses.isEmpty`
    -- form collapsed "declared a policy with no clauses" onto
    -- "declared nothing" — two different map states with the same
    -- cell value, which a cell root must not do.  The encoding of a
    -- clause-less policy still carries its CBE array head, so it is
    -- non-empty and distinguishable from the absent marker.
    match es.localPolicies[a]? with
    | some p => ByteArray.mk
                  (Encodable.encode (T := Authority.LocalPolicy) p).toArray
    | none   => ByteArray.empty
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
  -- The budget policy, whole.  One cell, because `BudgetPolicy` is one
  -- value: a cell is the unit a write updates, and a cell holding a
  -- component would make every write a read-modify-write of the rest.
  | .budgetPolicy =>
    ByteArray.mk (Encodable.encode (T := Authority.BudgetPolicy) es.budgetPolicy).toArray

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

/-- The budget-policy cell reads the whole policy. -/
theorem getCellValue_budgetPolicy_eq
    (es : ExtendedState) :
    getCellValue es .budgetPolicy =
      ByteArray.mk (Encodable.encode (T := Authority.BudgetPolicy)
        es.budgetPolicy).toArray := rfl

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
  | .nonce a =>
    -- Inverse of `getCellValue`'s nonce arm, which reads
    -- `Authority.expectsNonce` off `es.nonces.next`.
    --
    -- This used to be a no-op, on the reasoning that nonces are
    -- bumped by `advanceNonce` and not arbitrarily set.  That is the
    -- right rule for the KERNEL, and the wrong one here: this
    -- function is the L1 step VM's per-cell write primitive, and
    -- every one of the 25 actions writes `.nonce signer`.  A no-op on
    -- the single most common write meant the primitive could not
    -- express a step at all — a state reached by replaying a step's
    -- proven writes would carry the PRE-state's nonce, and so a
    -- different root from the one the sequencer published.
    --
    -- Arbitrariness is not a hazard the primitive has to defend
    -- against: it writes the value the opening proved, and what
    -- constrains that value to `old + 1` is the per-variant handler
    -- that computes it, verified against the pre-state cell.
    match Encodable.decode (T := Nat) value.data.toList with
    | .ok (n, _) => { es with nonces := { es.nonces with next := es.nonces.next.insert a n } }
    | .error _   => es
  | .registry a =>
    -- Inverse of `getCellValue`'s registry arm: the value is a CBE
    -- byte string wrapping the key, not the raw key.  Decoding it is
    -- what lets a registration with an empty public key round-trip
    -- instead of being read back as a no-op.
    if value.size = 0 then es  -- absent marker ⇒ no change
    else
      match Encodable.decode (T := ByteArray) value.data.toList with
      | .ok (pk, _) => { es with registry := es.registry.insert a pk }
      | .error _    => es
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
  | .bridgePending wd =>
    -- Inverse of `getCellValue`'s arm, which encodes
    -- `es.bridge.pending[wd]?` through `PendingWithdrawal.encode`.
    --
    -- This was a no-op on the reasoning that pending withdrawals are
    -- appended via `appendWithdrawal`, which assigns the id, so an
    -- arbitrary-key write is a runtime concern.  That confuses two
    -- questions: `appendWithdrawal` is how the KERNEL allocates an
    -- id, and this is how a verifier REPLAYS a write whose key the
    -- opening already fixed.  `withdraw` writes
    -- `bridgePending <nextWdId>`, so leaving the arm inert made that
    -- action's post-state unreachable from its own proven writes.
    --
    -- Empty ⇒ no change, matching `bridgeConsumed`: removal happens
    -- at finalisation, not inside a step.
    if value.size = 0 then es
    else
      match Bridge.PendingWithdrawal.decode value.data.toList with
      | .ok (pw, _) =>
        { es with bridge := { es.bridge with pending := es.bridge.pending.insert wd pw } }
      | .error _ => es
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
  | .budgetPolicy =>
    -- A genuine point write.  The three-cell form had to read the
    -- other two components back out of `es` and rebuild, so a
    -- "single-cell write" silently depended on two cells it did not
    -- name.
    match Encodable.decode (T := Authority.BudgetPolicy) value.data.toList with
    | .ok (p, _) => { es with budgetPolicy := p }
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
  -- No opening.  Not an oversight and not a default: building one
  -- needs `stateCellEntries`, which is defined ABOVE this module —
  -- the cell root is built out of `getCellValue`, so the reader
  -- cannot see the enumeration it feeds.
  --
  -- `buildCellProofWithOpening` (`StateCellsInjective.lean`) is the
  -- builder for anything that reaches an L1 verifier, and every
  -- production bundle uses it.  This one remains for the Lean-side
  -- `verifyCellProof` path, which recomputes the commit from
  -- `witnessState` and never reads the opening.
  proofData    := ByteArray.empty

end FaultProof
end LegalKernel

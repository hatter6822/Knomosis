-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Cell — `CellTag`, `CellProof`,
`CellProofBundle` (Workstream H §12 / WUs H.3.1 + H.3.2).

The L1 step VM (`KnomosisStepVM`) doesn't have access to the full
`ExtendedState`; it only holds the 32-byte top-level state
commitment.  When the bisection game narrows to a single disputed
step, the responding party supplies cell proofs (`CellProof`s)
for every cell the step reads or writes; the L1 contract verifies
the proofs against the committed root and uses the cell values as
inputs to the step function.

This module defines the per-cell proof shapes consumed by both
the Lean-side `kernelStepApply` (WU H.1.2) and the Solidity-side
`KnomosisStepVM.executeStep`.

**Granularity rationale (WU H.3 design notes).**  Cells are tagged
by their logical sub-state + key:

  * `balance r a`   — the actor `a`'s balance at resource `r`
                      (inner BalanceMap leaf).
  * `nonce a`       — actor `a`'s next-expected nonce.
  * `registry a`    — actor `a`'s registered public key (CBE bytes).
  * `localPolicy a` — actor `a`'s declared local policy.
  * `bridgeConsumed d` — whether L1 deposit `d` has been credited.
  * `bridgePending wd` — pending L2→L1 withdrawal `wd`'s payload.
  * `bridgeNextWdId`  — the next-withdrawal-id counter.

**Proof design (witness-state-bearing).**  `CellProof` carries a
*witness* `ExtendedState` plus the cell tag and value.  Verification
re-commits the witness state and checks that (a) the recommitted
hash equals the public commit and (b) the witness state has the
claimed cell value at the claimed tag.  Under collision-freeness of
`hashBytes` on the commitment chain's pre-images, that witness state
is the unique one behind the commit, up to extensional equality.

This design is **mathematically equivalent to a Sparse Merkle
Tree** for soundness purposes — the SMT version optimises the L1
gas cost (the witness state expands to its full encoded byte
sequence; the SMT version only sends `O(log N)` siblings).  Both
forms now ship side-by-side: the witness-state form (this
module) is the simpler reference; the SMT form
(`LegalKernel/FaultProof/Smt.lean`) is gas-efficient and used by
L1 deployments.  Deployments select the form via the
`KnomosisStateRootSubmission` parameter set; both have full Lean
soundness proofs under collision-freeness of `hashBytes` on the pre-images below.

This module is **not** part of the trusted computing base.  Bugs
here would only affect the deployment-side fault-proof tooling;
the kernel's invariant proofs are unaffected.  All theorems hold
without any new axioms.
-/

import LegalKernel.Authority.Crypto
import LegalKernel.Authority.Nonce
import LegalKernel.Bridge.State
import LegalKernel.Encoding.Encodable
import LegalKernel.FaultProof.Smt

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge

/-! ## State commitment type

Declared here rather than beside `commitExtendedState` because the
cell layer has to name it — `commitExtendedStateSmt` is a state
commitment built out of cells, so the type must sit below both the
cell reader and the commitment function that consumes it.  The
`abbrev` is `ByteArray` either way, so no consumer moves. -/

/-- The 32-byte top-level state commitment.  The sequencer
    publishes this value to L1 as the "state root"; the L1
    fault-proof game contract holds it for dispute resolution. -/
abbrev StateCommit : Type := ByteArray

/-! ## `CellTag` (§12.1.4) -/

/-- The tag identifying which sub-state + cell key a `CellProof`
    references.  Each variant maps to exactly one of the five
    sub-state SMTs (the kernel's inner `BalanceMap` tree, the
    nonce ledger, the key registry, the local-policies table,
    the bridge consumed-deposit map) or to the standalone
    `bridgeNextWdId` counter (which has no SMT — it's a single
    `Nat`).

    The ordering here is the canonical CBE-encoder order; the
    Solidity-side `CellTag` enum mirrors this byte-for-byte.

    `DecidableEq` is required for cell-bundle bookkeeping (e.g.
    detecting duplicate cells in a bundle); `Repr` is for test-
    suite failure messages. -/
inductive CellTag
  /-- A `(resource, actor)` balance cell.  Frozen tag 0. -/
  | balance        (resource : ResourceId) (actor : ActorId)
  /-- An actor's next-expected nonce.  Frozen tag 1. -/
  | nonce          (actor : ActorId)
  /-- An actor's registry entry (public key).  Frozen tag 2. -/
  | registry       (actor : ActorId)
  /-- An actor's declared local policy.  Frozen tag 3. -/
  | localPolicy    (actor : ActorId)
  /-- A bridge `consumed` map entry indexed by `DepositId`.
      Frozen tag 4. -/
  | bridgeConsumed (depositId : DepositId)
  /-- A bridge `pending` map entry indexed by `WithdrawalId`.
      Frozen tag 5. -/
  | bridgePending  (withdrawalId : WithdrawalId)
  /-- The bridge `nextWdId` counter (no key needed; singleton).
      Frozen tag 6. -/
  | bridgeNextWdId
  /-- GP.11.8 L2 mirror of the L1 AMM ETH reserve.  Tag 7. -/
  | bridgeAmmReserveEth
  /-- GP.11.8 L2 mirror of the L1 AMM BOLD reserve.  Tag 8. -/
  | bridgeAmmReserveBold
  /-- GP.11.8 BOLD circuit-breaker flag.  Tag 9. -/
  | bridgeBoldCircuitClosed
  /-- GP.11.8 per-BOLD TVL cap.  Tag 10. -/
  | bridgeBoldTvlCap
  /-- GP.11.8 per-BOLD total locked value.  Tag 11. -/
  | bridgeBoldTotalLockedValue
  /-- GP.11.10 AMM kill-switch flag.  Tag 12. -/
  | bridgeAmmDisabled
  /-- An actor's epoch-budget cell (`lastSeenEpoch`,
      `budgetBalance`).  Tag 13. -/
  | epochBudget (actor : ActorId)
  /-- The deployment's budget policy, whole.  Tag 14.

      One cell, not three.  `BudgetPolicy` is a single value —
      `.bounded freeTier actionCost currentEpoch` — and splitting it
      across three tags made a cell write a read-modify-write (the
      arm had to reconstruct the other two components out of the
      state), cost three SMT leaves and three sibling paths where
      every reader wants all three at once, and left an inconsistent
      triple representable in the proof obligations even though it
      was unreachable in practice. -/
  | budgetPolicy
  deriving Repr, DecidableEq

/-- Project a `CellTag` to its discriminator index, for canonical
    encoding and equality dispatch.  Aligns with the Solidity-side
    enum.  The frozen tag indices are:
    0 = balance, 1 = nonce, 2 = registry, 3 = localPolicy,
    4 = bridgeConsumed, 5 = bridgePending, 6 = bridgeNextWdId,
    7 = bridgeAmmReserveEth, 8 = bridgeAmmReserveBold,
    9 = bridgeBoldCircuitClosed, 10 = bridgeBoldTvlCap,
    11 = bridgeBoldTotalLockedValue, 12 = bridgeAmmDisabled,
    13 = epochBudget, 14 = budgetPolicy.

    **0–6 are frozen** (they are mirrored in the Solidity `CellKind`
    enum and pinned by the cross-stack corpus); 7–14 append to them.
    Indices are never reused or reordered. -/
def CellTag.kindIndex : CellTag → Nat
  | .balance _ _                => 0
  | .nonce _                    => 1
  | .registry _                 => 2
  | .localPolicy _              => 3
  | .bridgeConsumed _           => 4
  | .bridgePending _            => 5
  | .bridgeNextWdId             => 6
  | .bridgeAmmReserveEth        => 7
  | .bridgeAmmReserveBold       => 8
  | .bridgeBoldCircuitClosed    => 9
  | .bridgeBoldTvlCap           => 10
  | .bridgeBoldTotalLockedValue => 11
  | .bridgeAmmDisabled          => 12
  | .epochBudget _              => 13
  | .budgetPolicy               => 14

/-- The two key components of a `CellTag`.  Singleton cells (the
    bridge scalars, the budget policy) carry `(0, 0)`; the
    kind index is what distinguishes them. -/
def CellTag.keyParts : CellTag → Nat × Nat
  | .balance r a                => (r.toNat, a.toNat)
  | .nonce a                    => (a.toNat, 0)
  | .registry a                 => (a.toNat, 0)
  | .localPolicy a              => (a.toNat, 0)
  -- `DepositId` / `WithdrawalId` are `Nat` already, so no `.toNat`.
  | .bridgeConsumed d           => (d, 0)
  | .bridgePending w            => (w, 0)
  | .bridgeNextWdId             => (0, 0)
  | .bridgeAmmReserveEth        => (0, 0)
  | .bridgeAmmReserveBold       => (0, 0)
  | .bridgeBoldCircuitClosed    => (0, 0)
  | .bridgeBoldTvlCap           => (0, 0)
  | .bridgeBoldTotalLockedValue => (0, 0)
  | .bridgeAmmDisabled          => (0, 0)
  | .epochBudget a              => (a.toNat, 0)
  | .budgetPolicy               => (0, 0)

/-- `(kindIndex, keyA, keyB)` — the canonical flat projection of a
    cell tag.

    One source of truth for a destructuring that had been written
    out three times (the SMT key derivation, the cell-proof JSON
    formatter, and the cross-stack fixture writer), each an
    exhaustive match that had to be extended in lockstep.  A
    divergence between them is a cross-stack key mismatch — the
    failure mode where a proof for one cell verifies against
    another. -/
def CellTag.flatKey (t : CellTag) : Nat × Nat × Nat :=
  let (a, b) := t.keyParts
  (t.kindIndex, a, b)


/-! ## `CellProof` (§12.1.4)

The proof carries a *witness* `ExtendedState` from which the
verifier can recompute the top-level commit and the cell at the
claimed tag.  Under collision-freeness of `hashBytes` on the pre-images below, the witness state
is unique up to extensional equality, so a verifying proof
authoritatively binds the cell value to the public commit.

Production deployments may upgrade `CellProof` to a Merkle-path
form (per Workstream-D's SMT pattern) for L1 gas optimisation;
the soundness arguments lift transparently.  The first-pass
implementation prioritises mathematical clarity over gas. -/

/-- A proof witnessing that a single cell of the `ExtendedState`
    has a particular value at the committed root.

    `cellTag` identifies the cell.  `cellValue` is the cell's
    canonical CBE-encoded value.  `witnessState` is the underlying
    `ExtendedState` from which the verifier recommits and reads
    the cell.

    The verifier (`verifyCellProof`) checks:
      1. `commitExtendedState witnessState = committed root`
      2. `getCellValue witnessState cellTag = cellValue`

    Under collision-freeness of `hashBytes` on the pre-images below, condition 1 plus
    `commitExtendedState`'s injectivity (theorem #220) makes the
    `witnessState` unique up to extensional equality, so the
    verifier authoritatively binds `cellValue` to the public
    commit. -/
structure CellProof where
  /-- Which cell is being witnessed. -/
  cellTag       : CellTag
  /-- The cell's value at the committed root. -/
  cellValue     : ByteArray
  /-- The witness state from which the verifier can recompute
      the commitment and read the cell. -/
  witnessState  : ExtendedState
  deriving Repr

/-- A bundle of cell proofs covering every cell read/written by
    one step.  The bundle's contents are a function of the action
    variant (per WU H.1.4): each constructor declares which cells
    it touches, and the bundle includes a `CellProof` for each. -/
structure CellProofBundle where
  /-- The proofs in canonical order (per the action variant's
      `Action.requiredCells` declaration in WU H.1.4). -/
  proofs : List CellProof
  deriving Repr

/-! ## Helpers -/

/-- The empty cell-proof bundle. -/
def CellProofBundle.empty : CellProofBundle := { proofs := [] }

/-- Append a cell proof to a bundle. -/
def CellProofBundle.push (b : CellProofBundle) (p : CellProof) :
    CellProofBundle :=
  { proofs := b.proofs ++ [p] }

/-- The size of a cell-proof bundle. -/
def CellProofBundle.size (b : CellProofBundle) : Nat :=
  b.proofs.length

/-! ## Smoke checks -/

example : CellProofBundle.empty.size = 0 := rfl

/-! ## SMT cell-proof re-exports (Workstream SC.1)

The SMT cell-proof scheme ships in
`LegalKernel/FaultProof/Smt.lean` as the gas-efficient
alternative to the witness-state form defined above.  Both
forms ship side-by-side; deployments choose via the
`KnomosisStateRootSubmission` parameter set.

The re-exports below give a `Cell.*` namespace alias for the
SMT surface so consumers can stay within the `Cell` namespace
when using either form. -/

namespace Cell

/-- Re-export: SMT cell proof (`LegalKernel.FaultProof.SmtCellProof`). -/
abbrev SmtProof := SmtCellProof

/-- Re-export: SMT cell-proof verifier
    (`LegalKernel.FaultProof.verifySmtCellProof`). -/
abbrev smtVerify := @verifySmtCellProof

/-- Re-export: SMT cell-proof soundness theorem
    (`LegalKernel.FaultProof.smtCellProof_sound_under_collision_free`).
    Documents the operational binding property: under
    collision-freeness of `hashBytes` on the proofs' own hash
    pre-images, the verifier accepts at most one value per
    `(root, key)` pair. -/
theorem smtSound
    {K V : Type} [BitsKey K]
    [LegalKernel.Encoding.Encodable K] [LegalKernel.Encoding.Encodable V]
    (hVInj : Function.Injective
                (LegalKernel.Encoding.Encodable.encode :
                  V → LegalKernel.Encoding.Stream))
    (root : ByteArray) (key : K) (v₁ v₂ : V)
    (proof₁ proof₂ : SmtCellProof)
    (h_cf : Bridge.CollisionFreeOn
      (smtCellProofPreimages key v₁ v₂ proof₁ proof₂)
      LegalKernel.Runtime.hashBytes)
    (h_verify₁ : verifySmtCellProof root key v₁ proof₁ = true)
    (h_verify₂ : verifySmtCellProof root key v₂ proof₂ = true) :
    v₁ = v₂ :=
  smtCellProof_sound_under_collision_free hVInj root key v₁ v₂
    proof₁ proof₂ h_cf h_verify₁ h_verify₂

end Cell

end FaultProof
end LegalKernel

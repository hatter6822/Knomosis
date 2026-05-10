/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Cell — `CellTag`, `CellProof`,
`CellProofBundle` (Workstream H §12 / WUs H.3.1 + H.3.2).

The L1 step VM (`CanonStepVM`) doesn't have access to the full
`ExtendedState`; it only holds the 32-byte top-level state
commitment.  When the bisection game narrows to a single disputed
step, the responding party supplies cell proofs (`CellProof`s)
for every cell the step reads or writes; the L1 contract verifies
the proofs against the committed root and uses the cell values as
inputs to the step function.

This module defines the per-cell proof shapes consumed by both
the Lean-side `kernelStepApply` (WU H.1.2) and the Solidity-side
`CanonStepVM.executeStep`.

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
claimed cell value at the claimed tag.  Under `CollisionFree
hashBytes`, the witness state is unique up to extensional
equality.

This design is **mathematically equivalent to a Sparse Merkle
Tree** for soundness purposes — the SMT version optimises the L1
gas cost (the witness state expands to its full encoded byte
sequence; the SMT version only sends `O(log N)` siblings).  The
SMT optimisation is a future deployment-layer concern; the
correctness arguments hold under either representation.  Cross-
stack equivalence between the witness-state form and the
Solidity-side SMT form is documented as a follow-up integration
(per Genesis Plan §15.8 deviation block).

This module is **not** part of the trusted computing base.  Bugs
here would only affect the deployment-side fault-proof tooling;
the kernel's invariant proofs are unaffected.  All theorems hold
without any new axioms.
-/

import LegalKernel.Authority.Crypto
import LegalKernel.Authority.Nonce
import LegalKernel.Bridge.State
import LegalKernel.Encoding.Encodable

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge

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
  deriving Repr, DecidableEq

/-- Project a `CellTag` to its discriminator index, for canonical
    encoding and equality dispatch.  Aligns with the Solidity-side
    enum.  The frozen tag indices are:
    0 = balance, 1 = nonce, 2 = registry, 3 = localPolicy,
    4 = bridgeConsumed, 5 = bridgePending, 6 = bridgeNextWdId. -/
def CellTag.kindIndex : CellTag → Nat
  | .balance _ _      => 0
  | .nonce _          => 1
  | .registry _       => 2
  | .localPolicy _    => 3
  | .bridgeConsumed _ => 4
  | .bridgePending _  => 5
  | .bridgeNextWdId   => 6

/-! ## `CellProof` (§12.1.4)

The proof carries a *witness* `ExtendedState` from which the
verifier can recompute the top-level commit and the cell at the
claimed tag.  Under `CollisionFree hashBytes`, the witness state
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

    Under `CollisionFree hashBytes`, condition 1 plus
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

end FaultProof
end LegalKernel

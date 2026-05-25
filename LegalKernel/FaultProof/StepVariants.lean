/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.StepVariants — per-action `readOnlyCells` /
`writeCells` / `requiredCells` declarations (Workstream H §12 /
WU H.1.4 + WU H.3.2).

For each of the 19 `Action` constructors, this module declares:

  * `Action.readOnlyCells a` — cell tags whose values the step
    consults but does not mutate.  Required for admissibility
    checks; not required for state advance.
  * `Action.writeCells a` — cell tags whose values the step both
    reads (to verify the pre-state) and writes (with a new
    post-state value).
  * `Action.requiredCells a := readOnlyCells a ++ writeCells a` —
    the complete cell set for the action.

The cell-list specifications match `Appendix D` of
`docs/planning/fault_proof_migration_plan.md`.  Bulk actions
(`distributeOthers`, `proportionalDilute`) declare a *recipient-
list-dependent* `writeCells`; the corresponding sub-step
decomposition (per WU H.1.4) is captured by the `subSteps`
helper.

This module is **not** part of the trusted computing base.  Bugs
here would be caught by the cross-stack equivalence corpus (WU
H.10.1) since the Solidity step VM mirrors these declarations
line-for-line.
-/

import LegalKernel.Authority.Action
import LegalKernel.FaultProof.Cell

namespace LegalKernel
namespace Authority

open LegalKernel.FaultProof

/-! ## Per-action cell declarations (Appendix D)

These functions live in the `LegalKernel.Authority` namespace
(matching `Action`'s home) so the standard dot-notation
`a.readOnlyCells signer` projects without explicit namespace
qualification.  The Lean compiler looks up
`LegalKernel.Authority.Action.readOnlyCells` when given an
`Action` argument; placing the definitions here aligns the
namespace with the type. -/

/-- The cell tags an action reads but does not write.  Required
    for admissibility checks (e.g. signature verification consults
    `registry signer`, but the registry isn't changed by a
    transfer). -/
def Action.readOnlyCells : Action → ActorId → List CellTag
  -- For every action, the signature verification reads the
  -- signer's registry entry.  The `[registry signer]` cell is
  -- universal across all 19 constructors (it's how `Verify`
  -- locates the public key).
  | .transfer _ _ _ _,             signer => [.registry signer]
  | .mint _ _ _,                   signer => [.registry signer]
  | .burn _ _ _,                   signer => [.registry signer]
  | .freezeResource _,             signer => [.registry signer]
  | .replaceKey _ _,               signer => [.registry signer]
  | .reward _ _ _,                 signer => [.registry signer]
  | .distributeOthers _ _ _,       signer => [.registry signer]
  | .proportionalDilute _ _ _,     signer => [.registry signer]
  | .dispute _,                    signer => [.registry signer]
  | .disputeWithdraw _,            signer => [.registry signer]
  | .verdict _,                    signer => [.registry signer]
  | .rollback _,                   signer => [.registry signer]
  | .registerIdentity _ _,         signer => [.registry signer]
  -- Bridge: deposit additionally reads the consumed-deposit map
  -- to verify the deposit hasn't already been credited.
  | .deposit _ _ _ d,              signer =>
      [.registry signer, .bridgeConsumed d]
  | .withdraw _ _ _ _,             signer => [.registry signer]
  | .declareLocalPolicy _,         signer => [.registry signer]
  | .revokeLocalPolicy,            signer => [.registry signer]
  | .faultProofChallenge _ _ _ _,  signer => [.registry signer]
  | .faultProofResolution _ _ _ _, signer => [.registry signer]
  -- Workstream GP (v1.0): depositWithFee additionally reads the
  -- consumed-deposit map to verify the deposit hasn't already
  -- been credited (mirroring `deposit`).  topUpActionBudget only
  -- reads the signer's registry entry.
  | .depositWithFee _ _ _ _ _ _ d, signer =>
      [.registry signer, .bridgeConsumed d]
  | .topUpActionBudget _ _ _ _,    signer => [.registry signer]
  -- GP.3.4: delegated top-up reads only the signer's registry entry
  -- (the recipient-consent check reads the recipient's local policy
  -- at the admission layer, not at the L1 step-VM cell level).
  | .topUpActionBudgetFor _ _ _ _ _, signer => [.registry signer]

/-- The cell tags an action writes.  Per the §4.13 contract,
    every action advances the signer's nonce; the per-action
    additional writes are captured by the per-variant arms below.

    **Bulk actions** (`distributeOthers`, `proportionalDilute`):
    the recipient-list-dependent balance writes are NOT enumerated
    at this action level; instead they decompose per-recipient
    via `Action.subSteps` (per WU H.1.4).  At the action level
    we declare only the writes the action ALWAYS does (the
    signer's nonce); the bulk sub-steps emit the per-recipient
    balance cell proofs.

    **Withdraw**: the new bridge pending entry's key is the
    deployment's current `nextWdId` counter (not knowable
    statically from the action's parameters).  We declare the
    `bridgeNextWdId` counter cell and the signer's balance +
    nonce; the per-game cell-proof bundle additionally carries
    the witnessed `bridgePending nextWdId` cell, but at the
    action-declaration level we mark this dependency abstractly
    by including `bridgeNextWdId` (whose value the L1 step VM
    reads to derive the pending-id). -/
def Action.writeCells : Action → ActorId → List CellTag
  | .transfer r sender receiver _, signer =>
      [.balance r sender, .balance r receiver, .nonce signer]
  | .mint r to _,                  signer =>
      [.balance r to, .nonce signer]
  | .burn r fromActor _,           signer =>
      [.balance r fromActor, .nonce signer]
  | .freezeResource _,             signer =>
      [.nonce signer]
  | .replaceKey actor _,           signer =>
      [.registry actor, .nonce signer]
  | .reward r to _,                signer =>
      [.balance r to, .nonce signer]
  -- Bulk actions: action-level writes are nonce + bridge-state-
  -- independent cells.  Per-recipient writes are emitted by
  -- the sub-step machinery (`Action.subSteps`) at game-play time.
  | .distributeOthers _ _ _,       signer =>
      [.nonce signer]
  | .proportionalDilute _ _ _,     signer =>
      [.nonce signer]
  | .dispute _,                    signer => [.nonce signer]
  | .disputeWithdraw _,            signer => [.nonce signer]
  | .verdict _,                    signer => [.nonce signer]
  | .rollback _,                   signer => [.nonce signer]
  | .registerIdentity actor _,     signer =>
      [.registry actor, .nonce signer]
  | .deposit r recipient _ d,      signer =>
      [.balance r recipient, .nonce signer, .bridgeConsumed d]
  -- Withdraw: action-level writes are the signer's balance, the
  -- signer's nonce, and the `bridgeNextWdId` counter.  The newly-
  -- allocated `bridgePending <nextWdId>` cell is emitted by the
  -- runtime cell-proof builder at game-play time (the index is
  -- derived from the witnessed `bridgeNextWdId` cell's pre-state
  -- value); it doesn't appear in this STATIC action-level
  -- declaration.
  | .withdraw r sender _ _,        signer =>
      [.balance r sender, .nonce signer, .bridgeNextWdId]
  | .declareLocalPolicy _,         signer =>
      [.localPolicy signer, .nonce signer]
  | .revokeLocalPolicy,            signer =>
      [.localPolicy signer, .nonce signer]
  -- Fault-proof actions: only mutate the signer's nonce (the L1
  -- contract is authoritative for game state).
  | .faultProofChallenge _ _ _ _,  signer => [.nonce signer]
  | .faultProofResolution _ _ _ _, signer => [.nonce signer]
  -- Workstream GP (v1.0): depositWithFee writes the recipient's
  -- balance, the poolActor's balance, the bridge-consumed cell,
  -- and the signer's nonce.  The recipient's epoch-budget
  -- update (budget grant) is an admission-layer effect; at the
  -- L1 step-VM action-level we only declare kernel-state writes.
  | .depositWithFee r recipient poolActor _ _ _ d, signer =>
      [.balance r recipient, .balance r poolActor, .bridgeConsumed d, .nonce signer]
  -- topUpActionBudget writes the signer's gas balance, the
  -- poolActor's gas balance, and the signer's nonce.  The
  -- signer's epoch-budget increment is an admission-layer effect
  -- (out of scope for the L1 step VM's static cell declaration).
  | .topUpActionBudget gr _ _ pa,  signer =>
      [.balance gr signer, .balance gr pa, .nonce signer]
  -- GP.3.4: delegated top-up writes the signer's (payer's) gas
  -- balance, the poolActor's gas balance, and the signer's nonce.
  -- The recipient's epoch-budget increment is an admission-layer
  -- effect (out of scope for the L1 step VM's static cell
  -- declaration), so it is not a kernel-state cell write.
  | .topUpActionBudgetFor _ gr _ _ pa, signer =>
      [.balance gr signer, .balance gr pa, .nonce signer]

/-- The complete cell set an action touches: read-only ++ writes.
    The L1 step VM expects a `CellProofBundle` of exactly this
    cardinality and order. -/
def Action.requiredCells (a : Action) (signer : ActorId) : List CellTag :=
  a.readOnlyCells signer ++ a.writeCells signer

/-! ## Decidability -/

/-- `Action.readOnlyCells` is total and finite.  Decidability of
    membership in the result list follows from `DecidableEq` on
    `CellTag`. -/
instance Action.decReadOnlyCellsMem (a : Action) (signer : ActorId)
    (tag : CellTag) :
    Decidable (tag ∈ a.readOnlyCells signer) :=
  inferInstance

/-- `Action.writeCells` is total and finite. -/
instance Action.decWriteCellsMem (a : Action) (signer : ActorId)
    (tag : CellTag) :
    Decidable (tag ∈ a.writeCells signer) :=
  inferInstance

/-! ## Smoke checks -/

/-- A `transfer` requires four cells: registry-of-signer
    (read-only), balance-of-sender, balance-of-receiver,
    nonce-of-signer (all write). -/
example (r : ResourceId) (s rcv : ActorId) (a : Amount) :
    Action.requiredCells (.transfer r s rcv a) s =
      [CellTag.registry s, CellTag.balance r s, CellTag.balance r rcv,
       CellTag.nonce s] := rfl

/-- A `mint` requires three cells: registry-of-signer,
    balance-of-recipient, nonce-of-signer. -/
example (r : ResourceId) (to : ActorId) (a : Amount) (s : ActorId) :
    Action.requiredCells (.mint r to a) s =
      [CellTag.registry s, CellTag.balance r to, CellTag.nonce s] := rfl

/-- A `freezeResource` requires two cells: registry-of-signer,
    nonce-of-signer. -/
example (r : ResourceId) (s : ActorId) :
    Action.requiredCells (.freezeResource r) s =
      [CellTag.registry s, CellTag.nonce s] := rfl

/-- A `faultProofChallenge` requires two cells (signer
    registry + signer nonce). -/
example (bh : ByteArray) (sIdx eIdx : LegalKernel.Disputes.LogIndex)
    (cc : ByteArray) (s : ActorId) :
    Action.requiredCells (.faultProofChallenge bh sIdx eIdx cc) s =
      [CellTag.registry s, CellTag.nonce s] := rfl

/-! ## Required-cells partition (plan §18 #263)

The cell set an action touches decomposes into read-only ++
write-cells exactly as defined.  Used downstream by the verifier
to separate read-only from write proofs. -/

/-- #263 — `Action.requiredCells` decomposes into read-only ++
    write-cells exactly as defined.  This holds by `rfl` because
    `requiredCells` is defined as that concatenation above. -/
theorem Action.requiredCells_eq_readOnly_append_writeCells
    (a : Action) (signer : ActorId) :
    a.requiredCells signer = a.readOnlyCells signer ++ a.writeCells signer :=
  rfl

/-- #263 corollary — the read-only / write-cells decomposition's
    length sum equals the total required-cell count. -/
theorem Action.requiredCells_length_eq
    (a : Action) (signer : ActorId) :
    (a.requiredCells signer).length =
    (a.readOnlyCells signer).length + (a.writeCells signer).length := by
  rw [Action.requiredCells_eq_readOnly_append_writeCells]
  exact List.length_append

end Authority
end LegalKernel

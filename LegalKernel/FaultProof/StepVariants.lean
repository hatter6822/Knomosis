-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
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
  -- GP.9.1: refund-on-exit reads only the signer's registry entry.
  -- The refundable-budget bound + rate pin are admission-layer checks
  -- (over the signer's epoch budget + the trusted rate), not L1
  -- step-VM cell reads.
  | .claimBudgetRefund _ _ _ _,    signer => [.registry signer]
  -- GP.11.4: L2 AMM swap.  Reads only the signer's registry entry.
  -- The swap is bridge-attested; no deposit-id dedup is needed (the
  -- L1 contract prevents double-execution operationally via
  -- nonReentrant + single-atomic-swap semantics).
  | .ammSwap _ _ _ _ _,            signer => [.registry signer]
  -- GP.11.10: post-disable reserve sweep.  Reads only the signer's
  -- registry entry; the exact-sweep + kill-switch gates are
  -- admission-layer checks (`BridgeAdmissibleWith` conjunct 9 over the
  -- L2 `ammDisabled` mirror), not L1 step-VM cell reads.
  | .reclaimAmmReserves _ _ _ _,   signer => [.registry signer]
  -- Workstream SB: the user swap.  Reads only the signer's registry
  -- entry — every cell the quote is priced FROM (the reserve's two
  -- balances, the user's from-balance) is also WRITTEN, so they live
  -- in `writeCells`, whose openings carry the pre-values the L1
  -- verifier re-derives the quote from.
  | .reserveSwap _ _ _ _ _ _,      signer => [.registry signer]

/-- The cell tags an action writes.  Per the §4.13 contract,
    every action advances the signer's nonce; the per-action
    additional writes are captured by the per-variant arms below.

    **This list is deliberately incomplete**, for three variants, and
    for one reason: their write sets are functions of the STATE, which
    `(action, signer)` cannot name.  `Action.stateWriteCells` names
    them and `Action.writeCellsAt` is the union — that is what the
    fault proof consumes, and what `WriteSetComplete` is stated
    against.

      * **`withdraw`** — the new pending entry is keyed by the
        deployment's current `nextWdId`.
      * **`distributeOthers` / `proportionalDilute`** — one balance
        cell per non-excluded actor at the resource, i.e.
        `Laws.bulkRecipients`.

    The bulk pair used to be described as decomposing per-recipient via
    `Action.subSteps` instead.  That was the plan while the write set
    was thought to be unbounded; `Laws.BulkBounded` now caps it in the
    law's own precondition, so above the cap the step is a no-op and
    below it the recipient list IS the footprint.  Enumerating it keeps
    the bisection's terminal step a single `executeStep` rather than a
    second addressing scheme the game would have to carry. -/
def Action.writeCells : Action → ActorId → List CellTag
  | .transfer r sender receiver _, signer =>
      [.balance r sender, .balance r receiver, .nonce signer, .epochBudget signer]
  | .mint r to _,                  signer =>
      [.balance r to, .nonce signer, .epochBudget signer]
  | .burn r fromActor _,           signer =>
      [.balance r fromActor, .nonce signer, .epochBudget signer]
  | .freezeResource _,             signer =>
      [.nonce signer, .epochBudget signer]
  | .replaceKey actor _,           signer =>
      [.registry actor, .nonce signer, .epochBudget signer]
  | .reward r to _,                signer =>
      [.balance r to, .nonce signer, .epochBudget signer]
  -- Bulk actions: action-level writes are nonce + bridge-state-
  -- independent cells.  Per-recipient writes are emitted by
  -- the sub-step machinery (`Action.subSteps`) at game-play time.
  | .distributeOthers _ _ _,       signer =>
      [.nonce signer, .epochBudget signer]
  | .proportionalDilute _ _ _,     signer =>
      [.nonce signer, .epochBudget signer]
  | .dispute _,                    signer => [.nonce signer, .epochBudget signer]
  | .disputeWithdraw _,            signer => [.nonce signer, .epochBudget signer]
  | .verdict _,                    signer => [.nonce signer, .epochBudget signer]
  | .rollback _,                   signer => [.nonce signer, .epochBudget signer]
  | .registerIdentity actor _,     signer =>
      [.registry actor, .nonce signer, .epochBudget signer]
  | .deposit r recipient _ d,      signer =>
      [.balance r recipient, .nonce signer, .epochBudget signer, .bridgeConsumed d]
  -- Withdraw: action-level writes are the signer's balance, the
  -- signer's nonce, and the `bridgeNextWdId` counter.  The newly-
  -- allocated `bridgePending <nextWdId>` cell is emitted by the
  -- runtime cell-proof builder at game-play time (the index is
  -- derived from the witnessed `bridgeNextWdId` cell's pre-state
  -- value); it doesn't appear in this STATIC action-level
  -- declaration.
  | .withdraw r sender _ _,        signer =>
      [.balance r sender, .nonce signer, .epochBudget signer, .bridgeNextWdId]
  | .declareLocalPolicy _,         signer =>
      [.localPolicy signer, .nonce signer, .epochBudget signer]
  | .revokeLocalPolicy,            signer =>
      [.localPolicy signer, .nonce signer, .epochBudget signer]
  -- Fault-proof actions: only mutate the signer's nonce (the L1
  -- contract is authoritative for game state).
  | .faultProofChallenge _ _ _ _,  signer => [.nonce signer, .epochBudget signer]
  | .faultProofResolution _ _ _ _, signer => [.nonce signer, .epochBudget signer]
  -- Workstream GP (v1.0): depositWithFee writes the recipient's
  -- balance, the poolActor's balance, the bridge-consumed cell,
  -- and the signer's nonce.  The recipient's epoch-budget
  -- update (budget grant) is an admission-layer effect; at the
  -- L1 step-VM action-level we only declare kernel-state writes.
  | .depositWithFee r recipient poolActor _ _ _ d, signer =>
      [.balance r recipient, .balance r poolActor, .bridgeConsumed d,
       .nonce signer, .epochBudget signer, .epochBudget recipient]
  -- topUpActionBudget writes the signer's gas balance, the
  -- poolActor's gas balance, and the signer's nonce.  The
  -- signer's epoch-budget increment is an admission-layer effect
  -- (out of scope for the L1 step VM's static cell declaration).
  | .topUpActionBudget gr _ _ pa,  signer =>
      [.balance gr signer, .balance gr pa, .nonce signer, .epochBudget signer]
  -- GP.3.4: delegated top-up writes the signer's (payer's) gas
  -- balance, the poolActor's gas balance, and the signer's nonce.
  -- The recipient's epoch-budget increment is an admission-layer
  -- effect (out of scope for the L1 step VM's static cell
  -- declaration), so it is not a kernel-state cell write.
  | .topUpActionBudgetFor recipient gr _ _ pa, signer =>
      [.balance gr signer, .balance gr pa,
       .nonce signer, .epochBudget signer, .epochBudget recipient]
  -- GP.9.1: refund-on-exit writes the claimant's (signer's) gas
  -- balance (CREDITED from the pool), the poolActor's gas balance
  -- (DEBITED), and the signer's nonce.  The MIRROR of
  -- `topUpActionBudget`'s writes (same two balance cells + nonce; only
  -- the debit/credit direction differs).  The signer's epoch-budget
  -- DEBIT is an admission-layer effect, out of scope for the L1
  -- step-VM's static cell declaration.
  | .claimBudgetRefund gr _ _ pa,  signer =>
      [.balance gr signer, .balance gr pa, .nonce signer, .epochBudget signer]
  -- GP.11.4: L2 AMM swap writes the ammReserveActor's balances at
  -- BOTH resources (credit at fromResource, debit at toResource) plus
  -- the signer's nonce.
  | .ammSwap fr tr _ _ ra,         signer =>
      [.balance fr ra, .balance tr ra, .nonce signer, .epochBudget signer]
  -- GP.11.10: post-disable reserve sweep writes BOTH actors' balances
  -- at the single swept resource (debit the reserve actor to zero,
  -- credit the pool actor) plus the signer's nonce.
  | .reclaimAmmReserves r _ ra pa, signer =>
      [.balance r ra, .balance r pa, .nonce signer, .epochBudget signer]
  -- Workstream SB: the user swap writes FOUR balance cells — the user
  -- and the reserve each at both resources, listed in the law's write
  -- order (user debit at `fr`, reserve credit at `fr`, reserve debit
  -- at `tr`, user credit at `tr`) — plus the signer's nonce.  The
  -- openings of these four cells carry exactly the pre-values the L1
  -- verifier needs to re-derive the constant-product quote.
  | .reserveSwap fr tr user _ _ ra, signer =>
      [.balance fr user, .balance fr ra, .balance tr ra, .balance tr user,
       .nonce signer, .epochBudget signer]

/-- The cells an action writes whose KEY is a function of the
    pre-state rather than of the action.

    Exactly one action has any: `withdraw` allocates its pending entry
    at the deployment's current `nextWdId` (`BridgeState.appendWithdrawal`
    inserts at `bs.nextWdId` and then increments it), and no
    `(action, signer)` pair determines that number.

    Splitting it out rather than widening `Action.writeCells` keeps the
    static declaration a pure function of the action — which is what
    the Solidity mirror and the cross-stack corpus pin — while making
    the COMPLETE set (`Action.writeCellsAt`) available to the fault
    proof, which is the consumer that needs completeness.  Before this
    existed, a withdrawal's declared write set omitted the cell the
    withdrawal creates, so a bundle carrying only the declared cells
    could not reproduce the post-root. -/
def Action.stateWriteCells (es : ExtendedState) : Action → ActorId → List CellTag
  | .withdraw _ _ _ _, _ => [.bridgePending es.bridge.nextWdId]
  -- The two bulk variants credit every non-excluded actor at `r`, so
  -- their write set is the recipient list — a function of the state,
  -- which is exactly what this projection is for.  `Laws.bulkRecipients`
  -- is the SAME list both laws fold over, in the same `Std.TreeMap`
  -- order, so the write set is the footprint rather than a
  -- re-derivation of it.
  | .distributeOthers r excluded _, _ =>
      (Laws.bulkRecipients es.base r excluded).map (fun p => .balance r p.1)
  | .proportionalDilute r excluded _, _ =>
      (Laws.bulkRecipients es.base r excluded).map (fun p => .balance r p.1)
  | _,                 _ => []

/-- **The complete cell-write set**: the static declaration plus the
    state-keyed cells.  This is what a fault proof must open, and what
    `WriteSetComplete` is stated against. -/
def Action.writeCellsAt (es : ExtendedState) (a : Action) (signer : ActorId) :
    List CellTag :=
  a.writeCells signer ++ a.stateWriteCells es signer

/-- Away from `withdraw` and the two bulk variants the complete set IS
    the static one, so the other twenty-two pay nothing for the split. -/
theorem Action.writeCellsAt_eq_writeCells (es : ExtendedState) (a : Action)
    (signer : ActorId)
    (h : ∀ r sender amount rcp, a ≠ .withdraw r sender amount rcp)
    (h_bulk₁ : ∀ r excluded amount, a ≠ .distributeOthers r excluded amount)
    (h_bulk₂ : ∀ r excluded amount, a ≠ .proportionalDilute r excluded amount) :
    a.writeCellsAt es signer = a.writeCells signer := by
  unfold Action.writeCellsAt Action.stateWriteCells
  cases hact : a with
  | withdraw r sender amount rcp => exact absurd hact (h r sender amount rcp)
  | distributeOthers r e amt => exact absurd hact (h_bulk₁ r e amt)
  | proportionalDilute r e amt => exact absurd hact (h_bulk₂ r e amt)
  | _ => exact List.append_nil _

/-- At a bulk variant the complete set is the static one plus one
    balance cell per recipient, in the order both laws fold. -/
theorem Action.writeCellsAt_distributeOthers (es : ExtendedState)
    (r : ResourceId) (excluded : ActorId) (amount : Amount) (signer : ActorId) :
    (Action.distributeOthers r excluded amount).writeCellsAt es signer =
      [.nonce signer, .epochBudget signer] ++
        (Laws.bulkRecipients es.base r excluded).map (fun p => .balance r p.1) :=
  rfl

/-- ...and the same at `proportionalDilute`. -/
theorem Action.writeCellsAt_proportionalDilute (es : ExtendedState)
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) (signer : ActorId) :
    (Action.proportionalDilute r excluded totalReward).writeCellsAt es signer =
      [.nonce signer, .epochBudget signer] ++
        (Laws.bulkRecipients es.base r excluded).map (fun p => .balance r p.1) :=
  rfl

/-- And at `withdraw` it is the static set plus exactly the allocated
    pending cell. -/
theorem Action.writeCellsAt_withdraw (es : ExtendedState)
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (rcp : LegalKernel.Bridge.EthAddress) (signer : ActorId) :
    (Action.withdraw r sender amount rcp).writeCellsAt es signer =
      [.balance r sender, .nonce signer, .epochBudget signer, .bridgeNextWdId,
       .bridgePending es.bridge.nextWdId] := rfl

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
       CellTag.nonce s, CellTag.epochBudget s] := rfl

/-- A `mint` requires three cells: registry-of-signer,
    balance-of-recipient, nonce-of-signer. -/
example (r : ResourceId) (to : ActorId) (a : Amount) (s : ActorId) :
    Action.requiredCells (.mint r to a) s =
      [CellTag.registry s, CellTag.balance r to, CellTag.nonce s,
       CellTag.epochBudget s] := rfl

/-- A `freezeResource` requires two cells: registry-of-signer,
    nonce-of-signer. -/
example (r : ResourceId) (s : ActorId) :
    Action.requiredCells (.freezeResource r) s =
      [CellTag.registry s, CellTag.nonce s, CellTag.epochBudget s] := rfl

/-- A `faultProofChallenge` requires two cells (signer
    registry + signer nonce). -/
example (bh : ByteArray) (sIdx eIdx : LegalKernel.Disputes.LogIndex)
    (cc : ByteArray) (s : ActorId) :
    Action.requiredCells (.faultProofChallenge bh sIdx eIdx cc) s =
      [CellTag.registry s, CellTag.nonce s, CellTag.epochBudget s] := rfl

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

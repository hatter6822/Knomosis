-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Terminate — the OPENINGS-ONLY verifier: the
Lean mirror of `KnomosisStepVMRoot.executeStepToRoot`.

`stepPostRoot` (`StepWriteSets.lean`) is the SEQUENCER's computation.
It takes the pre-state and reads its `newValue` column off
`productionApplyBudget`, so its guarantee — the fold lands on the root
the sequencer published — says nothing about a bundle an arbitrary
party supplies.  A verifier holds a pre-root and a bundle of openings
and nothing else, so it has to derive both halves itself:

  * the cell LIST, from `(action, signer)` plus the proven
    `.bridgeNextWdId` — `verifierWriteCells`, checked against the
    submitted bundle position by position, which is what stops a
    responder omitting a write and folding to a root where that cell
    never moved;
  * each cell's VALUE, from the proven pre-values —
    `VerifierWrites`, which is `productionApplyBudget` re-expressed
    cell-locally with a `*_correct` theorem per cell kind.

This module assembles those into one function, so the Lean model of
`terminateOnSingleStep` computes what the contract computes rather
than what the sequencer does.

Two properties run through it, both inherited from `VerifierWrites`:

  * **the precondition is EVALUATED, not asserted** — `step_impl` is
    `if pre then apply_impl else id`, so an action whose precondition
    fails advances nothing but the nonce and the budget, and the fold
    still has to land on that root.  Refusing instead would not be a
    verdict: the terminal step is callable only by whoever's turn it
    is, so any refusing input costs the responsible party the game by
    timeout;
  * **the reader is PARTIAL** — an omitted opening derives `none`
    rather than a value of the responder's choosing.

`docs/planning/state_root_merkleisation_plan.md` §4 step 3.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.StepWriteSets
import LegalKernel.FaultProof.VerifierWrites

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding
open LegalKernel.Runtime

/-! ## The opening -/

/-- One cell opening in a step's bundle — the Lean mirror of
    `KnomosisStepVMRoot.CellOpening`.

    `preValue` is the cell's value in the state this opening is
    against: the PRE-state for the first write to a cell, and the
    running state for a later one.  It is not trusted — the opening
    must verify against the running root with a leaf built from
    exactly these bytes, so a lie is caught by the walk rather than by
    a check. -/
structure CellOpening where
  /-- Which cell this opening names. -/
  cellTag  : CellTag
  /-- The cell's value in the state this opening is against. -/
  preValue : ByteArray
  /-- The sibling path. -/
  proof    : SmtCellProof
  deriving Repr

/-- The opening a `StateCellWrite` carries: its tag, its pre-value and
    its path.  The new value is dropped on purpose — that column is
    the sequencer's, and a verifier that consumed it would fold to a
    root of the responder's choosing. -/
def CellOpening.ofStateCellWrite (w : StateCellWrite) : CellOpening :=
  { cellTag := w.1, preValue := w.2.1, proof := w.2.2.2 }

/-- The honest bundle for a step: `stepWriteBundle` with the new
    values stripped. -/
def stepOpenings (es : ExtendedState) (st : SignedAction) (idx : Nat) :
    List CellOpening :=
  (stepWriteBundle es st idx).map CellOpening.ofStateCellWrite

/-- The read-only budget-policy opening, against the pre-root.  Not a
    write, so it is not in the bundle — but `deriveEpochBudget`
    selects its branch on it and every one of the twenty-five variants
    writes an epoch-budget cell, so the verifier cannot start without
    it. -/
def policyOpening (es : ExtendedState) : CellOpening :=
  { cellTag  := .budgetPolicy
  , preValue := getCellValue es .budgetPolicy
  , proof    := buildStateCellProof es .budgetPolicy }

/-- The wire form of an opening: the `CellProof` the JSON emitter and
    the Rust conduit carry.

    `witnessState` is the pre-state on every entry, and nothing reads
    it — the L1 verifies `proofData` against the running root.  It is
    the field the wire dropped; it survives in the Lean structure only
    until `CellProof` itself retires. -/
def openingCellProof (es : ExtendedState) (o : CellOpening) : CellProof :=
  { cellTag      := o.cellTag
  , cellValue    := o.preValue
  , witnessState := es
  , proofData    := SmtCellProof.toWireBytes o.proof }

/-! ## The cell list

The verifier's counterpart to `Action.writeCellsAt`, which it cannot
call: that takes the state, and the only state-keyed cell an
adjudicable action writes is `withdraw`'s pending entry, keyed by the
PRE-state's counter — which is itself a proven cell. -/

/-- The cells a step writes, as a function of the action, the signer
    and the proven `.bridgeNextWdId` pre-value. -/
def verifierWriteCells (a : Action) (signer : ActorId) (nextWdIdPre : Nat) :
    List CellTag :=
  a.writeCells signer ++
    (match a with
     | .withdraw _ _ _ _ => [.bridgePending nextWdIdPre]
     | _                 => [])

/-- **The verifier's cell list is the complete one.**  For every
    adjudicable action, deriving from the proven counter reaches
    exactly `Action.writeCellsAt` — so the check against the submitted
    bundle is a check against completeness, not against a weaker
    static declaration.

    False for the two bulk variants, whose set is the actor set at a
    resource; that is what `FaultProofAdjudicable` excludes. -/
theorem verifierWriteCells_eq_writeCellsAt
    (es : ExtendedState) (a : Action) (signer : ActorId)
    (h : FaultProofAdjudicable a = true) :
    verifierWriteCells a signer es.bridge.nextWdId = a.writeCellsAt es signer := by
  unfold verifierWriteCells Action.writeCellsAt Action.stateWriteCells
  cases a with
  | withdraw r sender amount rcp => rfl
  | distributeOthers r e amt => exact absurd h (by simp [FaultProofAdjudicable])
  | proportionalDilute r e amt => exact absurd h (by simp [FaultProofAdjudicable])
  | _ => rfl

/-! ## Reading the bundle -/

/-- The PRE-STATE value of the opening at index `i`: the `preValue` of
    the FIRST opening naming that cell.

    A later write to the same cell opens against the running state, so
    its `preValue` is the earlier write's result, while every
    derivation is a function of the pre-state.  Duplicates are
    reachable — a self-transfer, a `depositWithFee` whose recipient is
    the signer, a self-delegated top-up — and every derivation is
    idempotent on them, so the second write lands the same value and
    leaves the root alone. -/
def preStateValueAt (ops : List CellOpening) (t : CellTag) : Option ByteArray :=
  (ops.find? (fun o => o.cellTag == t)).map CellOpening.preValue

/-- The balance reader the bundle induces: `some` exactly where the
    bundle opens that balance cell, and `none` elsewhere.

    PARTIAL by design.  A derivation reading a cell the bundle does
    not open produces nothing rather than a default, so an omitted
    opening cannot be passed off as a zero balance. -/
def openingBalanceReader (ops : List CellOpening) : BalanceReader :=
  fun r a =>
    match preStateValueAt ops (.balance r a) with
    | none   => none
    | some v =>
      match Encoding.decodeAmount v.data.toList with
      | .ok (n, []) => some n
      | _           => none

/-- The proven `.bridgeNextWdId` pre-value, or `0` when the bundle
    does not open that cell.

    The default is safe rather than convenient: only `withdraw` writes
    that cell, and for `withdraw` a wrong value names a pending cell
    whose opening then has to verify against the running root — which
    it cannot, since the bundle's shape is checked against the list
    this number determines. -/
def provenNextWdId (ops : List CellOpening) : Nat :=
  match preStateValueAt ops .bridgeNextWdId with
  | none   => 0
  | some v =>
    match Encodable.decode (T := Nat) v.data.toList with
    | .ok (n, []) => n
    | _           => 0

/-! ## The per-variant balance plan

The balance cells cannot be derived one at a time.  Five variants
write two that are CHAINED — the second read sees the first write —
and the coinciding case is reachable in every one of them, cheaply, by
anyone.  So the pair is planned once from BOTH pre-values, which is
what `VerifierWrites`' `derive*Balances` family already does: each
returns the per-cell post-values as an association list. -/

/-- The balance cells' post-values, as `((resource, actor), value)`
    pairs.  `none` when the bundle does not open a cell the variant
    needs. -/
def plannedBalances (read : BalanceReader)
    (a : Action) (signer : ActorId) :
    Option (List ((ResourceId × ActorId) × Nat)) :=
  match a with
  | .transfer r sender receiver amount =>
      deriveTransferBalances read r sender receiver amount
  | .mint r to amount   => deriveCreditBalance read r to amount
  | .reward r to amount => deriveCreditBalance read r to amount
  | .burn r from_ amount => deriveBurnBalance read r from_ amount
  | .deposit r recipient amount _ =>
      deriveDepositBalance read r recipient amount
  | .withdraw r sender amount _ =>
      deriveWithdrawBalance read r sender amount
  | .depositWithFee r recipient poolActor userAmount poolAmount _ _ =>
      deriveDepositWithFeeBalances read r recipient poolActor
        userAmount poolAmount
  | .topUpActionBudget gr gasAmount _ pa =>
      deriveTopUpBalances read gr signer pa gasAmount
  | .topUpActionBudgetFor recipient gr gasAmount _ pa =>
      deriveDelegatedTopUpBalances read gr signer pa recipient gasAmount
  | .claimBudgetRefund gr budgetUnits weiPerBudgetUnit pa =>
      deriveRefundBalances read gr pa signer
        (budgetUnits * weiPerBudgetUnit)
  | .ammSwap fromResource toResource amountIn amountOut reserveActor =>
      deriveAmmSwapBalances read fromResource toResource
        amountIn amountOut reserveActor
  | .reclaimAmmReserves r amount reserveActor poolActor =>
      deriveReclaimBalances read r reserveActor poolActor amount
  -- The thirteen variants that write no balance cell at all.
  | _ => some []

/-- Look one balance cell up in the plan. -/
def plannedBalanceAt (plan : List ((ResourceId × ActorId) × Nat))
    (r : ResourceId) (a : ActorId) : Option Nat :=
  (plan.find? (fun p => p.1 == (r, a))).map Prod.snd

/-! ## The per-cell value -/

/-- Cell `t`'s post-value, derived from the bundle's proven
    pre-values and the action's own fields.  `none` when a needed
    opening is missing or malformed. -/
def derivedCellValue (ops : List CellOpening) (policyValue : ByteArray)
    (a : Action) (signer : ActorId) (l2LogIndex : Nat)
    (plan : List ((ResourceId × ActorId) × Nat)) (t : CellTag) :
    Option ByteArray :=
  match t with
  | .balance r actor =>
    (plannedBalanceAt plan r actor).map
      (fun v => ByteArray.mk (Encoding.encodeAmount v).toArray)
  | .nonce _ =>
    match preStateValueAt ops t with
    | none   => none
    | some v => deriveNonceCellValue v
  | .epochBudget target =>
    match preStateValueAt ops (.epochBudget signer), preStateValueAt ops t with
    | some signerValue, some targetValue =>
      deriveEpochBudgetCellValue policyValue signerValue targetValue a signer target
    | _, _ => none
  | .registry _ =>
    match a with
    | .replaceKey _ key       => some (deriveRegistryCellValue key)
    | .registerIdentity _ pk  => some (deriveRegistryCellValue pk)
    | _                       => none
  | .localPolicy _ =>
    match a with
    | .declareLocalPolicy p => some (deriveDeclaredPolicyCellValue p)
    | .revokeLocalPolicy    => some deriveRevokedPolicyCellValue
    | _                     => none
  | .bridgeConsumed _ =>
    match a with
    | .deposit r _ amount _ =>
      some (deriveConsumedCellValue
        { resource := r, userAmount := amount
        , poolAmount := 0, budgetGrant := 0 })
    | .depositWithFee r _ _ userAmount poolAmount bg _ =>
      some (deriveConsumedCellValue
        { resource := r, userAmount := userAmount
        , poolAmount := poolAmount, budgetGrant := bg })
    | _ => none
  | .bridgePending _ =>
    match a with
    | .withdraw r _ amount rcp =>
      some (derivePendingCellValue
        { resource := r, recipient := rcp, amount := amount
        , l2LogIndex := l2LogIndex })
    | _ => none
  | .bridgeNextWdId =>
    match preStateValueAt ops t with
    | none   => none
    | some v => deriveNextWdIdCellValue v
  -- No adjudicable action writes any other cell kind; a bundle
  -- naming one fails the shape check before reaching here.
  | _ => none

/-! ## The verifier -/

/-- Assemble one write for the fold: the opening's own pre-value (the
    RUNNING one, which is what the opening is against) and the derived
    post-value. -/
def foldEntry (ops : List CellOpening) (policyValue : ByteArray)
    (a : Action) (signer : ActorId) (l2LogIndex : Nat)
    (plan : List ((ResourceId × ActorId) × Nat)) (o : CellOpening) :
    Option StateCellWrite :=
  (derivedCellValue ops policyValue a signer l2LogIndex plan o.cellTag).map
    (fun newV => (o.cellTag, o.preValue, newV, o.proof))

/-- **The openings-only post-state root** — what an L1 holding a
    pre-root and a bundle computes.  The Lean mirror of
    `KnomosisStepVMRoot.executeStepToRoot`.

    `none` on any refusal: a non-adjudicable action, a policy opening
    that does not verify or does not name the policy cell, a bundle
    whose cells are not the ones the action writes, a missing or
    malformed pre-value, or an opening that does not verify against
    the running root.  Every one of those is a SUBMISSION failure
    rather than a state-transition outcome — a failing law precondition
    is a no-op here, not a refusal. -/
def verifierPostRoot (preRoot : StateCommit) (a : Action) (signer : ActorId)
    (l2LogIndex : Nat) (policy : CellOpening) (ops : List CellOpening) :
    Option StateCommit :=
  if ¬ FaultProofAdjudicable a then none
  else if policy.cellTag ≠ .budgetPolicy then none
  else if ¬ verifyStateCellProof preRoot .budgetPolicy policy.preValue policy.proof
    then none
  else if ops.map CellOpening.cellTag
            ≠ verifierWriteCells a signer (provenNextWdId ops) then none
  else
    match plannedBalances (openingBalanceReader ops) a signer with
    | none      => none
    | some plan =>
      match ops.mapM (foldEntry ops policy.preValue a signer l2LogIndex plan) with
      | none       => none
      | some writes => foldStateCellWrites preRoot writes

end FaultProof
end LegalKernel

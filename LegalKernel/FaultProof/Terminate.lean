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
Lean mirror of `KnomosisStepVMRoot.executeStepToRootMulti`.

`stepPostRoot` (`StepWriteSets.lean`) is the SEQUENCER's computation.
It takes the pre-state and reads its `newValue` column off
`productionApplyBudget`, so its guarantee — the fold lands on the root
the sequencer published — says nothing about a bundle an arbitrary
party supplies.  A verifier holds a pre-root and a bundle and nothing
else, so it has to derive both halves itself:

  * the cell LIST, from `(action, signer)` plus the proven
    `.bridgeNextWdId` — `verifierWriteCells`, whose FRONTIER is checked
    against the submitted one as a set, which is what stops a responder
    omitting a write and folding to a root where that cell never moved;
  * each cell's VALUE, from the proven pre-values —
    `VerifierWrites`, which is `productionApplyBudget` re-expressed
    cell-locally with a `*_correct` theorem per cell kind.

This module assembles those into one function, so the Lean model of
`terminateOnSingleStep` computes what the contract computes rather
than what the sequencer does.

The bundle is a DEDUPLICATING PRE-ROOT MULTIPROOF: every cell opened
once against the pre-root, sharing one sibling list, with the aggregate
compared to the pre-root once.  A CHAINED arrangement shipped first —
one opening per WRITE, each against the running root — and lived here
until the multiproof replaced it on all three stacks; `CellOpening` is
what survives of it, because the SMT opening it carries is still the
shape `buildStateCellProof` produces and the observer publishes.

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

import LegalKernel.FaultProof.Frontier
import LegalKernel.FaultProof.MultiProof
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

/-- Look one balance cell up in the plan, refusing a disagreeing
    duplicate rather than resolving one.

    Routes through `plannedBalanceAt?` rather than taking the first
    match.  `plannedBalances_alias_consistent` proves the refusal
    unreachable from any action, so this changes no behaviour any step
    can reach; what it buys is that a derivation bug not yet written
    fails closed instead of silently picking whichever entry the search
    finds first.  Under the chained fold that could not matter — a cell
    was read per OCCURRENCE, against the running state — and under a
    multiproof it is read per CELL, which is what makes the question
    real. -/
def plannedBalanceAt (plan : List ((ResourceId × ActorId) × Nat))
    (r : ResourceId) (a : ActorId) : Option Nat :=
  plannedBalanceAt? plan r a

/-! ## The per-cell value -/

/-- A partial reader of a bundle's proven pre-values, keyed by cell.

    PARTIAL is the load-bearing half: a derivation reading a cell the
    bundle does not open must produce nothing rather than a default, so
    an omitted opening cannot be passed off as a zero. -/
abbrev CellValueReader := CellTag → Option ByteArray

/-- Cell `t`'s post-value, derived from the bundle's proven
    pre-values and the action's own fields.  `none` when a needed
    opening is missing or malformed.

    Parameterised by the READER rather than by a list of openings.  The
    chained fold reads per occurrence (`preStateValueAt ops`) and the
    multiproof reads per cell (`bundleValueAt b`); those are different
    lookups over different structures, and the derivation cares about
    neither — it wants a proven pre-value for a cell.  Taking the list
    forced the multiproof caller to fabricate `CellOpening`s carrying
    empty proofs purely to satisfy the type, which is a lie in a
    structure whose whole purpose is to carry a proof. -/
def derivedCellValue (read : CellValueReader) (policyValue : ByteArray)
    (a : Action) (signer : ActorId) (l2LogIndex : Nat)
    (plan : List ((ResourceId × ActorId) × Nat)) (t : CellTag) :
    Option ByteArray :=
  match t with
  | .balance r actor =>
    (plannedBalanceAt plan r actor).map
      (fun v => ByteArray.mk (Encoding.encodeAmount v).toArray)
  | .nonce _ =>
    match read t with
    | none   => none
    | some v => deriveNonceCellValue v
  | .epochBudget target =>
    match read (.epochBudget signer), read t with
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
    match read t with
    | none   => none
    | some v => deriveNextWdIdCellValue v
  -- No adjudicable action writes any other cell kind; a bundle
  -- naming one fails the shape check before reaching here.
  | _ => none

/-! ## Alias consistency

The multiproof reads a balance BY CELL, so a plan naming one cell twice
with different values would be a fork in the derivation.  `plannedBalanceAt?`
refuses that rather than resolving it, and this theorem says the refusal
is unreachable from any action. -/

theorem plannedBalances_alias_consistent (read : BalanceReader) (a : Action)
    (signer : ActorId) (plan : List ((ResourceId × ActorId) × Nat))
    (h : plannedBalances read a signer = some plan) :
    aliasConsistent plan = true := by
  unfold plannedBalances at h
  cases a with
  | transfer r sender receiver amount =>
      exact deriveTransferBalances_alias_consistent read r sender receiver amount plan h
  | mint r to amount => exact deriveCreditBalance_alias_consistent read r to amount plan h
  | reward r to amount => exact deriveCreditBalance_alias_consistent read r to amount plan h
  | burn r from_ amount =>
      exact deriveBurnBalance_alias_consistent read r from_ amount plan h
  | deposit r recipient amount _ =>
      exact deriveDepositBalance_alias_consistent read r recipient amount plan h
  | withdraw r sender amount _ =>
      exact deriveWithdrawBalance_alias_consistent read r sender amount plan h
  | depositWithFee r recipient poolActor userAmount poolAmount _ _ =>
      exact deriveChainPair_alias_consistent read r recipient poolActor _ _ plan h
  | topUpActionBudget gr gasAmount _ pa =>
      exact deriveTopUpBalances_alias_consistent read gr signer pa gasAmount plan h
  | topUpActionBudgetFor recipient gr gasAmount _ pa =>
      exact deriveDelegatedTopUpBalances_alias_consistent read gr signer pa recipient
        gasAmount plan h
  | claimBudgetRefund gr budgetUnits weiPerBudgetUnit pa =>
      exact deriveRefundBalances_alias_consistent read gr pa signer
        (budgetUnits * weiPerBudgetUnit) plan h
  | ammSwap fromResource toResource amountIn amountOut reserveActor =>
      exact deriveAmmSwapBalances_alias_consistent read fromResource toResource
        amountIn amountOut reserveActor plan h
  | reclaimAmmReserves r amount reserveActor poolActor =>
      exact deriveReclaimBalances_alias_consistent read r reserveActor poolActor
        amount plan h
  -- The thirteen variants that write no balance cell at all.
  | _ => simp only [Option.some.injEq] at h; subst h; exact aliasConsistent_nil

/-! ## The multiproof verifier

`verifierPostRoot` above is the CHAINED verifier: one opening per
write, each against the root the previous write produced, and a
first-occurrence rule for reading a cell's pre-value because a later
write's opening is against the running state rather than the
pre-state.

This is the same verifier over a pre-root multiproof, and the
differences are all consequences of that one change:

  * the bundle is a SET of cells, so the shape check normalises its
    order and refuses a duplicate;
  * a cell's pre-value is read BY CELL rather than by first
    occurrence, because there is exactly one opening per cell —
    `preStateValueAt`'s rule has nothing left to disambiguate;
  * the read-only budget-policy cell stops being special.  It joins
    the frontier as a cell written to its own value, so it needs no
    separate walk and no separate verification path.  A read is a
    write of the same value.
-/

/-- A multiproof bundle: the cells it opens with their PRE-state
    values, in any order, and the single sibling list serving both
    roots.

    One sibling list rather than one per opening is the whole
    difference on the wire, and `multiSiblings_congr` is why it is
    sound: every sibling is the root of a sub-tree holding no opened
    cell, so the writes cannot move it. -/
structure MultiBundle where
  /-- The opened cells with their pre-state values, in any order. -/
  cells : List (CellTag × ByteArray)
  /-- The shared wire: a gap mask plus the siblings it marks.
      COMPRESSED, not expanded — a gap whose sibling is the canonical
      empty sub-tree at its level costs a cleared bit rather than 32
      bytes, and at ~10⁶ live cells that is the overwhelming majority
      of the 256 levels.

      Carrying the compressed form rather than the expanded list is
      what makes the verifier's shape check possible at all: the
      expansion needs the gap LEVELS, which come from the key set, so
      `isWellFormedFor` can reject a wire of the wrong length before a
      single sibling is read.  An expanded list has no such length —
      any list is a list — and `expandMultiProof`'s `paddingHash`
      substitution, the exact failure mode the single-cell verifier
      has, becomes unreachable. -/
  proof : SmtMultiProof
  deriving Repr

/-- A cell's proven pre-value, looked up BY CELL.

    The replacement for `preStateValueAt`'s first-occurrence rule.
    Under a multiproof a cell is opened exactly once — the shape check
    refuses a duplicate — so "the first opening naming this cell" and
    "the opening naming this cell" are the same thing, and the rule
    that had to distinguish them is gone. -/
def bundleValueAt (b : MultiBundle) (t : CellTag) : Option ByteArray :=
  (b.cells.find? (fun c => smtCellKey c.1 == smtCellKey t)).map Prod.snd

/-- The balance reader a multiproof bundle induces.  PARTIAL, exactly
    as the chained one is: a derivation reading a cell the bundle does
    not open produces nothing rather than a default, so an omitted
    opening cannot be passed off as a zero balance. -/
def bundleBalanceReader (b : MultiBundle) : BalanceReader :=
  fun r a =>
    match bundleValueAt b (.balance r a) with
    | none   => none
    | some v =>
      match Encoding.decodeAmount v.data.toList with
      | .ok (n, []) => some n
      | _           => none

/-- The proven `.bridgeNextWdId` pre-value, or `0` when unopened. -/
def bundleNextWdId (b : MultiBundle) : Nat :=
  match bundleValueAt b .bridgeNextWdId with
  | none   => 0
  | some v =>
    match Encodable.decode (T := Nat) v.data.toList with
    | .ok (n, []) => n
    | _           => 0

/-- The cells a step's bundle must open: the written ones plus the
    read-only budget policy, deduplicated and in path order.

    The policy cell is IN the frontier rather than beside it.  Under
    the chained fold it needed its own opening and its own walk
    because it is a read among writes; here a read is a write of the
    same value, so it is one more cell. -/
def multiFrontierOf (a : Action) (signer : ActorId) (nextWdIdPre : Nat) :
    List CellTag :=
  frontierOf (.budgetPolicy :: verifierWriteCells a signer nextWdIdPre)

/-- **The multiproof post-state root** — what an L1 holding a pre-root
    and ONE bundle computes.

    `none` on any refusal, and each refusal is a submission failure
    rather than a state-transition outcome: a non-adjudicable action, a
    bundle whose cells are not the ones the step opens (a duplicate, a
    missing cell, an extra cell — order is free), a missing or
    malformed pre-value, a wire of the wrong shape, a wire that does
    not reproduce the submitted pre-root, or a wire the walk cannot
    consume exactly.

    The shape is checked BEFORE the walk and against the KEY SET, not
    against the wire: `multiGapLevels` never looks at an entry, so the
    gap count — and hence the mask size, the padding bits and the
    sibling count — is fixed the moment the frontier is.  That is what
    makes a short wire a refusal here where the single-cell verifier
    silently substitutes a padding hash and keeps walking.

    A failing law precondition is a NO-OP here, not a refusal: the
    derivations evaluate the precondition and return the pre-values
    when it fails, because `step_impl` is
    `if pre then apply_impl else id`. -/
def verifierPostRootMulti (preRoot : StateCommit) (a : Action) (signer : ActorId)
    (l2LogIndex : Nat) (b : MultiBundle) : Option StateCommit :=
  if ¬ FaultProofAdjudicable a then none
  else
    let expected := multiFrontierOf a signer (bundleNextWdId b)
    if ¬ frontierShapeOk (.budgetPolicy :: verifierWriteCells a signer (bundleNextWdId b))
           (b.cells.map Prod.fst) then none
    else
      match bundleValueAt b .budgetPolicy with
      | none => none
      | some policyValue =>
        match plannedBalances (bundleBalanceReader b) a signer with
        | none      => none
        | some plan =>
          -- The PRE side: the leaves the bundle claims, which must
          -- reproduce the submitted pre-root.
          let preOpened : List OpenedLeaf :=
            expected.filterMap (fun t =>
              (bundleValueAt b t).map (fun v => (smtCellKey t, cellLeaf t v)))
          -- The POST side: the same cells, with values DERIVED rather
          -- than submitted.  The policy cell is a read, so it keeps
          -- its value; every other cell takes the step's result.
          let postOpened : List OpenedLeaf :=
            expected.filterMap (fun t =>
              if t = .budgetPolicy then
                (bundleValueAt b t).map (fun v => (smtCellKey t, cellLeaf t v))
              else
                (derivedCellValue (bundleValueAt b) policyValue a signer
                  l2LogIndex plan t).map
                  (fun v => (smtCellKey t, cellLeaf t v)))
          if preOpened.length ≠ expected.length then none
          else if postOpened.length ≠ expected.length then none
          else
            -- The gap levels come from the KEY SET, so the wire's
            -- shape is known before it is read.  Both sides of the
            -- fold share one expansion: the same siblings serve both
            -- roots, which is the whole point of the multiproof.
            let levels := multiGapLevels smtDepth preOpened
            if ¬ b.proof.isWellFormedFor levels then none
            else
              let sibs := expandMultiProof levels b.proof
              match multiWalk smtDepth preOpened sibs with
              | some (r, []) =>
                if r ≠ preRoot then none
                else
                  match multiWalk smtDepth postOpened sibs with
                  | some (r', []) => some r'
                  | _             => none
              | _ => none

/-! ## The honest sequencer's side

`verifierPostRootMulti` is what an L1 computes.  These are what a
defender publishes so it can: the bundle, the wire, and the root the
verifier will reach — each a function of `(pre-state, signed action,
log index)` alone, which is what lets the observer emit them and the
game recompute them.

The multiproof counterparts of `stepWriteBundle` / `stepPostRoot`.  The
chained pair carries one opening per WRITE, each against the running
root; this pair carries one opening per CELL, all against the pre-root,
with the siblings shared. -/

/-- **The multiproof bundle an honest sequencer publishes for a step.**

    Emitted in path order — which is the order the walk consumes, so a
    caller who does not want to sort need not.  The verifier sorts
    anyway: order carries no information here, because every opening is
    against the same root. -/
def stepMultiBundle (es : ExtendedState) (st : SignedAction) : MultiBundle :=
  let ts := multiFrontierOf st.action st.signer es.bridge.nextWdId
  let opened := openedOf es ts
  { cells := ts.map (fun t => (t, getCellValue es t))
  , proof := buildMultiProof (multiGapLevels smtDepth opened)
               (multiSiblings smtDepth (stateCellEntries es) opened) }

/-- **The post-state root the multiproof verifier reaches** for an
    honest step: one merged walk, one root check, one answer.

    The multiproof counterpart of `stepPostRoot`, and `Option` for the
    same reason — the fold is fail-closed, so a bundle whose wire does
    not reproduce the pre-root aborts rather than inventing a root. -/
def stepMultiPostRoot (es : ExtendedState) (st : SignedAction) (idx : Nat) :
    Option StateCommit :=
  verifierPostRootMulti (commitExtendedState es) st.action st.signer idx
    (stepMultiBundle es st)

end FaultProof
end LegalKernel

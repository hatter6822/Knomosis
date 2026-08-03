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

/-- A cell's proven pre-value, looked up BY CELL IDENTITY.

    The replacement for `preStateValueAt`'s first-occurrence rule.
    Under a multiproof a cell is opened exactly once — the shape check
    refuses a duplicate — so "the first opening naming this cell" and
    "the opening naming this cell" are the same thing, and the rule
    that had to distinguish them is gone.

    By TAG rather than by hashed key, which is what
    `KnomosisStepVMRoot._findOpened` does: it compares
    `(cellKind, keyA, keyB)`.  The by-key form the chained era used
    agreed with it on anything past the shape check — that check forces
    the submitted tags to BE the derived frontier — but it made the two
    stacks decide the same question two ways, and it made "the entry
    whose key matches is the entry" a fact about `smtCellKey`'s
    injectivity rather than about a decidable equality on `CellTag`. -/
def bundleValueAt (b : MultiBundle) (t : CellTag) : Option ByteArray :=
  (b.cells.find? (fun c => c.1 == t)).map Prod.snd

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

/-- **The honest bundle reads back what the state holds**, at every
    cell the frontier opens.

    The bridge between `bundleValueAt` — a lookup BY KEY over a
    submitted list — and `getCellValue`, which is what every
    `VerifierWrites` correctness theorem is stated against.  It is not
    a `rfl`: the lookup finds the FIRST entry whose key matches, and
    "first entry with a matching key" is only "this entry" because the
    frontier's keys are distinct.  `frontierOf_keys_nodup` is what
    supplies that, so the `KeysSeparated` side condition is where the
    tree's ability to tell two cells apart enters.

    Composing this with the `*_correct` family is the remaining step
    toward `stepMultiPostRoot = some (commitExtendedState
    (productionApplyBudget …))` — see
    `docs/planning/state_root_merkleisation_plan.md` §6.5 M8. -/
theorem bundleValueAt_stepMultiBundle (es : ExtendedState) (st : SignedAction)
    (t : CellTag)
    (h_mem : t ∈ multiFrontierOf st.action st.signer es.bridge.nextWdId) :
    bundleValueAt (stepMultiBundle es st) t = some (getCellValue es t) := by
  unfold bundleValueAt stepMultiBundle
  simp only []
  generalize multiFrontierOf st.action st.signer es.bridge.nextWdId = ts at h_mem
  induction ts with
  | nil => simp at h_mem
  | cons u rest ih =>
    rw [List.map_cons, List.find?_cons]
    cases h_eq : (u == t) with
    | true =>
      have h_tag : u = t := by simpa using h_eq
      subst h_tag
      simp only []
      rfl
    | false =>
      simp only []
      refine ih ?_
      rcases List.mem_cons.mp h_mem with h' | h'
      · exact absurd h_eq (by simp [h'])
      · exact h'

/-! ## The honest bundle's reader is the state's

`bundleValueAt_stepMultiBundle` says the bundle reads back the state at
every cell the frontier opens.  The derivations do not read cells; they
read a `BalanceReader`, which is a decoded view.  These lemmas cross
that gap, and then lift it from a single cell to a whole plan.

Two hypotheses run through the section and neither is decoration:

  * `KeyInjectiveOn` — the tree can tell the step's cells apart.
    Without it the frontier may collapse two genuinely different cells,
    and a write to the collapsed one becomes invisible to the bundle.
  * `CanonicalBounds` — the state's balances fit the amount head.
    Without it a balance past `2^128` encodes to bytes that decode to
    something else, so the reader would disagree with the state at a
    cell the bundle opened honestly.

Both are the project's standing state-well-formedness obligations, not
new ones.
-/

/-- Every cell the action declares it writes is a cell the frontier
    opens. -/
theorem mem_multiFrontierOf_of_writeCells (es : ExtendedState) (st : SignedAction)
    (h_inj : KeyInjectiveOn (.budgetPolicy ::
      verifierWriteCells st.action st.signer es.bridge.nextWdId))
    (t : CellTag) (h : t ∈ st.action.writeCells st.signer) :
    t ∈ multiFrontierOf st.action st.signer es.bridge.nextWdId :=
  mem_frontierOf_of_mem _ h_inj t
    (List.mem_cons_of_mem _ (List.mem_append_left _ h))

/-- The read-only budget-policy cell is always opened — it leads the
    frontier's source list, which is what makes an empty bundle a
    shape failure rather than a vacuous success. -/
theorem budgetPolicy_mem_multiFrontierOf (es : ExtendedState) (st : SignedAction)
    (h_inj : KeyInjectiveOn (.budgetPolicy ::
      verifierWriteCells st.action st.signer es.bridge.nextWdId)) :
    CellTag.budgetPolicy ∈ multiFrontierOf st.action st.signer es.bridge.nextWdId :=
  mem_frontierOf_of_mem _ h_inj _ List.mem_cons_self

/-- **The honest bundle's balance reader is the state's**, at every
    balance cell the frontier opens.

    The decode is where `CanonicalBounds` enters: `getCellValue` writes
    the balance through the 17-byte amount head, and that round-trips
    only inside `2^128`.  Off the frontier the two readers genuinely
    differ — the bundle's is `none` — which is the partiality the
    derivations rely on, so the membership hypothesis is not
    removable. -/
theorem bundleBalanceReader_stepMultiBundle (es : ExtendedState) (st : SignedAction)
    (h_bounds : ExtendedState.CanonicalBounds es)
    (r : ResourceId) (a : ActorId)
    (h_mem : CellTag.balance r a ∈
      multiFrontierOf st.action st.signer es.bridge.nextWdId) :
    bundleBalanceReader (stepMultiBundle es st) r a = stateBalanceReader es r a := by
  unfold bundleBalanceReader
  rw [bundleValueAt_stepMultiBundle es st _ h_mem]
  show (match Encoding.decodeAmount (getCellValue es (.balance r a)).data.toList with
        | .ok (n, []) => some n
        | _           => none) = stateBalanceReader es r a
  have h_bytes : (getCellValue es (.balance r a)).data.toList
      = Encoding.encodeAmount (LegalKernel.getBalance es.base r a) := by
    show (Encoding.encodeAmount (LegalKernel.getBalance es.base r a)).toArray.toList = _
    simp
  rw [h_bytes,
    Encoding.amount_roundtrip_empty _ (getBalance_lt_of_canonicalBounds es r a h_bounds)]
  rfl

/-- **The honest bundle plans what the state plans.**

    The reader congruence lifted from one cell to a whole step: for
    every action, the cells the derivation reads are cells the action
    declares it writes, hence cells the frontier opens, hence cells
    where the two readers agree.

    Twenty-five branches because the read set is per-variant and naming
    it is the point — a single lemma quantified over "the cells it
    reads" would have to compute that set, and computing it is what
    `Action.writeCells` already does. -/
theorem plannedBalances_stepMultiBundle (es : ExtendedState) (st : SignedAction)
    (h_bounds : ExtendedState.CanonicalBounds es)
    (h_inj : KeyInjectiveOn (.budgetPolicy ::
      verifierWriteCells st.action st.signer es.bridge.nextWdId)) :
    plannedBalances (bundleBalanceReader (stepMultiBundle es st)) st.action st.signer
      = plannedBalances (stateBalanceReader es) st.action st.signer := by
  have key : ∀ (r : ResourceId) (x : ActorId),
      CellTag.balance r x ∈ st.action.writeCells st.signer →
      bundleBalanceReader (stepMultiBundle es st) r x = stateBalanceReader es r x :=
    fun r x hx => bundleBalanceReader_stepMultiBundle es st h_bounds r x
      (mem_multiFrontierOf_of_writeCells es st h_inj _ hx)
  unfold plannedBalances
  cases h_act : st.action with
  | transfer r sender receiver amount =>
      exact deriveTransferBalances_congr _ _ r sender receiver amount
        (key r sender (by rw [h_act]; simp [Action.writeCells]))
        (key r receiver (by rw [h_act]; simp [Action.writeCells]))
  | mint r to amount =>
      exact deriveCreditBalance_congr _ _ r to amount
        (key r to (by rw [h_act]; simp [Action.writeCells]))
  | reward r to amount =>
      exact deriveCreditBalance_congr _ _ r to amount
        (key r to (by rw [h_act]; simp [Action.writeCells]))
  | burn r from_ amount =>
      exact deriveBurnBalance_congr _ _ r from_ amount
        (key r from_ (by rw [h_act]; simp [Action.writeCells]))
  | deposit r recipient amount d =>
      exact deriveDepositBalance_congr _ _ r recipient amount
        (key r recipient (by rw [h_act]; simp [Action.writeCells]))
  | withdraw r sender amount rcp =>
      exact deriveWithdrawBalance_congr _ _ r sender amount
        (key r sender (by rw [h_act]; simp [Action.writeCells]))
  | depositWithFee r recipient poolActor userAmount poolAmount bg d =>
      exact deriveDepositWithFeeBalances_congr _ _ r recipient poolActor
        userAmount poolAmount
        (key r recipient (by rw [h_act]; simp [Action.writeCells]))
        (key r poolActor (by rw [h_act]; simp [Action.writeCells]))
  | topUpActionBudget gr gasAmount bi pa =>
      exact deriveTopUpBalances_congr _ _ gr st.signer pa gasAmount
        (key gr st.signer (by rw [h_act]; simp [Action.writeCells]))
        (key gr pa (by rw [h_act]; simp [Action.writeCells]))
  | topUpActionBudgetFor recipient gr gasAmount bi pa =>
      exact deriveDelegatedTopUpBalances_congr _ _ gr st.signer pa recipient gasAmount
        (key gr st.signer (by rw [h_act]; simp [Action.writeCells]))
        (key gr pa (by rw [h_act]; simp [Action.writeCells]))
  | claimBudgetRefund gr budgetUnits weiPerBudgetUnit pa =>
      exact deriveRefundBalances_congr _ _ gr pa st.signer
        (budgetUnits * weiPerBudgetUnit)
        (key gr pa (by rw [h_act]; simp [Action.writeCells]))
        (key gr st.signer (by rw [h_act]; simp [Action.writeCells]))
  | ammSwap fromResource toResource amountIn amountOut reserveActor =>
      exact deriveAmmSwapBalances_congr _ _ fromResource toResource
        amountIn amountOut reserveActor
        (key fromResource reserveActor (by rw [h_act]; simp [Action.writeCells]))
        (key toResource reserveActor (by rw [h_act]; simp [Action.writeCells]))
  | reclaimAmmReserves r amount reserveActor poolActor =>
      exact deriveReclaimBalances_congr _ _ r reserveActor poolActor amount
        (key r reserveActor (by rw [h_act]; simp [Action.writeCells]))
        (key r poolActor (by rw [h_act]; simp [Action.writeCells]))
  -- The thirteen variants that write no balance cell at all.
  | _ => rfl

/-! ## The derived value is the post-state's

`bundleValueAt_stepMultiBundle` and `plannedBalances_stepMultiBundle`
say the honest bundle presents the state faithfully.  This section is
the other half: what the verifier DERIVES from that presentation is
what the step actually leaves in the cell.

Every ingredient is already proved — `VerifierWrites`' `*_correct`
family covers all fifteen cell kinds across all twenty-five variants.
What is missing is the composition, and the obstacle is not arithmetic
but ADDRESSING: the `*_correct` theorems are stated for a NAMED cell
("`transfer`'s sender balance"), while the verifier holds an arbitrary
tag off the frontier and must discover which one it is.  The inversion
lemmas below are that discovery, and they are what makes the dispatch
finite: a tag on the frontier is a declared write or `withdraw`'s
state-keyed pending entry, and each cell kind pins the action down far
enough to name the theorem that applies.
-/

/-- **What frontier membership says about a cell.**

    Once the read-only policy cell is excluded, a tag the frontier
    opens is either a cell the action DECLARES it writes or
    `withdraw`'s state-keyed pending entry — the one cell whose key is
    a function of the pre-state rather than of the action.

    This is the inversion the whole dispatch below runs on.  Going the
    other way (`mem_multiFrontierOf_of_writeCells`) needs
    `KeyInjectiveOn`; this direction needs nothing, because dropping
    cells is what a frontier is allowed to do and inventing them is
    not. -/
theorem mem_vwc_of_mem_frontier (a : Action) (signer : ActorId) (n : Nat) (t : CellTag)
    (h_mem : t ∈ multiFrontierOf a signer n) (h_ne : t ≠ .budgetPolicy) :
    t ∈ a.writeCells signer ∨
      (t = .bridgePending n ∧ ∃ r s amt rcp, a = .withdraw r s amt rcp) := by
  have h := mem_frontierOf _ t h_mem
  rcases List.mem_cons.mp h with h' | h'
  · exact absurd h' h_ne
  · unfold verifierWriteCells at h'
    rcases List.mem_append.mp h' with h'' | h''
    · exact Or.inl h''
    · cases a <;> simp_all

/-- The only nonce cell any action writes is the signer's — which is
    why `deriveNonceCellValue_correct` can be action-independent. -/
theorem nonce_eq_signer (a : Action) (signer x : ActorId)
    (h : CellTag.nonce x ∈ a.writeCells signer) : x = signer := by
  cases a <;> simp_all [Action.writeCells]

/-- Every action writes the signer's epoch-budget cell, so the
    derivation's second read is always available. -/
theorem epochBudget_signer_mem (a : Action) (signer : ActorId) :
    CellTag.epochBudget signer ∈ a.writeCells signer := by
  cases a <;> simp [Action.writeCells]

/-- A registry cell in the write set names the action's own actor, and
    only the two identity actions write one. -/
theorem registry_cases (a : Action) (signer x : ActorId)
    (h : CellTag.registry x ∈ a.writeCells signer) :
    (∃ k, a = .replaceKey x k) ∨ (∃ pk, a = .registerIdentity x pk) := by
  cases a <;> simp_all [Action.writeCells]

/-- A local-policy cell in the write set is the SIGNER's — an actor
    cannot declare a policy for anyone else — and only the two policy
    actions write one. -/
theorem localPolicy_cases (a : Action) (signer x : ActorId)
    (h : CellTag.localPolicy x ∈ a.writeCells signer) :
    x = signer ∧ ((∃ p, a = .declareLocalPolicy p) ∨ a = .revokeLocalPolicy) := by
  cases a <;> simp_all [Action.writeCells]

/-- A consumed cell in the write set carries the action's own deposit
    id, so the derivation's record is the action's own fields rather
    than a lookup. -/
theorem bridgeConsumed_cases (a : Action) (signer : ActorId) (d : LegalKernel.Bridge.DepositId)
    (h : CellTag.bridgeConsumed d ∈ a.writeCells signer) :
    (∃ r rcp amt, a = .deposit r rcp amt d) ∨
      (∃ r rcp pa ua pam bg, a = .depositWithFee r rcp pa ua pam bg d) := by
  cases a <;> simp_all [Action.writeCells]

/-- The next-withdrawal-id counter is written by `withdraw` alone. -/
theorem bridgeNextWdId_cases (a : Action) (signer : ActorId)
    (h : CellTag.bridgeNextWdId ∈ a.writeCells signer) :
    ∃ r s amt rcp, a = .withdraw r s amt rcp := by
  cases a <;> simp_all [Action.writeCells]

/-- **The plan answers every balance cell the step writes**, with the
    value the step leaves there.

    The balance half of the dispatch, and the one that needs a plan
    rather than a per-cell derivation: five variants write two balance
    cells that are CHAINED, so the pair is planned once from both
    pre-values.  Composing `VerifierWrites`' twelve `*_correct`
    theorems with `plannedBalanceAt?_of_mem` turns that plan back into
    a per-cell answer.

    `plannedBalances_alias_consistent` is what licenses the lookup:
    without it a plan naming one cell twice could disagree with itself
    and `plannedBalanceAt?` would refuse. -/
theorem plannedBalanceAt_correct (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (x : ActorId)
    (h_mem : CellTag.balance r x ∈ st.action.writeCells st.signer)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h_plan : plannedBalances (stateBalanceReader es) st.action st.signer = some plan) :
    plannedBalanceAt plan r x
      = some (LegalKernel.getBalance (productionApplyBudget es st idx).base r x) := by
  have h_cons : aliasConsistent plan = true :=
    plannedBalances_alias_consistent _ _ _ _ h_plan
  unfold plannedBalanceAt
  cases h_act : st.action with
  | transfer r' sender receiver amount =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveTransferBalances_correct es st idx r' sender receiver amount h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      rcases h_mem with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
      · exact plannedBalanceAt?_of_mem _ _ _ _
          (List.mem_cons_of_mem _ List.mem_cons_self) h_cons
  | mint r' to amount =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveCreditBalance_correct_mint es st idx r' to amount h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      obtain ⟨rfl, rfl⟩ := h_mem
      exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
  | reward r' to amount =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveCreditBalance_correct_reward es st idx r' to amount h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      obtain ⟨rfl, rfl⟩ := h_mem
      exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
  | burn r' from_ amount =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveBurnBalance_correct es st idx r' from_ amount h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      obtain ⟨rfl, rfl⟩ := h_mem
      exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
  | deposit r' recipient amount d =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveDepositBalance_correct es st idx r' recipient amount d h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      obtain ⟨rfl, rfl⟩ := h_mem
      exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
  | withdraw r' sender amount rcp =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveWithdrawBalance_correct es st idx r' sender amount rcp h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      obtain ⟨rfl, rfl⟩ := h_mem
      exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
  | depositWithFee r' recipient poolActor userAmount poolAmount bg d =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveDepositWithFeeBalances_correct es st idx r' recipient poolActor
        userAmount poolAmount bg d h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      rcases h_mem with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
      · exact plannedBalanceAt?_of_mem _ _ _ _
          (List.mem_cons_of_mem _ List.mem_cons_self) h_cons
  | topUpActionBudget gr gasAmount bi pa =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveTopUpBalances_correct es st idx gr gasAmount bi pa h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      rcases h_mem with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
      · exact plannedBalanceAt?_of_mem _ _ _ _
          (List.mem_cons_of_mem _ List.mem_cons_self) h_cons
  | topUpActionBudgetFor recipient gr gasAmount bi pa =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveDelegatedTopUpBalances_correct es st idx recipient gr gasAmount
        bi pa h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      rcases h_mem with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
      · exact plannedBalanceAt?_of_mem _ _ _ _
          (List.mem_cons_of_mem _ List.mem_cons_self) h_cons
  | claimBudgetRefund gr budgetUnits weiPerBudgetUnit pa =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveRefundBalances_correct es st idx gr budgetUnits weiPerBudgetUnit
        pa h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      -- The plan runs POOL first while the write set leads with the
      -- claimant, so the two positions are swapped here.
      rcases h_mem with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · exact plannedBalanceAt?_of_mem _ _ _ _
          (List.mem_cons_of_mem _ List.mem_cons_self) h_cons
      · exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
  | ammSwap fromResource toResource amountIn amountOut reserveActor =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveAmmSwapBalances_correct es st idx fromResource toResource
        amountIn amountOut reserveActor h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      rcases h_mem with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
      · exact plannedBalanceAt?_of_mem _ _ _ _
          (List.mem_cons_of_mem _ List.mem_cons_self) h_cons
  | reclaimAmmReserves r' amount reserveActor poolActor =>
      rw [h_act] at h_plan h_mem
      dsimp only [plannedBalances] at h_plan
      rw [deriveReclaimBalances_correct es st idx r' amount reserveActor
        poolActor h_act] at h_plan
      simp only [Option.some.injEq] at h_plan; subst h_plan
      simp only [Action.writeCells, List.mem_cons, List.not_mem_nil, or_false,
        CellTag.balance.injEq, reduceCtorEq] at h_mem
      rcases h_mem with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · exact plannedBalanceAt?_of_mem _ _ _ _ List.mem_cons_self h_cons
      · exact plannedBalanceAt?_of_mem _ _ _ _
          (List.mem_cons_of_mem _ List.mem_cons_self) h_cons
  -- The thirteen variants that write no balance cell at all: the
  -- membership hypothesis is false.
  | _ => rw [h_act] at h_mem; simp [Action.writeCells] at h_mem

/-- **The verifier's derived value is the post-state's value**, at
    every cell a step's frontier opens.

    §4 step 3's statement for the whole cell space: what an L1 computes
    from PROVEN pre-values and the action's own fields is byte-for-byte
    what `productionApplyBudget` leaves in the cell — with no access to
    the post-state anywhere in the derivation.

    The budget-policy cell is excluded because it is a READ: the
    verifier keeps its value rather than deriving one, which is what
    lets a read join the frontier as a write of the same value.

    Two hypotheses carry the state's well-formedness.
    `CanonicalBounds` supplies every CBE width bound the decoders need
    (and the policy's anti-spam floor, which is not a width bound and
    is not decoration — a zero-cost policy is one no deployment can
    hold).  `KeyInjectiveOn` is needed for exactly one step: reading
    the SIGNER's epoch-budget cell when the tag names someone else's,
    which requires knowing the signer's is on the frontier too. -/
theorem derivedCellValue_correct (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (h_bounds : ExtendedState.CanonicalBounds es)
    (h_inj : KeyInjectiveOn (.budgetPolicy ::
      verifierWriteCells st.action st.signer es.bridge.nextWdId))
    (t : CellTag)
    (h_mem : t ∈ multiFrontierOf st.action st.signer es.bridge.nextWdId)
    (h_ne : t ≠ .budgetPolicy)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h_plan : plannedBalances (stateBalanceReader es) st.action st.signer = some plan) :
    derivedCellValue (bundleValueAt (stepMultiBundle es st))
        (getCellValue es .budgetPolicy) st.action st.signer idx plan t
      = some (getCellValue (productionApplyBudget es st idx) t) := by
  cases t with
  | balance r x =>
      rcases mem_vwc_of_mem_frontier _ _ _ _ h_mem h_ne with h | ⟨h_eq, _⟩
      · show (plannedBalanceAt plan r x).map
              (fun v => ByteArray.mk (Encoding.encodeAmount v).toArray) = _
        rw [plannedBalanceAt_correct es st idx r x h plan h_plan]
        rfl
      · exact absurd h_eq (by simp)
  | nonce x =>
      rcases mem_vwc_of_mem_frontier _ _ _ _ h_mem h_ne with h | ⟨h_eq, _⟩
      · have hx : x = st.signer := nonce_eq_signer _ _ _ h
        subst hx
        show (match bundleValueAt (stepMultiBundle es st) (.nonce st.signer) with
              | none   => none
              | some v => deriveNonceCellValue v) = _
        rw [bundleValueAt_stepMultiBundle es st _ h_mem]
        exact deriveNonceCellValue_correct es st idx
          (expectsNonce_lt_of_canonicalBounds es st.signer h_bounds)
      · exact absurd h_eq (by simp)
  | epochBudget target =>
      show (match bundleValueAt (stepMultiBundle es st) (.epochBudget st.signer),
                  bundleValueAt (stepMultiBundle es st) (.epochBudget target) with
            | some signerValue, some targetValue =>
              deriveEpochBudgetCellValue (getCellValue es .budgetPolicy)
                signerValue targetValue st.action st.signer target
            | _, _ => none) = _
      rw [bundleValueAt_stepMultiBundle es st (.epochBudget st.signer)
            (mem_multiFrontierOf_of_writeCells es st h_inj _
              (epochBudget_signer_mem _ _)),
          bundleValueAt_stepMultiBundle es st (.epochBudget target) h_mem]
      cases h_pol : es.budgetPolicy with
      | bounded ft ac ce =>
        obtain ⟨h_ft, h_ac, h_ce⟩ :=
          budgetPolicy_bounded_of_canonicalBounds es ft ac ce h_pol h_bounds
        have h_pos : 1 ≤ ac := (h_bounds.bp_val ft ac ce h_pol).2.2.2
        obtain ⟨h_se, h_sb⟩ := actorBudget_bounded_of_canonicalBounds es st.signer h_bounds
        obtain ⟨h_te, h_tb⟩ := actorBudget_bounded_of_canonicalBounds es target h_bounds
        exact deriveEpochBudgetCellValue_correct es st idx target ft ac ce h_pol
          h_ft h_ac h_ce h_pos h_se h_sb h_te h_tb
  | registry x =>
      rcases mem_vwc_of_mem_frontier _ _ _ _ h_mem h_ne with h | ⟨h_eq, _⟩
      · rcases registry_cases _ _ _ h with ⟨k, h_act⟩ | ⟨pk, h_act⟩
        · show (match st.action with
                | .replaceKey _ key      => some (deriveRegistryCellValue key)
                | .registerIdentity _ p  => some (deriveRegistryCellValue p)
                | _                      => none) = _
          rw [h_act]
          exact congrArg some
            (deriveRegistryCellValue_correct_replaceKey es st idx x k h_act)
        · show (match st.action with
                | .replaceKey _ key      => some (deriveRegistryCellValue key)
                | .registerIdentity _ p  => some (deriveRegistryCellValue p)
                | _                      => none) = _
          rw [h_act]
          exact congrArg some
            (deriveRegistryCellValue_correct_registerIdentity es st idx x pk h_act)
      · exact absurd h_eq (by simp)
  | localPolicy x =>
      rcases mem_vwc_of_mem_frontier _ _ _ _ h_mem h_ne with h | ⟨h_eq, _⟩
      · obtain ⟨hx, hcase⟩ := localPolicy_cases _ _ _ h
        subst hx
        rcases hcase with ⟨p, h_act⟩ | h_act
        · show (match st.action with
                | .declareLocalPolicy q => some (deriveDeclaredPolicyCellValue q)
                | .revokeLocalPolicy    => some deriveRevokedPolicyCellValue
                | _                     => none) = _
          rw [h_act]
          exact congrArg some (deriveDeclaredPolicyCellValue_correct es st idx p h_act)
        · show (match st.action with
                | .declareLocalPolicy q => some (deriveDeclaredPolicyCellValue q)
                | .revokeLocalPolicy    => some deriveRevokedPolicyCellValue
                | _                     => none) = _
          rw [h_act]
          exact congrArg some (deriveRevokedPolicyCellValue_correct es st idx h_act)
      · exact absurd h_eq (by simp)
  | bridgeConsumed d =>
      rcases mem_vwc_of_mem_frontier _ _ _ _ h_mem h_ne with h | ⟨h_eq, _⟩
      · rcases bridgeConsumed_cases _ _ _ h with ⟨r, rcp, amt, h_act⟩ |
          ⟨r, rcp, pa, ua, pam, bg, h_act⟩
        · show (match st.action with
                | .deposit r' _ amount _ =>
                  some (deriveConsumedCellValue
                    { resource := r', userAmount := amount
                    , poolAmount := 0, budgetGrant := 0 })
                | .depositWithFee r' _ _ ua' pa' bg' _ =>
                  some (deriveConsumedCellValue
                    { resource := r', userAmount := ua'
                    , poolAmount := pa', budgetGrant := bg' })
                | _ => none) = _
          rw [h_act]
          exact congrArg some
            (deriveConsumedCellValue_correct_deposit es st idx r rcp amt d h_act)
        · show (match st.action with
                | .deposit r' _ amount _ =>
                  some (deriveConsumedCellValue
                    { resource := r', userAmount := amount
                    , poolAmount := 0, budgetGrant := 0 })
                | .depositWithFee r' _ _ ua' pa' bg' _ =>
                  some (deriveConsumedCellValue
                    { resource := r', userAmount := ua'
                    , poolAmount := pa', budgetGrant := bg' })
                | _ => none) = _
          rw [h_act]
          exact congrArg some
            (deriveConsumedCellValue_correct_depositWithFee es st idx r rcp pa ua pam
              bg d h_act)
      · exact absurd h_eq (by simp)
  | bridgePending w =>
      rcases mem_vwc_of_mem_frontier _ _ _ _ h_mem h_ne with h | ⟨h_eq, r, s, amt, rcp, h_act⟩
      · exact absurd h (by cases st.action <;> simp [Action.writeCells])
      · injection h_eq with hw
        subst hw
        show (match st.action with
              | .withdraw r' _ amount rcp' =>
                some (derivePendingCellValue
                  { resource := r', recipient := rcp', amount := amount
                  , l2LogIndex := idx })
              | _ => none) = _
        rw [h_act]
        exact congrArg some (derivePendingCellValue_correct es st idx r s amt rcp h_act)
  | bridgeNextWdId =>
      rcases mem_vwc_of_mem_frontier _ _ _ _ h_mem h_ne with h | ⟨h_eq, _⟩
      · obtain ⟨r, s, amt, rcp, h_act⟩ := bridgeNextWdId_cases _ _ h
        show (match bundleValueAt (stepMultiBundle es st) .bridgeNextWdId with
              | none   => none
              | some v => deriveNextWdIdCellValue v) = _
        rw [bundleValueAt_stepMultiBundle es st _ h_mem]
        exact deriveNextWdIdCellValue_correct es st idx r s amt rcp h_act h_bounds.bs_nxt
      · exact absurd h_eq (by simp)
  | budgetPolicy => exact absurd rfl h_ne
  | _ =>
      rcases mem_vwc_of_mem_frontier _ _ _ _ h_mem h_ne with h | ⟨h_eq, _⟩
      · exact absurd h (by cases st.action <;> simp [Action.writeCells])
      · exact absurd h_eq (by simp)

/-! ## The honest fold lands on the published root

The composition M8 left open, assembled.  Three ingredients, all now
in hand: the frontier is sorted and key-distinct (`Frontier`), the
honest bundle reads back the state and plans what the state plans
(above), and the derivation reaches the post-state at every cell
(`derivedCellValue_correct`).  What remains is to feed them to
`multiFold_eq_commit_post` and discharge its side conditions.
-/

/-- **A state always yields a plan.**  `stateBalanceReader` is total,
    and the derivations refuse only on a missing read, so an honest
    sequencer's plan exists for every action.

    Worth stating because `verifierPostRootMulti` refuses on `none`
    and that refusal must be unreachable for an honest step — an
    adjudication that could not run would let a correct defender lose
    by default. -/
theorem plannedBalances_stateBalanceReader_isSome (es : ExtendedState)
    (a : Action) (signer : ActorId) :
    ∃ plan, plannedBalances (stateBalanceReader es) a signer = some plan := by
  cases a <;>
    simp [plannedBalances, stateBalanceReader, deriveTransferBalances,
      deriveCreditBalance, deriveBurnBalance, deriveDepositBalance,
      deriveWithdrawBalance, deriveDepositWithFeeBalances, deriveChainPair,
      deriveTopUpBalances, deriveDelegatedTopUpBalances, deriveRefundBalances,
      deriveAmmSwapBalances, deriveReclaimBalances] <;>
    (repeat' split) <;> simp_all

/-- **The verifier's post-side leaves are the post-state's own.**

    `derivedCellValue_correct` lifted from one cell to the whole
    frontier, in exactly the shape `verifierPostRootMulti` builds:
    the `filterMap` never drops (so the length check passes) and each
    surviving leaf is the leaf the post-state gives that cell.

    The policy cell takes the other branch and needs its own
    argument — it is a READ, so the verifier keeps the submitted
    pre-value rather than deriving one, and that is correct precisely
    because no action writes it
    (`productionApplyBudget_budgetPolicy`). -/
theorem postOpened_eq_openedOf (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (h_bounds : ExtendedState.CanonicalBounds es)
    (h_inj : KeyInjectiveOn (.budgetPolicy ::
      verifierWriteCells st.action st.signer es.bridge.nextWdId))
    (plan : List ((ResourceId × ActorId) × Nat))
    (h_plan : plannedBalances (stateBalanceReader es) st.action st.signer = some plan) :
    (multiFrontierOf st.action st.signer es.bridge.nextWdId).filterMap (fun t =>
        if t = .budgetPolicy then
          (bundleValueAt (stepMultiBundle es st) t).map
            (fun v => (smtCellKey t, cellLeaf t v))
        else
          (derivedCellValue (bundleValueAt (stepMultiBundle es st))
            (getCellValue es .budgetPolicy) st.action st.signer idx plan t).map
            (fun v => (smtCellKey t, cellLeaf t v)))
      = openedOf (productionApplyBudget es st idx)
          (multiFrontierOf st.action st.signer es.bridge.nextWdId) := by
  have h_each : ∀ t ∈ multiFrontierOf st.action st.signer es.bridge.nextWdId,
      (if t = .budgetPolicy then
          (bundleValueAt (stepMultiBundle es st) t).map
            (fun v => (smtCellKey t, cellLeaf t v))
        else
          (derivedCellValue (bundleValueAt (stepMultiBundle es st))
            (getCellValue es .budgetPolicy) st.action st.signer idx plan t).map
            (fun v => (smtCellKey t, cellLeaf t v)))
      = some (smtCellKey t,
          cellLeaf t (getCellValue (productionApplyBudget es st idx) t)) := by
    intro t ht
    by_cases h_bp : t = .budgetPolicy
    · subst h_bp
      rw [if_pos rfl, bundleValueAt_stepMultiBundle es st _ ht]
      -- The policy cell is a READ: no action writes it, so the
      -- pre-value IS the post-value.
      show some (smtCellKey CellTag.budgetPolicy,
        cellLeaf CellTag.budgetPolicy (getCellValue es .budgetPolicy)) = _
      rw [show getCellValue es CellTag.budgetPolicy
            = getCellValue (productionApplyBudget es st idx) CellTag.budgetPolicy from by
          simp [getCellValue, productionApplyBudget_budgetPolicy es st idx]]
    · rw [if_neg h_bp,
        derivedCellValue_correct es st idx h_bounds h_inj t ht h_bp plan h_plan]
      rfl
  unfold openedOf
  generalize multiFrontierOf st.action st.signer es.bridge.nextWdId = ts at h_each ⊢
  induction ts with
  | nil => rfl
  | cons u rest ih =>
    rw [List.filterMap_cons, List.map_cons,
      h_each u List.mem_cons_self,
      ih (fun t ht => h_each t (List.mem_cons_of_mem _ ht))]

/-- **The honest merged fold lands on the published post-root.**

    The multiproof counterpart of
    `stepPostRoot_eq_commit_productionApplyBudget`, and the statement
    the chained write algebra was kept alive for: hand a verifier the
    pre-state's wire and the post-state's leaves, and the single
    merged walk computes `commitExtendedState` of the state the step
    produces — m cells at once, order-free, with the pre-root checked
    once in aggregate.

    Every hypothesis is discharged elsewhere rather than assumed here.
    `WriteSetComplete` is proved per variant in `StepWriteSets`;
    `BitsDistinctBelow` on the entries comes from
    `stateCellEntries_bitsDistinct`; `KeyInjectiveOn` and `h_key` come
    from `CollisionFreeOn` over the step's own pre-images
    (`keyInjectiveOn_of_collisionFree`).  What this theorem adds is
    that they SUFFICE.

    Non-emptiness is not an extra assumption: the frontier always
    leads with the budget-policy cell, so `frontierOf_cons_ne_nil`
    supplies it. -/
theorem stepMultiFold_eq_commit_post (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (h_adj : FaultProofAdjudicable st.action = true)
    (h_inj : KeyInjectiveOn (.budgetPolicy ::
      verifierWriteCells st.action st.signer es.bridge.nextWdId))
    (h_complete : WriteSetComplete es (productionApplyBudget es st idx)
      st.action st.signer)
    (h_bd : BitsDistinctBelow smtDepth (stateCellEntries es))
    (h_bd' : BitsDistinctBelow smtDepth
      (stateCellEntries (productionApplyBudget es st idx)))
    (h_key : ∀ t ∈ multiFrontierOf st.action st.signer es.bridge.nextWdId,
      ∀ u ∈ stateCellTags (productionApplyBudget es st idx),
      smtCellKey u = smtCellKey t → u = t) :
    multiWalk smtDepth
        (openedOf (productionApplyBudget es st idx)
          (multiFrontierOf st.action st.signer es.bridge.nextWdId))
        (multiSiblings smtDepth (stateCellEntries es)
          (openedOf es (multiFrontierOf st.action st.signer es.bridge.nextWdId)))
      = some (commitExtendedState (productionApplyBudget es st idx), []) := by
  -- The step moves no cell the frontier does not open: `WriteSetComplete`
  -- gives that away from the declared write set, and the frontier
  -- contains the declared write set.
  have h_agree : ∀ t : CellTag,
      t ∉ multiFrontierOf st.action st.signer es.bridge.nextWdId →
      getCellValue (productionApplyBudget es st idx) t = getCellValue es t := by
    intro t ht
    refine h_complete t (fun h_w => ht ?_)
    refine mem_frontierOf_of_mem _ h_inj t (List.mem_cons_of_mem _ ?_)
    rw [verifierWriteCells_eq_writeCellsAt es st.action st.signer h_adj]
    exact h_w
  refine multiFold_eq_commit_post es (productionApplyBudget es st idx) _ ?_
    (agreeOffOpened_openedOf es _ _ h_agree) h_bd h_bd'
    (leavesCoherent_openedOf _ _ h_bd' h_key)
    (bitsDistinctBelow_openedOf _ _ (frontierOf_keys_nodup _))
  -- The frontier is never empty: it always opens the policy cell.
  intro h_nil
  have h_empty : multiFrontierOf st.action st.signer es.bridge.nextWdId = [] := by
    have h_keys := congrArg (List.map Prod.fst) h_nil
    rw [openedOf_keys_eq] at h_keys
    simpa using h_keys
  exact frontierOf_cons_ne_nil _ _ h_empty

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

-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Settlement — value-level tests for the
composite trust-model upgrade theorem (Workstream H §12.4.4 /
WU H.4.4c).

Exercises every settlement branch:
  * The step VM reproduces the COMMITTED endpoint → the responder
    wins (both turn parities).
  * It does not → the responder loses (both turn parities).
  * The submitted pre-state is not `range.low.commit` → the
    responder loses.
  * A bisection round is still open → the transition is refused.

Plus the composite theorem and the trace-bridge lemma.  Tests are
value-level: actually run `applyTransition`, build minimal
KernelSteps, and observe the resulting `gs'.status`.

Note the shape change.  These cases used to hand `applyTransition`
a `claimedPostCommit` and check it against the step's own
`postStateCommit`; both came from the caller, so every case passed
for the caller's chosen reason.  The settlement now compares the
step VM's computed output against `range.high.commit`, so the
fixtures below build the games around the COMPUTED value.
-/

import LegalKernel.FaultProof.Settlement
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Settlement

/-- A second non-zero commit, distinct from `oneCommit`. -/
private def twoCommit : StateCommit :=
  ByteArray.mk #[2, 2, 2, 2, 2, 2, 2, 2,
                 2, 2, 2, 2, 2, 2, 2, 2,
                 2, 2, 2, 2, 2, 2, 2, 2,
                 2, 2, 2, 2, 2, 2, 2, 2]

/-- A third non-zero commit. -/
private def threeCommit : StateCommit :=
  ByteArray.mk #[3, 3, 3, 3, 3, 3, 3, 3,
                 3, 3, 3, 3, 3, 3, 3, 3,
                 3, 3, 3, 3, 3, 3, 3, 3,
                 3, 3, 3, 3, 3, 3, 3, 3]

/-- A populated state, and the real single step from it.

    The fixtures used to be abstract 32-byte constants with an EMPTY
    opening bundle, which the old `kernelStepApply` accepted
    vacuously.  The verifier re-derives the cell list and verifies
    every opening against the running root, so a step has to be a REAL
    one over a REAL state to apply at all — and `low` has to be that
    state's published root.  That is a strengthening: the tests below
    now settle on a step whose post-root anyone can reproduce. -/
private def settlementBase : ExtendedState :=
  let st : LegalKernel.State :=
    { balances := (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
                    (((∅ : BalanceMap).insert 7 100).insert 8 40) }
  { base          := st
  , nonces        := { next := (∅ : Std.TreeMap ActorId Nonce compare).insert 7 3 }
  , registry      := (∅ : KeyRegistry).insert 7 (ByteArray.mk #[1, 2, 3])
  , bridge        := LegalKernel.Bridge.BridgeState.empty
  , epochBudgets  := (∅ : EpochBudgetState).insert 7
                       { lastSeenEpoch := 2, budgetBalance := 50 }
  , budgetPolicy  := .bounded 100 1 2 }

/-- The published root of `settlementBase` — the agreed `low`. -/
private def oneCommit : StateCommit := commitExtendedState settlementBase

/-- A single-step disputed range with low and high commits
    distinct.  `low` is the real pre-root, `high = twoCommit`. -/
private def singleStepRange : DisputedRange :=
  { low  := { idx := 0, commit := oneCommit },
    high := { idx := 1, commit := twoCommit } }

/-- The fixed 65-byte signature the batch leaf binds (Workstream SB
    ruling R7; the terminate arm's width gate requires exactly the
    secp256k1 wire width). -/
private def testSig : ByteArray :=
  ByteArray.mk (Array.replicate 65 (0x42 : UInt8))

/-- The action the real step applies. -/
private def trivialSignedAction : SignedAction :=
  { action := .transfer 1 7 8 30
  , signer := 7
  , nonce  := 3
  , sig    := testSig }

/-- The disputed batch: ONE entry, the fixture's signed action at
    absolute log index 0 — which is the range's `low.idx`, exactly
    where the terminate arm authenticates. -/
private def settlementLogEntry : Runtime.LogEntry :=
  { prevHash      := Runtime.zeroHash
  , signedAction  := trivialSignedAction
  , postStateHash := Runtime.zeroHash }

/-- The anchored actions root the games below carry. -/
private def settlementActionsRoot : ByteArray :=
  actionsRoot 0 [settlementLogEntry]

/-- The inclusion proof for the batch's single action. -/
private def settlementActionProof : SmtCellProof :=
  buildActionProof 0 [settlementLogEntry] 0

/-- A game state with the challenger's turn at a single-step
    range. -/
private def challengerRespondingGame : GameState :=
  { sequencer       := 1
  , challenger      := 2
  , range           := singleStepRange
  , pendingMidpoint := none
  , depth           := 1
  , turn            := .challenger
  , sequencerBond   := 1_000
  , challengerBond  := 50
  , status          := .inProgress
  , deploymentId    := ByteArray.empty
  , actionsRoot     := settlementActionsRoot }

/-- A game state with the sequencer's turn at a single-step
    range. -/
private def sequencerRespondingGame : GameState :=
  { sequencer       := 1
  , challenger      := 2
  , range           := singleStepRange
  , pendingMidpoint := none
  , depth           := 1
  , turn            := .sequencer
  , sequencerBond   := 1_000
  , challengerBond  := 50
  , status          := .inProgress
  , deploymentId    := ByteArray.empty
  , actionsRoot     := settlementActionsRoot }

/-- The canonical step from `settlementBase`, with the claim and the
    declared pre-commit left free.

    `postStateCommit` is a claim the settlement no longer reads; it is
    kept only because `KernelStep` has the field, and one of the tests
    below exists to show that varying it changes nothing.  Varying
    `preStateCommit` DOES matter — the transition refuses a step whose
    declared pre-commit is not the range's `low`. -/
private def stepClaiming (preCommit postCommit : StateCommit) : KernelStep :=
  { buildKernelStep settlementBase trivialSignedAction 1 with
      preStateCommit  := preCommit
    , postStateCommit := postCommit }

/-- What the step VM actually computes from the agreed pre-root.  This
    is the value the settlement compares against `range.high.commit`,
    so the fixtures below are built around it rather than around a
    caller-supplied claim.

    It is `some`, and it is the published root of the production
    advance — which is the whole point of the flip.  A bundle the
    responder controls no longer sets it. -/
private def computedFor (_preCommit : StateCommit) : StateCommit :=
  commitExtendedState (productionApplyBudget settlementBase trivialSignedAction 1)

/-- A single-step game whose committed endpoint IS what the step VM
    computes, so the responder's position is upheld. -/
private def matchingGame (turn : TurnSide) : GameState :=
  { challengerRespondingGame with
      range := { low  := { idx := 0, commit := oneCommit },
                 high := { idx := 1, commit := computedFor oneCommit } },
      turn  := turn }

/-- A single-step game whose committed endpoint is NOT what the step
    VM computes — the fabricated-state-root case. -/
private def mismatchGame (turn : TurnSide) : GameState :=
  { challengerRespondingGame with turn := turn }

/-- Tests for the composite trust-model theorem at value level. -/
def tests : List TestCase :=
  [ -- ===== Predicate sanity =====
    { name := "settlementDisagreement holds when high ≠ truth"
    , body := do
        let truth : LogIndex → StateCommit := fun _ => oneCommit
        let isDis :=
          decide (settlementDisagreement truth challengerRespondingGame)
        -- high.commit = twoCommit, truth(1) = oneCommit; the
        -- inequality holds, so `decide` of the predicate is `true`.
        assert isDis "decide returns true on genuine disagreement"
    }
  , { name := "settlementDisagreement false when high = truth"
    , body := do
        let truth : LogIndex → StateCommit := fun _ => twoCommit
        let isDis :=
          decide (settlementDisagreement truth challengerRespondingGame)
        -- high.commit = twoCommit = truth(1); no disagreement.
        assert (¬ isDis) "decide returns false when high = truth"
    }
  , -- ===== The responder wins iff the step VM reproduces `high` =====
    { name := "sequencer responder, step reproduces high → sequencerWon"
    , body := do
        let step := stepClaiming oneCommit twoCommit
        match applyTransition (matchingGame .sequencer)
                (.terminateOnSingleStep step settlementActionProof) with
        | .ok gs' =>
          assertEq (expected := GameStatus.sequencerWon) (actual := gs'.status)
            "an honest sequencer defending a true endpoint wins"
        | .error e => assert false s!"transition should succeed; got {repr e}"
    }
  , { name := "challenger responder, step reproduces high → challengerWon"
    , body := do
        let step := stepClaiming oneCommit twoCommit
        match applyTransition (matchingGame .challenger)
                (.terminateOnSingleStep step settlementActionProof) with
        | .ok gs' =>
          assertEq (expected := GameStatus.challengerWon) (actual := gs'.status)
            "the win follows the turn, not the party"
        | .error e => assert false s!"transition should succeed; got {repr e}"
    }
  , -- ===== The load-bearing branch: a fabricated endpoint loses =====
    { name := "sequencer responder, step differs from high → challengerWon"
    , body := do
        -- `mismatchGame`'s endpoint is `twoCommit`, which is not what
        -- the step VM computes, so the sequencer cannot defend it —
        -- no adjudicator participates.
        let step := stepClaiming oneCommit twoCommit
        match applyTransition (mismatchGame .sequencer)
                (.terminateOnSingleStep step settlementActionProof) with
        | .ok gs' =>
          assertEq (expected := GameStatus.challengerWon) (actual := gs'.status)
            "a fabricated endpoint cannot be defended"
        | .error e => assert false s!"transition should succeed; got {repr e}"
    }
  , { name := "challenger responder, step differs from high → sequencerWon"
    , body := do
        -- Symmetric: the settlement is turn-based, not party-based.
        let step := stepClaiming oneCommit twoCommit
        match applyTransition (mismatchGame .challenger)
                (.terminateOnSingleStep step settlementActionProof) with
        | .ok gs' =>
          assertEq (expected := GameStatus.sequencerWon) (actual := gs'.status)
            "the determinism is symmetric across turn parities"
        | .error e => assert false s!"transition should succeed; got {repr e}"
    }
  , -- ===== The claim the responder used to control is now inert =====
    { name := "step.postStateCommit does not affect the outcome"
    , body := do
        -- The regression for the vacuity.  Under the old
        -- `kernelStepApply` the responder set `postStateCommit` and
        -- the settlement compared it against itself, so this pair of
        -- steps would have settled DIFFERENTLY.  Now the field is
        -- never read and both must settle identically.
        let stepA := stepClaiming oneCommit twoCommit
        let stepB := stepClaiming oneCommit (computedFor oneCommit)
        match applyTransition (mismatchGame .sequencer) (.terminateOnSingleStep stepA settlementActionProof),
              applyTransition (mismatchGame .sequencer) (.terminateOnSingleStep stepB settlementActionProof) with
        | .ok a, .ok b =>
          assertEq (expected := a.status) (actual := b.status)
            "the responder's own claim must not move the settlement"
          assertEq (expected := GameStatus.challengerWon) (actual := a.status)
            "and both lose, because neither reproduces the endpoint"
        | _, _ => assert false "both transitions should succeed"
    }
  , -- ===== The pre-state is the committed one, not the caller's =====
    { name := "wrong pre-state → responder loses"
    , body := do
        -- Re-executing from a pre-state of the responder's choosing
        -- would let them manufacture any post-commit; the transition
        -- refuses it.  `twoCommit ≠ range.low.commit = oneCommit`.
        let step := stepClaiming twoCommit (computedFor twoCommit)
        match applyTransition (matchingGame .sequencer)
                (.terminateOnSingleStep step settlementActionProof) with
        | .ok gs' =>
          assertEq (expected := GameStatus.challengerWon) (actual := gs'.status)
            "a step from an uncommitted pre-state loses"
        | .error e => assert false s!"transition should succeed; got {repr e}"
    }
  , -- ===== Terminating mid-bisection is refused =====
    { name := "pending midpoint → terminationDuringBisection"
    , body := do
        -- Mirrors the contract's `MidpointAlreadyPending`.  This
        -- error variant existed but was unreachable.
        let g := { matchingGame .sequencer with
                     pendingMidpoint := some { idx := 1, commit := oneCommit } }
        let step := stepClaiming oneCommit twoCommit
        match applyTransition g (.terminateOnSingleStep step settlementActionProof) with
        | .ok _ => assert false "should refuse to terminate mid-bisection"
        | .error e =>
          assertEq (expected := GameError.terminationDuringBisection) (actual := e)
            "got the expected error variant"
    }
  , -- ===== The anchor: a substituted action cannot settle =====
    { name := "substituted action → actionNotInBatch"
    , body := do
        -- The audit-22 attack, refused at the model level: the batch
        -- committed `transfer 1 7 8 30`; a responder executing ANY
        -- other action — here the same shape with a different amount,
        -- so its leaf differs — cannot even reach the fold.  On L1
        -- this is the `ActionNotInBatch` revert.
        let substituted : SignedAction :=
          { trivialSignedAction with action := .transfer 1 7 8 29 }
        let step :=
          { buildKernelStep settlementBase substituted 1 with
              preStateCommit := oneCommit }
        match applyTransition (matchingGame .sequencer)
                (.terminateOnSingleStep step settlementActionProof) with
        | .ok _ => assert false "a substituted action must not settle"
        | .error e =>
          assertEq (expected := GameError.actionNotInBatch) (actual := e)
            "the substituted action is refused by the anchor"
    }
  , { name := "committed action under a different signature → actionNotInBatch"
    , body := do
        -- The leaf binds the SIGNATURE (ruling R7): the right action
        -- under different sig bytes has a different leaf, so it does
        -- not open in the batch either.
        let resigned : SignedAction :=
          { trivialSignedAction with
              sig := ByteArray.mk (Array.replicate 65 (0x43 : UInt8)) }
        let step :=
          { buildKernelStep settlementBase resigned 1 with
              preStateCommit := oneCommit }
        match applyTransition (matchingGame .sequencer)
                (.terminateOnSingleStep step settlementActionProof) with
        | .ok _ => assert false "a re-signed action must not settle"
        | .error e =>
          assertEq (expected := GameError.actionNotInBatch) (actual := e)
            "the signature is bound, not decorative"
    }
  , { name := "non-65-byte signature → actionNotInBatch"
    , body := do
        -- The width gate mirrors `ActionSigWrongLength`; it is what
        -- keeps `actionLeafPreimage`'s split unambiguous.
        let shortSig : SignedAction :=
          { trivialSignedAction with
              sig := ByteArray.mk (Array.replicate 64 (0x42 : UInt8)) }
        let step :=
          { buildKernelStep settlementBase shortSig 1 with
              preStateCommit := oneCommit }
        match applyTransition (matchingGame .sequencer)
                (.terminateOnSingleStep step settlementActionProof) with
        | .ok _ => assert false "a mis-width signature must not settle"
        | .error e =>
          assertEq (expected := GameError.actionNotInBatch) (actual := e)
            "the 65-byte width is enforced"
    }
  , { name := "authenticated step at the wrong log index → responder loses"
    , body := do
        -- `l2LogIndex` is the L1's `g.high.idx`, supplied by the game
        -- there and pinned here: an authenticated action executed at a
        -- log index of the responder's choosing (which `withdraw`'s
        -- state-keyed pending cell reads) is a loss, same as a
        -- fabricated pre-state.
        let step :=
          { buildKernelStep settlementBase trivialSignedAction 0 with
              preStateCommit := oneCommit }
        match applyTransition (matchingGame .sequencer)
                (.terminateOnSingleStep step settlementActionProof) with
        | .ok gs' =>
          assertEq (expected := GameStatus.challengerWon) (actual := gs'.status)
            "a caller-chosen log index loses"
        | .error e => assert false s!"transition should settle; got {repr e}"
    }
  , { name := "terminate_ok_requires_authentication type stable"
    , body := do
        let _proof :
            ∀ {gs gs' : GameState} {step : KernelStep}
              {actionProof : SmtCellProof},
              applyTransition gs (.terminateOnSingleStep step actionProof)
                = .ok gs' →
              step.signedAction.sig.size = 65 ∧
                verifyActionProof gs.actionsRoot gs.range.low.idx
                  (actionLeafValue step.signedAction) actionProof = true :=
          terminate_ok_requires_authentication
        assert true "authentication-inversion theorem API stable"
    }
  , { name := "anchored_challenger_wins type stable"
    , body := do
        let _proof :
            ∀ (truth : LogIndex → StateCommit)
              (gs gs' : GameState) (step : KernelStep)
              (actionProof trueProof : SmtCellProof)
              (trueKind : UInt8) (trueSigner : Nat)
              (trueFields trueSig : ByteArray),
              gs.turn = .sequencer →
              settlementDisagreement truth gs →
              trueSigner < 2 ^ 64 →
              trueSig.size = 65 →
              verifyActionProof gs.actionsRoot gs.range.low.idx
                (Runtime.hashBytes
                  (actionLeafPreimage trueKind trueSigner trueFields trueSig))
                trueProof = true →
              Bridge.CollisionFreeOn
                (smtCellProofPreimages (actionKey gs.range.low.idx)
                  (Runtime.hashBytes
                    (actionLeafPreimage
                      (StepVMCoherence.actionKindByte step.signedAction.action)
                      step.signedAction.signer.toNat
                      (StepVMCoherence.actionFieldsForL1
                        step.signedAction.action)
                      step.signedAction.sig))
                  (Runtime.hashBytes
                    (actionLeafPreimage trueKind trueSigner trueFields trueSig))
                  actionProof trueProof
                 ++ [actionLeafPreimage
                       (StepVMCoherence.actionKindByte step.signedAction.action)
                       step.signedAction.signer.toNat
                       (StepVMCoherence.actionFieldsForL1
                         step.signedAction.action)
                       step.signedAction.sig,
                     actionLeafPreimage trueKind trueSigner trueFields trueSig])
                Runtime.hashBytes →
              (∀ st : SignedAction, ∀ b : MultiBundle,
                StepVMCoherence.actionKindByte st.action = trueKind →
                st.signer.toNat = trueSigner →
                StepVMCoherence.actionFieldsForL1 st.action = trueFields →
                st.sig = trueSig →
                ∀ c, verifierPostRootMulti gs.range.low.commit st.action
                      st.signer gs.range.high.idx b = some c →
                  c = truth gs.range.high.idx) →
              applyTransition gs (.terminateOnSingleStep step actionProof)
                = .ok gs' →
              gs'.status = .challengerWon :=
          anchored_challenger_wins
        assert true "anchored composite theorem API stable"
    }
  , -- ===== Bridge lemma =====
    { name := "inDisagreementWithTruth_implies_settlementDisagreement"
    , body := do
        let truth : LogIndex → StateCommit :=
          fun i => if i = 0 then oneCommit else threeCommit
        -- inDisagreementWithTruth requires low.commit = truth(low.idx)
        -- and high.commit ≠ truth(high.idx).  Here low(0).commit =
        -- oneCommit = truth(0); high(1).commit = twoCommit ≠
        -- threeCommit = truth(1).
        let h : inDisagreementWithTruth truth challengerRespondingGame := by
          refine ⟨?_, ?_⟩
          · -- low.commit = truth(low.idx)
            show oneCommit = truth 0
            simp [truth]
          · -- high.commit ≠ truth(high.idx)
            show twoCommit ≠ truth 1
            simp [truth]
            intro heq
            have : twoCommit = threeCommit := heq
            -- Two distinct ByteArrays.
            simp [twoCommit, threeCommit] at this
        let projected :=
          inDisagreementWithTruth_implies_settlementDisagreement
            truth challengerRespondingGame h
        let _ := projected
        assert true "bridge lemma produces settlementDisagreement"
    }
  , -- ===== Type-stability checks =====
    { name := "terminate_responder_wins_when_step_reproduces_high type stable"
    , body := do
        let _proof :
            ∀ (gs gs' : GameState) (step : KernelStep)
              (actionProof : SmtCellProof),
              gs.status = .inProgress →
              gs.range.isSingleStep →
              gs.pendingMidpoint = none →
              step.signedAction.sig.size = 65 →
              verifyActionProof gs.actionsRoot gs.range.low.idx
                (actionLeafValue step.signedAction) actionProof = true →
              step.preStateCommit = gs.range.low.commit →
              step.l2LogIndex = gs.range.high.idx →
              kernelStepApply step = some gs.range.high.commit →
              applyTransition gs (.terminateOnSingleStep step actionProof)
                = .ok gs' →
              gs'.status =
                (match gs.turn with
                 | .sequencer  => GameStatus.sequencerWon
                 | .challenger => GameStatus.challengerWon) :=
          terminate_responder_wins_when_step_reproduces_high
        assert true "responder-win theorem API stable"
    }
  , { name := "terminate_responder_loses_when_step_differs type stable"
    , body := do
        let _proof :
            ∀ (gs gs' : GameState) (step : KernelStep)
              (actionProof : SmtCellProof) (computed : StateCommit),
              gs.status = .inProgress →
              gs.range.isSingleStep →
              gs.pendingMidpoint = none →
              step.signedAction.sig.size = 65 →
              verifyActionProof gs.actionsRoot gs.range.low.idx
                (actionLeafValue step.signedAction) actionProof = true →
              step.preStateCommit = gs.range.low.commit →
              step.l2LogIndex = gs.range.high.idx →
              kernelStepApply step = some computed →
              computed ≠ gs.range.high.commit →
              applyTransition gs (.terminateOnSingleStep step actionProof)
                = .ok gs' →
              gs'.status =
                (match gs.turn with
                 | .sequencer  => GameStatus.challengerWon
                 | .challenger => GameStatus.sequencerWon) :=
          terminate_responder_loses_when_step_differs
        assert true "responder-loss theorem API stable"
    }
  , { name := "honest_challenger_wins_against_invalid_state_root type stable"
    , body := do
        -- Fully ascribed: the composite is the workstream's headline
        -- claim, so its exact hypothesis set is the thing worth
        -- pinning.  Note there is no `claimedPostCommit` parameter
        -- and no response-branch disjunction any more — the
        -- settlement reads both sides from the game state.
        let _proof :
            ∀ (truth : LogIndex → StateCommit) (gs gs' : GameState)
              (step : KernelStep) (actionProof : SmtCellProof),
              gs.status = .inProgress →
              gs.range.isSingleStep →
              gs.pendingMidpoint = none →
              step.signedAction.sig.size = 65 →
              verifyActionProof gs.actionsRoot gs.range.low.idx
                (actionLeafValue step.signedAction) actionProof = true →
              step.preStateCommit = gs.range.low.commit →
              step.l2LogIndex = gs.range.high.idx →
              gs.turn = .sequencer →
              settlementDisagreement truth gs →
              kernelStepApply step = some (truth gs.range.high.idx) →
              applyTransition gs (.terminateOnSingleStep step actionProof)
                = .ok gs' →
              gs'.status = .challengerWon :=
          honest_challenger_wins_against_invalid_state_root
        assert true "composite #232 theorem API stable"
    }
  , -- ===== Game-state well-shaped =====
    { name := "challenger turn + single-step range is well-shaped"
    , body := do
        assert challengerRespondingGame.range.isSingleStep
          "range is single-step"
        assertEq (expected := TurnSide.challenger)
                 (actual := challengerRespondingGame.turn)
                 "challenger's turn"
    }
  , { name := "sequencer turn + single-step range is well-shaped"
    , body := do
        assert sequencerRespondingGame.range.isSingleStep
          "range is single-step"
        assertEq (expected := TurnSide.sequencer)
                 (actual := sequencerRespondingGame.turn)
                 "sequencer's turn"
    }
  ]

end LegalKernel.Test.FaultProof.Settlement

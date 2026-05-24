/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.Admissible — Workstream C.0 acceptance tests.

Drives the `BridgeAdmissibleWith` predicate, the
`apply_bridge_admissible_with` entry point, and the
`applyActionToBridgeState` helper at term-level + value-level.

Term-level API stability is checked via `#check`-shape `let _proof
:= @theorem_name; pure ()` patterns: the elaborator forces
`theorem_name`'s signature to match the binding's expected type,
so a signature drift fails the test at build time before the
`IO Unit` body even runs.
-/

import LegalKernel.Bridge.Admissible
import LegalKernel.FaultProof.StepVariants
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.Bridge.AdmissibleTests

/-- Tests for the bridge admissibility layer. -/
def tests : List TestCase :=
  [ { name := "Action.isBridgeOnly: bridge-attested constructors flagged"
    , body := do
        -- Workstream-C audit-1: `deposit` and `registerIdentity`
        -- are bridge-only.  `withdraw` is user-initiated and NOT in
        -- this set (see CLAUDE.md changelog).
        -- Workstream GP: `depositWithFee` is also bridge-only — the
        -- L1-attested deposit-with-fee event must be signed by
        -- bridgeActor.
        assertEq (expected := true)  (actual := Action.isBridgeOnly (.deposit 1 10 50 0))
                 "deposit flagged"
        assertEq (expected := true)  (actual := Action.isBridgeOnly (.registerIdentity 10 ⟨#[]⟩))
                 "registerIdentity flagged"
        assertEq (expected := true)
                 (actual := Action.isBridgeOnly (.depositWithFee 1 10 99 50 50 1000 42))
                 "depositWithFee flagged (Workstream GP)"
    }
  , { name := "Action.isBridgeOnly: withdraw is NOT bridge-only (audit-1)"
    , body := do
        -- Critical audit-1 invariant: `withdraw` must NOT be
        -- bridge-only.  Otherwise conjunct 8 of `BridgeAdmissibleWith`
        -- would force every withdrawal to be bridge-actor-signed,
        -- breaking the user-initiated withdrawal flow.
        assertEq (expected := false)
          (actual := Action.isBridgeOnly (.withdraw 1 10 50 EthAddress.zero))
          "withdraw must NOT be bridge-only"
        -- Workstream GP: `topUpActionBudget` is user-initiated (user
        -- pays gas to refill their own action budget) and must NOT
        -- be bridge-only.
        assertEq (expected := false)
          (actual := Action.isBridgeOnly (.topUpActionBudget 1 50 100 99))
          "topUpActionBudget must NOT be bridge-only"
    }
  , { name := "Action.isBridgeOnly: non-bridge constructors are not flagged"
    , body := do
        assertEq (expected := false) (actual := Action.isBridgeOnly (.transfer 1 2 3 4)) "transfer"
        assertEq (expected := false) (actual := Action.isBridgeOnly (.mint 1 2 3))      "mint"
        assertEq (expected := false) (actual := Action.isBridgeOnly (.burn 1 2 3))      "burn"
        assertEq (expected := false)
          (actual := Action.isBridgeOnly (.freezeResource 1)) "freeze"
        assertEq (expected := false)
          (actual := Action.isBridgeOnly (.replaceKey 10 ⟨#[]⟩)) "replaceKey"
        assertEq (expected := false) (actual := Action.isBridgeOnly (.reward 1 2 3)) "reward"
    }
  , { name := "applyActionToBridgeState: deposit inserts into consumed"
    , body := do
        let bs := applyActionToBridgeState BridgeState.empty (.deposit 1 10 100 42) 0
        assertEq (expected := true) (actual := bs.isConsumed 42) "consumed"
        assertEq (expected := false) (actual := bs.isConsumed 99) "not consumed"
    }
  , { name := "applyActionToBridgeState: depositWithFee inserts into consumed (Workstream GP)"
    , body := do
        -- The fix for the Workstream GP bridge-replay vulnerability:
        -- `.depositWithFee` MUST persist its `depositId` in
        -- `bridge.consumed` so a second admission with the same
        -- depositId is rejected at `BridgeAdmissibleWith` conjunct 6b.
        let bs := applyActionToBridgeState BridgeState.empty
                    (.depositWithFee 1 10 99 50 50 1000 77) 0
        assertEq (expected := true) (actual := bs.isConsumed 77)
                 "depositWithFee depositId consumed"
        assertEq (expected := false) (actual := bs.isConsumed 78)
                 "different depositId not consumed"
        -- The recorded amount is `userAmount + poolAmount` (total
        -- credited to L2 balances), matching the deposit-accounting
        -- invariant.
        match bs.consumed[(77 : DepositId)]? with
        | some rec =>
          assertEq (expected := (1 : ResourceId)) (actual := rec.resource)
                   "consumed resource"
          assertEq (expected := (100 : Amount)) (actual := rec.amount)
                   "consumed amount = userAmount + poolAmount"
        | none => throw <| IO.userError "depositId entry not found"
    }
  , { name := "depositWithFee and deposit share the consumed map"
    , body := do
        -- Workstream-GP closure: `.deposit` and `.depositWithFee`
        -- share the same `consumed` map.  A `.deposit` with
        -- depositId X followed by `.depositWithFee` carrying the
        -- same X (or vice versa) means the second action's
        -- depositId is NOT fresh.  This prevents cross-action
        -- replay using the L1-attested depositId space.
        let bs0 := applyActionToBridgeState BridgeState.empty (.deposit 1 10 100 50) 0
        let bs1 := applyActionToBridgeState bs0
                     (.depositWithFee 1 11 99 30 20 500 51) 1
        assertEq (expected := true) (actual := bs1.isConsumed 50) "deposit consumed"
        assertEq (expected := true) (actual := bs1.isConsumed 51) "depositWithFee consumed"
        assertEq (expected := (2 : Nat)) (actual := bs1.consumed.size)
                 "both depositIds tracked together"
    }
  , { name := "applyActionToBridgeState: depositWithFee self-recipient amount sums correctly"
    , body := do
        -- When recipient = poolActor, the consumed entry's amount
        -- is still userAmount + poolAmount (total credited).
        let bs := applyActionToBridgeState BridgeState.empty
                    (.depositWithFee 1 10 10 30 20 100 88) 0
        match bs.consumed[(88 : DepositId)]? with
        | some rec =>
          assertEq (expected := (50 : Amount)) (actual := rec.amount)
                   "self-recipient depositWithFee credits total 50"
        | none => throw <| IO.userError "depositId entry not found"
    }
  , { name := "applyActionToBridgeState: topUpActionBudget is identity"
    , body := do
        -- topUpActionBudget is user-initiated, no L1 attestation, so
        -- it MUST NOT mutate BridgeState.
        let bs := applyActionToBridgeState BridgeState.empty
                    (.topUpActionBudget 1 50 100 99) 0
        assertEq (expected := (0 : Nat)) (actual := bs.consumed.size) "no consumed entry"
        assertEq (expected := (0 : Nat)) (actual := bs.nextWdId) "nextWdId unchanged"
    }
  , { name := "applyActionToBridgeState: withdraw appends to pending"
    , body := do
        let bs := applyActionToBridgeState BridgeState.empty
                    (.withdraw 1 10 50 EthAddress.zero) 0
        assertEq (expected := (1 : Nat)) (actual := bs.nextWdId) "nextWdId bumped"
        assertEq (expected := (1 : Nat)) (actual := bs.pending.size) "pending size"
    }
  , { name := "applyActionToBridgeState: transfer is identity"
    , body := do
        let bs := applyActionToBridgeState BridgeState.empty (.transfer 1 2 3 4) 0
        assertEq (expected := (0 : Nat)) (actual := bs.nextWdId) "unchanged"
    }
  , { name := "applyActionToBridgeState: mint is identity"
    , body := do
        let bs := applyActionToBridgeState BridgeState.empty (.mint 1 2 3) 0
        assertEq (expected := (0 : Nat)) (actual := bs.nextWdId) "unchanged"
        assertEq (expected := (0 : Nat)) (actual := bs.consumed.size) "no deposits"
    }
  , { name := "applyActionToBridgeState: registerIdentity is identity"
    , body := do
        let bs := applyActionToBridgeState BridgeState.empty
                    (.registerIdentity 10 ⟨#[0xAA]⟩) 0
        assertEq (expected := (0 : Nat)) (actual := bs.nextWdId) "unchanged"
    }
  , { name := "Two distinct deposits update consumed independently"
    , body := do
        let bs0 := applyActionToBridgeState BridgeState.empty (.deposit 1 10 100 1) 0
        let bs1 := applyActionToBridgeState bs0                (.deposit 1 11 200 2) 1
        assertEq (expected := true) (actual := bs1.isConsumed 1) "first"
        assertEq (expected := true) (actual := bs1.isConsumed 2) "second"
        assertEq (expected := (2 : Nat)) (actual := bs1.consumed.size) "size 2"
    }
  , { name := "Two withdrawals get sequential ids 0, 1"
    , body := do
        let bs0 := applyActionToBridgeState BridgeState.empty
                     (.withdraw 1 10 50 EthAddress.zero) 0
        let bs1 := applyActionToBridgeState bs0
                     (.withdraw 1 11 75 EthAddress.zero) 1
        assertEq (expected := (2 : Nat)) (actual := bs1.nextWdId) "next is 2"
        assertEq (expected := (2 : Nat)) (actual := bs1.pending.size) "pending size 2"
    }
  -- ## Workstream-GP replay-rejection regression tests
  --
  -- These pin the core fix for the bridge-aware depositWithFee
  -- replay vulnerability: once a depositId has been marked
  -- consumed (via either a `.deposit` or `.depositWithFee` admission),
  -- a subsequent admission carrying the same depositId is rejected
  -- by `BridgeAdmissibleWith` at the predicate level (conjuncts 6
  -- and 6b), BEFORE the gate or the kernel step run.  This is the
  -- "ensure this can't happen again" regression for the original
  -- finding.
  , { name := "Replay rejection: depositWithFee depositId in consumed ⇒ predicate false"
    , body := do
        -- Pre-state has depositId 42 already marked consumed
        -- (e.g., from a prior `.depositWithFee` admission).
        let bs : BridgeState :=
          BridgeState.empty.markConsumed 42 ({ resource := 1, amount := 100 })
        -- `BridgeAdmissibleWith` conjunct 6b says: for any
        -- `.depositWithFee` action with depositId `d`,
        -- `consumed.contains d = false`.  When the pre-state's
        -- `consumed` already contains the depositId, conjunct 6b is
        -- false.
        let containsAlready := bs.consumed.contains 42
        assertEq (expected := true) (actual := containsAlready)
                 "pre-state has depositId 42 consumed"
        -- A `.depositWithFee` with depositId 42 would re-credit
        -- balances + budget if admitted.  Value-level check:
        -- `consumed.contains 42 = false` is FALSE for this state.
        assertEq (expected := false)
          (actual := (bs.consumed.contains 42 = false))
          "replay attempt: BridgeAdmissibleWith conjunct 6b fails"
    }
  , { name := "Replay rejection: deposit + depositWithFee with shared id are both consumed"
    , body := do
        -- A `.deposit` admission populates `consumed[d]`.  A
        -- subsequent `.depositWithFee` carrying the SAME d must
        -- ALSO be rejected (cross-action replay protection).
        -- This test simulates the runtime sequence at the
        -- `applyActionToBridgeState` layer.
        let bs0 := applyActionToBridgeState BridgeState.empty
                     (.deposit 1 10 100 7) 0
        assertEq (expected := true) (actual := bs0.isConsumed 7)
                 "first action consumed depositId 7"
        -- Any future `BridgeAdmissibleWith` evaluation on a
        -- `.depositWithFee r recipient poolActor ua pa bg 7`
        -- WOULD fail conjunct 6b because consumed[7] = true.  We
        -- assert the precondition at value level.
        assertEq (expected := false)
          (actual := (bs0.consumed.contains 7 = false))
          "depositWithFee with same id would fail conjunct 6b"
    }
  -- ## Cell-writes consistency regression
  --
  -- Verifies that the cells declared in `Action.writeCells` for
  -- bridge-mutating action variants match the cells that
  -- `applyActionToBridgeState` actually mutates.  Specifically:
  -- `.depositWithFee` declares `.bridgeConsumed d` in its
  -- writeCells; this test pins that the runtime actually marks
  -- `consumed[d]` after admission.  Catches future drift between
  -- the static declaration (used by the L1 step VM) and the
  -- dynamic state evolution.
  , { name := "Cell-writes consistency: depositWithFee writes .bridgeConsumed d"
    , body := do
        let d : DepositId := 0xABCDEF
        let action : Action := .depositWithFee 1 10 99 30 20 500 d
        -- Static declaration: .bridgeConsumed d is in writeCells.
        let declared := action.writeCells 7
        let hasBridgeConsumed := declared.any
          (fun t => match t with
            | .bridgeConsumed d' => d' = d
            | _ => false)
        assertEq (expected := true) (actual := hasBridgeConsumed)
                 "writeCells declares .bridgeConsumed d"
        -- Runtime: applyActionToBridgeState actually marks
        -- consumed[d] = true.
        let bs := applyActionToBridgeState BridgeState.empty action 0
        assertEq (expected := true) (actual := bs.isConsumed d)
                 "runtime marks consumed[d]"
    }
  -- Term-level API checks: `#check`-shape elaboration tests that
  -- catch any signature drift in the named theorems at build time.
  , { name := "apply_admissible_with_preserves_bridge: term-level API"
    , body := do
        let _t : ∀ (verify : PublicKey → ByteArray → Signature → Bool)
                   (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
                   (st : SignedAction) (h : AdmissibleWith verify P d es st),
                   (apply_admissible_with verify P d es st h).bridge = es.bridge :=
          apply_admissible_with_preserves_bridge
        pure ()
    }
  , { name := "apply_admissible_preserves_bridge: term-level API"
    , body := do
        let _t : ∀ (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction)
                   (h : Admissible P es st),
                   (apply_admissible P es st h).bridge = es.bridge :=
          apply_admissible_preserves_bridge
        pure ()
    }
  , { name := "applyActionToBridgeState_non_bridge: term-level API"
    , body := do
        let _t : ∀ (bs : BridgeState) (action : Action) (idx : Nat),
                  (∀ r recipient amount d, action ≠ .deposit r recipient amount d) →
                  (∀ r recipient poolActor ua pa bg d,
                    action ≠ .depositWithFee r recipient poolActor ua pa bg d) →
                  (∀ r sender amount rcp, action ≠ .withdraw r sender amount rcp) →
                  applyActionToBridgeState bs action idx = bs :=
          applyActionToBridgeState_non_bridge
        pure ()
    }
  , { name := "BridgeAdmissibleWith.toAdmissibleWith: term-level API"
    , body := do
        let _t : ∀ {verify : PublicKey → ByteArray → Signature → Bool}
                   {P : AuthorityPolicy} {d : ByteArray}
                   {es : ExtendedState} {st : SignedAction},
                   BridgeAdmissibleWith verify P d es st →
                   AdmissibleWith verify P d es st :=
          @BridgeAdmissibleWith.toAdmissibleWith
        pure ()
    }
  , { name := "BridgeAdmissibleWith.depositIdFresh: term-level API"
    , body := do
        let _t := @BridgeAdmissibleWith.depositIdFresh
        pure ()
    }
  , { name := "BridgeAdmissibleWith.depositWithFeeIdFresh: term-level API (Workstream GP)"
    , body := do
        let _t := @BridgeAdmissibleWith.depositWithFeeIdFresh
        pure ()
    }
  , { name := "BridgeAdmissibleWith.registrationFresh: term-level API"
    , body := do
        let _t := @BridgeAdmissibleWith.registrationFresh
        pure ()
    }
  , { name := "BridgeAdmissibleWith.bridgeOnlySigner: term-level API"
    , body := do
        let _t := @BridgeAdmissibleWith.bridgeOnlySigner
        pure ()
    }
  , { name := "applyActionToBridgeState_depositWithFee_consumed: term-level API (Workstream GP)"
    , body := do
        let _t := @applyActionToBridgeState_depositWithFee_consumed
        pure ()
    }
  , { name := "bridge_replay_impossible: term-level API"
    , body := do
        let _t : ∀ (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction)
                   (idx : Nat)
                   (h : BridgeAdmissibleWith Verify P ByteArray.empty es st),
                   ¬ BridgeAdmissibleWith Verify P ByteArray.empty
                       (apply_bridge_admissible_with Verify P ByteArray.empty es st idx h) st :=
          bridge_replay_impossible
        pure ()
    }
  -- Audit-1 post-state invariants
  , { name := "deposit_marks_consumed: term-level API (audit-1)"
    , body := do
        let _t := @deposit_marks_consumed
        pure ()
    }
  , { name := "deposit_replay_blocked_by_consumed: term-level API (audit-1)"
    , body := do
        let _t := @deposit_replay_blocked_by_consumed
        pure ()
    }
  -- Workstream LP / LP.8: declareLocalPolicy/revokeLocalPolicy are
  -- non-bridge actions (Action.isBridgeOnly returns false for them).
  , { name := "Action.isBridgeOnly false on declareLocalPolicy"
    , body := do
        let p : Authority.LocalPolicy := { clauses := [] }
        assertEq (expected := false)
          (actual := Action.isBridgeOnly (.declareLocalPolicy p))
          "declareLocalPolicy should not be bridge-only"
    }
  , { name := "Action.isBridgeOnly false on revokeLocalPolicy"
    , body := do
        assertEq (expected := false)
          (actual := Action.isBridgeOnly .revokeLocalPolicy)
          "revokeLocalPolicy should not be bridge-only"
    }
  , { name := "applyActionToBridgeState identity on LP actions"
    , body := do
        let bs := BridgeState.empty
        let p : Authority.LocalPolicy := { clauses := [] }
        let bs1 := applyActionToBridgeState bs (.declareLocalPolicy p) 0
        let bs2 := applyActionToBridgeState bs .revokeLocalPolicy 0
        assertEq bs.nextWdId bs1.nextWdId "declareLocalPolicy preserves nextWdId"
        assertEq bs.nextWdId bs2.nextWdId "revokeLocalPolicy preserves nextWdId"
    }
  , { name := "withdraw_bumps_nextWdId: term-level API (audit-1)"
    , body := do
        let _t := @withdraw_bumps_nextWdId
        pure ()
    }
  ]

end LegalKernel.Test.Bridge.AdmissibleTests

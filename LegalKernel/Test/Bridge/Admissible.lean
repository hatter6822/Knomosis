/-
  Canon  - A Societal Kernel
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
        -- Workstream-C audit-1: only `deposit` and `registerIdentity`
        -- are bridge-only.  `withdraw` is user-initiated and NOT in
        -- this set (see CLAUDE.md changelog).
        assertEq (expected := true)  (actual := Action.isBridgeOnly (.deposit 1 10 50 0))
                 "deposit flagged"
        assertEq (expected := true)  (actual := Action.isBridgeOnly (.registerIdentity 10 ⟨#[]⟩))
                 "registerIdentity flagged"
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

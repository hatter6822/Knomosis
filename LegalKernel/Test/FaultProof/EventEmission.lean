/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.EventEmission — value-level tests for
the three new `Event` constructors at frozen indices 13 / 14 / 15
plus event-extraction behaviour (Workstream H §12.3).
-/

import LegalKernel.Events.Extract
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Events
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.EventEmission

/-- Tests for fault-proof event types and emission rules. -/
def tests : List TestCase :=
  [ { name := "Event.faultProofGameOpened is fault-proof event"
    , body := do
        let e := Event.faultProofGameOpened 0 1 0 10 ByteArray.empty
        assert e.isFaultProofEvent "isFaultProofEvent fires"
    }
  , { name := "Event.faultProofBisectionStep is fault-proof event"
    , body := do
        let e := Event.faultProofBisectionStep 1 0 1 5 ByteArray.empty
        assert e.isFaultProofEvent "isFaultProofEvent fires"
    }
  , { name := "Event.faultProofGameSettled is fault-proof event"
    , body := do
        let e := Event.faultProofGameSettled 1 1 2 100
        assert e.isFaultProofEvent "isFaultProofEvent fires"
    }
  , { name := "Event.balanceChanged is NOT fault-proof event"
    , body := do
        let e := Event.balanceChanged 1 2 0 100
        assert (¬ e.isFaultProofEvent) "non-fault-proof rejected"
    }
  , { name := "Event.actor projects challenger from gameOpened"
    , body := do
        let e := Event.faultProofGameOpened 0 42 0 10 ByteArray.empty
        assertEq (expected := some 42) (actual := e.actor)
          "actor projection"
    }
  , { name := "Event.actor projects party from bisectionStep"
    , body := do
        let e := Event.faultProofBisectionStep 1 0 7 5 ByteArray.empty
        assertEq (expected := some 7) (actual := e.actor)
          "actor projection"
    }
  , { name := "Event.actor projects winner from gameSettled"
    , body := do
        let e := Event.faultProofGameSettled 1 99 100 50
        assertEq (expected := some 99) (actual := e.actor)
          "actor projection (winner)"
    }
  , { name := "extractEvents emits faultProofGameOpened on challenge"
    , body := do
        let bh := ByteArray.mk #[0xab]
        let st : SignedAction := {
          action := .faultProofChallenge bh 0 10 ByteArray.empty,
          signer := 5,
          nonce := 0,
          sig := ByteArray.empty
        }
        let evts := extractEvents ExtendedState.empty ExtendedState.empty st
        assert (evts.contains (Event.faultProofGameOpened 0 5 0 10 bh))
          "gameOpened event emitted"
    }
  , { name := "extractEvents emits faultProofGameSettled on resolution"
    , body := do
        let bh := ByteArray.mk #[0xcd]
        let st : SignedAction := {
          action := .faultProofResolution bh 42 99 5,
          signer := 7,
          nonce := 0,
          sig := ByteArray.empty
        }
        let evts := extractEvents ExtendedState.empty ExtendedState.empty st
        assert (evts.contains (Event.faultProofGameSettled 42 99 7 0))
          "gameSettled event emitted"
    }
  , { name := "DecidableEq on Event distinguishes fault-proof events"
    , body := do
        let e1 := Event.faultProofGameOpened 0 1 0 10 ByteArray.empty
        let e2 := Event.faultProofGameOpened 1 1 0 10 ByteArray.empty
        assert (¬ (e1 = e2)) "distinct gameId distinguishable"
    }
  ]

end LegalKernel.Test.FaultProof.EventEmission

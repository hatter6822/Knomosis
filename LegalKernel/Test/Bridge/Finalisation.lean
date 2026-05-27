/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.Finalisation — Workstream D.3
acceptance tests.

Drives `isFinalised`, `hasUpheldInRange`, plus the headline
`isFinalised_monotonic_in_currentBlock` and
`isFinalised_implies_no_upheld_against` theorems at the value
level.
-/

import LegalKernel.Bridge.Finalisation
import LegalKernel.Bridge.WithdrawalProof
import LegalKernel.Bridge.WithdrawalRoot
import LegalKernel.Bridge.State
import LegalKernel.Disputes.Filing
import LegalKernel.Authority.Nonce
import LegalKernel.Runtime.Snapshot
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding
open LegalKernel.Disputes
open LegalKernel.Test

namespace LegalKernel.Test.Bridge.FinalisationTests

/-- A minimal fixture: empty snapshot wrapped as finalisable. -/
def emptyFsnap : FinalisableSnapshot :=
  { snapshot := takeSnapshot ExtendedState.empty zeroHash 0
    submitL1Block := 1000
    logIndexLow := 0
    logIndexHigh := 0 }

/-- Tests for `Finalisation`. -/
def tests : List TestCase :=
  [ -- Basic predicate tests
    { name := "isFinalised: empty range, before window → false (insufficient confirmations)"
    , body := do
        -- Window = 100, current = 1050, submit = 1000.  Need current ≥ submit + window = 1100.
        let result := isFinalised emptyFsnap 1050 100 []
        assertEq (expected := false) (actual := result) "before window"
    }
  , { name := "isFinalised: empty range, exactly at window → true"
    , body := do
        let result := isFinalised emptyFsnap 1100 100 []
        assertEq (expected := true) (actual := result) "at window"
    }
  , { name := "isFinalised: empty range, after window → true"
    , body := do
        let result := isFinalised emptyFsnap 5000 100 []
        assertEq (expected := true) (actual := result) "after window"
    }
  , { name := "isFinalised: zero dispute window finalises immediately"
    , body := do
        let fsnap : FinalisableSnapshot :=
          { snapshot := takeSnapshot ExtendedState.empty zeroHash 0
            submitL1Block := 0
            logIndexLow := 0
            logIndexHigh := 0 }
        let result := isFinalised fsnap 0 0 []
        assertEq (expected := true) (actual := result) "zero window"
    }
  -- §8.3 #1: monotonicity
  , { name := "isFinalised_monotonic_in_currentBlock: term-level API"
    , body := do
        let _t := @isFinalised_monotonic_in_currentBlock
        pure ()
    }
  , { name := "isFinalised: monotonic in currentBlock (value-level)"
    , body := do
        let r1 := isFinalised emptyFsnap 1100 100 []
        let r2 := isFinalised emptyFsnap 2000 100 []
        if r1 = true ∧ r2 = true then pure ()
        else throw <| IO.userError "monotonic property failed at value level"
    }
  -- §8.3 #2: no upheld against
  , { name := "isFinalised_implies_no_upheld_against: term-level API"
    , body := do
        let _t := @isFinalised_implies_no_upheld_against
        pure ()
    }
  -- hasUpheldInRange tests
  , { name := "hasUpheldInRange: empty range = false"
    , body := do
        let result := hasUpheldInRange [] 5 5
        assertEq (expected := false) (actual := result) "empty"
    }
  , { name := "hasUpheldInRange: empty log = false"
    , body := do
        let result := hasUpheldInRange [] 0 10
        assertEq (expected := false) (actual := result) "empty log"
    }
  , { name := "hasUpheldInRange_false_implies: term-level API"
    , body := do
        let _t := @hasUpheldInRange_false_implies
        pure ()
    }
  -- isFinalised_deterministic
  , { name := "isFinalised_deterministic: term-level API"
    , body := do
        let _t := @isFinalised_deterministic
        pure ()
    }
  , { name := "isFinalised: deterministic on same inputs"
    , body := do
        let r1 := isFinalised emptyFsnap 5000 100 []
        let r2 := isFinalised emptyFsnap 5000 100 []
        if r1 = r2 then pure () else throw <| IO.userError "non-deterministic"
    }
  -- FinalisableSnapshot construction
  , { name := "FinalisableSnapshot has all four fields accessible"
    , body := do
        assertEq (expected := (1000 : Nat)) (actual := emptyFsnap.submitL1Block)
                 "submitL1Block"
        assertEq (expected := (0 : Nat)) (actual := emptyFsnap.logIndexLow)
                 "logIndexLow"
        assertEq (expected := (0 : Nat)) (actual := emptyFsnap.logIndexHigh)
                 "logIndexHigh"
        assertEq (expected := (0 : Nat)) (actual := emptyFsnap.snapshot.logIndex)
                 "snapshot.logIndex"
    }
  -- Edge case: window threshold boundary at submit + window - 1 should be NOT finalised
  , { name := "isFinalised: at submit + window - 1 → false (just below threshold)"
    , body := do
        -- submit = 1000, window = 100; threshold = 1100. At 1099, insufficient.
        let result := isFinalised emptyFsnap 1099 100 []
        assertEq (expected := false) (actual := result) "below threshold"
    }
  -- §8.2 + §8.3: extractFinalisedProof
  , { name := "extractFinalisedProof: term-level API"
    , body := do
        let _t := @extractFinalisedProof
        pure ()
    }
  , { name := "extractFinalisedProof_consistent_with_root: term-level API"
    , body := do
        let _t := @extractFinalisedProof_consistent_with_root
        pure ()
    }
  , { name := "extractFinalisedProof_deterministic: term-level API"
    , body := do
        let _t := @extractFinalisedProof_deterministic
        pure ()
    }
  , { name := "extractFinalisedProof_unfinalised: term-level API"
    , body := do
        let _t := @extractFinalisedProof_unfinalised
        pure ()
    }
  -- §8.2 + §8.3: extractFinalisedProof on unfinalised snapshot returns none
  , { name := "extractFinalisedProof: unfinalised → none (value-level)"
    , body := do
        -- emptyFsnap with currentBlock < submit + window: not finalised.
        -- extractFinalisedProof should return none regardless of idx.
        let result := extractFinalisedProof emptyFsnap 1050 100 [] 0
        match result with
        | none   => pure ()
        | some _ => throw <| IO.userError "expected none for unfinalised"
    }
  , { name := "extractFinalisedProof: finalised + empty bridge → none (no withdrawals)"
    , body := do
        -- Snapshot is finalised but bridge is empty, so extractProof returns none.
        let result := extractFinalisedProof emptyFsnap 5000 100 [] 0
        match result with
        | none   => pure ()
        | some _ => throw <| IO.userError "expected none for empty bridge"
    }
  ]

end LegalKernel.Test.Bridge.FinalisationTests

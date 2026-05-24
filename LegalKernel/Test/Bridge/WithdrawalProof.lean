/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.WithdrawalProof — Workstream D.2
acceptance tests.

Drives `extractProof`, `Snapshot.bridgeWithdrawalRoot`, and
`extractProof_consistent_with_root` at the value level.
-/

import LegalKernel.Bridge.WithdrawalProof
import LegalKernel.Bridge.WithdrawalRoot
import LegalKernel.Bridge.State
import LegalKernel.Bridge.AddressBook
import LegalKernel.Authority.Nonce
import LegalKernel.Encoding.State
import LegalKernel.Runtime.Snapshot
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding
open LegalKernel.Test

namespace LegalKernel.Test.Bridge.WithdrawalProofTests

/-- An `ExtendedState` with a one-leaf bridge ledger. -/
def fixtureExtendedState : ExtendedState :=
  let wd : PendingWithdrawal :=
    { resource := 1, recipient := EthAddress.zero, amount := 100, l2LogIndex := 5 }
  { base := genesisState
    nonces := NonceState.empty
    registry := KeyRegistry.empty
    bridge := BridgeState.empty.appendWithdrawal wd }

/-- A `Snapshot` of `fixtureExtendedState` at log index 0. -/
def fixtureSnapshot : Snapshot :=
  takeSnapshot fixtureExtendedState zeroHash 0

/-- An empty bridge `ExtendedState` (no withdrawals). -/
def emptyBridgeES : ExtendedState := ExtendedState.empty

/-- A snapshot of the empty bridge state. -/
def emptySnapshot : Snapshot := takeSnapshot emptyBridgeES zeroHash 0

/-- Tests for `WithdrawalProof`. -/
def tests : List TestCase :=
  [ -- extractProof basic shape tests
    { name := "extractProof on valid snapshot + present id returns some"
    , body := do
        match extractProof fixtureSnapshot 0 with
        | some _ => pure ()
        | none   => throw <| IO.userError "extractProof returned none"
    }
  , { name := "extractProof on valid snapshot + absent id returns none"
    , body := do
        match extractProof fixtureSnapshot 99 with
        | none   => pure ()
        | some _ => throw <| IO.userError "extractProof returned some for absent id"
    }
  , { name := "extractProof on empty bridge returns none"
    , body := do
        match extractProof emptySnapshot 0 with
        | none   => pure ()
        | some _ => throw <| IO.userError "extractProof returned some for empty"
    }
  -- Snapshot.bridgeWithdrawalRoot
  , { name := "Snapshot.bridgeWithdrawalRoot is 32 bytes"
    , body := do
        let root := fixtureSnapshot.bridgeWithdrawalRoot
        assertEq (expected := (32 : Nat)) (actual := root.size) "size"
    }
  , { name := "bridgeWithdrawalRoot of empty snapshot = empty-tree root"
    , body := do
        let r1 := emptySnapshot.bridgeWithdrawalRoot.toList
        let r2 := (defaultHash hashBytes smtHeight).toList
        if r1 == r2 then pure () else throw <| IO.userError "non-empty default"
    }
  , { name := "bridgeWithdrawalRoot of populated snapshot ≠ empty root"
    , body := do
        let r1 := fixtureSnapshot.bridgeWithdrawalRoot.toList
        let r2 := emptySnapshot.bridgeWithdrawalRoot.toList
        if r1 == r2 then
          throw <| IO.userError "populated bridge collided with empty"
        else pure ()
    }
  , { name := "bridgeWithdrawalRoot is deterministic"
    , body := do
        let r1 := fixtureSnapshot.bridgeWithdrawalRoot.toList
        let r2 := fixtureSnapshot.bridgeWithdrawalRoot.toList
        if r1 == r2 then pure () else throw <| IO.userError "non-deterministic"
    }
  -- §8.2 headline: extractProof_consistent_with_root
  , { name := "extracted proof verifies against snapshot root"
    , body := do
        match extractProof fixtureSnapshot 0 with
        | some proof =>
          if verifyProof hashBytes proof fixtureSnapshot.bridgeWithdrawalRoot then
            pure ()
          else
            throw <| IO.userError "extracted proof failed verification"
        | none => throw <| IO.userError "extractProof returned none"
    }
  , { name := "extractProof_consistent_with_root: term-level API"
    , body := do
        let _t := @extractProof_consistent_with_root
        pure ()
    }
  -- Determinism tests
  , { name := "extractProof_deterministic: term-level API"
    , body := do
        let _t := @extractProof_deterministic
        pure ()
    }
  , { name := "bridgeWithdrawalRoot_deterministic: term-level API"
    , body := do
        let _t := @bridgeWithdrawalRoot_deterministic
        pure ()
    }
  , { name := "extractProof on same input gives same output"
    , body := do
        let p1 := extractProof fixtureSnapshot 0
        let p2 := extractProof fixtureSnapshot 0
        if p1 == p2 then pure () else throw <| IO.userError "non-deterministic"
    }
  ]

end LegalKernel.Test.Bridge.WithdrawalProofTests

/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.State — Workstream C.1 acceptance tests.

Drives the `BridgeState` data structures (§7.1.1 / WU C.1.1) plus
the `ExtendedState` field embedding (§7.1.2 / WU C.1.2) at the
value level: `BridgeState.empty` properties, single-deposit /
single-withdrawal mutators, and `ExtendedState.empty` exposes the
genesis bridge ledger.
-/

import LegalKernel.Bridge.State
import LegalKernel.Authority.Nonce
import LegalKernel.Encoding.State
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Test

namespace LegalKernel.Test.Bridge.StateTests

/-- Tests for `BridgeState` data structures. -/
def tests : List TestCase :=
  [ { name := "BridgeState.empty: consumed map is empty"
    , body := do
        let _proof :
            (BridgeState.empty.consumed
              : Std.TreeMap DepositId DepositRecord compare) = ∅ :=
          BridgeState.empty_consumed_empty
        pure ()
    }
  , { name := "BridgeState.empty: pending map is empty"
    , body := do
        let _proof :
            (BridgeState.empty.pending
              : Std.TreeMap WithdrawalId PendingWithdrawal compare) = ∅ :=
          BridgeState.empty_pending_empty
        pure ()
    }
  , { name := "BridgeState.empty: nextWdId is 0"
    , body := do
        let _proof : BridgeState.empty.nextWdId = 0 :=
          BridgeState.empty_nextWdId_zero
        pure ()
    }
  , { name := "BridgeState.markConsumed inserts the deposit record"
    , body := do
        let bs := BridgeState.empty.markConsumed 42 ({ resource := 1, amount := 100 })
        assertEq (expected := true) (actual := bs.isConsumed 42) "consumed"
        assertEq (expected := false) (actual := bs.isConsumed 43) "not consumed"
    }
  , { name := "BridgeState.markConsumed leaves pending unchanged"
    , body := do
        let bs := BridgeState.empty.markConsumed 1 ({ resource := 1, amount := 100 })
        assertEq (expected := (0 : Nat)) (actual := bs.pending.size) "pending empty"
        assertEq (expected := (0 : Nat)) (actual := bs.nextWdId) "nextWdId 0"
    }
  , { name := "BridgeState.appendWithdrawal increments nextWdId"
    , body := do
        let wd : PendingWithdrawal :=
          { resource := 1, recipient := EthAddress.zero, amount := 50, l2LogIndex := 0 }
        let bs := BridgeState.empty.appendWithdrawal wd
        assertEq (expected := (1 : Nat)) (actual := bs.nextWdId) "nextWdId bumped"
        assertEq (expected := (1 : Nat)) (actual := bs.pending.size) "pending size"
    }
  , { name := "BridgeState.appendWithdrawal preserves consumed"
    , body := do
        let bs0 := BridgeState.empty.markConsumed 1 ({ resource := 1, amount := 100 })
        let wd : PendingWithdrawal :=
          { resource := 1, recipient := EthAddress.zero, amount := 50, l2LogIndex := 0 }
        let bs1 := bs0.appendWithdrawal wd
        assertEq (expected := true) (actual := bs1.isConsumed 1) "consumed preserved"
    }
  , { name := "Two appendWithdrawal calls produce id sequence 0, 1"
    , body := do
        let wd1 : PendingWithdrawal :=
          { resource := 1, recipient := EthAddress.zero, amount := 10, l2LogIndex := 0 }
        let wd2 : PendingWithdrawal :=
          { resource := 1, recipient := EthAddress.zero, amount := 20, l2LogIndex := 1 }
        let bs := (BridgeState.empty.appendWithdrawal wd1).appendWithdrawal wd2
        assertEq (expected := (2 : Nat)) (actual := bs.nextWdId) "next is 2"
        -- pending map should have entries at 0 and 1.
        assertEq (expected := (2 : Nat)) (actual := bs.pending.size) "two entries"
    }
  , { name := "ExtendedState.empty has empty bridge ledger"
    , body := do
        let es := ExtendedState.empty
        assertEq (expected := (0 : Nat)) (actual := es.bridge.nextWdId) "nextWdId 0"
        assertEq (expected := (0 : Nat)) (actual := es.bridge.consumed.size) "no deposits"
        assertEq (expected := (0 : Nat)) (actual := es.bridge.pending.size) "no withdrawals"
    }
  , { name := "DepositRecord equality is decidable"
    , body := do
        let r1 : DepositRecord := { resource := 1, amount := 100 }
        let r2 : DepositRecord := { resource := 1, amount := 100 }
        let r3 : DepositRecord := { resource := 2, amount := 100 }
        assert (r1 == r2) "equal records"
        assert (! (r1 == r3)) "distinct records"
    }
  , { name := "PendingWithdrawal equality is decidable"
    , body := do
        let w1 : PendingWithdrawal :=
          { resource := 1, recipient := EthAddress.zero, amount := 50, l2LogIndex := 0 }
        let w2 : PendingWithdrawal :=
          { resource := 1, recipient := EthAddress.zero, amount := 50, l2LogIndex := 0 }
        let w3 : PendingWithdrawal :=
          { resource := 2, recipient := EthAddress.zero, amount := 50, l2LogIndex := 0 }
        assert (w1 == w2) "equal pending"
        assert (! (w1 == w3)) "distinct pending"
    }
  -- Audit-1: encoding determinism API stability (§7.1.4 deliverable)
  , { name := "bridgeState_encode_deterministic: term-level API (audit-1)"
    , body := do
        let _t : ∀ (bs₁ bs₂ : BridgeState) (_h : bs₁ = bs₂),
                   Encodable.encode (T := BridgeState) bs₁ =
                   Encodable.encode (T := BridgeState) bs₂ :=
          bridgeState_encode_deterministic
        pure ()
    }
  , { name := "depositRecord_roundtrip: term-level API (audit-1)"
    , body := do
        let _t := @depositRecord_roundtrip
        pure ()
    }
  , { name := "depositRecord_encode_deterministic: term-level API (audit-1)"
    , body := do
        let _t := @depositRecord_encode_deterministic
        pure ()
    }
  , { name := "pendingWithdrawal_encode_deterministic: term-level API (audit-1)"
    , body := do
        let _t := @pendingWithdrawal_encode_deterministic
        pure ()
    }
  , { name := "pendingWithdrawal_roundtrip: term-level API (EI.7.b precursor)"
    , body := do
        let _t := @pendingWithdrawal_roundtrip
        pure ()
    }
  , { name := "pendingWithdrawal_roundtrip: value-level smoke (EI.7.b precursor)"
    , body := do
        -- Construct a concrete withdrawal at the smallest non-trivial size,
        -- encode it, then verify the decoder recovers the original record.
        -- Bounds are trivially satisfied: all Nat fields are < 2^64.
        let wd : Bridge.PendingWithdrawal :=
          { resource    := 7
            recipient   := ⟨42, by decide⟩
            amount      := 100
            l2LogIndex  := 3 }
        let encoded : Stream := Bridge.PendingWithdrawal.encode wd
        match Bridge.PendingWithdrawal.decode (encoded ++ []) with
        | .ok (wd', []) =>
            if decide (wd = wd') then pure ()
            else throw <| IO.userError s!"pendingWithdrawal_roundtrip: decode produced different record"
        | .ok (_, _ :: _) =>
            throw <| IO.userError "pendingWithdrawal_roundtrip: decoder produced trailing bytes"
        | .error e =>
            throw <| IO.userError s!"pendingWithdrawal_roundtrip: decode failed: {repr e}"
    }
  -- Value-level: BridgeState.empty encodes deterministically.
  , { name := "BridgeState.empty encode is deterministic (value-level)"
    , body := do
        let bytes1 := Encodable.encode (T := BridgeState) BridgeState.empty
        let bytes2 := Encodable.encode (T := BridgeState) BridgeState.empty
        if bytes1 == bytes2 then pure () else throw <| IO.userError "non-deterministic"
    }
  -- Value-level: BridgeState with one consumed deposit encodes
  -- to a different byte stream than empty.
  , { name := "Non-empty BridgeState distinguishable from empty"
    , body := do
        let bs := BridgeState.empty.markConsumed 42 ({ resource := 1, amount := 100 })
        let b1 := Encodable.encode (T := BridgeState) bs
        let b2 := Encodable.encode (T := BridgeState) BridgeState.empty
        if b1 == b2 then
          throw <| IO.userError "non-empty BridgeState collided with empty bytes"
        else pure ()
    }
  -- Audit-1: BridgeState.consumed map insertion is mathematically
  -- correct (insert-then-contains = true).
  , { name := "markConsumed then isConsumed: insert-then-contains semantics"
    , body := do
        let bs := BridgeState.empty.markConsumed 7 ({ resource := 1, amount := 50 })
        assertEq (expected := true) (actual := bs.isConsumed 7) "freshly consumed"
        -- A different deposit-id is NOT consumed.
        assertEq (expected := false) (actual := bs.isConsumed 8) "absent"
    }
  ]

end LegalKernel.Test.Bridge.StateTests

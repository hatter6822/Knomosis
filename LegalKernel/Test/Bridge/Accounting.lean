/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.Accounting — Workstream C.6 acceptance tests.

Drives the bridge accounting quantity functionals (`totalDeposited`,
`totalWithdrawn`) and the per-action delta lemmas at value-level
fixtures.
-/

import LegalKernel.Bridge.Accounting
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.Bridge.AccountingTests

/-- A bridge state with one deposit (id=1, resource=1, amount=100). -/
def bs1 : BridgeState :=
  BridgeState.empty.markConsumed 1 ({ resource := 1, amount := 100 })

/-- A bridge state with one deposit + one withdrawal at the same r. -/
def bs2 : BridgeState :=
  bs1.appendWithdrawal
    { resource := 1, recipient := EthAddress.zero, amount := 30, l2LogIndex := 0 }

/-- Wrap a `BridgeState` into a minimal `ExtendedState` for the
    accounting fold helpers. -/
def es (bs : BridgeState) : ExtendedState :=
  { ExtendedState.empty with bridge := bs }

/-- Tests for the bridge accounting functionals. -/
def tests : List TestCase :=
  [ { name := "totalDeposited_genesis: 0 at every resource"
    , body := do
        assertEq (expected := (0 : Nat))
                 (actual := totalDeposited ExtendedState.empty 1) "r=1"
        assertEq (expected := (0 : Nat))
                 (actual := totalDeposited ExtendedState.empty 2) "r=2"
    }
  , { name := "totalWithdrawn_genesis: 0 at every resource"
    , body := do
        assertEq (expected := (0 : Nat))
                 (actual := totalWithdrawn ExtendedState.empty 1) "r=1"
        assertEq (expected := (0 : Nat))
                 (actual := totalWithdrawn ExtendedState.empty 2) "r=2"
    }
  , { name := "totalDeposited: single deposit at r=1"
    , body := do
        assertEq (expected := (100 : Nat))
                 (actual := totalDeposited (es bs1) 1) "r=1"
        assertEq (expected := (0 : Nat))
                 (actual := totalDeposited (es bs1) 2) "r=2"
    }
  , { name := "totalWithdrawn: deposit alone is 0"
    , body := do
        assertEq (expected := (0 : Nat))
                 (actual := totalWithdrawn (es bs1) 1) "r=1"
    }
  , { name := "totalWithdrawn: deposit + withdrawal"
    , body := do
        assertEq (expected := (30 : Nat))
                 (actual := totalWithdrawn (es bs2) 1) "r=1"
        assertEq (expected := (0 : Nat))
                 (actual := totalWithdrawn (es bs2) 2) "r=2"
    }
  , { name := "totalDeposited: two deposits at the same r accumulate"
    , body := do
        let bs := bs1.markConsumed 2 ({ resource := 1, amount := 50 })
        assertEq (expected := (150 : Nat))
                 (actual := totalDeposited (es bs) 1) "150"
    }
  , { name := "totalDeposited: two deposits at different r"
    , body := do
        let bs := bs1.markConsumed 2 ({ resource := 2, amount := 75 })
        assertEq (expected := (100 : Nat))
                 (actual := totalDeposited (es bs) 1) "r=1"
        assertEq (expected := (75 : Nat))
                 (actual := totalDeposited (es bs) 2) "r=2"
    }
  , { name := "PendingWithdrawal.amountAt projects correctly"
    , body := do
        let wd : PendingWithdrawal :=
          { resource := 1, recipient := EthAddress.zero, amount := 50, l2LogIndex := 0 }
        assertEq (expected := (50 : Nat)) (actual := wd.amountAt 1) "r=1"
        assertEq (expected := (0 : Nat))  (actual := wd.amountAt 2) "r=2"
    }
  , { name := "DepositRecord.amountAt projects correctly"
    , body := do
        let drec : DepositRecord := { resource := 1, amount := 100 }
        assertEq (expected := (100 : Nat)) (actual := drec.amountAt 1) "r=1"
        assertEq (expected := (0 : Nat))   (actual := drec.amountAt 2) "r=2"
    }
  , { name := "totalDeposited_unchanged_when_bridge_eq: term-level API"
    , body := do
        let _t : ∀ (es₁ es₂ : ExtendedState) (_h : es₁.bridge = es₂.bridge)
                   (r : ResourceId),
                   totalDeposited es₁ r = totalDeposited es₂ r :=
          totalDeposited_unchanged_when_bridge_eq
        pure ()
    }
  , { name := "totalWithdrawn_unchanged_when_bridge_eq: term-level API"
    , body := do
        let _t : ∀ (es₁ es₂ : ExtendedState) (_h : es₁.bridge = es₂.bridge)
                   (r : ResourceId),
                   totalWithdrawn es₁ r = totalWithdrawn es₂ r :=
          totalWithdrawn_unchanged_when_bridge_eq
        pure ()
    }
  , { name := "accounting_delta_non_bridge: term-level API"
    , body := do
        let _t := @accounting_delta_non_bridge
        pure ()
    }
  , { name := "accounting_delta_transfer: term-level API"
    , body := do
        let _t := @accounting_delta_transfer
        pure ()
    }
  , { name := "accounting_delta_freeze: term-level API"
    , body := do
        let _t := @accounting_delta_freeze
        pure ()
    }
  , { name := "accounting_delta_replaceKey: term-level API"
    , body := do
        let _t := @accounting_delta_replaceKey
        pure ()
    }
  , { name := "accounting_delta_registerIdentity: term-level API"
    , body := do
        let _t := @accounting_delta_registerIdentity
        pure ()
    }
  , { name := "applyActionToBridgeState_deposit: term-level API"
    , body := do
        let _t : ∀ (bs : BridgeState) (r : ResourceId) (recipient : ActorId)
                   (amount : Amount) (d : DepositId) (idx : Nat),
                   applyActionToBridgeState bs (.deposit r recipient amount d) idx =
                   bs.markConsumed d ({ resource := r, amount := amount }) :=
          applyActionToBridgeState_deposit
        pure ()
    }
  , { name := "applyActionToBridgeState_withdraw: term-level API"
    , body := do
        let _t : ∀ (bs : BridgeState) (r : ResourceId) (sender : ActorId)
                   (amount : Amount) (rcp : EthAddress) (idx : Nat),
                   applyActionToBridgeState bs (.withdraw r sender amount rcp) idx =
                   bs.appendWithdrawal
                     { resource := r, recipient := rcp,
                       amount := amount, l2LogIndex := idx } :=
          applyActionToBridgeState_withdraw
        pure ()
    }
  , { name := "End-to-end: 4-step trace [deposit, transfer, withdraw, transfer]"
    , body := do
        -- Workstream §7.6.4 acceptance fixture.
        --   Step 0: ExtendedState.empty
        --   Step 1: deposit r=1 to actor 10, amount 100, depositId 1
        --   Step 2: (transfer; preserves bridge fields)
        --   Step 3: withdraw r=1 from actor 10, amount 30, recipientL1=zero
        --   Step 4: (transfer; preserves bridge fields)
        let s0 := ExtendedState.empty
        -- Apply step 1's bridge effect:
        let bs1 := applyActionToBridgeState s0.bridge (.deposit 1 10 100 1) 0
        let s1 := { s0 with bridge := bs1 }
        -- Step 2 doesn't touch bridge:
        let bs2 := applyActionToBridgeState s1.bridge (.transfer 1 10 20 50) 1
        let s2 := { s1 with bridge := bs2 }
        -- Step 3 inserts a pending withdrawal:
        let bs3 := applyActionToBridgeState s2.bridge
                     (.withdraw 1 10 30 EthAddress.zero) 2
        let s3 := { s2 with bridge := bs3 }
        -- Step 4 doesn't touch bridge:
        let bs4 := applyActionToBridgeState s3.bridge (.transfer 1 50 60 10) 3
        let s4 := { s3 with bridge := bs4 }
        -- Verify the accounting invariant:
        --   totalDeposited s4 1 = 100  (one deposit of 100)
        --   totalWithdrawn s4 1 = 30   (one withdrawal of 30)
        assertEq (expected := (100 : Nat)) (actual := totalDeposited s4 1)
                 "deposits at end of trace"
        assertEq (expected := (30 : Nat))  (actual := totalWithdrawn s4 1)
                 "withdrawals at end of trace"
        -- Verify quantities at intermediate steps:
        assertEq (expected := (100 : Nat)) (actual := totalDeposited s1 1) "after step 1"
        assertEq (expected := (100 : Nat)) (actual := totalDeposited s2 1) "after step 2"
        assertEq (expected := (0 : Nat))   (actual := totalWithdrawn s2 1) "no wd yet"
        assertEq (expected := (30 : Nat))  (actual := totalWithdrawn s3 1) "after step 3"
    }
  , -- Workstream LP / LP.8: declareLocalPolicy/revokeLocalPolicy don't change bridge accounting.
    { name := "applyActionToBridgeState_declareLocalPolicy is identity"
    , body := do
        -- Verify via field projections: nextWdId is unchanged.
        let bs := BridgeState.empty
        let p : Authority.LocalPolicy := { clauses := [.denyTags [0]] }
        let bs' := applyActionToBridgeState bs (.declareLocalPolicy p) 0
        let _proof := applyActionToBridgeState_declareLocalPolicy bs p 0
        assertEq bs.nextWdId bs'.nextWdId "nextWdId unchanged by declareLocalPolicy"
    }
  , { name := "applyActionToBridgeState_revokeLocalPolicy is identity"
    , body := do
        let bs := BridgeState.empty
        let bs' := applyActionToBridgeState bs .revokeLocalPolicy 0
        let _proof := applyActionToBridgeState_revokeLocalPolicy bs 0
        assertEq bs.nextWdId bs'.nextWdId "nextWdId unchanged by revokeLocalPolicy"
    }
  , { name := "accounting_delta_declareLocalPolicy term-level API"
    , body := do
        let _t := @accounting_delta_declareLocalPolicy
        pure ()
    }
  , { name := "accounting_delta_revokeLocalPolicy term-level API"
    , body := do
        let _t := @accounting_delta_revokeLocalPolicy
        pure ()
    }
  ]

end LegalKernel.Test.Bridge.AccountingTests

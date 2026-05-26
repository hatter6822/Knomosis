/-
  Knomosis  - A Societal Kernel
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
  BridgeState.empty.markConsumed 1 ({ resource := 1, userAmount := 100, poolAmount := 0, budgetGrant := 0 })

/-- A bridge state with one deposit + one withdrawal at the same r. -/
def bs2 : BridgeState :=
  bs1.appendWithdrawal
    { resource := 1, recipient := EthAddress.zero, amount := 30, l2LogIndex := 0 }

/-- GP.4.2: a bridge state with one fee-bearing deposit at r=1
    (userAmount 60, poolAmount 40, budgetGrant 9). -/
def bsFee : BridgeState :=
  BridgeState.empty.markConsumed 1
    { resource := 1, userAmount := 60, poolAmount := 40, budgetGrant := 9 }

/-- GP.4.2: a bridge state mixing a legacy deposit (id 1, user 100,
    pool 0) and two fee deposits (id 2: user 30/pool 20 at r=1; id 3:
    user 75/pool 25 at r=2). -/
def bsMixed : BridgeState :=
  (bs1.markConsumed 2
      { resource := 1, userAmount := 30, poolAmount := 20, budgetGrant := 5 }).markConsumed 3
      { resource := 2, userAmount := 75, poolAmount := 25, budgetGrant := 7 }

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
        let bs := bs1.markConsumed 2
          ({ resource := 1, userAmount := 50, poolAmount := 0, budgetGrant := 0 })
        assertEq (expected := (150 : Nat))
                 (actual := totalDeposited (es bs) 1) "150"
    }
  , { name := "totalDeposited: two deposits at different r"
    , body := do
        let bs := bs1.markConsumed 2
          ({ resource := 2, userAmount := 75, poolAmount := 0, budgetGrant := 0 })
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
        let drec : DepositRecord := { resource := 1, userAmount := 100, poolAmount := 0, budgetGrant := 0 }
        assertEq (expected := (100 : Nat)) (actual := drec.amountAt 1) "r=1"
        assertEq (expected := (0 : Nat))   (actual := drec.amountAt 2) "r=2"
    }
  , { name := "DepositRecord.amountAt sums userAmount + poolAmount (GP.4.1)"
    , body := do
        -- A fee-bearing deposit record: the total L2 credit is the
        -- sum of the user and pool legs; budgetGrant is excluded.
        let drec : DepositRecord := { resource := 1, userAmount := 60, poolAmount := 40, budgetGrant := 9 }
        assertEq (expected := (100 : Nat)) (actual := drec.amountAt 1) "60 + 40 = 100"
        assertEq (expected := (0 : Nat))   (actual := drec.amountAt 2) "resource mismatch ⇒ 0"
    }
  , { name := "totalDeposited sums userAmount + poolAmount across fee deposits (GP.4.1)"
    , body := do
        -- One fee-less and one fee-bearing deposit at r=1:
        --   legacy deposit: userAmount 100, poolAmount 0  → 100
        --   fee deposit:    userAmount 30,  poolAmount 20 → 50
        -- totalDeposited r=1 = 150.
        let bs := bs1.markConsumed 2
          ({ resource := 1, userAmount := 30, poolAmount := 20, budgetGrant := 5 })
        assertEq (expected := (150 : Nat)) (actual := totalDeposited (es bs) 1)
          "100 + (30 + 20) = 150"
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
                   bs.markConsumed d ({ resource := r, userAmount := amount, poolAmount := 0, budgetGrant := 0 }) :=
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
  -- ====================================================================
  -- GP.4.2 — accounting-equation split (totalUserDeposited /
  -- totalPoolDeposited), per-action deltas, and pool solvency.
  -- ====================================================================
  , { name := "GP.4.2 totalUserDeposited_genesis: 0 at every resource"
    , body := do
        assertEq (expected := (0 : Nat))
                 (actual := totalUserDeposited ExtendedState.empty 1) "r=1"
        assertEq (expected := (0 : Nat))
                 (actual := totalUserDeposited ExtendedState.empty 2) "r=2"
    }
  , { name := "GP.4.2 totalPoolDeposited_genesis: 0 at every resource"
    , body := do
        assertEq (expected := (0 : Nat))
                 (actual := totalPoolDeposited ExtendedState.empty 1) "r=1"
        assertEq (expected := (0 : Nat))
                 (actual := totalPoolDeposited ExtendedState.empty 2) "r=2"
    }
  , { name := "GP.4.2 DepositRecord.userAmountAt / poolAmountAt project legs"
    , body := do
        let drec : DepositRecord := { resource := 1, userAmount := 60, poolAmount := 40, budgetGrant := 9 }
        assertEq (expected := (60 : Nat)) (actual := drec.userAmountAt 1) "user r=1"
        assertEq (expected := (40 : Nat)) (actual := drec.poolAmountAt 1) "pool r=1"
        assertEq (expected := (0 : Nat))  (actual := drec.userAmountAt 2) "user r=2 ⇒ 0"
        assertEq (expected := (0 : Nat))  (actual := drec.poolAmountAt 2) "pool r=2 ⇒ 0"
    }
  , { name := "GP.4.2 userAmountAt + poolAmountAt = amountAt (per-record split)"
    , body := do
        let drec : DepositRecord := { resource := 1, userAmount := 60, poolAmount := 40, budgetGrant := 9 }
        assertEq (expected := drec.amountAt 1) (actual := drec.userAmountAt 1 + drec.poolAmountAt 1)
          "60 + 40 = amountAt"
        assertEq (expected := drec.amountAt 2) (actual := drec.userAmountAt 2 + drec.poolAmountAt 2)
          "0 + 0 = amountAt (resource mismatch)"
    }
  , { name := "GP.4.2 fee deposit: user leg = userAmount, pool leg = poolAmount"
    , body := do
        assertEq (expected := (60 : Nat)) (actual := totalUserDeposited (es bsFee) 1) "user r=1"
        assertEq (expected := (40 : Nat)) (actual := totalPoolDeposited (es bsFee) 1) "pool r=1"
        assertEq (expected := (100 : Nat)) (actual := totalDeposited (es bsFee) 1) "total r=1"
        assertEq (expected := (0 : Nat))  (actual := totalUserDeposited (es bsFee) 2) "user r=2"
        assertEq (expected := (0 : Nat))  (actual := totalPoolDeposited (es bsFee) 2) "pool r=2"
    }
  , { name := "GP.4.2 legacy deposit: pool leg is 0, user leg is amount"
    , body := do
        assertEq (expected := (100 : Nat)) (actual := totalUserDeposited (es bs1) 1) "user r=1"
        assertEq (expected := (0 : Nat))   (actual := totalPoolDeposited (es bs1) 1) "pool r=1 ⇒ 0"
    }
  , { name := "GP.4.2 split identity holds at value level (mixed deposits)"
    , body := do
        -- bsMixed: r=1 → user (100+30)=130, pool (0+20)=20, total 150
        --          r=2 → user 75, pool 25, total 100
        assertEq (expected := (130 : Nat)) (actual := totalUserDeposited (es bsMixed) 1) "user r=1"
        assertEq (expected := (20 : Nat))  (actual := totalPoolDeposited (es bsMixed) 1) "pool r=1"
        assertEq (expected := (75 : Nat))  (actual := totalUserDeposited (es bsMixed) 2) "user r=2"
        assertEq (expected := (25 : Nat))  (actual := totalPoolDeposited (es bsMixed) 2) "pool r=2"
        -- user + pool = total, per the split identity, at each resource:
        assertEq (expected := totalDeposited (es bsMixed) 1)
                 (actual := totalUserDeposited (es bsMixed) 1 + totalPoolDeposited (es bsMixed) 1)
                 "split r=1"
        assertEq (expected := totalDeposited (es bsMixed) 2)
                 (actual := totalUserDeposited (es bsMixed) 2 + totalPoolDeposited (es bsMixed) 2)
                 "split r=2"
    }
  , { name := "GP.4.2 step delta (depositWithFee) via applyActionToBridgeState"
    , body := do
        -- Apply a fresh fee deposit to the genesis bridge: recipient 10,
        -- poolActor 99, userAmount 60, poolAmount 40, budgetGrant 9, id 1.
        let bs := applyActionToBridgeState BridgeState.empty
                    (.depositWithFee 1 10 99 60 40 9 1) 0
        assertEq (expected := (60 : Nat)) (actual := totalUserDeposited (es bs) 1) "user += 60"
        assertEq (expected := (40 : Nat)) (actual := totalPoolDeposited (es bs) 1) "pool += 40"
        -- Different resource is untouched:
        assertEq (expected := (0 : Nat))  (actual := totalUserDeposited (es bs) 2) "user r=2 untouched"
        assertEq (expected := (0 : Nat))  (actual := totalPoolDeposited (es bs) 2) "pool r=2 untouched"
    }
  , { name := "GP.4.2 step delta (legacy deposit) credits only the user leg"
    , body := do
        let bs := applyActionToBridgeState BridgeState.empty (.deposit 1 10 100 1) 0
        assertEq (expected := (100 : Nat)) (actual := totalUserDeposited (es bs) 1) "user += 100"
        assertEq (expected := (0 : Nat))   (actual := totalPoolDeposited (es bs) 1) "pool unchanged"
    }
  , { name := "GP.4.2 non-bridge action leaves both legs unchanged"
    , body := do
        -- A transfer on top of bsFee must not touch the consumed ledger.
        let bs := applyActionToBridgeState bsFee (.transfer 1 10 20 5) 1
        assertEq (expected := totalUserDeposited (es bsFee) 1)
                 (actual := totalUserDeposited (es bs) 1) "user unchanged"
        assertEq (expected := totalPoolDeposited (es bsFee) 1)
                 (actual := totalPoolDeposited (es bs) 1) "pool unchanged"
    }
  , { name := "GP.4.2 two fee deposits accumulate per leg"
    , body := do
        let bs := bsFee.markConsumed 2
          { resource := 1, userAmount := 10, poolAmount := 5, budgetGrant := 1 }
        assertEq (expected := (70 : Nat)) (actual := totalUserDeposited (es bs) 1) "60 + 10"
        assertEq (expected := (45 : Nat)) (actual := totalPoolDeposited (es bs) 1) "40 + 5"
    }
  , -- Term-level API-stability checks for the GP.4.2 theorems.
    { name := "GP.4.2 userAmountAt_add_poolAmountAt: term-level API"
    , body := do
        let _t : ∀ (rec : DepositRecord) (r : ResourceId),
                   rec.userAmountAt r + rec.poolAmountAt r = rec.amountAt r :=
          DepositRecord.userAmountAt_add_poolAmountAt
        pure ()
    }
  , { name := "GP.4.2 totalUserDeposited_plus_pool_eq_totalDeposited: term-level API"
    , body := do
        let _t : ∀ (es : ExtendedState) (r : ResourceId),
                   totalUserDeposited es r + totalPoolDeposited es r = totalDeposited es r :=
          totalUserDeposited_plus_pool_eq_totalDeposited
        pure ()
    }
  , { name := "GP.4.2 bridge_accounting_equation_balanced: term-level API"
    , body := do
        let _t := @bridge_accounting_equation_balanced
        pure ()
    }
  , { name := "GP.4.2 totalUserDeposited_step_eq / totalPoolDeposited_step_eq: term-level API"
    , body := do
        let _u := @totalUserDeposited_step_eq
        let _p := @totalPoolDeposited_step_eq
        pure ()
    }
  , { name := "GP.4.2 step_eq_deposit (user / pool legacy): term-level API"
    , body := do
        let _u := @totalUserDeposited_step_eq_deposit
        let _p := @totalPoolDeposited_step_eq_deposit
        pure ()
    }
  , { name := "GP.4.2 accounting_userpool_delta_non_bridge: term-level API"
    , body := do
        let _t := @accounting_userpool_delta_non_bridge
        pure ()
    }
  , { name := "GP.4.2 markConsumed deltas (user / pool): term-level API"
    , body := do
        let _u := @totalUserDeposited_markConsumed
        let _p := @totalPoolDeposited_markConsumed
        pure ()
    }
  , { name := "GP.4.2 applyActionToBridgeState_depositWithFee: term-level API"
    , body := do
        let _t : ∀ (bs : BridgeState) (r : ResourceId) (recipient poolActor : ActorId)
                   (ua pa : Amount) (bg : Nat) (d : DepositId) (idx : Nat),
                   applyActionToBridgeState bs
                     (.depositWithFee r recipient poolActor ua pa bg d) idx =
                   bs.markConsumed d
                     { resource := r, userAmount := ua, poolAmount := pa, budgetGrant := bg } :=
          applyActionToBridgeState_depositWithFee
        pure ()
    }
  , { name := "GP.4.2 unchanged_when_bridge_eq (user / pool): term-level API"
    , body := do
        let _u := @totalUserDeposited_unchanged_when_bridge_eq
        let _p := @totalPoolDeposited_unchanged_when_bridge_eq
        pure ()
    }
  , { name := "GP.4.2 depositWithFee_credits_poolActor: term-level API"
    , body := do
        let _t := @depositWithFee_credits_poolActor
        pure ()
    }
  , { name := "GP.4.2 depositWithFee_pool_credit_matches_ledger_delta: term-level API"
    , body := do
        let _t := @depositWithFee_pool_credit_matches_ledger_delta
        pure ()
    }
  , { name := "GP.4.2 pool_balance_eq_totalPoolDeposited_minus_payouts (+ genesis): term-level API"
    , body := do
        let _t := @pool_balance_eq_totalPoolDeposited_minus_payouts
        let _g := @pool_balance_eq_totalPoolDeposited_minus_payouts_genesis
        pure ()
    }
  , { name := "GP.4.2 genesis lemmas (user / pool): term-level API"
    , body := do
        let _u := @totalUserDeposited_genesis
        let _p := @totalPoolDeposited_genesis
        pure ()
    }
  -- --------------------------------------------------------------------
  -- GP.4.2 audit follow-up: withdraw preserves the deposit folds, the
  -- consumed-only dependence, and the atomic admitted-step forms.
  -- --------------------------------------------------------------------
  , { name := "GP.4.2 withdraw preserves both deposit folds (consumed untouched)"
    , body := do
        -- A withdraw appends to `pending`, leaving `consumed` (hence
        -- both deposit folds) unchanged.  Value-level mirror of
        -- accounting_userpool_delta_withdraw.
        let bs := applyActionToBridgeState bsFee (.withdraw 1 10 25 EthAddress.zero) 0
        assertEq (expected := totalUserDeposited (es bsFee) 1)
                 (actual := totalUserDeposited (es bs) 1) "user leg unchanged by withdraw"
        assertEq (expected := totalPoolDeposited (es bsFee) 1)
                 (actual := totalPoolDeposited (es bs) 1) "pool leg unchanged by withdraw"
        -- The withdrawal IS recorded on the pending side:
        assertEq (expected := (25 : Nat)) (actual := totalWithdrawn (es bs) 1)
                 "withdrawal recorded in pending"
    }
  , { name := "GP.4.2 deposit folds depend only on consumed (different pending, same folds)"
    , body := do
        -- Two states with identical `consumed` but different `pending`
        -- agree on both deposit folds.
        let bsA := bsFee
        let bsB := bsFee.appendWithdrawal
          { resource := 1, recipient := EthAddress.zero, amount := 7, l2LogIndex := 0 }
        assertEq (expected := totalUserDeposited (es bsA) 1)
                 (actual := totalUserDeposited (es bsB) 1) "user leg consumed-only"
        assertEq (expected := totalPoolDeposited (es bsA) 1)
                 (actual := totalPoolDeposited (es bsB) 1) "pool leg consumed-only"
    }
  , { name := "GP.4.2 unchanged_when_consumed_eq (user / pool): term-level API"
    , body := do
        let _u := @totalUserDeposited_unchanged_when_consumed_eq
        let _p := @totalPoolDeposited_unchanged_when_consumed_eq
        pure ()
    }
  , { name := "GP.4.2 accounting_userpool_delta_withdraw: term-level API"
    , body := do
        let _t := @accounting_userpool_delta_withdraw
        pure ()
    }
  , { name := "GP.4.2 atomic step deltas over apply_bridge_admissible_with: term-level API"
    , body := do
        let _u := @totalUserDeposited_admissible_depositWithFee
        let _p := @totalPoolDeposited_admissible_depositWithFee
        pure ()
    }
  , { name := "GP.4.2 atomic pool credit + ledger coherence: term-level API"
    , body := do
        let _c := @depositWithFee_admissible_credits_poolActor
        let _m := @depositWithFee_admissible_pool_credit_matches_ledger
        pure ()
    }
  -- --------------------------------------------------------------------
  -- GP.4.2 optimal-closure follow-up: iff-form balanced equation, the
  -- genuine pool-solvency inductive step, and coherence over the literal
  -- budget-gated runtime entry.
  -- --------------------------------------------------------------------
  , { name := "GP.4.2 balanced-equation iff holds at value level (mixed deposits)"
    , body := do
        -- bsMixed r=1: totalDeposited 150, totalWithdrawn 0, split 130+20.
        -- For escrow = 150 both sides of the iff are true; the iff is the
        -- split identity re-expressed against the §15D RHS shape.
        let lhs := totalUserDeposited (es bsMixed) 1 + totalPoolDeposited (es bsMixed) 1
        let rhs := totalWithdrawn (es bsMixed) 1 + 150
        assertEq (expected := rhs) (actual := lhs) "split LHS = totalWithdrawn + 150"
        -- And the legacy side agrees, witnessing the iff's two sides coincide:
        assertEq (expected := rhs) (actual := totalDeposited (es bsMixed) 1)
                 "legacy LHS = totalWithdrawn + 150"
    }
  , { name := "GP.4.2 bridge_accounting_equation_balanced_iff: term-level API"
    , body := do
        let _t : ∀ (es : ExtendedState) (r : ResourceId) (escrow : Nat),
                   (totalUserDeposited es r + totalPoolDeposited es r =
                      totalWithdrawn es r + escrow) ↔
                   (totalDeposited es r = totalWithdrawn es r + escrow) :=
          bridge_accounting_equation_balanced_iff
        pure ()
    }
  , { name := "GP.4.2 pool_solvency_preserved_by_admitted_depositWithFee: term-level API"
    , body := do
        let _t := @pool_solvency_preserved_by_admitted_depositWithFee
        pure ()
    }
  , { name := "GP.4.2 runtime-entry (budget-gated) coherence + agreement lemma: term-level API"
    , body := do
        let _m := @depositWithFee_budget_admitted_pool_credit_matches_ledger
        let _a := @apply_bridge_admissible_with_budget_base_bridge_eq
        pure ()
    }
  ]

end LegalKernel.Test.Bridge.AccountingTests

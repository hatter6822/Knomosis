-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.RefundOnExit — Workstream GP.9.1 acceptance tests.

Drives the refund-on-exit mechanism (`LegalKernel/Bridge/RefundOnExit.lean`)
at the value level plus term-level API stability for every headline
theorem:

  * **`refundAmount` arithmetic.**  Full refund at zero dwell, exact
    amortisation at / past the window, the degenerate zero-window and
    zero-fee cases, mid-window linear decay (with Nat floor), the
    bounded-by-fee guarantee across a sweep, and antitone-in-elapsed.
  * **`refundForDeposit`.**  Reads `(poolAmount, depositTime)` off a
    recorded `DepositRecord`; the dwell-time anchor; bounded by the
    recorded `poolAmount`; zero for a fee-less deposit / past the window.
  * **`applyRefund` over a real `ExtendedState`.**  The
    `gasPoolActor → user` transfer is applied to the bridge ledger's
    looked-up deposit: the pool is debited, the user credited,
    conservation holds, the pool-loss bound holds, an unknown deposit /
    fully-amortised deposit is a no-op.
  * **Term-level API stability** for every headline theorem.
-/

import LegalKernel
import LegalKernel.Bridge.RefundOnExit
import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge
namespace RefundOnExitTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Test

/-! ## Fixtures -/

/-- The ETH-mirror resource the value-level fixtures deposit / refund at. -/
def resEth : ResourceId := 0

/-- A user-range actor (distinct from the reserved `gasPoolActor` = 1 and
    `sequencerActor` = 2). -/
def user : ActorId := 7

/-- A representative recorded deposit: the user paid a `poolAmount = 100`
    gas-pool fee on a deposit applied at L2 log index `depositTime = 3`
    (with a `userAmount = 900` user credit and a `budgetGrant = 50`). -/
def depRec : DepositRecord :=
  { resource := resEth, userAmount := 900, poolAmount := 100,
    budgetGrant := 50, depositTime := 3 }

/-- The deposit id the fixture deposit is recorded under. -/
def depId : DepositId := 42

/-- An `ExtendedState` whose gas pool holds 500 units at `resEth` (from
    accumulated fees) and whose bridge ledger records the fixture
    deposit. -/
def esWithDeposit : ExtendedState :=
  { ExtendedState.empty with
      base   := setBalance ExtendedState.empty.base resEth gasPoolActor 500
      bridge := BridgeState.empty.markConsumed depId depRec }

/-! ## `refundAmount` arithmetic -/

/-- Tests for the refund-on-exit mechanism. -/
def tests : List TestCase :=
  [ { name := "refundAmount: full refund at zero dwell (elapsed = 0)"
    , body := do
        assertEq (expected := (100 : Nat)) (actual := refundAmount 100 0 10) "elapsed 0 ⇒ fee"
        assertEq (expected := (7 : Nat))   (actual := refundAmount 7 0 1)   "window 1, elapsed 0"
    }
  , { name := "refundAmount: fully amortised at exactly the window"
    , body := do
        assertEq (expected := (0 : Nat)) (actual := refundAmount 100 10 10) "elapsed = window ⇒ 0"
    }
  , { name := "refundAmount: fully amortised past the window"
    , body := do
        assertEq (expected := (0 : Nat)) (actual := refundAmount 100 11 10) "elapsed > window ⇒ 0"
        assertEq (expected := (0 : Nat)) (actual := refundAmount 100 1000 10) "elapsed ≫ window ⇒ 0"
    }
  , { name := "refundAmount: degenerate zero window refunds nothing"
    , body := do
        assertEq (expected := (0 : Nat)) (actual := refundAmount 100 0 0) "window 0 ⇒ 0"
        assertEq (expected := (0 : Nat)) (actual := refundAmount 100 5 0) "window 0, elapsed 5 ⇒ 0"
    }
  , { name := "refundAmount: zero fee refunds nothing"
    , body := do
        assertEq (expected := (0 : Nat)) (actual := refundAmount 0 0 10) "fee 0 ⇒ 0"
    }
  , { name := "refundAmount: linear mid-window decay"
    , body := do
        -- half-way through the window ⇒ half the fee.
        assertEq (expected := (50 : Nat)) (actual := refundAmount 100 5 10) "50% dwell ⇒ 50% fee"
        -- one quarter dwell ⇒ three quarters of the fee.
        assertEq (expected := (75 : Nat)) (actual := refundAmount 100 1 4) "25% dwell ⇒ 75% fee"
    }
  , { name := "refundAmount: Nat-floor on non-exact division"
    , body := do
        -- 10 * (3 - 1) / 3 = 20 / 3 = 6 (floor); residue favours the pool.
        assertEq (expected := (6 : Nat)) (actual := refundAmount 10 1 3) "floor(20/3) = 6"
    }
  , { name := "refundAmount: bounded by fee across a sweep"
    , body := do
        for fee in [0, 1, 7, 100, 999999] do
          for elapsed in [0, 1, 5, 10, 50] do
            for window in [0, 1, 3, 10, 100] do
              assert (refundAmount fee elapsed window ≤ fee)
                s!"refundAmount {fee} {elapsed} {window} exceeded fee"
    }
  , { name := "refundAmount: antitone in elapsed (value-level)"
    , body := do
        -- e1 = 3 ≤ e2 = 7 ⇒ refund(7) ≤ refund(3): 30 ≤ 70.
        assertEq (expected := (70 : Nat)) (actual := refundAmount 100 3 10) "refund@3 = 70"
        assertEq (expected := (30 : Nat)) (actual := refundAmount 100 7 10) "refund@7 = 30"
        assert (refundAmount 100 7 10 ≤ refundAmount 100 3 10) "longer dwell ⇒ no larger refund"
    }
    -- === refundForDeposit ===
  , { name := "refundForDeposit: full refund when claimed at deposit time"
    , body := do
        -- now = depositTime = 3 ⇒ elapsed 0 ⇒ full poolAmount 100.
        assertEq (expected := (100 : Nat)) (actual := refundForDeposit depRec 3 10) "elapsed 0 ⇒ 100"
    }
  , { name := "refundForDeposit: half refund half-way through the window"
    , body := do
        -- now 8, depositTime 3 ⇒ elapsed 5, window 10 ⇒ 100 * 5 / 10 = 50.
        assertEq (expected := (50 : Nat)) (actual := refundForDeposit depRec 8 10) "elapsed 5 ⇒ 50"
    }
  , { name := "refundForDeposit: zero past the amortisation window"
    , body := do
        -- now 13, depositTime 3 ⇒ elapsed 10 = window ⇒ 0.
        assertEq (expected := (0 : Nat)) (actual := refundForDeposit depRec 13 10) "elapsed 10 ⇒ 0"
        assertEq (expected := (0 : Nat)) (actual := refundForDeposit depRec 100 10) "elapsed ≫ ⇒ 0"
    }
  , { name := "refundForDeposit: fee-less deposit refunds nothing"
    , body := do
        let feeless : DepositRecord :=
          { resource := resEth, userAmount := 1000, poolAmount := 0,
            budgetGrant := 0, depositTime := 3 }
        assertEq (expected := (0 : Nat)) (actual := refundForDeposit feeless 5 10) "poolAmount 0 ⇒ 0"
    }
  , { name := "refundForDeposit: claim before deposit time is the full fee (clamped)"
    , body := do
        -- now < depositTime ⇒ Nat elapsed = 0 ⇒ full fee (safe over-approx,
        -- still ≤ poolAmount).
        assertEq (expected := (100 : Nat)) (actual := refundForDeposit depRec 1 10) "now < depositTime ⇒ fee"
    }
  , { name := "refundForDeposit: bounded by poolAmount across a sweep"
    , body := do
        for now in [0, 3, 5, 8, 13, 100] do
          for window in [0, 1, 5, 10] do
            assert (refundForDeposit depRec now window ≤ depRec.poolAmount)
              s!"refundForDeposit @ now={now} window={window} exceeded poolAmount"
    }
    -- === applyRefund over a real ExtendedState ===
  , { name := "applyRefund: gasPool → user transfer credits the user (half refund)"
    , body := do
        -- now 8, depositTime 3, window 10 ⇒ refund 50.
        let es' := applyRefund esWithDeposit depId gasPoolActor user 8 10
        assertEq (expected := (50 : Amount))
          (actual := getBalance es'.base resEth user) "user credited 50"
    }
  , { name := "applyRefund: gasPool → user transfer debits the pool (half refund)"
    , body := do
        let es' := applyRefund esWithDeposit depId gasPoolActor user 8 10
        assertEq (expected := (450 : Amount))
          (actual := getBalance es'.base resEth gasPoolActor) "pool debited 50 (500 → 450)"
    }
  , { name := "applyRefund: conserves total supply at the refunded resource"
    , body := do
        let before := TotalSupply esWithDeposit.base resEth
        let es' := applyRefund esWithDeposit depId gasPoolActor user 8 10
        assertEq (expected := before)
          (actual := TotalSupply es'.base resEth) "supply invariant under refund"
    }
  , { name := "applyRefund: full refund at deposit time (elapsed 0)"
    , body := do
        -- now = depositTime = 3 ⇒ refund = poolAmount = 100.
        let es' := applyRefund esWithDeposit depId gasPoolActor user 3 10
        assertEq (expected := (100 : Amount))
          (actual := getBalance es'.base resEth user) "user credited the full fee 100"
        assertEq (expected := (400 : Amount))
          (actual := getBalance es'.base resEth gasPoolActor) "pool debited 100 (500 → 400)"
    }
  , { name := "applyRefund: fully-amortised deposit is a no-op"
    , body := do
        -- now 13, elapsed 10 = window ⇒ refund 0 ⇒ transfer pre fails ⇒ no-op.
        let es' := applyRefund esWithDeposit depId gasPoolActor user 13 10
        assertEq (expected := (0 : Amount))
          (actual := getBalance es'.base resEth user) "user uncredited"
        assertEq (expected := (500 : Amount))
          (actual := getBalance es'.base resEth gasPoolActor) "pool unchanged"
    }
  , { name := "applyRefund: unknown deposit id is a no-op"
    , body := do
        -- depositId 999 is not in the ledger ⇒ no transfer ⇒ balances unchanged.
        let es' := applyRefund esWithDeposit 999 gasPoolActor user 8 10
        assertEq (expected := (500 : Amount))
          (actual := getBalance es'.base resEth gasPoolActor) "pool unchanged"
        assertEq (expected := (0 : Amount))
          (actual := getBalance es'.base resEth user) "user uncredited"
        assertEq (expected := esWithDeposit.bridge.nextWdId)
          (actual := es'.bridge.nextWdId) "bridge ledger untouched"
    }
  , { name := "applyRefund: refund never exceeds the recorded poolAmount (pool-loss bound)"
    , body := do
        -- Across the window, the pool's loss is at most poolAmount = 100.
        for now in [3, 5, 8, 13, 100] do
          let es' := applyRefund esWithDeposit depId gasPoolActor user now 10
          let poolAfter := getBalance es'.base resEth gasPoolActor
          assert (500 - poolAfter ≤ depRec.poolAmount)
            s!"pool lost more than poolAmount at now={now}"
    }
    -- === Term-level API stability ===
  , { name := "refundAmount_le_fee: term-level API"
    , body := do
        let _t : ∀ (fee elapsed window : Nat),
                   refundAmount fee elapsed window ≤ fee :=
          refundAmount_le_fee
        pure ()
    }
  , { name := "refundAmount_eq_fee_of_elapsed_zero: term-level API"
    , body := do
        let _t : ∀ (fee window : Nat), 0 < window →
                   refundAmount fee 0 window = fee :=
          refundAmount_eq_fee_of_elapsed_zero
        pure ()
    }
  , { name := "refundAmount_zero_of_elapsed_ge_window: term-level API"
    , body := do
        let _t : ∀ (fee elapsed window : Nat), window ≤ elapsed →
                   refundAmount fee elapsed window = 0 :=
          refundAmount_zero_of_elapsed_ge_window
        pure ()
    }
  , { name := "refundAmount_antitone_in_elapsed: term-level API"
    , body := do
        let _t : ∀ (fee window e₁ e₂ : Nat), e₁ ≤ e₂ →
                   refundAmount fee e₂ window ≤ refundAmount fee e₁ window :=
          refundAmount_antitone_in_elapsed
        pure ()
    }
  , { name := "refundAmount_monotone_in_fee: term-level API"
    , body := do
        let _t : ∀ (f₁ f₂ elapsed window : Nat), f₁ ≤ f₂ →
                   refundAmount f₁ elapsed window ≤ refundAmount f₂ elapsed window :=
          refundAmount_monotone_in_fee
        pure ()
    }
  , { name := "refundForDeposit_le_poolAmount: term-level API"
    , body := do
        let _t : ∀ (rec : DepositRecord) (now window : Nat),
                   refundForDeposit rec now window ≤ rec.poolAmount :=
          refundForDeposit_le_poolAmount
        pure ()
    }
  , { name := "refundForDeposit_zero_of_fully_amortised: term-level API"
    , body := do
        let _t : ∀ (rec : DepositRecord) (now window : Nat),
                   window ≤ now - rec.depositTime →
                   refundForDeposit rec now window = 0 :=
          refundForDeposit_zero_of_fully_amortised
        pure ()
    }
  , { name := "refundTransition_conserves: term-level API"
    , body := do
        let _t : ∀ (rec : DepositRecord) (poolActor recipient : ActorId)
                   (now window : Nat) (s : State),
                   (refundTransition rec poolActor recipient now window).pre s →
                   TotalSupply
                     (step_impl s (refundTransition rec poolActor recipient now window))
                     rec.resource = TotalSupply s rec.resource :=
          refundTransition_conserves
        pure ()
    }
  , { name := "refund_credits_recipient: term-level API"
    , body := do
        let _t := @refund_credits_recipient
        pure ()
    }
  , { name := "refund_debits_pool: term-level API"
    , body := do
        let _t := @refund_debits_pool
        pure ()
    }
  , { name := "applyRefund_conserves: term-level API"
    , body := do
        let _t : ∀ (es : ExtendedState) (depositId : DepositId)
                   (poolActor recipient : ActorId) (now window : Nat) (r : ResourceId),
                   TotalSupply (applyRefund es depositId poolActor recipient now window).base r
                     = TotalSupply es.base r :=
          applyRefund_conserves
        pure ()
    }
  , { name := "applyRefund_pool_balance_lower_bound: term-level API"
    , body := do
        let _t := @applyRefund_pool_balance_lower_bound
        pure ()
    }
  , { name := "applyRefund_credits_recipient: term-level API"
    , body := do
        let _t := @applyRefund_credits_recipient
        pure ()
    }
  , { name := "applyRefund_unknown_deposit: term-level API"
    , body := do
        let _t : ∀ (es : ExtendedState) (depositId : DepositId)
                   (poolActor recipient : ActorId) (now window : Nat),
                   es.bridge.consumed[depositId]? = none →
                   applyRefund es depositId poolActor recipient now window = es :=
          applyRefund_unknown_deposit
        pure ()
    }
  ]

end RefundOnExitTests
end LegalKernel.Test.Bridge

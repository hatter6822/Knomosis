/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.AbsentCellCreation — API + value-level
tests for the per-Action-variant absent-cell creation theorems.
-/

import LegalKernel.FaultProof.AbsentCellCreation
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.AbsentCellCreation

/-- Tests for #261 per-Action absent-cell creation. -/
def tests : List TestCase :=
  [ { name := "#261.mint API stable"
    , body := do
        let _ := @mint_creates_balance_cell
        assert true "API exists"
    }
  , { name := "#261.reward API stable"
    , body := do
        let _ := @reward_creates_balance_cell
        assert true "API exists"
    }
  , { name := "#261.deposit API stable"
    , body := do
        let _ := @deposit_creates_balance_cell
        assert true "API exists"
    }
  , { name := "#261.transfer API stable"
    , body := do
        let _ := @transfer_credits_receiver_from_fresh_actor
        assert true "API exists"
    }
  , { name := "#261.mint value-level: minting to fresh actor creates balance"
    , body := do
        let s : LegalKernel.State := { balances := Std.TreeMap.empty }
        let h_absent : getBalance s 1 10 = 0 := rfl
        let result := getBalance ((Laws.mint 1 10 42).apply_impl s) 1 10
        assertEq (expected := 42) (actual := result)
          "mint creates balance with the minted amount"
        let _proof :
            getBalance ((Laws.mint 1 10 42).apply_impl s) 1 10 = 42 :=
          mint_creates_balance_cell s 1 10 42 h_absent
        assert true "theorem holds at value level"
    }
  , { name := "#261.transfer value-level: transfer to fresh receiver credits amount"
    , body := do
        -- Start: actor 10 has 100 at resource 1, actor 20 has 0.
        let s₀ : LegalKernel.State := { balances := Std.TreeMap.empty }
        let s : LegalKernel.State := setBalance s₀ 1 10 100
        -- Sender ≠ receiver, receiver's balance is 0.
        let h_distinct : (10 : ActorId) ≠ 20 := by decide
        let h_receiver_absent : getBalance s 1 20 = 0 := by
          show getBalance (setBalance s₀ 1 10 100) 1 20 = 0
          rw [getBalance_setBalance_other s₀ 1 1 10 20 100 (Or.inr (by decide))]
          rfl
        let result :=
          getBalance ((Laws.transfer 1 10 20 5).apply_impl s) 1 20
        assertEq (expected := 5) (actual := result)
          "transfer to fresh receiver credits the amount"
        let _proof :=
          transfer_credits_receiver_from_fresh_actor
            s 1 10 20 5 h_distinct h_receiver_absent
        assert true "theorem holds at value level"
    }
  ]

end LegalKernel.Test.FaultProof.AbsentCellCreation

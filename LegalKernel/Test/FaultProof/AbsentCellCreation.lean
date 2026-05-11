/-
  Canon  - A Societal Kernel
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
  ]

end LegalKernel.Test.FaultProof.AbsentCellCreation

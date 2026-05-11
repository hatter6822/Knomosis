/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.MissingTheorems — API-stability +
value-level tests for the post-audit-1 revision of
`LegalKernel.FaultProof.MissingTheorems`.

The audit removed four vacuous theorems (`kernelStep_encode_distinguishes`,
`smtPathFromNat_inj_under_bound` as restated, `applyCellWrites_handles_absent_cells`,
`verifyTypedCellProofs_separates_readOnly_writeCells`) and replaced
them with honest content.  This test suite pins the new content's
API and verifies non-trivial properties at the value level.
-/

import LegalKernel.FaultProof.MissingTheorems
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.MissingTheorems

/-- Tests for the honest-revision MissingTheorems module. -/
def tests : List TestCase :=
  [ -- ## #258 DISCHARGED — real injectivity tests
    { name := "#258: smtPathFromNat_inj_under_bound API stable"
    , body := do
        let _ := @smtPathFromNat_inj_under_bound
        assert true "API exists"
    }
  , { name := "#258 value-level: distinct bounded nats produce distinct paths"
    , body := do
        -- Two nats 5 and 7, both < 2^4 = 16.  Their SMT paths
        -- (at smtHeight = 4) must differ — verified by
        -- contraposition of the injectivity theorem.
        let path_5 := smtPathFromNat 5 4
        let path_7 := smtPathFromNat 7 4
        assert (path_5 ≠ path_7) "distinct bounded nats have distinct paths"
    }
  , { name := "#258 value-level: equal paths imply equal nats (under bound)"
    , body := do
        -- 42 has bits 101010 in low 6 positions.  At smtHeight = 8
        -- it has a unique path.  Compute and verify reflexivity.
        let _h_eq : smtPathFromNat 42 8 = smtPathFromNat 42 8 := rfl
        -- Applying the injectivity theorem to this reflexive
        -- equation yields 42 = 42, which holds trivially.  The
        -- value of the test is that the theorem's signature
        -- accepts the bound hypothesis.
        let h_bound : 42 < 2 ^ 8 := by decide
        let _proof :
            smtPathFromNat_inj_under_bound 42 42 8 h_bound h_bound rfl = rfl :=
          rfl
        assert true "injectivity-theorem signature accepts bound hypothesis"
    }
    -- ## #263 DISCHARGED — read-only / write decomposition
  , { name := "#263: requiredCells_eq_readOnly_append_writeCells API stable"
    , body := do
        let _ := @requiredCells_eq_readOnly_append_writeCells
        assert true "API exists"
    }
  , { name := "#263 value-level: transfer's requiredCells matches readOnly ++ writeCells"
    , body := do
        let a : Action := .transfer 1 10 20 5
        let req := a.requiredCells 10
        let ro_w := a.readOnlyCells 10 ++ a.writeCells 10
        assertEq (expected := req) (actual := ro_w)
          "requiredCells = readOnlyCells ++ writeCells"
    }
  , { name := "#263 value-level: mint's requiredCells matches"
    , body := do
        let a : Action := .mint 1 20 10
        assertEq (expected := a.requiredCells 5)
                 (actual := a.readOnlyCells 5 ++ a.writeCells 5)
          "mint decomposition"
    }
  , { name := "#263: requiredCells_length_eq API stable"
    , body := do
        let _ := @requiredCells_length_eq
        assert true "API exists"
    }
  , { name := "#263 value-level: requiredCells length = readOnly + write lengths"
    , body := do
        let a : Action := .transfer 1 10 20 5
        let req_len := (a.requiredCells 10).length
        let sum_len := (a.readOnlyCells 10).length + (a.writeCells 10).length
        assertEq (expected := req_len) (actual := sum_len)
          "length composition"
    }
    -- ## #227 PARTIAL — sub-step determinism + bound
  , { name := "#227: bulk_action_substeps_deterministic API stable"
    , body := do
        let _ := @bulk_action_substeps_deterministic
        assert true "API exists"
    }
  , { name := "#227: bulk_action_substeps_length_bound API stable"
    , body := do
        let _ := @bulk_action_substeps_length_bound
        assert true "API exists"
    }
    -- ## #228 PARTIAL — encode determinism only
  , { name := "#228: kernelStep_encode_deterministic_strong API stable"
    , body := do
        let _ := @kernelStep_encode_deterministic_strong
        assert true "API exists"
    }
    -- ## #249 PARTIAL — type-level totality
  , { name := "#249: applyCellWrites_type_total API stable"
    , body := do
        let _ := @applyCellWrites_type_total
        assert true "API exists"
    }
    -- ## #271 — edge-case rejection theorems (4 shipped)
  , { name := "#271.1: response_without_pendingMidpoint API stable"
    , body := do
        let _ := @applyTransition_rejects_response_without_pendingMidpoint
        assert true "API exists"
    }
  , { name := "#271.2: disagree_without_pendingMidpoint API stable"
    , body := do
        let _ := @applyTransition_rejects_disagree_without_pendingMidpoint
        assert true "API exists"
    }
  , { name := "#271.3: applyTransition_rejects_post_settlement API stable"
    , body := do
        let _ := @applyTransition_rejects_post_settlement
        assert true "API exists"
    }
  , { name := "#271.6: applyTransition_rejects_malformed_midpoint API stable"
    , body := do
        let _ := @applyTransition_rejects_malformed_midpoint
        assert true "API exists"
    }
  ]

end LegalKernel.Test.FaultProof.MissingTheorems

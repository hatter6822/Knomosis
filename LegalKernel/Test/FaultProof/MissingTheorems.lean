/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.MissingTheorems — API stability tests
for the supplemental theorems #213 / #227 / #228 / #229 / #249 /
#258 / #261 / #263 / #271.* / #272.
-/

import LegalKernel.FaultProof.MissingTheorems
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.MissingTheorems

/-- API-stability tests for the supplemental Workstream-H
    theorems landed in `MissingTheorems.lean`. -/
def tests : List TestCase :=
  [ { name := "#213: commitState_after_setBalance_deterministic API stable"
    , body := do
        let _ := @commitState_after_setBalance_deterministic
        assert true "API exists"
    }
  , { name := "#213: commitState_after_setBalance_extensional API stable"
    , body := do
        let _ := @commitState_after_setBalance_extensional
        assert true "API exists"
    }
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
  , { name := "#228: kernelStep_encode_deterministic_strong API stable"
    , body := do
        let _ := @kernelStep_encode_deterministic_strong
        assert true "API exists"
    }
  , { name := "#229: kernelStep_encode_distinguishes API stable"
    , body := do
        let _ := @kernelStep_encode_distinguishes
        assert true "API exists"
    }
  , { name := "#249: applyCellWrites_total API stable"
    , body := do
        let _ := @applyCellWrites_total
        assert true "API exists"
    }
  , { name := "#258: smtPathFromNat_inj_under_bound API stable"
    , body := do
        let _ := @smtPathFromNat_inj_under_bound
        assert true "API exists"
    }
  , { name := "#261: applyCellWrites_handles_absent_cells API stable"
    , body := do
        let _ := @applyCellWrites_handles_absent_cells
        assert true "API exists"
    }
  , { name := "#263: verifyTypedCellProofs_separates_readOnly_writeCells API stable"
    , body := do
        let _ := @verifyTypedCellProofs_separates_readOnly_writeCells
        assert true "API exists"
    }
  , { name := "#271.1: applyTransition_rejects_response_without_pendingMidpoint API stable"
    , body := do
        let _ := @applyTransition_rejects_response_without_pendingMidpoint
        assert true "API exists"
    }
  , { name := "#271.2: applyTransition_rejects_disagree_without_pendingMidpoint API stable"
    , body := do
        let _ := @applyTransition_rejects_disagree_without_pendingMidpoint
        assert true "API exists"
    }
  , { name := "#271.3: applyTransition_rejects_post_settlement API stable"
    , body := do
        let _ := @applyTransition_rejects_post_settlement
        assert true "API exists"
    }
  , { name := "#271.4: applyTransition_total API stable"
    , body := do
        let _ := @applyTransition_total
        assert true "API exists"
    }
  , { name := "#271.5: applyTransition_deterministic_edge API stable"
    , body := do
        let _ := @applyTransition_deterministic_edge
        assert true "API exists"
    }
  , { name := "#271.6: applyTransition_rejects_malformed_midpoint API stable"
    , body := do
        let _ := @applyTransition_rejects_malformed_midpoint
        assert true "API exists"
    }
  , { name := "#272: gameState_encode_deterministic_strong API stable"
    , body := do
        let _ := @gameState_encode_deterministic_strong
        assert true "API exists"
    }
  ]

end LegalKernel.Test.FaultProof.MissingTheorems

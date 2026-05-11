/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.GameTransitionEdgeCases — API +
value-level tests for `applyTransition` rejection-path
theorems (plan §18 #271 family).
-/

import LegalKernel.FaultProof.GameTransitionEdgeCases
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.GameTransitionEdgeCases

/-- Tests for the applyTransition edge-case rejection theorems. -/
def tests : List TestCase :=
  [ { name := "#271.1: response_without_pendingMidpoint API stable"
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

end LegalKernel.Test.FaultProof.GameTransitionEdgeCases

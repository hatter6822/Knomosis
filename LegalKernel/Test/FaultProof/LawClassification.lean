/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.LawClassification — instance-resolution
checks for the two new fault-proof Action constructors.
-/

import LegalKernel.FaultProof.LawClassification
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.LawClassification

/-- Tests that the two new Action constructors classify correctly
    as both `IsConservative` and `IsMonotonic`.

    We invoke instance resolution against the inline-constructed
    `Action` values rather than `private def` fixtures, because
    the `private def` would block typeclass resolution from
    seeing the constructor head. -/
def tests : List TestCase :=
  [ { name := "Action.faultProofChallenge compiles to freezeResource 0"
    , body := do
        let _ :
            Action.compileTransition
              (.faultProofChallenge ByteArray.empty 0 0 ByteArray.empty)
            = Laws.freezeResource 0 :=
          faultProofChallenge_compileTransition_eq_freezeResource_zero
            ByteArray.empty 0 0 ByteArray.empty
        pure ()
    }
  , { name := "Action.faultProofResolution compiles to freezeResource 0"
    , body := do
        let _ :
            Action.compileTransition
              (.faultProofResolution ByteArray.empty 1 1 0)
            = Laws.freezeResource 0 :=
          faultProofResolution_compileTransition_eq_freezeResource_zero
            ByteArray.empty 1 1 0
        pure ()
    }
  , { name := "faultProofChallenge_compiled_isConservative resolves"
    , body := do
        -- Force typeclass resolution at the value level.
        let _ :
            IsConservative
              (Action.compileTransition
                (.faultProofChallenge ByteArray.empty 0 0 ByteArray.empty)) :=
          inferInstance
        pure ()
    }
  , { name := "faultProofResolution_compiled_isConservative resolves"
    , body := do
        let _ :
            IsConservative
              (Action.compileTransition
                (.faultProofResolution ByteArray.empty 1 1 0)) :=
          inferInstance
        pure ()
    }
  , { name := "faultProofChallenge_compiled_isMonotonic resolves"
    , body := do
        let _ :
            IsMonotonic
              (Action.compileTransition
                (.faultProofChallenge ByteArray.empty 0 0 ByteArray.empty)) :=
          inferInstance
        pure ()
    }
  , { name := "faultProofResolution_compiled_isMonotonic resolves"
    , body := do
        let _ :
            IsMonotonic
              (Action.compileTransition
                (.faultProofResolution ByteArray.empty 1 1 0)) :=
          inferInstance
        pure ()
    }
  , { name := "fault_proof_pipeline_actions_classification API stability"
    , body := do
        -- Term-level stability check — the theorem signature must hold.
        let _proof :=
          @fault_proof_pipeline_actions_classification
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.LawClassification

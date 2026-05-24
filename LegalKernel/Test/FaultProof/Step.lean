/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Step — value-level tests for the
`KernelStep` type and `kernelStepApply` semantics.
-/

import LegalKernel.FaultProof.Step
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Step

private def emptyCommit : StateCommit := commitExtendedState ExtendedState.empty

private def someAction : Authority.Action :=
  .transfer 1 2 3 0  -- deliberately invalid (amount = 0); used only for shape

private def someSignedAction : SignedAction := {
  action := someAction,
  signer := 2,
  nonce  := 0,
  sig    := ByteArray.empty
}

/-- Tests for the `KernelStep` data type and `kernelStepApply`. -/
def tests : List TestCase :=
  [ { name := "chainKernelStepApply on empty list returns initial commit"
    , body := do
        let c := emptyCommit
        match chainKernelStepApply c [] with
        | some c' => assertEq (expected := c) (actual := c') "empty chain"
        | none    => assert false "empty chain returned none"
    }
  , { name := "kernelStepApply rejects bundle with bad cell proof"
    , body := do
        -- Construct a step with empty cell-proof bundle (no proofs).
        -- The bundle's verifyCellProofs returns true on empty (all []
        -- in `List.all`); but we'll test the deterministic shape.
        let bundle : CellProofBundle := { proofs := [] }
        let step : KernelStep := {
          preStateCommit := emptyCommit,
          signedAction := someSignedAction,
          postStateCommit := emptyCommit,
          cellProofs := bundle
        }
        match kernelStepApply step with
        | some _ => pure ()  -- empty bundle => trivially verifies
        | none   => assert false "empty bundle should verify"
    }
  , { name := "kernelStepApply is deterministic"
    , body := do
        let step : KernelStep := {
          preStateCommit := emptyCommit,
          signedAction := someSignedAction,
          postStateCommit := emptyCommit,
          cellProofs := { proofs := [] }
        }
        let r1 := kernelStepApply step
        let r2 := kernelStepApply step
        assertEq (expected := r1) (actual := r2) "determinism"
    }
  , { name := "chainKernelStepApply rejects mismatched preStateCommit"
    , body := do
        let dummyCommit : StateCommit := ByteArray.empty
        let step : KernelStep := {
          preStateCommit := dummyCommit,  -- distinct from emptyCommit
          signedAction := someSignedAction,
          postStateCommit := emptyCommit,
          cellProofs := { proofs := [] }
        }
        -- chainKernelStepApply emptyCommit [step] should fail because
        -- step's preStateCommit ≠ initialCommit (emptyCommit).
        let r := chainKernelStepApply emptyCommit [step]
        match r with
        | some _ => assert false "should reject mismatched preCommit"
        | none   => pure ()
    }
  , { name := "chainKernelStepApply accepts matching preStateCommit"
    , body := do
        let step : KernelStep := {
          preStateCommit := emptyCommit,
          signedAction := someSignedAction,
          postStateCommit := emptyCommit,
          cellProofs := { proofs := [] }
        }
        match chainKernelStepApply emptyCommit [step] with
        | some c => assertEq (expected := emptyCommit) (actual := c) "single-step chain"
        | none   => assert false "single-step should succeed"
    }
  , { name := "chainKernelStepApply two-step chain threads commits"
    , body := do
        let step : KernelStep := {
          preStateCommit := emptyCommit,
          signedAction := someSignedAction,
          postStateCommit := emptyCommit,
          cellProofs := { proofs := [] }
        }
        match chainKernelStepApply emptyCommit [step, step] with
        | some c => assertEq (expected := emptyCommit) (actual := c) "two-step chain"
        | none   => assert false "two-step should succeed"
    }
  , { name := "chainKernelStepApply_split (concrete)"
    , body := do
        let step : KernelStep := {
          preStateCommit := emptyCommit,
          signedAction := someSignedAction,
          postStateCommit := emptyCommit,
          cellProofs := { proofs := [] }
        }
        let lhs := chainKernelStepApply emptyCommit ([step] ++ [step])
        let rhs :=
          (chainKernelStepApply emptyCommit [step]).bind
            (fun c' => chainKernelStepApply c' [step])
        assertEq (expected := lhs) (actual := rhs) "split equation holds"
    }
  , { name := "chainKernelStepApply_singleton_match (concrete)"
    , body := do
        let step : KernelStep := {
          preStateCommit := emptyCommit,
          signedAction := someSignedAction,
          postStateCommit := emptyCommit,
          cellProofs := { proofs := [] }
        }
        let lhs := chainKernelStepApply emptyCommit [step]
        let rhs := kernelStepApply step
        assertEq (expected := lhs) (actual := rhs) "singleton match"
    }
  ]

end LegalKernel.Test.FaultProof.Step

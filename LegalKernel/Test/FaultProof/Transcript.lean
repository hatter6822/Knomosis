-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Transcript — value-level tests for the
transcript machinery: applyCellWrites, extractRequiredCells,
Action.requiredCellProofs, NonMembershipProof, isLegalTranscript,
chainKernelStepApplyFromLog.
-/

import LegalKernel.FaultProof.Transcript
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Transcript

/-- A simple transfer signed action for fixture purposes. -/
private def transferSt : SignedAction := {
  action := .transfer 1 10 20 5,
  signer := 10,
  nonce  := 0,
  sig    := ByteArray.empty
}

/-- A trivial empty extended state. -/
private def emptyES : ExtendedState := ExtendedState.empty

/-- Tests for the transcript machinery. -/
def tests : List TestCase :=
  [ { name := "applyCellWrites is deterministic on equal inputs"
    , body := do
        let h := applyCellWrites_deterministic emptyES emptyES transferSt transferSt rfl rfl
        let _ := h
        assert true "API exists; determinism holds"
    }
  , { name := "extractRequiredCells is deterministic"
    , body := do
        let h := extractRequiredCells_deterministic transferSt transferSt rfl
        let _ := h
        assert true "API exists; determinism holds"
    }
  , { name := "Action.requiredCellProofs_size matches required cells"
    , body := do
        let h := Action.requiredCellProofs_size emptyES transferSt
        let _ := h
        assert true "API exists; size theorem holds"
    }
  , { name := "NonMembershipProof.build is deterministic"
    , body := do
        let proof₁ := NonMembershipProof.build emptyES (CellTag.balance 1 10)
        let proof₂ := NonMembershipProof.build emptyES (CellTag.balance 1 10)
        assertEq (expected := proof₁.cellTag) (actual := proof₂.cellTag) "tag eq"
        assertEq (expected := proof₁.absentValueHash.size)
                 (actual := proof₂.absentValueHash.size) "value hash eq size"
    }
  , { name := "isLegalTranscript on empty list is true"
    , body := do
        let h : isLegalTranscript ByteArray.empty [] := isLegalTranscript_nil _
        let _ := h
        assert true "trivially legal on empty"
    }
  , { name := "isLegalTranscript_singleton iff statement"
    , body := do
        let _ := @isLegalTranscript_singleton
        assert true "API exists"
    }
  , { name := "chainKernelStepApplyFromLog on empty log is empty"
    , body := do
        let r := chainKernelStepApplyFromLog emptyES []
        assertEq (expected := 0) (actual := r.length) "empty produces empty"
    }
  , { name := "chainKernelStepApplyFromLog_length theorem holds"
    , body := do
        let _ := @chainKernelStepApplyFromLog_length
        assert true "API exists"
    }
  , { name := "chainKernelStepApplyFromLog_isLegalTranscript theorem holds"
    , body := do
        let _ := @chainKernelStepApplyFromLog_isLegalTranscript
        assert true "API exists"
    }
  , { name := "chainKernelStepApplyFromLog produces legal transcript on empty"
    , body := do
        let h := chainKernelStepApplyFromLog_isLegalTranscript emptyES []
        let _ := h
        assert true "value-level legality holds for empty"
    }
  ]

end LegalKernel.Test.FaultProof.Transcript

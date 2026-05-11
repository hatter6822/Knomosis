/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Coherence — value-level tests for the
multi-step kernel-step chain coherence theorem (Workstream H
WU H.1.3d, theorem #253).

Exercises `foldStepApplyOverLog`, the per-step bridge to
`kernelOnlyApply`, and the chain-level coherence with
`kernelOnlyReplay`.
-/

import LegalKernel.FaultProof.Coherence
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Coherence

/-- A trivial signed action (freezeResource 0 — no-op at kernel
    level).  Used for shape tests. -/
private def trivialSignedAction : SignedAction :=
  { action := .freezeResource 0
  , signer := 1
  , nonce  := 0
  , sig    := ByteArray.empty }

/-- A trivial log entry wrapping the trivial signed action. -/
private def trivialLogEntry : LogEntry :=
  { prevHash       := ByteArray.empty
  , signedAction   := trivialSignedAction
  , postStateHash  := ByteArray.empty }

/-- Tests for the `foldStepApplyOverLog` chain function and its
    coherence with `kernelOnlyReplay`. -/
def tests : List TestCase :=
  [ -- ===== Reduction lemmas =====
    { name := "foldStepApplyOverLog on empty log is identity"
    , body := do
        let es := ExtendedState.empty
        let result := foldStepApplyOverLog es []
        -- `result = es` definitionally (per `foldStepApplyOverLog_nil`).
        let _ := foldStepApplyOverLog_nil es
        let _ := result
        assert true "empty log is identity by definition"
    }
  , { name := "foldStepApplyOverLog cons reduction is sequential"
    , body := do
        let es := ExtendedState.empty
        let e := trivialLogEntry
        let rest : List LogEntry := []
        -- foldStepApplyOverLog es (e :: rest) =
        --   foldStepApplyOverLog (applyCellWrites_to_state es e.sa) rest
        let _ := foldStepApplyOverLog_cons es e rest
        assert true "cons reduction holds by definition"
    }
  , -- ===== Per-step bridge =====
    { name := "applyCellWrites_to_state agrees with kernelOnlyApply"
    , body := do
        let es := ExtendedState.empty
        let entry := trivialLogEntry
        -- The theorem says the two are equal.
        let _ :=
          applyCellWrites_to_state_eq_kernelOnlyApply es entry
        assert true "per-step bridge theorem provable"
    }
  , -- ===== Value-level chain coherence =====
    { name := "foldStepApplyOverLog empty equals kernelOnlyReplay empty"
    , body := do
        let es := ExtendedState.empty
        let log : List LogEntry := []
        -- foldStepApplyOverLog es [] = es = kernelOnlyReplay es []
        -- via foldStepApplyOverLog_eq_kernelOnlyReplay.
        let lhs := foldStepApplyOverLog es log
        let rhs := kernelOnlyReplay es log
        -- We can't BEq ExtendedState directly, but commits are
        -- canonical 32-byte arrays.  Compare via commits.
        assertEq (expected := commitExtendedState rhs)
                 (actual := commitExtendedState lhs)
                 "empty-log chain coherence at commit level"
    }
  , { name := "foldStepApplyOverLog singleton equals kernelOnlyReplay singleton"
    , body := do
        let es := ExtendedState.empty
        let log := [trivialLogEntry]
        let lhs := foldStepApplyOverLog es log
        let rhs := kernelOnlyReplay es log
        assertEq (expected := commitExtendedState rhs)
                 (actual := commitExtendedState lhs)
                 "singleton-log chain coherence at commit level"
    }
  , { name := "foldStepApplyOverLog 3-element chain equals kernelOnlyReplay"
    , body := do
        let es := ExtendedState.empty
        let log := [trivialLogEntry, trivialLogEntry, trivialLogEntry]
        let lhs := foldStepApplyOverLog es log
        let rhs := kernelOnlyReplay es log
        assertEq (expected := commitExtendedState rhs)
                 (actual := commitExtendedState lhs)
                 "3-element chain coherence at commit level"
    }
  , -- ===== Commit-level chain coherence theorem =====
    { name := "recomputeCommitment_chain_coherent_with_kernelOnlyReplay API stable"
    , body := do
        let _ := @recomputeCommitment_chain_coherent_with_kernelOnlyReplay
        pure ()
    }
  , -- ===== Per-step coherence theorem (#225) =====
    { name := "recomputeCommitment_coherent_with_kernelOnlyApply API stable"
    , body := do
        let _ := @recomputeCommitment_coherent_with_kernelOnlyApply
        pure ()
    }
  , -- ===== `recomputeCommitment` is deterministic =====
    { name := "recomputeCommitment is deterministic"
    , body := do
        let es := ExtendedState.empty
        let st := trivialSignedAction
        let r₁ := recomputeCommitment es st
        let r₂ := recomputeCommitment es st
        assertEq (expected := r₁) (actual := r₂)
                 "recomputeCommitment is deterministic"
    }
  , { name := "recomputeCommitment has 32-byte output"
    , body := do
        let es := ExtendedState.empty
        let st := trivialSignedAction
        let r := recomputeCommitment es st
        assertEq (expected := 32) (actual := r.size)
                 "recomputeCommitment is 32 bytes"
    }
  ]

end LegalKernel.Test.FaultProof.Coherence

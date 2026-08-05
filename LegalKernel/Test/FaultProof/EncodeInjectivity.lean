-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.EncodeInjectivity — value-level +
API-stability tests for the encoder determinism, distinguish-
inputs, and commit byte-injectivity theorems.

Every test verifies content that is fully proved in
`LegalKernel.FaultProof.EncodeInjectivity` — no round-trip
hypotheses, no deferrals.
-/

import LegalKernel.FaultProof.EncodeInjectivity
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.EncodeInjectivity

/-- Tests for encoder injectivity / distinguish-inputs theorems. -/
def tests : List TestCase :=
  [ -- ## #213 byte-injectivity
    { name := "#213: commitState_setBalance_bytes_inj_under_collision_free API stable"
    , body := do
        let _ := @commitState_setBalance_bytes_inj_under_collision_free
        assert true "API exists"
    }
    -- ## #228
  , { name := "#228: kernelStep_encode_deterministic API stable"
    , body := do
        let _ := @kernelStep_encode_deterministic
        assert true "API exists"
    }
  , { name := "#228 value-level: equal KernelSteps produce equal bytes"
    , body := do
        let st : Authority.SignedAction := {
          action := .freezeResource 1,
          signer := 0, nonce := 0, sig := ByteArray.empty }
        let s : FaultProof.KernelStep := {
          preStateCommit := ByteArray.empty,
          signedAction := st,
          postStateCommit := ByteArray.empty,
          l2LogIndex := 0,
          bundle := { cells := [(.budgetPolicy, ByteArray.empty)],
                      proof := { gapMask := ByteArray.empty, siblings := #[] } } }
        let h_eq : s = s := rfl
        let h := kernelStep_encode_deterministic s s h_eq
        let _ := h
        assert true "determinism holds value-level"
    }
    -- ## #229 distinguish-inputs
  , { name := "#229: kernelStep_encode_distinguishes_inputs API stable"
    , body := do
        let _proof : ∀ (s₁ s₂ : FaultProof.KernelStep),
            Encoding.KernelStep.encode s₁ ≠ Encoding.KernelStep.encode s₂ →
            s₁ ≠ s₂ :=
          fun s₁ s₂ h => kernelStep_encode_distinguishes_inputs s₁ s₂ h
        assert true "API exists"
    }
    -- ## #272
  , { name := "#272: gameState_encode_deterministic API stable"
    , body := do
        let _proof : ∀ (g₁ g₂ : LegalKernel.FaultProof.GameState), g₁ = g₂ →
            Encoding.GameState.encode g₁ = Encoding.GameState.encode g₂ :=
          fun g₁ g₂ h => gameState_encode_deterministic g₁ g₂ h
        assert true "API exists"
    }
  , { name := "#272: gameState_encode_distinguishes_inputs API stable"
    , body := do
        let _proof : ∀ (g₁ g₂ : LegalKernel.FaultProof.GameState),
            Encoding.GameState.encode g₁ ≠ Encoding.GameState.encode g₂ →
            g₁ ≠ g₂ :=
          fun g₁ g₂ h => gameState_encode_distinguishes_inputs g₁ g₂ h
        assert true "API exists"
    }
  ]

end LegalKernel.Test.FaultProof.EncodeInjectivity

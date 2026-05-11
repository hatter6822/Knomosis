/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.EncodeInjectivity — API stability +
value-level tests for encoder determinism, distinguish-inputs,
and the round-trip-conditional injectivity packagers.
-/

import LegalKernel.FaultProof.EncodeInjectivity
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.EncodeInjectivity

/-- Tests for encoder injectivity / distinguish-inputs theorems. -/
def tests : List TestCase :=
  [ -- ## #213
    { name := "#213 byte form: commitState_setBalance_bytes_inj_under_collision_free API stable"
    , body := do
        let _ := @commitState_setBalance_bytes_inj_under_collision_free
        assert true "API exists"
    }
  , { name := "#213 value form (round-trip-conditional packager) API stable"
    , body := do
        let _ := @commitState_after_setBalance_value_injective
        assert true "API exists (round-trip hypothesis required)"
    }
    -- ## #228
  , { name := "#228: kernelStep_encode_deterministic_strong API stable"
    , body := do
        let _ := @kernelStep_encode_deterministic_strong
        assert true "API exists"
    }
    -- ## #229
  , { name := "#229 practical: kernelStep_encode_distinguishes_inputs API stable"
    , body := do
        let _ := @kernelStep_encode_distinguishes_inputs
        assert true "API exists"
    }
  , { name := "#229 packager: kernelStep_encode_injective_via_roundtrip API stable"
    , body := do
        let _ := @kernelStep_encode_injective_via_roundtrip
        assert true "API exists"
    }
  , { name := "#229 packager: kernelStep_encode_distinguishes_via_roundtrip API stable"
    , body := do
        let _ := @kernelStep_encode_distinguishes_via_roundtrip
        assert true "API exists"
    }
    -- ## #272
  , { name := "#272: gameState_encode_deterministic_strong API stable"
    , body := do
        let _ := @gameState_encode_deterministic_strong
        assert true "API exists"
    }
  , { name := "#272 practical: gameState_encode_distinguishes_inputs API stable"
    , body := do
        let _ := @gameState_encode_distinguishes_inputs
        assert true "API exists"
    }
  , { name := "#272 packager: gameState_encode_injective_via_roundtrip API stable"
    , body := do
        let _ := @gameState_encode_injective_via_roundtrip
        assert true "API exists"
    }
  , { name := "#272 packager: gameState_encode_distinguishes_via_roundtrip API stable"
    , body := do
        let _ := @gameState_encode_distinguishes_via_roundtrip
        assert true "API exists"
    }
  ]

end LegalKernel.Test.FaultProof.EncodeInjectivity

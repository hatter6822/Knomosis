/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Umbrella — value-level tests for the umbrella module.

Tests that target `LegalKernel.lean` directly (the umbrella
re-export), as opposed to the trusted-core `LegalKernel.Kernel`.  In
Phase 0 the only umbrella-level surface that warrants a runtime test
is `kernelBuildTag`, which is consumed by `Main.lean` and serves as
a link-time confirmation that the kernel module compiled.

Future phases will add tests here when the umbrella grows additional
non-TCB conveniences.
-/

import LegalKernel
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Test

namespace LegalKernel.Test.Umbrella

/-- Tests for the umbrella module's non-TCB surface. -/
def tests : List TestCase :=
  [ { name := "kernelBuildTag is non-empty"
    , body := do
        assert (kernelBuildTag.length > 0) "kernel build tag empty"
    }
  , { name := "kernelBuildTag reflects current Phase"
    , body := do
        -- Catches a stale tag after a Phase bump.  The tag is
        -- string-equal to a known constant; CI will fail if a Phase
        -- promotion lands without updating the build tag.
        assertEq (expected := "canon-audit-remediation")
                 (actual   := kernelBuildTag)
                 "build tag identifies the current phase"
    }
  ]

end LegalKernel.Test.Umbrella

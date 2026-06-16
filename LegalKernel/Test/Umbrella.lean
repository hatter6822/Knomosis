-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Umbrella — value-level tests for the umbrella module.

Tests that target `LegalKernel.lean` directly (the umbrella
re-export), as opposed to the trusted-core `LegalKernel.Kernel`.  In
Phase 0 the only umbrella-level surface that warrants a runtime test
is `kernelVersion`, which is consumed by `Main.lean` and serves as
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
  [ { name := "kernelVersion is non-empty"
    , body := do
        assert (kernelVersion.length > 0) "kernel version empty"
    }
  ]

end LegalKernel.Test.Umbrella

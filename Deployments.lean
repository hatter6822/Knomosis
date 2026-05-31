-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Deployments — umbrella module for example and reference
deployment manifests.

LX.37 of `docs/planning/lex_implementation_plan.md`.

Currently re-exports the worked-example USD-clearing manifest
(`Deployments.Examples.UsdClearing`).  Future deployments append
their import here.

These are non-TCB; bugs cannot violate any kernel invariant.
-/

import Deployments.Examples.UsdClearing

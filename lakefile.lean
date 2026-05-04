/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

import Lake
open Lake DSL

/--
Canon — A Legal Kernel.

Phase 0 of the Genesis Plan (`docs/GENESIS_PLAN.md`, §12) lays down the
build skeleton: a pinned Lean toolchain, a Lake package, the trusted-core
kernel module, the canonical `transfer` law, and a CI pipeline.  The
kernel is intentionally `Std`-only — no Mathlib dependency, no external
Lean packages — so that the trusted computing base equals exactly the
Lean core distribution plus this repository.
-/
package canon where
  -- Per-package Lean options.  Phase 0's hygiene gate:
  --
  -- * `autoImplicit := false` — every universe / type variable must
  --   be declared explicitly; Lean must not auto-introduce them
  --   (Genesis Plan §13.6, "Decidability discipline" in CLAUDE.md).
  -- * `relaxedAutoImplicit := false` — same rule, even for "section
  --   variables", which are otherwise auto-bound under the relaxed
  --   form.
  -- * `linter.unusedVariables := true` — surfaces dead bindings.
  -- * `linter.missingDocs := true` — every public surface must have
  --   a `/-- … -/` docstring.  CLAUDE.md mandates this; promoting it
  --   to a build-time check prevents drift.
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    ⟨`relaxedAutoImplicit, false⟩,
    ⟨`linter.unusedVariables, true⟩,
    ⟨`linter.missingDocs, true⟩
  ]

/-- The trusted core: kernel module, plus the law set that the deployment
    chooses to admit.  See `LegalKernel.lean` for the umbrella import. -/
@[default_target]
lean_lib LegalKernel where
  roots := #[`LegalKernel]

/-- Test driver: a thin executable that imports every test module and
    fails (non-zero exit) if any property check raises. `lake test`
    invokes this binary via the `@[test_driver]` attribute. -/
@[test_driver]
lean_exe Tests where
  root := `Tests
  supportInterpreter := true

/-- Placeholder driver executable.  Phase 5 of the Genesis Plan
    (`Runtime/Loop.lean`) will replace this with the real runtime. -/
lean_exe canon where
  root := `Main

/-- Shared utilities for the Phase 1 audit executables: the kernel-TCB
    file list, the TCB allowlist path, and a safe file reader.  Kept
    in its own `lean_lib` so both `tcb_audit` and `count_sorries` can
    depend on it without re-declaring constants in lockstep. -/
lean_lib ToolsCommon where
  roots := #[`Tools.Common]

/-- WU 1.11 (Phase 1) TCB-audit executable.  Enumerates the *direct
    imports* of the trusted-core source files (`Kernel.lean`,
    `RBMapLemmas.lean`) and compares each to the allowlist at
    `tcb_allowlist.txt`.  Fails (non-zero exit) on any un-allowlisted
    import; CI consumes the exit code to block PRs that expand the
    TCB without going through the §13.6 amendment process. -/
lean_exe tcb_audit where
  root := `Tools.TcbAudit
  supportInterpreter := true

/-- WU 1.12 (Phase 1) `count_sorries` executable.  Counts `sorry`
    occurrences in proof position across the project; fails (non-zero
    exit) if any kernel-TCB module has a non-zero count.  CI runs
    this as a hard gate after `lake build` so a `sorry` reaching
    `Kernel.lean` or `RBMapLemmas.lean` blocks the build. -/
lean_exe count_sorries where
  root := `Tools.CountSorries
  supportInterpreter := true

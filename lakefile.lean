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
  -- Workstream LX (LX.1): register the action-index registry and
  -- the codegen-input directory as extra build dependencies so
  -- `lake build` re-fires when either changes.  Without this,
  -- editing the registry alone wouldn't trigger a rebuild and the
  -- `lex_lint` / `lex_codegen --check` gates would run against
  -- stale state in incremental builds.
  extraDepTargets := #[`lexIndexRegistry, `lexCodegenInputs]

/-- LX.1: the action-index registry file as an input dependency.
    Lake re-fires every dependent target when the registry's
    bytes change. -/
input_file lexIndexRegistry where
  path := "lex_index_registry.txt"

/-- LX.1: the codegen-input directory as an input dependency.
    Lake re-fires every dependent target when any file in the
    directory changes. -/
input_dir lexCodegenInputs where
  path := "LegalKernel/_lex_inputs"

/-- The trusted core: kernel module, plus the law set that the deployment
    chooses to admit.  See `LegalKernel.lean` for the umbrella import. -/
@[default_target]
lean_lib LegalKernel where
  roots := #[`LegalKernel]

/-- LX.37 — example deployment manifests.  Non-TCB; demonstrates
    the `deployment` macro's full surface (LX.31 / LX.32 / LX.33)
    and serves as the M3 acceptance gate.  See
    `Deployments/Examples/UsdClearing.lean`. -/
lean_lib Deployments where
  roots := #[`Deployments]

/-- Test driver: a thin executable that imports every test module and
    fails (non-zero exit) if any property check raises. `lake test`
    invokes this binary via the `@[test_driver]` attribute. -/
@[test_driver]
lean_exe Tests where
  root := `Tests
  supportInterpreter := true

/-- The Phase-5 `canon` runtime executable (WU 5.1).  Multiplexes
    five subcommands (`info`, `process`, `replay`, `bootstrap`,
    `snapshot`) against an append-only log file at the path supplied
    on the command line.  See `Main.lean` for the dispatcher and
    `docs/abi.md` for the on-disk byte layouts. -/
lean_exe canon where
  root := `Main

/-- The Phase-5 `canon-replay` executable (WU 5.5).  A focused,
    audit-oriented binary that reads a log file and prints the
    final state hash without writing to the log.  An auditor running
    this on a separate machine reproduces the runtime's `StateHash`
    byte-for-byte (Genesis Plan §13.2 acceptance). -/
lean_exe «canon-replay» where
  root := `Replay

/-- Shared utilities for the Phase 1 audit executables: the kernel-TCB
    file list, the TCB allowlist path, and a safe file reader.  Kept
    in its own `lean_lib` so both `tcb_audit` and `count_sorries` can
    depend on it without re-declaring constants in lockstep. -/
lean_lib ToolsCommon where
  roots := #[`Tools.Common]

/-- Content-name-discipline audit library.  Exposes
    `Tools.NamingAudit` for the `naming_audit` executable. -/
lean_lib NamingAuditLib where
  roots := #[`Tools.NamingAudit]

/-- No-deferrals-policy audit library.  Exposes
    `Tools.DeferralAudit` for the `deferral_audit` executable. -/
lean_lib DeferralAuditLib where
  roots := #[`Tools.DeferralAudit]

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

/-- Audit-3.8 stub-detection executable.  Walks every `.lean` file
    under `LegalKernel/` and flags lines whose code body matches a
    placeholder pattern (`:= ByteArray.empty`, `:= []`, etc.) AND
    whose preceding docstring contains red-flag tokens (`stub`,
    `placeholder`, `TODO`, `wire`, etc.).  Allowlist:
    `tools/stub_allowlist.txt`.  CI runs this after `tcb_audit` so
    a future placeholder-stub regression (like the historical
    `signingInput := ByteArray.empty`) blocks merge automatically. -/
lean_exe stub_audit where
  root := `Tools.StubAudit
  supportInterpreter := true

/-- Content-name discipline enforcer.  Scans every `.lean` file
    under `LegalKernel/` and `Tools/` for file names + declaration
    identifiers containing provenance / process tokens (per
    `CLAUDE.md`'s "Names describe content, never provenance"
    rule).  Forbidden tokens include `missing`, `deferred`,
    `supplemental`, `helpers`, `misc`, `wu1`/`wu2`/..., `phase0`/
    `phase1`/..., `audit1`/`audit2`/..., `_old`, `_new`, `_v2`,
    `_tmp`, `_todo`, `_fixme`, etc.  Exact list at
    `Tools/NamingAudit.lean` (`forbiddenTokens`).

    Exit semantics:
      * 0 — every file + identifier is content-driven.
      * 1 — at least one forbidden-token match found.

    Allowlist (rare exceptions): `tools/naming_allowlist.txt`. -/
lean_exe naming_audit where
  root := `NamingAudit
  supportInterpreter := true

/-- No-deferrals-policy audit.  Scans every `.lean` file under
    `LegalKernel/` and `Tools/` for deferral markers in
    docstrings, comments, or status tables — `DEFERRED`,
    `PARTIAL`, `deferred to follow-up`, `round-trip-conditional`,
    `multi-day work`, `not yet provable`, `TODO:`, `FIXME:`,
    etc.  Premise: deferrals weaken the project's no-shortcuts
    discipline; either ship the proof or don't ship the theorem.

    Exit semantics:
      * 0 — no deferral markers.
      * 1 — at least one marker found.

    Allowlist: `tools/deferral_allowlist.txt`. -/
lean_exe deferral_audit where
  root := `DeferralAudit
  supportInterpreter := true

/-- Workstream LX (LX.4) — shared utilities consumed by the Lex
    audit binaries (`lex_lint`, `lex_codegen`, `lex_diff`,
    `lex_format`).  Provides the `LawDecl` Lean structure mirroring
    `docs/lex_implementation_plan.md` §5.2's JSON schema, registry
    parsing, the JSON codec, and the `Diagnostic` record + uniform
    formatter (§18.1). -/
lean_lib LexCommon where
  roots := #[`Tools.LexCommon]

/-- Workstream LX — make `Tools.LexLint`, `Tools.LexCodegen`,
    `Tools.LexDiff`, and `Tools.LexFormat` importable as a
    library (e.g. by test files in
    `LegalKernel/Test/Tools/Lex*.lean`).  The `def main` entry-
    point glue lives in the project-root `LexLint.lean`,
    `LexCodegen.lean`, `LexDiff.lean`, and `LexFormat.lean`
    wrappers, NOT in these library modules; the library
    contains only the helper functions, renderers, and type
    definitions. -/
lean_lib LexAudit where
  roots := #[`Tools.LexLint, `Tools.LexCodegen, `Tools.LexDiff, `Tools.LexFormat]

/-- Workstream LX (LX.5) — the `lex_lint` audit binary.  Walks
    `LegalKernel/Laws/` and `Deployments/` (M3), parses every
    `.lean` file's `law` and `deployment` declarations, and emits
    diagnostics for the §13.1 rule violations.  CI runs this as a
    fast-fail gate after `lake build`.

    The `def main` entry-point glue lives in the project-root
    `LexLint.lean` wrapper file (which imports `Tools.LexLint`);
    this lets test files import `Tools.LexLint`'s helpers without
    colliding with `Tools.LexCodegen`'s top-level `main`. -/
lean_exe lex_lint where
  root := `LexLint
  supportInterpreter := true

/-- Workstream LX (LX.17 – LX.20) — the `lex_codegen` build-time
    codegen binary.  Reads every JSON file under
    `LegalKernel/_lex_inputs/`, sorts by `action_index`, and (in
    M1's additive mode) appends new constructors / branches inside
    `-- BEGIN LEX-GENERATED` / `-- END LEX-GENERATED` fences in the
    four cross-module artefacts (`Authority/Action.lean`,
    `Encoding/Action.lean`, `Events/Extract.lean`,
    `Authority/SignedAction.lean`).  CI runs `lake exe lex_codegen
    --check` to verify the committed files match generated.

    The `def main` entry-point glue lives in the project-root
    `LexCodegen.lean` wrapper (mirrors `LexLint`). -/
lean_exe lex_codegen where
  root := `LexCodegen
  supportInterpreter := true

/-- Workstream LX (LX.34 / LX.35) — the `lex_diff` semantic-diff
    binary.  Compares two trees of codegen-input JSON files and
    emits a per-law / per-deployment diff.  Used by reviewers
    walking PRs that mutate Lex laws, and by CI to gate
    governance-critical changes (L007 mismatched version-bump,
    L016 missing refinement proof). -/
lean_exe lex_diff where
  root := `LexDiff
  supportInterpreter := true

/-- Workstream LX (LX.36) — the `lex_format` pretty-printer.
    Reads a Lex law / deployment file, normalises clause order
    + indentation + trailing whitespace, and emits the canonical
    form to stdout.  Idempotent: format-then-format = format. -/
lean_exe lex_format where
  root := `LexFormat
  supportInterpreter := true

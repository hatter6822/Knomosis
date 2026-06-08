-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

import Lake
open Lake DSL

/--
Knomosis — A Legal Kernel.

Phase 0 of the Genesis Plan (`docs/GENESIS_PLAN.md`, §12) lays down the
build skeleton: a pinned Lean toolchain, a Lake package, the trusted-core
kernel module, the canonical `transfer` law, and a CI pipeline.  The
kernel is intentionally `Std`-only — no Mathlib dependency, no external
Lean packages — so that the trusted computing base equals exactly the
Lean core distribution plus this repository.
-/
package knomosis where
  -- Lockstep with the Rust workspace version
  -- (`runtime/Cargo.toml`'s `[workspace.package] version`).  Bumped
  -- on every PR per the patch-version-bump policy in `CLAUDE.md`.
  version := v!"0.5.5"
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
  path := "Lex/IndexRegistry.txt"

/-- LX.1: the codegen-input directory as an input dependency.
    Lake re-fires every dependent target when any file in the
    directory changes. -/
input_dir lexCodegenInputs where
  path := "Lex/Inputs"

/-- AR.10 — default fallback static library for the hash-adaptor C
    ABI symbols (`knomosis_hash_bytes`, `knomosis_hash_stream`,
    `knomosis_hash_identifier`).  Compiles
    `runtime/knomosis-hash-fallback.c` and packages it as a static
    library that Lake links into every executable in the package
    (`knomosis`, `knomosis-replay`, the audit binaries, the test driver)
    so the @[extern] swap-points resolve even when no production
    implementation is linked.  Production deployments override the
    symbols by linking a real BLAKE3-256 (or keccak256)
    implementation library AHEAD of this fallback in their link
    order.

    The macro elaborator (which evaluates Lean code at compile
    time, including some macros that call `Runtime.Hash.*`) never
    reaches `hashBytes` / `hashStream` / `hashImplementationIdentifier`
    on the @[extern] path: deployment-manifest hashing in
    `Lex/DSL/Deployment.lean` deliberately binds to the Lean
    fallback `hashStreamFallback` so the macro is independent of
    link-time configuration.  This keeps the `extern_lib` purely a
    runtime concern. -/
extern_lib knomosisHashFallback (pkg : NPackage __name__) := do
  -- Opt-in keccak-linked cross-stack verification build: when
  -- `KNOMOSIS_HASH_BACKEND=keccak256`, link the pre-built
  -- `knomosis-hash-keccak256` adaptor staticlib (which exports the same
  -- three `knomosis_hash_*` C-ABI symbols, backed by real keccak256 via
  -- the `sha3` crate) IN PLACE OF the FNV-1a-64 fallback.  The staticlib
  -- is built out-of-band by `scripts/verify_keccak_crossstack.sh`
  -- (`cargo build -p knomosis-hash-keccak256 --features lean-ffi`) and
  -- its absolute path passed via `KNOMOSIS_KECCAK_STATICLIB`.  This is a
  -- SINGLE-archive swap — exactly one library defines the hash symbols,
  -- so there is no link-order / `--whole-archive` / duplicate-symbol
  -- race.  The default path (no env var) is byte-identical to the FNV
  -- fallback build below.
  match (← IO.getEnv "KNOMOSIS_HASH_BACKEND") with
  | some "keccak256" =>
    match (← IO.getEnv "KNOMOSIS_KECCAK_STATICLIB") with
    | some kPath => inputBinFile (System.FilePath.mk kPath)
    | none =>
      error
        ("KNOMOSIS_HASH_BACKEND=keccak256 requires KNOMOSIS_KECCAK_STATICLIB " ++
         "(absolute path to a libknomosis_hash_keccak256.a built with " ++
         "`cargo build -p knomosis-hash-keccak256 --features lean-ffi`)")
  | _ =>
    let srcPath : System.FilePath := pkg.dir / "runtime" / "knomosis-hash-fallback.c"
    let oFile := pkg.buildDir / "runtime" / "knomosis-hash-fallback.o"
    let srcJob ← inputTextFile srcPath
    let weakArgs := #["-I", (← getLeanIncludeDir).toString, "-fPIC"]
    let oJob ← buildO oFile srcJob weakArgs #[] (← getLeanc)
    buildStaticLib (pkg.staticLibDir / nameToStaticLib "knomosis-hash-fallback") #[oJob]

/-- The trusted core: kernel module, plus the law set that the deployment
    chooses to admit.  See `LegalKernel.lean` for the umbrella import. -/
@[default_target]
lean_lib LegalKernel where
  roots := #[`LegalKernel]

/-- Workstream LX — the Lex programming language.  Houses the
    Lex DSL macros (`Lex.DSL.*`), the demonstration example
    `Lex.Examples.ExampleLex`, and (via separate `lean_lib`
    declarations below) the audit-binary tooling.  The
    runtime-relevant surface re-exports from `Lex.lean`. -/
@[default_target]
lean_lib Lex where
  roots := #[`Lex]

/-- LX.37 — example deployment manifests.  Non-TCB; demonstrates
    the `deployment` macro's full surface (LX.31 / LX.32 / LX.33)
    and serves as the M3 acceptance gate.  See
    `Deployments/Examples/UsdClearing.lean`. -/
@[default_target]
lean_lib Deployments where
  roots := #[`Deployments]

/-- Test driver: a thin executable that imports every test module and
    fails (non-zero exit) if any property check raises. `lake test`
    invokes this binary via the `@[test_driver]` attribute. -/
@[default_target, test_driver]
lean_exe Tests where
  root := `Tests
  supportInterpreter := true

/-- The Phase-5 `knomosis` runtime executable (WU 5.1).  Multiplexes
    the runtime subcommands (`info`, `process`, `replay`, `bootstrap`,
    `snapshot`, `withdrawal-proof`, `replay-up-to`, `export-cell-proofs`,
    `export-terminate-bundle`, and `extract-events` — the RH-D event
    extractor backend, GP.6.3) against an append-only log file at the
    path supplied on the command line.  See `Main.lean` for the
    dispatcher and `docs/abi.md` for the on-disk byte layouts. -/
@[default_target]
lean_exe knomosis where
  root := `Main

/-- The Phase-5 `knomosis-replay` executable (WU 5.5).  A focused,
    audit-oriented binary that reads a log file and prints the
    final state hash without writing to the log.  An auditor running
    this on a separate machine reproduces the runtime's `StateHash`
    byte-for-byte (Genesis Plan §13.2 acceptance). -/
@[default_target]
lean_exe «knomosis-replay» where
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
@[default_target]
lean_exe tcb_audit where
  root := `Tools.TcbAudit
  supportInterpreter := true

/-- WU 1.12 (Phase 1) `count_sorries` executable.  Counts `sorry`
    occurrences in proof position across the project; fails (non-zero
    exit) if any kernel-TCB module has a non-zero count.  CI runs
    this as a hard gate after `lake build` so a `sorry` reaching
    `Kernel.lean` or `RBMapLemmas.lean` blocks the build. -/
@[default_target]
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
@[default_target]
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
@[default_target]
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
@[default_target]
lean_exe deferral_audit where
  root := `DeferralAudit
  supportInterpreter := true

/-- AR.9 / M-10 — production-import-of-test-module audit.  Scans
    every `.lean` file in the production source roots
    (`LegalKernel/`, `Lex/`, `Tools/`, `Deployments/`, plus the
    top-level driver files) for `import LegalKernel.Test.*`,
    `import Lex.Test.*`, or `import Tools.Test.*` lines.  Any
    match is reported as a CI-blocking violation.

    The historical hazard this closes: `LegalKernel/Test/MockCrypto.lean`
    docstring claimed the existing `stub_audit` flagged production
    imports — but `stub_audit` is about placeholder bodies, not
    imports.  This new gate mechanically enforces the documented
    contract.

    Exit semantics:
      * 0 — no production module imports a Test module.
      * 1 — at least one violation found. -/
@[default_target]
lean_exe mock_import_audit where
  root := `Tools.MockImportAudit
  supportInterpreter := true

/-- Workstream LX (LX.4) — shared utilities consumed by the Lex
    audit binaries (`lex_lint`, `lex_codegen`, `lex_diff`,
    `lex_format`).  Provides the `LawDecl` Lean structure mirroring
    `docs/planning/lex_implementation_plan.md` §5.2's JSON schema, registry
    parsing, the JSON codec, and the `Diagnostic` record + uniform
    formatter (§18.1). -/
lean_lib LexCommon where
  roots := #[`Lex.Tools.Common]

/-- Workstream LX — make `Lex.Tools.Lint`, `Lex.Tools.Codegen`,
    `Lex.Tools.Diff`, and `Lex.Tools.Format` importable as a
    library (e.g. by test files in `Lex/Test/Tools/`).  The
    `def main` entry-point glue lives in
    `Lex/Bin/{Lint,Codegen,Diff,Format}.lean`, NOT in these
    library modules; the library contains only the helper
    functions, renderers, and type definitions. -/
lean_lib LexAudit where
  roots := #[`Lex.Tools.Lint, `Lex.Tools.Codegen, `Lex.Tools.Diff, `Lex.Tools.Format]

/-- Workstream LX (LX.5) — the `lex_lint` audit binary.  Walks
    `LegalKernel/Laws/`, `Lex/Examples/`, and `Deployments/` (M3),
    parses every `.lean` file's `law` and `deployment`
    declarations, and emits diagnostics for the §13.1 rule
    violations.  CI runs this as a fast-fail gate after
    `lake build`.

    The `def main` entry-point glue lives at `Lex/Bin/Lint.lean`
    (which imports `Lex.Tools.Lint`); this lets test files import
    `Lex.Tools.Lint`'s helpers without colliding with
    `Lex.Tools.Codegen`'s top-level `main`. -/
@[default_target]
lean_exe lex_lint where
  root := `Lex.Bin.Lint
  supportInterpreter := true

/-- Workstream LX (LX.17 – LX.20) — the `lex_codegen` build-time
    codegen binary.  Reads every JSON file under
    `Lex/Inputs/`, sorts by `action_index`, and (in
    M1's additive mode) appends new constructors / branches inside
    `-- BEGIN LEX-GENERATED` / `-- END LEX-GENERATED` fences in the
    four cross-module artefacts (`Authority/Action.lean`,
    `Encoding/Action.lean`, `Events/Extract.lean`,
    `Authority/SignedAction.lean`).  CI runs `lake exe lex_codegen
    --check` to verify the committed files match generated.

    The `def main` entry-point glue lives at
    `Lex/Bin/Codegen.lean` (mirrors `lex_lint`). -/
@[default_target]
lean_exe lex_codegen where
  root := `Lex.Bin.Codegen
  supportInterpreter := true

/-- Workstream LX (LX.34 / LX.35) — the `lex_diff` semantic-diff
    binary.  Compares two trees of codegen-input JSON files and
    emits a per-law / per-deployment diff.  Used by reviewers
    walking PRs that mutate Lex laws, and by CI to gate
    governance-critical changes (L007 mismatched version-bump,
    L016 missing refinement proof). -/
@[default_target]
lean_exe lex_diff where
  root := `Lex.Bin.Diff
  supportInterpreter := true

/-- Workstream LX (LX.36) — the `lex_format` pretty-printer.
    Reads a Lex law / deployment file, normalises clause order
    + indentation + trailing whitespace, and emits the canonical
    form to stdout.  Idempotent: format-then-format = format. -/
@[default_target]
lean_exe lex_format where
  root := `Lex.Bin.Format
  supportInterpreter := true

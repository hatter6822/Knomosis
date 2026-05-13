<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

<!--
  Canon — A Legal Kernel
  Adapted from the structure of Orbcrypt's CLAUDE.md
  (https://github.com/hatter6822/Orbcrypt/blob/main/CLAUDE.md)
  with project-specific guidance for Canon's Std-only, kernel-centric
  Lean 4 codebase.
-->

# CLAUDE.md — Canon project guidance

This file owns engineering conventions and the day-to-day developer /
agent workflow.  The design specification lives in
`docs/GENESIS_PLAN.md`; the top-level introduction lives in
`README.md`.  Where this file disagrees with the Genesis Plan, the
Genesis Plan wins.

## What this project is

Canon is a **proof-carrying state transition system** built in Lean 4.
It implements the Genesis Plan (`docs/GENESIS_PLAN.md`): a small,
parametric, law-free kernel where "legality" is a Lean type, every
state change is accompanied by a machine-checkable proof of
admissibility, and global system properties (determinism, refinement,
no-silent-illegality, invariant preservation) are guaranteed by
inductive theorems rather than by trust in operators.

**Current status.** Phases 0 – 6 complete; Ethereum integration
Workstreams A – F complete (Lean side); Workstream LP (actor-scoped
policies) complete; Workstream LX (Lex law-declaration language)
milestones M1 / M2 / M3 complete; Workstream H (fault-proof
migration) complete (Lean side; Rust off-chain observer deferred).
Workstream G (Ethereum documentation + amendment) and Phase 7
(Advanced Capabilities) are the next scoped work.  See
`docs/GENESIS_PLAN.md` §12 / §15B and
`docs/ethereum_integration_plan.md` / `docs/fault_proof_migration_plan.md`
for the per-phase deliverables; see "Implementation roadmap" below
for the status table.

## Build and run

```bash
# Recommended: SHA-256-verified setup.  Pins the Lean toolchain,
# verifies every download, and records a binary integrity snapshot.
./scripts/setup.sh            # idempotent
./scripts/setup.sh --build    # full setup + lake build
./scripts/setup.sh --quiet    # suppress informational logs

# Manual alternative (skip integrity verification):
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
  | sh -s -- -y --default-toolchain none
elan toolchain install "$(cat lean-toolchain)"

# Daily commands.
source ~/.elan/env
lake build                          # full project build
lake build LegalKernel.<Module>     # one module (fastest feedback)
lake test                           # ~1835 tests across ~100 suites
lake exe count_sorries              # zero-sorry kernel gate
lake exe tcb_audit                  # TCB allowlist gate
lake exe stub_audit                 # stub-detection gate
lake exe naming_audit               # content-name discipline gate
lake exe deferral_audit             # no-deferrals policy gate
lake exe lex_lint                   # Lex registry + sidecar gate
lake exe lex_codegen --check        # Lex codegen-consistency gate
                                    #   (also: --canonical for full-body
                                    #   regeneration, --gen-property-tests)
lake exe lex_diff <before> <after>  # Lex semantic-diff binary
                                    #   (also: --git <ref-a> <ref-b>)
lake exe lex_format <file>          # Lex pretty-printer

# Runtime smoke test.
.lake/build/bin/canon info
.lake/build/bin/canon bootstrap /tmp/test.log
.lake/build/bin/canon-replay /tmp/test.log

# Workstream E (Solidity contracts) — see solidity/README.md.
cd solidity && ./scripts/vendor-deps.sh   # one-time
cd solidity && forge build
cd solidity && forge test
cd solidity && make test-cross-stack          # F.1.x equivalence suite
cd solidity && make testnet-acceptance-dryrun # F.3 local fork dry-run
```

`lakefile.lean` is the source of truth for every build target,
executable, and `lean_lib`; consult it before adding new targets.

**Toolchain.** Lean 4 v4.29.1 (pinned in `lean-toolchain`).  Bumping
the toolchain requires recomputing the four
`LEAN_TOOLCHAIN_SHA256_*` archive constants (one per
`(format, architecture)` pair: zst/zip × x86_64/aarch64) in
`scripts/setup.sh` and landing both changes in the same PR.

## Module build verification (mandatory)

Before committing any `.lean` file, build the specific module:

```bash
lake build LegalKernel.<Module.Path>
lake build Lex.<Module.Path>           # for Lex DSL / tools / examples / tests
```

After any source change, also run:

* `lake test` — runs the `@[test_driver]` declared in `Tests.lean`.
  Catches semantic regressions that elaboration-only checks miss
  (e.g. the §4.11 self-transfer fix would silently survive a build
  but break a test).  Each post-Phase-0 theorem additionally has a
  term-level API-stability test whose elaboration fails if the
  theorem signature changes.
* `lake exe count_sorries` — fails on any `sorry` in proof position
  in a kernel-adjacent module (`Kernel.lean`, `RBMapLemmas.lean`,
  `Laws/Transfer.lean` — the `Tools.Common.kernelTcbFiles` list).
  The detector masks `--` comments, `/- -/` blocks, and `"..."`
  string literals, so the word "sorry" in prose is fine; only the
  *term* in proof position is forbidden.
* `lake exe tcb_audit` — fails if a TCB-core module
  (`Kernel.lean`, `RBMapLemmas.lean` — the `Tools.Common.tcbCoreFiles`
  list) imports anything not on `tcb_allowlist.txt` *or* in
  `Tools.Common.tcbInternalImports` (the explicit, enumerated list
  of project-internal modules a TCB-core file may import).
* `lake exe stub_audit` — catches placeholder-body stubs
  (`:= ByteArray.empty`, `:= []`, etc.) accompanied by red-flag
  docstring tokens.  Allowlist: `tools/stub_allowlist.txt`.
* `lake exe lex_lint` + `lake exe lex_codegen --check` — enforce
  the Lex action-index registry's append-only discipline and the
  byte-stability of codegen-input sidecars.

CI (`.github/workflows/ci.yml`) runs all of the above on every PR.

## Source layout

```
canon/
├── lakefile.lean              -- Lake config (lean_lib, lean_exe, plus
│                                  input_file/input_dir build deps for the Lex
│                                  registry and codegen-input directory)
├── lean-toolchain             -- pinned Lean version
├── tcb_allowlist.txt          -- TCB import allowlist
├── Main.lean                  -- `canon` runtime CLI
├── Replay.lean                -- `canon-replay` audit binary
├── Tests.lean                 -- @[test_driver]; imports every test module
├── LegalKernel.lean           -- umbrella module (re-exports everything)
├── Lex.lean                   -- umbrella module for the Lex language
├── Deployments.lean           -- umbrella for the `Deployments` lean_lib
├── LegalKernel/
│   ├── Kernel.lean            -- §4.12 trusted core (TCB)
│   ├── RBMapLemmas.lean       -- §8.3 RBMap proof library (TCB)
│   ├── Conservation.lean      -- §8.1 / §5.3 economic invariants + LX classification typeclasses
│   ├── Laws/                  -- one law per file (transfer, mint, burn, freeze,
│   │                             reward, distributeOthers, proportionalDilute,
│   │                             deposit, withdraw, replaceKey, registerIdentity,
│   │                             dispute pipeline, local-policy laws).  Lex
│   │                             re-expressions live alongside the hand-written
│   │                             law; Lex-only demonstration laws live under
│   │                             `Lex/Examples/`.
│   ├── Authority/             -- Crypto, Action, Identity, Nonce, LocalPolicy,
│   │                             LocalPolicySemantics, SignedAction
│   ├── Encoding/              -- CBE codec (CBOR, Encodable, Action, SignedAction,
│   │                             State, SignInput, Disputes, LocalPolicy)
│   ├── DSL/                   -- Law.mk + `law` macro (base DSL).  The Lex
│   │                             extension (`lexlaw`, `lex_*` clauses) lives
│   │                             under the top-level `Lex/DSL/`.
│   ├── Events/                -- §8.9.2 Event inductive + extractEvents
│   ├── Runtime/               -- Hash, LogFile, Replay, Snapshot, Loop (Phase 5)
│   ├── Disputes/              -- §8.4 four-stage pipeline (Phase 6) + incentive amendment
│   ├── LocalPolicy/           -- Workstream LP classification typeclasses
│   ├── Bridge/                -- Workstreams A–D: crypto adaptors, identity,
│   │                             bridge laws, withdrawal proofs
│   ├── FaultProof/            -- Workstream H: state-commitment scheme,
│   │                             kernel-step type, bisection-game state
│   │                             machine, convergence / honesty / settlement
│   │                             theorems, witness construction, observer
│   │                             reference
│   └── Test/                  -- IO-based test harness; one suite per module
├── Lex/                       -- Workstream LX — the Lex programming language.
│   ├── IndexRegistry.txt      -- frozen action-index registry (append-only; LX.1)
│   ├── DSL/                   -- Lex DSL macros (`lex_law`, `lexlaw`, properties,
│   │                             deployments).  PreGrammar, ImplCalculus,
│   │                             ImplLowering, Events, Shim, Law, Property,
│   │                             Deployment.
│   ├── Tools/                 -- Lex audit-binary libraries (Common, Lint,
│   │                             Codegen, Diff, Format).
│   ├── Bin/                   -- Lake `lean_exe` entry-point wrappers
│   │                             (Lint, Codegen, Diff, Format).
│   ├── Inputs/                -- Lex codegen-input JSON sidecars (one per
│   │                             Lex law) plus the canonical manifest and the
│   │                             property-test coverage file.
│   ├── Examples/              -- Lex-only demonstration laws (ExampleLex).
│   └── Test/                  -- Lex test modules (DSL, Tools, Properties,
│                                 AutoGenProperties, ExampleLex, M2).
├── Deployments/Examples/      -- LX-M3 worked example deployments (UsdClearing)
├── Tools/                     -- non-Lex audit binaries (TcbAudit, CountSorries,
│                                  StubAudit, NamingAudit, DeferralAudit) +
│                                  shared `Common` library.  (Lex audit
│                                  binaries live under `Lex/Tools/` and
│                                  `Lex/Bin/`.)
├── solidity/                  -- Workstreams E + H: L1 mirror (10 contracts,
│                                  5 libraries, 20+ forge test suites).
│                                  See solidity/README.md.
├── scripts/setup.sh           -- SHA-256-verified toolchain + Foundry installer
├── .github/workflows/ci.yml   -- build + test + audits on PR / push
├── README.md                  -- project entry point
├── CLAUDE.md                  -- this file
└── docs/
    ├── GENESIS_PLAN.md                  -- canonical design document
    ├── ethereum_integration_plan.md     -- Workstreams A – G
    ├── actor_scoped_policies_plan.md    -- Workstream LP
    ├── lex_implementation_plan.md       -- Workstream LX
    ├── law_language_design.md           -- Lex DSL design notes
    ├── lex_amendment_walkthrough.md     -- LX-M3 worked walkthrough
    ├── decidability_discipline.md       -- decPre discipline
    ├── std_dependencies.md              -- Std lemma audit
    ├── economic_invariants.md           -- Phase-2 + monotonicity-tier design
    ├── parameterized_laws_plan.md       -- (planning)
    ├── extraction_notes.md              -- Lean → runtime erasure / persistence
    ├── fault_proof_migration_plan.md    -- Workstream H engineering plan
    ├── fault_proof_design.md            -- Workstream H design rationale
    ├── fault_proof_runbook.md           -- Workstream H operator runbook
    └── abi.md                           -- on-disk frame format + CLI ABI
```

Per-file purpose lives in each file's `/-! ... -/` module docstring,
not duplicated here.

### Module dependency graph

```
LegalKernel.RBMapLemmas        (TCB; Std-only)
LegalKernel.Kernel             (TCB; imports RBMapLemmas)

LegalKernel.Conservation       (non-TCB; imports Kernel + RBMapLemmas)
LegalKernel.Laws.*             (non-TCB; imports Conservation + Kernel)

LegalKernel.Authority.*        (non-TCB; intra-Authority layering is
                                Crypto → Action → Identity → Nonce →
                                LocalPolicy{,Semantics} → SignedAction.
                                Note that `Authority.Action` also imports
                                every `Laws.*` module plus `Bridge.AddressBook`,
                                `Bridge.State`, and `Disputes.Types` because
                                the `Action` inductive has constructors that
                                reference those types — the linear chain above
                                shows the intra-Authority order only.)

LegalKernel.Encoding.*         (non-TCB; CBOR / Encodable foundation, then
                                Action → SignedAction → State → SignInput;
                                Disputes / LocalPolicy add their own variants)

LegalKernel.DSL.{Law, LawSyntax}              (non-TCB; base law DSL; depends
                                               on Kernel + Authority)

Lex.DSL.{PreGrammar, ImplCalculus, ImplLowering,
          Events, Shim, Law, Property,
          Deployment}                         (non-TCB; Lex language extension
                                               of the base DSL; depends on
                                               LegalKernel.DSL + Authority +
                                               Lex.Tools.Common)
Lex.Examples.ExampleLex                       (non-TCB; LX.21 acceptance demo)
Lex                                           (umbrella; re-exports the Lex
                                               DSL surface)

LegalKernel.Events.{Types, Extract}            (non-TCB; depends on Authority)
LegalKernel.Runtime.{Hash, LogFile, Replay,
                      Snapshot, AttestedSnapshot,
                      Loop}                    (non-TCB; depends on Encoding + Events)

LegalKernel.Disputes.{Types, Filing, Evidence,
                       Verdict, LawClassification,
                       MonotonicDeployment,
                       Rewards, Staking}       (non-TCB; depends on Authority + Runtime)

LegalKernel.LocalPolicy.LawClassification     (non-TCB)
LegalKernel.Bridge.*                          (non-TCB; Workstreams A – D)

LegalKernel                                   (umbrella; re-exports everything)
Main / Replay / Tests                         (executables)

Tools.Common                                  (lean_lib `ToolsCommon`; shared
                                               helpers for the TCB / stub audits)
Lex.Tools.Common                              (lean_lib `LexCommon`; shared
                                               helpers for the Lex audit binaries)
Tools.{TcbAudit, CountSorries, StubAudit,
       NamingAudit, DeferralAudit}            (non-Lex audit binaries; no
                                               Lean-level dependency on the kernel)
Lex.Tools.{Lint, Codegen, Diff, Format}       (Lex audit-binary libraries;
                                               their `def main` entry-point
                                               glue lives at `Lex.Bin.*`)
Lex.Bin.{Lint, Codegen, Diff, Format}         (Lake `lean_exe` entry-point
                                               wrappers for the Lex audit
                                               binaries)
```

The kernel has **zero** external Lean-package dependencies.
`Std.Data.TreeMap` is part of Lean core (since Lean ≥ 4.10), not a
separate Lake package, so the TCB equals exactly the Lean core
distribution plus `Kernel.lean` + `RBMapLemmas.lean`.  Every other
module is non-TCB deployment-facing infrastructure: bugs there are
scoped to deployment-level claims, not kernel invariants.

**Trust assumptions.**  Two non-Lean assumptions surface through
opaque declarations rather than axioms (so `#print axioms` stays at
exactly `propext`, `Classical.choice`, `Quot.sound`):

1. `Authority.Crypto.Verify` — the deployment-supplied signature
   scheme is EUF-CMA secure.
2. `Runtime.Hash.hashBytes` — the production hash function (BLAKE3
   in production via `@[extern]`; FNV-1a-64 fallback for tests) is
   collision-resistant.

The kernel's authority and replay guarantees are conditional on
these.

## Reading large files

`docs/GENESIS_PLAN.md` is ~4200 lines / ~180 KB.  Read in chunks with
`Read(file_path, offset=…, limit=500)` rather than the whole file.
The table of contents at the top of the document maps section numbers
to the line ranges you actually need.

When editing, read the specific region around the target lines first
(e.g., `offset=2580, limit=80`) so the `old_string` matches exactly,
including indentation and whitespace.

## Writing and editing files

The Write tool replaces an entire file in one call.  For files over
~100 lines this is error-prone: the tool may time out, drop content,
or fill the context window.  **Prefer the Edit tool for all changes
to existing files**, regardless of size.

**Rules for large-file changes:**

1. **Never rewrite a large file with Write.**  Use Edit with a
   precise `old_string`/`new_string` pair targeting only the lines
   that change.
2. **One logical change per Edit call.**  Three separate edits beat
   one giant cross-section replacement.
3. **Read before you edit.**  Always Read the specific region first
   so the `old_string` matches exactly.
4. **Adding large new sections.**  If you must insert more than ~80
   new lines, break the insertion into multiple sequential Edit
   calls, anchoring each to context already present.
5. **Creating new large files.**  Build incrementally: an initial
   Write (under 100 lines) followed by Edit appends, *or* a Bash
   heredoc (`cat <<'EOF' > path/to/file.lean ... EOF`) which has no
   content-size timeout.
6. **Post-write verification.**  After any large write or edit
   sequence, spot-check by reading the modified region and the
   file's last few lines.

## Handling large search and command output

- **Grep**: cap with `head_limit` (e.g., `head_limit=30`); use
  `output_mode: "files_with_matches"` first, then drill in.
- **Glob**: scope with `path` instead of searching the whole repo.
- **Bash output**: pipe through `head` / `tail` (e.g.,
  `lake build 2>&1 | tail -80`).  For very large output, redirect
  to a temp file and `Read` it in chunks.

**Rule of thumb:** if a command might return more than ~100 lines,
limit it upfront.

## Background-agent file-change protection

Background agents (Task tool with `run_in_background: true`) run
concurrently and may finish after the foreground agent has already
modified the same files.  Their stale writes will silently overwrite
foreground progress.  Prevent this proactively:

1. **Never delegate file writes to a background agent for files you
   may also edit.**  Identify every file the agent may create or
   modify before launching.
2. **Partition files strictly.**  If parallel work is genuinely
   needed, assign each agent a disjoint set of files and document
   the partition in the agent's prompt ("you own `Foo.lean` only —
   do not modify any other file").
3. **Use background agents only for read-only or independent-file
   tasks.**  Safe: builds, tests, searches, research.  Unsafe:
   editing shared sources or configs.
4. **Check background results before acting on shared state.**  If
   the agent wrote to a file you have since modified, discard the
   agent's version and redo on top of your current state.
5. **When in doubt, run in foreground.**  Sequential correctness
   beats parallel speed.

## Key conventions

- **Two-reviewer rule for kernel-touching changes (ABSOLUTE).**  Any
  change to `LegalKernel/Kernel.lean` or
  `LegalKernel/RBMapLemmas.lean` requires two reviewers per Genesis
  Plan §13.6.  Law modules and tests require one reviewer.

  `.github/CODEOWNERS` (AR.20) is the request-for-review surface
  for the TCB-core file set: any PR touching `Kernel.lean` or
  `RBMapLemmas.lean` auto-requests the listed reviewers.
  CODEOWNERS is NOT a merge-block; full mechanical enforcement
  requires a GitHub branch-protection rule, which is repository-
  administrator territory and outside the scope of a code-only
  PR.  The two-reviewer rule remains a process rule enforced by
  the team.

- **No `sorry` in kernel-adjacent code (ABSOLUTE).**  The
  kernel-adjacent files (`Kernel.lean`, `RBMapLemmas.lean`,
  `Laws/Transfer.lean` — strictly wider than the TCB core, which
  is just `Kernel.lean` + `RBMapLemmas.lean`) must not contain a
  `sorry` in proof position.  `lake exe count_sorries` is the
  mechanical check; CI blocks the merge on a non-zero count.
  Comments referencing the *word* "sorry" are allowed; only the
  *term* in proof position is forbidden.

- **No custom axioms (ABSOLUTE).**  The kernel may use Lean's
  built-in axioms (`propext`, `Classical.choice`, `Quot.sound`) but
  must not introduce its own.  Adding an `axiom` declaration is a
  Genesis-Plan amendment and triggers the two-reviewer gate.

- **Std-core only in the kernel TCB.**  The kernel imports
  `Std.Data.TreeMap` (Lean core, not batteries) plus the sibling
  TCB module `LegalKernel.RBMapLemmas`.  `lake exe tcb_audit`
  compares each TCB module's direct-import set against
  `tcb_allowlist.txt` and `Tools.Common.tcbInternalImports`.
  Adding Mathlib or batteries is a TCB expansion and must go
  through the §13.6 amendment process.  Non-TCB law modules may
  import other things if absolutely necessary, but the default is
  "Std core only" until a specific need is justified.

- **Strict linters project-wide.**  `lakefile.lean` sets:
  - `autoImplicit := false` (and `relaxedAutoImplicit := false`) —
    Lean must not silently introduce universe / type variables.
  - `linter.missingDocs := true` — public surfaces (def, theorem,
    structure field, inductive constructor) must carry a
    `/-- … -/` docstring or the build warns.
  - `linter.unusedVariables := true` — surfaces dead bindings.
  - CI's strict-warnings gate fails the build on any `: warning:`
    line, so these are forcing-functions, not advisories.

- **Decidability discipline (§13.6 step 2).**  Every
  `Transition.decPre` field should be definable as
  `fun _ => inferInstance` whenever the precondition is built from
  arithmetic comparisons, `Nat` operations, and finite conjunctions.
  A law needing a hand-written `Decidable` derivation is a signal to
  security-review the law (§14.8): preconditions that resist
  `inferInstance` often hide an unbounded quantifier or a
  non-computable predicate that breaks the executable path.

- **Naming conventions:**
  - Theorems and lemmas: `snake_case` (Lean / Mathlib style) —
    `impl_refines_spec`, `transfer_conserves`.
  - Structures and types: `CamelCase` — `Transition`, `Legal`,
    `CertifiedTransition`.
  - Type variables: capital letters by role — `α`, `β`, `γ` for
    generic types; `s`, `s'` for states; `t` for transitions.
  - Hypothesis names: `h`-prefixed — `hpre`, `hreach`, `h_init`,
    `h_step`.
  - Namespaces: `LegalKernel`, `LegalKernel.Laws`,
    `LegalKernel.Test`.
  - **Names describe content, never provenance.**  An identifier
    must describe *what the declaration is or proves*, never *which
    work unit, audit, phase, or session produced it*.  Forbidden
    tokens in declaration names include, non-exhaustively:
    - work-unit labels: `wu`, `wu1`, `wu_2_5`, `phase`, `phase0`
    - audit / finding ids: `audit`, `finding`, `f02`, `cve`
    - session / branch references: `claude_`, `session_`, `pr23`
    - temporal markers: `old`, `new`, `v2`, `legacy`, `tmp`, `todo`,
      `fixme`

    Process markers may appear in *docstrings* (a `/-- ... -/`
    block can say "added in WU 2.5") and in commit messages,
    branch names, and planning documents.  The boundary is sharp:
    the docstring may carry a process tag, the identifier may not.

  - **Enforcement.**  Before landing any new declaration, scan the
    diff:
    ```bash
    git diff --cached -U0 -- '*.lean' \
      | grep -E '^\+(def|theorem|structure|class|instance|abbrev|lemma|noncomputable)' \
      | grep -iE 'workstream|\bws[0-9]|\bwu[0-9]|\bphase[0-9_]|audit|\bf[0-9]{2}\b|\btmp\b|\btodo\b|\bfixme\b|claude_|session_|_v[2-5]\b'
    ```
    A non-empty result is a review-blocking naming violation.
    AR.8 / M-9: the `_v2` / `_v3` / `_v4` / `_v5` family is also
    enforced mechanically by `naming_audit`'s `forbiddenTokens`
    list — the grep above mirrors the CI gate.

- **Proof style:**
  - Prefer tactic mode (`by …`) for non-trivial proofs.
  - Use `calc` blocks for equational reasoning chains.
  - Use `have` for intermediate steps with descriptive names.
  - Comment proof strategy at the top of each non-obvious theorem.
  - Avoid `decide` on large finite types (performance trap).

- **Documentation:**
  - Every `.lean` file begins with a `/-! ... -/` module docstring
    naming the Genesis-Plan section it implements.
  - Every public `def` / `theorem` / `structure` / `instance` has a
    `/-- ... -/` docstring.
  - Where a definition tracks a Genesis-Plan section (e.g.
    `transfer` is §4.11), say so in the docstring so future readers
    can cross-reference.

- **Import discipline:**  Import by full path within the project
  (`import LegalKernel.Kernel`).  Re-export top-level definitions
  via `LegalKernel.lean` (the umbrella module) so downstream
  consumers can `import LegalKernel` and get everything.

- **Git practices:**  One commit per completed work unit.  Commit
  messages may reference the WU number (`"WU 0.2: Kernel module
  skeleton"`).  All commits must pass `lake build` AND `lake test`
  — never commit broken or untested code.

## Type-level design properties

The Genesis Plan promises a small set of type-level guarantees
(§1, §5).  As of Phases 0 – 6 + Workstreams A – D + LP + LX + H,
every guarantee is mechanised by a real Lean theorem (no `sorry`,
no custom axioms — only `propext`, `Classical.choice`, `Quot.sound`).
Selected headline theorems by tier:

| Tier  | Property                                | Headline theorem                  | File                                    |
|-------|-----------------------------------------|-----------------------------------|-----------------------------------------|
| TCB   | Determinism                             | typing of `step_impl`             | `Kernel.lean`                           |
| TCB   | No silent illegality                    | `impl_noop_if_not_pre`            | `Kernel.lean`                           |
| TCB   | Refinement                              | `impl_refines_spec`               | `Kernel.lean`                           |
| TCB   | Invariant preservation                  | `invariant_preservation`          | `Kernel.lean`                           |
| TCB   | Compositionality of invariants          | `invariants_compose`              | `Kernel.lean`                           |
| TCB   | Certified ≡ executable                  | `apply_certified_eq_step_impl`    | `Kernel.lean`                           |
| TCB   | Reachability is reflexive-transitive    | `Reachable.refl`, `Reachable.trans` | `Kernel.lean` (§4.9)                  |
| TCB   | Per-law-set invariant preservation      | `invariant_preservation_via_laws` | `Kernel.lean` (§4.10)                   |
| TCB   | RBMap fold / insert lemmas              | `find?_insert_*`, `sumValues_*`   | `RBMapLemmas.lean` (§8.3)               |
| Phase 2 | Per-resource accounting on `setBalance` | `totalSupply_setBalance`        | `Conservation.lean`                     |
| Phase 2 | Transfer preserves total supply       | `transfer_conserves`              | `Laws/Transfer.lean` (§4.11.1)          |
| Phase 2 | Conservation classification typeclass | `IsConservative`                  | `Conservation.lean`                     |
| Phase 2 | Type-level firewall for conservation  | `ConservativeLawSet`              | `Conservation.lean` (§6.2)              |
| Phase 2 | Global supply preservation            | `total_supply_global[_via_law_set]` | `Conservation.lean` (§5.3)            |
| Phase 2 | Frozen-resource preservation          | `*_preserves_freeze`              | `Laws/Freeze.lean` (§4.10)              |
| 4-prelude | Monotonicity classification + firewall | `IsMonotonic`, `MonotonicLawSet` | `Conservation.lean`                    |
| 4-prelude | Per-resource non-decrease            | `total_supply_globally_nondecreasing` | `Conservation.lean`                |
| 4-prelude | `proportionalDilute` dust bound      | `proportionalDilute_distributed_le_totalReward` | `Laws/ProportionalDilute.lean` |
| Phase 3 | Action compilation is injective       | `Action.compile_injective`        | `Authority/Action.lean` (§4.13)         |
| Phase 3 | Per-actor nonce is strictly monotonic | `expectsNonce_strict_mono`        | `Authority/Nonce.lean` (§8.5)           |
| Phase 3 | Nonce uniqueness across admissibility | `nonce_uniqueness`                | `Authority/SignedAction.lean` (§8.5.2)  |
| Phase 3 | Replay is type-level impossible       | `replay_impossible`               | `Authority/SignedAction.lean` (§8.5.2)  |
| Phase 3 | Key-rotation registry mutation        | `replaceKey_updates_registry`     | `Authority/SignedAction.lean`           |
| Phase 4 | CBE round-trip + injectivity          | `*_roundtrip`, `*_encode_injective` | `Encoding/*.lean`                     |
| Phase 4 | Domain-separated sign inputs          | `signInput_*` (cross-deployment)  | `Encoding/SignInput.lean` (§8.8.5)      |
| Phase 6 | Dispute filing rejects malformed inputs | `fileDispute_rejects_*`         | `Disputes/Filing.lean`                  |
| Phase 6 | `disputeWithdraw` is idempotent       | `applyWithdraw_idempotent`        | `Disputes/Filing.lean`                  |
| Phase 6 | Evidence verifiers are deterministic  | `checkEvidence_deterministic`     | `Disputes/Evidence.lean`                |
| Phase 6 | `applyVerdict` is provably total under witness | `applyVerdict_under_witness_succeeds` | `Disputes/Verdict.lean` (Option-C) |
| Phase 6 | Dispute pipeline composes with monotonic deployments | `disputable_monotonic_total_supply_nondecreasing` | `Disputes/MonotonicDeployment.lean` |
| LP    | Local policies cannot lock out meta-actions | `localPolicy_meta_action_independent` | `Authority/SignedAction.lean`     |
| E-A   | EIP-712 wrap injectivity              | `eip712Wrap_injective`            | `Bridge/Eip712.lean`                    |
| E-B   | Bridge actor policy authorises only registry actions | `bridgePolicy_*` family | `Bridge/BridgeActor.lean`             |
| E-C   | Deposit / withdraw replay impossible  | `deposit_replay_blocked_by_consumed`, `withdraw_bumps_nextWdId` | `Bridge/Admissible.lean` |
| E-D   | SMT verifier completeness + soundness | `verifyProof_complete`, `verifyProof_sound` | `Bridge/WithdrawalRoot.lean` |
| E-D   | Finalisation is monotonic in L1 block | `isFinalised_monotonic_in_currentBlock` | `Bridge/Finalisation.lean`        |
| LX    | Locality / freeze-preservation typeclass firewalls | `LocalTo`, `FreezePreserving`, `FreezePreservingLawSet` | `Conservation.lean` |
| LX    | Registry-preservation classification  | `RegistryPreserving`              | `Authority/SignedAction.lean`           |
| H     | State-commit sub-state byte equality under CR | `commitExtendedState_subcommits_bytes_eq_under_collision_free` | `FaultProof/Commit.lean` (§15B.1)¹ |
| H     | Kernel step coherent with kernelOnlyApply | `recomputeCommitment_coherent_with_kernelOnlyApply` | `FaultProof/Coherence.lean` (§15B.2) |
| H     | Multi-step coherence with kernelOnlyReplay | `recomputeCommitment_chain_coherent_with_kernelOnlyReplay` | `FaultProof/Coherence.lean` (§15B.2) |
| H     | Bisection narrows under any response  | `range_narrows_on_response_{agree,disagree}` | `FaultProof/Game.lean` (§15B.3) |
| H     | Bisection converges after enough rounds | `bisection_converges_after_enough_rounds` | `FaultProof/Convergence.lean` (§15B.3) |
| H     | Disagreement persists along honest trace | `disagreement_persists_along_trace` | `FaultProof/Honesty.lean` (§15B.4)     |
| H     | Honest challenger wins at settlement  | `honest_challenger_wins_against_invalid_state_root` | `FaultProof/Settlement.lean` (§15B.4) |
| H     | Witness implies state-root wrong       | `faultProof_challenger_won_implies_state_root_wrong` | `FaultProof/Witness.lean` (§15B.6)² |

¹ The shipped theorem proves byte-equality of CBE-encoded sub-states under `CollisionFree hashBytes`.  Lifting bytes-equality to extensional state equality (`toList` equality) requires CBE encoder canonicality for `State` / `NonceState` / `KeyRegistry` / `LocalPolicies` / `BridgeState`, which is shipped at the structural level (`*_encode_deterministic` and round-trip lemmas) but not as a stand-alone `*_encode_injective` lemma for the map-backed sub-states; that's a Workstream-H follow-up.

² The shipped theorem decomposes a `FaultProofChallengerWon` witness's L1 attestation against an explicit `L1AttestationSemantics` deployment assumption (the operational implication "L1 watcher confirms ⇒ sequencer's claim ≠ canonical commit").  The L1 contract enforces this operationally; cross-stack verification (WU H.10.1 corpus) ratifies it.

The full per-theorem catalogue lives in source — each module's
`/-! ... -/` docstring names the Genesis-Plan section it
implements, and `#print axioms` confirms each theorem depends only
on the canonical three Lean built-ins (or a strict subset, e.g.
many encoding theorems use only `propext` and `Quot.sound`).

Modifying any TCB-tier property is a TCB change and triggers the
two-reviewer gate; modifying any non-TCB property needs one
reviewer.  The Phase-3, Workstream E-A, and Workstream E-D
properties additionally depend on trust assumptions about
deployment-supplied crypto (see "Trust assumptions" above).

## Std core integration

Canon's kernel uses **Lean core only**, no Mathlib or batteries.
Familiarity with these Std definitions is essential before
modifying the kernel:

| Std name              | Type                          | Role in Canon            |
|-----------------------|-------------------------------|--------------------------|
| `Std.TreeMap α β cmp` | structure                     | balanced ordered map (RB)|
| `TreeMap.empty`       | `TreeMap α β cmp`             | empty map                |
| `TreeMap.insert`      | `… → α → β → TreeMap …`       | insert / overwrite       |
| `m[k]?` / `find?`     | `… → α → Option β`            | lookup                   |
| `m[k]?.getD v`        | `… → α → β → β`               | lookup with default      |
| `TreeMap.foldl`       | `(δ → α → β → δ) → δ → … → δ` | order-determined fold    |

The TCB imports `Std.Data.TreeMap` only.  The full per-lemma audit
lives in `docs/std_dependencies.md`; reviewers consult it during
toolchain bumps.  Each addition to the kernel's import set must
update **both** `tcb_allowlist.txt` and `docs/std_dependencies.md`
in the same PR; CI blocks on un-allowlisted imports.

**Version strategy.**  Pin the Lean toolchain in `lean-toolchain`;
`scripts/setup.sh` validates archive SHA-256s against the
per-architecture pin baked into the script.  Bump only when a
specific feature is needed, and recompute the SHAs in the same PR.

## Implementation roadmap

Genesis Plan §12 lays out eight phases (0–7) plus cross-cutting
work units.  Status:

| Phase     | Title                              | Status   |
|-----------|------------------------------------|----------|
| 0         | Foundations                        | Complete |
| 1         | Kernel completion                  | Complete |
| 2         | Economic invariants                | Complete |
| 3         | Authority layer                    | Complete |
| 4-prelude | Positive-incentive mechanisms      | Complete |
| 4         | DSL and serialization              | Complete |
| 5         | Runtime and extraction             | Complete (Lean side; Rust-host WUs 5.4 / 5.7 / 5.8 / 5.11 deferred) |
| 6         | Disputes and adjudication          | Complete |
| 6-amend   | Phase-6 incentive integration      | Complete |
| E-A       | Ethereum: cryptographic adaptors   | Complete (Lean side; Rust adaptor crates deferred) |
| E-B       | Ethereum: identity and authority   | Complete (Lean side; Rust ingestor deferred) |
| E-C       | Ethereum: bridge laws              | Complete (Lean side; chain-level §7.6.4 / §7.6.5 follow-up) |
| E-D       | Ethereum: withdrawal proofs        | Complete |
| E-E       | Ethereum: Solidity contracts       | Complete |
| E-F       | Ethereum: cross-stack verification | Complete |
| LP        | Actor-scoped policies              | Complete (Lean side; Solidity mirror future work) |
| LX-M1     | Lex: macro skeleton + synthesizer  | Complete |
| LX-M2     | Lex: re-express 17 kernel laws     | Complete |
| LX-M3     | Lex: deployment manifests + governance | Complete |
| H         | Fault-proof migration              | Complete (Lean side; Rust off-chain observer deferred) |
| E-G       | Ethereum: documentation + amendment | Not started |
| 7         | Advanced capabilities              | Not started |

Read the Genesis Plan's per-phase work-unit breakdown and the
relevant workstream plan in `docs/` before starting new work.
Each WU has explicit deliverables, acceptance criteria, and
dependencies.

## Documentation rules

When changing behaviour, theorems, or formalisation status, update
in the same PR:

1. `docs/GENESIS_PLAN.md` — if the change affects the architecture,
   the formal model, the threat model, or the roadmap.  Bump the
   "Phase X status" subsection at the bottom of the relevant phase.
2. `README.md` — if project status, build commands, or quickstart
   change.
3. `CLAUDE.md` (and `AGENTS.md` — keep them byte-identical) — if
   conventions, build commands, or current-status summary change.

Canonical ownership: `docs/GENESIS_PLAN.md` owns the design; this
file owns engineering conventions and the day-to-day developer /
agent workflow; `README.md` owns the top-level introduction.

**Don't extend audit narratives in this file.**  Per-audit and
per-WU completion details belong in commit messages and PR
descriptions, where they have permanent provenance via git history.
This file describes the *current state*, not the path that got us
here.

## Pull request authoring policy (ABSOLUTE)

**Forbidden in PR summaries / descriptions / bodies:** session URLs
of the shape `https://claude.ai/code/session_*` (or any equivalent
agent-harness session permalink).  Examples of the forbidden form:

* `https://claude.ai/code/session_019S9v23eC235cqr76MNWe5S`
* `claude.ai/code/session_<any-id>`
* Any other URL whose path identifies a private agent-harness
  conversation.

**Why this rule exists.**

1. *Privacy / opacity.*  A session URL points at a private workspace
   artefact: full transcript, tool calls, intermediate code.  PR
   readers cannot open it; the link is dead from their perspective.
2. *Link rot.*  Sessions expire, compress, or get archived behind
   authentication.  A PR description that points at one will break
   in days or weeks.
3. *Provenance leakage.*  Session URLs embed harness internals
   (Claude Code vs Web vs Action, session-id format) that the PR's
   *content* (theorems, build posture) needn't disclose.
4. *Citation discipline.*  Per the "Names describe content, never
   provenance" rule, release-facing prose must describe what it
   documents, not the workflow that produced it.

**Allowed alternatives — what to cite instead.**

* The Genesis-Plan section number (e.g. `§4.12`, `§12 WU 0.2`).
* The headline theorem name + file path (e.g. `impl_refines_spec`
  in `LegalKernel/Kernel.lean`).
* The relevant workstream-plan document under `docs/`.

**Scope of the rule.**

* **In scope (forbidden):** PR descriptions / bodies; PR review
  comments; PR-edit `body` arguments to
  `mcp__github__update_pull_request`; cross-link inserts via
  `mcp__github__add_issue_comment`,
  `mcp__github__add_reply_to_pull_request_comment`.
* **Out of scope:** local commit messages (the agent harness's
  default `gh commit` template may auto-append a session footer to
  *commits*; this policy concerns *PR-level* surfaces).

**Enforcement.**  Before invoking
`mcp__github__create_pull_request` or
`mcp__github__update_pull_request`, scan the prepared `body` for
the regex
`https?://(?:www\.)?claude\.ai/code/session_[A-Za-z0-9]+` and strip
every match before submission.

## Current development status

**Build tag** (`kernelBuildTag` in `LegalKernel.lean`):
`"canon-audit-remediation"` (AR.22).  `Test/Umbrella.lean` pins
this value in a regression test, so any phase / milestone bump
must update both the constant and the test in the same PR.

**Test count.**  ~1845 tests across ~100 suites at the time of
the AR milestone (Workstream AR).  The exact number drifts with
every PR; `lake test` is the canonical query.  Unlike the build
tag, the test count is not pinned — only its monotonic growth is
enforced by individual regression tests landing alongside new
theorems.

**Workstream AR (Audit Remediation, see
`docs/audit_remediation_plan.md`)** is the most recent landing.
Highlights of the AR remediation pass:

  * AR.1: shared `Authority.signedActionDomain` constant (M-7).
  * AR.2: `RuntimeState.deploymentId` field threaded through
    `processSignedAction` / `bootstrap` / `replayWith` /
    `checkSignatureInvalidWith` plus `--deployment-id <hex>` CLI
    flag on both `canon` and `canon-replay` (the audit binary
    refuses to run without it).  Closes M-1 + M-5.
  * AR.3: `bootstrapFromSnapshot` chain-anchor check
    (`.anchorMismatch`) + `bootstrapFromAttestedSnapshot` wrapper.
    Closes M-2.
  * AR.5 / AR.6: regression pins for all 19 `Action` and 16 `Event`
    constructor indices (M-8, m-7).  New `Event.tag` projection.
  * AR.7: `Lex.Tools.Diff` widened to compare type + kind + tactic
    body, not just names (M-6).
  * AR.9: new `mock_import_audit` binary mechanically enforces
    "no production module imports `Test/*`" (M-10).
  * AR.10: real `@[extern]` annotations on `hashBytes` /
    `hashStream` / `hashImplementationIdentifier`, with default
    `runtime/canon-hash-fallback.c` forwarder + Lake `extern_lib`
    `canonHashFallback`.  Closes the cross-verification M+1
    finding.
  * AR.11: `synth_local_kindOnly` now refuses to admit
    resource-bearing statements without resource info; the new
    `dispatchSynthesizerResourceAware` is the production entry.
    Closes M+2.
  * AR.12: `lexlaw`'s `renderSyntax` uses `Syntax.reprint` for
    byte-fidelity with user source.  L010 / L022 lints exempted
    for kernel-built-in laws (`legalkernel.*` prefix).  Closes
    m-13.
  * AR.16 + AR.17: `Verdict.decode` enforces explicit
    signers/sigs length-match (m-17); `kernelOnlyApply`'s wildcard
    arm replaced by an exhaustive per-`Action`-constructor match
    (m-14).
  * AR.19: `fileDispute_rejects_indexOutOfRange` /
    `_duplicateDispute` theorems.
  * AR.20: `.github/CODEOWNERS` request-for-review surface for
    TCB-core files.
  * AR.21: `withdraw.pre` strengthened with positivity (`0 <
    amount`).  Closes m-4.

**Deferred from AR:**

  * **AR.4** (encoder injectivity quartet for the five map-backed
    sub-states) is a 9–16 working-day proof track per the plan; it
    remains scoped but unshipped on this branch.  The load-bearing
    FaultProof chain still lifts via the existing bytes-eq lemma
    (`commitExtendedState_subcommits_bytes_eq_under_collision_free`)
    and this file's footnote 1 stays in place documenting the
    lift.

  * **AR.18 mechanical visibility** (the `private`-modifier
    promotion for `applyVerdictUnchecked`) is documented in the
    function's docstring but not lexically enforced — Lean 4's
    `private` is file-local, and the legitimate cross-file
    callers (`Rewards.applyVerdictWithRewardsUnchecked`,
    `Rewards.applyVerdictWithRewardsMultiUnchecked`) would need to
    be moved into `Verdict.lean` to make `private` work.  AR.18's
    review-gate contract (a clearly-labelled "UNCHECKED — TESTING
    ONLY" docstring) remains the operational guard.  See
    `docs/GENESIS_PLAN.md` §15C.6 for the deferral rationale.

**TCB audit (latest run).**  `#print axioms` on every kernel,
Phase-2, Phase-3, Phase-4, Phase-5, Phase-6, and Workstream-H
theorem returns a subset of `[propext, Classical.choice,
Quot.sound]`.  No custom axioms have been introduced in any phase.
`Verify` and `hashBytes` are `opaque`, not `axiom`, so they do
not appear in the audit output of theorems that mention them.
Workstream H adds one new opaque (`l1FaultProofVerifier` in
`LegalKernel/FaultProof/Witness.lean`) for the deployment-side L1
event watcher; per the same opaque pattern as `Verify` / `hashBytes`,
it does not appear in `#print axioms` output.

**TCB import discipline.**  `Tools.Common.tcbInternalImports`
enumerates the project-internal modules each TCB-core file
(`Kernel.lean`, `RBMapLemmas.lean`) may import — only
`LegalKernel.Kernel` and `LegalKernel.RBMapLemmas` themselves.
This is a *specific allowlist*, not a `LegalKernel.*` namespace
pattern: a TCB-core file that tries to import e.g.
`LegalKernel.Laws.Transfer` fails the audit and blocks the merge.

**Test patterns.**  Tests use two complementary patterns:

1. **Value-level**: assert `==` between expected and actual results
   (catches definitional drift / Std-API renames at runtime).
2. **Term-level API stability**: ascribe a `let _proof : T :=
   theorem ...` binding whose type uses the theorem's exact
   signature (catches signature changes at elaboration time,
   before the `IO Unit` body runs).

The `Authority.SignedAction` suite uses term-level API checks for
`nonce_uniqueness` and `replay_impossible` (rather than value-level
admissibility witness construction) because the `Verify` opaque
cannot be reduced at the Lean level — the runtime adaptor wires
the actual cryptographic implementation.  The algebraic core of
the theorems (the post-advance nonce inequality) is value-level
checked separately.  The shared `LegalKernel/Test/MockCrypto.lean`
module supplies `mockVerify` / `mockSign` for happy-path coverage
that the production opaque `Verify` (which returns `false` at the
Lean level) cannot exercise.

**Active development history.**  Per-audit and per-WU completion
narratives live in git history (see `git log --grep="WU"` /
`git log --grep="audit"`), not in this file.  Each major audit
pass produces both a commit and (typically) a Genesis-Plan
amendment in `docs/GENESIS_PLAN.md`; consult that document for the
formal status of every property.

## Vulnerability reporting

Canon is research-stage software.  If you discover a logic bug in
the kernel module (e.g. a counterexample to `impl_noop_if_not_pre`,
or a state advance that bypasses the `if` in `step_impl`), open an
issue with the `kernel-soundness` label.  Such reports gate any
in-flight PR; the two-reviewer rule applies to the fix.

For non-kernel issues (laws, tooling, documentation), the standard
issue tracker workflow applies.

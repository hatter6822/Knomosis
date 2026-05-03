<!--
  Canon — A Legal Kernel
  Adapted from the structure of Orbcrypt's CLAUDE.md
  (https://github.com/hatter6822/Orbcrypt/blob/main/CLAUDE.md)
  with project-specific guidance for Canon's Std-only, kernel-centric
  Lean 4 codebase.
-->

# CLAUDE.md — Canon project guidance

## What this project is

Canon is a **proof-carrying state transition system** built in Lean 4.
It is an *implementation* of the Genesis Plan
(`docs/GENESIS_PLAN.md`): a small, parametric, law-free kernel where
"legality" is a Lean type, every state change is accompanied by a
machine-checkable proof of admissibility, and global system properties
(determinism, refinement, no-silent-illegality, invariant
preservation) are guaranteed by inductive theorems rather than by
trust in operators.

Current status: **Phases 0 – 2 complete.**  Phase 0 (Foundations)
landed the kernel skeleton, the canonical transfer law, the build
pipeline, and the Genesis Plan.  Phase 1 (Kernel Completion) added
the §8.3 RBMap proof library, the §4.3 balance lemmas, the §4.9
multi-step / law-set reachability extensions, the Phase-1 audit
tooling (`lake exe count_sorries`, `lake exe tcb_audit`), and the
WU-1.6 / WU-1.13 documentation.  Phase 2 (Economic Invariants)
landed the §8.1 `TotalSupply` quantity functional, `transfer_conserves`
(§4.11.1), the `IsConservative` typeclass, the `mint`/`burn`
non-conservative laws (with explicit non-conservation witnesses), the
`ConservativeLawSet` machinery, the §5.3 `total_supply_global`
theorem, and the `freezeResource` / `FrozenForResource` immutability
layer.  Phases 3 – 7 (Authority layer, DSL and serialization, Runtime
and extraction, Disputes and adjudication, Advanced capabilities) are
scoped in §12 of the Genesis Plan and have not yet started.

Canonical source of truth for the design: `docs/GENESIS_PLAN.md`.
Where this file disagrees with the Genesis Plan, the Genesis Plan
wins; CLAUDE.md is engineering guidance, not specification.

## Build and run

```bash
# Recommended: use the setup script.  It pins the Lean version,
# verifies all downloads with SHA-256, and records a binary integrity
# snapshot on first run.
./scripts/setup.sh           # full setup; idempotent
./scripts/setup.sh --build   # full setup + lake build
./scripts/setup.sh --quiet   # suppress informational logs

# Manual alternative (skip integrity verification):
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
  | sh -s -- -y --default-toolchain none
elan toolchain install "$(cat lean-toolchain)"

# Daily commands (after setup):
source ~/.elan/env
lake build                          # full project build
lake build LegalKernel.Kernel       # kernel only (fastest feedback loop)
lake build LegalKernel.RBMapLemmas  # §8.3 fold lemmas only (fast)
lake build LegalKernel.Conservation # Phase-2 economic-invariants framework
lake build LegalKernel.Laws.Transfer
lake build LegalKernel.Laws.Mint    # Phase-2 mint law
lake build LegalKernel.Laws.Burn    # Phase-2 burn law
lake build LegalKernel.Laws.Freeze  # Phase-2 freeze marker + invariant
lake test                           # run Tests.lean driver (83 tests)
lake exe count_sorries              # WU 1.12: zero-sorry kernel gate
lake exe tcb_audit                  # WU 1.11: TCB allowlist gate
```

**Toolchain:** Lean 4 v4.29.1 (pinned in `lean-toolchain`; the
latest stable Lean release as of the last toolchain bump).  The
`scripts/setup.sh` script handles toolchain install with SHA-256
integrity verification of every artefact (elan installer, elan
binary, Lean toolchain archive) — see the script header for the
audit log.  Bumping the toolchain version requires recomputing the
four `LEAN_TOOLCHAIN_SHA256_*` constants and updating this section
in the same PR.

## Module build verification (mandatory)

**Before committing any `.lean` file**, build the specific module:

```bash
lake build LegalKernel.<Module.Path>
```

Examples:
- Edited `LegalKernel/Kernel.lean`     → `lake build LegalKernel.Kernel`
- Edited `LegalKernel/Laws/Transfer.lean` → `lake build LegalKernel.Laws.Transfer`

**`lake build` (default target) is sufficient at Phases 0 – 2**
because `LegalKernel.lean` re-exports the kernel, the §8.3 RBMap
proof library, the Phase-2 economic-invariants framework, and every
deployed law (transfer, mint, burn, freeze), so every TCB / law /
kernel file is reachable from the default target.  This convention
may change in later phases when the law set grows; check the
`lean_lib LegalKernel` `roots` field in `lakefile.lean` if in doubt.

After any source change, also run:

* `lake test` — runs the test driver (83 tests across eight suites
  as of Phase 2; was 43 in Phase 1, 24 in Phase 0).  Catches semantic
  regressions that elaboration-only checks miss (e.g. the §4.11
  self-transfer fix would silently survive a build but break a test).
  Each new Phase-1+ theorem additionally has a term-level
  API-stability test whose elaboration fails if the theorem signature
  changes.
* `lake exe count_sorries` — fails if any kernel-TCB module
  (`Kernel.lean`, `RBMapLemmas.lean`, `Laws/Transfer.lean`) has a
  `sorry` in proof position.  The detector pre-masks `--` line
  comments, `/- … -/` block comments / docstrings, and `"…"`
  string literals before pattern-matching, so a `sorry` mention
  inside a comment or string is correctly *not* flagged.
* `lake exe tcb_audit` — fails if a TCB core module imports anything
  not on `tcb_allowlist.txt` *or* in `Tools.Common.tcbInternalImports`
  (the explicit list of project-internal modules a TCB core file is
  allowed to import).  The internal-imports list is enumerated, not
  pattern-based, so a TCB core file cannot silently depend on a
  non-TCB sibling like `LegalKernel.Laws.Transfer`.

## Source layout

```
canon/
├── lakefile.lean                  -- Lake config: lib + test driver +
│                                     canon exe + audit executables.
├── lean-toolchain                 -- pinned Lean version (Section 13.4).
├── tcb_allowlist.txt              -- WU 1.11 TCB import allowlist.
├── Main.lean                      -- placeholder runtime; Phase 5 replaces it.
├── Tests.lean                     -- @[test_driver]; runs every test module.
├── LegalKernel.lean               -- umbrella import (kernel + RBMap + Conservation + laws).
├── LegalKernel/
│   ├── Kernel.lean                -- §4.12 trusted core (TCB).
│   ├── RBMapLemmas.lean           -- §8.3 RBMap proof library (TCB).
│   ├── Conservation.lean          -- §8.1 / §5.3 Phase-2 economic invariants
│   │                                 framework: TotalSupply, IsConservative,
│   │                                 ConservativeLawSet, total_supply_global
│   │                                 (non-TCB).
│   ├── Laws/
│   │   ├── Transfer.lean          -- §4.11 transfer law + Phase-2
│   │   │                             transfer_conserves + IsConservative
│   │   │                             instance.
│   │   ├── Mint.lean              -- Phase-2 mint law + non-conservation.
│   │   ├── Burn.lean              -- Phase-2 burn law + non-conservation.
│   │   └── Freeze.lean            -- Phase-2 freezeResource marker +
│   │                                 FrozenForResource invariant.
│   └── Test/
│       ├── Framework.lean         -- minimal IO-based test harness + emptyState.
│       ├── KernelTests.lean       -- value-level kernel tests (22 cases).
│       ├── RBMapLemmasTests.lean  -- §8.3 fold-lemma tests (8 cases).
│       ├── Umbrella.lean          -- umbrella-module smoke tests (2 cases).
│       ├── ConservationTests.lean -- Phase-2 conservation tests (12 cases).
│       └── Laws/
│           ├── Transfer.lean      -- transfer-law tests (16 cases incl. Phase 2).
│           ├── Mint.lean          -- Phase-2 mint tests (7 cases).
│           ├── Burn.lean          -- Phase-2 burn tests (9 cases).
│           └── Freeze.lean        -- Phase-2 freeze tests (7 cases).
├── Tools/
│   ├── Common.lean                -- shared TCB constants + readFileSafe.
│   ├── TcbAudit.lean              -- WU 1.11 TCB allowlist enforcer.
│   └── CountSorries.lean          -- WU 1.12 sorry-counting CI gate.
├── scripts/
│   └── setup.sh                   -- SHA-256-verified toolchain installer.
├── .github/workflows/
│   └── ci.yml                     -- lake build + test + count_sorries +
│                                     tcb_audit on PR / push.
├── CLAUDE.md                      -- this file.
├── README.md                      -- project entry point.
└── docs/
    ├── GENESIS_PLAN.md            -- canonical design document.
    ├── decidability_discipline.md -- WU 1.6 (decPre) discipline.
    ├── std_dependencies.md        -- WU 1.13 Std lemma audit.
    └── economic_invariants.md     -- Phase 2 design + proof-obligation note.
```

### Module dependency graph (Phases 0 – 2)

```
LegalKernel.Kernel        (TCB, §4.12 + §4.3 balance lemmas + §4.9 reachability)
  └──── imports LegalKernel.RBMapLemmas
LegalKernel.RBMapLemmas   (TCB, §8.3 fold + insert lemmas)
LegalKernel.Conservation  (non-TCB; §8.1 TotalSupply + §5.3 framework)
  └──── imports Kernel + RBMapLemmas
LegalKernel.Laws.Transfer (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.Mint     (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.Burn     (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.Freeze   (non-TCB; depends on Kernel + Conservation +
                                    Transfer + Mint + Burn)
LegalKernel.Test.Framework (no Kernel dependency)
LegalKernel.Test.KernelTests
LegalKernel.Test.RBMapLemmasTests
LegalKernel.Test.ConservationTests
LegalKernel.Test.Laws.{Transfer, Mint, Burn, Freeze}
                                 │
LegalKernel  (umbrella) ─────────┘
                                 │
Main.lean / Tests.lean ──────────┘

Tools.TcbAudit       (parses TCB sources; no Lean-level dep on the kernel).
Tools.CountSorries   (parses every .lean under LegalKernel/; no Lean-level dep).
```

The kernel has **zero** external Lean-package dependencies.
`Std.Data.TreeMap` is part of Lean core (since Lean ≥ 4.10), not a
separate Lake package.  The TCB therefore equals exactly the Lean
core distribution plus the trusted-core modules of this repository
(`Kernel.lean` + `RBMapLemmas.lean`).  Phase 2's economic-invariants
framework is **not** TCB: `Conservation.lean` and the four
`Laws/*.lean` modules are deployment-facing infrastructure, with
bugs scoped to deployment-level claims (not kernel invariants).

## Reading large files

`docs/GENESIS_PLAN.md` is ~4200 lines / ~180 KB.  Read it in chunks
with `Read(file_path, offset=…, limit=500)` rather than the whole
file.  The table of contents at the top of the document maps section
numbers to the line ranges you actually need.

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
  `lake build 2>&1 | tail -80`).  For very large output, redirect to
  a temp file and `Read` it in chunks.

**Rule of thumb:** if a command might return more than ~100 lines,
limit it upfront.

## Background-agent file-change protection

Background agents (Task tool with `run_in_background: true`) run
concurrently and may finish after the foreground agent has already
modified the same files.  Their stale writes will silently overwrite
foreground progress.  **Prevent this proactively:**

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

- **Two reviewer rule for kernel-touching changes (ABSOLUTE).**  Any
  change to `LegalKernel/Kernel.lean` or `LegalKernel/RBMapLemmas.lean`
  (the latter is Phase 1+) requires two reviewers per Genesis Plan
  §13.6.  Law modules and tests require one reviewer.

- **No `sorry` in kernel-adjacent code (ABSOLUTE).**  Phase 0's
  exit gate was "zero `sorry` in `LegalKernel/Kernel.lean` and
  `LegalKernel/Laws/Transfer.lean`".  Phase 1 widened this to
  *also* cover `LegalKernel/RBMapLemmas.lean` and added the
  `count_sorries` CI tool that enforces it.  The mechanical check is
  ```bash
  lake exe count_sorries
  ```
  (or, equivalently and more pessimistically,
  `grep -rnE '(:= sorry|by sorry|exact sorry|^[[:space:]]*sorry[[:space:]]*$)' LegalKernel/`).
  CI runs `lake exe count_sorries` on every PR and blocks the merge
  on a non-zero kernel-TCB count.  Comments referencing the *word*
  "sorry" (e.g. "no `sorry` in this file") are allowed; only the
  *term* `sorry` in proof position is forbidden.

- **No custom axioms (ABSOLUTE).**  The kernel may use Lean's
  built-in axioms (`propext`, `Classical.choice`, `Quot.sound`) but
  must not introduce its own.  Any Phase 1+ work that adds an
  `axiom` declaration is a Genesis-Plan amendment and requires the
  two-reviewer gate.

- **Std-core only in the kernel TCB.**  The kernel imports
  `Std.Data.TreeMap` (Lean core, not batteries) and the sibling TCB
  module `LegalKernel.RBMapLemmas` (also Std-core only).  The
  `tcb_audit` tool (`lake exe tcb_audit`) compares each TCB module's
  direct-import set against `tcb_allowlist.txt`; CI runs this on
  every PR.  Adding Mathlib or batteries to either TCB module is a
  TCB expansion and must go through the §13.6 amendment process,
  which includes an entry in `tcb_allowlist.txt` (with a comment
  explaining the dependency) and the two-reviewer gate.  Law modules
  may import other things if absolutely necessary, but the default
  is "Std core only" until a specific need is justified.

- **`autoImplicit := false` and `linter.missingDocs := true`.**  The
  lakefile enforces both project-wide:
  - `autoImplicit := false` (and its `relaxedAutoImplicit` sibling)
    forbids Lean from silently introducing universe / type variables
    that the proof author didn't declare.
  - `linter.missingDocs := true` makes the *absence* of a `/-- … -/`
    docstring on a public surface (def, theorem, structure field,
    inductive constructor) a build warning, surfacing the
    documentation rule below as a mechanical check rather than a
    review-time observation.

  `linter.unusedVariables := true` is also set, surfacing dead bindings.

- **Decidability discipline (Genesis Plan §13.6 step 2).**  Every
  `Transition.decPre` field should be definable as
  `fun _ => inferInstance` whenever the precondition is built from
  arithmetic comparisons, `Nat` operations, and finite conjunctions.
  If a law needs a hand-written `Decidable` derivation, that is a
  signal to security-review the law (§14.8): preconditions that
  resist `inferInstance` often hide an unbounded quantifier or a
  non-computable predicate that breaks the executable path.

- **Naming conventions:**
  - Theorems and lemmas: `snake_case` (Lean / Mathlib style) — e.g.,
    `impl_refines_spec`, `transfer_conserves`.
  - Structures and types: `CamelCase` — e.g., `Transition`, `Legal`,
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
    block can say "added in WU 2.5") and in commit messages, branch
    names, and planning documents.  The boundary is sharp: the
    docstring may carry a process tag, the identifier may not.
  - **Enforcement.**  Before landing any new declaration, scan the
    diff:
    ```bash
    git diff --cached -U0 -- '*.lean' \
      | grep -E '^\+(def|theorem|structure|class|instance|abbrev|lemma|noncomputable)' \
      | grep -iE 'workstream|\bws[0-9]|\bwu[0-9]|\bphase[0-9_]|audit|\bf[0-9]{2}\b|\btmp\b|\btodo\b|\bfixme\b|claude_|session_'
    ```
    A non-empty result is a review-blocking naming violation.

- **Proof style:**
  - Prefer tactic mode (`by …`) for non-trivial proofs.
  - Use `calc` blocks for equational reasoning chains.
  - Use `have` for intermediate steps with descriptive names.
  - Comment proof strategy at the top of each non-obvious theorem.
  - Avoid `decide` on large finite types (performance trap; the
    kernel has no large finite types yet, but laws may).

- **Documentation:**
  - Every `.lean` file begins with a `/-! ... -/` module docstring
    naming the Genesis-Plan section it implements.
  - Every public `def` / `theorem` / `structure` / `instance` has a
    `/-- ... -/` docstring.
  - Where a definition deliberately tracks a Genesis-Plan section
    (e.g. `transfer` is §4.11), say so in the docstring so future
    readers can cross-reference.

- **Import discipline:**  Import by full path within the project
  (`import LegalKernel.Kernel`).  Re-export top-level definitions via
  `LegalKernel.lean` (the umbrella module) so downstream consumers
  can `import LegalKernel` and get everything.

- **Git practices:**  One commit per completed work unit.  Commit
  messages reference the WU number when applicable: `"WU 0.2:
  Kernel module skeleton"`.  All commits must pass `lake build`
  AND `lake test` — never commit broken or untested code.

## Type-level design properties enforced in Phases 0 – 2

The Genesis Plan promises a small set of type-level guarantees
(§1, §5).  The kernel and the Phase-2 economic-invariants framework
mechanise each of the following:

| #  | Property                                | Lean theorem                          | Phase / File                       |
|----|-----------------------------------------|---------------------------------------|------------------------------------|
| 1  | Determinism                             | typing of `step_impl`                 | 0 / `Kernel.lean`                  |
| 2  | No silent illegality                    | `impl_noop_if_not_pre`                | 0 / `Kernel.lean`                  |
| 3  | Refinement                              | `impl_refines_spec`                   | 0 / `Kernel.lean`                  |
| 4  | Invariant preservation                  | `invariant_preservation`              | 0 / `Kernel.lean`                  |
| 5  | Compositionality of invariants          | `invariants_compose`                  | 0 / `Kernel.lean`                  |
| 6  | Certified ≡ executable                  | `apply_certified_eq_step_impl`        | 0 / `Kernel.lean`                  |
| 7  | Pointwise balance (write-then-read)     | `getBalance_setBalance_same/_other`   | 1 / `Kernel.lean` (§4.3)           |
| 8  | Reachability is reflexive-transitive    | `Reachable.refl`, `Reachable.trans`   | 1 / `Kernel.lean` (§4.9)           |
| 9  | Per-law-set invariant preservation      | `invariant_preservation_via_laws`     | 1 / `Kernel.lean` (§4.10)          |
| 10 | Per-resource accounting on `setBalance` | `totalSupply_setBalance`              | 2 / `Conservation.lean`            |
| 11 | Transfer preserves total supply         | `transfer_conserves`                  | 2 / `Laws/Transfer.lean` (§4.11.1) |
| 12 | Transfer is local to its resource       | `transfer_does_not_touch_other_resources` | 2 / `Laws/Transfer.lean` (§4.11.2) |
| 13 | Transfer is `IsConservative`            | `transfer_isConservative`             | 2 / `Laws/Transfer.lean` (§5.3)    |
| 14 | Mint is non-conservative                | `mint_not_conservative`               | 2 / `Laws/Mint.lean` (§5.6)        |
| 15 | Burn is non-conservative                | `burn_not_conservative`               | 2 / `Laws/Burn.lean` (§5.6)        |
| 16 | Global supply preservation              | `total_supply_global` / `…_via_law_set` | 2 / `Conservation.lean` (§5.3)   |
| 17 | Frozen-resource preservation by transfer/mint/burn | `*_preserves_freeze` (3 lemmas) | 2 / `Laws/Freeze.lean` (§4.10) |

These are not stubs.  They are real Lean theorems that the build
will not accept with a `sorry`, and `#print axioms` confirms that
each depends only on the three Lean built-in axioms (`propext`,
`Classical.choice`, `Quot.sound`).  Modifying any of properties
#1 – #9 (kernel-TCB) is a TCB change and triggers the two-reviewer
gate; properties #10 – #17 (Phase-2 deployment infrastructure) are
non-TCB and need only one reviewer.

The §8.3 RBMap proof library (`LegalKernel/RBMapLemmas.lean`) ships
the supporting `find?_insert_self`, `find?_insert_other`, and
`Nat`-summing fold lemmas (`sumValues_eq_values_sum`,
`sumValues_insert_absent`, `sumValues_insert_present`) that
property #7 above and the Phase-2 `totalSupply_setBalance` master
lemma both depend on.

## Std core integration

Canon's kernel uses **Lean core only**, no Mathlib or batteries.
Familiarity with these definitions is essential before modifying the
kernel:

| Std name              | Type                        | Role in Canon                |
|-----------------------|-----------------------------|------------------------------|
| `Std.TreeMap α β cmp` | structure                   | balanced ordered map (RB)    |
| `TreeMap.empty`       | `TreeMap α β cmp`           | empty map (also `∅`)         |
| `TreeMap.insert`      | `… → α → β → TreeMap …`     | insert / overwrite           |
| `m[k]?` / `find?`     | `… → α → Option β`          | lookup                       |
| `m[k]?.getD v`        | `… → α → β → β`             | lookup with default          |
| `TreeMap.foldl`       | `(δ → α → β → δ) → δ → … → δ` | order-determined fold     |

**Required Std modules (Phases 0 – 1):**

- `Std.Data.TreeMap` — the ordered finite-map backing `BalanceMap`,
  imported by both `Kernel.lean` and `RBMapLemmas.lean`.

The full per-lemma audit lives in `docs/std_dependencies.md`
(WU 1.13); reviewers consult it during toolchain bumps.

Future phases will add modules (e.g. `Std.Data.HashMap` for the event
log, `Std.Data.Nat.Lemmas` for Nat-arithmetic helpers).  Each
addition to the kernel's import set must update **both**
`tcb_allowlist.txt` (WU 1.11) and `docs/std_dependencies.md` (WU 1.13)
in the same PR; CI will block on un-allowlisted imports.

**Version strategy:**  Pin the Lean toolchain in `lean-toolchain`;
the script `scripts/setup.sh` validates the archive's SHA-256
against the per-architecture pin baked into the script.  Bump the
toolchain only when a specific feature is needed, and recompute
the SHAs in the same PR.

## Implementation roadmap

Genesis Plan §12 lays out eight phases (0–7) plus cross-cutting work
units.  Brief summary:

| Phase | Title                       | Work units (Genesis §12) | Status      |
|-------|-----------------------------|--------------------------|-------------|
| 0     | Foundations                 | 0.1–0.5                  | Complete    |
| 1     | Kernel completion           | 1.1–1.13                 | Complete    |
| 2     | Economic invariants         | 2.1–2.9                  | Complete    |
| 3     | Authority layer             | 3.1–3.10+                | Not started |
| 4     | DSL and serialization       | 4.x                      | Not started |
| 5     | Runtime and extraction      | 5.x                      | Not started |
| 6     | Disputes and adjudication   | 6.x                      | Not started |
| 7     | Advanced capabilities       | 7.x                      | Not started |

Read the Genesis Plan's per-phase work-unit breakdown before
starting any new work.  Each work unit has explicit deliverables,
acceptance criteria, and dependencies.

## Documentation rules

When changing behaviour, theorems, or formalisation status, update in
the same PR:

1. `docs/GENESIS_PLAN.md` — if the change affects the architecture,
   the formal model, the threat model, or the roadmap.  Specifically
   bump the "Phase X status" subsection at the bottom of the relevant
   phase.
2. `README.md` — if project status, build commands, or quickstart
   change.
3. `CLAUDE.md` — if conventions, build commands, or project status
   change.

Canonical ownership: `docs/GENESIS_PLAN.md` owns the design.  This
file (`CLAUDE.md`) owns the engineering conventions and the
day-to-day developer / agent workflow.  `README.md` owns the
top-level introduction.

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
4. *Citation discipline.*  Per the **Names describe content, never
   provenance** rule above, release-facing prose must describe what
   it documents, not the workflow that produced it.

**Allowed alternatives — what to cite instead.**

* The Genesis-Plan section number (e.g. `§4.12`, `§12 WU 0.2`).
* The headline theorem name + file path
  (e.g. `impl_refines_spec` in `LegalKernel/Kernel.lean`).
* This CLAUDE.md changelog entry that records the work
  (e.g. "WU 0.2 — Kernel module skeleton").

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

## Active development status

**Current Phase:** Phases 0 – 2 Complete; Phase 3 (Authority Layer)
is next.

WU 0.1 (Lean toolchain pin & Lake project skeleton) — complete:
- `lean-toolchain` pinned to `leanprover/lean4:v4.29.1` (the latest
  stable Lean release).
- `lakefile.lean` with `LegalKernel` library, `canon` placeholder
  exe, and `Tests` test driver (wired via `@[test_driver]`).  Strict
  hygiene: `autoImplicit := false`, `relaxedAutoImplicit := false`,
  `linter.unusedVariables := true`, `linter.missingDocs := true`.
- `Main.lean` placeholder runtime.
- `.gitignore` covering `.lake/`, `build/`, OS / editor noise.
- `scripts/setup.sh` SHA-256-verified setup script (`shellcheck`
  clean, fast-path skip, defense-in-depth binary integrity snapshot).
- `lake build` succeeds on a clean checkout.

WU 0.2 (Kernel module skeleton) — complete:
- `LegalKernel/Kernel.lean` ships the literal §4.12 listing.
- Zero `sorry`, zero custom axioms.  Each of the five kernel
  theorems (`impl_refines_spec`, `impl_noop_if_not_pre`,
  `apply_certified_eq_step_impl`, `invariant_preservation`,
  `invariants_compose`) `#print axioms` to exactly
  `[propext, Classical.choice, Quot.sound]` — the Lean built-in
  set CLAUDE.md explicitly allows.
- `lake build LegalKernel.Kernel` succeeds with strict linters on.
- Note: the original draft's `Std.Data.RBMap` is replaced by
  `Std.Data.TreeMap` (Lean core ≥ 4.10; same red-black-tree
  semantics; `Std`-only rule preserved).
- The non-TCB `kernelBuildTag` constant lives in the umbrella
  `LegalKernel.lean` module, *not* in `Kernel.lean`, so the WU 1.11
  TCB audit tool can enumerate the trusted core without seeing
  convenience constants.

WU 0.3 (`transfer` law) — complete:
- `LegalKernel/Laws/Transfer.lean` ships the §4.11 transfer law.
- Self-transfer fix preserved verbatim (read receiver balance from
  post-debit state).
- `decPre := fun _ => inferInstance` discipline followed.
- Decidability smoke-test: `example : Decidable ((transfer …).pre s)
  := inferInstance`.
- Conservation theorem `transfer_conserves` is **deferred to Phase 2**
  (depends on §8.3 fold lemmas from Phase 1) so Phase 0 modules are
  `sorry`-free.

WU 0.4 (CI) — complete:
- `.github/workflows/ci.yml` runs `lake build` and `lake test` on
  every PR to `main` and on direct pushes to `main`.  Phase 1
  extended this to also run `lake exe count_sorries` (WU 1.12) and
  `lake exe tcb_audit` (WU 1.11).
- Third-party actions (`actions/checkout`, `leanprover/lean-action`)
  pinned to **commit SHAs** with version comments — the only
  immutable-release form per GitHub's supply-chain guidance.
- Concurrency group cancels in-flight runs on force-push.
- `permissions: contents: read` (no workflow step writes to the repo).

WU 0.5 (Genesis Plan) — complete (predates this branch).

WU 1.1 – 1.4 (RBMap proof library, §8.3) — complete:
- `LegalKernel/RBMapLemmas.lean` (TCB) ships pointwise insert
  lemmas and `Nat`-summing fold lemmas:
  - WU 1.1: `find?_insert_self`, `find?_insert_other`.
  - WU 1.2: `sumValues_insert_absent` (key absent case).
  - WU 1.3: `sumValues_insert_present` (key present, additive form).
  - WU 1.4: `sumValues_eq_values_sum` (the canonical
    sum-of-values form).
- Proofs go through `Std.TreeMap.toList_insert_perm`, `List.Perm`,
  and `Std.DTreeMap.Equiv.of_forall_constGet?_eq`; no Mathlib, no
  custom axioms.

WU 1.5 (Balance lemmas, §4.3) — complete:
- `getBalance_setBalance_same` and `getBalance_setBalance_other`
  proved in `LegalKernel/Kernel.lean`, using
  `RBMap.find?_insert_self` and `RBMap.find?_insert_other` from
  WU 1.1.

WU 1.6 (Decidability discipline) — complete:
- `docs/decidability_discipline.md` records the
  `decPre := fun _ => inferInstance` rule, the security-review
  trigger when `inferInstance` does not resolve, and the manual
  audit grep.

WU 1.7 – 1.9 (Reachability extensions, §4.9 / §4.10) — complete:
- `Reachable.refl` and `Reachable.trans` close `Reachable` under
  the standard refl-trans laws.
- `ReachableViaLaws L s0 s` restricts reachability to a deployed
  law set.
- `reachable_of_reachable_via_laws` embeds the restricted form
  into the unrestricted one.
- `invariant_preservation_via_laws` is the law-set-indexed variant
  of the §4.10 central theorem; Phase 2's `total_supply_global`
  argument depends on it.

WU 1.10 (Package & document `RBMapLemmas`) — complete:
- `LegalKernel.lean` umbrella re-exports `RBMapLemmas` so
  downstream callers can `import LegalKernel`.
- `kernelBuildTag` bumped to `"canon-phase-1-kernel-completion"`;
  the Umbrella test suite verifies the bump.

WU 1.11 (TCB-audit tool) — complete:
- `Tools/TcbAudit.lean` and `tcb_allowlist.txt` ship; the audit
  enumerates direct imports of `Kernel.lean` and `RBMapLemmas.lean`
  and rejects any not on the allowlist.  CI runs `lake exe
  tcb_audit` after `lake build`.

WU 1.12 (`count_sorries`) — complete:
- `Tools/CountSorries.lean` walks `LegalKernel/` and counts `sorry`
  occurrences in proof position.  CI runs `lake exe count_sorries`
  and fails on any kernel-TCB hit (`Kernel.lean`,
  `RBMapLemmas.lean`, `Laws/Transfer.lean`).

WU 1.13 (Std-dependency audit) — complete:
- `docs/std_dependencies.md` enumerates every `Std`-library lemma
  the TCB invokes, with stability notes and a per-toolchain-bump
  review checklist.

WU 2.1 – 2.9 (Phase 2: Economic Invariants) — complete:
- WU 2.1: `LegalKernel/Conservation.lean` ships `genesisState`, the
  §8.1 `TotalSupply` definition, the sanity lemma
  `totalSupply_genesis_eq_zero`, the more general
  `totalSupply_eq_zero_of_no_resource`, and the master accounting
  lemma `totalSupply_setBalance` (the `Nat`-equation that every
  per-law conservation proof reduces to).
- WU 2.2 + 2.3: `LegalKernel/Laws/Transfer.lean` proves
  `transfer_conserves` (§4.11.1).  The proof is *uniform* over the
  distinct-actor and self-transfer cases — the §4.11 self-transfer
  fix in `transfer.apply_impl` makes the case-split unnecessary at
  the conservation level.  Also lands `transfer_other_resource_untouched`
  (state-level) and `transfer_does_not_touch_other_resources`
  (pointwise; §4.11.2), both via `RBMap.find?_insert_other`.
- WU 2.4: `IsConservative` typeclass in `Conservation.lean`;
  `transfer_isConservative` instance in `Laws/Transfer.lean` combines
  `transfer_conserves` (at the transferred resource) with
  `transfer_conserves_other_resource` (at every other resource).
- WU 2.5: `LegalKernel/Laws/Mint.lean` and `LegalKernel/Laws/Burn.lean`
  ship the two non-conservative balance mutators with `decPre := fun _
  => inferInstance` and a single `setBalance` transformer each.  Both
  ship `totalSupply_after_*` accounting corollaries.
- WU 2.6: `mint_not_conservative` and `burn_not_conservative` deliver
  explicit non-conservation witnesses; both negate the
  `IsConservative` typeclass directly.
- WU 2.7: `ConservativeLawSet` structure in `Conservation.lean` is
  the §6.2 type-level firewall — mint/burn cannot be added because
  no `IsConservative` instance exists.
- WU 2.8: `total_supply_global` (§5.3 verbatim) plus the
  typeclass-driven corollary `total_supply_global_via_law_set`.
- WU 2.9: `LegalKernel/Laws/Freeze.lean` ships the `freezeResource r`
  no-op marker, the `FrozenForResource r snap` invariant (a closure
  over the snapshotted per-resource `BalanceMap`), and the four
  preservation lemmas (`freezeResource_preserves_freeze` trivially;
  `transfer_preserves_freeze`, `mint_preserves_freeze`,
  `burn_preserves_freeze` each conditional on operating on a
  *different* resource than the frozen one).

**Test coverage (after Phase 2).**  83 passing tests across eight
suites:
- `KernelTests` (22) — unchanged from Phase 1.
- `RBMapLemmasTests` (8) — unchanged from Phase 1.
- `Umbrella` (2) — non-TCB build-tag smoke test, with the Phase-2
  bump check (`kernelBuildTag = "canon-phase-2-economic-invariants"`).
- `ConservationTests` (12) — new — sanity for `TotalSupply`,
  `totalSupply_setBalance` value-level checks at four representative
  inputs, `TotalSupplyEquals` round-trip, two `transfer_conserves`
  witnesses (distinct + self-transfer), `IsConservative` typeclass
  resolution, `ConservativeLawSet` construction, and a runtime
  `total_supply_global` invocation.
- `Transfer` (16) — Phase-0 base (11, including the **§4.11
  self-transfer regression** witness) plus 5 Phase-2 cases
  (`transfer_conserves`, `transfer_does_not_touch_other_resources`,
  `transfer_conserves_other_resource`, `IsConservative` instance).
- `Mint` (7) — new — precondition decidability,
  `step_impl`/`apply_impl` value semantics,
  `totalSupply_after_mint` at runtime, and `mint_not_conservative`
  term-level API check.
- `Burn` (9) — new — symmetric to mint, with the additional edge
  case "burn down to zero is allowed".
- `Freeze` (7) — new — `FrozenForResource` reflexivity at snapshot
  time, all four preservation lemmas at runtime, and
  freezeResource-is-identity value-level check.

Tests use two complementary patterns:
1. **Value-level**: assert `==` between expected and actual results
   (catches definitional drift / Std-API renames at runtime).
2. **Term-level API stability**: ascribe a `let _proof : T :=
   theorem ...` binding whose type uses the theorem's exact
   signature (catches signature changes at elaboration time, before
   the `IO Unit` body runs).

`lake test` runs the suite via the `Tests.lean` driver and exits
non-zero on any failure; CI runs the same driver.

**Axiom audit (Phase 2).**  `#print axioms` on every kernel, RBMap,
and Phase-2 theorem (kernel: 11 theorems; RBMap: 7 theorems;
Conservation + per-law theorems: 19) returns exactly
`[propext, Classical.choice, Quot.sound]`.  No custom axioms have
been introduced in Phase 2.

**TCB-audit hardening.**  `Tools.Common.tcbInternalImports` lists
the project-internal modules each TCB core file may import — only
`LegalKernel.Kernel` and `LegalKernel.RBMapLemmas`.  This is a
*specific allowlist*, not a `LegalKernel.*` namespace pattern: a
TCB core file that tries to import e.g. `LegalKernel.Laws.Transfer`
fails the audit, blocking the merge and forcing a §13.6
amendment.

## Vulnerability reporting

Canon is research-stage software.  If you discover a logic bug in
the kernel module (e.g. a counterexample to `impl_noop_if_not_pre`,
or a state advance that bypasses the `if` in `step_impl`), open an
issue with the `kernel-soundness` label.  Such reports gate any
in-flight PR; the two-reviewer rule applies to the fix.

For non-kernel issues (laws, tooling, documentation), the standard
issue tracker workflow applies.

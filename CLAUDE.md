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

## What this project is

Canon is a **proof-carrying state transition system** built in Lean 4.
It is an *implementation* of the Genesis Plan
(`docs/GENESIS_PLAN.md`): a small, parametric, law-free kernel where
"legality" is a Lean type, every state change is accompanied by a
machine-checkable proof of admissibility, and global system properties
(determinism, refinement, no-silent-illegality, invariant
preservation) are guaranteed by inductive theorems rather than by
trust in operators.

Current status: **Phases 0 – 3 complete + Phase-4 prelude (Positive
Incentives) complete.**  Phase 0 (Foundations)
landed the kernel skeleton, the canonical transfer law, the build
pipeline, and the Genesis Plan.  Phase 1 (Kernel Completion) added
the §8.3 RBMap proof library, the §4.3 balance lemmas, the §4.9
multi-step / law-set reachability extensions, the Phase-1 audit
tooling (`lake exe count_sorries`, `lake exe tcb_audit`), and the
WU-1.6 / WU-1.13 documentation.  Phase 2 (Economic Invariants)
landed the §8.1 `TotalSupply` quantity functional,
`transfer_conserves` (§4.11.1), the `IsConservative` typeclass, the
`mint`/`burn` non-conservative laws (with explicit non-conservation
witnesses), the `ConservativeLawSet` machinery, the §5.3
`total_supply_global` theorem, and the `freezeResource` /
`FrozenForResource` immutability layer.  Phase 3 (Authority Layer)
landed the §4.13 `Action` data layer with structural
`compile_injective` via the `CompiledAction` wrapper; the
`AuthorityPolicy` (with `empty`/`unrestricted`/`union`/`intersect`/
`singleton` combinators) and `KeyRegistry` (with `register`/
`revoke`/`mergeLeftBiased`); the cryptographic `Verify` interface
(opaque, deployment-supplied); the §8.5 `NonceState`,
`ExtendedState` (kernel state + nonce ledger + key registry), and
the headline `expectsNonce_strict_mono` lemma; the five-condition
`Admissible` predicate (§8.2); the single guarded `apply_admissible`
entry point; the §8.5.2 `nonce_uniqueness` and `replay_impossible`
theorems; and the WU 3.10 `replaceKey` action with full
registry-mutation theorems and an end-to-end key-rotation test
chain.  The **Phase-4 prelude (Positive-Incentive Mechanisms)**
landed `IsMonotonic` typeclass + `MonotonicLawSet` structure (the
type-level firewall for "no value destruction" deployments), the
`total_supply_globally_nondecreasing[_via_law_set]` headline
theorems, three new positive-incentive laws (`reward`,
`distributeOthers`, `proportionalDilute`) with full classification
including `proportionalDilute_distributed_le_totalReward` (the
floor-division dust bound), three new `Action` constructors with
their compile branches, the `burn_not_monotonic` negative witness
that completes the firewall, and the missing
`freezeResource_isConservative` instance.  Phases 4 – 7 (DSL and
serialization, Runtime and extraction, Disputes and adjudication,
Advanced capabilities) are scoped in §12 of the Genesis Plan and
have not yet started.

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
lake build LegalKernel.Authority.Crypto       # Phase-3 Verify interface
lake build LegalKernel.Authority.Action       # Phase-3 Action layer + compile_injective
lake build LegalKernel.Authority.Identity     # Phase-3 KeyRegistry + AuthorityPolicy
lake build LegalKernel.Authority.Nonce        # Phase-3 NonceState + ExtendedState
lake build LegalKernel.Authority.SignedAction # Phase-3 admissibility + replay protection
lake test                           # run Tests.lean driver (191 tests)
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

**`lake build` (default target) is sufficient at Phases 0 – 3**
because `LegalKernel.lean` re-exports the kernel, the §8.3 RBMap
proof library, the Phase-2 economic-invariants framework, every
deployed law (transfer, mint, burn, freeze), and the Phase-3
authority layer (`Authority.{Crypto, Action, Identity, Nonce,
SignedAction}`), so every TCB / law / kernel / authority file is
reachable from the default target.  This convention may change in
later phases when the law set grows; check the `lean_lib LegalKernel`
`roots` field in `lakefile.lean` if in doubt.

After any source change, also run:

* `lake test` — runs the test driver (191 tests across twelve suites
  as of Phase 3 / post-audit; was 156 at first Phase-3 commit, 95 in
  Phase 2, 43 in Phase 1, 24 in Phase 0).  Catches semantic
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
├── LegalKernel.lean               -- umbrella import (kernel + RBMap + Conservation + laws + authority).
├── LegalKernel/
│   ├── Kernel.lean                -- §4.12 trusted core (TCB).
│   ├── RBMapLemmas.lean           -- §8.3 RBMap proof library (TCB).
│   ├── Conservation.lean          -- §8.1 / §5.3 Phase-2 economic invariants
│   │                                 framework: TotalSupply, IsConservative,
│   │                                 ConservativeLawSet, total_supply_global
│   │                                 + Phase-4-prelude monotonicity tier:
│   │                                 IsMonotonic, MonotonicLawSet,
│   │                                 total_supply_globally_nondecreasing,
│   │                                 sumOthers, getBalance_le_totalSupply,
│   │                                 state_filter_sum_eq_sumOthers
│   │                                 (non-TCB).
│   ├── Laws/
│   │   ├── Transfer.lean          -- §4.11 transfer law + Phase-2
│   │   │                             transfer_conserves + IsConservative
│   │   │                             instance + Phase-4-prelude
│   │   │                             transfer_isMonotonic.
│   │   ├── Mint.lean              -- Phase-2 mint law + non-conservation
│   │   │                             + Phase-4-prelude mint_isMonotonic.
│   │   ├── Burn.lean              -- Phase-2 burn law + non-conservation
│   │   │                             + Phase-4-prelude burn_not_monotonic
│   │   │                             (negative witness).
│   │   ├── Freeze.lean            -- Phase-2 freezeResource marker +
│   │   │                             FrozenForResource invariant
│   │   │                             + Phase-4-prelude
│   │   │                             freezeResource_isConservative
│   │   │                             + freezeResource_isMonotonic.
│   │   ├── Reward.lean            -- Phase-4-prelude WU R.5: single-
│   │   │                             recipient positive-incentive credit
│   │   │                             (non-conservative, monotonic).
│   │   ├── DistributeOthers.lean  -- Phase-4-prelude WU R.8 / R.9:
│   │   │                             uniform reward of all non-excluded
│   │   │                             actors at a resource.
│   │   └── ProportionalDilute.lean -- Phase-4-prelude WU R.12 / R.13 /
│   │                                  R.14 / R.15: proportional reward
│   │                                  (Nat floor, dust discarded) with
│   │                                  the dust-bound theorem.
│   ├── Authority/
│   │   ├── Crypto.lean            -- Phase-3 WU 3.4: PublicKey,
│   │   │                             Signature, opaque Verify, opaque
│   │   │                             SigningInput (non-TCB).
│   │   ├── Action.lean            -- Phase-3 WU 3.1 + 3.2: Action
│   │   │                             inductive, CompiledAction wrapper,
│   │   │                             Action.compile_injective via
│   │   │                             congrArg (non-TCB).
│   │   ├── Identity.lean          -- Phase-3 WU 3.3: Identity,
│   │   │                             KeyRegistry (with empty / register
│   │   │                             / revoke / mergeLeftBiased),
│   │   │                             AuthorityPolicy (with empty /
│   │   │                             unrestricted / union / intersect /
│   │   │                             singleton) (non-TCB).
│   │   ├── Nonce.lean             -- Phase-3 WU 3.5: NonceState,
│   │   │                             ExtendedState (= base + nonces +
│   │   │                             registry), expectsNonce,
│   │   │                             advanceNonce,
│   │   │                             expectsNonce_strict_mono (non-TCB).
│   │   └── SignedAction.lean      -- Phase-3 WU 3.6 / 3.7 / 3.8 / 3.10:
│   │                                 SignedAction, Admissible (5
│   │                                 conditions), apply_admissible
│   │                                 (single guarded entry point),
│   │                                 nonce_uniqueness, replay_impossible,
│   │                                 replaceKey registry-mutation
│   │                                 theorems (non-TCB).
│   └── Test/
│       ├── Framework.lean         -- minimal IO-based test harness + emptyState.
│       ├── KernelTests.lean       -- value-level kernel tests (22 cases).
│       ├── RBMapLemmasTests.lean  -- §8.3 fold-lemma tests (8 cases).
│       ├── Umbrella.lean          -- umbrella-module smoke tests (2 cases).
│       ├── ConservationTests.lean -- Phase-2 conservation tests (21 cases incl. R.20 monotonicity-tier extensions + end-to-end behaviour test).
│       ├── Laws/
│       │   ├── Transfer.lean      -- transfer-law tests (17 cases incl. R.19).
│       │   ├── Mint.lean          -- mint tests (11 cases incl. R.19).
│       │   ├── Burn.lean          -- burn tests (13 cases incl. R.19).
│       │   ├── Freeze.lean        -- freeze tests (12 cases incl. R.19).
│       │   ├── Reward.lean        -- Phase-4-prelude R.6: reward tests (11 cases).
│       │   ├── DistributeOthers.lean -- Phase-4-prelude R.10: distributeOthers tests (14 cases).
│       │   └── ProportionalDilute.lean -- Phase-4-prelude R.16: proportionalDilute tests (17 cases).
│       └── Authority/
│           ├── Action.lean        -- Action layer tests (31 cases incl. R.18).
│           ├── Identity.lean      -- Phase-3 Identity / KeyRegistry /
│           │                         AuthorityPolicy tests (14 cases).
│           ├── Nonce.lean         -- Phase-3 nonce ledger tests (11 cases).
│           └── SignedAction.lean  -- Phase-3 admissibility / replay /
│                                     key-rotation tests (17 cases).
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
    └── economic_invariants.md     -- Phase 2 design + Phase-4-prelude
                                      monotonicity tier section.
```

### Module dependency graph (Phases 0 – 3 + Phase-4 prelude)

```
LegalKernel.Kernel        (TCB, §4.12 + §4.3 balance lemmas + §4.9 reachability)
  └──── imports LegalKernel.RBMapLemmas
LegalKernel.RBMapLemmas   (TCB, §8.3 fold + insert lemmas)
LegalKernel.Conservation  (non-TCB; §8.1 TotalSupply + §5.3 framework
                            + Phase-4-prelude monotonicity tier)
  └──── imports Kernel + RBMapLemmas
LegalKernel.Laws.Transfer            (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.Mint                (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.Burn                (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.Freeze              (non-TCB; depends on Kernel + Conservation +
                                                Transfer + Mint + Burn)
LegalKernel.Laws.Reward              (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.DistributeOthers    (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.ProportionalDilute  (non-TCB; depends on Kernel + Conservation)

LegalKernel.Authority.Crypto       (non-TCB; PublicKey, Signature,
                                              opaque Verify)
LegalKernel.Authority.Action       (non-TCB; depends on Kernel +
                                              Conservation + Laws.* (incl.
                                              the three new positive-incentive
                                              laws) + Authority.Crypto)
LegalKernel.Authority.Identity     (non-TCB; depends on Kernel +
                                              RBMapLemmas +
                                              Authority.{Crypto, Action})
LegalKernel.Authority.Nonce        (non-TCB; depends on Kernel +
                                              RBMapLemmas +
                                              Authority.{Crypto, Identity})
LegalKernel.Authority.SignedAction (non-TCB; depends on Kernel +
                                              Authority.{Crypto, Action,
                                              Identity, Nonce})

LegalKernel.Test.Framework (no Kernel dependency)
LegalKernel.Test.KernelTests
LegalKernel.Test.RBMapLemmasTests
LegalKernel.Test.ConservationTests
LegalKernel.Test.Laws.{Transfer, Mint, Burn, Freeze, Reward,
                       DistributeOthers, ProportionalDilute}
LegalKernel.Test.Authority.{Action, Identity, Nonce, SignedAction}
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
framework and Phase 3's authority layer are **not** TCB:
`Conservation.lean`, the four `Laws/*.lean` modules, and the five
`Authority/*.lean` modules are deployment-facing infrastructure,
with bugs scoped to deployment-level claims (not kernel invariants).
Phase 3's `Verify` axiom is a *trust assumption* (the deployment-
supplied signature scheme is EUF-CMA secure); the kernel's authority
guarantees are conditional on this assumption.

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

## Type-level design properties enforced in Phases 0 – 3 + Phase-4 prelude

The Genesis Plan promises a small set of type-level guarantees
(§1, §5).  The kernel, the Phase-2 economic-invariants framework, the
Phase-3 authority layer, and the Phase-4-prelude positive-incentive
tier each mechanise one or more of the following:

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
| 18 | Mint / burn are local to their resource | `mint_/burn_other_resource_untouched`, `*_does_not_touch_other_resources`, `*_conserves_other_resource` | 2 / `Laws/Mint.lean` and `Laws/Burn.lean` |
| 19 | Action compilation is structurally injective | `Action.compile_injective` | 3 / `Authority/Action.lean` (§4.13) |
| 20 | Per-actor nonce is strictly monotonic | `expectsNonce_strict_mono` | 3 / `Authority/Nonce.lean` (§8.5) |
| 21 | Two admissible actions by same signer share nonce | `nonce_uniqueness` | 3 / `Authority/SignedAction.lean` (§8.5.2) |
| 22 | Successful application precludes replay | `replay_impossible` | 3 / `Authority/SignedAction.lean` (§8.5.2) |
| 23 | `replaceKey` updates the registry to the new key | `replaceKey_updates_registry` | 3 / `Authority/SignedAction.lean` (WU 3.10) |
| 24 | `replaceKey` doesn't affect other actors' keys | `replaceKey_other_actor_untouched` | 3 / `Authority/SignedAction.lean` (WU 3.10) |
| 25 | Non-`replaceKey` actions preserve the registry | `non_replaceKey_preserves_registry` | 3 / `Authority/SignedAction.lean` (WU 3.10) |
| 26 | KeyRegistry register/revoke semantics (4 lemmas) | `KeyRegistry.lookup_{register_self,register_other,revoke_self,revoke_other}` | 3 / `Authority/Identity.lean` (WU 3.3) |
| 27 | AuthorityPolicy combinator characterisations (8 lemmas) | `AuthorityPolicy.{empty,unrestricted,union,intersect,singleton}_authorized`, `union_comm`, `union_empty`, `intersect_unrestricted` | 3 / `Authority/Identity.lean` (WU 3.3) |
| 28 | Admissibility field extractors (5 lemmas) | `admissible_{authorized,nonce,pre,signer_registered,signer_registered_and_signed}` | 3 / `Authority/SignedAction.lean` (WU 3.6) |
| 29 | `apply_admissible` field projections (2 lemmas) | `apply_admissible_base`, `apply_admissible_registry` | 3 / `Authority/SignedAction.lean` (WU 3.7) |
| 30 | Cross-actor nonce isolation under `apply_admissible` | `expectsNonce_after_apply_admissible_other` | 3 / `Authority/SignedAction.lean` (WU 3.7) |
| 31 | `compile` injectivity equivalent / contrapositive forms | `Action.compile_eq_iff`, `Action.compile_ne_of_ne` | 3 / `Authority/Action.lean` (§4.13) |
| 32 | Monotonicity classification typeclass | `IsMonotonic` | R / `Conservation.lean` |
| 33 | Conservative laws are automatically monotonic | `monotonic_of_conservative` (priority := low) | R / `Conservation.lean` |
| 34 | Type-level firewall for monotonic deployments | `MonotonicLawSet` | R / `Conservation.lean` |
| 35 | Per-resource non-decrease across reachable states | `total_supply_globally_nondecreasing` | R / `Conservation.lean` |
| 36 | Typeclass-driven non-decrease corollary | `total_supply_globally_nondecreasing_via_law_set` | R / `Conservation.lean` |
| 37 | Reward is monotonic at every resource | `reward_isMonotonic` | R / `Laws/Reward.lean` |
| 38 | Reward is not conservative | `reward_not_conservative` | R / `Laws/Reward.lean` |
| 39 | DistributeOthers preserves the excluded actor | `distributeOthers_excluded_unchanged` | R / `Laws/DistributeOthers.lean` |
| 40 | DistributeOthers is monotonic | `distributeOthers_isMonotonic` | R / `Laws/DistributeOthers.lean` |
| 41 | ProportionalDilute respects the dust bound | `proportionalDilute_distributed_le_totalReward` | R / `Laws/ProportionalDilute.lean` |
| 42 | ProportionalDilute is monotonic | `proportionalDilute_isMonotonic` | R / `Laws/ProportionalDilute.lean` |
| 43 | Burn is not monotonic (negative witness) | `burn_not_monotonic` | R / `Laws/Burn.lean` |

The "Phase / File" `R` markers identify the Phase-4-prelude
positive-incentive WUs (`R.1` – `R.23`); they precede Phase 4 (DSL and
Serialisation) in the implementation roadmap.

These are not stubs.  They are real Lean theorems that the build
will not accept with a `sorry`, and `#print axioms` confirms that
each depends only on the three Lean built-in axioms (`propext`,
`Classical.choice`, `Quot.sound`) — or, in a few cases, no axioms
at all (e.g. `AuthorityPolicy.union_authorized` is `Iff.rfl`).
Modifying any of properties #1 – #9 (kernel-TCB) is a TCB change
and triggers the two-reviewer gate; properties #10 – #43 (Phase-2 /
Phase-3 / Phase-4-prelude deployment infrastructure) are non-TCB and
need only one reviewer.

The Phase-3 properties additionally depend on the `Verify` opaque
declaration (i.e. on the deployment-supplied EUF-CMA-secure
signature scheme).  `Verify` is declared `opaque` rather than
`axiom`, so the kernel's `#print axioms` audit continues to return
exactly the three Lean built-ins; the EUF-CMA assumption surfaces
as a *trust assumption* on the runtime adaptor, not as a Lean axiom.

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

**Required Std modules (Phases 0 – 3):**

- `Std.Data.TreeMap` — the ordered finite-map backing `BalanceMap`,
  imported by both `Kernel.lean` and `RBMapLemmas.lean` (TCB), and
  by `Authority/Identity.lean` and `Authority/Nonce.lean` for
  `KeyRegistry` and `NonceState.next` (non-TCB).

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

| Phase  | Title                              | Work units (Genesis §12) | Status      |
|--------|------------------------------------|--------------------------|-------------|
| 0      | Foundations                        | 0.1–0.5                  | Complete    |
| 1      | Kernel completion                  | 1.1–1.13                 | Complete    |
| 2      | Economic invariants                | 2.1–2.9                  | Complete    |
| 3      | Authority layer                    | 3.1–3.10                 | Complete    |
| 4-prelude | Positive-incentive mechanisms   | R.1–R.23                 | Complete    |
| 4      | DSL and serialization              | 4.x                      | Not started |
| 5      | Runtime and extraction             | 5.x                      | Not started |
| 6      | Disputes and adjudication          | 6.x                      | Not started |
| 7      | Advanced capabilities              | 7.x                      | Not started |

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

**Current Phase:** Phases 0 – 3 Complete + Phase-4 prelude
(Positive-Incentive Mechanisms) Complete; Phase 4 (DSL and
Serialization) is next.

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
  ship `totalSupply_after_*` accounting corollaries plus a per-law
  cross-resource locality triple (state-level
  `*_other_resource_untouched`, pointwise
  `*_does_not_touch_other_resources`, and the per-resource supply form
  `*_conserves_other_resource`) that mirrors the Phase-2 additions to
  `Laws/Transfer.lean`.
- WU 2.6: `mint_not_conservative` and `burn_not_conservative` deliver
  explicit non-conservation witnesses; both negate the
  `IsConservative` typeclass directly.
- WU 2.7: `ConservativeLawSet` structure in `Conservation.lean` is
  the §6.2 type-level firewall — mint/burn cannot be added because
  no `IsConservative` instance exists.
- WU 2.8: `total_supply_global` (§5.3 verbatim) plus the
  typeclass-driven corollary `total_supply_global_via_law_set`.
- WU 2.9: `LegalKernel/Laws/Freeze.lean` ships the `freezeResource _r`
  no-op marker (the `_r` parameter is part of the action-layer API
  but deliberately ignored at the kernel level, so `freezeResource 1`
  and `freezeResource 2` are *definitionally equal* `Transition`
  values), the `FrozenForResource r snap` invariant (a closure over
  the snapshotted per-resource `BalanceMap`), and the four
  preservation lemmas: `freezeResource_preserves_freeze` reduces to
  `hI` by definitional equality (`step_impl` on a `True`-precondition
  identity transition collapses); `transfer_preserves_freeze`,
  `mint_preserves_freeze`, `burn_preserves_freeze` each consume the
  corresponding `*_other_resource_untouched` state-level helper and
  are conditional on operating on a *different* resource than the
  frozen one.

WU 3.1 + 3.2 (Action layer + structural compile_injective) — complete:
- `LegalKernel/Authority/Action.lean` ships the `Action` inductive
  with five constructors (`transfer`, `mint`, `burn`,
  `freezeResource`, `replaceKey`); the `CompiledAction` wrapper
  (`source : Action`, `transition : Transition`); the
  `Action.compileTransition` raw compiler; the `Action.compile`
  wrapper that produces `CompiledAction`; and the headline
  `Action.compile_injective` theorem proved as a one-line
  `congrArg CompiledAction.source`.
- The `CompiledAction` wrapper is the Phase-3 redesign that makes
  injectivity *structural*: distinct compiled actions necessarily
  have distinct `source` fields, so the proof is mechanical.  The
  alternative — proving injectivity at the bare `Transition` level
  — would have required hairy discrimination lemmas and would have
  *failed* on the Phase-2 `freezeResource` (whose body ignores its
  parameter) and on vacuous action pairs like `transfer r s s 0` vs
  `mint r s 0`.
- The kernel TCB is unchanged: `Transition` retains its three
  fields, and `CompiledAction` lives in `LegalKernel/Authority/`
  (non-TCB).
- Convenience accessors `Action.pre`, `Action.apply_impl`, and
  `Action.decPre` are also exported for downstream call sites that
  want kernel-shaped APIs.

WU 3.3 (Identity, KeyRegistry, AuthorityPolicy) — complete:
- `LegalKernel/Authority/Identity.lean` ships the `Identity`
  structure (`id : ActorId`, `key : PublicKey`); the `KeyRegistry =
  TreeMap ActorId PublicKey compare` abbreviation with `empty`,
  `register`, `revoke`, `lookup`, and `mergeLeftBiased`; the
  `AuthorityPolicy` structure (`authorized` predicate + `decAuth`
  decidability witness); and four combinators (`empty`,
  `unrestricted`, `union`, `intersect`, `singleton`).
- Phase-3 design deviation from §8.2: the dynamic `KeyRegistry`
  lives in `ExtendedState` (so `replaceKey` can mutate it), not
  inside `AuthorityPolicy`.  The `AuthorityPolicy` retains only the
  static authorisation predicate and its decidability witness.
- `mergeLeftBiased` uses left-biased key collision resolution per
  the Genesis-Plan §8.2 spec; deployments needing a different
  resolution rule supply their own combinator.

WU 3.4 (`Verify` interface) — complete:
- `LegalKernel/Authority/Crypto.lean` ships `PublicKey` and
  `Signature` as `ByteArray` abbreviations (with explicit `Repr`
  and `DecidableEq` instances for downstream `deriving`); the
  `Nonce = Nat` abbreviation; the opaque `Verify : PublicKey →
  ByteArray → Signature → Bool`; and the opaque `signingInput :
  Action → ActorId → Nonce → SigningInput` (the canonical encoding
  Phase 4 will replace).
- `Verify` is declared `opaque` rather than `axiom`, so the kernel's
  axiom audit continues to return exactly `[propext,
  Classical.choice, Quot.sound]`.  The EUF-CMA security assumption
  is a *trust assumption* on the deployment-supplied runtime
  adaptor (Phase 5, WU 3.9), not a Lean axiom.

WU 3.5 (`NonceState` + `ExtendedState`) — complete:
- `LegalKernel/Authority/Nonce.lean` ships the `NonceState`
  structure (`next : TreeMap ActorId Nonce compare`); the
  `ExtendedState` structure (`base : State`, `nonces : NonceState`,
  `registry : KeyRegistry`); and the `expectsNonce` / `advanceNonce`
  operations.
- The §8.5 headline lemma `expectsNonce_strict_mono` is proved via
  `RBMap.find?_insert_self` (WU 1.1) in three lines.  Companion
  lemmas `expectsNonce_advance_other` (cross-actor isolation),
  `advanceNonce_base`, `advanceNonce_registry` (field
  preservation), and the Nat-arithmetic corollaries
  `expectsNonce_after_advance_gt_old` and
  `expectsNonce_after_advance_ne_old` are also exported.

WU 3.6 (`SignedAction` + `Admissible`) — complete:
- `LegalKernel/Authority/SignedAction.lean` ships the `SignedAction`
  structure (`action`, `signer`, `nonce`, `sig`); the §8.2
  `Admissible` predicate as a four-conjunct `Prop` (registration
  conjoined with signature verification, since both consume the
  same `pk`); and the `applyActionToRegistry` helper that captures
  the action-specific authority-layer effects (`replaceKey` mutates
  the registry; other actions leave it unchanged).
- The `Admissible` predicate's clause order matches the §8.2
  static-vs-dynamic decomposition: condition 2 (`authorized`) and
  conditions 1+3 (registration + signature) are static in the
  signer-action-nonce triple; condition 4 (nonce match) and
  condition 5 (kernel pre) are dynamic in the `ExtendedState`.

WU 3.7 (`apply_admissible` + `nonce_uniqueness`) — complete:
- `apply_admissible : (P : AuthorityPolicy) → (es : ExtendedState) →
  (st : SignedAction) → Admissible P es st → ExtendedState` is the
  single guarded entry point.  Order of operations: compile the
  action, apply the kernel transition's `apply_impl` to `es.base`,
  wrap, advance the signer's nonce, and (for `replaceKey`) update
  the registry.
- `nonce_uniqueness` has a five-line proof: extract the nonce-match
  conjunct from each admissibility witness, rewrite by the
  same-signer hypothesis, and chain the equalities.
- `expectsNonce_after_apply_admissible` is the algebraic core that
  `replay_impossible` consumes: after one `apply_admissible`, the
  signer's expected nonce is exactly one greater than before.

WU 3.8 (`replay_impossible`) — complete:
- Proved in eight lines via `expectsNonce_after_apply_admissible`,
  `admissible_nonce_eq` (×2, on the pre- and post-states), and a
  single `Nat.ne_of_lt (Nat.lt_succ_self _)` to close the
  contradiction.
- The headline takeaway: a successfully applied signed action
  cannot be admissible at the post-state.  No race, no log replay,
  no pathological scenario in which this guarantee fails.

WU 3.10 (`replaceKey` + key rotation) — complete:
- `Action.replaceKey` is one of the five Action constructors; its
  authority-layer effect is captured by `applyActionToRegistry`
  inside `apply_admissible`.  Three theorems pin down the
  semantics:
  - `replaceKey_updates_registry`: the post-`apply_admissible`
    registry has `actor → newKey`.
  - `replaceKey_other_actor_untouched`: other actors' registry
    entries are unchanged.
  - `non_replaceKey_preserves_registry`: any non-`replaceKey`
    action preserves the registry pointwise.
- The end-to-end key-rotation chain (§8.2 acceptance criterion) is
  exercised by the `keyRotationTests` sub-suite in
  `LegalKernel/Test/Authority/SignedAction.lean`: register actor 10
  with K1, rotate to K2, rotate back to K1, and verify cross-actor
  independence.

WUs R.1 – R.23 (Phase-4 prelude: Positive Incentives) — complete:
- **R.1 / R.2**: introduce the missing tier between conservation and
  unrestricted laws.  `IsMonotonic` typeclass (supply non-decreasing)
  + `monotonic_of_conservative` low-priority auto-upgrade in
  `Conservation.lean`.  `MonotonicLawSet` structure + headline
  theorems `total_supply_globally_nondecreasing[_via_law_set]`.
  Mirror of `IsConservative` / `ConservativeLawSet` /
  `total_supply_global[_via_law_set]` in shape.
- **R.3 / R.4**: per-existing-law classification.
  `transfer_isMonotonic`, `mint_isMonotonic`,
  `freezeResource_isConservative` + `_isMonotonic` (the latter pair
  was missing in Phase 2); `burn_not_monotonic` negative witness in
  `Laws/Burn.lean` (mirroring `burn_not_conservative` in proof shape,
  with the equality flipped to a strict inequality discharged by
  manual additive cancellation).
- **R.5 / R.6**: `Laws/Reward.lean` — single-recipient
  positive-incentive credit.  Definitionally identical to `mint` at
  the kernel level, but distinct at the `Action` layer (see R.17) so
  authority policies can grant reward / mint independently.  Eleven
  test cases mirroring `Test/Laws/Mint.lean`.
- **R.7**: `getBalance_le_totalSupply` lemma in `Conservation.lean`
  (bound any single actor's balance by the per-resource supply).
  Used by `proportionalDilute`'s precondition reasoning and by the
  dust-bound theorem.  Pivot from the original `bmReplaceValues`
  generic helper to a focused single-lemma WU because the per-law
  `apply_impl` implementations (foldl-of-`setBalance`) avoid the
  rebuild-from-empty fold that would have required the generic
  lemma.
- **R.8 / R.9 / R.10**: `Laws/DistributeOthers.lean` — uniform
  reward of all non-excluded actors at a resource.  `apply_impl`
  iterates `setBalance` over the pre-filtered list of non-excluded
  entries; each step is a known kernel operation, so locality
  (other-resource untouched, excluded actor unchanged) and the supply
  equation `post = pre + amount * size_excluding_key` reduce to short
  inductive arguments.  `IsMonotonic` instance + non-conservative
  witness.  Fourteen test cases on multi-actor fixtures.
- **R.11 / R.12 / R.13 / R.14 / R.15 / R.16**: `Laws/ProportionalDilute.lean` —
  proportional positive-incentive distribution.  Each non-excluded
  actor `k` receives `totalReward * v_k / sumOthers` (Nat floor
  division; dust discarded).  Generic foldl-of-`setBalance` helpers
  generalised over the per-step value function (since the increment
  is data-dependent on the snapshotted balance).  Supply equation
  (R.13), the **full dust bound**
  `proportionalDilute_distributed_le_totalReward` (R.14), `IsMonotonic`
  instance + non-conservative witness (R.15), seventeen test cases
  on hand-computed fixtures (R.16).  R.14's proof goes through new
  filter-sum infrastructure in `Conservation.lean`
  (`list_partition_sum_by_key`, `list_filter_eq_singleton_of_distinct`,
  `balanceMap_filter_sum_plus_lookup`,
  `state_filter_sum_eq_sumOthers`) which uses
  `Std.TreeMap.distinct_keys_toList` to bridge the per-bm filter sum
  to `sumOthers`.
- **R.17 / R.18**: extend `Authority/Action.lean` with three new
  constructors (`reward`, `distributeOthers`, `proportionalDilute`),
  three new `compileTransition` cases, three smoke `example` lines.
  `Action.compile_injective` is unchanged (structural via
  `CompiledAction.source`).  `non_replaceKey_preserves_registry` in
  `Authority/SignedAction.lean` extended to handle the three new
  constructors (each closes by `rfl` since none mutate the registry).
  Eight new test cases in `Test/Authority/Action.lean`.
- **R.19 / R.20**: per-existing-law instance-resolution tests
  (Transfer / Mint / Burn / Freeze test files); ConservationTests
  extensions exercising `IsMonotonic`, `MonotonicLawSet`, and the
  headline theorems; **end-to-end behaviour test** that runs a
  4-step trace (mint, reward, distributeOthers, transfer) and
  verifies per-step non-decrease at the value level + the expected
  final supply.
- **R.21**: `LegalKernel.lean` umbrella adds three new imports;
  `kernelBuildTag` bumped to
  `"canon-phase-4-prelude-positive-incentives"`; `Tests.lean` driver
  registers three new suites; `Test/Umbrella.lean` build-tag literal
  updated.

**Test coverage (after Phase-4 prelude).**  255 passing tests across
fifteen suites:
- `KernelTests` (22) — unchanged from Phase 1.
- `RBMapLemmasTests` (8) — unchanged from Phase 1.
- `Umbrella` (2) — non-TCB build-tag smoke test, with the Phase-4-
  prelude bump check (`kernelBuildTag =
  "canon-phase-4-prelude-positive-incentives"`).
- `ConservationTests` (21) — Phase 2 (15) + Phase-4-prelude R.20
  extensions: `IsMonotonic` typeclass resolution checks,
  `MonotonicLawSet` constructibility (mixed conservative + monotone
  laws), `total_supply_globally_nondecreasing[_via_law_set]` API
  stability, plus the **end-to-end behaviour test** (4-step trace
  through positive-incentive laws verified to be supply-non-
  decreasing at the value level).
- `Transfer` (17) — Phase 2 (16) + R.19's `transfer_isMonotonic`
  instance-resolution check.
- `Mint` (11) — Phase 2 (10) + R.19's `mint_isMonotonic`
  instance-resolution check.
- `Burn` (13) — Phase 2 (12) + R.19's `burn_not_monotonic` API
  stability check (the negative-witness counterpart to the
  monotonicity firewall).
- `Freeze` (12) — Phase 2 (10) + R.19's `freezeResource_isConservative`
  AND `freezeResource_isMonotonic` instance-resolution checks (the
  `IsConservative` instance was missing in Phase 2 and is added by
  R.3).
- `Reward` (11) — Phase-4-prelude WU R.6.  Mirrors `Test/Laws/Mint.lean`
  case-for-case (since `reward`'s kernel-level shape is identical to
  `mint`); plus monotonicity-instance check and non-conservation API
  stability.
- `DistributeOthers` (14) — Phase-4-prelude WU R.10.  Multi-actor
  fixtures (3-actor F1: balances 30/40/50, exclude 2, distributes 50
  to actors 1 & 3); per-actor and total-supply assertions; locality
  (other resources untouched, excluded actor unchanged); arithmetic
  API stability and the negative-witness API check.
- `ProportionalDilute` (17) — Phase-4-prelude WU R.16.  Hand-computed
  fixtures: F1 with 3 actors {1→30, 2→40, 3→50}, exclude actor 2,
  totalReward 10; verifies actor 1 → 33 (3+amt), actor 3 → 56
  (6+amt), supply 120 → 129 with dust 1 discarded.  F2 with exact
  division (no dust).  F3 precondition fail (sumOthers = 0).
  F4 excluded-absent.  Numerical dust-bound check; API stability for
  the four headline theorems including
  `_distributed_le_totalReward`.
- `Authority.ActionTests` (31) — Action constructor distinguishability,
  `Action.compile` shape per constructor, compiled `apply_impl`
  matching the underlying law, term-level + value-level
  `compile_injective` / `compile_eq_iff` / `compile_ne_of_ne` API
  stability, convenience-accessor smoke tests, plus Phase-4-prelude
  R.18 additions: distinguishability for the three new constructors
  including the critical `.reward` vs `.mint` distinguishability
  check (same scalar shape, different constructors), plus compile
  shape rfl-checks.
- `Authority.IdentityTests` (27) — `KeyRegistry` round-trips
  (register / revoke / overwrite / merge); `AuthorityPolicy`
  `empty`/`unrestricted`/`union`/`intersect`/`singleton` decidability
  checks at concrete `(actor, action)` pairs; term-level API
  stability for the four `KeyRegistry.lookup_*` semantic theorems
  (`register_self`, `register_other`, `revoke_self`, `revoke_other`)
  and the seven `AuthorityPolicy` combinator theorems
  (`empty_authorized`, `unrestricted_authorized`,
  `union_authorized`, `intersect_authorized`, `singleton_authorized`,
  `union_comm`, `union_empty`, `intersect_unrestricted`).
- `Authority.NonceTests` (11) — `expectsNonce` zero-default,
  `advanceNonce` increments, cross-actor isolation, base/registry
  preservation, and term-level `expectsNonce_strict_mono`/
  `_advance_other`/`_after_advance_*` API stability.
- `Authority.SignedActionTests` (38) — admissibility decomposition
  (auth + nonce + pre); negative cases for every condition (stale
  nonce, unauthorized signer, unregistered signer, insufficient
  balance); `apply_admissible` term-level signature check;
  `applyActionToRegistry` value semantics for every Action
  constructor including the three Phase-4-prelude additions
  (`reward`, `distributeOthers`, `proportionalDilute`) — each
  asserted to be registry-identity, mirroring the existing
  transfer/mint/burn/freezeResource non-replaceKey tests; term-level
  API stability for the five `admissible_*`
  field extractors; the new `apply_admissible_base`,
  `apply_admissible_registry`, and
  `expectsNonce_after_apply_admissible_other` cross-actor isolation
  theorems; term-level `nonce_uniqueness`/`replay_impossible` API
  stability; post-advance ≠ pre-action nonce algebraic check; cross-
  actor isolation value-level check; full WU 3.10 key-rotation chain
  (forward + back + cross-actor isolation).

Tests use two complementary patterns:
1. **Value-level**: assert `==` between expected and actual results
   (catches definitional drift / Std-API renames at runtime).
2. **Term-level API stability**: ascribe a `let _proof : T :=
   theorem ...` binding whose type uses the theorem's exact
   signature (catches signature changes at elaboration time, before
   the `IO Unit` body runs).

The `Authority.SignedActionTests` suite uses term-level API checks
for `nonce_uniqueness` and `replay_impossible` (rather than
value-level admissibility witness construction) because the `Verify`
opaque cannot be reduced at the Lean level — the runtime adaptor
(Phase 5) wires the actual cryptographic implementation.  The
algebraic core of the theorems (the post-advance nonce inequality)
is value-level checked separately.

`lake test` runs the suite via the `Tests.lean` driver and exits
non-zero on any failure; CI runs the same driver.

**Axiom audit (Phase 3).**  `#print axioms` on every kernel, RBMap,
Phase-2, and Phase-3 theorem (kernel: 11 theorems; RBMap: 7
theorems; Conservation + per-law theorems: 19; Authority theorems:
~10) returns exactly `[propext, Classical.choice, Quot.sound]`.  No
custom axioms have been introduced in Phase 3.  The `Verify` and
`signingInput` declarations are `opaque`, not `axiom`, so they do
not appear in the axiom-audit output of theorems that mention them.

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

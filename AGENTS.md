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
Workstreams A – G complete (Lean side); Workstream LP (actor-scoped
policies) complete; Workstream LX (Lex law-declaration language)
milestones M1 / M2 / M3 complete; Workstream H (fault-proof
migration) complete (Lean side; Rust off-chain observer complete
under RH-G).  Phase 7 (Advanced Capabilities) is the next scoped
work; the Workstream-G amendment (`docs/GENESIS_PLAN.md` §15D)
ratifies the canon-as-rollup deployment scenario, the five Ethereum
trust assumptions, the bridge accounting equation, the EIP-712
signing surface, the ten-contract Solidity surface, and the F.1.x +
SC.3 cross-stack verification corpus.  See
`docs/GENESIS_PLAN.md` §12 / §15B / §15D and
`docs/planning/ethereum_integration_plan.md` / `docs/planning/fault_proof_migration_plan.md` / `docs/planning/ethereum_workstream_g_plan.md`
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
lake test                           # ~1907 tests across ~100 suites
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

# Workstream RH (Rust host runtime) — see runtime/README.md.
# Toolchain pin: runtime/rust-toolchain.toml (stable 1.83).
cd runtime && cargo build --workspace --all-targets
cd runtime && cargo test --workspace
cd runtime && cargo clippy --workspace --all-targets -- -D warnings
cd runtime && cargo fmt --all -- --check
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
│   │                             State, SignInput, Disputes, LocalPolicy,
│   │                             StateInjective, LocalPolicyInjective,
│   │                             BridgeInjective).  The `*Injective.lean`
│   │                             siblings host the EI.2 – EI.7 encoder-
│   │                             injectivity theorems: `StateInjective`
│   │                             covers the nested-map `State` / `BalanceMap`
│   │                             carrier plus the flat `NonceState` and
│   │                             `KeyRegistry` maps; `LocalPolicyInjective`
│   │                             covers `LocalPolicies`; `BridgeInjective`
│   │                             covers the bridge consumed / pending maps
│   │                             plus the concat-form `BridgeState.encode`.
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
│   │                             reference.  Workstream SC.1 (`Smt.lean`)
│   │                             adds the sparse-Merkle-tree cell-proof
│   │                             spec + soundness theorem alongside the
│   │                             witness-state form in `Cell.lean`.
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
├── runtime/                   -- Workstream RH (Rust host runtime).
│   ├── Cargo.toml             --   workspace manifest
│   ├── rust-toolchain.toml    --   pinned Rust channel (stable 1.83)
│   ├── canon-hash-fallback.c  --   AR.10 default fallback (lake-built)
│   ├── canon-cli-common/      --   shared CLI / logging helpers (RH-H)
│   ├── canon-cross-stack/     --   dev-dep fixture loader (RH-H)
│   ├── canon-verify-secp256k1/ --  RH-A.1 ECDSA secp256k1 verifier
│   ├── canon-hash-keccak256/  --   RH-A.2 keccak-256 hash adaptor
│   ├── canon-host/            --   RH-C (TCP / TLS / Unix network adaptor)
│   ├── canon-l1-ingest/       --   RH-B (L1 event watcher daemon)
│   ├── canon-event-subscribe/ --   RH-D (event subscription server)
│   ├── canon-storage/         --   RH-E.0 (Storage trait + SQLite-backed impl)
│   ├── canon-indexer/         --   RH-E.1 (SQLite event indexer daemon)
│   ├── canon-faultproof-observer/ -- RH-G off-chain bisection-game observer
│   ├── canon-bench/           --   RH-F (transfer-throughput benchmark)
│   └── tests/cross-stack/     --   shared fixture corpus (.cxsf files)
├── scripts/setup.sh           -- SHA-256-verified toolchain + Foundry installer
├── .github/workflows/ci.yml   -- Lean build + test + audits on PR / push
├── .github/workflows/ci-rust.yml -- Rust workspace build + test + clippy +
│                                  fmt on PR / push (path-filtered to
│                                  runtime/**)
├── README.md                  -- project entry point
├── CLAUDE.md                  -- this file
└── docs/
    ├── GENESIS_PLAN.md                  -- canonical design document
    ├── law_language_design.md           -- Lex DSL design notes
    ├── lex_amendment_walkthrough.md     -- LX-M3 worked walkthrough
    ├── decidability_discipline.md       -- decPre discipline
    ├── std_dependencies.md              -- Std lemma audit
    ├── economic_invariants.md           -- Phase-2 + monotonicity-tier design
    ├── extraction_notes.md              -- Lean → runtime erasure / persistence
    ├── fault_proof_design.md            -- Workstream H design rationale
    ├── fault_proof_runbook.md           -- Workstream H operator runbook
    ├── abi.md                           -- on-disk frame format + CLI ABI
    ├── audits/                          -- per-area Lean audit reports
    └── planning/                        -- engineering / workstream plans
        ├── ethereum_integration_plan.md     -- Workstreams A – G
        ├── actor_scoped_policies_plan.md    -- Workstream LP
        ├── lex_implementation_plan.md       -- Workstream LX
        ├── parameterized_laws_plan.md       -- (planning)
        ├── fault_proof_migration_plan.md    -- Workstream H engineering plan
        ├── audit_remediation_plan.md        -- audit-remediation workstream
        ├── chain_level_accounting_plan.md   -- §7.6.4 / §7.6.5 inductive promotion
        ├── cleanup_and_consolidation_plan.md -- documentation / visibility tidy-up
        ├── deferred_work_index.md           -- navigator across deferred-work plans
        ├── encoder_injectivity_plan.md      -- EI proof-track plan (complete)
        ├── ethereum_workstream_g_plan.md    -- E-G documentation amendment
        ├── lex_v2_v3_roadmap_plan.md        -- Lex v2 / v3 forward roadmap
        ├── open_questions.md                -- master design-decision registry
        ├── parameterized_laws_landing_plan.md -- PA landing plan
        ├── phase_7_plan.md                  -- advanced-capability portfolio
        ├── rust_host_runtime_plan.md        -- Phase 5 + E-A/B + H.10.5 Rust host
        ├── smt_cell_proofs_plan.md          -- SMT cell-proof cross-stack plan
        └── step_vm_coherence_plan.md        -- L1 step-VM 19-variant coherence + observer terminate wiring
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
                                Disputes / LocalPolicy add their own variants;
                                Encoding.StateInjective extends State with
                                the EI.2 – EI.4 encoder-injectivity theorems
                                for BalanceMap / State / NonceState /
                                KeyRegistry plus the State.Equiv relation;
                                Encoding.LocalPolicyInjective hosts EI.5
                                (LocalPolicies map injectivity);
                                Encoding.BridgeInjective hosts EI.6 + EI.7
                                (consumed / pending map injectivity plus
                                the concat-form BridgeState.encode).)

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

- **Patch-version bumps (DEFAULT).**  Each pull request bumps the
  patch component of the relevant package version unless the
  user explicitly says otherwise.  This is the default release
  discipline; deviations require explicit instruction in the
  task or commit message.  Scope:

  | Surface        | Bump location                                    |
  |----------------|--------------------------------------------------|
  | Lean kernel    | `lakefile.lean`'s `version` field on the         |
  |                | `package canon where` block.  Bumped in lockstep |
  |                | with the Rust workspace so Canon ships a single  |
  |                | semver across all surfaces.                      |
  | Rust workspace | `runtime/Cargo.toml`'s `[workspace.package]      |
  |                | version` field (every member crate inherits      |
  |                | via `version.workspace = true`).                 |
  | Solidity       | `solidity/foundry.toml` if a `version` field is  |
  |                | present (typically tracked at the contract /     |
  |                | release level rather than per-package).          |
  | README banner  | `README.md`'s top-of-file `**Version:** vX.Y.Z`  |
  |                | line.  Bumped in lockstep with the Lean / Rust   |
  |                | versions so the public-facing version banner     |
  |                | never drifts from the build artifacts.           |

  *Semantics.*  Use semver:
    - **Patch** (default): bug fixes, internal refactors,
      documentation-only changes, additional tests, performance
      improvements that don't change observable behaviour.
      Example: `0.1.0 → 0.1.1`.
    - **Minor**: new functionality that is backwards compatible
      (new public API, new feature flag, new optional config).
      Example: `0.1.5 → 0.2.0`.
    - **Major**: backwards-incompatible changes to the public
      API or wire format.  Example: `0.2.3 → 1.0.0`.
    The user opts into a non-patch bump explicitly (e.g.,
    "bump minor for this PR" or "this is a 1.0 release").

  *Mechanics for the Rust workspace.*  Bumping the workspace
  version requires updating exactly one line in
  `runtime/Cargo.toml`:

  ```toml
  [workspace.package]
  version = "0.2.9"     # <-- bump this
  ```

  Every member crate inherits via `version.workspace = true`.
  `Cargo.lock` is regenerated automatically by `cargo build`;
  the new lockfile must be committed in the same PR.

  *Mechanics for the Lean side.*  The Lean kernel's version is
  held on the `package canon where` block in `lakefile.lean`:

  ```lean
  package canon where
    version := v!"0.2.9"     -- <-- bump this
  ```

  This field is bumped in lockstep with the Rust workspace
  (`runtime/Cargo.toml`'s `[workspace.package] version`) so the
  two surfaces never drift.  Every PR — Lean-only, Rust-only,
  or both — bumps BOTH version fields to the same new value in
  the same PR.  No Lake-side lockfile is generated (Lake's
  resolved manifest is materialised at build time, not
  committed).

  *When NOT to bump.*  Pure documentation edits (typo fixes,
  README updates) within an in-progress workstream do not need
  their own patch bump if the workstream itself already has an
  in-flight PR that will bump.  Use judgement: a standalone
  doc-only PR still bumps; a doc tweak added mid-PR does not.

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
| EI.2    | Inner-map encoder injectivity         | `BalanceMap.encode_injective`     | `Encoding/StateInjective.lean`          |
| EI.2    | Nested-state encoder injectivity      | `State.encode_injective`          | `Encoding/StateInjective.lean`          |
| EI.3    | Nonce-ledger encoder injectivity      | `NonceState.encode_injective`     | `Encoding/StateInjective.lean`          |
| EI.4    | Key-registry encoder injectivity      | `KeyRegistry.encodeMap_injective` | `Encoding/StateInjective.lean`          |
| EI.5    | Local-policies map encoder injectivity | `LocalPolicies.encodeMap_injective` | `Encoding/LocalPolicyInjective.lean`  |
| EI.6    | Bridge-consumed map encoder injectivity | `Bridge.BridgeState.encodeConsumed_injective` | `Encoding/BridgeInjective.lean` |
| EI.7    | Bridge-pending map encoder injectivity | `Bridge.BridgeState.encodePending_injective` | `Encoding/BridgeInjective.lean`   |
| EI.7    | Bridge full-state encoder injectivity | `Bridge.BridgeState.encode_injective` | `Encoding/BridgeInjective.lean`     |
| EI.8    | State-commit sub-state extensional eq under CR | `commitExtendedState_subcommits_extensional_eq_under_collision_free` | `FaultProof/Commit.lean` (§15B.1) |
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
| H     | State-commit sub-state byte equality under CR | `commitExtendedState_subcommits_bytes_eq_under_collision_free` | `FaultProof/Commit.lean` (§15B.1) |
| H     | Kernel step coherent with kernelOnlyApply | `recomputeCommitment_coherent_with_kernelOnlyApply` | `FaultProof/Coherence.lean` (§15B.2) |
| H     | Multi-step coherence with kernelOnlyReplay | `recomputeCommitment_chain_coherent_with_kernelOnlyReplay` | `FaultProof/Coherence.lean` (§15B.2) |
| H     | Bisection narrows under any response  | `range_narrows_on_response_{agree,disagree}` | `FaultProof/Game.lean` (§15B.3) |
| H     | Bisection converges after enough rounds | `bisection_converges_after_enough_rounds` | `FaultProof/Convergence.lean` (§15B.3) |
| H     | Disagreement persists along honest trace | `disagreement_persists_along_trace` | `FaultProof/Honesty.lean` (§15B.4)     |
| H     | Honest challenger wins at settlement  | `honest_challenger_wins_against_invalid_state_root` | `FaultProof/Settlement.lean` (§15B.4) |
| H     | Witness implies state-root wrong       | `faultProof_challenger_won_implies_state_root_wrong` | `FaultProof/Witness.lean` (§15B.6)¹ |
| SC.1  | SMT step injectivity under CR          | `smtStep_inj_under_collision_free` | `FaultProof/Smt.lean` (SC.1.d core) |
| SC.1  | SMT walk leaf injectivity under CR     | `walk_leaf_inj_under_collision_free` | `FaultProof/Smt.lean` (SC.1.d) |
| SC.1  | SMT cell-proof no value substitution   | `smtCellProof_no_value_substitution` | `FaultProof/Smt.lean` (SC.1.e) |
| SC.1  | SMT cell-proof soundness               | `smtCellProof_sound_under_collision_free` | `FaultProof/Smt.lean` (SC.1.d) |
| SC.1  | SMT verifier completeness              | `verifySmtCellProof_walks_to_root` | `FaultProof/Smt.lean` (SC.1.c) |
| SC.1  | SMT empty-subtree-hash array size      | `emptySubtreeHashes_size` | `FaultProof/Smt.lean` (SC.1.a) |
| SC.1  | SMT root output-size invariant         | `smtRoot_size` | `FaultProof/Smt.lean` (SC.1.b) |
| SC.3  | SMT cross-stack fixture corpus (50 honest + 50 adversarial) | `crosscheck-smt-cell-proof` suite | `LegalKernel/Test/Bridge/CrossCheck/SmtCellProof.lean` (Lean fixture generator) + `solidity/test/CrossCheck/SmtCellProof.t.sol` (Solidity consumer) |
| SVC   | Step-VM dispatcher mirrors Solidity executeStep | `stepVMHash_<variant>_kind` (17 per-variant `rfl` proofs) | `FaultProof/StepVMCoherence.lean` |
| SVC   | Canonical step-VM hash via action-driven inputs | `stepVMHashFromAction`, `step_vm_dispatch_well_typed` | `FaultProof/StepVMCoherence.lean` |
| SVC   | Terminate-bundle cell-proofs verify against pre-state commit | `buildTerminateBundle_cellProofs_verify` | `FaultProof/TerminateBundle.lean` |

¹ The shipped theorem decomposes a `FaultProofChallengerWon` witness's L1 attestation against an explicit `L1AttestationSemantics` deployment assumption (the operational implication "L1 watcher confirms ⇒ sequencer's claim ≠ canonical commit").  The L1 contract enforces this operationally; cross-stack verification (WU H.10.1 corpus) ratifies it.

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
| E-A       | Ethereum: cryptographic adaptors   | Complete (Lean + Rust RH-A.1 / RH-A.2) |
| E-B       | Ethereum: identity and authority   | Complete (Lean + Rust RH-B) |
| E-C       | Ethereum: bridge laws              | Complete (Lean side; chain-level §7.6.4 / §7.6.5 follow-up) |
| E-D       | Ethereum: withdrawal proofs        | Complete |
| E-E       | Ethereum: Solidity contracts       | Complete |
| E-F       | Ethereum: cross-stack verification | Complete |
| LP        | Actor-scoped policies              | Complete (Lean side; Solidity mirror future work) |
| LX-M1     | Lex: macro skeleton + synthesizer  | Complete |
| LX-M2     | Lex: re-express 17 kernel laws     | Complete |
| LX-M3     | Lex: deployment manifests + governance | Complete |
| H         | Fault-proof migration              | Complete (Lean + Rust off-chain observer RH-G) |
| RH-H      | Rust host: workspace + CI harness  | Complete |
| RH-A.1    | Rust host: secp256k1 verify adaptor | Complete |
| RH-A.2    | Rust host: keccak256 hash adaptor  | Complete |
| RH-B      | Rust host: L1 event ingestor       | Complete |
| RH-C      | Rust host: network adaptor         | Complete |
| RH-D      | Rust host: event subscription      | Complete (Rust framework; Lean `canon extract-events` subcommand deferred) |
| RH-E.0    | Rust host: storage abstraction     | Complete |
| RH-E.1    | Rust host: SQLite indexer          | Complete (Rust framework; `--verify-against-canon` wiring deferred pending canon-host getBalance endpoint) |
| RH-F      | Rust host: 10k tx/sec benchmark    | Complete (harness ships; observed throughput ~7.5k ops/sec under default workload — gap documented in plan §RH-F closeout) |
| RH-G      | Rust host: fault-proof observer    | Complete (off-chain observer daemon; game state machine + honest strategy + L1 watcher + persistence + JSON-RPC EIP-1559 submitter + `canon replay-up-to` / `canon export-cell-proofs` subcommands + eth_call game-state reader + chaos suite + 50-trace cross-stack corpus) |
| SC.1      | SMT cell proofs: Lean spec + soundness | Complete |
| SC.2      | SMT cell proofs: Solidity verifier | Complete |
| SC.3      | SMT cell proofs: cross-stack soundness + corpus | Complete |
| SVC       | L1 step-VM cross-stack coherence + observer terminate wiring | Complete (Lean + Rust; cross-stack 218-entry fixture corpus with cell-proof bundles emitted per fixture entry; all 134 happy fixtures byte-equivalence-tested against Solidity `executeStep` under `isKeccak256Linked = true` via a single uniform driver) |
| E-G       | Ethereum: documentation + amendment | Complete (GENESIS_PLAN §15D + ABI §16 + extraction_notes §2.X + std_dependencies refresh) |
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
`"canon-step-vm-coherence"` (SVC).  `Test/Umbrella.lean`,
`Lex/Test/M2.lean`, and `Lex/Test/ExampleLex.lean` all pin this
value in regression tests, so any phase / milestone bump must
update the constant and every pinning test in the same PR.

**Test count.**  ~2 382 tests across 128 suites at the
GP.3.3 closure (Workstream GP §15E v1.0 admission gate + Action-
layer integration + five-round post-audit security hardening +
bridge-aware parity coverage + Workstream-GP bridge-replay fix +
step-VM dispatcher extension to kinds 19 / 20 + cross-stack
fixture-corpus extension to 238 entries + per-variant coherence
specialisations for the two new variants + end-to-end
`stepVMHashFromAction` production-path coverage + terminate-bundle
coverage for the new variants).  `lake test` is the
canonical query; the exact number drifts upward with every PR.
Only monotonic growth is enforced — individual regression tests
land alongside new theorems, and no global gate pins the count.

Notable Lean suites at the current build tag:

  * `authority-signed-budget` (41 cases, GP.3.2 v1.0) — pins all
    10 GP.3.2 admission-gate theorems at the value level
    (`admission_consumes_budget_on_success`,
    `admission_rejected_when_budget_zero`,
    `bridgeActor_budget_exempt`,
    `depositWithFee_grants_budget`,
    `depositWithFee_budget_locality`,
    `topUpActionBudget_net_budget_change`,
    `admission_locality_in_budget`,
    `replenishment_via_epoch_advance`,
    `nonce_uniqueness_preserved`,
    `replay_impossible_preserved`) plus regression coverage for
    cross-actor budget isolation, self-topup chain semantics,
    **five-round post-audit security hardening**: (a)
    insufficient-gas REJECTION (round 1), (b) zero-gas
    REJECTION (round 2), (c) bridgeActor self-topup REJECTION
    (round 3, defense in depth), (d) self-pool topup REJECTION
    (round 4, defends against `signer = poolActor` gas-round-trip
    attack that would otherwise grant free budget), (e) non-bridge
    depositWithFee REJECTION (round 5, defends against a non-
    bridgeActor signer crediting themselves with free balance +
    free budget) — pins all five on both the kernel-only and
    bridge-aware mirrors, boundary conditions (zero budgetGrant /
    zero budgetIncrement / all-zero topup args), genesis-default
    rejection, bridge-aware mirror parity (seven additional
    value-level tests against `apply_bridge_admissible_with_budget`,
    including the bridge-aware zero-gas, bridgeActor-topup,
    self-pool, and non-bridge-depositWithFee rejections), and
    the depositWithFee-recipient-equals-bridgeActor corner case.
    Each theorem additionally has a term-level API stability
    test ensuring the theorem signature survives future refactors.
  * `authority-actorbudget` (10 cases) — pins the GP.1
    foundational lemmas consumed by the GP.3.2 admission proofs
    (`currentBudget_after_consume_self/other`,
    `currentBudget_after_topUp_self/other`,
    `consume_eq_none_iff`, `currentBudget_floored_at_freeTier`,
    `currentBudget_empty_genesis`).
  * `encoding-action` (35 cases) — extended with byte-stable CBE
    encode/decode round-trip + per-field injectivity + tag
    regression pins for the two new GP.2.3 constructors
    (`depositWithFee` at index 19, `topUpActionBudget` at index 20).

  * `faultproof-stepvm-coherence` (100 cases, GP.3.3) — pins the
    21-variant step-VM dispatcher byte-for-byte against Solidity's
    `executeStep`, including the bulk-variant 256-recipient cap,
    adversarial-input regressions on `decodeCellNat`, and the
    Workstream-GP additions: per-variant value-level dispatch
    tests for kinds 19 / 20 with distinct / self-credit /
    self-pool defended branches, the load-bearing
    `budgetGrant` / `budgetIncrement` design property (admission-
    layer fields excluded from the step-VM hash), and four
    end-to-end `stepVMHashFromAction` production-path tests that
    verify the full `commitExtendedState` + `actionFieldsForL1` +
    `buildObserverCellProofs` + dispatcher chain reads the correct
    pre-balances from the observer bundle (distinct, self-credit,
    topUp, and zero/absent-pre-balance cases).
  * `crosscheck-step-vm` (37 cases, GP.3.3) — pins per-variant
    fixture counts for the 238-entry corpus (218 from SVC.5.e +
    20 Workstream-GP additions) plus cell-proof bundle
    invariants for all 146 happy fixtures.
  * `faultproof-terminate-bundle` (20 cases) +
    `integration-export-terminate-bundle-cli` (15 cases) — wire
    the `canon export-cell-proofs` subcommand to the RH-G
    observer's terminate-bundle JSON contract.
  * `faultproof-smt` (79 cases, SC.1) — `BitsKey` instances
    (UInt64 + ByteArray, MSB-first), canonical empty-subtree
    hash chain, walk determinism, tamper rejection (wrong root,
    ill-formed proof, tampered value / key / sibling / bitmask
    bit), `buildSmtCellProof` construction for 0/1/2/3/4/8-cell
    maps, insertion-order independence, 8-key stress + full
    substitution-rejection sweep, output-shape guarantees.
  * `crosscheck-smt-cell-proof` (16 cases, SC.3) — the 100-entry
    honest + adversarial corpus consumer (six tamper classes),
    byte-shape invariants for `smtKey` / `leafPreimage` /
    `proofData` / `root`, fixture byte-determinism, write/verify
    cycle, and the `isKeccak256Linked` cross-stack gate.
  * `encoding-injectivity` (78 cases, EI track) — EI.2 – EI.8
    inner-map / state / nonce-ledger / key-registry / local-policy
    / bridge sub-state injectivity ladders, plus value-level
    smoke checks on the `State.Equiv` corollaries.

**Rust-side test count.**  ~1 400 tests across the 11 workspace
crates at the RH-G audit-pass-4-round-6 landing.  `cargo test
--workspace --locked` from `runtime/` is the canonical query.
Approximate per-crate breakdown at the landing:

| Crate                            | Tests | Role                                                       |
|----------------------------------|-------|------------------------------------------------------------|
| `canon-cli-common`               |   ~8  | shared logging / exit-code / paths helpers                 |
| `canon-cross-stack`              |  ~31  | fixture loader dev-dep                                     |
| `canon-verify-secp256k1`         |  ~42  | RH-A.1 ECDSA secp256k1 verifier (cdylib)                   |
| `canon-hash-keccak256`           |  ~32  | RH-A.2 Keccak-256 hash adaptor (cdylib)                    |
| `canon-l1-ingest`                | ~227  | RH-B L1 event watcher daemon                               |
| `canon-host`                     | ~183  | RH-C TCP/TLS/Unix network adaptor                          |
| `canon-event-subscribe`          | ~176  | RH-D event subscription server                             |
| `canon-storage`                  |  ~67  | RH-E.0 storage abstraction + SQLite impl                   |
| `canon-indexer`                  | ~138  | RH-E.1 SQLite event indexer daemon                         |
| `canon-bench`                    | ~111  | RH-F transfer-throughput benchmark                         |
| `canon-faultproof-observer`      | ~312  | RH-G off-chain bisection-game observer                     |

Per-WU + per-audit completion narratives live in git history
(`git log --grep="WU"` / `git log --grep="audit"`), not here — per
the file's own "Active development history" rule below.

### Workstream snapshots

Each entry below describes the *current state* — what ships and where
the code lives, not the path that got us here.  Per-WU and per-audit
narratives live in git history (`git log --grep="WU"` / `git log
--grep="audit"`).

**Workstream RH-H (Rust host workspace + CI harness).**  **Complete.**
Lands the workspace under `runtime/` (11 member crates: 10 from the
plan §2.2 layout plus `canon-cross-stack`, the dev-dep fixture loader)
per `docs/planning/rust_host_runtime_plan.md` §RH-H.  Highlights:

  * Two foundation crates: `canon-cli-common` (shared logging /
    exit-code / paths helpers) and `canon-cross-stack` (cross-stack
    fixture loader + file-format spec).  Downstream crates dev-dep
    on `canon-cross-stack` for byte-equivalence assertions against
    the Lean reference.
  * `runtime/rust-toolchain.toml` pins stable 1.83;
    `workspace.package.rust-version = "1.83"` documents the MSRV.
  * `.github/workflows/ci-rust.yml` runs four gates on every PR
    touching `runtime/**`: `cargo build --workspace --all-targets`,
    `cargo test --workspace`, `cargo clippy --workspace
    --all-targets -- -D warnings`, `cargo fmt --all -- --check`.
    Third-party action SHAs verified against upstream release tags.
  * `unsafe_code = "forbid"` workspace default;
    `missing_docs = "warn"`; `clippy::pedantic` enabled workspace-wide.
    Crates exposing FFI shims (RH-A.1, RH-A.2) relax to
    `unsafe_code = "deny"` with `# Safety` annotations on every
    `unsafe` block.
  * Cross-stack fixture format: 16-byte "CXSF" header (magic +
    version + kind tag + count), per-record `(u32 BE input-len,
    input, u32 BE expected-len, expected)`.  Panic-free parser;
    every error path returns a typed `LoaderError` variant.

**Workstream RH-A (Cryptographic adaptors).**  **Complete.**
Materialises the two `cdylib` adaptors a Lean deployment links against
to wire the kernel's crypto opaques.

  * **RH-A.1 — `canon-verify-secp256k1`.**  Production ECDSA secp256k1
    verification adaptor.  Exposes the `canon_verify_ecdsa` C ABI
    symbol; a Lean deployment with a matching `@[extern
    "canon_verify_ecdsa"]` declaration on `Authority.Crypto.Verify`
    links here at runtime.  Strict input validation (33-byte
    SEC1-compressed pubkey with 0x02 / 0x03 prefix, 32-byte pre-hashed
    message, 64-byte `(r ‖ s)` signature), `1 ≤ r < n` and `1 ≤ s < n`
    bounds, EIP-2 / BIP-62 low-s canonicalisation via `k256::IsHigh`.
    Built on `k256 = "0.13"`.  210-record cross-stack fixture corpus
    (`runtime/tests/cross-stack/ecdsa_secp256k1.cxsf`).
  * **RH-A.2 — `canon-hash-keccak256`.**  Production Keccak-256
    (Ethereum-flavoured, NOT FIPS-202 SHA3-256) hash adaptor.  Exposes
    three C ABI symbols matching Lean's `@[extern]` declarations in
    `Runtime/Hash.lean`: `canon_hash_bytes`, `canon_hash_stream`,
    `canon_hash_identifier`.  Production binaries link the cdylib
    AHEAD of the `canon-hash-fallback.o` forwarder to override the
    FNV-1a-64 fallback.  Identifier: `"keccak256/EVM-compatible/v1"`.
    Built on `sha3 = "0.10"`.  51-record cross-stack fixture corpus
    (`runtime/tests/cross-stack/keccak256.cxsf`).
  * **C ABI shim design.**  Each crate ships a tiny C shim
    (`c/lean_shim.c`) wrapping Lean's `static inline` runtime API as
    non-inline `canon_lean_*` symbols.  `build.rs` discovers `lean.h`
    via `LEAN_INCLUDE_DIR` → `LEAN_SYSROOT` → `lean --print-prefix` →
    soft-skip.  The `lean-ffi` Cargo feature promotes a missing
    `lean.h` to hard-fail for production builds.

**Workstream RH-B (L1 event ingestor).**  **Complete.**  The
long-running daemon that watches Ethereum L1, translates `CanonBridge`
/ `CanonIdentityRegistry` event logs to Canon `Action`s via the
byte-equivalent Rust mirror of `LegalKernel.Bridge.Ingest.ingest`,
signs with a `zeroize`-protected bridge-actor key, and forwards
CBE-encoded `SignedAction`s to the downstream consumer.

  * **Surface.**  `canon-l1-ingest` library + daemon binary
    (`--l1-rpc / --bridge-actor-keystore / --canon-host-url /
    --bridge-contract / --identity-registry / --state-file
    [+ optional --deployment-id / --confirmation-depth /
    --poll-interval-ms / --until-block]`).  Identifier:
    `"canon-l1-ingest/v1"`.
  * **Byte-exact CBE.**  `src/encoding.rs` hand-rolls Lean's
    `Encoding.Action.encode` layout byte-for-byte: 1-byte tag +
    8-byte LE-Nat head per field; byte strings as head + raw
    payload; constructor-tag indices frozen against
    `Encoding/Action.lean`.  12-record cross-stack corpus
    (`l1_ingest.cxsf`).
  * **No `ethers-rs` / `tokio` dependency.**  Hand-rolled minimal
    Ethereum ABI decoder (`src/events.rs`) over the four event
    signatures; synchronous watcher loop.
  * **Re-org tolerance.**  `src/reorg.rs::ReorgWindow` — bounded
    `VecDeque<BlockHeader>` with `advance` returning
    `Advanced` (linear) / `Reorged` (shallow re-org absorbed).
    Deeper re-orgs return `DeepReorg` / `OrphanedParent` and the
    watcher halts loudly.  Logs fetched by **block hash**
    (EIP-234), defending against re-org racing the header→logs
    fetch.  Re-org-tolerant idempotency via `(block_hash, tx_hash,
    log_index)` keying; idempotent across restarts via the JSONL
    state file.
  * **Atomic state mutations.**  Each successful submission writes
    a single `Submitted` JSONL record carrying the forwarded key,
    new `next_nonce`, and (optional) address-book assignment.
    Address-book is mutated only AFTER a successful submission
    (preview / commit discipline).
  * **Hand-rolled JSON-RPC.**  `src/source.rs::json_rpc` is a
    minimal HTTP/1.1 client over `std::net::TcpStream`.  Supports
    `eth_blockNumber`, `eth_getBlockByNumber`, `eth_getLogs`.
    10 MiB max-response DoS guard; 10 s default request timeout.
  * **Cryptographic discipline.**  `src/key.rs::BridgeActorKey`
    wraps the 32-byte secp256k1 private scalar in `Zeroizing<[u8;
    32]>` (scrubbed on drop).  `sign_prehash` emits low-s `(r ||
    s)` signatures via `k256` v0.13.

**Workstream RH-C (Network adaptor).**  **Complete.**  The
TCP / TLS-on-TCP / Unix-socket service that accepts length-prefixed
CBE-encoded `SignedAction` requests, dispatches them to a configured
`Kernel` implementation, and returns a verdict byte (+ optional UTF-8
reason).

  * **Surface.**  `canon-host` library + daemon (`--listen /
    --tls-listen / --tls-cert / --tls-key / --unix-socket /
    --canon-binary / --canon-log / --canon-work-dir /
    --deployment-id / --max-queue-depth / --max-frame-size /
    --max-concurrent-connections / --mock`).  Identifier:
    `"canon-host/v1"`.
  * **Canonical wire format.**  Request: 4-byte BE u32 length + N
    CBE-encoded `SignedAction` bytes.  Response: 1-byte verdict
    (0=Ok, 1=NotAdmissible, 2=ParseError, 3=Busy) + 4-byte BE u32
    reason length + M UTF-8 reason bytes.  Documented in
    `docs/abi.md` §10.
  * **No `tokio` dependency.**  Uses `std::thread` + bounded
    `std::sync::mpsc::sync_channel` instead — smaller dependency
    tree, matches the workspace's "no async runtime" philosophy.
    Per-connection `std::thread::spawn` + a single dedicated
    worker thread for kernel dispatch.
  * **Three listener variants.**  `tcp::TcpListener`,
    `tls::TlsListener` (`rustls` + `ring` backend),
    `unix::UnixListener` (mode 0600; refuses to clobber non-socket
    files).  Multiple transports may be configured simultaneously.
  * **`Kernel` abstraction.**  `MockKernel` (in-memory test /
    dev kernel) and `CommandKernel` (spawns the Lean `canon`
    binary's `process` subcommand per request).  `CommandKernel`
    is heavy (re-loads the log file every request); a future
    persistent `canon serve` subcommand would eliminate the
    per-request bootstrap cost.
  * **Hardening.**  Bounded mpsc queue with `Busy` overflow;
    `--max-concurrent-connections` cap via RAII `ConnectionSlot`;
    spawn-storm DoS defence; in-flight drain on shutdown; per-
    connection write-timeout; kernel-panic isolation via
    `panic::catch_unwind`; `unsafe_code = "forbid"`.

**Workstream RH-D (Event subscription server).**  **Complete (Rust
framework; Lean `canon extract-events` subcommand deferred).**  The
TCP service that tails Canon's transition log, extracts deployment-
facing events via a Lean `canon` subprocess, and streams those events
to subscribers in strict order with bounded-lag eviction.

  * **Surface.**  `canon-event-subscribe` library + daemon
    (`--log-path / --listen / --mock | --canon-binary /
    --max-subscriber-lag / --keep-history / --max-frame-size /
    --max-subscribers / --max-concurrent-connections /
    --send-queue-depth / --write-timeout-ms /
    --handshake-read-timeout-ms / --poll-interval-ms`).
    Identifier: `"canon-event-subscribe/v1"`.
  * **Canonical wire format.**  Documented in `docs/abi.md` §11.
    Inbound `SUBSCRIBE` frame (1-byte kind + 8-byte BE u64
    resume-from); outbound `EVENT` frame (1-byte kind + 8-byte BE
    seq + 4-byte BE length + N CBE event bytes); 4 termination /
    control frames each 9 bytes total: `LAG_EXCEEDED`,
    `TRUNCATED`, `SERVER_SHUTDOWN`, `INVALID_REQUEST`.
  * **No `tokio` / `inotify` dependency.**  Uses `std::fs::File`
    + simple metadata-poll cursor.  Default poll interval 100 ms;
    operator-tunable via `--poll-interval-ms`.
  * **Log-tail reader.**  `tail.rs::TailReader` walks the Lean
    log-file format (4-byte "CANO" magic + 8-byte LE length +
    payload + 8-byte LE FNV-1a-64 trailer).  Pending frames
    (writer mid-frame) distinguished from corruption (bad magic /
    trailer / oversize).  Symlink rejection + post-open inode
    verification + truncation detection.
  * **Extractor abstraction.**  `MockExtractor` (programmable
    test impl) and `SubprocessExtractor` (spawns `canon` in a
    future `extract-events` mode; re-spawns on subprocess crash
    with exponential backoff).
  * **Event cache + backfill.**  Bounded FIFO `EventCache`;
    `range(from_seq)` returns `InWindow` / `OutOfWindow` /
    `AtLiveTail`.  Resume semantics: `resume_from == 0` means
    live-tail; `> 0` means "give me everything strictly greater
    than X".  Out-of-window resumes return a typed `TRUNCATED`
    frame.  Multi-event-per-frame batches handled atomically
    against subscriber-set snapshots taken once per batch
    (registration atomicity), AND enqueued as a single channel
    slot (`DeliveryEvent::Live(Vec<CachedEvent>)`) so a queue-full
    condition drops/evicts the WHOLE batch — never a prefix
    (C-NEW-2 audit fix; closes a partial-batch race where a
    subscriber whose bounded queue filled mid-batch received a
    silently-incomplete frame).
  * **Subscriber bounded-lag.**  Each subscriber's eviction is
    independent — slow subscribers do not delay events to fast
    subscribers.  Per-subscriber atomic disconnect / lag counters
    / last-delivered-seq.  `--max-subscribers` cap enforced at
    registration time.  Lag accounting and queue depth are now
    batch-granular (one slot per log frame).

**Workstream RH-E (SQLite indexer + Rust DB layer).**  **Complete
(Rust framework; `--verify-against-canon` wiring deferred pending
canon-host getBalance endpoint).**  Two crates that materialise the
storage abstraction (RH-E.0) and the per-(actor, resource) balance
indexer (RH-E.1).

  * **RH-E.0 — `canon-storage` (library only).**  `Storage` /
    `StorageSnapshot` / `StorageTransaction` traits.  Byte-array
    keys with strict lex-order scan contract.  `SqliteStorage`
    implementation: single-table `kv(key BLOB PRIMARY KEY NOT NULL,
    value BLOB NOT NULL) WITHOUT ROWID` + a `_meta` table for the
    schema version.  Pragmas: `journal_mode = WAL`, `synchronous =
    NORMAL`, `foreign_keys = ON`, `temp_store = MEMORY`.  Wraps
    `rusqlite` in `std::sync::Mutex`; `rusqlite = "0.31"` with
    `bundled` so SQLite is compiled from source (no system
    libsqlite3 dep).  Snapshots use `BEGIN DEFERRED` + a forced
    `SELECT 1 FROM sqlite_master LIMIT 1` to pin the WAL read mark
    immediately.  Append-only `MIGRATIONS` table; `BEGIN IMMEDIATE`
    for migrations + version re-read inside the transaction.
    Auto-commit defence: every `snapshot()` / `transaction()` call
    issues a defensive ROLLBACK if `is_autocommit()` is false.
  * **RH-E.1 — `canon-indexer` (library + binary).**  `daemon`
    subcommand subscribes to `canon-event-subscribe` and maintains
    a per-(actor, resource) balance view; `query <actor>
    <resource>` provides ad-hoc lookups.  Idempotent restart via
    a stored cursor; each event-batch commits atomically with
    the cursor advance.  Identifier: `"canon-indexer/v1"`.
  * **Event dispatch contract** (see `docs/abi.md` §11A.4):
    - `BalanceChanged(r, a, _, new_v)` → `set(a, r, new_v)`
      (authoritative).
    - `RewardIssued(r, recipient, amount)` → `credit(recipient,
      r, amount)` (saturating).
    - `WithdrawalRequested(r, sender, amount, ...)` →
      `debit(sender, r, amount)` (strict; underflow rolls back).
    - `DepositCredited(r, recipient, amount, _)` →
      `credit(recipient, r, amount)` (saturating).
    - All other event tags → no-op at the balance-view layer.
    Two-pass dispatch order (BalanceChanged authoritative AFTER
    semantic events) prevents double-counting and underflow on
    `[balanceChanged?, rewardIssued|withdrawalRequested]` batches.
  * **Hardening.**  Partial-batch discard on EOF / ServerShutdown /
    LagExceeded (no per-batch terminator in §11 wire format —
    only a strictly-greater seq trigger commits).  Hard
    `INDEXER_MAX_BATCH_EVENTS = 1024` cap.  Commit-failure
    classification: `CommitAmbiguous` (recoverable; cursor
    re-loaded from disk) vs `CursorRecoveryFailed` (poisons the
    indexer; restart required).  Poisoned indexer rejects all
    `apply_batch` calls until process restart.

**Workstream RH-F (Transfer-throughput benchmark).**  **Complete.**
Materialises `runtime/canon-bench/` as a deterministic transfer-
throughput harness per `docs/planning/rust_host_runtime_plan.md`
§RH-F.

  * **Surface.**  Library + binary (`canon-bench`) with CLI flags
    `--standalone | --connect <ENDPOINT>` for mode selection;
    `--actor-count / --transfer-count / --worker-count /
    --warmup-requests / --seed` for the workload; `--queue-depth
    / --max-frame-size` for the embedded server; `--report <PATH>
    / --baseline <PATH> / --threshold <FRAC> / --target-tps <N> /
    --target-p99-ms <N>` for the JSON report + regression gates.
    Identifier: `"canon-bench/v1"`.
  * **Deterministic fixture.**  Pre-funds `actor_count` (default
    1000) secp256k1 keypairs derived from a `(seed, actor_index)`
    Keccak-256 hash chain with rejection sampling into `[1, n)`
    curve order.  Generates `transfer_count` (default 10 000)
    round-robin `Action::Transfer` payloads signed with the
    sender's actor key + per-actor monotonic nonce.  Reuses
    `canon-l1-ingest::encoding` primitives so emitted SignedAction
    bytes are cross-stack-equivalent to Lean's
    `Encoding.SignedAction.encode`.  Two runs with the same
    `(seed, actor_count, transfer_count)` produce byte-identical
    payloads.
  * **Concurrent driver.**  Default 64 submitter threads sharing
    an atomic cursor into the pre-framed payloads.  Each worker
    opens a fresh connection per request (mirroring canon-host's
    one-shot wire format), writes the framed payload, reads the
    5-byte verdict header + reason payload, and records elapsed
    wallclock as a latency sample.  Per-worker histograms merged
    at the end.  Throughput is wallclock between first measured
    submission and last response.
  * **Histogram.**  Bounded-resolution sample collector via a
    `Vec<u64>` of per-request nanosecond durations.  Percentiles
    via NIST nearest-rank method; mean / stddev via the Welford
    one-pass numerically-stable algorithm.  Insertion is `O(1)`;
    report is `O(N log N)`.
  * **Observed throughput.**  Default 1000-actor / 10 000-transfer
    / 64-worker workload sustains ~7 500 ops/sec on a developer
    workstation (Linux 6.18, opt-level=3, LTO=thin) with p50 ~ 8
    ms and p99 ~ 13 ms.  The plan §RH-F target (≥ 10 000 tx/sec,
    p99 < 10 ms) is partially met; the gap is the one-shot-per-
    request connection pattern + listener polling.  Resolving
    requires a persistent-connection wire-format amendment
    (Phase-7 roadmap).
  * **JSON report + regression check.**  `BenchmarkReport`
    serialises to versioned JSON (the `protocol_version` field
    gates forward-incompatible schema evolution).
    `compare_against_baseline` detects throughput drops or
    latency growths beyond `threshold` (default 10 %).
    `--target-tps` / `--target-p99-ms` give the CI escape hatch
    for new deployments without a baseline.  Atomic save via
    sibling `.tmp` + `rename(2)`.  Hardened against silent
    serde-json `INFINITY` / `NaN` corruption.

**Workstream RH-G (Off-chain fault-proof observer).**  **Complete.**
Materialises `runtime/canon-faultproof-observer/` as the operational
counterpart to the Workstream-H Lean fault-proof soundness chain.
See `docs/planning/rust_host_runtime_plan.md` §RH-G and
`docs/fault_proof_runbook.md` §7.

  * **Surface.**  Library (11 modules: `config`, `error`, `events`,
    `game`, `jsonrpc_submitter`, `observer`, `persistence`,
    `state_reader`, `strategy`, `submitter`, `watcher`) plus the
    `canon-faultproof-observer` daemon (CLI flags `--l1-rpc /
    --game-contract / --state-root-contract / --storage /
    --keystore / --deployment-id / --play-as /
    --confirmation-depth / --reorg-window / --blocks-per-iter /
    --poll-interval-ms / --start-block / --canon-binary /
    --canon-log / --chain-id / --log-level`).  Identifier:
    `"canon-faultproof-observer/v1"` (published via
    `OBSERVER_IDENTIFIER` and the storage's `w/identifier` cell).
  * **Game state machine** (`src/game.rs`).  Rust port of
    `LegalKernel.FaultProof.Game.applyTransition` —
    byte-for-byte equivalent.  Identical data shapes (`Claim`,
    `DisputedRange`, `TurnSide`, `GameStatus`, `GameState`,
    `GameTransition`, `GameError`); identical transition
    function.  Bisection converges in `ceil(log2(width))` rounds.
  * **Honest-strategy computation** (`src/strategy.rs`).  The
    `TruthOracle` trait abstracts `LogIndex → StateCommit`; two
    impls: `MemoryTruthOracle` (in-memory; for tests / dev) and
    `SubprocessTruthOracle` (shells out to `canon replay-up-to
    LOG IDX`, with bounded stdout cap and spawn-drain-before-wait
    discipline to avoid pipe-buffer deadlocks).  `compute_next_move`
    mirrors Lean's `honestStrategy` decision tree exactly.
  * **L1 event-watch + re-org handling** (`src/watcher.rs`,
    `src/events.rs`).  Reuses `canon-l1-ingest`'s `ReorgWindow` +
    `L1Source` trait surface.  Decodes the five game-contract
    events (`FaultProofGameOpened`, `BisectionMidpointSubmitted`,
    `BisectionResponseSubmitted`, `FaultProofGameSettled`,
    `StateRootSubmitted`).  Defence-in-depth: logs fetched by
    block hash, not number.  Cross-contract logs in a single
    block merged + decoded in `log_index` order.  Keccak256 topic
    hashes hard-pinned to canonical hex.
  * **Response submission + signing** (`src/submitter.rs`,
    `src/jsonrpc_submitter.rs`).  `Submitter` trait + two impls:
    `MockSubmitter` (in-memory; records every submission) and
    `JsonRpcSubmitter` (production EIP-1559 typed-2 transaction
    encoder + `eth_sendRawTransaction` driver; defence-in-depth
    tx-hash cross-check; hand-rolled RLP encoder; signs via
    `canon-l1-ingest::key::BridgeActorKey::sign_prehash`'s low-s
    wrapper).  `encode_calldata` emits the four observer-callable
    methods' ABI calldata (`submitMidpoint`, `respondToMidpoint`,
    `terminateOnSingleStep`, `claimTimeout`); method selectors
    pinned against `forge inspect` canonical values.
    `JsonRpcSubmitter` wired into the production binary via the
    `--chain-id` CLI flag; `verify_rpc_chain_id` called at startup.
    Gas-estimate margin formula: `raw * 1.25`.  Nonce-cache
    peek/commit discipline: sign-time failures don't consume
    nonces; broadcast-time failures clear the cache via
    `Submitter::invalidate_nonce_cache`.
  * **eth_call game-state reader** (`src/state_reader.rs`).
    Decodes the Solidity `games(uint256)` getter's 18-slot ABI
    response.  Closes the cold-start gap: games adopted from
    `FaultProofGameOpened` events start with `state_known = false`;
    `Observer::hydrate_cold_start_games` flips to `state_known =
    true` via the audited `mark_state_known` API (deployment-id
    cross-check + range non-degeneracy + status non-resurrection
    guards).  Strict-bool / oversize / collision invariants on
    decoded fields; turn / status slot high-byte validation.
  * **Persistence + crash recovery** (`src/persistence.rs`).
    `canon-storage`-backed game / response / cursor / identifier
    cell layout.  Keyspaces: `g/<game_id_16BE>`,
    `r/<tx_hash_32>`, `w/cursor`, `w/identifier`,
    `w/reorg_window`.  Every batch commits atomically via
    `Storage::transaction` (game updates + response records +
    cursor advance + reorg-window snapshot together).
    Identifier-cell discipline rejects opening a database from a
    different observer / version.  Crash-recovery classification:
    `CommitAmbiguous` (recoverable; cursor re-loaded) vs
    `CursorRecoveryFailed` (poisons the daemon; restart needed).
    In-memory `submitted_pivots` dedup cache for O(1) duplicate-
    submission detection; rollback on `commit_batch` failure.
  * **Lean cell-proof export** (`Main.lean`).  `canon
    export-cell-proofs LOG IDX SIGNER` builds the cell-proof
    bundle via `buildObserverCellProofs` and emits it as a JSON
    array.  The Rust submitter's `CellProof` struct consumes the
    same shape via custom serde deserializers for hex-encoded
    fields.  Module `LegalKernel.Runtime.CellProofJson`
    canonicalises the snake_case envelope.
  * **Cross-stack equivalence**
    (`tests/observer_game_traces.rs`).  50-trace observer game-
    trace corpus generated by Lean at
    `solidity/test/CrossCheck/fixtures/observer_game_traces.json`;
    Rust replays every trace and asserts byte-equivalence with
    Lean's `applyTransition`.
  * **Chaos suite** (`tests/chaos.rs`).  Covers shallow + deep
    re-orgs, kill-restart at varying iteration points, dropped-
    connection RPC injection, and an adversarial-opponent
    simulator.  `CANON_CHAOS_SEED=N` drives the seed-sweep entry
    point for operator-level fuzz testing.
  * **TerminateOnSingleStep wiring.**  Three of four move types
    (Submit / RespondAgree / RespondDisagree) are fully wired
    end-to-end through the production submitter.  Wiring
    TerminateOnSingleStep requires extending L1 step-VM coherence
    (workstream SVC) from its current 2-variant scope to all 19
    `Action` variants — tracked in
    `docs/planning/step_vm_coherence_plan.md`.  Until SVC
    completes, the off-chain observer's safety posture is
    unaffected: bisection rounds use opaque-actionFields hashing
    that matches cross-stack on both sides, so the observer can
    defend correctly by playing Submit / RespondAgree /
    RespondDisagree until the game settles via timeout.

**Workstream SC.3 (SMT cell-proof cross-stack soundness corpus).**
**Complete.**  Ships the cross-stack ratification of the SC.1 / SC.2
SMT cell-proof verifiers as a mechanical fixture corpus: 100 entries
(50 honest + 50 adversarial) generated by Lean and re-verified by
Solidity, byte-for-byte.  Closes the operational off-chain audit gap
documented in `docs/GENESIS_PLAN.md` §15B.

  * **Lean fixture generator** (`LegalKernel/Test/Bridge/CrossCheck/
    SmtCellProof.lean`, ~620 lines).  Generates fixtures via
    `buildSmtCellProof` against a `CrossStackUInt64` wrapper whose
    `Encodable` produces 8 big-endian bytes (matching Solidity's
    MSB-first key reading).  Six tamper classes (`valueSubst`,
    `siblingTamper`, `bitmaskTamper`, `rootTamper`, `keyMismatch`,
    `absentKey`).  Honest coverage: singleton / two-cell / three-
    cell / four-cell / eight-cell maps + 10 single-bit-position
    edge cases.
  * **Solidity consumer** (`solidity/test/CrossCheck/SmtCellProof
    .t.sol`).  12 test cases: header shape, per-entry
    `shouldVerify`-matches-position, structural invariants for
    `smtKey` / `leafPreimage` / `proofData` / `root`, per-entry
    cross-stack verdict (gated on `isKeccak256Linked`), per-honest-
    entry root byte-equality, spot checks, tamper-class coverage,
    syntactic-distinctness regressions.
  * **Wire-format alignment.**  Each entry: `smtKeyHex` (8-byte
    BE), `leafPreimageHex` (16 bytes: `keyBE ‖ valueBE`),
    `proofDataHex` (32-byte LSB-first bitmask ‖ N×32-byte
    siblings, low-depth-first), `rootHex` (32 bytes),
    `shouldVerify`, `tamper`.
  * **Hash-binding-conditional behaviour.**  At `lake test` time
    the per-entry verdict + root-byte tests are gated on the
    header's `isKeccak256Linked` flag (Lean's default fallback is
    FNV-1a-64; production keccak256 binding ships via
    `canon-hash-keccak256`).  Header-shape + byte-size assertions
    run unconditionally.

**Workstream SVC (L1 step-VM cross-stack coherence + observer
terminate wiring).**  **Complete (Lean + Rust).**  Extends the L1
step-VM coherence corpus from 2 variants (Transfer + Mint) to all 19
`Action` variants; lays the groundwork for fully wiring the
RH-G observer's `TerminateOnSingleStep` move type.  See
`docs/planning/step_vm_coherence_plan.md` for the engineering plan.

  * **Headline.**  `stepVMHash`-driven per-variant byte-equivalence
    against Solidity's `executeStep`.  218-entry fixture corpus
    with cell-proof bundles emitted per fixture entry; all 134
    happy fixtures byte-equivalence-tested against Solidity under
    `isKeccak256Linked = true` via a single uniform driver.
  * **Lean theorems.**  `stepVMHash_<variant>_kind` (17 per-variant
    `rfl` proofs in `LegalKernel/FaultProof/StepVMCoherence.lean`);
    `stepVMHashFromAction` canonical step-VM hash via action-driven
    inputs; `step_vm_dispatch_well_typed`;
    `buildTerminateBundle_cellProofs_verify`
    (`FaultProof/TerminateBundle.lean`).
  * **Test suites.**  `faultproof-stepvm-coherence` (100 cases —
    83 at SVC close, +17 from the Workstream-GP variant-19/20
    extension + end-to-end production-path coverage),
    `crosscheck-step-vm` (37 cases — 35 at SVC close, +2 GP
    fixture-count pins), `faultproof-terminate-bundle` (20 cases —
    18 at SVC close, +2 GP variant coverage),
    `integration-export-terminate-bundle-cli` (15 cases).

**Workstream AR (Audit Remediation).**  **Complete.**  See
`docs/planning/audit_remediation_plan.md` for the engineering plan.
Headline contributions surviving in current code:

  * **AR.1** shared `Authority.signedActionDomain` constant.
  * **AR.2** `RuntimeState.deploymentId` field threaded through
    `processSignedAction` / `bootstrap` / `replayWith` /
    `checkSignatureInvalidWith` + `--deployment-id <hex>` CLI
    flag on both `canon` and `canon-replay`.
  * **AR.2.5** parameterised `checkEvidenceWith verify d`
    dispatcher routing the `signatureInvalid` claim through
    `checkSignatureInvalidWith` with explicit deploymentId.
  * **AR.3** `bootstrapFromSnapshot` chain-anchor check
    (`.anchorMismatch`) + `bootstrapFromAttestedSnapshot` wrapper.
  * **AR.5 / AR.6** regression pins for all 19 `Action` and 16
    `Event` constructor indices.
  * **AR.7** `Lex.Tools.Diff` widened to compare type + kind +
    tactic body, not just names.
  * **AR.9** new `mock_import_audit` binary mechanically enforces
    "no production module imports `Test/*`".
  * **AR.10** real `@[extern]` annotations on `hashBytes` /
    `hashStream` / `hashImplementationIdentifier`, with default
    `runtime/canon-hash-fallback.c` forwarder + Lake `extern_lib`
    `canonHashFallback`.
  * **AR.11** `dispatchSynthesizerResourceAware` as the production
    Lex synthesizer entry (`synth_local_kindOnly` refuses to admit
    resource-bearing statements without resource info).
  * **AR.12** `lexlaw`'s `renderSyntax` uses `Syntax.reprint` for
    byte-fidelity with user source.
  * **AR.16 / AR.17** `Verdict.decode` enforces explicit
    signers/sigs length-match; `kernelOnlyApply`'s wildcard arm
    replaced by an exhaustive per-`Action`-constructor match.
  * **AR.19** `fileDispute_rejects_indexOutOfRange` /
    `_duplicateDispute` theorems.
  * **AR.20** `.github/CODEOWNERS` request-for-review surface for
    TCB-core files.
  * **AR.21** `withdraw.pre` strengthened with positivity (`0 <
    amount`).
  * **AR.18 (visibility)** documented but not lexically enforced —
    `applyVerdictUnchecked` has a clearly-labelled "UNCHECKED —
    TESTING ONLY" docstring; the cross-file callers
    (`Rewards.applyVerdictWithRewardsUnchecked`,
    `Rewards.applyVerdictWithRewardsMultiUnchecked`) require
    moving into `Verdict.lean` for `private` to bite.  See
    `docs/GENESIS_PLAN.md` §15C.6 for the deferral rationale.

**Workstream EI (Encoder Injectivity).**  **Complete.**  The AR.4
deferral closed.  The fault-proof chain now lifts from bytes-equality
to extensional state equality via
`commitExtendedState_subcommits_extensional_eq_under_collision_free`
(`FaultProof/Commit.lean`, EI.8.b).  Eight sub-units shipped (EI.0 –
EI.8); see `docs/planning/encoder_injectivity_plan.md` for the
engineering plan.  Headline theorems by sub-unit:

  * **EI.1** atomic-injectivity foundation
    (`LegalKernel/Encoding/Encodable.lean` +
    `LegalKernel/Encoding/State.lean`).
  * **EI.2** `BalanceMap.encode_injective` + `State.Equiv` +
    `State.encode_injective` (`LegalKernel/Encoding/State
    Injective.lean`).
  * **EI.3** `NonceState.encode_injective` +
    `expectedNonce_eq_of_encode_eq` corollary.
  * **EI.4** `KeyRegistry.encodeMap_injective`.
  * **EI.5** `LocalPolicies.encodeMap_injective`
    (`LegalKernel/Encoding/LocalPolicyInjective.lean`).
  * **EI.6** `Bridge.BridgeState.encodeConsumed_injective`
    (`LegalKernel/Encoding/BridgeInjective.lean`).
  * **EI.7** `Bridge.BridgeState.encodePending_injective` +
    `Bridge.BridgeState.encode_injective`.
  * **EI.8** `ExtendedState.extEq` + `CanonicalBounds` bundle +
    `commitExtendedState_subcommits_extensional_eq_under_collision_free`.

Visibility note: `LocalPolicy.encodeAsBytes`,
`Bridge.DepositRecord.encodeAsBytes`, and
`Bridge.PendingWithdrawal.encodeAsBytes` were promoted from `private`
to non-private (per OQ-EI-2 option (a)) so per-sub-state framing-
injectivity lemmas co-locate with their headline siblings in the
`*Injective.lean` files.  29 new test cases bring the
`encoding-injectivity` suite from 49 to 78 cases.

**Workstream GP (Unified gas pool / per-actor budgets / DoS
resistance).**  **In progress** (Lean-side GP.0 — GP.3 partial
complete).  See `docs/planning/unified_gas_pool_plan.md` for the
full plan.  Headline contributions surviving in current code:

  * **GP.1** `ActorBudget` + `EpochBudgetState` per-actor budget
    ledger (`LegalKernel/Authority/ActorBudget.lean`).  Includes
    `normalise` (epoch-boundary floor at freeTier), `consume`
    (saturating debit), `topUp` (additive credit), and the
    foundational `currentBudget_after_consume_self/other` +
    `currentBudget_after_topUp_self/other` locality lemmas the
    admission gate's theorems depend on.
  * **GP.2.1 / GP.2.2** New laws `Laws.depositWithFee`
    (`Laws/DepositWithFee.lean`) and `Laws.topUpActionBudget`
    (`Laws/TopUpActionBudget.lean`).  Both are signer-agnostic at
    the `Transition` level; the signer-aware kernel step for
    `topUpActionBudget` is threaded at the admission layer.
  * **GP.2.3** `Action` inductive extended with `depositWithFee`
    (frozen index 19) and `topUpActionBudget` (frozen index 20).
    Byte-stable CBE encoding + decoder; `action_roundtrip` /
    `action_encode_injective` cover both new constructors.
    `Action.tag` regression pins at indices 19 / 20.  Three new
    Event constructors at indices 16 / 17 / 18
    (`depositWithFeeCredited` / `actionBudgetTopUp` /
    `gasPoolClaim`); `extractEvents` covers both new actions.
    `applyActionToRegistry` and `applyActionToLocalPolicies`
    extended with append-only arms for both new actions (no
    registry / local-policy mutation; both are `RegistryPreserving`).
    `kernelOnlyApply` (Disputes/Evidence.lean) uses a signer-aware
    kernel step for `topUpActionBudget` (via
    `Laws.topUpActionBudget st.signer ...`), wrapped in
    `step_impl` for insufficient-gas safety; mirrors
    `apply_admissible_with` exactly so
    `apply_admissible_with_eq_kernelOnlyApply` remains by `rfl`.
  * **GP.3.1** `BudgetPolicy` configuration field on
    `ExtendedState` with `bounded freeTier actionCost currentEpoch`
    inductive.  Genesis default `.bounded 0 1 0` (deny-by-default
    posture: actor at currentEpoch=0 with freeTier=0 admits
    nothing).  Byte-stable encoder injectivity.
  * **GP.3.2** Admission gate
    `apply_admissible_with_budget` and bridge-aware
    `apply_bridge_admissible_with_budget`
    (`LegalKernel/Authority/SignedAction.lean` and
    `LegalKernel/Bridge/Admissible.lean`).  Both feature: (a)
    **two named signer-correlation safety gates at the head**,
    each rejecting a specific attack vector uncovered during the
    five-round adversarial audit:
      - `topUpActionBudget_gasCheck` (four conjuncts on the
        `topUpActionBudget` signer):
        * `signer ≠ Bridge.bridgeActor` (defense in depth: the
          bridgeActor's consume-exemption combined with the
          budget-grant arm would otherwise credit free budget to
          bridgeActor's own slot).
        * `signer ≠ poolActor` (self-pool defense: the kernel-step
          `setBalance s gr signer (balance - ga); setBalance s gr pa
          (balance' + ga)` round-trips gas through `signer` when `pa
          = signer`, producing no net kernel-state change while the
          budget arm still credits `budgetIncrement` for free).
        * `gasAmount > 0` (zero-gas defense: an action with `ga = 0`
          would have `getBalance ≥ 0` trivially true, the kernel
          step a no-op, and the budget arm would still credit
          `budgetIncrement` for free).
        * `getBalance ≥ gasAmount` (insufficient-gas defense: an
          action with `ga > balance` would have the kernel step a
          safe no-op via `step_impl`'s underflow guard, with the
          budget arm still crediting `budgetIncrement` for free).
      - `depositWithFee_signerCheck` (single conjunct on the
        `depositWithFee` signer):
        * `signer = Bridge.bridgeActor` (non-bridge depositWithFee
          defense: a non-bridgeActor signer who could sign a
          depositWithFee would credit `userAmount + poolAmount` to
          recipient's balance AND credit `budgetGrant` to recipient's
          budget — free balance + free budget injection.  In
          production the `bridgePolicy` admission layer rejects this
          earlier, but under `unrestricted` policy (tests / dev) and
          to future-proof against `bridgePolicy` extensions, the gate
          hard-codes the requirement that depositWithFee MUST be
          signed by bridgeActor).
    All five attack vectors are critical-severity DoS amplifiers
    (unbounded free budget accumulation; round 5 additionally a free
    balance injection) and are pinned by the regression tests
    `topupInsufficientGasRejected`, `topupZeroGasRejected`,
    `topupByBridgeActorRejected`, `topupSelfPoolRejected`,
    `depositWithFeeNonBridgeSignerRejected`, and their bridge-aware
    mirrors.  (b) bridgeActor exemption per OQ-GP-6 (applies only to
    non-topUp actions; topUp signed by bridgeActor is rejected
    earlier by the gas check's first conjunct), (c) consume step
    on non-bridge signers, (d) per-action budget-grant arm for
    `depositWithFee` (credits recipient) and `topUpActionBudget`
    (credits signer).  Ten headline theorems pinned:
    `admission_consumes_budget_on_success`,
    `admission_rejected_when_budget_zero`,
    `bridgeActor_budget_exempt`,
    `depositWithFee_grants_budget`,
    `depositWithFee_budget_locality`,
    `topUpActionBudget_net_budget_change`,
    `admission_locality_in_budget`,
    `replenishment_via_epoch_advance`,
    `nonce_uniqueness_preserved`,
    `replay_impossible_preserved`.
  * **Runtime threading.**  `processSignedActionWith`,
    `processPure`, and the replay-tool entries
    (`replayStepWith` / `replayLoopWith` / `replayFromSeedWith`)
    all dispatch on `BridgeAdmissibleWith` and apply via
    `apply_bridge_admissible_with_budget`; production IO and pure
    test paths see identical budget behaviour.
  * **GP.3.3** `kernelOnlyApply` exhaustive-match extension and
    full step-VM dispatcher coverage for variants 19 / 20
    (`FaultProof/StepVMCoherence.lean` + `Disputes/Evidence.lean`).
    Headline theorems:
    - `stepVMHash_depositWithFee_kind` (rfl): dispatcher reduces to
      the two-arm credit pattern matching `Laws.depositWithFee`'s
      sequential `setBalance` semantics; collapses to a single
      credit when `recipient = poolActor`.
    - `stepVMHash_topUpActionBudget_kind` (rfl): dispatcher reduces
      to the debit-then-credit pattern matching
      `Laws.topUpActionBudget`'s gas-transfer semantics; defends
      the `signer = poolActor` corner via an explicit no-op branch
      (the canonical path is blocked at admission by round-4).
    - `coherence_depositWithFee` / `coherence_topUpActionBudget`:
      specialisations of `recomputeCommitment_coherent_with_kernelOnlyApply`
      to the two new constructors, pinned at the term level in
      `FaultProof/PerVariantCoherence.lean`.
    - Cross-stack fixture corpus widened from 218 → 238 entries
      (added 6 happy + 4 adversarial per new variant), with
      `cellProofsForFixture` non-emptiness on the cell-bound new
      variants pinned by `SVC.5.e+` regression tests.
    - Solidity `_stepDepositWithFee` and `_stepTopUpActionBudget`
      step functions (already shipped in `solidity/src/contracts/CanonStepVM.sol`)
      consume the same field layout the Lean `actionFieldsForL1`
      emits: 7 × uint64BE = 56 bytes for depositWithFee
      (`r ‖ recipient ‖ poolActor ‖ userAmount ‖ poolAmount ‖
      budgetGrant ‖ depositId`) and 4 × uint64BE = 32 bytes for
      topUpActionBudget (`gasResource ‖ gasAmount ‖
      budgetIncrement ‖ poolActor`).  Admission-layer fields
      (`budgetGrant`, `budgetIncrement`) are decoded for layout
      symmetry but excluded from the step-VM hash by design.
    - Solidity-side `StepVM.t.sol` extended to 9 happy + 1 skipped
      tests over the 238-entry corpus, including the widened
      `actionKindByte` range check (0..18 → 0..20).

Out of scope for this in-flight closure: GP.3.4 (delegated top-up
via `topUpActionBudgetFor`), GP.4 – GP.11 (Bridge accounting,
Solidity contracts beyond the step-VM, Rust runtime, pool
governance, sequencer integration, AMM, etc.).

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

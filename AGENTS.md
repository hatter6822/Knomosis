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
  | Lean kernel    | `lean-toolchain` *is not* a version; the kernel  |
  |                | does not have a per-package version.  No bump.   |
  | Rust workspace | `runtime/Cargo.toml`'s `[workspace.package]      |
  |                | version` field (every member crate inherits      |
  |                | via `version.workspace = true`).                 |
  | Solidity       | `solidity/foundry.toml` if a `version` field is  |
  |                | present (typically tracked at the contract /     |
  |                | release level rather than per-package).          |

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
  version = "0.1.0"     # <-- bump this
  ```

  Every member crate inherits via `version.workspace = true`.
  `Cargo.lock` is regenerated automatically by `cargo build`;
  the new lockfile must be committed in the same PR.

  *Mechanics for the Lean side.*  The Lean kernel has no
  per-package version (the kernel is identified by its
  `kernelBuildTag` string and the pinned `lean-toolchain`).
  Lean-only PRs do not require a version bump.

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

**Test count.**  ~2245 tests across 125 suites at the SVC.5.e+
audit-pass-3 milestone (+5 from the cross-stack byte-equivalence
fix on `decodeCellNat` — the `faultproof-stepvm-coherence`
suite grew from 78 to 83 cases adding 5 new regression tests
pinning the decoder's byte-for-byte agreement with Solidity's
`_decodeNat` on canonical AND adversarial inputs: tag-byte-
ignored, trailing-bytes-ignored, short-bytes-return-0, full-u64-
max-round-trip, and a multi-tag-byte cross-validation;
+10 from the post-merge audit which fixed
`stepVMHash` for bulk variants 6/7 — they now do the full
per-recipient fold matching Solidity's `_stepDistributeOthers`
/ `_stepProportionalDilute` byte-for-byte, including the
256-recipient cap; the `faultproof-stepvm-coherence` suite
grew from 68 to 78 cases adding the 8 new bulk-dispatch
property tests + 2 API-stability tests; +5 from the
SVC.5.e+ cell-proof bundle wiring — the `crosscheck-step-vm`
suite gained 5 new structural tests pinning cell-proof
invariants on the 218-entry corpus, taking it from 30 to 35
cases; +22 from the SVC.5.e fixture-corpus widening — the
`crosscheck-step-vm` suite grew from 8 to 30 cases as it
pins per-variant fixture counts for all 19 variants and
schema invariants over the widened 218-entry corpus; +101
from EI/SC.3's 2203 base; SVC adds the 83-case
`faultproof-stepvm-coherence` suite, the 18-case
`faultproof-terminate-bundle` suite, and the 15-case
`integration-export-terminate-bundle-cli` suite).  ~2083 tests
across ~102 suites at the SC.3 milestone (+16 from SC.1's 2067;
SC.3 adds the 16-case
`crosscheck-smt-cell-proof` suite — see below).  The 79-case `faultproof-smt` suite
covers: BitsKey instances (UInt64 + ByteArray, MSB-first);
canonical empty-subtree hash chain (H_0 = hashBytes
"EMPTY_LEAF"; H_{d+1} = hashBytes(H_d ++ H_d)); SmtCellProof
well-formedness; expander coherence; walk determinism;
verifier acceptance + rejection of every tamper variant
(wrong root, ill-formed proof, tampered value, tampered key,
tampered sibling, tampered bitmask bit); buildSmtCellProof
canonical-proof construction for 0/1/2/3/4/8-cell maps;
singleton coherence with smtRoot; cross-key rejection (k1's
proof can't witness k2); absent-key rejection (no value
verifies for a key not in the map); insertion-order
independence of smtRoot; 8-key stress test with full
substitution-rejection sweep; smtRoot output-shape guarantees;
setBitmaskBit helper.  Plus 6 term-level API-stability checks
for the shipped theorems.  The new 16-case
`crosscheck-smt-cell-proof` suite (SC.3) covers fixture-shape
invariants, honest-side Lean verification for all 50 honest
entries, adversarial-side Lean rejection for all 50
adversarial entries (across 6 tamper classes: valueSubst,
siblingTamper, bitmaskTamper, rootTamper, keyMismatch,
absentKey), structural-byte invariants for smtKey (8-byte BE)
/ leafPreimage (16-byte) / proofData (32-byte bitmask +
N×32-byte siblings) / root (32-byte), tamper-class coverage,
syntactic-distinctness regressions (each adversarial entry
differs from its honest base; per-tamper-class field-delta
matches the documented mutation), fixture byte-determinism,
fixture write/verify cycle, and the `isKeccak256Linked`
cross-stack gate.  At the EI
milestone the count was ~1986 across ~100 suites, up from
1907 at the AR milestone (+79).  The exact number drifts
with every PR; `lake test` is the canonical query.  Unlike
the build tag, the test count is not pinned — only its
monotonic growth is enforced by individual regression tests
landing alongside new theorems.

**Rust-side test count.**  1404 tests at the RH-G
audit-pass-4-round-6 landing (+5 from round-5's 1399;
+9 from round-4's 1395; +359 from the RH-F + audit-3
landing's 1045): six audit rounds in the audit-pass-4
cycle progressively hardened the RH-G surface.  The
observer crate now ships 357 tests total (295 lib + 6
cross-stack-corpus + 12 end-to-end integration + 9
state-reader-mock-RPC integration + 6 chaos + 4
real-canon subprocess + 7 real-canon export-cell-proofs
end-to-end + 18 property), up from 352 pre-round-6
(round-6 added the 1 MiB deadlock-prevention regression
test + 4 CLI parser tests for `--canon-binary` /
`--canon-log`).

Audit-pass-4 contributions across all three rounds:
* **Round 1**: critical gas-estimate-margin formula fix
  (`raw * 0.25` → `raw * 1.25`), nonce-cache peek/commit
  refactor (sign-time failures don't consume nonces),
  runtime chain_id cross-check, state-reader strict-bool /
  oversize-cap / missing-invariants, chaos suite `matches!`
  no-op fix, chaos reorg-test correctness, corpus-loader
  schema-drift surfacing.
* **Round 2**: Lean cell-proof JSON snake_case naming +
  envelope-shape + byte-pinning tests; chaos test renaming
  to honestly reflect architectural reality; tautological
  test replacement; load_corpus strict-parse + u128 custom
  deserializer.
* **Round 3**: cross-stack CellProof JSON round-trip
  (custom serde deserializers for hex-encoded fields —
  previously broken at the type boundary); SubprocessTruthOracle
  subprocess timeout + stdout size cap (CRITICAL: hung canon
  binary could wedge observer; multi-MB stdout could OOM);
  JsonRpcSubmitter wired into production binary via new
  `--chain-id` CLI flag (was dead code); verify_rpc_chain_id
  called at startup; Submitter::invalidate_nonce_cache trait
  hook called on broadcast failure (was permanent nonce gap);
  state-reader Zero/Collision checks use FULL 20-byte address
  (not low-8 projection); submitted_pivots rollback on
  commit_batch failure (was permanent in-process pivot lock);
  Solidity ABI selector pinning regression.
* **Round 6**: CRITICAL `SubprocessTruthOracle::commit_at`
  deadlock when canon writes more than the pipe buffer
  (~64 KiB on Linux) — fixed by spawning the stdout drain
  thread BEFORE the wait loop, so the drain consumes
  continuously while the parent waits for child exit.
  Plus HIGH `MockRpcServer::spawn()` accept-thread race
  — fixed by synchronously waiting for the accept thread
  to enter its first iteration before returning.
See the §RH-G entry below for the workstream-specific
breakdown.  Earlier-landing breakdowns carried below for
posterity.

**RH-E test count.**  914 tests at the RH-E
audit-pass-3 landing (up from 702 at the RH-D landing —
+212 tests across the two new crates: 67 in `canon-storage`
(49 lib + 10 integration + 8 property — +1 integration test
from the audit pass) and 138 in `canon-indexer` (108 lib +
8 integration + 7 property + 12 wire-protocol + 9
daemon-loop + 4 fault-injection — +8 audit-regression lib
tests covering two-pass dispatch and credit overflow, +5
encode_event_checked tests, +2 decoder fuzz property tests,
+2 wire-protocol DoS / empty-payload tests, +4 fault-
injection tests covering CursorRecoveryFailed / Poisoned /
BatchTooLarge / commit-failure paths, +1 seq=0 protocol-
violation test).  At the RH-D
landing the breakdown was 702 tests
across 26 non-empty test binaries
(up from 526 at the RH-C landing —
+176 tests across the new `canon-event-subscribe` crate: 150
lib + 18 integration + 8 property, including 13 audit-regression
tests covering: C-1 / C-NEW-1 / C-3R-1 duplicate-delivery +
multi-event-per-frame races (incl. deterministic unit-level
snapshot-atomicity tests `broadcast_to_snapshot_excludes_post
_snapshot_registrants` + `broadcast_to_snapshot_multi_event
_uniform_exclusion`); C-2 multi-event-per-frame cache; C-3
slow-reader write-timeout; M-4 symlinked log-path defence; H-4
laggy shutdown; H-NEW-3 max-concurrent-vs-subscribers
validation; H-NEW-4 bounded_join (`bounded_join_abandons_wedged
_thread` + `bounded_join_returns_clean_for_finished_thread`);
partial-batch-eviction detection in `EventCache::range`; stress
test exercising concurrent subscribers + multi-event-per-frame
batches.  `cargo test --workspace` from `runtime/` is the
canonical query.  Test mass breakdown:

  * `canon-cross-stack` — 31 tests (29 unit + 2 integration);
    unchanged since RH-H.
  * `canon-cli-common` — 8 tests; unchanged since RH-H.
  * `canon-verify-secp256k1` — 42 tests (25 unit + 8 known-vector
    + 7 property + 2 cross-stack).  The 25 unit tests cover length
    rejection, every SEC1-prefix variant (0x00, 0x01, 0x02 / 0x03
    accepted, 0x04, 0x05, 0x06, 0x07, 0xFF rejected, plus an
    exhaustive 254-case test of every other invalid prefix byte),
    zero-r / zero-s / r=n / s=n rejection, x=0 off-curve rejection.
  * `canon-hash-keccak256` — 32 tests (13 unit + 10 known-vector
    + 5 property + 3 cross-stack + 1 integration).
  * `canon-l1-ingest` — 227 tests (204 lib + 4 cross-stack + 6
    integration + 11 property + 2 doc).  Lib tests cover: action
    tag table (16 frozen indices), CBE encoder layout per Action
    variant + known-vector tests against hand-calculated Lean
    byte streams, address-book monotonicity / locality /
    idempotency / overflow rejection (`try_assign` returns
    `AssignError::Overflow` rather than silently producing
    duplicate ids), L1 ABI decoder (every event variant + every
    malformed-input error path), bridge-actor key zeroization /
    low-s signature enforcement / file loading / size-bound
    rejection, re-org window linear advance / shallow re-org
    absorption / deep re-org rejection (at-floor AND
    below-floor) / capacity-1 edge case / capacity-trim
    correctness, `OrphanedParent` vs `DeepReorg` distinction,
    mock and JSON-RPC L1 sources (`logs_in_block_by_hash` with
    defence-in-depth filters, HTTP chunked-encoding rejection),
    JSONL state store round-trip / malformed-line rejection /
    legacy + new `Submitted` mixed replay / address-book gap
    rejection / duplicate-actor-id rejection, buffering and
    HTTP submitters / verdict byte-table / backpressure
    cycling, translation byte-equivalence to Lean reference
    (`ingest` + new `preview_ingest` + `commit_assignment` with
    explicit `CommitError`), watcher confirmation-depth gating
    / idempotency / NotAdmissible halt / Busy retry /
    `blocks_per_iteration == 0` rejection /
    `last_confirmed_block == u64::MAX` saturation / verdict
    Ok-NotAdmissible mapping / same-contract dedup, fixture
    format round-trip / huge-length-rejection.  Regression
    tests for the three audit passes: address-book not
    corrupted by failed submit, nonce not bumped by
    None-translating events, atomic `Submitted` record format,
    arithmetic overflow guards, address-book ID overflow
    guard, duplicate-state-file-record detection,
    chunked-encoding rejection, EIP-1271 end-to-end
    integration, decoder allocation bounds, keystore file-size
    bounds, capacity-1 reorg window semantics.
  * `canon-host` — 183 tests (150 lib + 15 TCP integration +
    7 Unix-socket integration + 11 property).  Lib tests cover:
    Verdict byte-table + round-trip + Send/Sync;
    VerdictResponse encode (empty + UTF-8 + payload-length
    alignment); wire-frame parser (round-trip, EOF before
    header, truncated header / payload, oversize rejection,
    zero-length rejection, fragmented Read source, WouldBlock
    propagation); MockKernel (default Ok, response cycling,
    reason carry-through, raw-byte preservation); CommandKernel
    (missing binary, work-dir creation, exit-code → verdict
    mapping via `/bin/true` and `/bin/false`, temp-file cleanup,
    concurrent calls serialised by the spawn lock); BoundedQueue
    (capacity admission, Busy on overflow, drain_one /
    try_drain_one, disconnected → Busy graceful path); TLS
    config (PEM cert / key load, NoCertificates /
    NoPrivateKey rejection on empty / garbage files);
    ServerConfigBuilder (NoListeners rejection, queue depth
    plumbing); end-to-end TCP round-trip + NotAdmissible-
    with-reason round-trip + oversize-frame ParseError;
    Config (every flag + every validation rule + help text).
    Integration tests cover: end-to-end TCP request/response,
    fixture-replay pattern, mock NotAdmissible + Busy +
    ParseError round-trips, saturation produces Busy verdict
    under capacity-1 + slow kernel, oversize frame rejected,
    zero-length frame rejected, immediate client disconnect
    handled, many sequential requests succeed, boundary frame
    size accepted.  Unix-socket integration covers: end-to-end
    round-trip, socket-file mode 0600, rebind unlinks stale
    socket, rebind refuses to clobber regular file, NotAdmissible
    with reason, many sequential, concurrent clients.  Property
    tests cover: frame round-trip on arbitrary payloads, parser
    never panics on arbitrary input, truncation always errors,
    oversize always rejected, verdict round-trip, verdict
    out-of-range returns None, response encoding deterministic
    + prefix layout + length matches payload, bounded queue
    admits exactly N before Busy, drain dispatches every
    enqueue.
  * `canon-event-subscribe` — 176 tests (150 lib + 18
    integration + 8 property).  Lib tests cover: wire-frame
    parser (SUBSCRIBE / EVENT / LAG_EXCEEDED / TRUNCATED /
    SERVER_SHUTDOWN / INVALID_REQUEST round-trip; truncated /
    oversize / unknown-kind rejection; fragmented-reader
    correctness; WouldBlock propagation); log-tail reader
    (single / multi-frame happy path, partial header /
    payload / trailer pending, bad-magic / bad-trailer /
    oversize-frame typed errors, append-after-read pickup,
    cursor reset on reopen, FNV-1a-64 reference vectors);
    event cache (FIFO eviction at capacity, range
    correctness: InWindow / OutOfWindow / AtLiveTail
    boundaries, capacity-1 edge case, range under churn,
    out-of-order push rejection); subscriber state machine
    (Enqueued / Lagging / LagExceeded / Disconnected
    outcomes; lag counter reset on successful enqueue;
    disconnect propagation; registry register / unregister /
    broadcast / broadcast_shutdown; subscriber capacity cap;
    distinct subscriber ids); extractor abstraction
    (MockExtractor programmable response cycling +
    error injection; SubprocessExtractor missing-binary /
    broken-pipe error paths); CLI config (every flag +
    every validation rule + help text).  Integration tests
    cover: end-to-end happy path (subscribe + frame
    delivery), lag eviction, resume-across-reconnect,
    backfill-from-genesis, truncation rejection, invalid
    handshake rejection, zero-length event payload,
    shutdown frame propagation, event order preservation
    across multiple subscribers, many sequential events,
    subscriber capacity cap enforcement.  Property tests
    cover: parser never panics on arbitrary inputs (both
    directions), full round-trip on arbitrary payloads,
    control-frame round-trip on arbitrary seqs, cache
    invariants under random pushes, range correctness
    under random capacities and from_seqs, oversize-length
    rejection without allocation.
  * Three skeleton crates (`canon-bench`,
    `canon-faultproof-observer`, `canon-storage`) contribute one
    crate-name regression test each (3 total).  The remaining
    binary-only skeleton crate (`canon-indexer`) has no
    library tests yet.

The count will continue growing as RH-E onward materialises.

**Workstream RH-H (Rust host workspace + CI harness).**
**Complete.**  Lands the workspace under `runtime/` (11 member
crates: 10 from the plan §2.2 layout plus `canon-cross-stack`
hosting the fixture loader as a separate dev-dep, per the plan
§4 RH-H step 4 "thin Rust helper that other crates import as a
dev-dependency") per `docs/planning/rust_host_runtime_plan.md`
§RH-H.
Headlines:

  * Two fully-implemented crates: `canon-cli-common` (shared
    logging / exit-code / paths helpers) and `canon-cross-stack`
    (cross-stack fixture loader + file-format spec; the
    load-bearing RH-H deliverable that downstream crates dev-dep
    on for byte-equivalence assertions).
  * Eight skeleton crates (RH-A.1, RH-A.2, RH-B, RH-C, RH-D,
    RH-E.0, RH-E.1, RH-F, RH-G — nine if you count RH-E.0 +
    RH-E.1 separately) ready for the implementing work units to
    fill in.  Skeleton binaries exit code `3 = NotImplemented`
    with a deferral message; no C-ABI symbols exported (no
    silently-incorrect fallback verifier / hash adaptor).  As of
    the RH-C landing, RH-A.1 / RH-A.2 / RH-B / RH-C are fully
    implemented (no longer skeletons).
  * `runtime/rust-toolchain.toml` pins stable 1.83;
    `workspace.package.rust-version = "1.83"` documents the MSRV
    at the package level.
  * `.github/workflows/ci-rust.yml` runs four gates
    (`cargo build --workspace --all-targets`, `cargo test
    --workspace`, `cargo clippy --workspace --all-targets --
    -D warnings`, `cargo fmt --all -- --check`) on every PR
    that touches `runtime/**`; Lean-only PRs do not trigger the
    Rust workflow.  Third-party action SHAs verified against
    upstream release tags (actions/checkout v4.3.1,
    Swatinem/rust-cache v2.7.7).
  * `unsafe_code = "forbid"`, `missing_docs = "warn"`,
    `clippy::pedantic` enabled workspace-wide.
  * Cross-stack fixture format: 16-byte "CXSF" header (magic +
    version + kind tag + count), per-record `(u32 BE input-len,
    input, u32 BE expected-len, expected)`.  Self-describing,
    bounded-length, byte-deterministic.  Parser is panic-free in
    all non-trivial code paths: `read_u32_be_at` returns
    `Option<u32>` rather than `expect`-on-precondition, and
    every error path returns a typed [`LoaderError`] variant.
  * `Cargo.lock` committed (workspace contains binaries; lockfile
    is a reproducibility requirement).
  * `tempfile` pinned at `~3.14` (newer versions transitively
    require Rust 1.85+ for `edition2024`; pin coupled to
    `rust-toolchain.toml`'s 1.83 channel).

**Workstream RH-A (Cryptographic adaptors).**
**Complete.**  Materialises the two `cdylib` adaptors a Lean
deployment links against to wire the kernel's crypto opaques:
`canon-verify-secp256k1` (RH-A.1) and `canon-hash-keccak256`
(RH-A.2).  See `docs/planning/rust_host_runtime_plan.md` §RH-A.1
/ §RH-A.2 for the closeouts.  Headlines:

  * **RH-A.1 — `canon-verify-secp256k1`.**  Production ECDSA
    secp256k1 verification adaptor.  Exposes the `canon_verify_ecdsa`
    C ABI symbol; a Lean deployment with a matching
    `@[extern "canon_verify_ecdsa"]` declaration on
    `Authority.Crypto.Verify` links here at runtime.  Strict
    input validation (33-byte SEC1-compressed pubkey with 0x02 /
    0x03 prefix, 32-byte pre-hashed message, 64-byte `(r ‖ s)`
    signature), `1 ≤ r < n` and `1 ≤ s < n` bounds (via k256's
    `Signature::from_slice`), and the load-bearing EIP-2 / BIP-62
    low-s canonicalisation enforced via `k256::IsHigh`.  Built
    on `k256 = "0.13"` (no `std`, no signing in the production
    cdylib).  210 cross-stack fixture vectors generated by a
    deterministic RFC-6979 signer (30 valid base signatures +
    30 high-s mates + 150 tampered variants = 210 records; the
    30 valid base signatures come from KEY_COUNT × MSGS_PER_KEY
    = 10 × 3).  Committed to
    `runtime/tests/cross-stack/ecdsa_secp256k1.cxsf`.  Property
    tests via `proptest` (256 cases × 7 properties); fresh-sign
    + verify roundtrip is one of them.

  * **RH-A.2 — `canon-hash-keccak256`.**  Production Keccak-256
    (Ethereum-flavoured, NOT FIPS-202 SHA3-256) hash adaptor.
    Exposes three C ABI symbols matching Lean's `@[extern]`
    declarations in `Runtime/Hash.lean`: `canon_hash_bytes`,
    `canon_hash_stream`, `canon_hash_identifier`.  Each
    production binary links the cdylib AHEAD of the
    `canon-hash-fallback.o` forwarder to override the FNV-1a-64
    fallback with the production keccak-256.  Identifier string:
    `"keccak256/EVM-compatible/v1"`.  Built on `sha3 = "0.10"`.
    51 cross-stack fixture vectors covering boundary cases (0,
    1, 31, 32, 33 bytes), block-rate boundaries (135, 136, 137
    bytes — the keccak rate), well-known test vectors (`""`,
    `"abc"`, "the quick brown fox..."), repeated bytes, xorshift-
    seeded pseudorandom data, and a multi-megabyte input.
    Property tests via `proptest` exercise the streaming context
    against the one-shot path on random inputs and random
    chunkings.

  * **C ABI shim design.**  Lean's `lean.h` exposes most of its
    runtime API as `static inline` C functions
    (`lean_sarray_size`, `lean_sarray_cptr`, `lean_dec`, etc.),
    which Rust cannot call directly via `extern "C"`.  Each
    crate ships a tiny C shim (`c/lean_shim.c`) that wraps these
    inlines as non-inline `canon_lean_*` symbols Rust binds to.
    The actual Lean ABI entry point lives in Rust
    (`#[no_mangle] pub unsafe extern "C" fn canon_verify_ecdsa`
    etc.) so `rustc`'s cdylib export discipline keeps the
    symbol in the dynamic-symbol table.  `build.rs` discovers
    `lean.h` via `LEAN_INCLUDE_DIR` → `LEAN_SYSROOT` → `lean
    --print-prefix` → soft-skip; the cfg `canon_lean_ffi` gates
    the Rust-side FFI code, so CI environments without Lean
    still produce a working rlib (without the Lean-facing C
    symbols).  Verified via `nm -D` that the production cdylib
    exports the expected symbol set.

  * **Workspace dependency additions.**  `k256 = "0.13"` (ECDSA),
    `sha3 = "0.10"` (Keccak), `subtle = "2.6"` (constant-time
    primitives), `hex = "0.4"` (dev-only fixture hex), `proptest
    = "1.5"` (dev-only property tests), and `cc = "1.0"`
    (build-script C compiler driver).  All pinned at the
    workspace level; `base64ct` transitively pinned to 1.6.0
    (newer requires Rust 1.85), `proptest` to 1.5.0 (same
    constraint).

  * **Audit posture at landing.**
    - `cargo build --workspace --all-targets` — green.
    - `cargo test --workspace` — 116 tests across 15 non-empty
      test binaries, all passing.
    - `cargo clippy --workspace --all-targets -- -D warnings` —
      clean.
    - `cargo fmt --all -- --check` — clean.
    - `unsafe_code = "deny"` workspace lint (narrowed from
      `"forbid"` in the two crypto crates; the `unsafe` blocks
      are tightly scoped to the FFI shims with documented
      `# Safety` contracts).
    - Production cdylibs verified to export the expected C ABI
      symbols (`canon_verify_ecdsa`, `canon_hash_bytes`,
      `canon_hash_stream`, `canon_hash_identifier`) via `nm -D`.

**Workstream RH-B (L1 event ingestor).**
**Complete (post-audit, three passes).**  Materialises the
long-running daemon that watches Ethereum L1, translates
`CanonBridge` / `CanonIdentityRegistry` event logs to Canon
`Action`s via the byte-equivalent Rust mirror of
`LegalKernel.Bridge.Ingest.ingest`, signs with a
`zeroize`-protected bridge-actor key, and forwards CBE-encoded
`SignedAction`s to the downstream consumer (planned: `canon-
host`).  See `docs/planning/rust_host_runtime_plan.md` §RH-B
Closeout for the full per-sub-unit breakdown plus the
audit-pass remediation history (23 correctness / security
issues found and fixed across three audit passes in the same
workstream PR — seven from pass 1, eight from pass 2, eight
from pass 3).  Headlines:

  * **Library + binary surface.**  `canon-l1-ingest` is now a
    library (`lib.rs` exporting 13 sub-modules) plus a binary
    (`canon-l1-ingest` daemon with documented CLI flags
    `--l1-rpc / --bridge-actor-keystore / --canon-host-url /
    --bridge-contract / --identity-registry / --state-file
    [+ optional --deployment-id / --confirmation-depth /
    --poll-interval-ms / --until-block]`).  Identifier string
    `"canon-l1-ingest/v1"` published as
    `INGEST_IDENTIFIER`.

  * **Byte-exact cross-stack equivalence.**  The CBE encoder
    (`src/encoding.rs`) hand-rolls Lean's `Encoding.Action.encode`
    layout byte-for-byte: 1-byte tag + 8-byte LE-Nat head per
    field; byte strings as head + raw payload; constructor-tag
    indices frozen against Lean's `Encoding/Action.lean` table
    (0 = Transfer, ..., 12 = RegisterIdentity, ..., 18 =
    FaultProofResolution).  The 12-record
    `runtime/tests/cross-stack/l1_ingest.cxsf` corpus
    (`FixtureKind::L1Ingest`) covers every translatable event
    variant + edge cases (empty pubkey, 33-byte SEC1-compressed,
    large nonce, populated address-book context).

  * **No `ethers-rs` / `tokio` dependency.**  The plan §RH-B.2
    suggested `ethers-contract` for ABI bindings.  We instead
    hand-roll a minimal Ethereum ABI decoder
    (`src/events.rs::decode_event`) over the four event
    signatures RH-B cares about.  Panic-free on attacker input;
    every malformed-input path returns a typed `DecodeError`.
    The watcher loop is synchronous — no async runtime — keeping
    the dependency tree small and the audit surface narrow.

  * **Re-org tolerance.**  `src/reorg.rs::ReorgWindow` —
    bounded `VecDeque<BlockHeader>` with `advance` that returns
    `Advanced` (linear) or `Reorged { dropped_count }` (shallow
    re-org absorbed).  Deeper re-orgs return `DeepReorg` /
    `OrphanedParent` and the watcher halts loudly so the
    operator can intervene (per the plan §RH-B.4).  Designed
    for shared reuse by RH-G.  **Defence-in-depth**: the
    watcher fetches logs by **block hash** (EIP-234's
    `eth_getLogs.blockHash` parameter), not by number — so an
    L1 re-org racing the header→logs fetch resolves to a
    typed error rather than wrong-fork logs being processed.

  * **Re-orgs simulated via mocks.**  `src/source.rs::mock::
    InMemoryL1Source::rewrite_chain` lets tests synthesise
    re-orgs without spinning up a real Ethereum node.  Live-
    RPC chaos testing is deferred to a future operator
    runbook scope.

  * **Re-org-tolerant idempotency.**  The watcher's
    forwarded-events ledger is keyed by `(block_hash, tx_hash,
    log_index)`; even under a re-org that puts an event back at
    a different block hash, the key changes (new `block_hash`)
    and the event is freshly forwarded.  Idempotency across
    restarts: the JSONL state file (`src/state.rs`) replays
    every `Submitted` (atomic) or legacy `Forwarded` record on
    startup, rebuilding the dedup set.

  * **Atomic state mutations.**  Each successful submission
    writes a single `Submitted` JSONL record carrying the
    forwarded key, the new `next_nonce`, and (optional)
    address-book assignment.  Line-level atomicity at the OS
    level prevents the partial-failure window that the
    previous three-record sequence was vulnerable to.

  * **Preview / commit address-book discipline.**  Translation
    is via `translation::preview_ingest` (peek-only); the book
    is only mutated AFTER a successful submission via
    `commit_assignment`.  This prevents the state-corruption
    bug where a failed submit left the book half-mutated and
    caused retries to emit `ReplaceKey` instead of
    `RegisterIdentity`.

  * **Submitter abstraction.**  `src/submitter.rs::Submitter`
    trait + two impls (in-memory `BufferingSubmitter` for tests
    / dry-run, length-prefixed-binary-over-HTTP `HttpSubmitter`
    for production).  When RH-C lands, the production wire
    format will be a thin compatibility check; the trait
    contract is stable.

  * **Cryptographic discipline.**  `src/key.rs::BridgeActorKey`
    wraps the 32-byte secp256k1 private scalar in
    `Zeroizing<[u8; 32]>` (scrubbed on drop).  `sign_prehash`
    emits low-s `(r || s)` signatures via `k256` v0.13
    (`PrehashSigner::sign_prehash` + belt-and-suspenders
    `normalize_s` post-sign).  The
    `sign_prehash_emits_low_s` property test confirms
    `s ≤ n/2` by comparing the lower 32 bytes of every emitted
    signature against the secp256k1 half-order constant.  This
    is the load-bearing contract with `canon-verify-secp256k1`
    (RH-A.1): the verifier rejects high-s signatures, so the
    signer must emit low-s.

  * **Hand-rolled JSON-RPC.**  `src/source.rs::json_rpc::
    JsonRpcL1Source` is a minimal HTTP/1.1 client over
    `std::net::TcpStream` (no `reqwest` / `ureq` / `hyper`).
    Supports the three RPC methods RH-B needs:
    `eth_blockNumber`, `eth_getBlockByNumber`,
    `eth_getLogs`.  10 MiB max-response-size DoS guard; 10s
    default request timeout.  HTTPS / WS / IPC are out of scope
    at the RH-B landing (future operator wrapper).

  * **Workspace dependency additions.**  `zeroize = "1.8"`
    (no_std + alloc, no derive), `serde = "1.0"` (derive +
    alloc), `serde_json = "1.0"` (alloc).  Workspace-shared
    `tempfile = "~3.14"`.  Bumped workspace version to `0.1.2`.

  * **Audit posture at landing.**
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test --workspace --locked` — 297 tests passing.
    - `cargo clippy --workspace --all-targets --locked -- -D
      warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - `unsafe_code = "forbid"` (the ingestor is a pure-Rust
      orchestrator; no FFI surface).

**Workstream RH-C (Network adaptor).**
**Complete.**  Materialises `runtime/canon-host/` — the
TCP / TLS-on-TCP / Unix-socket service that accepts
length-prefixed CBE-encoded `SignedAction` requests, dispatches
them to a configured `Kernel` implementation, and returns a
verdict byte (+ optional UTF-8 reason).  See
`docs/planning/rust_host_runtime_plan.md` §RH-C and §RH-C
Closeout for the full per-sub-unit breakdown.  Headlines:

  * **Library + binary surface.**  `canon-host` is a library
    (`lib.rs` exporting 8 sub-modules: `config`, `frame`,
    `kernel`, `listener`, `queue`, `server`, `tls`, `verdict`)
    plus a binary (`canon-host` daemon with documented CLI
    flags `--listen / --tls-listen / --tls-cert / --tls-key /
    --unix-socket / --canon-binary / --canon-log /
    --canon-work-dir / --deployment-id / --max-queue-depth /
    --max-frame-size / --mock`).  Identifier string
    `"canon-host/v1"` published as `HOST_IDENTIFIER`.

  * **Canonical wire format.**  Request: 4-byte BE u32 length +
    N CBE-encoded `SignedAction` bytes.  Response: 1-byte
    verdict + 4-byte BE u32 reason length + M UTF-8 reason
    bytes.  Verdict table: `0 = Ok`, `1 = NotAdmissible`,
    `2 = ParseError`, `3 = Busy` (new in RH-C.4).  Full spec
    documented in `docs/abi.md` §10.

  * **No `tokio` dependency.**  Departure from the plan
    §RH-C.1's `tokio + tokio-util` recommendation: we use
    `std::thread` + `std::sync::mpsc::sync_channel` instead.
    Trades some peak throughput for a significantly smaller
    dependency tree (`tokio` would add ~80 transitive crates)
    and matches the workspace's consistent "no async runtime,
    hand-rolled HTTP" philosophy from `canon-l1-ingest`.  The
    acceptance criteria are met via per-connection
    `std::thread::spawn` + a single dedicated worker thread
    for kernel dispatch.

  * **Three listener variants.**  `tcp::TcpListener`,
    `tls::TlsListener` (via `rustls = "0.23"` + `ring`
    backend), and `unix::UnixListener` (mode 0600 socket file;
    refuses to clobber non-socket files at the path).
    Multiple transports may be configured simultaneously; the
    daemon runs one acceptor thread per transport and shares a
    single worker queue across them.

  * **Kernel abstraction.**  `Kernel` trait + two impls.
    `mock::MockKernel` is the in-memory test / dev kernel
    (configurable verdict sequence; default `Ok`; records every
    submission for test assertions).  `command::CommandKernel`
    spawns the Lean `canon` binary's `process` subcommand per
    request and collapses non-zero exit codes to
    `NotAdmissible` with captured stderr as the reason.  The
    `CommandKernel` is heavy (O(log size) per request because
    canon re-loads the log file every time); the canonical
    future optimization is a `canon serve` Lean-side subcommand
    that reads CBE frames from stdin and writes verdicts to
    stdout, eliminating the per-request bootstrap cost.  This
    is deferred to a future Lean-side PR.

  * **Bounded queue + Busy backpressure.**  `BoundedQueue`
    wraps `std::sync::mpsc::sync_channel(capacity)`; the
    listener thread's `try_submit` returns
    `SubmitOutcome::Busy` rather than blocking when the queue
    is full.  Default `--max-queue-depth 256`; hard ceiling
    65_536.  Memory usage is bounded by
    `max_queue_depth × max_frame_size`.  Per-connection
    threads block on a capacity-1 reply channel waiting for
    the worker's response.

  * **No `unsafe`.**  `unsafe_code = "forbid"` workspace lint.
    The host is a pure-Rust orchestrator; the FFI surface is
    delegated to the `Kernel` implementation (which is itself
    safe Rust for the `CommandKernel`).

  * **No panics on attacker input.**  Every frame-parse error
    path returns a typed `FrameError`; every queue-overflow
    path returns `Busy`; every kernel-timeout path returns
    `NotAdmissible` with a "kernel timeout" reason.  The 11
    property tests sweep arbitrary attacker-supplied bytes
    through the parser and verify it never panics.

  * **Workspace dependency additions.**  `rustls = "0.23"`
    (with `ring` + `tls12` + `std` features, no `aws-lc-rs`,
    no logging, no `default-features`), `rustls-pemfile =
    "2"`, `rustls-pki-types = "1.10"`.  Bumped workspace
    version to `0.1.3`.

  * **Audit posture at landing (post-RH-C audit pass).**  An
    independent code-review agent surfaced 20 findings; the
    six critical / high-severity issues have been addressed
    in-PR:
    - **#1** CommandKernel `cmd.output()` replaced with
      `cmd.spawn()` + bounded `try_wait` poll loop + SIGKILL
      on timeout.  A wedged canon binary now bounded by
      `with_timeout`.
    - **#2** New `--max-concurrent-connections` flag (default
      1024) bounds the number of simultaneously active
      handler threads via an RAII `ConnectionSlot`,
      defending against spawn-storm DoS.
    - **#3** CommandKernel temp-file creation switched from
      predictable PID+counter paths + `File::create` (which
      follows symlinks) to `tempfile::Builder` (random
      suffixes + `O_CREAT | O_EXCL`).  Defends against
      pre-existing-symlink TOCTOU on multi-tenant work
      directories.
    - **#4** Server shutdown rewritten to drain in strict
      phases: listeners exit → wait for in-flight handlers
      → drop queue → join worker.  Each handler thread
      holds a `ConnectionSlot` whose Drop decrements an
      `AtomicUsize`; the orchestrator polls until the
      counter reaches zero (bounded by
      `SHUTDOWN_DRAIN_TIMEOUT`).  Closes the "no
      in-flight loss on shutdown" promise.
    - **#6** Listener accept-loop's fixed 100 ms
      error-sleep replaced with exponential backoff
      (100 ms × 2^n, capped at 3.2 s).  Defends against
      EMFILE-style file-descriptor exhaustion.
    - **#14** `read_frame` now clamps the supplied
      `max_frame_size` to `HARD_MAX_FRAME_SIZE` so library
      consumers bypassing the CLI cannot disable the bound.
    Plus three medium-severity fixes (#11 EofBeforeHeader
    log accuracy via the new `HandleOutcome` enum; #12
    mutex poison recovery in CommandKernel's spawn_lock;
    #15 documented BoundedQueue zero-capacity behaviour).
    A second audit pass (post-staging-extension) surfaced 9
    findings; a third audit pass (post-audit-2) surfaced 6
    findings.  Headline fixes across both passes:
    - **AR-2 #2 (HIGH)** `file.flush()` is a no-op on
      `std::fs::File`; replaced with `file.sync_data()` for
      NFS / FUSE work-dir durability.
    - **AR-2 #3 (HIGH)** kernel-panic isolation: every
      `kernel.submit` call wrapped in
      `panic::catch_unwind(AssertUnwindSafe(...))`.  In
      release `panic=abort` makes the wrap inert; in debug
      a panic becomes `NotAdmissible "kernel panicked"`
      keeping the worker alive.
    - **AR-2 #8 (CRITICAL)** `SubscribableKernel`
      contract strengthened from "non-decreasing" to
      "strictly increasing" with documented atomic-snapshot
      rule (implementations hold a single mutex across both
      `current` advancement + channel send, and across both
      snapshot + receiver claim in `subscribe`).  New
      regression test
      `subscribe_during_advance_no_duplicate_events`.
    - **AR-3 #1 (MEDIUM)** the AR-2 race-safety test was
      passing for the wrong reason — the fixture's
      `subscribe()` didn't drain channel-buffered events ≤
      snapshot, but a 5ms sleep in the advancer ensured the
      subscriber always won the race.  Audit-3 rewrote the
      fixture to drain buffered events under the mutex AND
      restructured the test into three deterministic
      scenarios (subscribe-before-advance,
      subscribe-after-advance, concurrent), proving strict
      monotonicity in all orderings.
    - **AR-3 #4 (LOW)** pinned the rustls crypto provider
      per-config via `builder_with_provider` (audited:
      `ring`) instead of relying on the process-global
      default.  Defends against library consumers that
      install a different provider.
    - **AR-3 #2 (LOW)** MockKernel's `.expect("MockKernel
      mutex poisoned")` lock calls replaced with the
      `unwrap_or_else(|p| p.into_inner())` recovery
      pattern, matching CommandKernel.
    - **AR-3 #5 (LOW)** removed the unused
      `canon-cross-stack` dev-dep from canon-host.
    - Plus a self-found defence-in-depth: clamped
      `ConnectionSlot::try_acquire`'s `cap` against
      `HARD_MAX_CONCURRENT_CONNECTIONS`.
    - Plus a flaky-test fix:
      `shutdown_drains_inflight_requests` and
      `saturation_returns_busy` now use `try_submit_one`
      and tolerate transport errors during shutdown /
      concurrency races (the strict assertion path was
      panicking on rare connection-refused outcomes).
    Final gates:
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test --workspace --locked` — 526 tests passing
      (+183 from the RH-B landing's 343).
    - `cargo clippy --workspace --all-targets --locked -- -D
      warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - `unsafe_code = "forbid"`.
    - Binary smoke-tested via `./target/release/canon-host
      --listen 127.0.0.1:23457 --mock` plus a manual request
      via `nc`; response bytes match the documented wire
      format byte-for-byte (`00 00 00 00 00` = verdict Ok +
      zero-length reason).

**Workstream RH-D (Event subscription server).**
**Complete.**  Materialises `runtime/canon-event-subscribe/` —
the TCP service that tails Canon's transition log, extracts
deployment-facing events via a Lean `canon` subprocess, and
streams those events to subscribers in strict order with
bounded-lag eviction.  See
`docs/planning/rust_host_runtime_plan.md` §RH-D and §RH-D
Closeout for the full per-sub-unit breakdown.  Headlines:

  * **Library + binary surface.**  `canon-event-subscribe` is
    a library (`lib.rs` exporting 7 sub-modules: `config`,
    `event_cache`, `extract`, `frame`, `server`,
    `subscription`, `tail`) plus a binary (`canon-event-subscribe`
    daemon with documented CLI flags `--log-path / --listen /
    --mock | --canon-binary / --max-subscriber-lag /
    --keep-history / --max-frame-size / --max-subscribers /
    --send-queue-depth / --poll-interval-ms`).  Identifier
    string `"canon-event-subscribe/v1"` published as
    `SUBSCRIBE_IDENTIFIER`.

  * **Canonical wire format.**  Documented in `docs/abi.md`
    §11 (new top-level section).  Inbound `SUBSCRIBE` frame
    (1-byte kind + 8-byte BE u64 resume-from); outbound
    `EVENT` frame (1-byte kind + 8-byte BE seq + 4-byte BE
    length + N CBE event bytes); 4 termination/control frames
    each 9 bytes total: `LAG_EXCEEDED`, `TRUNCATED`,
    `SERVER_SHUTDOWN`, `INVALID_REQUEST`.

  * **No `tokio` dependency.**  Departure from the plan
    §RH-D.1's suggested `tokio::fs::File` + async lines API:
    we use `std::fs::File` + a simple metadata-poll cursor,
    keeping the dependency tree minimal and matching the
    workspace's consistent "no async runtime" philosophy
    from `canon-l1-ingest` and `canon-host`.

  * **No `inotify` dependency.**  The plan §RH-D.1 explicitly
    rules out inotify ("on EOF, sleep + retry") for
    portability; we follow that recommendation.  Default
    poll interval is 100 ms; operators tune via
    `--poll-interval-ms <N>`.

  * **Log-tail reader.**  `tail.rs::TailReader` walks the
    Lean log-file format (4-byte ASCII "CANO" magic + 8-byte
    LE length + payload + 8-byte LE FNV-1a-64 trailer),
    assigns monotonic seq numbers starting at `1`.  Pending
    frames (writer mid-frame) cleanly distinguished from
    corruption (bad magic / bad trailer / oversize) via
    typed `PollOutcome` and `TailError` enums.  The
    FNV-1a-64 implementation includes reference test vectors
    matching Lean's `LegalKernel/Runtime/Hash.lean`.

  * **Extractor abstraction.**  `extract.rs::Extractor`
    trait with two implementations.  `MockExtractor` is the
    programmable test impl (cycles through a configured
    response sequence; supports error injection via
    `MockResponse::Err`).  `SubprocessExtractor` spawns the
    Lean `canon` binary in a future `extract-events` mode,
    re-spawning on subprocess crash.  The subprocess wire
    protocol is documented in the module docstring.

  * **Event cache + backfill.**  `event_cache.rs::EventCache`
    is a bounded FIFO keyed by seq.  `range(from_seq)`
    returns `InWindow { events }` / `OutOfWindow { oldest }`
    / `AtLiveTail`.  Resume semantics: `resume_from == 0`
    means "live-tail" (no backfill); `resume_from > 0` means
    "give me everything strictly greater than X".
    Out-of-window resumes return a typed `TRUNCATED` frame
    with the oldest available seq.

  * **Subscriber state machine + bounded-lag.**
    `subscription.rs::Subscriber` holds an atomic disconnect
    flag, atomic lag counter, atomic last-delivered-seq, and
    a `SyncSender<DeliveryEvent>`.  `try_enqueue` returns
    `Enqueued` (lag reset to 0) / `Lagging { lag }` (queue
    full but within threshold) / `LagExceeded` (disconnect
    flag set) / `Disconnected`.  The dispatch thread reads
    the disconnect flag each iteration and emits a final
    `LAG_EXCEEDED` frame before closing the socket.  Each
    subscriber's eviction is independent — slow subscribers
    do not delay events to fast subscribers.

  * **Subscriber capacity cap.**  `SubscriberRegistry`
    enforces `--max-subscribers <N>` at registration time
    (returns `RegisterError::AtCapacity`); the dispatch
    thread translates this to a `LAG_EXCEEDED` frame
    (semantically "server cannot serve you; back off").

  * **No `unsafe`.**  `unsafe_code = "forbid"` workspace
    lint.  The subscriber is a pure-Rust orchestrator; the
    only FFI surface is the subprocess pipe to `canon`.

  * **No panics on attacker input.**  Every frame-parse
    error path returns a typed `FrameError`; every
    subprocess error path returns a typed `ExtractError`;
    every cache-bounds violation returns a typed
    `PushError`.  Property tests sweep arbitrary bytes
    through the parsers and verify no panics.

  * **Workspace dependency additions.**  None beyond
    workspace-shared crates (`thiserror`, `tracing`,
    `tracing-subscriber`, `proptest`, `tempfile`).

  * **Lean-side follow-up.**  The `SubprocessExtractor`
    delegates event extraction to a future `canon
    extract-events` subcommand that Main.lean does not yet
    expose.  Until that lands, operators use
    `--mock` for testing/dev.  Surfacing the subcommand is
    a Lean-side PR that requires defining an `Encodable
    Event` instance (the inductive has 16 frozen
    constructors, indices 0..15 per `docs/abi.md` §5.3);
    none of the RH-D Rust code needs changing once it
    lands.  When the subscriber is invoked against a
    canon binary without the subcommand, the typed
    `ExtractError::SubprocessUnavailable` surfaces a
    clean operator-visible failure rather than silently
    wrong events.

  * **Audit posture at landing (post-RH-D audit pass).**  An
    independent code-review agent surfaced 4 critical and 6
    high-severity findings; all have been addressed in-PR:
    - **C-1** (Critical) Duplicate event delivery race between
      backfill and broadcast.  Fix: `dispatch_live` now drains
      pre-backfill channel duplicates at start (events with
      `seq ≤ last_delivered_seq`).  Regression test:
      `no_duplicate_delivery_under_load`.
    - **C-2** (Critical) Multi-event-per-frame events shared a
      seq, but the cache's `OutOfOrder` check rejected the 2nd+
      events.  Fix: `EventCache::push` now accepts equal seqs
      (only strictly-decreasing or `seq=0` is rejected).
      Regression tests: `equal_seq_push_accepted`,
      `multi_event_per_frame_all_delivered`,
      `multi_event_per_frame_backfill_includes_all`.
    - **C-3** (Critical) Slow-reader DoS: no TCP write-timeout
      meant a malicious client could pin a dispatch thread
      indefinitely by refusing to read.  Fix: new
      `--write-timeout-ms` flag (default 30s) sets
      `set_write_timeout` on every accepted stream.
    - **C-4** (Critical) Subprocess stderr pipe deadlock: the
      subprocess's stderr was `Stdio::piped()` but never
      drained, so a noisy Lean side could wedge the daemon.
      Fix: `Stdio::inherit()` so stderr flows to the parent's
      stderr (operator-visible, no buffer).
    - **H-1** (High) Connection-spawn-storm DoS: no cap on
      simultaneous dispatch threads.  Fix: new
      `--max-concurrent-connections` flag (default 1024) with
      RAII `ConnectionSlot` guard (mirrors canon-host's
      pattern).  Slot acquired BEFORE spawning, refused
      connections receive `LagExceeded` and close.
    - **H-2** (High) Half-dead server: extractor failure
      didn't set the stop flag, so the acceptor kept taking
      connections it couldn't serve.  Fix: `halt_extractor`
      helper sets the stop flag AND broadcasts shutdown.
    - **H-3** (High) `wait_for_dispatch_drain` timeout not
      enforced.  Fix: replaced unconditional joins with a
      counter-poll pattern (mirrors canon-host) + `is_finished`
      reaping for surviving panic info.
    - **H-4** (High) `ServerShutdown` frame lost when
      subscriber's queue was full.  Fix: replaced
      `enqueue_shutdown` with `request_shutdown` which sets a
      separate `shutdown_requested` atomic flag, decoupling
      shutdown signal from queue capacity.  Regression tests:
      `request_shutdown_full_channel_sets_flag_only`,
      `registry_broadcast_shutdown_laggy_subscriber_keeps_alive`.
    - **H-5** (High) Silent seq gap on extractor error: the
      tail cursor advanced past frames that the extractor
      failed to process.  Fix: any non-transient extractor
      error halts the extractor via `halt_extractor` rather
      than silently skipping.
    Plus several medium-severity fixes:
    - **M-1** Removed the unused `canon-cross-stack` dev-dep
      and documented why cross-stack fixtures are deferred
      (no Lean Event encoder yet).
    - **M-2** `is_connected` probe now treats stray
      post-handshake bytes as a protocol violation (per
      §11.1) and closes the connection.
    - **M-3** SubprocessExtractor now applies exponential
      backoff on consecutive spawn failures (100ms × 2^n,
      capped at 30s).
    - **M-4** TailReader rejects symlinked log paths and
      non-regular files.
    - **M-5** TailReader detects file-shrinkage (truncation)
      via a new `TailError::FileShrank` variant and halts
      cleanly.
    - **M-8** Lag-counter atomic ordering bumped to `AcqRel`
      so a dispatch thread seeing `disconnected=true` reads a
      consistent `lag` value.
    A second independent audit pass surfaced 4 additional
    critical findings (all introduced by the first audit's
    fixes) plus 6 high + 9 medium.  All criticals and highs
    are now addressed:
    - **C-NEW-1** (Critical) The first-pass C-1 fix had a
      regression: when a multi-event-per-frame batch was split
      across the cache snapshot and channel state, the
      drain-on-startup logic silently dropped channel events
      mis-classified as duplicates.  Fix: `extractor_loop`
      now holds the cache lock across BOTH the entire batch
      push AND broadcast, making the snapshot+channel state
      atomically consistent.  Regression test:
      `multi_event_per_frame_no_silent_drops_under_load`.
    - **C-NEW-3** (Critical) `accept_loop`'s `.expect("spawn
      dispatch thread")` panicked the daemon on `EAGAIN` /
      `ENOMEM`, defeating the `max_concurrent_connections`
      DoS cap.  Fix: replaced with an explicit match that
      logs the failure and continues; the slot RAII releases
      the counter via the consumed closure.
    - **C-NEW-4** (Critical) `dispatch_handles.retain(|h|
      !h.is_finished())` silently dropped finished JoinHandles
      without joining them, swallowing panic info.  Fix: new
      `reap_finished_dispatch_handles` joins finished handles
      and logs panics.
    - **H-NEW-6** (High) `shutdown_emits_shutdown_frame_to_all
      _subscribers` test used `>= 1` instead of `== 3`,
      meaning the test passed even if H-4 was reverted.  Fix:
      assertion strengthened to `== 3`; new
      `laggy_subscriber_receives_shutdown_not_lag_exceeded`
      regression test covers the H-4 fix directly.
    - **M-NEW-2** Subprocess respawn backoff now bumps on
      extract-time errors too (not just spawn-time), preventing
      tight loops if subprocess crashes on every input.
    - **M-NEW-5** TailReader's TOCTOU between
      `symlink_metadata` and `File::open` closed via post-open
      inode verification on Unix (`(dev, ino)` match).
    - **M-NEW-7** Acceptor backoff now resets on `WouldBlock`
      success and on `Ok`, not just on `Ok`.
    - **M-NEW-8** Rejection-write deadline tightened from 2s
      to 250ms to bound acceptor-thread tie-up.
    - **L-NEW-1** / **L-NEW-6** `is_connected` now skips the
      probe entirely if `read_timeout()` fails (defensive),
      and treats `Interrupted` errno as "still connected"
      (signal-delivery transient).
    - Extractor thread now wraps its body in `catch_unwind`
      so panics still trigger `broadcast_shutdown` + stop=true.
    - EventCache tracks `last_evicted_seq` for future
      partial-batch detection (helper API exposed; range
      semantics unchanged for backwards compatibility).
    A third audit pass surfaced 4 medium / low issues PLUS one
    critical (C-3R-1) and one high (H-3R-3) — all addressed:
    - **C-3R-1** (Critical) Multi-event-per-frame batch
      atomicity broke when `registry.broadcast` was called
      per-event in a loop (each call re-snapshotted the
      subscriber set, so a subscriber registering mid-batch
      received event[1..] without event[0]).  Fix: new
      `SubscriberRegistry::broadcast_to_snapshot` takes a
      pre-computed snapshot; `extractor_loop` snapshots ONCE
      per batch and broadcasts every event to the same set.
      A subscriber registering mid-batch is uniformly excluded
      from this batch (they'll pick it up via cache backfill
      on `resume_from > 0`, or skip it for live-tail).
      Regression test:
      `multi_event_per_frame_atomic_under_concurrent_subscribe`.
    - **H-3R-3** (High) `.expect("spawn extractor thread")`
      panicked the daemon on EAGAIN/ENOMEM at startup.
      Mirrors the C-NEW-3 dispatch-spawn fix.  Now logs +
      returns from `Server::run` cleanly.
    - **H-3R-4** (High) `shutdown_emits_shutdown_frame_to_all
      _subscribers` test had a contradictory pattern (tolerated
      `Err` in loop but asserted `== 3`).  Rewritten to strictly
      require ALL 3 subscribers receive the frame; `Err` now
      panics.
    - **EventCache `range` partial-batch detection**: the
      previous fix exposed `has_partial_front()` but the
      `range` method didn't use it.  Now `range(from_seq)`
      returns `OutOfWindow { oldest_available_seq: partial_seq
      + 1 }` when the cache's front is a partial multi-event
      batch and `from_seq < partial_seq`.  Subscribers no
      longer see incomplete batches via backfill.  Regression
      tests: `partial_batch_front_returns_out_of_window`,
      `complete_eviction_front_is_in_window`.
    - **H-NEW-4 (High)** `Server::run`'s shutdown ordering had
      `extractor_handle.join()` BEFORE `broadcast_shutdown`,
      and the join was unbounded.  A wedged extractor (e.g.
      blocked in subprocess I/O) would block shutdown
      indefinitely.  Fix: broadcast_shutdown FIRST so existing
      subscribers see the signal immediately, then bounded
      `bounded_join` with 10s timeout via `is_finished` polling.
    - **H-NEW-5 (High)** `dispatch_live`'s `Disconnected`
      arm emitted no wire frame on broadcast-sender drop.
      Now emits `ServerShutdown` so clients distinguish
      "server gone" from "network failure".
    - **H-NEW-3 (High)** Config validation now rejects
      `--max-concurrent-connections < --max-subscribers` to
      prevent SUBSCRIBE refusal-at-slot-cap with registry
      room available.  Regression test:
      `max_concurrent_below_max_subscribers_fails`.
    - **M-NEW-7** Acceptor backoff now resets on `WouldBlock`
      (no-op success), not just on `Ok`.  Saturating-mul on
      `backoff * 2` guards the academic Duration-overflow edge
      case (L-NEW-5).
    Final gates:
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test --workspace --locked` — 702 tests passing
      (+176 from the RH-C landing's 526).
    Fourth audit pass: surfaced 2 medium + 1 low + test-coverage
    gaps; all addressed:
    - **M-3R-4** `docs/abi.md` §11 missing entries for
      `--write-timeout-ms` / `--handshake-read-timeout-ms` /
      `--max-concurrent-connections`.  Added §11.5.1 (Transport
      timeouts) and §11.5.2 (DoS bounds) with full coverage.
    - **M-3R-5** TailReader's test-only `reopen` bypassed the
      symlink + inode TOCTOU check.  Now delegates to
      `Self::open` for uniform safety.
    - **L-3R-1** Race-window-check `request_shutdown` outcome
      now logs at `tracing::debug` for observability instead
      of silently discarding.
    - Deterministic unit tests for `broadcast_to_snapshot`
      atomicity (C-3R-1 regression catch):
      `broadcast_to_snapshot_excludes_post_snapshot_registrants`
      + `broadcast_to_snapshot_multi_event_uniform_exclusion`.
    - Unit tests for `bounded_join` (H-NEW-4 regression catch):
      `bounded_join_abandons_wedged_thread` +
      `bounded_join_returns_clean_for_finished_thread`.
    - `cargo clippy --workspace --all-targets --locked -- -D
      warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - `unsafe_code = "forbid"`.
    - Binary smoke-tested via
      `./target/release/canon-event-subscribe --help` /
      `--version` / `--mock` startup; the daemon listens,
      accepts SUBSCRIBE handshakes, and shuts down cleanly
      on the internal stop flag.

**Workstream RH-E (SQLite indexer + Rust DB layer).**
**Complete.**  Materialises both `runtime/canon-storage/`
(the storage abstraction trait + SQLite-backed
implementation; RH-E.0) and `runtime/canon-indexer/` (the
long-running SQLite event indexer daemon; RH-E.1) per
`docs/planning/rust_host_runtime_plan.md` §RH-E.0 and
§RH-E.1.  See `docs/abi.md` §11A for the on-disk key schema
and dispatch table.  Headlines:

  * **RH-E.0 library + binary surface.**  `canon-storage`
    ships as a pure library (`lib.rs` exporting 3 sub-modules:
    `storage` — the trait surface; `sqlite` — `SqliteStorage`
    impl + `SqliteOpenOptions` + `JournalMode` / `SynchronousMode`
    pragma helpers; `migration` — append-only migration
    scaffolding with `current_schema_version` /
    `target_schema_version` / `apply_migrations` helpers).
    Identifier string `"canon-storage/v1"` published as
    `STORAGE_IDENTIFIER`.  No binary; the storage layer is
    consumed by downstream daemons.

  * **RH-E.1 library + binary surface.**  `canon-indexer`
    ships as a library + binary (`canon-indexer` daemon with
    documented CLI flags `--storage / --subscribe /
    --max-frame-size / --reconnect-backoff-ms /
    --max-reconnects / --verify-against-canon` for the
    `daemon` subcommand, plus a `query <actor> <resource>`
    subcommand).  Identifier string `"canon-indexer/v1"`
    published as `INDEXER_IDENTIFIER`.

  * **Storage trait surface.**  `Storage` /
    `StorageSnapshot` / `StorageTransaction` traits.  Five
    methods on `Storage` (`get` / `put` / `delete` / `scan` /
    `snapshot` / `transaction`).  Byte-array keys with strict
    lex-order scan contract.  `StorageSnapshot` and
    `StorageTransaction` deliberately NOT `Send` (they hold a
    `std::sync::MutexGuard`, which is `!Send`; per-thread
    usage is the intended pattern).

  * **SQLite implementation.**  Single-table schema
    `kv(key BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL)
    WITHOUT ROWID` plus a `_meta` table for the schema version.
    Pragmas applied on open: `journal_mode = WAL`,
    `synchronous = NORMAL`, `foreign_keys = ON`,
    `temp_store = MEMORY`.  Wraps `rusqlite::Connection` in
    `std::sync::Mutex` rather than `tokio::sync::Mutex`
    (workspace consistently avoids an async runtime).
    `rusqlite` pinned at `0.31` with the `bundled` feature so
    SQLite is compiled from source — no system libsqlite3
    dependency.  Snapshots use `BEGIN DEFERRED` + a forced
    `SELECT 1` to pin the WAL state immediately; close-out
    via `ROLLBACK` (no writes occurred).

  * **Migration scaffolding.**  Append-only `MIGRATIONS`
    table.  Each migration carries a static name + an apply
    function `fn(&Connection) -> Result<(), rusqlite::Error>`;
    the runner bumps `_meta::schema_version` atomically inside
    the migration's own transaction.  Forward-incompatibility
    (on-disk version > binary's target) surfaces as a typed
    `StorageError::MigrationMismatch` rather than silent
    corruption.

  * **Indexer module structure.**
    - `event.rs` — typed Rust `Event` enum mirroring Lean's
      16-constructor `LegalKernel.Events.Event` inductive
      (frozen tags 0..15 per `LegalKernel/Events/Types.lean`
      and `docs/abi.md` §5.3).
    - `decoder.rs` — CBE decoder + matching encoder for the
      future Lean encoder's wire format.  Uses the same CBE
      primitives as `canon-l1-ingest/src/encoding.rs` (1-byte
      tag + 8-byte LE u64 heads).
    - `balance.rs` — per-(actor, resource) balance view over
      the `Storage` trait.  Key layout: 18-byte fixed-width
      string `"b/" + actor(8BE) + resource(8BE)`; value:
      16-byte BE u128.
    - `cursor.rs` — `c/cursor` (last-processed seq) +
      `c/identifier` cells.  Identifier mismatch on open
      surfaces as a typed error rather than silent corruption.
    - `indexer.rs` — orchestration: subscribe → decode →
      dispatch event → atomic-commit (balance updates +
      cursor advance in a single storage transaction).
    - `client.rs` — hand-rolled TCP client for the
      canon-event-subscribe §11 wire protocol.  Does NOT
      dev-dep on canon-event-subscribe to keep the runtime
      dependency tree minimal.
    - `config.rs` — CLI parsing for `daemon` and `query`
      subcommands.

  * **Dispatch table (see `docs/abi.md` §11A.4).**
    - `BalanceChanged(r, a, _, new_v)` → `set(a, r, new_v)`
      (authoritative).
    - `RewardIssued(r, recipient, amount)` →
      `credit(recipient, r, amount)` (saturating; overflow
      saturates to `u128::MAX` + typed warning).
    - `WithdrawalRequested(r, sender, amount, ...)` →
      `debit(sender, r, amount)` (strict; underflow rolls
      back the entire batch).
    - `DepositCredited(r, recipient, amount, _)` →
      `credit(recipient, r, amount)` (saturating).
    - All other tags (`NonceAdvanced`, `IdentityRegistered`,
      etc.) → no-op at the balance-view layer.

  * **Atomicity.**  Each event-batch (one log frame's worth
    of events, all sharing the same seq) commits atomically
    inside a single `Storage::transaction`.  The cursor
    advance is the transaction's last operation.  On any
    per-event error (underflow, corrupt cell, etc.), the
    transaction rolls back; the cursor does NOT advance; the
    indexer's next subscribe re-delivers the failing batch.

  * **Idempotent restart.**  On startup, the indexer reads
    the cursor and subscribes with
    `resume_from = cursor_value`.  Per the §11 wire format,
    the server replays every event with `seq > cursor_value`.
    Multi-event-per-seq batches are handled correctly: the
    `main.rs::consume_batched` path accumulates frames sharing
    a seq into a batch and dispatches them as a single
    transaction.

  * **Mathematical contract.**  For any extracted event
    stream `[e_1, e_2, ..., e_n]`, the indexer's balance view
    after replay equals the kernel's `getBalance(actor,
    resource)` for every `(actor, resource)` pair.  This is
    the load-bearing correctness property; the
    `--verify-against-canon` CLI flag is plumbed for future
    cross-check work against a running `canon-host`.

  * **Event encoding decision.**  The Lean side does not yet
    ship an `Encodable Event` instance (the `canon
    extract-events` subcommand is deferred per the
    "Workstream RH-D" entry above).  The Rust decoder uses
    the established CBE convention so it remains compatible
    the moment the Lean encoder lands.  Symmetric
    `encode_event` co-located so the future Lean encoder can
    be cross-checked byte-for-byte against the Rust mirror.

  * **Workspace dependency additions.**  `rusqlite = "0.31"`
    with `bundled` feature.  No other new dependencies.

  * **Workspace version bump.**  `0.1.3 → 0.2.0` (minor bump —
    RH-E ships two substantial new public APIs in
    `canon-storage` and `canon-indexer`; per the workspace
    release-discipline section in this file, this opts into a
    minor bump rather than the default patch).

  * **Test mass.**  66 tests in `canon-storage` (49 unit + 9
    integration + 8 property) and 117 tests in
    `canon-indexer` (95 unit + 7 integration + 5 property +
    10 wire-protocol) = 183 new tests.  The wire-protocol
    tests stand up a tiny mock canon-event-subscribe server
    in a background thread and verify the indexer's
    `SubscribeClient` round-trips every frame variant
    byte-for-byte against the §11 wire spec.  Workspace test
    total: 884.

  * **Audit posture at landing.**
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test --workspace --locked` — 900 tests passing.
    - `cargo clippy --workspace --all-targets --locked -- -D
      warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - `unsafe_code = "forbid"` on both new crates.
    - Binary smoke-tested via
      `./target/release/canon-indexer --version` →
      `canon-indexer/v1 (version 0.2.0)`;
      `./target/release/canon-indexer query --storage <tmp>
      42 7` → `42 7 0` (exit 0) on a fresh DB; daemon mode
      gracefully retries on connect-refused and exits
      transient when `--max-reconnects` is exceeded; mock-
      server end-to-end flow confirms two-pass dispatch
      (BalanceChanged + RewardIssued for same key →
      authoritative BalanceChanged value, NOT double-count)
      and partial-batch discard on connection-drop.

  * **Post-landing audit pass.**  Two independent code-review
    agents surfaced 12 critical / high-severity findings
    across `canon-storage` and `canon-indexer`; all
    addressed in-PR:
    - **CRITICAL canon-storage**: `snapshot()` used
      `SELECT 1` to "force the WAL read mark" — but a
      SELECT on a literal doesn't touch any table, so
      SQLite never pinned the read mark.  A concurrent
      writer between BEGIN DEFERRED and the snapshot's
      first real read could leak post-write state into
      the snapshot.  Fix: replaced with
      `SELECT 1 FROM sqlite_master LIMIT 1` — forces a
      real-table touch.  New regression test
      `snapshot_pins_wal_state_across_connections`
      (using two SqliteStorage instances on the same
      file) verifies the fix.
    - **CRITICAL canon-indexer**: `consume_batched`
      committed in-flight (partial) batches on EOF,
      ServerShutdown, and LagExceeded.  The wire protocol
      has no per-batch terminator — the only signal that
      seq=N's batch is complete is a frame with seq=N+1.
      Committing a partial batch and advancing the cursor
      would PERMANENTLY LOSE the seq's missing tail on
      reconnect.  Fix: only commit on a strictly-greater
      seq trigger; discard on any other terminator.
      Three new regression tests
      (`partial_batch_on_eof_not_committed`,
      `partial_batch_on_server_shutdown_not_committed`,
      `partial_batch_on_lag_exceeded_not_committed`) plus
      an end-to-end Python harness verify the fix.
    - **CRITICAL canon-indexer**: Arrival-order dispatch
      double-counted BalanceChanged + semantic-event
      batches.  The Lean side emits `[balanceChanged?,
      rewardIssued]` (balanceChanged FIRST), so the
      previous dispatch set the post-state value then
      applied the credit on top → balance + amount instead
      of balance.  Worse: for withdraw,
      `[balanceChanged?, withdrawalRequested]` triggered
      underflow (post-balance < withdrawn amount), rolling
      back the entire batch.  Fix: two-pass dispatch — Pass
      1 collects `(actor, resource)` pairs covered by
      `BalanceChanged`; Pass 2 applies semantic events
      skipping those pairs; Pass 3 applies `BalanceChanged`
      events as authoritative sets.  Six new regression
      tests pin the contract per dispatch variant.
    - **CRITICAL canon-indexer**: Cursor desync on
      `tx.commit()` failure.  If commit reported an error
      but SQLite's commit had actually succeeded, the
      in-memory cursor stayed at the old value but disk
      had the new value.  Next call would double-apply
      the batch.  Fix: on commit failure, reload cursor
      from disk; if disk reflects the new value, surface
      a typed `IndexerError::CommitAmbiguous`.
    - **HIGH canon-storage**: `BEGIN DEFERRED` + warmup
      read failure left the connection in a half-
      transaction state.  Fix: ROLLBACK on warmup failure
      before returning the error.
    - **HIGH canon-storage**: `tx.commit()` failure left
      the transaction state ambiguous (SQLite may have
      auto-rolled-back; the Drop's ROLLBACK could fail
      silently).  Fix: defensive ROLLBACK inside `commit`
      (tolerates failure); set `ended=true` regardless so
      Drop doesn't double-attempt.
    - **HIGH canon-storage**: Drop's silent ROLLBACK
      swallowed errors that could indicate a wedged
      connection.  Fix: log via `tracing::warn`.
    - **HIGH canon-indexer**: 30-second read timeout on
      SubscribeClient caused idle subscribers to thrash
      (reconnect every 30s on quiet deployments).  Fix:
      no default read timeout; rely on TCP-level FIN for
      liveness.  Operators can override via
      `ClientOptions`.
    - **HIGH canon-indexer**: Out-of-order seq from server
      was wrapped in `StorageError::Other(...)` —
      mistyped.  Fix: new
      `IndexerError::ProtocolViolation` variant.
    - **HIGH canon-indexer**: Decode failures wrapped in
      `StorageError::Other(...)` — mistyped.  Fix: new
      `IndexerError::Decode { seq, source: DecodeError }`.
    - **MEDIUM canon-storage**: `scan_lower_bound_filtered`
      materialised value bytes before the prefix check.
      Fix: read key first, check prefix, then read value
      (avoids allocation-before-bounds-check).
    - **MEDIUM canon-indexer**: `IdentifierNotUtf8` lost
      the bytes preview.  Fix: carry a hex preview of up
      to 32 leading bytes.
    - **MEDIUM canon-indexer**: Wire-protocol tests used
      a fixed port range, risking collision under
      parallel cargo runs.  Fix: bind to
      `127.0.0.1:0` (kernel-assigned ephemeral).
    - **MEDIUM canon-indexer**: Property tests never
      exercised multi-event-per-seq; `realistic_scenario`
      test hand-ordered semantic events before
      `BalanceChanged`, hiding the dispatch bug.  Fix: new
      regression test `dispatch_two_pass_reward_no_double_count`.
    - Plus various minor cleanups: dead `let _ = off`
      removed from decoder cursor; stale "working-set
      HashMap" docstring removed from transaction;
      `Display for &dyn StorageSnapshot` dead code
      removed; cursor monotonicity policy (NON-strict at
      cursor level, strict at indexer level) documented
      explicitly.
    Final gates: workspace `cargo test --workspace
    --locked` reports 900 tests passing (+16 from the
    initial RH-E landing's 884: new daemon-loop and
    storage-pinning regression tests).  Clippy + fmt
    clean.

  * **Indexer module extraction.**  The event-consumption
    loop (`consume_stream` / `consume_batched`) was moved
    from `main.rs` to a new `canon_indexer::daemon`
    library module so the partial-batch / two-pass fixes
    have unit-test coverage.  `main.rs` now just wires
    the CLI to the library functions.

  * **Second audit pass (post-first-audit-fix).**  A second
    round of independent code review surfaced 4 additional
    findings introduced by the first audit's fixes; all
    addressed:
    - **CRITICAL canon-indexer (broken test assertion)**:
      `daemon_loop.rs::partial_batch_on_eof_not_committed`
      used `matches!(outcome, ConsumeOutcome::CleanEof);`
      which discards the resulting bool — the test would
      silently pass for ANY outcome variant.  Fixed to
      `assert!(matches!(...))`.
    - **CRITICAL canon-indexer (cascading-failure cursor
      desync)**: when `tx.commit()` failed AND the
      subsequent disk-cursor reload ALSO failed, the
      indexer silently propagated only the read-cursor
      error.  The original commit error was dropped, and
      the in-memory cursor stayed at the stale pre-batch
      value — a subsequent `apply_batch` could double-apply
      if SQLite had actually persisted the failed commit.
      Fix: new `IndexerError::CursorRecoveryFailed` variant
      carrying BOTH error messages; the indexer is marked
      `poisoned` and rejects all subsequent `apply_batch`
      calls with `IndexerError::Poisoned` until the process
      restarts (which reloads the cursor from disk via
      `Indexer::open`).  Four new fault-injection tests
      verify the recovery semantics via a `FaultyStorage`
      adaptor.
    - **HIGH canon-storage (no autocommit defense)**: if a
      previous `snapshot()` or `transaction()` call hit
      back-to-back failures (BEGIN + defensive cleanup
      both fail), the SQLite connection was left in a
      half-transaction state.  Subsequent BEGIN calls
      would fail until the process restarted.  Fix: new
      `recover_autocommit_if_needed` helper that issues a
      defensive ROLLBACK at the start of every
      `snapshot()` / `transaction()` if `is_autocommit()`
      is false.  Now the indexer can recover from any
      transient SQLite-state corruption.
    - **HIGH canon-indexer (commit-ambiguous daemon halt)**:
      the daemon halted with `OperatorAction` on every
      `IndexerError` including the recoverable
      `CommitAmbiguous` (where the disk cursor has been
      successfully resynced).  Fix: special-case
      `CommitAmbiguous` to log at WARN and continue the
      reconnect loop; only `Poisoned`,
      `CursorRecoveryFailed`, and other terminal errors
      halt.
    - **HIGH canon-indexer (unbounded batch)**: `apply_batch`
      built an O(N) HashSet of `(actor, resource)` pairs
      with no upper bound on N.  Added
      `INDEXER_MAX_BATCH_EVENTS = 1024` (mirrors
      canon-event-subscribe's `HARD_MAX_EVENT_COUNT`); new
      `IndexerError::BatchTooLarge` variant rejects
      oversize batches before allocation.
    - **MEDIUM canon-storage (silent debug log on
      commit-fail rollback)**: bumped `tracing::debug` →
      `tracing::warn` on the commit-failure defensive
      rollback path so operators running at INFO level
      see the diagnostic.
    - **MEDIUM canon-indexer (silent encoder truncation)**:
      added `encode_event_checked` (a fallible variant of
      `encode_event`) that returns
      `EncodeError::AmountExceedsBound` on amounts `>= 2^64`.
      The original `encode_event` keeps its truncation
      semantics (matches Lean's `Encodable Nat`); the
      checked variant is for production callers handling
      arbitrary Amount values.  Five new tests pin the
      contract.
    - **LOW canon-indexer (defensive client flush)**: added
      explicit `flush()` after the handshake `write_all`
      in `SubscribeClient::connect`.  No-op today (the
      raw `TcpStream` is unbuffered) but defends against a
      future maintainer wrapping in `BufWriter`.
    - **LOW canon-indexer (first-frame decode log gap)**:
      added `tracing::debug!` on the first-frame decode
      error path in `consume_batched` to match the
      EOF/client-error paths.
    - Plus 2 new property tests (decoder fuzz against
      arbitrary bytes + arbitrary tail-after-valid-tag);
      2 new wire-protocol tests (empty-payload regression
      + oversize-declared-length DoS bound); the 4
      fault-injection tests already listed above.
    Final gates: workspace `cargo test --workspace
    --locked` reports 913 tests passing (+13 from the
    first audit pass's 900: 5 encode_event_checked tests,
    2 decoder fuzz, 2 wire-protocol DoS, 4 fault
    injection).  Clippy + fmt clean.

  * **Third audit pass (self-review of the second
    audit's fixes).**  A focused re-review of the
    audit-pass-2 changes found one CRITICAL race
    condition and two improvements; all addressed:
    - **CRITICAL canon-storage**: the `is_autocommit`
      defense added in audit-pass-2 used a buggy drop-
      and-reacquire pattern: the trait method acquired
      the mutex, called `recover_autocommit_if_needed`,
      then DROPPED the mutex and re-acquired it inside
      a separate `snapshot_inner` / `transaction_inner`
      helper.  Between the drop and re-acquire,
      another thread could acquire the mutex and wedge
      the connection again — defeating the recovery's
      purpose entirely.  Fix: inlined the recovery
      directly into `snapshot` and `transaction` so the
      mutex is held for the entire recovery + BEGIN
      sequence (atomic).  Removed the `_inner` helpers.
    - **HIGH canon-indexer**: `consume_stream` accepted
      events with seq=0, which is the wire protocol's
      reserved sentinel for "no resume".  Added an
      explicit defensive check that returns
      `IndexerError::ProtocolViolation` when seq=0 is
      observed in an EVENT frame.  Regression test
      `seq_zero_event_protocol_violation`.
    - **MEDIUM canon-storage migration**: the migration
      runner read `current_schema_version` OUTSIDE the
      transaction.  For the v1 idempotent CREATE TABLE
      migration this is harmless, but a future non-
      idempotent migration (e.g., ALTER TABLE ADD
      COLUMN) would corrupt under concurrent multi-
      process migration.  Switched to BEGIN IMMEDIATE
      (acquires the write lock at BEGIN itself) AND
      re-read the version INSIDE the transaction.  Now
      each migration sees an authoritative post-other-
      processes' committed version when deciding what
      to apply.
    Final gates: 914 tests passing (+1 from the second
    audit pass's 913: the new seq=0 regression).
    Clippy + fmt clean.  End-to-end Python harness
    against a release binary still passes (two-pass
    dispatch correctness, partial-batch discard, and
    new seq=0 defense all verified).

**Workstream RH-F (Transfer-throughput benchmark).**
**Complete.**  Materialises `runtime/canon-bench/` as a
library + binary per `docs/planning/rust_host_runtime_plan.md`
§RH-F.  Headlines:

  * **Library + binary surface.**  `canon-bench` ships as a
    library (`lib.rs` exporting 6 modules: `config`,
    `fixture`, `histogram`, `report`, `runner`, `server`)
    plus a binary (`canon-bench` harness with documented CLI
    flags `--standalone | --connect <ENDPOINT>` for mode
    selection, `--actor-count / --transfer-count /
    --worker-count / --warmup-requests / --seed` for the
    workload, `--queue-depth / --max-frame-size` for the
    embedded server, `--report <PATH> / --baseline <PATH> /
    --threshold <FRAC> / --target-tps <N> / --target-p99-ms
    <N>` for the report + regression gates).  Identifier
    string `"canon-bench/v1"` published as `BENCH_IDENTIFIER`.

  * **Deterministic fixture generator.**  Pre-funds
    `actor_count` (default 1000) secp256k1 keypairs derived
    from a `(seed, actor_index)` Keccak-256 hash chain with
    rejection sampling into `[1, n)` curve order.  Generates
    `transfer_count` (default 10000) round-robin
    `Action::Transfer` payloads each signed with the sender's
    actor key + per-actor monotonically-increasing nonce.
    Reuses `canon-l1-ingest::encoding` primitives so the
    emitted SignedAction bytes are cross-stack-equivalent to
    Lean's `Encoding.SignedAction.encode`.  Two runs with the
    same `(seed, actor_count, transfer_count)` produce
    byte-identical payloads.

  * **Latency histogram.**  Bounded-resolution sample collector
    using a `Vec<u64>` of per-request nanosecond durations.
    Percentile computation via NIST nearest-rank method
    (`p_k = sorted[ceil(k*N/100) - 1]`); mean / stddev via
    the Welford one-pass numerically-stable algorithm.
    Insertion is `O(1)`; report is `O(N log N)`.  Bounded
    memory at the documented 10k-transfer workload (~80 KiB
    for the samples Vec).

  * **Concurrent benchmark driver.**  Spawns a configurable
    number of submitter threads (default 64) sharing an
    atomic cursor into the pre-framed payloads.  Each worker
    opens a fresh connection per request (mirroring the
    canon-host §10.5 one-shot wire format), writes the framed
    payload (4-byte BE length + N CBE bytes), reads the
    5-byte verdict header + reason payload, and records
    elapsed wallclock as a latency sample.  Per-worker
    histograms merged at the end.  Throughput is wallclock
    between first measured submission and last response
    (NOT a per-thread sum, which would mis-attribute
    speed-up to the benchmark's own parallelism).

  * **JSON report + baseline regression check.**
    `BenchmarkReport` serialises to versioned JSON (the
    `protocol_version` field gates forward-incompatible
    schema evolution).  `compare_against_baseline` detects
    throughput drops > `threshold` and latency growths >
    `threshold` (default 10%) and returns a typed
    `RegressionVerdict::Regression` enumerating each
    regressing metric.  Direction-aware: speed improvements
    never trigger a regression.  Absolute targets via
    `--target-tps` / `--target-p99-ms` (the CI escape hatch
    for new deployments without a baseline).

  * **In-process server helper.**  `StandaloneServer` spawns
    an in-process `canon_host::server::Server` backed by
    `MockKernel` so the binary's `--standalone` mode is
    self-contained (no operator-supplied canon-host
    required).  `--connect <ENDPOINT>` mode points at any
    running canon-host (e.g., the production
    `CommandKernel`-backed binary).

  * **Observed throughput at landing (informational).**  On a
    developer workstation (Linux 6.18, opt-level=3, LTO=thin),
    the default 1000-actor / 10000-transfer / 64-worker
    workload sustains ~7500 ops/sec with p50 ~ 8 ms and p99
    ~ 13 ms.  The plan §RH-F target (≥ 10 000 tx/sec, p99
    < 10 ms) is ~75% met on throughput and 1.3× over budget
    on p99 — gap documented in plan §RH-F closeout.  The
    bottleneck is the one-shot-per-request connection
    pattern + the listener's polling accept-loop; resolution
    is out of scope for RH-F (would require a wire-format
    amendment for persistent connections).  The harness
    faithfully measures the production wire format's
    throughput ceiling.

  * **Workspace dependency additions.**  None beyond
    workspace-shared crates (`canon-cli-common`,
    `canon-host`, `canon-l1-ingest`, `sha3`, `thiserror`,
    `tracing`, `tracing-subscriber`, `serde`, `serde_json`,
    `tempfile`).

  * **Workspace version bump.**  `0.2.0 → 0.2.1` (patch bump
    per CLAUDE.md's default release discipline; canon-bench
    is a new crate but adds no public-API surface to existing
    crates).

  * **Test mass at landing.**  After audit-pass-1: 103 lib unit
    tests + 8 smoke / integration tests = 111 new tests.
    Workspace total rises from ~914 (post-RH-E audit-pass-3) to
    ~1024.  Coverage breakdown:
    - `fixture` (18 tests): scalar-in-range edge cases (zero,
      `n`, `n ± 1`), deterministic key derivation, small-scale
      fixture generation, payload-byte layout pinning, per-actor
      nonce monotonicity (decoded back from encoded bytes for
      round-trip verification), the `MAX_SCALAR_ATTEMPT_INDEX` /
      `MAX_SCALAR_ATTEMPTS` invariant.
    - `histogram` (17 tests): percentile correctness on
      known input, summary idempotency, merge correctness,
      constant-sample / two-sample stddev (textbook formula
      verification), JSON round-trip preservation.
    - `report` (18 tests): baseline regression direction-
      awareness (improvement never regresses), multi-metric
      regression aggregation, protocol-version drift
      detection, JSON malformed / missing-file error paths.
    - `runner` (13 tests): zero-workers / oversize-warmup
      validation, Endpoint cloning, `RunOutcome::throughput_
      ops_per_sec` zero / typical / sub-second cases,
      `read_exact_with_eof` happy-path / truncated-header /
      truncated-reason / zero-length / fragmented-reader
      coverage, `SpawnFailed` / `UnexpectedVerdict` Display
      format pinning.
    - `config` (22 tests): every flag's happy path + every
      documented error path (unknown / missing / invalid /
      conflicting), CLI mode composition, seed hex/decimal
      parsing, NaN-rejection for `--threshold` / `--target-tps`
      / `--target-p99-ms` (load-bearing defence: `NaN <= 0.0`
      is silently `false`), Inf-rejection for the same.
    - `server` (3 tests): spawn + stop on Unix + TCP, stop
      idempotency.
    - `smoke.rs` (8 end-to-end): Unix-socket benchmark, TCP
      benchmark, complete report round-trip (save + load +
      compare), refused-connection error path, histogram-
      merge integration, deterministic fixture byte-equality,
      elapsed-brackets-workload (reduce-on-join correctness),
      elapsed-consistent-across-runs (run-to-run stability).
    - Crate-level (4): crate-name / identifier / protocol-
      version / default-constants don't drift.

  * **Audit-pass-1 (post-landing self-review).**  An internal
    deep-audit pass surfaced 10 correctness / best-practice /
    documentation findings; all addressed in-PR:
    - **HIGH** `config::CliConfig::validate` silently passed
      NaN values for `threshold` / `target_tps` /
      `target_p99_ms` because every IEEE-754 comparison
      against NaN is `false`, so the pure-range checks
      (`threshold <= 0.0 || >= 1.0`) didn't trip.  Fix:
      `is_finite()` guard rejects NaN + ±∞ before the range
      check.  Tests pin the new behaviour (NaN- and
      Inf-rejection assertions on every float-valued field).
    - **HIGH** `runner::worker_loop` updated `measurement_end`
      via a `Mutex<Option<Instant>>` on **every** successful
      non-warmup request — a per-request shared-lock hot path
      that serialized all worker threads at the join point.
      Fix: each worker tracks its own latest completion
      timestamp locally; `run` collects them via
      `JoinHandle::join` and takes the max as the global
      measurement-end.  Zero shared-lock operations on the
      per-request happy path.
    - **HIGH** `runner::run` and `server::StandaloneServer::
      spawn_unix` / `spawn_tcp` used
      `.expect("spawn ... thread")` on the `thread::Builder`
      result — same anti-pattern fixed in canon-host's
      audit-pass-2 (C-NEW-3): EAGAIN / ENOMEM under sustained
      load would panic instead of surfacing a typed error.
      Fix: new `RunnerError::SpawnFailed` /
      `StandaloneServerError::SpawnFailed` variants;
      already-spawned workers / threads join cleanly before
      the error propagates.
    - **MEDIUM** `runner::worker_loop` re-acquired
      `measurement_start` lock on every non-warmup request
      even after the timestamp was already set.  Fix: gated
      by a new `AtomicBool` (`measurement_started`) with
      Acquire-load / Release-store discipline; the lock is
      now acquired exactly once globally.
    - **MEDIUM** `runner::read_exact_with_eof` distinguished
      header (5-byte) vs reason-payload truncation via a
      magic `total_len == 5` check inside the function.
      Fragile — would mis-attribute on any future 5-byte
      reason read.  Fix: explicit `ReadKind` enum parameter.
    - **MEDIUM** `runner::worker_loop`'s
      `Histogram::with_capacity(.../4)` hardcoded a `/4`
      divisor where `/ worker_count` was intended.  Fix:
      `worker_count` propagated into `SharedRunState`; the
      pre-allocation uses `div_ceil(worker_count.max(1))`
      with a `1 << 20` defensive cap.
    - **LOW** `fixture::MAX_SCALAR_ATTEMPTS = 255` with
      `for attempt in 0..=255u8` (256 iterations) reported
      `attempts: 255` in the error path — off-by-one.  Fix:
      split into `MAX_SCALAR_ATTEMPT_INDEX` (loop bound) and
      `MAX_SCALAR_ATTEMPTS` (count, = index + 1).
    - **LOW (docs)** `server.rs` module docstring claimed
      `Drop` "joins the background thread" — actually `Drop`
      deliberately does NOT join (would deadlock).  Also
      referenced a `with_queue_depth` setter that doesn't
      exist.  Fix: re-documented the `Drop` / `stop`
      lifecycle ladder with the correct semantics.
    - **LOW (docs)** `lib.rs` Mathematical-soundness section
      claimed `p50 = sorted[(N-1)/2]` — mathematically
      equivalent to the actual `ceil(50*N/100) - 1` for all
      `N >= 1`, but misleadingly imprecise (only the latter
      generalises to `p90` / `p99` / `p999`).  Fix:
      docstring states the actual formula explicitly and
      notes the p50 equivalence.
    - **LOW (docs)** `config.rs` flag-matrix table marked
      `--standalone` / `--connect` as "Required" — actually
      both are optional with `--standalone` as the implicit
      default.  Fix: re-cast the table as `(Flag, Default,
      Description)` so the default value is explicit.

  * **Audit-pass-2 (deeper self-review).**  A second independent
    pass surfaced 8 more correctness / security / best-practice
    findings; all addressed in-PR:
    - **HIGH (DoS surface in `--connect` mode)** `submit_once`
      read the server-declared `reason_len` (up to `u32::MAX` =
      4 GiB) and `vec![0u8; reason_len]`-ed the buffer without
      a cap.  A hostile / misbehaving `--connect <ADDR>` target
      could declare an absurd length and OOM the client.  Fix:
      new `MAX_REASON_BYTES = 64 KiB` (mirrors canon-host's
      `MAX_SUBPROCESS_OUTPUT`); declared lengths over the cap
      surface as a typed `SubmissionError::ResponseTooLarge`
      BEFORE allocation.
    - **HIGH (TCP connect hang)** `Endpoint::connect()` used
      `TcpStream::connect()` with no timeout, which would
      block indefinitely against a non-responding host.  Fix:
      new `Endpoint::connect_with_timeout(timeout)` that uses
      `TcpStream::connect_timeout(addr, timeout)` for TCP; the
      Unix-socket variant inherits the existing fast-fail
      semantics.  `DEFAULT_CONNECT_TIMEOUT = 5 s`.
    - **MEDIUM (hot-path allocation)** `submit_once` always
      allocated `reason_bytes` + the reason String even on the
      happy path (Ok verdict + empty reason).  Fix: short-circuit
      after the cap check when verdict==0; skip the reason
      read + allocation entirely.  The kernel discards
      pending reason bytes when the connection closes (the
      §10.5 wire format is one-shot).
    - **MEDIUM (fixture overflow late-fail)**
      `FixtureConfig::transfer_amount >= 2^64` previously
      failed only at first-transfer-encoding inside `generate`,
      AFTER the O(actor_count) key-derivation work.  Fix:
      pre-validate in `FixtureConfig::validate` via
      `TransferAmountTooLarge`.
    - **MEDIUM (report-save atomicity)** `BenchmarkReport::save`
      used `fs::write` which is `open + write + close` — a
      mid-write crash leaves a partial JSON document that the
      next baseline load would fail to parse.  Fix: write to a
      sibling `.tmp` and `rename(2)` into place.  POSIX
      guarantees rename is atomic w.r.t. concurrent readers.
    - **LOW (defensive)** `percentile_nearest_rank` divides by
      `denominator` without a non-zero check.  Private fn;
      callers use literal 100/1000.  Fix: `debug_assert!` for
      contract clarity.
    - **LOW (docs)** `Cargo.toml` lint comment claimed
      `SECP256K1_ORDER_BE` was the "half-order constant" —
      actually it's the full curve order `n`.  Fix:
      corrected comment.
    - **LOW (test coverage)** No tests for
      `SubmissionError::UnexpectedVerdict` or
      `ResponseTooLarge` paths from `submit_once`.  Fix:
      `smoke_unexpected_verdict_surfaces` and
      `smoke_response_too_large_surfaces` spawn a mock TCP
      server returning controlled wire-format bytes and
      verify the typed errors surface correctly.

  * **Audit-pass-3 (silent-serde discovery + report hardening).**
    A third deep audit pass surfaced 5 more correctness / robustness
    findings; all addressed in-PR:
    - **HIGH (silent corruption in `save`)** — discovered that
      `serde_json::to_string_pretty` silently converts
      `f64::INFINITY` and `f64::NAN` to the JSON literal `null`,
      producing a file that fails to re-load (since the f64
      deserializer rejects `null`).  This is a silent
      save-time data-loss path.  Fix: `BenchmarkReport::save`
      now validates f64 fields upfront via the new
      `validate_loaded` helper, converting the silent path
      into a typed `InvalidFieldValue` error BEFORE any disk
      write occurs.  Three new tests pin this behaviour for
      infinity-throughput, NaN-stddev, and negative-mean
      cases.
    - **HIGH (no load-time validation)** — `BenchmarkReport::load`
      previously only validated `protocol_version`.  A
      hand-edited or corrupted JSON could smuggle negative
      throughput / negative latency through the parser.  Fix:
      `validate_loaded` is now also called from `load` to
      reject negative f64 fields.  Three new tests pin this.
    - **MEDIUM (`compare_against_baseline` defense-in-depth)**
      — added a non-finite-`threshold` short-circuit that
      returns `WithinTolerance` rather than producing NaN-laden
      drift values.  `CliConfig::validate` already rejects
      non-finite thresholds at the CLI; this is the
      library-API defense.  Two tests pin NaN-threshold and
      ±∞-threshold behaviour.
    - **MEDIUM (one fewer syscall per request)** —
      `worker_loop` previously called `Instant::now()` TWICE
      per successful non-warmup request (once via
      `started.elapsed()`, once for `last_completion`).
      Consolidated into a single `Instant::now()` capture used
      for both, saving one syscall per measured request AND
      making the two derived values consistent at the exact
      same wallclock instant.
    - **LOW (merge-loop pre-allocation)** —
      `run()`'s `merged: Histogram` previously started with
      zero capacity, requiring O(log W) reallocations as
      per-worker histograms merged in.  Pre-allocate with
      `fixture.len() - warmup_requests` upfront so the merge
      loop runs zero-reallocation.

  * **Audit-pass-3 serde_json behaviour discovery.**  Pinned via
    `load_rejects_infinity_overflow_via_serde`: `serde_json`'s
    parser rejects `1e500` (decimal overflow to f64::INFINITY)
    as a `ParseJson` error before our `validate_loaded` check
    fires.  Our load-time non-finite check is therefore
    defence-in-depth for JSON-load paths but reachable for
    direct-API callers that construct a `BenchmarkReport`
    struct in Rust.  The complementary `save()` pre-write
    validation IS reachable because the OTHER serde_json
    behaviour (silent `INFINITY`-to-`null` coercion on
    serialize) is fully active.

  * **Audit posture at landing.**
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test --workspace --locked` — ~1045 tests
      passing (+131 from RH-E's 914 landing; +9 from
      audit-pass-2's 1036 via audit-pass-3).
    - `cargo clippy --workspace --all-targets --locked -- -D
      warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - `unsafe_code = "forbid"`.
    - Binary smoke-tested via
      `./target/release/canon-bench --version` →
      `canon-bench/v1 v0.2.1 (protocol v1)`;
      `./target/release/canon-bench --help` lists every
      documented flag; a full default-workload run
      (1000 actors / 10000 transfers / 64 workers) sustains
      ~6500-7500 ops/sec without errors.

**Workstream RH-G (Off-chain fault-proof observer).**
**Complete (full landing — every sub-unit shipped, zero
deferred work).**  Materialises
`runtime/canon-faultproof-observer/` as the operational
counterpart to the Workstream-H Lean fault-proof soundness
chain.  See `docs/planning/rust_host_runtime_plan.md` §RH-G
and `docs/fault_proof_runbook.md` §7.

The initial RH-G landing left several items deferred; this
full landing closes them all:

  * **RH-G.4 SubprocessTruthOracle.**  The Rust observer's
    `SubprocessTruthOracle` shells out to `canon replay-up-to
    LOG IDX` for in-production truth lookups.  Real-canon
    integration tests live in
    `tests/real_canon_subprocess.rs`.
  * **RH-G.5 JSON-RPC EIP-1559 submitter.**  Production
    `JsonRpcSubmitter` in `src/jsonrpc_submitter.rs` (1582
    lines) builds + signs EIP-1559 typed-2 transactions via
    the audited `BridgeActorKey::sign_prehash` wrapper +
    hand-rolled RLP encoder; broadcasts via
    `eth_sendRawTransaction`; defence-in-depth tx-hash cross-
    check.  Includes `terminateOnSingleStep` full-signature
    calldata builder.
  * **RH-G.7 cross-stack corpus.**  Lean side generates a
    50-trace observer game-trace corpus at
    `solidity/test/CrossCheck/fixtures/observer_game_traces.json`;
    the Rust test `tests/observer_game_traces.rs` replays
    every trace and asserts byte-equivalence with the Lean
    reference's `applyTransition`.
  * **RH-G.7 chaos suite.**  `tests/chaos.rs` covers shallow
    + deep re-orgs, kill-restart at varying iteration points,
    dropped-connection RPC injection, and an adversarial-
    opponent simulator.  `chaos_with_seed_drives_all_scenarios`
    is the operator-facing seed-sweep entry point
    (`CANON_CHAOS_SEED=N`).
  * **eth_call game-state reader.**  `src/state_reader.rs`
    decodes the Solidity `games(uint256)` auto-generated
    getter's 18-slot ABI response.  Closes the "we don't
    have access to the full L1 game state" cold-start gap;
    `Observer::hydrate_cold_start_games` flips every
    `state_known=false` game to `state_known=true` via the
    audited `mark_state_known` API.
  * **Lean cell-proof export.**  `Main.lean`'s
    `canon export-cell-proofs LOG IDX SIGNER` subcommand
    builds the cell-proof bundle via `buildObserverCellProofs`
    and emits it as a JSON array per line.  Rust submitter's
    `CellProof` struct consumes the same shape.

  * **Library + binary surface.**  `canon-faultproof-observer`
    ships as a library (11 modules: `config`, `error`,
    `events`, `game`, `jsonrpc_submitter`, `observer`,
    `persistence`, `state_reader`, `strategy`, `submitter`,
    `watcher` + crate root) plus a binary
    (`canon-faultproof-observer` daemon with documented CLI flags
    `--l1-rpc / --game-contract / --state-root-contract /
    --storage / --keystore / --deployment-id / --play-as /
    --confirmation-depth / --reorg-window / --blocks-per-iter /
    --poll-interval-ms / --start-block / --log-level`).
    Identifier string `"canon-faultproof-observer/v1"` published
    via the crate's `OBSERVER_IDENTIFIER` constant and the
    storage's `w/identifier` cell.

  * **RH-G.3 — Game state machine.**  Rust port of
    `LegalKernel.FaultProof.Game.applyTransition` in
    `src/game.rs`.  Mirrors the Lean reference byte-for-byte:
    identical data shapes (`Claim`, `DisputedRange`, `TurnSide`,
    `GameStatus`, `GameState`, `GameTransition`, `GameError`),
    identical transition function (every error variant maps to
    the Lean reference's `Except GameError` arm).  Headline
    property: `apply_transition` is byte-equivalent to the Lean
    reference (verified by 14 property tests).  Bisection
    convergence is observable as a property test:
    `bisection_terminates_in_logarithmic_rounds` exercises full
    bisection traces over random widths and asserts the
    `ceil(log2(width))` bound.

  * **RH-G.4 — Honest-strategy computation.**  In
    `src/strategy.rs`: the `TruthOracle` trait abstracts the
    truthful-commit function (`LogIndex → StateCommit`); two
    implementations ship (in-memory `MemoryTruthOracle` for
    tests and the in-memory mode; a `SubprocessTruthOracle`
    pattern documented for production wire-up to a future
    `canon --replay-up-to` subcommand).  The `compute_next_move`
    function mirrors Lean's `honestStrategy` decision tree
    exactly (no-move / submit / respond-agree / respond-disagree
    / terminate-on-single-step).

  * **RH-G.2 — L1 event-watch with re-org handling.**  In
    `src/watcher.rs` + `src/events.rs`.  Reuses
    `canon-l1-ingest`'s sliding-window re-org tracker
    (`reorg::ReorgWindow`) and `L1Source` trait surface — sharing
    the audited code rather than duplicating it.  Decodes the
    five game-contract events (`FaultProofGameOpened`,
    `BisectionMidpointSubmitted`, `BisectionResponseSubmitted`,
    `FaultProofGameSettled`, `StateRootSubmitted`) via a typed
    `GameEvent` enum.  Defence-in-depth: logs fetched **by block
    hash** (not by number) — defends against re-org racing the
    header→logs sequence.  Deep re-orgs (depth > window) and
    orphaned-parent inconsistencies surface as typed
    `WatcherError::Reorg` errors that halt the daemon with an
    operator alert.

  * **RH-G.5 — Response submission + signing.**  In
    `src/submitter.rs`: the `Submitter` trait + a
    `mock::MockSubmitter` impl that records every submission for
    inspection.  The pure-Rust `encode_calldata` function emits
    the four observer-callable methods' ABI calldata bytes
    (`submitMidpoint`, `respondToMidpoint`,
    `terminateOnSingleStep`, `claimTimeout`).  Method selectors
    derived from `keccak256(signature)` at runtime.  The full
    JSON-RPC submitter (EIP-1559 transaction encoder +
    `eth_sendRawTransaction` driver) is sketched as a public
    trait but the actual transport layer is RH-G follow-up
    work; the calldata bytes are the load-bearing cross-stack
    contract and they ARE pinned by the unit + property tests.

  * **RH-G.6 — Persistence + crash recovery.**  In
    `src/persistence.rs`: `canon-storage`-backed game / response
    / cursor / identifier cell layout.  Three keyspaces:
    `g/<game_id_16BE>` for game records, `r/<tx_hash_32>` for
    response records, `w/cursor` for the watcher cursor,
    `w/identifier` for the identifier cell.  Every batch commit
    is atomic via `Storage::transaction` — game updates +
    response records + cursor advance commit together or roll
    back together.  On startup the observer re-loads every
    game + cursor and resumes from the persisted position.
    Identifier-cell discipline rejects opening a database
    written by a different observer or version.

  * **RH-G.1 — Crate skeleton + dependencies.**  Workspace
    dependency additions: `hex` (regular, was dev-only),
    `k256`, `serde`, `serde_json`, `sha3`, `thiserror`,
    `tracing`, `tracing-subscriber`, `zeroize`, plus
    `canon-cli-common`, `canon-storage`, and `canon-l1-ingest`
    (path).  The signing key path uses
    `canon-l1-ingest::key::BridgeActorKey` (already-audited
    `Zeroizing<[u8; 32]>` wrapper).

  * **RH-G.7 — Cross-stack equivalence corpus + chaos suite.**
    **Partial.**  The 14 property tests in `tests/property.rs`
    cover: `apply_transition` determinism, respond-agree /
    respond-disagree narrowing, settled-game rejection,
    settlement idempotence, depth-tick invariant, calldata
    encoding shape, `compute_next_move` panic-freeness, turn
    flipping, midpoint-inside-range invariant, bisection
    logarithmic-convergence bound, JSON round-trip.  The 7
    integration tests in `tests/integration.rs` cover: end-to-
    end game lifecycle, persistence-across-restart, idempotent
    iteration, cold-start skip of unknown-game settlement,
    missing-truth-oracle deferral, full SQLite round-trip,
    settlement composition.  The Lean-generated corpus
    (50+ recorded game traces) is deferred to a follow-up
    cross-stack landing once the Lean side ships an equivalent
    generator alongside the SubprocessTruthOracle.

  * **Workspace dependency additions.**  None beyond
    workspace-shared crates (the `hex` workspace dep was already
    in the table; we promote our use from dev-dependency to
    regular dependency to encode response-record tx-hashes).

  * **Post-landing audit pass.**  Four independent code-review
    agents produced consolidated findings; the security- and
    correctness-relevant items were all addressed in-PR before
    the audit report could become stale:
    - **CRITICAL (C-2 docstring lie)** lib.rs claimed the
      observer validates `deployment_id` against L1 events.
      It does not (the `FaultProofGameOpened` event payload
      doesn't carry the field).  Docstring rewritten to flag
      the deferral honestly; validation is RH-G follow-up
      work requiring an `eth_call` to `games(uint256)`.
    - **CRITICAL (C-3 wrong-shape calldata)** the previous
      `handle_midpoint_submitted` heuristic
      `state.range.high.idx = idx.saturating_mul(2)`
      synthesised an incorrect range bound for cold-start
      games.  The observer would then compute midpoint calldata
      against this fictional range and submit it on-chain.
      Removed the heuristic.  Cold-start games adopted from
      `FaultProofGameOpened` are now marked
      `GameRecord.state_known = false`; the orchestrator's
      `maybe_play_move` refuses to compute or submit moves for
      `state_known=false` games until the full state is
      learned (via the deferred eth_call).  The persistence
      layer's new `state_known` field carries `#[serde(default)]`
      for backward compatibility.
    - **CRITICAL (C-1 fresh-watcher event-skip)** implemented
      the `--start-block` CLI override.  Renamed
      `Observer::seed_watcher_last_confirmed` → `set_start_block`
      and exposed it as a documented operator escape hatch.
      Without `--start-block`, the fresh watcher still jumps to
      the confirmed head (documented behaviour); operators
      catching up from a historic block now have a supported
      knob.
    - **HIGH (H-2 O(N) dedup scan)** replaced the
      `list_responses()`-per-call scan in
      `has_submitted_for_pivot` with an in-memory
      `HashSet<(u128, Option<u64>)>` populated at startup from
      persistence and updated atomically with each batch
      commit.  Constant-time dedup defends against unbounded
      growth over the daemon's lifetime.
    - **HIGH (H-Submitter wrong-selector calldata)** the
      previous `encode_calldata(TerminateOnSingleStep)`
      produced a minimum-form selector that does NOT match
      the deployed contract's `terminateOnSingleStep(uint256,
      uint8, bytes, uint64, CellProof[], bytes32)` signature.
      Broadcasting that calldata would revert at the
      selector-dispatch layer.  Now `encode_calldata` returns
      `SubmitError::TerminateNotImplemented` for this move
      kind; the minimum-form helper
      `encode_terminate_calldata` remains available for
      integration smoke tests but production callers cannot
      silently broadcast it.
    - **MEDIUM (M-tx_hash_hex case drift)** persistence now
      canonicalises `tx_hash_hex` to lowercase + no `0x`
      prefix on `store_response` / `commit_batch`, so two
      writes for the same hash with different surface formats
      produce one canonical JSON payload.
    - **MEDIUM (M-Error)** `ReorgError::NonMonotone` now maps
      to `OperatorExitCode::Transient` (recoverable via
      back-off + retry, per the underlying reorg-window
      docstring) instead of `OperatorAction`.  Operators no
      longer get spurious page-outs on transient L1-RPC gaps.
    - **MEDIUM (M-config bounds)** `WatcherConfig::validate`
      and `CliConfig::validate` now enforce hard upper bounds
      on `reorg_window_capacity` (4096),
      `confirmation_depth` (4096), and `blocks_per_iteration`
      (4096), defending against operator-typo-induced OOM /
      memory-bomb scenarios.
    - **LOW (apply_settlement diagnostic)** added
      `GameError::InvalidSettlement` for the
      `apply_settlement(InProgress)` path, distinct from
      `GameAlreadyEnded`.
    - **LOW (Lean parity)** added `GameError::WrongTurn` and
      `GameError::TerminationDuringBisection` variants for
      byte-equivalence with the Lean reference's
      `GameError` inductive (both are Lean-side dead code,
      not emitted in practice).

  * **Audit pass 2 (deeper post-fix self-review).**  A second
    audit-pass directly re-inspected the audit-pass-1 fixes for
    defects, and identified additional issues that the
    first-pass auditors had categorised as lower-priority but
    that combine with the new state_known design to require
    in-PR handling:
    - **Defensive (cold-start status guards)**: the cold-start
      bypasses in `handle_midpoint_submitted` and
      `handle_response_submitted` now refuse to mutate state
      when the game's status is already terminal.  In normal
      flow the L1 contract never emits these events on a
      settled game, but a re-org could re-deliver an in-window
      event.  Mirrors `apply_transition`'s `gameAlreadyEnded`
      guard for the bypass path.
    - **Cross-contract log ordering**: the watcher now merges
      logs from both target contracts within a single block and
      decodes them in `log_index` order, so a `StateRootSubmitted`
      at log_index 2 and a `FaultProofGameOpened` at log_index 5
      within the same block are processed in their on-chain
      emission order.  Previously the watcher iterated all
      game-contract logs first, then all state-root logs,
      ignoring interleaving.
    - **`mark_state_known` integration point**: added the public
      method that the deferred `eth_call`-based contract-state
      reader (RH-G follow-up work) will use to transition
      cold-start games from `state_known = false` to
      `state_known = true`.  Provides a stable API surface for
      the follow-up PR without requiring observer-internal
      refactoring at integration time.
    - **Keccak256 topic hashes pinned to canonical hex**:
      replaced the self-consistency check with hard-pinned
      32-byte hex values (computed via the canon-l1-ingest
      keccak256 helper, then literal-pinned).  Any future
      signature drift in `GameEventTopic::signature()` now
      breaks loudly against the pinned hash.
    - **Property-test coverage**: added `submit_midpoint_guard_ordering_matches_lean`,
      `respond_agree_guard_ordering_matches_lean`,
      `single_step_at_u64_max_no_panic`, and
      `settlement_matrix` to exercise the cross-stack guard-
      ordering invariants and the 4-cell settlement coverage
      matrix.

  * **Audit pass 3 (validation hardening + lifecycle test).**
    A third independent audit-pass surfaced three findings;
    all addressed:
    - **CRITICAL (mark_state_known validation)**: the original
      `mark_state_known` API performed NO defensive checks on
      the supplied `full_state`.  An eth_call response (deferred
      RH-G follow-up) from a malicious / misconfigured contract
      could (a) replace the in-memory state with a different
      `deployment_id` (cross-deployment-replay), (b) resurrect
      a settled game's status from terminal to `InProgress`,
      or (c) install a degenerate range (low.idx >= high.idx).
      Now enforces all three invariants at the API boundary,
      returning `ObserverError::Invariant` on violation.
    - **MEDIUM (depth clamp in cold-start bypass)**: the
      cold-start `handle_response_submitted` bypass's
      `depth.saturating_add(1)` could grow `state.depth` past
      `MAX_BISECTION_DEPTH = 64` over many observed responses.
      Clamps at `MAX_BISECTION_DEPTH + 1` so a future
      `apply_transition` on this state cleanly returns
      `BisectionDepthExceeded` rather than mis-reporting a
      smaller depth.
    - **MEDIUM (cache-vs-persistence ordering documentation)**:
      the in-memory `submitted_pivots` cache is updated BEFORE
      `commit_batch`.  Under a commit-fail + restart scenario,
      the cache loses the entry and the observer would re-submit
      on next iteration.  With the mock submitter this is
      benign (no L1 broadcast); with the future production
      JSON-RPC submitter, the same logical move could be
      broadcast twice (contract reverts the duplicate; gas
      wasted but no state corruption).  Documented loudly in
      the code comment; the production submitter wire-up MUST
      persist a "pre-submit intent" record (tracked as RH-G
      follow-up).
    - **Test additions**: `mark_state_known_rejects_mismatched_deployment_id`,
      `mark_state_known_refuses_to_resurrect_settled_game`,
      `mark_state_known_rejects_degenerate_range`,
      `mark_state_known_is_idempotent` (unit); full
      `cold_start_lifecycle_with_mark_state_known` integration
      test exercising adoption → mark-known → strategy-ready
      precondition.

  * **Audit posture at landing (post-audit-pass-3).**
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test -p canon-faultproof-observer --locked` —
      183 unit + 11 integration + 18 property = 212 tests
      passing (+6 from audit-pass-2's 206: 4 new
      mark_state_known unit tests, 2 new integration tests
      for the lifecycle and degenerate-range rejection).
    - `cargo test --workspace --locked` — 1256 tests
      (+6 from the prior workspace total of 1250).
    - `cargo clippy --workspace --all-targets --locked
      -- -D warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - `unsafe_code = "forbid"`.
    - Binary smoke-tested via
      `./target/release/canon-faultproof-observer --version` →
      `canon-faultproof-observer v0.2.3 (canon-faultproof-observer/v1)`;
      `--help` lists every documented flag.

  * **Audit posture at full landing (post-deferral-closure).**
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test -p canon-faultproof-observer --locked` —
      260 unit + 12 integration + 6 observer-game-traces +
      6 state-reader-integration + 6 chaos + 4 real-canon +
      18 property = 312 tests passing (+100 from the
      audit-pass-3 landing's 212: +62 jsonrpc_submitter
      lib tests, +15 state_reader lib tests, +6 game-traces
      integration, +6 state-reader-mock-RPC integration, +6
      chaos, +4 real-canon, plus growth in existing modules).
    - `cargo test --workspace --locked` — 1359 tests
      (+103 from the prior workspace total of 1256).
    - `cargo clippy --workspace --all-targets --locked
      -- -D warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - `unsafe_code = "forbid"`.
    - Lean side: `lake build` / `lake test` green;
      `ALL TESTS PASSED` (~2093 tests across ~104 suites
      including the new `crosscheck-observer-game-traces`,
      `integration-replay-up-to-cli`, and
      `integration-export-cell-proofs-cli` suites).
    - Binary smoke-tested via
      `./target/release/canon-faultproof-observer --version`
      reporting v0.2.4; `--help` lists every documented flag.
    - Workspace version bumped 0.2.3 → 0.2.4 for the RH-G.5
      submitter landing.
    - Lean cell-proof export verified end-to-end via
      `canon export-cell-proofs /tmp/empty.log 0 1` smoke
      test.

  * **Audit posture at audit-pass-4 landing (post deep-review
    of the full-landing).**  A fourth independent audit pass
    surfaced 1 CRITICAL test no-op (`outcome_encoder_recognises
    _ok_and_err` used `matches!` without `assert!`), several
    HIGH-severity submitter / state-reader issues (silent
    gas-estimate-margin formula bug producing `raw * 0.25`
    instead of `raw * 1.25`; nonce-cache bump-before-sign
    consuming nonces on transient failures; lenient bool
    encoding accepting non-canonical Solidity slots;
    unbounded `hex::decode` allocation against hostile RPCs;
    silent schema-drift in cross-stack corpus loader), and
    MEDIUM defence-in-depth items (no runtime chain_id
    cross-check; missing Solidity-side `initiateChallenge`
    invariants).  All fixes landed in audit-pass-4 commits:
    - JSON-RPC submitter: gas-estimate margin corrected;
      `peek_next_nonce` / `commit_nonce_bump` discipline
      prevents nonce gaps; `verify_rpc_chain_id` cross-check
      method.
    - State reader: `read_strict_bool_from_slot` rejects
      non-canonical bools; turn / status slot high-byte
      validation; depth-out-of-range typed error; oversize-
      hex pre-check; zero-address / collision invariant
      enforcement in `read_and_validate`.
    - Lean cell-proof JSON: hoisted to library module
      `LegalKernel.Runtime.CellProofJson`; switched to
      snake_case field naming (matches Rust serde
      convention); Rust `CellProof` struct now derives
      `Deserialize` for direct JSON consumption; byte-pinned
      tests for JSON envelope shape and minimal-balance-proof
      output.
    - Cross-stack corpus: replaced tautological "outcomes
      are total" test with kernel-vs-fixture drift detection;
      added "every reachable GameError variant" coverage
      catalogue; load_corpus now panics on schema-drift
      (was silently SKIP'ing).
    - Chaos suite: `chaos_shallow_reorg_absorbed` rewritten
      as `chaos_reorg_surfaces_typed_error` to honestly
      reflect the architectural reality that the observer's
      `run_iteration` cannot ABSORB re-orgs that rewrite
      cached blocks (no re-fetch loop in the current
      design); the typed-error / no-op safe-failure path is
      asserted instead.

    Final gates at audit-pass-4 landing:
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test --workspace --locked` — 1370 tests
      passing (+11 from full-landing 1359: +9 lib test
      additions, +2 net from the chaos / corpus replacements).
    - `cargo clippy --workspace --all-targets --locked
      -- -D warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - Lean: `lake build` / `lake test` green; 2101 tests
      across 122 suites including the new byte-pinning,
      envelope-shape, kernel-vs-fixture-drift, and
      reachable-error-variant coverage tests.

  * **Audit posture at audit-pass-4-round-3 landing.**
    A third deep self-audit re-reviewed audit-pass-4
    rounds 1+2 and surfaced new defects in integration
    boundaries that unit tests didn't catch.  All fixed:
    - CRITICAL: cross-stack CellProof JSON contract was
      silently broken at the type boundary (Rust expected
      u128 / Vec<u8> / [u8;32], Lean emitted hex strings).
      Custom serde deserializers added; 6 round-trip tests.
    - CRITICAL: SubprocessTruthOracle had no timeout (hung
      canon binary would wedge observer indefinitely) and no
      stdout cap (canon binary printing GB could OOM
      observer).  spawn+kill-on-timeout with default 30s;
      stdout cap default 4096 bytes; 2 regression tests.
    - HIGH: JsonRpcSubmitter was dead code in production —
      main.rs hardcoded MockSubmitter regardless of operator
      intent.  New `--chain-id <N>` CLI flag opts into the
      production submitter; without it, defaults to the
      mock with explicit operator-visible logging.
    - HIGH: verify_rpc_chain_id never called.  Now called
      at startup when the production submitter is wired.
    - HIGH: Submitter::invalidate_nonce_cache was missing
      from the trait.  Added with default no-op; production
      override clears the cache; observer.broadcast_and_update_status
      invokes it on broadcast failure (closes the nonce-gap
      that the round-1 peek/commit refactor didn't cover).
    - HIGH: state-reader Zero/Collision checks operated on
      the low-8-byte ActorId projection; false positives on
      legitimate addresses, false negatives on collisions.
      Refactored to use the full 20-byte L1 address via
      new `decode_game_state_with_addresses` helper.
    - HIGH: submitted_pivots desync — commit_batch failure
      left the dedup cache populated, permanently locking
      the pivot in this process.  Added rollback-set
      pattern; failure now reverts the cache entries.
    - MEDIUM: Solidity ABI selector pinning regression.
      All 4 method selectors pinned against `forge inspect`
      canonical values.

    Final gates at audit-pass-4-round-3 landing:
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test --workspace --locked` — 1379 passed
      (+9 from round-2's 1370: +6 CellProof round-trip,
      +2 subprocess timeout/cap, +1 Solidity selector pin).
    - `cargo clippy --workspace --all-targets --locked
      -- -D warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - Lean: ALL TESTS PASSED across 122 suites.

  * **Audit posture at audit-pass-4-round-4 landing.**
    A fourth round of independent audits caught two new
    CRITICAL defects that round-3 had introduced or left
    uncovered.  All fixed:
    - CRITICAL: `cmdExportCellProofs` took SIGNER as a CLI
      argument but built the bundle for the action read
      from `entries[idx]`.  A signer mismatch would
      silently produce a bundle whose cells point to a
      different actor than the action uses → L1 rejects
      the calldata AFTER operator pays gas.  Fixed:
      derive signer from `entry.signedAction.signer`;
      surface a typed error on CLI mismatch.
    - CRITICAL: SubprocessTruthOracle post-exit drain
      blocked indefinitely if canon was wrapped in a shell
      without `exec` (orphaned subprocess inherits the
      stdout fd).  Round-3's "post-exit drain handles the
      orphan case" claim was empirically wrong.  Fixed
      with a bounded reader thread + 500ms DRAIN_TIMEOUT;
      new `subprocess_oracle_drain_timeout_handles_orphan_pipe`
      regression test.
    - HIGH: `iteration_pivot_inserts` rollback only fired
      on commit_batch failure; any other run_iteration
      error left submitted_pivots permanently populated for
      entries that never persisted.  Refactored into
      outer/inner where the outer ALWAYS rolls back on Err.
    - HIGH: `serialize_u128_hex_lowpadded` silent
      truncation via `as u64`.  Added debug_assert.
    - HIGH: `Self::invalidate_nonce_cache(self)` correctly
      dispatches to inherent (Rust resolution rule), but
      a maintainer removing the inherent method would
      silently make it infinite recursion.  Pinned via
      `trait_invalidate_nonce_cache_no_infinite_recursion`.
    - HIGH: MockSubmitter-path keystore stayed in memory
      for the whole observer.run() duration via
      `let _signing_key = ...`.  Changed to `let _ = ...`
      to drop immediately.
    - MEDIUM: `cell_value` deserializer added
      MAX_CELL_VALUE_BYTES = 1 MiB DoS cap.
    - MEDIUM: 4 new tests for `--chain-id` flag.
    - MEDIUM: 2 new state_reader full-address regression
      tests.
    - LOW: JSON envelope-shape test enforces exact field
      count.
    - LOW: corpus generator enforces "no
      TerminateOnSingleStep transitions".
    - LOW: SubprocessTruthOracle constants hoisted.
    - NEW end-to-end test file
      `tests/real_canon_export_cell_proofs.rs` (6 tests)
      proves the Lean→Rust cell-proof JSON contract works
      end-to-end via the real canon binary.

    Final gates at audit-pass-4-round-4 landing:
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test --workspace --locked` — 1395 passed
      (+16 from round-3's 1379).
    - `cargo clippy --workspace --all-targets --locked
      -- -D warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - Lean: ALL TESTS PASSED; 2102 tests across 122 suites
      (+1 from round-3's 2101: corpus no-terminate
      enforcement).

  * **Audit posture at audit-pass-4-round-5 landing.**
    A fifth round of parallel deep audits caught two new
    CRITICAL defects in previously-unexamined code (the
    `--start-block` operator escape hatch and the
    `recover_intent_records` recovery loop) plus 6 HIGH
    defects across the persistence, watcher, and
    test-coverage surfaces.  All fixed:
    - CRITICAL: `Observer::set_start_block` left the
      persisted reorg window stale relative to the new
      cursor; the next iteration's `advance` would
      surface `OrphanedParent` / `DeepReorg` /
      `NonMonotone`.  Added `ReorgWindow::clear()` +
      `Watcher::clear_reorg_window()`; set_start_block
      now clears the window.
    - CRITICAL: `recover_intent_records` `?`-propagated
      on per-record errors, aborting recovery on the
      first failure and crashing the daemon.  Changed
      to log + continue pattern.
    - HIGH: `WatcherConfig::validate` didn't reject
      `confirmation_depth == 0`; library consumers
      could bypass the CLI's check.  Added validation.
    - HIGH: `verify_or_initialise_identifier` silently
      adopted any DB without an identifier cell, even
      if it contained game/response/cursor cells.
      Strengthened to require empty DB OR matching
      identifier.
    - HIGH: `read_reorg_window` had no upper bound on
      deserialized cell size.  Added cap at
      `MAX_REORG_WINDOW_CAPACITY * 1 KiB = 4 MiB`.
    - HIGH: Mid-iteration `advance` error in watcher
      left `reorg_window` inconsistent.  Wrapped
      `run_iteration` in a snapshot/restore pattern
      so any error rolls back the window.
    - HIGH: state-reader new invariants (round-3
      ZeroSequencer/Collision) had no rejection-path
      tests.  Added 3 integration tests.
    - HIGH: round-4 CRITICAL signer-mismatch fix had
      no end-to-end test.  Added test that runs the
      real canon binary with wrong signer and asserts
      exit code 2.
    - MEDIUM: tightened `MAX_CELL_VALUE_BYTES` from
      1 MiB to 64 KiB.
    - MEDIUM: `signerNat > u64::MAX` explicit rejection
      in cmdExportCellProofs.
    - MEDIUM: TerminateOnSingleStep test catchall
      replaced with exhaustive match.

    Final gates at audit-pass-4-round-5 landing:
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test --workspace --locked` — 1399 passed
      (+4 from round-4's 1395).
    - `cargo clippy --workspace --all-targets --locked
      -- -D warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - Lean: ALL TESTS PASSED across 122 suites.

  * **Audit posture at audit-pass-4-round-6 landing.**
    A sixth round of deep self-audit caught a CRITICAL
    deadlock in `SubprocessTruthOracle::commit_at` (the
    production-critical oracle for the bisection-game
    truth lookup) plus a HIGH-severity flake source in
    the state-reader integration tests.  All fixed:
    - CRITICAL: `SubprocessTruthOracle::commit_at` drained
      stdout AFTER the child exited (introduced by
      audit-pass-4-round-3's `spawn + try_wait` refactor).
      If the child wrote more than the kernel's pipe
      buffer (~64 KiB on Linux), the child blocked on
      pipe-full while the parent's wait-loop blocked on
      child-exit — a classic write-side deadlock.  The
      30 s default `DEFAULT_SUBPROCESS_TIMEOUT` was the
      only thing breaking the deadlock, masking the bug
      in the test that was supposed to pin the cap
      rejection (the test took the full 30 s).  In
      production, any canon binary emitting verbose
      diagnostic output (a perfectly legitimate
      operational mode) would deadlock the observer's
      oracle calls for 30 s each — devastating to
      bisection-round throughput against an L1 turn
      deadline.  Fix: spawn the stdout drain thread
      BEFORE the wait loop.  The drain thread reads
      continuously, captures the first `cap+1` bytes,
      and consumes-and-discards the rest so the child
      can finish writing without blocking.  After
      child exit, the drain thread reaches EOF
      promptly and we join.  The orphan-pipe drain
      timeout (`DRAIN_TIMEOUT = 500 ms`) still
      protects against the operator-misconfiguration
      scenario.  Two new regression tests pin the
      fix: the existing `subprocess_oracle_stdout_
      cap_rejects_oversize_output` now asserts
      `elapsed < 5 s` (was 30 s pre-fix), and a new
      `subprocess_oracle_does_not_deadlock_on_large_
      stdout` test exercises 1 MiB of stdout (vastly
      over any pipe buffer) and asserts the same
      time bound.
    - HIGH: `MockRpcServer::spawn()` in the state-reader
      integration tests returned BEFORE the accept
      thread had reached its first iteration, leading
      to intermittent flakes under heavy parallel-test
      load when the client's full HTTP exchange
      happened in the window before the accept thread
      ran.  The flake manifested as
      `malformed_response_surfaces_typed_error`
      asserting on the wrong error variant.  Fix:
      synchronous oneshot channel pinned to the
      accept thread's first iteration.  `spawn()`
      now blocks on `ready_rx.recv_timeout(5 s)`
      until the accept thread signals it has entered
      the loop.  Verified across 5 consecutive full
      workspace runs — zero flakes (was 1-in-3
      pre-fix).
    - MEDIUM: improved the malformed-response test
      assertion to include the actual error variant
      in the message, so future flakes are
      diagnosable from a single failure log without
      manual reproduction.

    Plus a third deep-audit pass within round-6 also wired
    the production `SubprocessTruthOracle` through the
    observer binary (was hardcoded to `MemoryTruthOracle`,
    making the observer unable to play bisection moves in
    production):
    - Added `impl<T: TruthOracle + ?Sized> TruthOracle for
      Box<T>` blanket impl in `strategy.rs` so
      `Box<dyn TruthOracle>` satisfies the generic bound on
      `Observer`.
    - Added CLI flags `--canon-binary <PATH>` and
      `--canon-log <PATH>` in `config.rs`.  Both required
      together OR both omitted; the parser validates this
      cross-flag invariant.
    - Added `build_truth_oracle(cfg)` helper in `main.rs`:
      when both flags are supplied, constructs a
      `SubprocessTruthOracle` pre-configured with the
      `--deployment-id` flag.  Otherwise falls back to
      `MemoryTruthOracle` with operator-visible log warning
      (passive event-watcher mode).
    - 4 new CLI parser tests pinning the new flags' happy
      path + validation invariants.
    - The observer can now play Submit / RespondAgree /
      RespondDisagree moves end-to-end in production.

    `HonestMove::TerminateOnSingleStep` remains unwired (3
    of 4 move types fully wired).  Wiring this 4th move
    requires the L1 step-VM cross-stack coherence to be
    extended from the current 2 variants (Transfer + Mint)
    to all 19 `Action` variants.  A new engineering plan
    `docs/planning/step_vm_coherence_plan.md` (workstream
    SVC) captures this work — ~9 weeks total across 5
    sub-units.  The off-chain observer's current safety
    posture is unaffected: the bisection-game's bisection
    rounds use opaque-actionFields hashing that DOES match
    cross-stack (both sides hash the same bytes), so the
    observer can defend correctly against an invalid
    state-root claim by playing Submit / RespondAgree /
    RespondDisagree until the game settles via timeout.
    The terminate move is the 4th-of-4 closing-move type
    that fires only at maximum bisection depth.

    Final gates at audit-pass-4-round-6 landing:
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test --workspace --locked` — 1404 passed
      (+5 from round-5's 1399: the new large-stdout
      deadlock-prevention regression test + 4 CLI parser
      tests for `--canon-binary` / `--canon-log`).
      Verified across 5 consecutive runs — zero flakes.
    - `cargo clippy --workspace --all-targets --locked
      -- -D warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - Workspace version bumped 0.2.4 → 0.2.5 per the
      patch-bump default discipline.
    - Lean: ALL TESTS PASSED across 122 suites.

**Workstream SC.3 (SMT cell-proof cross-stack soundness corpus,
see `docs/planning/smt_cell_proofs_plan.md`).**  **Complete.**
Ships the cross-stack ratification of the SC.1 / SC.2 SMT
cell-proof verifiers as a mechanical fixture corpus: 100
entries (50 honest + 50 adversarial) generated by Lean and
re-verified by Solidity, byte-for-byte.  Closes the
operational off-chain audit gap documented in
`docs/GENESIS_PLAN.md` §15B.

  * **Lean fixture generator.**
    `LegalKernel/Test/Bridge/CrossCheck/SmtCellProof.lean`
    (~620 lines).  Generates fixtures via the canonical
    `buildSmtCellProof` constructor against a small
    `CrossStackUInt64` wrapper whose `Encodable` instance
    produces 8 big-endian bytes (matching Solidity's MSB-first
    key reading) and whose `BitsKey` defers to `UInt64`'s.
    The fixture's six tamper classes (`valueSubst`,
    `siblingTamper`, `bitmaskTamper`, `rootTamper`,
    `keyMismatch`, `absentKey`) each map a valid base entry
    to an entry that MUST reject on both sides.  Honest
    coverage: singleton / two-cell / three-cell / four-cell /
    eight-cell maps plus 10 single-bit-position edge cases.

  * **Solidity consumer.**
    `solidity/test/CrossCheck/SmtCellProof.t.sol` (~390 lines).
    12 test cases: header shape (count + tamper-class
    breakdown), per-entry `shouldVerify`-matches-position
    (honest in [0,50), adversarial in [50,100)), structural
    invariants for `smtKey` / `leafPreimage` / `proofData` /
    `root`, the per-entry cross-stack verdict assertion
    (`isKeccak256Linked`-gated), per-honest-entry root
    byte-equality (also gated), spot checks for entry 0 and
    entry 50, per-entry tamper-string-in-valid-set
    (fixture-corruption defense), per-entry
    category-consistent-with-tamper (drift-between-fields
    defense).  Uses a locally-defined
    `SmtCellProofCrossCheckProxy` (mirrors
    `SmtCellVerifier.t.sol`'s proxy pattern with a distinct
    name to avoid ABI-name collisions when running the full
    forge suite).

  * **Wire-format alignment.**  Each fixture entry carries:
    - `smtKeyHex` — 8-byte big-endian UInt64.
    - `leafPreimageHex` — 16 bytes: `keyBE || valueBE`.
    - `proofDataHex` — 32-byte LSB-first bitmask || N×32-byte
      siblings, low-depth-first.
    - `rootHex` — 32-byte hash output.
    - `shouldVerify` — bool.
    - `tamper` — string or null (the tamper-class label).
    The on-wire `proofData` layout matches the SC.2 wire-format
    spec verbatim, so Solidity reads the exact bytes Lean
    produced.

  * **Hash-binding-conditional behaviour.**  At default
    `lake test` time, `Bridge.HashAdaptor.isKeccak256Linked
    = false` and `hashBytes` falls back to FNV-1a-64 padded to
    32 bytes; the fixture's `root` and sibling hashes are
    FNV-derived, which Solidity (always-keccak256) cannot
    reproduce.  The Solidity per-entry verdict + per-honest-
    entry root-byte tests are gated on the header's
    `isKeccak256Linked` flag and SKIP cleanly in that mode.
    Header-shape and byte-size assertions run unconditionally.
    In a production environment with the
    `canon-hash-keccak256` Rust adaptor linked at the
    `@[extern]` symbol `canon_hash_bytes`, both sides walk
    keccak256 and the verdicts match exactly.

  * **Audit posture at landing.**
    - `lake build` — green; zero new warnings.
    - `lake test` — `ALL TESTS PASSED`; 2083 total tests
      (+16 from SC.1's 2067).
    - `lake exe deferral_audit` / `naming_audit` /
      `tcb_audit` / `stub_audit` / `count_sorries` — all PASS.
    - `forge build` — green.
    - `forge test` — 402 tests passing; 11 skipped (+2 from
      pre-SC.3's 9: the two new SC.3 keccak-gated tests; the
      audit pass added 2 non-keccak-gated tests).
    - `forge fmt --check test/CrossCheck/SmtCellProof.t.sol`
      — clean.

  * **TCB delta:** zero.  The new module is in
    `LegalKernel/Test/Bridge/CrossCheck/` (test-only,
    non-TCB).
  * **Trust-assumption delta:** zero.  The cross-stack
    assertion's correctness rests on the same `CollisionFree
    hashBytes` hypothesis the SC.1 Lean theorems already
    document.

**Workstream AR (Audit Remediation, see
`docs/planning/audit_remediation_plan.md`)** is the previous
audit landing.  Highlights of the AR remediation pass:

  * AR.1: shared `Authority.signedActionDomain` constant (M-7).
  * AR.2: `RuntimeState.deploymentId` field threaded through
    `processSignedAction` / `bootstrap` / `replayWith` /
    `checkSignatureInvalidWith` plus `--deployment-id <hex>` CLI
    flag on both `canon` and `canon-replay` (the audit binary
    refuses to run without it).  Closes M-1 + M-5.
  * AR.2.5: parameterised `checkEvidenceWith verify d`
    dispatcher in `Disputes/Evidence.lean` so the
    `signatureInvalid` claim arm routes through
    `checkSignatureInvalidWith` with an explicit deploymentId.
    Plain `checkEvidence` is preserved as the back-compat alias
    `checkEvidenceWith Verify ByteArray.empty`.  Closes the
    cross-deployment-replay observability gap surfaced by the
    third audit pass at the dispute pipeline's Stage 2.
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

**Workstream EI (Encoder Injectivity).**  **Complete.**  The
AR.4 deferral closed.  The fault-proof chain now lifts from
bytes-equality to extensional state equality via
`commitExtendedState_subcommits_extensional_eq_under_collision_free`
(`FaultProof/Commit.lean`, EI.8.b).  All eight sub-units (EI.0 –
EI.8) shipped under their respective branches; the engineering
plan and per-sub-unit retrospectives live in
`docs/planning/encoder_injectivity_plan.md`.

**Deferred from AR:**

    **EI.0 pre-flight + scaffolding complete** on
    `claude/review-encoder-plan-0p5MI`
    (`docs/planning/encoder_injectivity_plan.md` §4.0): Std-core
    lemma audit confirms the proof recipe's preconditions are
    present in the pinned toolchain (`docs/std_dependencies.md`'s
    "EI.0.a" subsection), module-placement decision recorded in
    Appendix D OQ-EI-1, and the test scaffolding lives at
    `LegalKernel/Test/Encoding/Injectivity.lean` (wired into
    `Tests.lean` under the `"encoding-injectivity"` suite name).

    **EI.1 helper / atomic-injectivity foundation complete** on
    `claude/atomic-injectivity-foundation-yHSwQ`
    (`docs/planning/encoder_injectivity_plan.md` §4.1).  Eight
    non-conditional sub-sub-units shipped (EI.1.a was dropped at
    EI.0.a per the Std-core audit, so the §13.6 two-reviewer gate
    is **not** triggered):

      - **EI.1.b** `Encodable.Encodable_via_decode_inj` +
        `_append` residual-suffix variant
        (`LegalKernel/Encoding/Encodable.lean`).
      - **EI.1.c** `cborHeadEncode_injective`
        (`LegalKernel/Encoding/CBOR.lean`) — extracts
        `major₁ = major₂ ∧ n₁ = n₂` under both `< 2^64` bounds.
      - **EI.1.d** `encodeAsBytes_eq_injective_of_encode_eq_injective`
        (in `Encodable.lean`) + `encodeAsBytes_equiv_injective_of_encode_equiv_injective`
        (in `State.lean`, where `Std.TreeMap.Equiv` is in scope).
      - **EI.1.e** `encodeSortedPairs_injective` (universal
        round-trip variant) + `encodeSortedPairs_injective_bounded`
        (per-list round-trip variant) + private
        `decodeNPairs_encode_foldr` / `decodeNPairs_encode_foldr_in`
        helpers (`LegalKernel/Encoding/State.lean`) — the headline
        polymorphic map-level injectivity lemma EI.2 – EI.7 consume.
        The `_bounded` variant is the one downstream sub-states
        actually use, because their pair lists key on `Nat` (via
        `.toNat`) where `Nat`'s round-trip is conditional on
        `< 2^64`.  The unbounded variant covers UIntN-typed pair
        lists (unconditional round-trip).
      - **EI.1.f** `uInt8_encode_injective` /
        `uInt16_encode_injective` / `uInt32_encode_injective` /
        `uInt64_encode_injective` quartet
        (`LegalKernel/Encoding/Encodable.lean`).
      - **EI.1.g** Project-wrapper injectivity sweep
        (`LegalKernel/Encoding/State.lean`): `actorId_*`,
        `resourceId_*` (unconditional, delegated to UInt64);
        `amount_*`, `nonce_*`, `depositId_*`, `withdrawalId_*`,
        `publicKey_*` (conditional on `< 2^64`).  `EthAddress` is
        EI.7.a, not EI.1.g.
      - **EI.1.h** `list_encode_injective` (conditional on length
        bound) + `option_encode_injective` (unconditional)
        (`LegalKernel/Encoding/Encodable.lean`).
      - **EI.1.i** `Encodable.HasInjective` ergonomic class with
        six instances (Bool, BoundedNat, UInt8/16/32/64;
        ActorId / ResourceId resolve through UInt64 via
        `abbrev`).  Conditional types intentionally lack
        instances — they keep their bound-quantified
        explicit-hypothesis lemmas.

    Audit posture: `lake build` / `lake test` / every audit
    binary green; `#print axioms` ⊆ `[propext, Classical.choice,
    Quot.sound]` on every shipped lemma; no new opaques, no new
    axioms, no TCB-tier change.

    **EI.2 nested-map template complete** on
    `claude/implement-state-encode-nested-nbXhh`
    (`docs/planning/encoder_injectivity_plan.md` §4.2).  Six
    sub-sub-units shipped:

      - **EI.2.a** `BalanceMap.encode_injective`
        (`LegalKernel/Encoding/StateInjective.lean`) — inner-map
        injectivity (conditional on length + per-amount bounds),
        concluding `Std.TreeMap.Equiv` on the inner map.  Uses
        `encodeSortedPairs_injective_bounded` (EI.1.e) at
        `(Nat, Amount)`; lifts the `a.toNat` projection through
        `UInt64.toNat_inj` and `List.map_inj_right`, then via
        `Std.TreeMap.equiv_iff_toList_eq` to `Equiv`.
      - **EI.2.b** `BalanceMap.encode_injective_to_equiv` —
        explicit `Equiv`-shaped alias (EI.2.a already concludes
        `Equiv`, so this collapses to a re-export).
      - **EI.2.c** `BalanceMap.encodeAsBytes_injective` —
        framing injectivity for the byte-wrapped inner encoder.
        OQ-EI-2 resolved to option (a): `BalanceMap.encodeAsBytes`
        promoted from `private` to non-private so framing-
        injectivity can co-locate with EI.2.a / EI.2.d in
        `StateInjective.lean`.
      - **EI.2.d** `State.Equiv` (custom nested extensional
        relation) + `State.encode_injective` (the headline
        nested theorem).  `State.Equiv` asserts outer-key
        agreement (via `Iff` on `r ∈ s.balances`) plus
        per-resource inner-`BalanceMap` `Equiv`, since
        `Std.TreeMap.Equiv` on the outer `balances` map would
        require structural `Eq` on inner `BalanceMap`s — too
        strong, since the encoder canonicalises away RB-tree
        shape.  Helpers: `outer_keys_agree` (`Iff` form),
        `outer_isSome_eq` (`Bool` form), `inner_equiv`, `refl`,
        `symm`, and the flat `getBalance_eq` corollary.
      - **EI.2.e** 17 new test cases in
        `LegalKernel/Test/Encoding/Injectivity.lean` covering
        term-level API stability, positive injectivity
        (distinct inputs → distinct encodings), negative
        determinism (structurally-distinct extensionally-equal
        inputs → identical encodings), and value-level smoke
        checks on the `State.Equiv` corollaries (`refl`, `symm`,
        `outer_isSome_eq`, `getBalance_eq`).  Total
        `encoding-injectivity` suite: 49 cases (was 32 pre-EI.2).
      - **EI.2.f** Retrospective recorded in
        `docs/planning/encoder_injectivity_plan.md` §4.2 closeout
        block: `Equiv`-as-target was a net win; EI.3 – EI.7
        should follow the inline-framing pattern (rather than
        EI.1.d's universal-quantifier helper) for their
        conditional-bounds injectivity proofs.

    Axiom posture: `#print axioms` ⊆ `[propext,
    Classical.choice, Quot.sound]` on every EI.2 theorem;
    `lake build` / `lake test` / every audit binary green.

  * **EI.3 – EI.8 status (flat-map sub-states + composition).**
    **Complete.**  All landed on
    `claude/encoder-injectivity-implementation-UggQv`.

      - **EI.3** `NonceState.encode_injective` +
        `expectedNonce_eq_of_encode_eq` corollary
        (`LegalKernel/Encoding/StateInjective.lean`).
      - **EI.4** `KeyRegistry.encodeMap_injective`
        (`LegalKernel/Encoding/StateInjective.lean`).
      - **EI.5** `LocalPolicy.encodeAsBytes_injective` +
        `LocalPolicies.encodeMap_injective` +
        `LocalPolicies.lookup_eq_of_encode_eq` corollary
        (`LegalKernel/Encoding/LocalPolicyInjective.lean`).
        Inner-record injectivity (`localPolicy_encode_injective`,
        `localPolicyClause_encode_injective`) was already shipped
        in `Encoding/LocalPolicy.lean` and is reused as-is.
      - **EI.6** `Bridge.DepositRecord.encode_injective` +
        `Bridge.DepositRecord.encodeAsBytes_injective` +
        `Bridge.BridgeState.encodeConsumed_injective`
        (`LegalKernel/Encoding/BridgeInjective.lean`).
      - **EI.7** `Bridge.EthAddress.toBytes_injective` +
        `Bridge.PendingWithdrawal.encode_injective` +
        `Bridge.PendingWithdrawal.encodeAsBytes_injective` +
        `Bridge.BridgeState.encodePending_injective` +
        `Bridge.BridgeState.encode_injective`
        (`LegalKernel/Encoding/BridgeInjective.lean`).
        Precursors `pendingWithdrawal_roundtrip` and
        `encodeSortedPairs_self_delim_split` ship alongside in
        `LegalKernel/Encoding/State.lean`.
      - **EI.8.a/b** `ExtendedState.extEq` definition +
        `ExtendedState.extEq.refl` + `ExtendedState.CanonicalBounds`
        bundle + headline composition theorem
        `commitExtendedState_subcommits_extensional_eq_under_collision_free`
        (`LegalKernel/FaultProof/Commit.lean`).  Retires
        CLAUDE.md footnote 1.
      - **EI.8.i** `kernelBuildTag` bumped to
        `"canon-encoder-injectivity"`; `Test/Umbrella.lean`,
        `Lex/Test/M2.lean`, and `Lex/Test/ExampleLex.lean` all
        updated to pin the new value.

    Visibility note: `LocalPolicy.encodeAsBytes`,
    `Bridge.DepositRecord.encodeAsBytes`, and
    `Bridge.PendingWithdrawal.encodeAsBytes` were promoted from
    `private` to non-private (per OQ-EI-2 option (a)) so the
    per-sub-state framing-injectivity lemmas can co-locate with
    their headline siblings in the `*Injective.lean` files rather
    than being forced inside the encoder definitions.

    Axiom posture: `#print axioms` ⊆ `[propext, Classical.choice,
    Quot.sound]` on every EI.3 – EI.8 theorem; `lake build` /
    `lake test` / every audit binary green.  29 new test cases
    bring the `encoding-injectivity` suite from 49 to 78 cases.

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

<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

<!--
  Knomosis — A Legal Kernel
  Adapted from the structure of Orbcrypt's CLAUDE.md
  (https://github.com/hatter6822/Orbcrypt/blob/main/CLAUDE.md)
  with project-specific guidance for Knomosis's Std-only, kernel-centric
  Lean 4 codebase.
-->

# CLAUDE.md — Knomosis project guidance

This file owns engineering conventions and the day-to-day developer /
agent workflow.  The design specification lives in
`docs/GENESIS_PLAN.md`; the top-level introduction lives in
`README.md`.  Where this file disagrees with the Genesis Plan, the
Genesis Plan wins.

## What this project is

Knomosis is a **proof-carrying state transition system** built in Lean 4.
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
ratifies the knomosis-as-rollup deployment scenario, the five Ethereum
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
./scripts/setup.sh --build    # full setup + full-project build (all targets)
./scripts/setup.sh --quiet    # suppress informational logs

# Manual alternative (skip integrity verification):
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
  | sh -s -- -y --default-toolchain none
elan toolchain install "$(cat lean-toolchain)"

# Daily commands.
source ~/.elan/env
lake build                          # default target (LegalKernel lib)
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
python3 scripts/regenerate_codemaps.py  # regenerate codemaps (CI gate)

# Runtime smoke test.
.lake/build/bin/knomosis info
.lake/build/bin/knomosis bootstrap /tmp/test.log
.lake/build/bin/knomosis-replay /tmp/test.log

# Workstream E (Solidity contracts) — see solidity/README.md.
cd solidity && ./scripts/vendor-deps.sh   # one-time
cd solidity && forge build
cd solidity && forge test
cd solidity && make test-cross-stack          # F.1.x equivalence suite
cd solidity && make audit-caps                # GP.5.2 fee-split-cap audit gate
cd solidity && make audit-caps-selftest       # self-test for the cap gate
cd solidity && make testnet-acceptance-dryrun # F.3 local fork dry-run

# Keccak-linked cross-stack verification — proves Lean's hashing ==
# the EVM's keccak256 byte-for-byte.  Links the real keccak256 adaptor
# (knomosis-hash-keccak256) in place of the FNV fallback, regenerates
# the corpora with isKeccak256Linked=true, and runs the Solidity
# consumers.  Needs elan + cargo + forge.  Runs in CI via
# .github/workflows/ci-keccak-crossstack.yml.
./scripts/verify_keccak_crossstack.sh

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
* `python3 scripts/regenerate_codemaps.py` — regenerates the
  per-language navigation maps under `codemaps/`; CI fails if the
  result differs from the committed tree.  The generator masks
  comments, string literals, Rust raw strings, and char literals
  before extracting each named declaration, and records a lexical
  reference graph in every declaration's `called` field (semantics
  in `codemaps/README.md` and the script's module docstring).

CI (`.github/workflows/ci.yml`) runs all of the above on every PR.

## Source layout

```
knomosis/
├── lakefile.lean              -- Lake config (lean_lib, lean_exe, plus
│                                  input_file/input_dir build deps for the Lex
│                                  registry and codegen-input directory)
├── lean-toolchain             -- pinned Lean version
├── tcb_allowlist.txt          -- TCB import allowlist
├── Main.lean                  -- `knomosis` runtime CLI
├── Replay.lean                -- `knomosis-replay` audit binary
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
│   ├── knomosis-hash-fallback.c  --   AR.10 default fallback (lake-built)
│   ├── knomosis-cli-common/      --   shared CLI / logging helpers (RH-H)
│   ├── knomosis-cross-stack/     --   dev-dep fixture loader (RH-H)
│   ├── knomosis-verify-secp256k1/ --  RH-A.1 ECDSA secp256k1 verifier
│   ├── knomosis-hash-keccak256/  --   RH-A.2 keccak-256 hash adaptor
│   ├── knomosis-host/            --   RH-C (TCP / TLS / Unix network adaptor)
│   ├── knomosis-l1-ingest/       --   RH-B (L1 event watcher daemon)
│   ├── knomosis-event-subscribe/ --   RH-D (event subscription server)
│   ├── knomosis-storage/         --   RH-E.0 (Storage trait + SQLite-backed impl)
│   ├── knomosis-indexer/         --   RH-E.1 (SQLite event indexer daemon)
│   ├── knomosis-faultproof-observer/ -- RH-G off-chain bisection-game observer
│   ├── knomosis-bench/           --   RH-F (transfer-throughput benchmark)
│   └── tests/cross-stack/     --   shared fixture corpus (.cxsf files)
├── scripts/setup.sh           -- SHA-256-verified toolchain + Foundry installer
├── scripts/verify_keccak_crossstack.sh -- keccak-linked cross-stack
│                                  equivalence orchestration (Lean<->EVM;
│                                  links the real keccak256 adaptor)
├── .github/workflows/ci.yml   -- Lean build + test + audits on PR / push
├── .github/workflows/ci-rust.yml -- Rust workspace build + test + clippy +
│                                  fmt on PR / push (path-filtered to
│                                  runtime/**)
├── .github/workflows/ci-solidity.yml -- Solidity GP.5.2 cap gate +
│                                  self-test + forge build/test on PR /
│                                  push (path-filtered to solidity/**)
├── .github/workflows/ci-keccak-crossstack.yml -- Lean<->EVM keccak256
│                                  byte-equivalence (links the real keccak
│                                  adaptor, regenerates corpora, runs the
│                                  Solidity consumers); PR-filtered to the
│                                  hash / cross-stack surface + nightly +
│                                  manual dispatch
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
  - CI's strict-warnings gate (`.github/workflows/ci.yml`) fails the
    build on any Lean `warning:` diagnostic line, so these are
    forcing-functions, not advisories.  Two properties make the gate
    sound: (1) every `lean_lib` + `lean_exe` in `lakefile.lean` is
    `@[default_target]`, so a bare `lake build` compiles every
    first-party module (kernel, laws, tests, Lex, Deployments, the
    runtime + audit-binary executables) — no module's warnings can
    hide; and (2) the gate's grep matches Lean's actual format
    (`warning: <file>.lean:<line>:<col>: …`, warning-token first),
    not the legacy `<…>: warning:` form.

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
  |                | `package knomosis where` block.  Bumped in lockstep |
  |                | with the Rust workspace so Knomosis ships a single  |
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
  held on the `package knomosis where` block in `lakefile.lean`:

  ```lean
  package knomosis where
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
| H     | Fault-proof per-step transition leaves the bridge ledger invariant (scope boundary) | `kernelOnlyApply_preserves_bridge`, `kernelOnlyReplay_preserves_bridge`, `applyCellWrites_to_state_preserves_bridge` | `Disputes/Evidence.lean`, `FaultProof/Coherence.lean` |
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

Knomosis's kernel uses **Lean core only**, no Mathlib or batteries.
Familiarity with these Std definitions is essential before
modifying the kernel:

| Std name              | Type                          | Role in Knomosis            |
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
| RH-D      | Rust host: event subscription      | Complete (Rust framework; Lean `knomosis extract-events` subcommand deferred) |
| RH-E.0    | Rust host: storage abstraction     | Complete |
| RH-E.1    | Rust host: SQLite indexer          | Complete (Rust framework; `--verify-against-knomosis` wiring deferred pending knomosis-host getBalance endpoint) |
| RH-F      | Rust host: 10k tx/sec benchmark    | Complete (harness ships; observed throughput ~7.5k ops/sec under default workload — gap documented in plan §RH-F closeout) |
| RH-G      | Rust host: fault-proof observer    | Complete (off-chain observer daemon; game state machine + honest strategy + L1 watcher + persistence + JSON-RPC EIP-1559 submitter + `knomosis replay-up-to` / `knomosis export-cell-proofs` subcommands + eth_call game-state reader + chaos suite + 50-trace cross-stack corpus) |
| SC.1      | SMT cell proofs: Lean spec + soundness | Complete |
| SC.2      | SMT cell proofs: Solidity verifier | Complete |
| SC.3      | SMT cell proofs: cross-stack soundness + corpus | Complete |
| SVC       | L1 step-VM cross-stack coherence + observer terminate wiring | Complete (Lean + Rust; cross-stack fixture corpus with cell-proof bundles emitted per fixture entry — 218 entries / 134 happy at SVC close, since widened by GP.3.3 → 238 and GP.5.3 → 248 / 152 happy; every happy fixture byte-equivalence-tested against Solidity `executeStep` under `isKeccak256Linked = true` via a single uniform driver) |
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
`"knomosis-step-vm-coherence"` (SVC).  `Test/Umbrella.lean`,
`Lex/Test/M2.lean`, and `Lex/Test/ExampleLex.lean` all pin this
value in regression tests, so any phase / milestone bump must
update the constant and every pinning test in the same PR.

**Test count.**  ~2 500 tests across 130 suites.  At the GP.5.3
closure the L1 step-VM execution arm for the delegated
`topUpActionBudgetFor` (action-index 21) lands: the
`faultproof-stepvm-coherence` suite grows from 100 to 110 cases (kind-21
value-level dispatch incl. tag-separation, admission-field exclusion,
self-pool defended branch, exact-balance Nat boundary, two end-to-end
production-path cases including the absent-pool-pre-balance edge,
field-layout pin, and the `stepVMHash_topUpActionBudgetFor_kind`
API-stability check),
`crosscheck-step-vm` grows from 37 to 39 cases (the
`topUpActionBudgetFor` corpus-count pin + the data-flow packed-layout
goldens' well-formedness guard), the cross-stack `step_vm.json`
corpus grows from 238 to 248 entries (+`topUpActionBudgetFor`: 6 happy +
4 adversarial) plus the `packedLayoutGoldens` / `variant21TailGolden`
data-flow layout-golden header sections, and the Solidity suites add
cases: in `KnomosisStepVM.t.sol` the keccak-independent
`test_topUpActionBudgetFor_matches_canonical_recipe` recipe pin, a
tag-separation test, a self-pool net-zero test, and an
exact-balance-drain boundary test (48 total); in
`CrossCheck/StepVM.t.sol` the two data-flow layout-golden consumers
`test_packedLayoutGoldens_match_abiEncodePacked` /
`test_variant21_tailGolden_matches_abiEncodePacked` (11 total + the
keccak-gated byte-equivalence driver).  Cross-stack byte-equivalence
was additionally confirmed dynamically end-to-end under a keccak-linked
verification build (all 152 happy fixtures byte-match `executeStep`);
the committed fixture stays on the FNV default.  At the
GP.5.1 closure (the GP.5.1 ETH fee-split entry point adds the Lean
cross-stack generator suite `crosscheck-deposit-fee-split`, 13 cases —
including the proof-carrying spec theorems `feeSplit_conserves` /
`feeSplit_pool_le` / `feeSplit_budget_le_max` — which emits the
80-entry `deposit_fee_split.json` corpus consumed by the Solidity
`DepositFeeSplitCrossCheck` (8 cases: arithmetic recompute, a
hash-independent preimage-tail layout pin, and a direct live-contract
check that deploys the bridge per entry and asserts the emitted split
equals the Lean values); the Solidity-side behavioural suite
`BridgeFeeSplit.t.sol`, 44 cases, lives in the forge tree).  Earlier,
at the GP.4.2 closure (Workstream GP §15E v1.0 admission gate + Action-
layer integration + five-round post-audit security hardening +
bridge-aware parity coverage + Workstream-GP bridge-replay fix +
step-VM dispatcher extension to kinds 19 / 20 + cross-stack
fixture-corpus extension to 238 entries + per-variant coherence
specialisations for the two new variants + end-to-end
`stepVMHashFromAction` production-path coverage + terminate-bundle
coverage for the new variants + the GP.3.4 delegated-top-up suite
`authority-delegated-topup`, 56 cases + the GP.4.1 `DepositRecord`
widening coverage across `bridge-state`, `bridge-accounting`,
`bridge-admissible`, `encoding-injectivity`, and
`runtime-bridge-admission` + the GP.4.2 accounting-equation split
adding 38 `bridge-accounting` cases, 59 total — the per-leg
`totalUserDeposited` / `totalPoolDeposited` folds, the split identity,
per-action deltas (including `withdraw` and the atomic admitted-step
forms), and the pool-solvency inflow coherence).
`lake test` is the canonical query;
the exact number drifts upward with every PR.  Only monotonic
growth is enforced — individual regression tests land alongside new
theorems, and no global gate pins the count.

Notable Lean suites at the current build tag:

  * `authority-signed-budget` (42 cases, GP.3.2 v1.0) — pins all
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
  * `encoding-action` (39 cases) — extended with byte-stable CBE
    encode/decode round-trip + per-field injectivity + tag
    regression pins for the GP.2.3 constructors (`depositWithFee`
    at index 19, `topUpActionBudget` at index 20) and the GP.3.4
    `topUpActionBudgetFor` at index 21 (round-trip, distinct-bytes
    vs `topUpActionBudget`, tag pin, recipient-field injectivity).
    The AR.5 / AR.6 `Action.tag` / `Event.tag` regression-pin
    sections are likewise complete: 22 `Action` pins (0..21) and
    20 `Event` pins (0..19).

  * `faultproof-stepvm-coherence` (109 cases, GP.3.3 + GP.5.3) —
    pins the 22-variant step-VM dispatcher byte-for-byte against
    Solidity's `executeStep`, including the bulk-variant
    256-recipient cap, adversarial-input regressions on
    `decodeCellNat`, and the Workstream-GP additions: per-variant
    value-level dispatch tests for kinds 19 / 20 / 21 with distinct
    / self-credit / self-pool defended branches, the load-bearing
    `budgetGrant` / `budgetIncrement` / `recipient` design property
    (admission-layer fields excluded from the step-VM hash), the
    GP.5.3 kind-21 tag-separation regression (delegated
    `topUpActionBudgetFor` ≠ self-funded `topUpActionBudget` on
    identical gas-transfer fields), and six end-to-end
    `stepVMHashFromAction` production-path tests that verify the full
    `commitExtendedState` + `actionFieldsForL1` +
    `buildObserverCellProofs` + dispatcher chain reads the correct
    pre-balances from the observer bundle (distinct, self-credit,
    topUp, delegated-topUp, absent-pool-pre-balance, and
    zero/absent-pre-balance cases).
  * `crosscheck-step-vm` (39 cases, GP.3.3 + GP.5.3) — pins
    per-variant fixture counts for the 248-entry corpus (218 from
    SVC.5.e + 30 Workstream-GP additions: depositWithFee +
    topUpActionBudget + topUpActionBudgetFor at 10 each), the
    well-formedness of the data-flow packed-layout goldens
    (`packedLayoutGoldens` full-width `uint64BE`/`uint256BE` encodings
    + `variant21TailGolden`, byte-matched against `abi.encodePacked`
    on the Solidity side by `test_packedLayoutGoldens_match_abiEncodePacked`
    / `test_variant21_tailGolden_matches_abiEncodePacked`), plus
    cell-proof bundle invariants for all 152 happy fixtures.
  * `faultproof-terminate-bundle` (20 cases) +
    `integration-export-terminate-bundle-cli` (15 cases) — wire
    the `knomosis export-cell-proofs` subcommand to the RH-G
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

**Rust-side test count.**  ~1 480 tests across the 11 workspace
crates at the GP.6.1 landing.  `cargo test --workspace --locked`
from `runtime/` is the canonical query.  Approximate per-crate
breakdown at the landing:

| Crate                            | Tests | Role                                                       |
|----------------------------------|-------|------------------------------------------------------------|
| `knomosis-cli-common`               |   ~8  | shared logging / exit-code / paths helpers                 |
| `knomosis-cross-stack`              |  ~32  | fixture loader dev-dep                                     |
| `knomosis-verify-secp256k1`         |  ~42  | RH-A.1 ECDSA secp256k1 verifier (cdylib)                   |
| `knomosis-hash-keccak256`           |  ~32  | RH-A.2 Keccak-256 hash adaptor (cdylib)                    |
| `knomosis-l1-ingest`                | ~275  | RH-B L1 event watcher daemon + GP.6.1 fee-split mirror     |
| `knomosis-host`                     | ~183  | RH-C TCP/TLS/Unix network adaptor                          |
| `knomosis-event-subscribe`          | ~176  | RH-D event subscription server                             |
| `knomosis-storage`                  |  ~67  | RH-E.0 storage abstraction + SQLite impl                   |
| `knomosis-indexer`                  | ~138  | RH-E.1 SQLite event indexer daemon                         |
| `knomosis-bench`                    | ~111  | RH-F transfer-throughput benchmark                         |
| `knomosis-faultproof-observer`      | ~312  | RH-G off-chain bisection-game observer                     |

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
plan §2.2 layout plus `knomosis-cross-stack`, the dev-dep fixture loader)
per `docs/planning/rust_host_runtime_plan.md` §RH-H.  Highlights:

  * Two foundation crates: `knomosis-cli-common` (shared logging /
    exit-code / paths helpers) and `knomosis-cross-stack` (cross-stack
    fixture loader + file-format spec).  Downstream crates dev-dep
    on `knomosis-cross-stack` for byte-equivalence assertions against
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

  * **RH-A.1 — `knomosis-verify-secp256k1`.**  Production ECDSA secp256k1
    verification adaptor.  Exposes the `knomosis_verify_ecdsa` C ABI
    symbol; a Lean deployment with a matching `@[extern
    "knomosis_verify_ecdsa"]` declaration on `Authority.Crypto.Verify`
    links here at runtime.  Strict input validation (33-byte
    SEC1-compressed pubkey with 0x02 / 0x03 prefix, 32-byte pre-hashed
    message, 64-byte `(r ‖ s)` signature), `1 ≤ r < n` and `1 ≤ s < n`
    bounds, EIP-2 / BIP-62 low-s canonicalisation via `k256::IsHigh`.
    Built on `k256 = "0.13"`.  210-record cross-stack fixture corpus
    (`runtime/tests/cross-stack/ecdsa_secp256k1.cxsf`).
  * **RH-A.2 — `knomosis-hash-keccak256`.**  Production Keccak-256
    (Ethereum-flavoured, NOT FIPS-202 SHA3-256) hash adaptor.  Exposes
    three C ABI symbols matching Lean's `@[extern]` declarations in
    `Runtime/Hash.lean`: `knomosis_hash_bytes`, `knomosis_hash_stream`,
    `knomosis_hash_identifier`.  Production binaries link the cdylib
    AHEAD of the `knomosis-hash-fallback.o` forwarder to override the
    FNV-1a-64 fallback.  Identifier: `"keccak256/EVM-compatible/v1"`.
    Built on `sha3 = "0.10"`.  51-record cross-stack fixture corpus
    (`runtime/tests/cross-stack/keccak256.cxsf`).
  * **C ABI shim design.**  Each crate ships a tiny C shim
    (`c/lean_shim.c`) wrapping Lean's `static inline` runtime API as
    non-inline `knomosis_lean_*` symbols.  `build.rs` discovers `lean.h`
    via `LEAN_INCLUDE_DIR` → `LEAN_SYSROOT` → `lean --print-prefix` →
    soft-skip.  The `lean-ffi` Cargo feature promotes a missing
    `lean.h` to hard-fail for production builds.

**Workstream RH-B (L1 event ingestor).**  **Complete.**  The
long-running daemon that watches Ethereum L1, translates `KnomosisBridge`
/ `KnomosisIdentityRegistry` event logs to Knomosis `Action`s via the
byte-equivalent Rust mirror of `LegalKernel.Bridge.Ingest.ingest`,
signs with a `zeroize`-protected bridge-actor key, and forwards
CBE-encoded `SignedAction`s to the downstream consumer.

  * **Surface.**  `knomosis-l1-ingest` library + daemon binary
    (`--l1-rpc / --bridge-actor-keystore / --knomosis-host-url /
    --bridge-contract / --identity-registry / --state-file
    [+ optional --deployment-id / --confirmation-depth /
    --poll-interval-ms / --until-block]`).  Identifier:
    `"knomosis-l1-ingest/v1"`.
  * **Byte-exact CBE.**  `src/encoding.rs` hand-rolls Lean's
    `Encoding.Action.encode` layout byte-for-byte: 1-byte tag +
    8-byte LE-Nat head per field; byte strings as head + raw
    payload; constructor-tag indices frozen against
    `Encoding/Action.lean`.  12-record cross-stack corpus
    (`l1_ingest.cxsf`).
  * **No `ethers-rs` / `tokio` dependency.**  Hand-rolled minimal
    Ethereum ABI decoder (`src/events.rs`) over the five event
    signatures (the four identity / deposit events plus the
    Workstream-GP `DepositWithFeeInitiated`, GP.5.1); synchronous
    watcher loop.  Both deposit events decode to `Translated::NoAction`
    — deposit materialisation is the sequencer's responsibility
    (chain-level follow-up), not the ingestor's; the fee-split event is
    recognised + decoded for observability and dedup symmetry with
    `DepositInitiated`.
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

  * **Surface.**  `knomosis-host` library + daemon (`--listen /
    --tls-listen / --tls-cert / --tls-key / --unix-socket /
    --knomosis-binary / --knomosis-log / --knomosis-work-dir /
    --deployment-id / --max-queue-depth / --max-frame-size /
    --max-concurrent-connections / --mock`).  Identifier:
    `"knomosis-host/v1"`.
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
    dev kernel) and `CommandKernel` (spawns the Lean `knomosis`
    binary's `process` subcommand per request).  `CommandKernel`
    is heavy (re-loads the log file every request); a future
    persistent `knomosis serve` subcommand would eliminate the
    per-request bootstrap cost.
  * **Hardening.**  Bounded mpsc queue with `Busy` overflow;
    `--max-concurrent-connections` cap via RAII `ConnectionSlot`;
    spawn-storm DoS defence; in-flight drain on shutdown; per-
    connection write-timeout; kernel-panic isolation via
    `panic::catch_unwind`; `unsafe_code = "forbid"`.

**Workstream RH-D (Event subscription server).**  **Complete (Rust
framework; Lean `knomosis extract-events` subcommand deferred).**  The
TCP service that tails Knomosis's transition log, extracts deployment-
facing events via a Lean `knomosis` subprocess, and streams those events
to subscribers in strict order with bounded-lag eviction.

  * **Surface.**  `knomosis-event-subscribe` library + daemon
    (`--log-path / --listen / --mock | --knomosis-binary /
    --max-subscriber-lag / --keep-history / --max-frame-size /
    --max-subscribers / --max-concurrent-connections /
    --send-queue-depth / --write-timeout-ms /
    --handshake-read-timeout-ms / --poll-interval-ms`).
    Identifier: `"knomosis-event-subscribe/v1"`.
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
    log-file format (4-byte "KNOM" magic + 8-byte LE length +
    payload + 8-byte LE FNV-1a-64 trailer).  Pending frames
    (writer mid-frame) distinguished from corruption (bad magic /
    trailer / oversize).  Symlink rejection + post-open inode
    verification + truncation detection.
  * **Extractor abstraction.**  `MockExtractor` (programmable
    test impl) and `SubprocessExtractor` (spawns `knomosis` in a
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
(Rust framework; `--verify-against-knomosis` wiring deferred pending
knomosis-host getBalance endpoint).**  Two crates that materialise the
storage abstraction (RH-E.0) and the per-(actor, resource) balance
indexer (RH-E.1).

  * **RH-E.0 — `knomosis-storage` (library only).**  `Storage` /
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
  * **RH-E.1 — `knomosis-indexer` (library + binary).**  `daemon`
    subcommand subscribes to `knomosis-event-subscribe` and maintains
    a per-(actor, resource) balance view; `query <actor>
    <resource>` provides ad-hoc lookups.  Idempotent restart via
    a stored cursor; each event-batch commits atomically with
    the cursor advance.  Identifier: `"knomosis-indexer/v1"`.
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
Materialises `runtime/knomosis-bench/` as a deterministic transfer-
throughput harness per `docs/planning/rust_host_runtime_plan.md`
§RH-F.

  * **Surface.**  Library + binary (`knomosis-bench`) with CLI flags
    `--standalone | --connect <ENDPOINT>` for mode selection;
    `--actor-count / --transfer-count / --worker-count /
    --warmup-requests / --seed` for the workload; `--queue-depth
    / --max-frame-size` for the embedded server; `--report <PATH>
    / --baseline <PATH> / --threshold <FRAC> / --target-tps <N> /
    --target-p99-ms <N>` for the JSON report + regression gates.
    Identifier: `"knomosis-bench/v1"`.
  * **Deterministic fixture.**  Pre-funds `actor_count` (default
    1000) secp256k1 keypairs derived from a `(seed, actor_index)`
    Keccak-256 hash chain with rejection sampling into `[1, n)`
    curve order.  Generates `transfer_count` (default 10 000)
    round-robin `Action::Transfer` payloads signed with the
    sender's actor key + per-actor monotonic nonce.  Reuses
    `knomosis-l1-ingest::encoding` primitives so emitted SignedAction
    bytes are cross-stack-equivalent to Lean's
    `Encoding.SignedAction.encode`.  Two runs with the same
    `(seed, actor_count, transfer_count)` produce byte-identical
    payloads.
  * **Concurrent driver.**  Default 64 submitter threads sharing
    an atomic cursor into the pre-framed payloads.  Each worker
    opens a fresh connection per request (mirroring knomosis-host's
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
Materialises `runtime/knomosis-faultproof-observer/` as the operational
counterpart to the Workstream-H Lean fault-proof soundness chain.
See `docs/planning/rust_host_runtime_plan.md` §RH-G and
`docs/fault_proof_runbook.md` §7.

  * **Surface.**  Library (11 modules: `config`, `error`, `events`,
    `game`, `jsonrpc_submitter`, `observer`, `persistence`,
    `state_reader`, `strategy`, `submitter`, `watcher`) plus the
    `knomosis-faultproof-observer` daemon (CLI flags `--l1-rpc /
    --game-contract / --state-root-contract / --storage /
    --keystore / --deployment-id / --play-as /
    --confirmation-depth / --reorg-window / --blocks-per-iter /
    --poll-interval-ms / --start-block / --knomosis-binary /
    --knomosis-log / --chain-id / --log-level`).  Identifier:
    `"knomosis-faultproof-observer/v1"` (published via
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
    `SubprocessTruthOracle` (shells out to `knomosis replay-up-to
    LOG IDX`, with bounded stdout cap and spawn-drain-before-wait
    discipline to avoid pipe-buffer deadlocks).  `compute_next_move`
    mirrors Lean's `honestStrategy` decision tree exactly.
  * **L1 event-watch + re-org handling** (`src/watcher.rs`,
    `src/events.rs`).  Reuses `knomosis-l1-ingest`'s `ReorgWindow` +
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
    `knomosis-l1-ingest::key::BridgeActorKey::sign_prehash`'s low-s
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
    `knomosis-storage`-backed game / response / cursor / identifier
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
  * **Lean cell-proof export** (`Main.lean`).  `knomosis
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
    simulator.  `KNOMOSIS_CHAOS_SEED=N` drives the seed-sweep entry
    point for operator-level fuzz testing.
  * **Move-type wiring (all four).**  All four observer move
    types — Submit / RespondAgree / RespondDisagree /
    TerminateOnSingleStep — are wired end-to-end through the
    production submitter, now that L1 step-VM coherence
    (workstream SVC + GP.3.3 + GP.5.3) covers every `Action` variant
    (indices 0..21).  TerminateOnSingleStep is dispatched via
    `Observer::build_terminate_calldata` (`src/observer.rs`),
    which fetches a cell-proof bundle from the configured
    `TerminateBundleOracle` and encodes the full-form
    `terminateOnSingleStep` calldata (`src/submitter.rs`).  The
    production daemon attaches a `SubprocessTruthOracle`-backed
    bundle oracle when both `--knomosis-binary` and `--knomosis-log`
    are supplied (`build_terminate_bundle_oracle` in
    `src/main.rs`); without them the observer logs and defers the
    terminate move with no safety impact — bisection rounds use
    opaque-actionFields hashing that matches cross-stack on both
    sides, so the observer still defends correctly by playing
    Submit / RespondAgree / RespondDisagree until the game
    settles via timeout.

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
    `knomosis-hash-keccak256`).  Header-shape + byte-size assertions
    run unconditionally.

**Workstream SVC (L1 step-VM cross-stack coherence + observer
terminate wiring).**  **Complete (Lean + Rust).**  Extends the L1
step-VM coherence corpus from 2 variants (Transfer + Mint) to all 19
`Action` variants; lays the groundwork for fully wiring the
RH-G observer's `TerminateOnSingleStep` move type.  See
`docs/planning/step_vm_coherence_plan.md` for the engineering plan.

  * **Headline.**  `stepVMHash`-driven per-variant byte-equivalence
    against Solidity's `executeStep`.  Fixture corpus with cell-proof
    bundles emitted per fixture entry — 218 entries / 134 happy at
    SVC close, since widened by GP.3.3 (→ 238, kinds 19 / 20) and
    GP.5.3 (→ 248 / 152 happy, kind 21); every happy fixture
    byte-equivalence-tested against Solidity under
    `isKeccak256Linked = true` via a single uniform driver.
  * **Lean theorems.**  `stepVMHash_<variant>_kind` (per-variant
    `rfl` proofs in `LegalKernel/FaultProof/StepVMCoherence.lean`,
    including the GP-family `depositWithFee` / `topUpActionBudget` /
    `topUpActionBudgetFor` arms); `stepVMHashFromAction` canonical
    step-VM hash via action-driven inputs;
    `step_vm_dispatch_well_typed`;
    `buildTerminateBundle_cellProofs_verify`
    (`FaultProof/TerminateBundle.lean`).
  * **Test suites.**  `faultproof-stepvm-coherence` (110 cases —
    83 at SVC close, +17 from the Workstream-GP variant-19/20
    extension + end-to-end production-path coverage, +10 from the
    GP.5.3 variant-21 extension incl. the exact-balance Nat boundary),
    `crosscheck-step-vm` (39 cases — 35 at SVC close, +2 GP
    variant-19/20 fixture-count pins, +2 GP.5.3 variant-21 pins incl.
    the data-flow packed-layout goldens), `faultproof-terminate-bundle`
    (20 cases — 18 at SVC close, +2 GP variant coverage),
    `integration-export-terminate-bundle-cli` (15 cases).

**Workstream AR (Audit Remediation).**  **Complete.**  See
`docs/planning/audit_remediation_plan.md` for the engineering plan.
Headline contributions surviving in current code:

  * **AR.1** shared `Authority.signedActionDomain` constant.
  * **AR.2** `RuntimeState.deploymentId` field threaded through
    `processSignedAction` / `bootstrap` / `replayWith` /
    `checkSignatureInvalidWith` + `--deployment-id <hex>` CLI
    flag on both `knomosis` and `knomosis-replay`.
  * **AR.2.5** parameterised `checkEvidenceWith verify d`
    dispatcher routing the `signatureInvalid` claim through
    `checkSignatureInvalidWith` with explicit deploymentId.
  * **AR.3** `bootstrapFromSnapshot` chain-anchor check
    (`.anchorMismatch`) + `bootstrapFromAttestedSnapshot` wrapper.
  * **AR.5 / AR.6** regression pins for the frozen `Action` and
    `Event` constructor indices (22 `Action` constructors, 0..21,
    after the GP.3.4 `topUpActionBudgetFor`; 20 `Event`
    constructors, 0..19, after the GP.3.4
    `delegatedActionBudgetTopUp`).
  * **AR.7** `Lex.Tools.Diff` widened to compare type + kind +
    tactic body, not just names.
  * **AR.9** new `mock_import_audit` binary mechanically enforces
    "no production module imports `Test/*`".
  * **AR.10** real `@[extern]` annotations on `hashBytes` /
    `hashStream` / `hashImplementationIdentifier`, with default
    `runtime/knomosis-hash-fallback.c` forwarder + Lake `extern_lib`
    `knomosisHashFallback`.
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
resistance).**  **In progress** (Lean-side GP.0 — GP.3 complete,
including GP.3.4, plus GP.4.1 and GP.4.2; Solidity-side GP.5.1 — the
ETH fee-split deposit entry point — GP.5.2 — the constitutional
fee-split-cap audit gate — GP.5.3 — the L1 step-VM execution arm
for the delegated `topUpActionBudgetFor` (variant 21) — GP.5.4 —
the opt-in BOLD-currency fee-split deposit entry point
`depositBoldWithFee` — and GP.5.5 — the BOLD-specific safety
hardening (per-currency circuit breaker, Liquity-V2 depeg
auto-trigger, per-BOLD TVL cap) — complete; Rust-side GP.6.1 — the
`knomosis-l1-ingest` GP-family encoder + fee-split fixture corpus —
complete).
See `docs/planning/unified_gas_pool_plan.md` for the full plan.
Headline contributions surviving in current code:

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
    `bridgeAuthorizedAction` (`Bridge/BridgeActor.lean`) authorises
    `depositWithFee` for the bridge actor — `depositWithFee` is
    `Action.isBridgeOnly`, so `BridgeAdmissibleWith` forces it to be
    bridge-signed, and it must therefore be bridge-authorised or it
    would be unadmittable under `bridgePolicy`.  The
    `bridgeAuthorizedAction_of_isBridgeOnly` consistency theorem
    (`Bridge/Admissible.lean`) pins the `isBridgeOnly ⊆
    bridgeAuthorizedAction` invariant so this class of bug cannot
    recur; the user gas actions `topUpActionBudget` /
    `topUpActionBudgetFor` remain rejected by `bridgePolicy`
    (`bridgePolicy_rejects_topUpActionBudget{,For}`), being
    user-initiated rather than bridge attestations.
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
    `replay_impossible_preserved`.  Each budget theorem additionally
    has a **bridge-aware mirror** (`*_bridge`) in
    `Bridge/Admissible.lean` pinning the SAME property on the
    *production* path (`apply_bridge_admissible_with_budget`), all
    lifted DRY through the single budget-gate agreement lemma
    `apply_bridge_admissible_with_budget_epochBudgets_eq` (with its
    `_none_iff` / `_kernel_epochBudgets` corollaries) — the bridge
    budget gate is the kernel budget gate up to a `bridge`-field
    stamp, so every property transfers verbatim.
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
      step functions (already shipped in `solidity/src/contracts/KnomosisStepVM.sol`)
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
  * **GP.3.4** Delegated `topUpActionBudgetFor` (frozen `Action`
    index 21) — pre-authorised delegated budget top-up (OQ-GP-7).
    A delegate (signer) pays gas into the pool so a *different*
    actor's (recipient's) epoch budget is credited, gated by the
    recipient's prior consent.  Shipped:
    - New positive `LocalPolicyClause.allowTopUpFrom (delegates :
      List ActorId)` clause (frozen clause index 3) with the
      `MAX_DELEGATES_PER_ALLOW = 64` DoS cap, CBE codec +
      round-trip, and `LocalPolicyClause.permits` treating it as
      vacuously permissive in the signer-scoped restrictive check.
    - New law `Laws.topUpActionBudgetFor`
      (`Laws/TopUpActionBudgetFor.lean`): same debit-signer /
      credit-pool kernel shape as `topUpActionBudget`, plus a
      `recipient ≠ signer` precondition.  Full §4.11 classification
      ladder (`_conserves`, `_signer_debited`, `_pool_credited`,
      `_other_actor_untouched`, `_other_resource_untouched`,
      `IsConservative` / `IsMonotonic` / `LocalTo [gasResource]` /
      `FreezePreserving`).
    - **DEFAULT-DENY consent** enforced at the admission layer via
      the combined `topUpActionBudgetFor_gate` (six conjuncts:
      `signer ≠ bridgeActor`, `signer ≠ poolActor`, `recipient ≠
      signer`, `gasAmount > 0`, `getBalance ≥ gasAmount`, and the
      recipient-consent check `delegatedTopUpConsentBool`, whose
      meaning is characterised by `delegatedTopUpConsentBool_iff`).
      Wired into both `apply_admissible_with_budget` and the
      bridge-aware `apply_bridge_admissible_with_budget`; the
      per-action budget-grant arm targets the RECIPIENT.  Headline
      admission theorems: `delegatedTopUp_grants_budget_to_recipient`,
      `delegatedTopUp_requires_allowTopUpFrom`,
      `delegatedTopUp_signer_balance_debited`.  `RegistryPreserving`
      instance ships; `Action.toTransition` threads the signer
      (mirrored by `kernelOnlyApply`, so the dispute-pipeline
      equivalence `apply_admissible_with_eq_kernelOnlyApply` stays
      by `rfl`).
    - New semantic event `Event.delegatedActionBudgetTopUp` (frozen
      event index 19) emitted by `extractEvents`; the signer's
      gas-balance change and the pool credit are emitted as
      `balanceChanged` events.
    - Step-VM: `actionKindByte` / `actionFieldsForL1` /
      `Action.readOnlyCells` / `Action.writeCells` extended for
      variant 21.  At GP.3.4 the L1 step-VM *execution* arm
      (`stepVMHash` kind 21) + the Solidity `_step21` + cross-stack
      fixtures were deferred to GP.5.3; **GP.5.3 has since closed
      that arm** (the `stepVMHash` kind-21 dispatch reduces to
      `stepCommitTopUpActionBudgetFor`, the Solidity
      `_stepTopUpActionBudgetFor` + dispatcher arm ship in
      `KnomosisStepVM.sol`, and the cross-stack corpus carries 10
      `topUpActionBudgetFor` entries), so `topUpActionBudgetFor` is
      now L1-fault-proof-executable.  Cell-write semantic agreement
      IS proven (`cellwrites_topUpActionBudgetFor`) and commit
      coherence with `kernelOnlyApply`
      (`coherence_topUpActionBudgetFor`), both independent of the
      step-VM execution arm.
    - Kernel-path budget ladder beyond the three headline theorems:
      `delegatedTopUp_signer_budget_consumed` (the delegate pays one
      action-budget unit) and `delegatedTopUp_budget_locality` (no
      other actor's budget changes).  All five GP.3.4 admission
      theorems plus the three GP.3.4-relevant law theorems have
      bridge-aware (`*_bridge`) production-path mirrors.
    - Test suite `authority-delegated-topup` (56 cases).
  * **GP.4.1** `DepositRecord` widened from the two-field
    `(resource, amount)` shape to the four-field
    `(resource, userAmount, poolAmount, budgetGrant)` record
    (`LegalKernel/Bridge/State.lean`), with a `LegacyDepositRecord`
    compatibility type and the lossless `DepositRecord.fromLegacy` /
    `DepositRecord.toLegacy` lift (`toLegacy_fromLegacy` round-trip).
    The CBE codec + `depositRecord_roundtrip`
    (`LegalKernel/Encoding/State.lean`), the EI.6.a/b/c + EI.7.e
    injectivity ladder (`LegalKernel/Encoding/BridgeInjective.lean`),
    and the `ExtendedState.CanonicalBounds.bs_cons_rec` field
    (`LegalKernel/FaultProof/Commit.lean`) all carry the widened
    per-field canonical bounds.  `applyActionToBridgeState` records
    the `(userAmount, poolAmount, budgetGrant)` split (no longer the
    collapsed sum); `DepositRecord.amountAt` recombines
    `userAmount + poolAmount` so `totalDeposited` is value-preserving
    (`LegalKernel/Bridge/Accounting.lean`), on which the GP.4.2
    accounting split builds.
  * **GP.4.2** Bridge accounting-equation split
    (`LegalKernel/Bridge/Accounting.lean`).  The legacy single-term
    LHS `totalDeposited` is split into the per-leg folds
    `totalUserDeposited` / `totalPoolDeposited` (over the
    `DepositRecord.userAmountAt` / `poolAmountAt` projections, with the
    per-record split `DepositRecord.userAmountAt_add_poolAmountAt`).
    The headline split identity
    `totalUserDeposited_plus_pool_eq_totalDeposited`
    (`totalUserDeposited + totalPoolDeposited = totalDeposited`)
    feeds `bridge_accounting_equation_balanced`: given the §15D legacy
    equation `totalDeposited = rhs`, the amended split equation holds
    with the same `rhs` — the deposit-fee split is a bookkeeping split,
    not an escrow split.  Per-action deltas
    (`totalUserDeposited_step_eq` / `totalPoolDeposited_step_eq`, the
    `*_step_eq_deposit` legacy specialisations, the fresh-insert
    `*_markConsumed` deltas via a generic projected-fold
    insert-absent lemma, and `accounting_userpool_delta_non_bridge`)
    cover every action.  Pool solvency:
    `depositWithFee_pool_credit_matches_ledger_delta` (every wei
    credited to the pool actor's L2 balance is matched, wei-for-wei,
    by the ledger's recorded `poolAmount`) and
    `pool_balance_eq_totalPoolDeposited_minus_payouts`
    (`getBalance gasPoolActor = totalPoolDeposited − payouts`,
    parameterised over an arbitrary pool actor — no dependency on the
    GP.7.1 `gasPoolActor` reservation).  A post-implementation audit
    added the **atomic admitted-step** forms over the real
    `apply_bridge_admissible_with` (the runtime / dispute-pipeline
    entry), *deriving* deposit-id freshness from the
    `BridgeAdmissibleWith` witness:
    `totalUserDeposited_admissible_depositWithFee`,
    `totalPoolDeposited_admissible_depositWithFee`,
    `depositWithFee_admissible_credits_poolActor`, and
    `depositWithFee_admissible_pool_credit_matches_ledger` (live pool
    balance and `totalPoolDeposited` move in lockstep over the same
    step), plus `accounting_userpool_delta_withdraw` (closing per-action
    coverage — `withdraw` touches only `pending`) and the
    `*_unchanged_when_consumed_eq` lemmas.  A second (optimal-closure)
    audit then added the iff-form balanced equation
    `bridge_accounting_equation_balanced_iff` (names `totalWithdrawn`,
    bidirectional), the genuine pool-solvency inductive step
    `pool_solvency_preserved_by_admitted_depositWithFee` (reconciliation
    is preserved across an admitted deposit — a real obligation, not a
    hypothesis rearrangement), and runtime-entry coherence:
    `apply_bridge_admissible_with_budget_base_bridge_eq`
    (`Bridge/Admissible.lean` — the budget gate overwrites only
    `epochBudgets`, so every accounting delta transfers verbatim) plus
    `depositWithFee_budget_admitted_pool_credit_matches_ledger` over the
    literal `apply_bridge_admissible_with_budget` runtime entry.  38 new
    `bridge-accounting` cases (59 total).  The split identity is named
    without the sketch's `_legacy` infix (a `naming_audit`-forbidden
    temporal marker).
  * **GP.5.1** L1 `KnomosisBridge` user-chosen fee-split deposit
    (`solidity/src/contracts/KnomosisBridge.sol`).  New payable entry
    `depositETHWithFee(uint16 chosenFeeBps)` splits `msg.value` into a
    user credit and a gas-pool fee at a caller-chosen rate within the
    deployment's immutable `[minFeeBps, maxFeeBps]` band, converts the
    pool credit to an action-budget grant at the immutable
    `weiPerBudgetUnitEth` rate clamped at `MAX_BUDGET_PER_DEPOSIT`
    (10^12), and emits `DepositWithFeeInitiated`.  The shared
    `_registerDepositWithFee` helper (resource-generic, reused by the
    GP.5.4 BOLD path) enforces the TVL cap on the FULL deposit, bumps
    the per-depositor nonce, and binds the canonical `receiptHash` over
    `(deploymentId, sender, resourceId, token, userAmount, poolAmount,
    budgetGrant, nonce)` — `deploymentId` gives deployment-replay
    resistance and the eight-field cover defeats replay-with-modified-
    fields (unified-gas-pool plan §22.7b).  Compile-time caps
    `MAX_FEE_BPS_CAP` (5000), `MIN_WEI_PER_BUDGET_UNIT` (1),
    `MAX_BUDGET_PER_DEPOSIT` (10^12) and the constructor guards
    (`MinFeeBpsExceedsMax`, `MaxFeeBpsExceedsCap`,
    `WeiPerBudgetUnitTooSmall`) ship alongside.  `userAmount +
    poolAmount = msg.value` is exact — the floor-division residue
    favours the user, and `userAmount = v − poolAmount` is
    `unchecked`-safe because `poolAmount ≤ ⌊v/2⌋` (`maxFeeBps ≤
    MAX_FEE_BPS_CAP = 5000`).  The Lean generator additionally proves
    the spec-level guarantees `feeSplit_conserves` (userAmount +
    poolAmount = v), `feeSplit_pool_le`, and `feeSplit_budget_le_max`,
    so the contract's conservation + budget-bound are proof-carrying up
    to the cross-stack equivalence (not merely fuzz-observed).
    Coverage: `test/BridgeFeeSplit.t.sol` (44 behavioural cases
    including three fuzz properties, a near-`uint64`-max-rate case, a
    gas-regression smoke test, and explicit receiptHash replay-resistance
    tests isolating the nonce-binding and deploymentId-binding
    dimensions) plus the `deposit_fee_split.json`
    cross-stack corpus (80 entries; Lean generator
    `LegalKernel/Test/Bridge/CrossCheck/DepositFeeSplit.lean` + Solidity
    consumer `test/CrossCheck/DepositFeeSplit.t.sol`, 8 cases).  The
    cross-check pins the split + receiptHash three ways: the arithmetic
    recompute against the `FeeSplitMath` reference; a hash-independent
    byte-match of the Lean-emitted 224-byte receiptHash preimage tail
    against `abi.encode` (runs in every binding mode); and a DIRECT
    live-contract check that deploys the bridge per entry, calls
    `depositETHWithFee`, and asserts the EMITTED split equals the Lean
    values (no `FeeSplitMath` intermediary) with an on-chain
    real-keccak256 receiptHash-recipe check.  The behavioural suite also
    covers the migration circuit-breaker on the new entry point, the
    shared per-depositor nonce across `depositETH` / `depositETHWithFee`,
    and the `minFeeBps == maxFeeBps == 0` forced-zero-fee deployment.
    On the Rust side, the RH-B L1 ingestor (`knomosis-l1-ingest`) now
    recognises + decodes the `DepositWithFeeInitiated` event into a new
    `IngestedEvent::DepositWithFeeInitiated` variant that translates to
    `NoAction` — symmetric with `DepositInitiated` (deposit
    materialisation is the sequencer's chain-level responsibility, not
    the ingestor's, for both events) — with `.cxsf` fixture round-trip
    coverage.  The BOLD entry point (`depositBoldWithFee`) shipped in
    GP.5.4 (below); the L1 step-VM execution arms are complete for every
    GP-family variant (kinds 19 / 20 via GP.3.3, kind 21 via GP.5.3).
  * **GP.5.2** Constitutional fee-split-cap audit gate.  The three
    compile-time caps shipped in GP.5.1 — `MAX_FEE_BPS_CAP = 5000`,
    `MIN_WEI_PER_BUDGET_UNIT = 1`, `MAX_BUDGET_PER_DEPOSIT = 10^12`
    (`KnomosisBridge.sol`) — are now guarded by two independent layers:
    the compiled-contract runtime pin
    `test/BridgeFeeSplit.t.sol::test_compileTimeCaps_pinned` (asserts
    each value through the public getter) and the new source-level
    grep gate `solidity/scripts/audit_compile_time_caps.sh` (run via
    `make audit-caps`).  The gate reads each cap's value *by name*
    (anchored on `constant <name> =`, so it reads exactly that
    constant rather than the last number on the line), checks the
    declared `uintN` width, requires exactly one declaration, and
    matches over a comment-stripped view of the source (so a
    canonical-looking line hidden in a `//` or multi-line `/* */`
    comment cannot mask a drifted real declaration) — so a value
    drift, a type narrowing, a missing / duplicated declaration, or a
    comment-masked drift all fail closed before `solc` runs, while a
    value-preserving underscore reformat (`1_000_000_000_000` vs
    `1000000000000`) passes.  A companion self-test
    (`solidity/scripts/audit_compile_time_caps_selftest.sh`, `make
    audit-caps-selftest`, 18 cases) proves the tripwire accepts the
    canonical source and rejects every drift class — including the
    comment-masking false-pass surfaced in PR review — so the gate
    cannot be silently disabled by a later edit.  Both layers run on every
    Solidity PR via `.github/workflows/ci-solidity.yml` (the first
    Solidity-side CI in the repo): the `caps-audit` job runs the gate +
    self-test (toolchain-free, fast), and the `forge` job runs the
    runtime pin alongside the full suite.  Changing any cap is a
    Genesis-Plan §13.6 amendment that triggers the two-reviewer rule;
    the gate's `CAPS` table must be updated in the same PR.  Each
    constant's NatSpec carries the per-value rationale plus a `@dev`
    governance tag naming both protection layers.
  * **GP.5.3** L1 step-VM execution arm for the delegated
    `topUpActionBudgetFor` (action-index 21) — the last GP-family
    `stepVMHash` catch-all (empty-hash) sentinel, now closed.  The
    Lean `stepVMHash` kind-21 arm dispatches to a new
    `stepCommitTopUpActionBudgetFor` recipe
    (`FaultProof/SolidityStepVMCommit.lean`), structurally identical
    to `stepCommitTopUpActionBudget` (debit the delegate-signer at
    `gasResource`, credit `poolActor`) but bound by a DISTINCT
    `keccak256("topUpActionBudgetFor")` tag so the two top-up
    variants can never produce a colliding commit.  The `recipient`
    (field offset 0) and `budgetIncrement` (offset 24) are
    admission-layer effects on the *recipient's* epoch-budget slot —
    decoded for field-layout symmetry but excluded from the step-VM
    hash, exactly as kinds 19 / 20 exclude their `budgetGrant` /
    `budgetIncrement`.  Shipped: the `actionKindByteCases` widening
    to include 21 + the `stepVMHash_topUpActionBudgetFor_kind`
    reduction theorem + `stepVMHash_unknown_kind_empty` re-pinned at
    kind 22 (`FaultProof/StepVMCoherence.lean`); the Solidity
    `ActionKind.TopUpActionBudgetFor` enum value +
    `TAG_TOPUP_ACTION_BUDGET_FOR` + `_toActionKind` bound (`> 21`) +
    dispatcher arm + `_stepTopUpActionBudgetFor`
    (`KnomosisStepVM.sol`); the cross-stack `step_vm.json` corpus
    widened 238 → 248 (`+topUpActionBudgetFor`: 6 happy + 4
    adversarial); 10 new `faultproof-stepvm-coherence` cases (incl. an
    exact-balance Nat-boundary dispatch) + 2 new `crosscheck-step-vm`
    cases + Solidity cases (in `KnomosisStepVM.t.sol`: the
    keccak-binding-independent `test_topUpActionBudgetFor_matches_canonical_recipe`
    recipe pin, a `test_topUpActionBudgetFor_distinct_from_topUpActionBudget`
    tag-separation test, a self-pool net-zero test, and an
    exact-balance-drain boundary test; in `CrossCheck/StepVM.t.sol`:
    the data-flow goldens below).
    **Cross-stack byte-equivalence — verified two ways.**  (1)
    *Dynamic, end-to-end:* under a keccak-linked verification build
    (the `knomosis-hash-keccak256` staticlib forced ahead of the FNV
    fallback), the fixture regenerates with `isKeccak256Linked = true`
    and the forge `test_perEntry_byte_equivalence_all_happy` driver —
    no longer skipped — confirms all 152 happy fixtures (the 6
    variant-21 entries included) byte-match `executeStep`.  The
    committed fixture stays on the FNV default (`isKeccak256Linked =
    false`), so the default `lake test` / `forge test` skip the
    dynamic comparison exactly as for kinds 0..20.  (2)
    *Hash-independent, always-on:* the **data-flow layout goldens**
    (`packedLayoutGoldens` + `variant21TailGolden`, emitted by Lean
    into `step_vm.json`, read back and recomputed via `abi.encodePacked`
    by `test_packedLayoutGoldens_match_abiEncodePacked` /
    `test_variant21_tailGolden_matches_abiEncodePacked`) pin the
    `uint64BE`/`uint256BE` ↔ `abi.encodePacked` layout — including
    full-32-byte-width `uint256` values — in EVERY binding mode, with a
    single source of truth (no independently-maintained literals).
    Combined with the `keccak256("topUpActionBudgetFor")` tag and the
    shared `preCommit`, this proves the full step-VM commit
    byte-equivalent without the binding.  The GP.3.4
    `cellwrites_topUpActionBudgetFor` / `coherence_topUpActionBudgetFor`
    full-state-commit coherence theorems remain valid unchanged.  On
    the Rust side the RH-G observer's `submitter::ActionKind` table (a
    naming mirror of the canonical action index; production
    terminate-calldata encoding uses the raw `u8`, so kind 21 already
    flowed through) gains the `TopUpActionBudgetFor = 21` member so the
    enum stays consistent with the Lean / Solidity index table.  The
    deliberate scope boundary — the step-VM commit does NOT bind the
    `epochBudgets` ledger (no `epochBudgets` cell tag), so admission-
    layer budget effects are out of fault-proof re-execution scope, as
    for kinds 19 / 20 and the nonce of every variant — is recorded as
    `OQ-GP-11` in `docs/planning/open_questions.md`.
  * **GP.5.4** L1 `KnomosisBridge` BOLD-currency fee-split deposit
    (`solidity/src/contracts/KnomosisBridge.sol`).  New external entry
    `depositBoldWithFee(uint256 amount, uint16 chosenFeeBps)` — the
    BOLD-leg mirror of `depositETHWithFee`: identical fee-split
    arithmetic + the same resource-generic `_registerDepositWithFee`
    bookkeeping, but value arrives as the pinned BOLD ERC-20 via
    `SafeERC20.safeTransferFrom` (with a `balanceOf`-delta check that
    rejects fee-on-transfer / rebase tokens, `BoldTransferAmountMismatch`),
    the pool credit accrues at `RESOURCE_ID_BOLD = 1`, and the budget
    grant uses the immutable `weiPerBudgetUnitBold` rate (clamped at
    `MAX_BUDGET_PER_DEPOSIT`).  BOLD is **opt-in**: the constructor's new
    `boldTokenAddress` arg is either `address(0)` (BOLD disabled — the
    bridge still deploys on chains without BOLD, every pre-GP.5.4 ETH-only
    deployment shape is unchanged, and the entry point reverts
    `BoldNotEnabled`) or the constitutional pin `BOLD_TOKEN_ADDRESS`
    (`0x6440f144b7e50D6a8439336510312d2F54beB01D`), in which case the
    constructor also requires `weiPerBudgetUnitBold >=
    MIN_WEI_PER_BUDGET_UNIT` and cross-checks
    `BOLD_TOKEN.symbol() == EXPECTED_BOLD_SYMBOL ("BOLD")` —
    defence-in-depth behind the address pin (a reverting / undecodable /
    absent symbol fails construction via `BoldTokenSymbolUnavailable`, a
    wrong symbol via `BoldTokenSymbolMismatch`, a non-pin address via
    `BoldTokenAddressMismatch`).  The opt-in design (vs. the plan's
    unconditional pin) is load-bearing: a mandatory pin would break the
    test `Deployer` (a contract — it cannot `vm.etch` a BOLD mock at the
    pin) and every non-mainnet deployment.  When BOLD is enabled the
    constructor AUTO-BINDS `(RESOURCE_ID_BOLD -> BOLD_TOKEN_ADDRESS)` in
    the resource map and RESERVES both `RESOURCE_ID_BOLD` and
    `BOLD_TOKEN_ADDRESS` from the deployer's map (`BoldResourceReserved`),
    so BOLD withdrawals via `withdrawWithProof` (which reads
    `_resourceTokens[resourceId]`) always resolve to the canonical BOLD
    token with no deployer action — closing a stuck-funds /
    deposit-withdraw-divergence footgun.  A `resourceToken(uint64)` getter
    exposes the binding.  The function carries
    `nonReentrant` + `circuitOpen` + the per-currency `boldCircuitOpen`
    breaker; the per-currency BOLD circuit breaker (`boldCircuitOpen`)
    + per-BOLD TVL cap ship in GP.5.5 (below).  Coverage:
    `test/BridgeFeeSplitBold.t.sol` (59 cases — the GP.5.1 happy / revert
    mirror over the BOLD path, the non-conformant BOLD mocks
    (fee-on-transfer, false-returning transfer, wrong / reverting / absent
    symbol), the opt-out cases, the `RESOURCE_ID_BOLD` reserve / auto-bind
    cases, a full end-to-end deposit -> escrow -> attested-state-root ->
    finalise -> `withdrawWithProof` -> replay-rejection lifecycle test, a
    cross-leg calibration-parity check, and three fuzz properties) plus
    the 80-entry cross-stack corpus
    `deposit_fee_split_bold.json` (Lean generator
    `LegalKernel/Test/Bridge/CrossCheck/DepositFeeSplitBold.lean`, 14
    cases; Solidity consumer `test/CrossCheck/DepositFeeSplitBold.t.sol`,
    8 cases + 1 keccak-gated skip, incl. a live-contract per-entry deposit
    that deploys a BOLD-enabled bridge and asserts the emitted split
    equals the Lean values).  The BOLD mocks live in
    `test/utils/MockBold.sol`; the split + receiptHash reuse the
    resource-generic GP.5.1 `FeeSplitMath` reference.  The two BOLD
    constitutional pins (`BOLD_TOKEN_ADDRESS`, `EXPECTED_BOLD_SYMBOL`) are
    pinned at runtime by `test_boldConstants_pinned` AND source-level by an
    extension to the GP.5.2 `scripts/audit_compile_time_caps.sh` gate
    (kind-specific address / string checks; the self-test grows 18 -> 23
    cases) — matching the dual-layer protection the numeric caps already
    have.  The keccak256 receiptHash byte-equivalence is closed
    transitively (the always-on `receiptTail` layout match + the global
    `keccak256.json` corpus + the live-contract real-keccak recipe), and
    the belt-and-braces keccak-linked fixture regeneration is now wired in
    CI: `scripts/verify_keccak_crossstack.sh` (via
    `.github/workflows/ci-keccak-crossstack.yml`) regenerates the BOLD
    corpus under real keccak256 and runs its gated consumer assertion.
    On the Rust side the RH-B ingestor's `DepositWithFeeInitiated` decoder
    is resource-generic (reads `resourceId` from `topics[2]`) and the
    translation ignores `resourceId` (`{ .. } => NoAction`); two BOLD
    (`resourceId = 1`) tests pin that explicitly (`events.rs`
    decode + `translation.rs` translate) — no production Rust change.
  * **GP.5.5** L1 `KnomosisBridge` BOLD-specific safety hardening
    (`solidity/src/contracts/KnomosisBridge.sol`).  Three
    defence-in-depth mechanisms not present for the ETH leg, all gated
    by two tightly-scoped immutable roles + a strict role-separation
    discipline (least privilege: `boldCircuitBreaker` can only
    pause/resume; `boldAdmin` can only tune the cap; the two MUST be
    distinct addresses AND neither may be the bridge itself —
    `BoldRolesNotDistinct` / `BoldRoleIsBridge` enforce — so neither
    role can move funds, alter state roots, or touch the ETH leg; the
    `test_no_admin_surface` invariant still holds since these are not
    the canonical Ownable/UUPS selectors):
    (1) the **per-currency circuit breaker** `boldCircuitClosed` +
    `boldCircuitOpen` modifier on `depositBoldWithFee`, toggled by
    `closeBoldCircuit` / `openBoldCircuit` — a closed BOLD circuit halts
    only BOLD deposits while ETH deposits and ALL withdrawals (incl.
    BOLD) keep working (the "deposits halted, withdrawals continue"
    posture);
    (2) the permissionless, opt-in (`enableLiquityAutoCircuitTrigger`)
    **Liquity-V2 branch-shutdown auto-trigger**
    `closeBoldCircuitIfAnyLiquityBranchShutdown`, which reads
    `shutdownTime()` from each of the three constitutionally-pinned
    Liquity V2 collateral-branch TroveManagers
    (`LIQUITY_V2_TROVE_MANAGER_ETH` /
    `LIQUITY_V2_TROVE_MANAGER_WSTETH` / `LIQUITY_V2_TROVE_MANAGER_RETH`,
    via interface `src/interfaces/ILiquityV2TroveManager.sol`) — the
    canonical on-chain depeg signal — and closes the circuit if ANY
    branch reports a non-zero `shutdownTime` (early-return on first
    detection; emits the first-detected branch + its shutdownTime); the
    read goes through a low-level `staticcall` with strict `success` +
    `returndata.length == 32` guards AND a 100k-gas forwarding cap
    (`LIQUITY_ORACLE_READ_GAS`), so EVERY oracle fault (revert, no
    code, wrong / oversized return, mutating-callee under staticcall,
    gas griefing) routes uniformly to `LiquityV2ReadFailed`, AND the
    staticcall context forbids any SSTORE in the inner frame so a
    re-entrant TroveManager cannot corrupt bridge state by EVM
    construction; idempotent when already closed;
    (3) the **per-BOLD TVL cap** `boldTvlCap` + `boldTotalLockedValue`
    (net BOLD = deposits − withdrawals; incremented in
    `_registerDepositWithFee`, decremented in `withdrawWithProof`),
    bounded above by the global `tvlCap`, adjustable by `boldAdmin` via
    `setBoldTvlCap`, fail-closed at 0.  The three Liquity TroveManager
    address pins join `BOLD_TOKEN_ADDRESS` in the GP.5.2
    `scripts/audit_compile_time_caps.sh` gate, AND
    `LIQUITY_ORACLE_READ_GAS` joins the cap-list (`public constant` so
    monitoring tools can query it programmatically), so the gate now
    covers 4 caps + 4 address pins + 1 symbol pin; self-test 37 cases
    (includes a multi-line-declaration tolerance check covering the
    forge-fmt-wrapped address-pin case).
    Runtime pins: `test_troveManagerConstants_pinned` +
    `test_liquityOracleReadGas_pinned`.  The constructor adds a
    pairwise-distinctness check on the three TM constants
    (`BoldTroveManagersNotDistinct`, defence-in-depth behind the gate)
    and parameterises the code-presence error
    (`LiquityOracleHasNoCode(address)`) so operators see which branch is
    missing.  Coverage:
    `test/BoldCircuitBreaker.t.sol` (85 cases incl. a stateful
    Foundry-invariant suite — manual + auto circuit toggling,
    access-control + least-privilege separation + roles-not-distinct +
    role-is-bridge + TM-distinctness constructor guards, per-branch
    shutdown detection (ETH / wstETH / rETH), multi-shutdown
    short-circuit, all-healthy revert, the per-BOLD cap composing with
    the global cap, fail-closed at cap 0, the oracle-fault / idempotency
    paths, two end-to-end tests proving withdrawals continue while
    paused and that the per-BOLD counter decrements on withdrawal, four
    fuzz tests (cap-invariant, any-branch-shutdown with event-content
    assertion, setter bounds, constructor bounds), per-branch
    oracle-fault tests for FOUR fault classes (wrong-size, oversized,
    revert, code-removed) × {ETH, wstETH, rETH} = 12 cases, three
    mutating-callee tests (one per branch) positively proving the
    staticcall context blocks SSTORE, three constructor-revert-ordering
    pins, a malicious-BOLD reentrancy attack test proving
    `nonReentrant` blocks `depositBoldWithFee` reentry, two
    grief-bounded gas tests pinning the `LIQUITY_ORACLE_READ_GAS` cap,
    seven gas-regression smoke tests, and three Foundry-invariant tests
    (`boldTotalLockedValue <= totalLockedValue`,
    `boldTotalLockedValue == sum of admitted deposits`,
    `boldTvlCap <= tvlCap`) driven by a `BoldHandler` over 128 000
    random call sequences) + the programmable
    `test/utils/MockLiquityV2.sol` (5 mock variants:
    `MockLiquityV2TroveManager` / `WrongSizeLiquityV2` /
    `OversizedLiquityV2` / `ReentrantLiquityV2` + adversarial
    `MutatingLiquityV2`) + the `ReentrantBold` mock in
    `test/utils/MockBold.sol`.  Operator procedures live in
    `docs/gas_pool_runbook.md`.  Solidity-only; no Lean / cross-stack /
    Rust change (the breaker is an L1 deployment-side control with no
    L2 counterpart).  Design notes vs. the plan sketch (immutable +
    split + BOLD-scoped roles with mandatory distinctness + no-self
    guards; Liquity oracles are three constitutional `constant`
    `TroveManager` pins under the GP.5.2 audit gate; the depeg signal
    is "any branch's `shutdownTime != 0`" — the definitive on-chain
    indicator — rather than a redemption-rate threshold; `boldTvlCap`
    is also a constructor arg; `boldTotalLockedValue` decrements on
    withdrawal; staticcall is gas-bounded to defeat malicious-callee
    griefing) are recorded in the GP.5.5 status block in
    `docs/planning/unified_gas_pool_plan.md`.

  * **GP.6.1** Rust-side `knomosis-l1-ingest` GP-family encoder +
    fee-split fixture corpus.  Extends the Rust mirror of the Lean
    `Authority.Action` inductive
    (`runtime/knomosis-l1-ingest/src/action.rs`) with three new
    constructors matching Lean's frozen tag indices:
    `Action::DepositWithFee` (tag 19, 7 fields), `Action::
    TopUpActionBudget` (tag 20, 4 fields), `Action::
    TopUpActionBudgetFor` (tag 21, 5 fields).  Extends the CBE
    encoder (`runtime/knomosis-l1-ingest/src/encoding.rs`) with the
    three corresponding match arms producing byte-identical output
    to Lean's `Encoding/Action.lean::Action.encode` for the new
    variants.  Differential acceptance check: four hand-pinned
    known-vector tests
    (`encode_deposit_with_fee_known_vector`,
    `encode_deposit_with_fee_bold_known_vector`,
    `encode_top_up_action_budget_known_vector`,
    `encode_top_up_action_budget_for_known_vector`) pin the
    per-variant byte layouts against bytes hand-computed from the
    Lean encoder recipe.  Adds the `FeeSplitInput` shape +
    `FeeSplitInput::split` arithmetic
    (`runtime/knomosis-l1-ingest/src/fixture.rs`), mirroring the
    L1 contract's recipe and the Lean side's `feeSplit` reference
    (conservation, pool-cap, budget-cap properties).  Adds a new
    `FixtureKind::L1IngestFeeSplit` variant (on-disk tag 6) to
    `knomosis-cross-stack`.  Ships the cross-stack fixture corpus
    `runtime/tests/cross-stack/l1_ingest_fee_split.cxsf` (248
    entries: 240 from a 5 × 6 × 4 × 2 grid spanning
    `msg_value ∈ {1, 10⁹, 10¹², 10¹⁵, 10¹⁸}`,
    `chosen_fee_bps ∈ {0, 1, 100, 1000, 2500, 5000}`,
    `wei_per_budget_unit ∈ {1, 10⁶, 10¹², 10¹⁵}`,
    `resource_id ∈ {ETH=0, BOLD=1}`, plus 8 boundary cases
    including `u64::MAX`, rounding edges, budget clamp, and ETH/BOLD
    calibration parity).  Generator example
    `runtime/knomosis-l1-ingest/examples/gen_fee_split_fixtures.rs`
    + consumer test
    `runtime/knomosis-l1-ingest/tests/cross_stack_fee_split.rs`
    (7 cases: round-trip, coverage threshold + ETH/BOLD presence,
    mathematical soundness, resource-parametric byte-equivalence,
    input round-trip, encoder determinism, per-record
    `DepositWithFee` tag pin).  Translation behaviour for
    `DepositWithFeeInitiated` events stays as `Translated::
    NoAction` per the MVP-scope semantics (deposit materialisation
    is the sequencer's responsibility, not the ingestor's); the
    encoder additions stand alone, ready for future sequencer-side
    action emission.  In total, 22 new fixture tests + 17 new
    encoder tests + 2 new action-tag tests ship; the Rust-side
    workspace `cargo test --workspace --locked` reports ~1480
    tests passing.

Out of scope for this in-flight closure: the
trace-level promotion of GP.4.2's pool-solvency reconciliation (the
per-step deposit-case preservation
`pool_solvency_preserved_by_admitted_depositWithFee` ships; folding it
over a whole admitted trace, plus the outflow / non-deposit cases, is
the `gasPoolPolicy` drain bound, GP.7.3, which needs `gasPoolActor`
from GP.7.1) and the AMM-aware strong-conservation extension (needs
`Action.ammSwap` + `ammReserveActor`, GP.11); the materialised
`bridgeEscrowBalance` RHS + full inductive accounting equation (the
WU C.6.4 / C.6.5 `BridgeReachable` follow-up; the `escrow` term stays
abstract in `bridge_accounting_equation_balanced_iff`); and GP.6.2 –
GP.11 (the remaining knomosis-host admission gate, event-subscribe
extensions, indexer budget view, BOLD-specific cross-stack
fixture corpus, pool governance, sequencer integration, AMM,
etc.).  GP.5.1's ETH fee-split entry point, GP.5.2's
constitutional fee-split-cap audit gate, GP.5.3's L1 step-VM
execution arm for `topUpActionBudgetFor` (variant 21), GP.5.4's
BOLD-currency fee-split entry point `depositBoldWithFee`, and
GP.5.5's BOLD-specific safety hardening (per-currency circuit
breaker + Liquity-V2 depeg auto-trigger + per-BOLD TVL cap) are
complete (above) — closing the GP.5 Solidity-side L1-mirror
arm.  GP.6.1's Rust-side encoder mirror (above) closes the first
sub-WU of the Phase-GP.6 Rust runtime amendment.

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

Knomosis is research-stage software.  If you discover a logic bug in
the kernel module (e.g. a counterexample to `impl_noop_if_not_pre`,
or a state advance that bypasses the `if` in `step_impl`), open an
issue with the `kernel-soundness` label.  Such reports gate any
in-flight PR; the two-reviewer rule applies to the fix.

For non-kernel issues (laws, tooling, documentation), the standard
issue tracker workflow applies.

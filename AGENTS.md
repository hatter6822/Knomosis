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
# GP.7.4 worked unified-gas-pool deployment, end-to-end (genesis
# wiring -> ETH + BOLD deposits -> dual sequencer claim -> log persist
# -> replay round-trip):
.lake/build/bin/knomosis gas-pool-demo
# Event-subscription extractor backend (RH-D / GP.6.3): streams the
# Event list per log-frame request on stdin; the off-chain
# knomosis-event-subscribe SubprocessExtractor drives it.
.lake/build/bin/knomosis extract-events --log /tmp/test.log  < /dev/null

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
│   ├── Encoding/              -- CBE codec (CBOR, Encodable, Action, Event,
│   │                             SignedAction,
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
│   ├── Runtime/               -- Hash, LogFile, Replay, EventStream, Snapshot, Loop (Phase 5);
│   │                             BudgetSidecar (GP.6.2) + GasPoolSidecar (GP.7.4) +
│   │                             RefundRateSidecar (GP.9.1) config persistence
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
├── Deployments/Examples/      -- worked example deployments: UsdClearing
│                                  (LX-M3) + GasPoolExample (GP.7.4 genesis
│                                  ratification, runnable via `knomosis
│                                  gas-pool-demo`)
├── Tools/                     -- non-Lex audit binaries (TcbAudit, CountSorries,
│                                  StubAudit, NamingAudit, DeferralAudit) +
│                                  shared `Common` library.  (Lex audit
│                                  binaries live under `Lex/Tools/` and
│                                  `Lex/Bin/`.)
├── solidity/                  -- Workstreams E + H: L1 mirror (10 contracts,
│                                  6 libraries incl. the GP.11.3 `AmmMath`
│                                  swap-math lib, 20+ forge test suites).
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
        ├── step_vm_coherence_plan.md        -- L1 step-VM 19-variant coherence + observer terminate wiring
        ├── fair_queuing_plan.md             -- Workstream FQ (per-actor fair queuing; superseded by the GP.8 plan)
        └── GP.8_SEQUENCER_INTEGRATION_PLAN.md -- Workstream GP.8 (sequencer: fair queuing + reimbursement + config + ops)
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
                      EventStream, Snapshot, AttestedSnapshot,
                      Loop}                    (non-TCB; depends on Encoding + Events.
                                                EventStream (RH-D / GP.6.3) wraps
                                                Replay + Events.Extract for the
                                                `extract-events` per-frame step)

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
| GP.7.0 | Bridge actor signs EXACTLY the four L1-attested actions (exhaustive characterisation; forcing function for future constructors) | `bridgeAuthorizedAction_eq_true_iff`, `bridgePolicy_authorizes_all_bridge_actions`, `bridgePolicy_rejects_non_bridgeable` | `Bridge/BridgeActor.lean` |
| GP.7.1 | Reserved gas-pool actors are pairwise distinct; genesis `nextActorId` advances to 3 so `assign` never issues a reserved slot (Rust adaptor mirrors the genesis) | `gasPoolActor_ne_bridgeActor`, `sequencerActor_ne_bridgeActor`, `sequencerActor_ne_gasPoolActor`, `AddressBook.addressBook_empty_nextActorId`, `empty_assign_id_avoids_reserved` | `Bridge/BridgeActor.lean`, `Bridge/AddressBook.lean` |
| GP.7.2 | Gas-pool outflow is a capped sequencer-only `transfer` of the pool's OWN funds (`sender = gasPoolActor`); the policy permits EXACTLY that set, is silent off the two gas legs, and the LP.7 meta-action exemption + the sender-debit drain vector are closed by a complementary `AuthorityPolicy` | `gasPoolPolicy_denies_all_non_transfer`, `gasPoolPolicy_permits_transfer_iff`, `gasPoolPolicy_admission_permits_meta_actions`, `gasPoolAuthorityPolicy_rejects_meta`, `gasPoolAuthorityPolicy_rejects_non_pool_sender`, `gasPoolAuthorityPolicy_intersect_rejects_meta` | `Bridge/GasPoolPolicy.lean` |
| GP.7.3 | Per-epoch pool drain is bounded **per-resource**: across any contiguous trace of `n` admitted SignedActions respecting the gas-pool discipline, `gasPoolActor`'s leg-`rLeg` balance cannot have decreased by more than `n × legCap mEth mBold rLeg` (inductive promotion of the GP.7.2 per-action cap; rests on `gasPoolAuthorityPolicy`, the sender-blind `LocalPolicy` being insufficient; the non-pool obligation is discharged exhaustively over every `Action`; the literal executable fold ships as `applyTrace`; the per-step bound lifts onto the budget-gated runtime entry) | `pool_drain_bounded_by_action_count_per_resource`, `pool_drain_bounded_by_action_count{,_bold}`, `pool_balance_lower_bound_via_trace`, `pool_nondecreasing_of_does_not_debit`, `per_resource_pool_independence`, `applyTrace_drain_bounded_per_resource`, `pool_signed_step_drain_le_budget` | `Bridge/PoolDrainBound.lean` |
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
| RH-D      | Rust host: event subscription      | Complete (incl. the Lean `knomosis extract-events` subcommand + `Encodable Event` — landed under GP.6.3) |
| RH-E.0    | Rust host: storage abstraction     | Complete |
| RH-E.1    | Rust host: SQLite indexer          | Complete (Rust framework; `--verify-against-knomosis` wiring deferred pending knomosis-host getBalance endpoint) |
| RH-F      | Rust host: 10k tx/sec benchmark    | Complete (harness ships; observed throughput ~7.5k ops/sec under default workload — gap documented in plan §RH-F closeout) |
| RH-G      | Rust host: fault-proof observer    | Complete (off-chain observer daemon; game state machine + honest strategy + L1 watcher + persistence + JSON-RPC EIP-1559 submitter + `knomosis replay-up-to` / `knomosis export-cell-proofs` subcommands + eth_call game-state reader + chaos suite + 50-trace cross-stack corpus) |
| SC.1      | SMT cell proofs: Lean spec + soundness | Complete |
| SC.2      | SMT cell proofs: Solidity verifier | Complete |
| SC.3      | SMT cell proofs: cross-stack soundness + corpus | Complete |
| SVC       | L1 step-VM cross-stack coherence + observer terminate wiring | Complete (Lean + Rust; cross-stack fixture corpus with cell-proof bundles emitted per fixture entry — 218 entries / 134 happy at SVC close, since widened by GP.3.3 → 238 and GP.5.3 → 248 / 152 happy; every happy fixture byte-equivalence-tested against Solidity `executeStep` under `isKeccak256Linked = true` via a single uniform driver) |
| E-G       | Ethereum: documentation + amendment | Complete (GENESIS_PLAN §15D + ABI §16 + extraction_notes §2.X + std_dependencies refresh) |
| FQ / GP.8 | Per-actor fair queuing / burst resistance (knomosis-host) | Track A complete: Rung 0 (connection-keyed DRR) + Rung 1 (signer-hint wire `PROTOCOL_VERSION 2` + two-tier DRR), default-OFF `--scheduler drr`, + the `--persistent-connections` pipelined mode under which DRR fair scheduling is exercised through the wire (`tests/persistent.rs`); Tracks B–D (reimbursement claim / config guidance / runbook) future work — see `docs/planning/GP.8_SEQUENCER_INTEGRATION_PLAN.md` |
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

**Test count.**  ~2 753 tests across 141 suites (the GP.7.4 genesis
ratification adds the `deployments-gas-pool-example` suite, 17 cases —
the end-to-end ETH+BOLD `depositWithFee` → user+pool credit → L2
budget-grant → dual capped sequencer-claim worked sequence run through
the production admission gate, the final user / pool / sequencer
balances on both legs, the user's budget = free tier + both grants,
a proof-carrying budget-grant tie (via `depositWithFee_grants_budget_bridge`),
genesis fidelity (the state declares `gasPoolPolicy`), the discipline
rejections against a well-funded pool (over-cap ETH / BOLD,
pool meta-action, victim-sender, non-sequencer), the
intersection-narrows-only-the-pool positive case, an honest per-half
contribution test (LocalPolicy caps the amount but is sender-blind +
meta-exempt; the AuthorityPolicy is the binding enforcer), a
restrictive-base (`bridgePolicy`) composition, a snapshot round-trip of
the gas-pool genesis state, the
`knomosis gas-pool-demo` IO binary's process → log → replay round-trip,
and term-level API stability for the `gasPoolGenesis*` hook surface —
plus the new `runtime-gas-pool-sidecar` suite, 9 cases — the
`GasPoolSidecar` codec round-trip + tolerant/rejecting decode + the
`checkConsistent` / `writeSidecarIfAbsent` discipline (enabled enforced,
disabled writes no sidecar, a gas-pool-disabled run against an enabled
log rejected) + the `*OfConfig` opt-in/opt-out genesis builders.
Earlier, the GP.7.3
inductive pool-drain bound — at its optimal/per-resource closure — adds
the `bridge-pool-drain-bound` suite, 23 cases — the per-step ETH drain
(value + the live `pool_signed_step_drain_le_eth`), the BOLD-leg drain +
per-resource bound (`…_bold` / `…_per_resource`) with two-leg
independence (`per_resource_pool_independence`), the EXHAUSTIVE external
discharge value-checked on credit/no-op/other-sender actions
(`pool_nondecreasing_of_does_not_debit`) + the `doesNotDebitPoolAt`
classifier, 1-/2-/3-step pure-pool and mixed pool/external
`PoolBoundedTrace`s with the numeric `pool_drain_bounded_by_action_count`
bound + the `pool_balance_lower_bound_via_trace` floor, the EXECUTABLE
`applyTrace` fold driven at runtime (+ `applyTrace_drain_bounded_per_resource`)
plus the `applyTrace_yields_poolBoundedTrace` bridge fed through the
relation-form bound, the runtime-entry lift value-checked over the LITERAL
budget-gated `apply_bridge_admissible_with_budget` (`pool_signed_step_drain_le_budget`,
with an epoch-advanced budget policy so `gasPoolActor` clears the gate),
the discipline rejections (over-cap, victim-sender, non-sequencer,
off-leg, meta-action, zero-amount), the at-cap drain, the
`maxDrainPerActionEth = 0` boundary (`pool_cannot_drain_when_cap_zero`),
genesis-wiring fidelity (declared `gasPoolPolicy` + intersected
`gasPoolAuthorityPolicy`), and term-level API stability for every
headline theorem + the `PoolBoundedTrace` constructors + the
runtime-entry lift.  Earlier, the GP.7.2
canonical `gasPoolPolicy` adds the `bridge-gas-pool-policy` suite,
61 cases — the deny-list shape, only-`transfer` outflow across
every non-transfer Action tag (1..21, none skipped), per-leg
ETH/BOLD recipient + amount cap boundaries, the
`maxDrainPerAction = 0` degenerate case, leg independence, the
`permits_transfer_iff` source-of-truth characterisation, the
resource-`≥ 2` permissiveness boundary, the admission-layer
(`localPolicyPermits`) characterisation INCLUDING the proven
LP.7 meta-action escape hatch, `fieldsBounded` + CBE round-trip
(the GP.7.4 genesis prerequisite), sender-independence, and — the
escape-hatch fix — the complementary `gasPoolAuthorityPolicy`
(it bars `gasPoolActor` meta-actions + off-leg + non-sequencer +
over-cap transfers at the exemption-free AuthorityPolicy conjunct,
is a no-op on non-pool actors under `intersect`, and is wired
end-to-end), plus term-level API stability for every headline
theorem.  Earlier, the GP.7.1
`gasPoolActor` reservation grows the `bridge-actor` suite by a
further 13 cases, 71 total — the `gasPoolActor` = 1 /
`sequencerActor` = 2 constant values, pairwise distinctness, the three
disjointness theorems' term-level API
(`gasPoolActor_ne_bridgeActor` / `sequencerActor_ne_bridgeActor` /
`sequencerActor_ne_gasPoolActor`), the genesis
`addressBook_empty_nextActorId` + its term-level API, an `empty` +
`assign` integration pinning the first issued id at 3 and distinct
from all reserved slots, a below-genesis bound on every reserved id,
and the reservation-guarantee theorem `empty_assign_id_avoids_reserved`
(value + term-level + a check that no reserved actor appears in the
post-`assign` reverse map) — and rebases the `bridge-address-book`
(31) / `bridge-ingest` (28) value fixtures onto the new genesis id 3
(`assign` allocation now starts at 3).  Earlier, the GP.7.0
exhaustive bridge-policy characterisation grew the `bridge-actor`
suite by 20 cases, 58 total — value-level `bridgeAuthorizedAction`
checks + iff forward/backward at `replaceKey` / `deposit` /
`depositWithFee` + term-level API stability for
`bridgeAuthorizedAction_eq_true_iff`
/ `bridgePolicy_authorizes_all_bridge_actions` /
`bridgePolicy_rejects_non_bridgeable` + exhaustive rejection applied
to `transfer` / `mint` / `proportionalDilute` / `topUpActionBudget` /
`topUpActionBudgetFor` / `faultProofChallenge` + five END-TO-END
admission cases under `bridgePolicy` itself (not
`AuthorityPolicy.unrestricted`) driving the full `BridgeAdmissibleWith`
pipeline: bridge-signed `depositWithFee` / `deposit` /
`registerIdentity` admitted, bridge-signed `transfer` /
`topUpActionBudget` rejected; the GP.6.5
BOLD-specific cross-stack corpus adds the `crosscheck-bold-deposit`
suite, 21 cases — incl. two Lean theorems binding the corpus's
recipient-budget post-state to the production admission gate's
grant arm (`recipientBudgetCell_currentBudget` /
`recipientBudgetCell_matches_gate`); the GP.6.3 full
RH-D closure adds the `encoding-event` (10), `runtime-extract-events`
(9), and `crosscheck-event-cbe` (5) suites for the `Event` CBE codec,
the `extract-events` step + wire framing, and the Lean→Rust
`Event.encode` cross-stack differential).  At the GP.5.3
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
    21 `Event` pins (0..20, after the GP.6.4 `budgetConsumed`).

  * `faultproof-stepvm-coherence` (115 cases, GP.3.3 + GP.5.3 + GP.9.1) —
    pins the 23-variant step-VM dispatcher byte-for-byte against
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
  * `crosscheck-step-vm` (40 cases, GP.3.3 + GP.5.3 + GP.9.1) — pins
    per-variant fixture counts for the 258-entry corpus (218 from
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

**Rust-side test count.**  ~1 919 tests across the 11 workspace
crates (the persistent + pipelined connection mode adds ~17 tests — the
opt-in `--persistent-connections` host flag + `run_persistent`
reader/writer pipelined handler wiring `ConnReader`'s persistent path,
with a BOUNDED reader→writer `sync_channel` (sized to
`QueueHandle::pipeline_capacity`) so a non-reading client back-pressures
instead of growing host memory (an OOM-DoS an unbounded channel allowed);
`tests/persistent.rs` (7 e2e cases over REAL TCP: v2 + v1 pipelining,
one-shot back-compat, the DRR-bites-through-the-wire fairness test + its
FIFO contrast, graceful shutdown with an open connection, and the
bounded-channel back-pressure regression); the
`knomosis-host` `config.rs` flag tests; the `knomosis-bench --persistent`
pipelined client (2 standalone smoke cases) + its `--persistent` config
test + the `report.rs` persistent wire-mode-mismatch `NotComparable` test;
and the 4 `knomosis-bench` `main.rs` exit-path unit tests
(`regression_verdict_to_result` / `exit_code_for`, closing the
untested-CLI-glue gap).  The FQ Rung-1 post-review hardening adds ~17 tests
— the
per-connection aggregate-backlog cap `--max-conn-backlog` (default =
`--per-flow-cap`, restoring the Rung-0 per-connection bound the two-tier
split would otherwise relax to `max_signers × per_flow`; new
`RejectReason::ConnBacklog` + `DrrStats::rejected_conn_backlog`, the
leaf-first check ordering so `per_flow` stays attributable, the
`src/fair/drr.rs` aggregate-cap + default + clamp tests, the six
`src/config.rs` flag parse / default / zero / too-large / cross-field
tests, the `src/queue.rs` hint-rotation-confinement test, and the
`tests/fair_queue.rs` queue-level aggregate-cap test) plus the
`knomosis-bench` `BenchmarkReport.emit_hints` / `persistent` wire-mode
fields (`#[serde(default)]` legacy-baseline load + the
`RegressionVerdict::NotComparable` wire-mode guard so a hinted / persistent
candidate is never silently compared against a legacy baseline); the FQ Rung-1
signer-hint wire amendment + two-tier DRR
adds ~60 tests — incl. an audit-pass round closing coverage gaps: the
`--max-signers-per-conn` config flag's parse / default / non-numeric /
zero-rejected-intrinsic / too-large / caps-plumbing tests (mirroring its
`--per-flow-cap` / `--max-flows` siblings), the `Box<dyn Submitter>`
delegation test, and the `v2_preamble_only_then_close_is_clean`
negotiation-robustness test; plus the `src/frame.rs` Rung-1 wire suite (preamble
negotiation, hinted-frame read incl. the dedicated `TruncatedHint` +
`TruncatedHintedFrame` committed-but-truncated variants, the
`ConnReader` per-connection read-state machine (one-shot + persistent
multi-frame v1/v2, negotiates once), the compile-time + runtime
`HARD_MAX_FRAME_SIZE < KNH2_MAGIC` collision invariant, the
`encode_hinted_frame` round-trip, and the negotiation fuzz that never
misclassifies a v1 frame), the two-tier `src/fair/drr.rs` tests (the
extracted single-tier `Tier` suite preserved behaviour-for-behaviour —
now driving the REAL `enqueue_leaf` with no synthetic global, which
lives at the `DrrState` level — + two-tier enqueue / eviction /
outer-fairness + the spoof-confinement property under arbitrary
interleavings + per-connection `max_signers` targeting + the
Rung-0-collapse single-signer case), the `tests/fair_queue.rs`
two-tier-fairness + queue-level spoof-resistance + targeted-`max_signers`
+ the two-tier queue-op throughput microbench (~2.7× FIFO in isolation,
guarded), the new `tests/wire_compat.rs` v1/v2 interop suite (back-compat
on BOTH the FIFO and DRR schedulers, negotiation robustness, the
oversize-non-magic `ParseError`, the truncated-hint `ParseError`, and
mixed concurrent load), the `knomosis-bench --emit-hints` flag + an
end-to-end hinted-path smoke test, AND the FQ.13a `knomosis-l1-ingest`
`RawTcpSubmitter` suite (framing layout, byte-equivalence against the
canonical `knomosis_host::frame` encoders, end-to-end against a live
host, + the daemon's submitter-endpoint validation); `PROTOCOL_VERSION`
is bumped 1 → 2 for the additive, opt-in wire superset (v1 clients
unaffected) and the package semver to 0.4.0 (minor — new public API +
flags + wire version); up from ~1 824
at the FQ Rung-0 landing, where the FQ Rung-0 fair scheduler adds ~70
`knomosis-host` tests — the pure DRR core (`fair::drr`: per-flow / max-flows /
global cap enforcement, round-robin `pick`, empty-flow eviction +
deficit reset, plus the equal-weight fairness-bound, the
bounded-overtaking property under arbitrary interleavings,
determinism, and structural-invariant soak property tests), the
`FairQueue` concurrency wrapper (targeted backpressure, blocking
`next` + non-blocking `try_next`, `wake_all` prompt-unblock +
`close` post-shutdown-`Busy`, lock-free dispatch incl. a
dispatch-outside-the-lock-under-load test, MPSC exactly-once,
poison recovery, `stats` incl. a concurrent-consistency test), the
`assign_conn_id` (FQ.3) distinct/monotonic concurrency test, the
`--scheduler` / `--per-flow-cap` / `--max-flows` config gate (incl.
`ConfigError::UnknownScheduler` + the intrinsic/cross-field cap
validation split), the `QueueHandle` seam, and the
`tests/fair_queue.rs` behavioural / stress / shutdown-under-load /
DRR-reorders-but-preserves-multiset / kernel-panic-firewall /
throughput suite — the e2e throughput benchmark is `#[ignore]`d per
FQ.7c (not a CI gate); up from ~1 754 at
the GP.7.4 landing, where the `knomosis-host` gas-pool forwarding
adds ten tests — five in `config` (`gas_pool_flags_parse_and_assemble`,
`no_gas_pool_flags_disabled`, `gas_pool_single_cap_defaults_other_to_zero`,
`gas_pool_invalid_cap_rejected`, `help_text_mentions_gas_pool_flags`),
two in `kernel::command` (`gas_pool_caps_flags_passed_to_subprocess`,
`no_gas_pool_policy_passes_no_gas_pool_flags`), pinning that the
`CommandKernel` forwards `--gas-pool-eth-cap` / `--gas-pool-bold-cap`
to the spawned `knomosis process` argv, plus three real-binary
integration tests (`tests/real_knomosis_gas_pool.rs`,
gated-on-binary-presence like the observer / event-subscribe
`real_knomosis_*` tests) that drive the actual `knomosis` gas-pool CLI
lifecycle end-to-end (process → `<log>.gaspoolcfg` sidecar → matching
replay exit 0 → wrong-cap / disabled replay exit 2; the
`export-terminate-bundle` gas-pool-config cross-check; and the gas-pool
genesis hash distinct from the plain genesis); up from ~1 744 at the GP.7.1
landing, where the runtime-adaptor lockstep added three
`knomosis-l1-ingest` tests — `gas_pool_and_sequencer_ids_are_reserved`,
`replay_rejects_reserved_actor_id`, and
`replay_rejects_reserved_actor_id_in_submitted_record` — alongside rebasing the
`AddressBook` / `state` / `translation` / `watcher` / integration
fixtures and the `l1_ingest.cxsf` corpus onto the genesis-3
allocation; up from ~1 741 at the GP.6.5 landing, where the
BOLD-specific cross-stack
corpus adds `cross_stack_bold.rs` (11 tests) + the
`knomosis-cross-stack` `L1IngestBold` tag-7 enumeration / pin tests;
up from ~1 729 at the GP.6.4 landing, ~1 639 at the GP.6.3
landing; the GP.6.4 budget view + its v2.1 deep-audit refactor
add tests across `event` / `decoder` / `budget_view` /
`indexer` / the new `knomosis-storage` `budget_storage` +
`combined_transaction` modules + the `budget_property` /
`budget_concurrency` / `fault_injection` integration suites,
including deep-audit edge-case coverage for
recipient-equals-pool-actor, zero-amount fields, u64::MAX
fields, actor-zero / actor-max corners, view+tx-read
consistency, dispatch-event-total-on-all-tags exhaustiveness,
the `(seq − 1) / epoch_length` epoch-boundary alignment, the
single-transaction `remaining_this_epoch` consistency, and an
atomicity test pinning that a budget-pass corrupt-cell error
rolls back staged balance writes).
`cargo test --workspace --locked` from `runtime/` is the
canonical query.  Approximate per-crate breakdown at the
landing:

| Crate                            | Tests | Role                                                       |
|----------------------------------|-------|------------------------------------------------------------|
| `knomosis-cli-common`               |   ~8  | shared logging / exit-code / paths helpers                 |
| `knomosis-cross-stack`              |  ~33  | fixture loader dev-dep (+ GP.6.5 `L1IngestBold` kind)      |
| `knomosis-verify-secp256k1`         |  ~42  | RH-A.1 ECDSA secp256k1 verifier (cdylib)                   |
| `knomosis-hash-keccak256`           |  ~32  | RH-A.2 Keccak-256 hash adaptor (cdylib)                    |
| `knomosis-l1-ingest`                | ~321  | RH-B L1 event watcher daemon + GP.6.1 fee-split mirror + GP.6.5 BOLD corpus consumer + GP.7.1 genesis-3 reservation lockstep + FQ.13a raw-TCP `knomosis-host` submitter (opt-in signer hints) |
| `knomosis-host`                     | ~426  | RH-C network adaptor + GP.6.2 budget admission gate + FQ Rung-0/1 two-tier DRR fair scheduler + signer-hint wire (`PROTOCOL_VERSION 2`) + `--max-conn-backlog` aggregate cap + `--persistent-connections` pipelined mode (DRR exercised over the wire) |
| `knomosis-event-subscribe`          | ~219  | RH-D event subscription server + GP.6.3 registry + extract-events |
| `knomosis-storage`                  | ~100  | RH-E.0 storage abstraction + SQLite impl + GP.6.4 budget tables / combined transaction |
| `knomosis-indexer`                  | ~205  | RH-E.1 SQLite event indexer daemon + GP.6.3 Lean-event round-trip + GP.6.4 budget / pool views |
| `knomosis-bench`                    | ~147  | RH-F transfer-throughput benchmark + FQ.13c `--emit-hints` + `--persistent` pipelined client + `BenchmarkReport.emit_hints`/`persistent` wire-mode guard + exit-path unit tests |
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
    (`--l1-rpc / --bridge-actor-keystore /
    (--knomosis-host-url | --knomosis-host-tcp) /
    --bridge-contract / --identity-registry / --state-file
    [+ optional --emit-signer-hints / --deployment-id /
    --confirmation-depth / --poll-interval-ms / --until-block]`).
    Identifier: `"knomosis-l1-ingest/v1"`.
  * **Submitters (FQ.13a).**  `submitter::raw_tcp::RawTcpSubmitter`
    (`--knomosis-host-tcp <ADDR>`) is the canonical forwarder — it speaks
    `knomosis-host`'s actual length-prefixed wire format (the HTTP
    `--knomosis-host-url` path is a placeholder that cannot talk to a real
    host), so it is the first real RH-B → RH-C link.  Opt-in
    `--emit-signer-hints` prepends the Rung-1 `KNH2` preamble + the 8-byte
    signer-`ActorId` hint per frame (default OFF ⇒ byte-identical legacy
    v1).  The daemon boxes the chosen submitter (`Box<dyn Submitter>`),
    requires exactly one endpoint, and gates `--emit-signer-hints` on the
    raw-TCP endpoint.  Framing is hand-rolled but byte-pinned against the
    canonical `knomosis_host::frame` encoders (dev-dep) + driven
    end-to-end against a live in-process host.
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

**Workstream FQ / GP.8 Track A (Per-actor fair queuing — Rungs 0 + 1).**
**Track A complete** (Lean has no part here; this is a
`knomosis-host`-only liveness layer).  Adds the optional, default-OFF
**two-tier** Deficit-Round-Robin fair scheduler that bounds, under
contention for the single serial worker, the share any one actor can
take — so a short-burst flood delays only itself while honest actors
keep their share and their enqueue capacity, and a productive burst on
an idle host is throttled by nothing.  The OUTER tier round-robins
across transport-authenticated connection ids; the INNER tier (Rung 1)
round-robins across an optional, advisory per-frame signer hint within
each connection, so a connection multiplexing many (possibly forged)
hints is confined to its single outer share (`§2.6` invariant 2).  See
`docs/planning/GP.8_SEQUENCER_INTEGRATION_PLAN.md` §2 + §4 (Rung 0 =
FQ.0 – FQ.8; Rung 1 = FQ.9 – FQ.15).  What ships and where:

  * **Pure two-tier DRR core** (`src/fair/drr.rs`).  ONE I/O-free,
    lock-free, clock-free generic round-robin `Tier<K, S>` reused at
    both tiers (FQ.11a): the outer scheduler is `Tier<ConnId, ConnBucket>`
    where `ConnBucket = Tier<SignerHint, RequestFifo>` is the inner
    signer tier (any `Tier` is itself a `FlowStore`, so the same `pick`
    drives both).  The production `DrrState` wraps the outer tier;
    `enqueue(conn, signer, req)` enforces the five caps (`Caps {
    per_flow, max_flows, max_signers, max_conn_backlog, global }`) and
    hands a rejected request back (`Err(req)` → `Busy`; nothing dropped,
    tallied per reason).  The inner `enqueue_signer` checks them in
    priority order — leaf `per_flow`, then the per-connection aggregate
    `max_conn_backlog` (the Rung-1.5 dual of `per_flow`: it bounds a
    connection's TOTAL backlog summed across all its hints, defaulting to
    `per_flow` so a hint-rotating flood cannot exceed the Rung-0
    per-connection bound, and checked AFTER the leaf cap so `per_flow`
    stays the attributable reason for a single-leaf flood), then the
    distinct-hint `max_signers`; `pick` is equal-weight DRR (quantum = cost = 1 ⇒ strict
    round-robin) with immediate empty-flow eviction at BOTH tiers (no
    deficit banked across idle periods — the anti-burst property).
    Deterministic + replayable (the accountable-fairness seam);
    `BTreeMap` flow maps (no hash-DoS surface).  The single-tier FQ.1
    suite runs green against the extracted `Tier`, proving the refactor
    is behaviour-preserving; the spoof-confinement property is pinned
    under arbitrary interleavings.  The `deficit` / `quantum` fields are
    retained for a future budget-weighted quantum (a non-goal here).
  * **Wire negotiation + signer hint** (`src/frame.rs`, FQ.9 / FQ.10).
    A Rung-1 (v2) client opens with the 4-byte `KNH2_PREAMBLE`; the host
    peeks the first 4 bytes once (`negotiate_connection`) and reads either
    a v1 frame (`read_frame_with_prefix`, the prefix not lost) or a hinted
    `[8-byte BE hint][4-byte len][payload]` frame (`read_hinted_frame`,
    the bounded hint read BEFORE any body allocation, with a dedicated
    `TruncatedHint`).  `read_request` is the one-shot composite (legacy ⇒
    `LEGACY_SIGNER_HINT`).  The disambiguation is collision-proof because
    `HARD_MAX_FRAME_SIZE` (16 MiB) is strictly below `KNH2_MAGIC`
    (`0x4B4E4832` ≈ 1.18 GiB) — pinned by a `const` assertion + a unit
    test — so a valid v1 length can never equal the preamble.  The hint
    is **advisory routing only** (the kernel reads + verifies the real
    signer from the CBE body, so a forged hint is fairness-only).
    `encode_hinted_frame` is the canonical client-side encoder (the
    single source of truth for the layout).
  * **`FairQueue` + `QueueHandle`** (`src/queue.rs`).  The concurrency
    wrapper (`Arc<Mutex<DrrState>>` + `Condvar`): `try_submit(conn,
    signer, payload)` notifies only on the empty→non-empty transition
    (the lone worker can only be parked then); `next(timeout)` does ONE
    bounded `Condvar` wait then `pick`s — a wakeup with the queue still
    empty (timeout / `wake_all` / spurious) yields `Idle` so the worker
    re-checks `stop`, and the dispatch is returned with the lock ALREADY
    released so the slow `kernel.submit` runs lock-free (the §2.8
    throughput property); non-blocking `try_next` for the shutdown drain;
    `wake_all` to promptly unblock a parked worker at shutdown; `close()`
    so a request submitted after the worker exits gets a prompt `Busy`
    (the FairQueue counterpart of FIFO's disconnected-channel rejection);
    poison-recovering locks.
    `QueueHandle { Fifo(BoundedQueue), Fair(FairQueue) }` unifies both
    behind one `submit(conn, signer, payload)` so the listener code is
    scheduler-agnostic (FIFO ignores both routing values).
  * **Wiring** (`src/server.rs`, `src/listener.rs`, `src/config.rs`,
    `src/main.rs`).  `Server::run` branches on `--scheduler`: FIFO is
    byte-for-byte the historical path (`worker_loop` + `BoundedQueue`),
    DRR spawns `fair_worker_loop` (mirrors `worker_loop` exactly via
    `FairQueue::next` / `try_next`).  A process-wide monotonic
    `ConnId` (FQ.3) is assigned at `accept()` across all three
    listeners; `handle_connection` performs the Rung-1 negotiation on
    EVERY path (a wire concern, not a scheduler one — so a v2 client
    interoperates with a FIFO host) and threads `(conn, signer)` to the
    submit call.  Flags `--scheduler {fifo|drr}` (default `fifo`),
    `--per-flow-cap` (default 64), `--max-flows` (default 4096),
    `--max-signers-per-conn` (default 256, the Rung-1 inner cap),
    `--max-conn-backlog` (default = `--per-flow-cap`, the Rung-1.5
    per-connection aggregate cap), with `--max-queue-depth` reused as the
    global cap.  An unrecognised
    `--scheduler` value is a `ConfigError::UnknownScheduler` (deferred to
    `validate`, mirroring `--budget-policy`); intrinsic cap sanity
    (`per_flow ≥ 1`, `1 ≤ max_flows ≤ HARD_MAX_FLOWS`,
    `1 ≤ max_signers ≤ HARD_MAX_SIGNERS_PER_CONN`,
    `1 ≤ max_conn_backlog ≤ HARD_MAX_QUEUE_DEPTH`) is checked under ANY
    scheduler, while the cross-field `per_flow ≤ max_queue_depth` and
    `max_conn_backlog ≤ max_queue_depth` are
    enforced only under `--scheduler drr`; `Caps::new` /
    `with_max_signers` / `with_max_conn_backlog` also clamp to the hard
    ceilings as defence in depth.
  * **Observability (FQ.6).**  `FairQueue::stats()` exposes the
    `DrrStats` counters (dispatched + per-reason rejections incl.
    `rejected_max_signers` + `rejected_conn_backlog` + active-flow /
    active-signer gauges), and the
    fair worker logs an aggregate `"fair scheduler summary"` line at
    shutdown and, while running, at most once per 30 s when there has
    been activity — never per request, silent on an idle host.
  * **Safety boundary preserved (§2.6).**  The routing keys influence
    order + drop ONLY, never admissibility; the host still parses no CBE
    bytes (it reads at most the explicit, untrusted hint).  A queue-level
    test pins that DRR genuinely reorders vs FIFO yet preserves the
    verdict multiset; spoof confinement (a forged-hint flood cannot
    starve a real victim) is pinned both as a `drr.rs` property and a
    queue-level e2e test; the kernel-panic firewall and
    lock-free-dispatch-under-load are tested on the fair path too
    (`tests/fair_queue.rs`).
  * **Wire interop (FQ.14b).**  `tests/wire_compat.rs` proves a legacy
    (v1) client and a v2 client both work against one host instance, on
    BOTH FIFO and DRR; the negotiation never mis-parses (an
    oversize-non-magic length is a `ParseError`, a truncated hint is a
    `ParseError`); v1/v2 connections under mixed concurrent load all get
    the correct verdict.  `PROTOCOL_VERSION` is `2` for the additive,
    opt-in wire superset (a v1 client with no preamble is unaffected and
    gets Rung-0 fairness).
  * **Client emitters (FQ.13a + FQ.13c).**  Two real wire clients emit
    hints.  (FQ.13c) `knomosis-bench --emit-hints` (default OFF) opens
    each connection with `KNH2` + prepends the per-frame signer hint via
    the canonical `knomosis_host::frame` encoders.  (FQ.13a) the
    `knomosis-l1-ingest` `submitter::raw_tcp::RawTcpSubmitter` is the
    crate's **first real `knomosis-host` forwarder** — unlike the HTTP
    placeholder it speaks the host's actual length-prefixed wire format,
    and the `--knomosis-host-tcp <ADDR>` + opt-in `--emit-signer-hints`
    daemon flags select it (the hint is the signer `ActorId`).  Its
    hand-rolled framing is byte-pinned against `encode_frame` /
    `encode_hinted_frame` (single source of truth, a `knomosis-host`
    dev-dep — no runtime coupling) and driven end-to-end against a live
    in-process host (legacy + hinted + v1/v2 interop).  FQ.13b (observer)
    is N/A: it submits L1 JSON-RPC game-move calldata, never a
    `SignedAction` to the host, so there is nothing to hint — the
    `encode_hinted_frame` primitive is the ready drop-in if that changes.
    `BenchmarkReport` records the run's wire mode in an `emit_hints` field
    (`#[serde(default)]`, so a pre-Rung-1 baseline loads as the legacy v1
    mode it was measured under), and `compare_against_baseline` returns
    `RegressionVerdict::NotComparable` (a CLI operator-action exit) when
    the candidate and baseline wire modes differ — so a hinted candidate
    can never be silently regression-checked against a legacy baseline.
  * **Per-connection aggregate cap (`--max-conn-backlog`, Rung 1.5).**
    The two-tier split would let one hint-rotating connection buffer
    `max_signers × per_flow` requests — relaxing the Rung-0 per-connection
    bound (one `per_flow`, the connection's single leaf) and letting it
    crowd the global queue.  The fourth DRR cap restores it: it bounds a
    connection's AGGREGATE backlog across all its hints, defaults to
    `--per-flow-cap` (so spoofed hints stay self-confined out of the box),
    is checked AFTER the leaf cap (so `per_flow` stays the attributable
    reason for a single-leaf flood) and BEFORE a new hint, and is RAISED
    by an operator for a legitimately-multiplexing connection.  Closes the
    PR-review regression the two-tier split introduced.
  * **Persistent + pipelined connection mode (`--persistent-connections`).**
    Closes the §2.5 topology gap.  Fairness bites only when a connection
    carries multiple simultaneously-queued requests; the DEFAULT one-shot
    lifecycle (one frame → one verdict → close) holds at most one, so DRR
    coincides with FIFO end-to-end.  The opt-in `--persistent-connections`
    flag (default off) wires a persistent, PIPELINED TCP / Unix mode: a
    connection sends many frames back-to-back and the host replies one
    verdict per request in submission order (a dedicated writer thread
    delivers in order while the reader keeps reading; the §10.1 response
    frame is unchanged).  This is where `ConnReader`'s persistent
    read-state path is finally USED (`run_persistent` in `src/listener.rs`):
    it negotiates once, then loops `ConnReader::read_next`.  The
    reader→writer hand-off is a BOUNDED `sync_channel` sized to the queue's
    per-connection in-flight capacity (`QueueHandle::pipeline_capacity` =
    `--max-conn-backlog` on the DRR path, `--max-queue-depth` on FIFO): a
    client that pipelines frames but never reads its responses makes the
    writer block on `write_all`, the channel fills, and the reader BLOCKS
    on `send` — OS receive-buffer fill + TCP flow control then bound total
    memory (an unbounded channel here would be an OOM DoS; pinned by
    `persistent_bounded_channel_backpressures_without_deadlock`).  TLS
    stays one-shot (the rustls session is single-owner); a one-shot client
    is a degenerate subset that works unchanged.  **Fair scheduling under
    contention is now
    exercised through the wire** (`tests/persistent.rs`): a deterministic
    gated-kernel integration test over REAL TCP shows DRR interleaving an
    honest connection into a flood (≤ ~half the flood precedes the honest
    connection's last request), with a FIFO contrast test proving the flood
    buries it without DRR.  The fairness *property* is therefore pinned
    BOTH at the queue-API level AND end-to-end through the TCP server.  A
    shipping client drives it: `knomosis-bench --persistent` (each worker
    reuses one connection and pipelines batches).
  * **Throughput (FQ.7c).**  Three measurements (all always-on
    queue-op microbenches except the e2e one).  (1) Single-tier queue-op
    overhead in ISOLATION (no-op kernel): Rung-0 DRR is ~1.8× the per-op
    cost of the FIFO `sync_channel` — the `Mutex` + `Condvar` + `BTreeMap`
    the fairness machinery inherently carries, DRR's worst case with no
    dispatch work to amortise it.  (2) Two-tier queue-op overhead
    (16 conns × 8 signers, both `BTreeMap`s per op): ~2.7× FIFO — the
    inner tier adds a small constant over Rung-0; a fast always-on test
    guards each against catastrophic regression.  (3) END-TO-END
    single-actor throughput through the full server: drr/fifo = **1.00×**
    (both bounded by the listener's 50 ms accept-poll + dispatch,
    identical on both paths) — comfortably within the plan's ≥90% intent.
    The e2e benchmark is `#[ignore]`d (FQ.7c is not a CI gate; the
    sequential one-shot pattern is slow), runnable with `--ignored`.
  * **Remaining (Tracks B–D).**  The reimbursement claim (Track B), the
    free-tier/epoch config guidance (Track C), and the operator runbook
    (Track D) are future work — see the GP.8 plan.

**Workstream RH-D (Event subscription server).**  **Complete**
(including the Lean `knomosis extract-events` subcommand +
`Encodable Event` wire codec, landed under GP.6.3 — see the
Workstream-GP snapshot).  The
TCP service that tails Knomosis's transition log, extracts deployment-
facing events via a Lean `knomosis` subprocess, and streams those events
to subscribers in strict order with bounded-lag eviction.

  * **Surface.**  `knomosis-event-subscribe` library + daemon
    (`--log-path / --listen / --mock | --knomosis-binary /
    --deployment-id / --budget-policy / --free-tier / --action-cost /
    --current-epoch / --epoch-length /
    --max-subscriber-lag / --keep-history / --max-frame-size /
    --max-subscribers / --max-concurrent-connections /
    --send-queue-depth / --write-timeout-ms /
    --handshake-read-timeout-ms / --poll-interval-ms`).  The
    deployment-config flags (`--deployment-id` + budget + epoch) are
    forwarded verbatim to the `knomosis extract-events` subprocess so
    extraction replays under the same config the log was produced with
    (GP.6.3 review fix).
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
    test impl) and `SubprocessExtractor` (spawns `knomosis
    [deployment-config global flags] extract-events --log LOG` — the
    GP.6.3 review fix prepends `--deployment-id` + budget + epoch
    flags via `with_global_args` so replay re-verifies signatures
    against the right domain and reconstructs the right budget epochs;
    re-spawns on subprocess crash with exponential backoff).
  * **Event-type registry** (`event_type.rs`, GP.6.3; widened to tag
    20 by GP.6.4).  Lightweight `EventType` catalogue mirroring
    Lean's `Event.tag` (`0..=20`, incl. the gas-pool family
    16/17/18/19 + the GP.6.4 `budgetConsumed` 20) — `from_tag` (a drift-safe
    `const fn` scan of `ALL_EVENT_TYPES`) / `tag` / `name` /
    `is_gas_pool_family` + `peek_event_tag` (reads only the leading
    9-byte CBE tag head, no field decode → no drift from the Lean
    `Encodable Event` field layout) + the total, non-rejecting
    `EventClass::classify` (`Known` / `Unknown` / `Unparseable`) +
    `EventStreamStats` (per-type atomic stream counters).  The
    extractor loop classifies + tallies every streamed event and
    logs a per-type summary at shutdown; the additive-extension
    policy is mechanised (any unrecognised / future tag is tallied
    and still streams verbatim).  Verified against REAL Lean
    `Event.encode` bytes by the `cross_stack_lean_event` differential.
    NOT a field decoder — that is `knomosis-indexer::decoder`'s job.
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
    after the GP.3.4 `topUpActionBudgetFor`; 21 `Event`
    constructors, 0..20, after the GP.6.4 `budgetConsumed`).
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
GP.6.2 — the `knomosis-host` per-actor budget admission gate —
GP.6.3 — the `knomosis-event-subscribe` event-type registry +
the full RH-D closure (Lean `Encodable Event` + the `knomosis
extract-events` subcommand + Lean→Rust cross-stack differential) —
and GP.6.4 — the `knomosis-indexer` per-actor budget view +
per-resource (ETH/BOLD) gas-pool inflow views, with the new
kernel `Event.budgetConsumed` (tag 20) + the indexer's `Event`
mirror widened from 0..=15 to 0..=20 to include the four
GP-family tags plus `budgetConsumed` — and GP.6.5 — the
BOLD-specific tri-stack (Lean→Rust→Solidity) cross-stack fixture
corpus (`l1_ingest_bold.cxsf` + `bold_deposit.json`), adding the
recipient post-deposit `ActorBudget` mutation as a byte-pinned
dimension — complete; Phase GP.6 is therefore fully landed.  Phase
GP.7 (pool-actor governance) is underway: GP.7.0 — the exhaustive
characterisation of the bridge-signable action set — is complete on
the Lean side, GP.7.1 — the `gasPoolActor` / `sequencerActor`
reservation (genesis `AddressBook.empty.nextActorId` advances 1 → 3)
— is complete end-to-end (Lean + the Rust `knomosis-l1-ingest`
runtime adaptor, which mirrors the genesis-3 allocation so the
reservation is honoured in production), GP.7.2 — the canonical
`gasPoolPolicy` declaration governing `gasPoolActor` outflow
(`transfer`-to-`sequencerActor`-only, per-leg ETH/BOLD recipient +
amount caps) — is complete on the Lean side, and GP.7.3 — the
inductive **per-resource** per-epoch pool-drain bound (across an admitted
trace of `n` steps the pool's leg-`rLeg` balance falls by at most `n ×
legCap mEth mBold rLeg`), at its optimal closure (exhaustive external
discharge + executable `applyTrace` + production-runtime lift + the
GP.7.5 two-leg-independence core) — is complete on the Lean side, and
GP.7.4 — the genesis ratification of the pool discipline (the
`gasPoolGenesis` hook + the config-driven `gasPoolGenesisOfConfig`
opt-in wiring BOTH the `gasPoolPolicy` declaration and the
`gasPoolAuthorityPolicy` intersection at genesis, a worked ETH+BOLD
example deployment + the `knomosis gas-pool-demo` subcommand, the
generic `knomosis process`/`replay`/… gas-pool CLI flags
(`--gas-pool-eth-cap` / `--gas-pool-bold-cap`) backed by a
`<log>.gaspoolcfg` `GasPoolSidecar`, and the `knomosis-host`
`CommandKernel` forwarding of those flags) — is complete end-to-end
(Lean + the production CLI + Rust host).  Phase GP.11 (embedded
ETH↔BOLD AMM) has begun: GP.11.1 — the AMM's L1 state scaffold on
`KnomosisBridge.sol` (the `ammReserveEth` / `ammReserveBold` reserves,
the immutable `ammSeedRatioBps` validated `<= MAX_AMM_SEED_RATIO_BPS`,
and the two constitutional caps `AMM_SWAP_FEE_BPS = 30` /
`MAX_AMM_SEED_RATIO_BPS = 8000`) — is complete on the Solidity side
(purely additive; `ammSeedRatioBps = 0` preserves the pre-v1.3
behaviour), and GP.11.2 — deposit-side seeding (`_registerDepositWithFee`
now routes `floor(poolAmount * ammSeedRatioBps / 10000)` of every
fee-split deposit into the matching reserve via `_seedAmmReserves`, with
the AMM split carried in the canonical `DepositWithFeeInitiated` event
(a new `ammSeedAmount` field inserted after `poolAmount`) and BOUND in the
`receiptHash` — the plan-literal wire format, propagated cross-stack in
lockstep to the Rust ingestor's pinned topic + decoder and the
`deposit_fee_split{,_bold}.json` receiptHash corpora) — is also complete
end-to-end (Solidity + Lean cross-check + Rust), and GP.11.3 — the
permissionless constant-product swap `ammSwap` (Uniswap v2-style ETH↔BOLD
exchange with the 0.30% `AMM_SWAP_FEE_BPS` retained in the reserves so the
product `k = ammReserveEth × ammReserveBold` is monotonically
non-decreasing, `minAmountOut` slippage + `deadline` MEV protection, a pure
`AmmMath` swap-math library, and Checks-Effects-Interactions + `nonReentrant`
safety) — is complete on the Solidity side (the L2 `Action.ammSwap` mirror
is GP.11.4).  See
`docs/planning/unified_gas_pool_plan.md` for the full plan.  Headline
contributions surviving in current code:

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
    variants.  The genuine **Lean → Rust differential** ships as
    `LegalKernel/Test/Bridge/CrossCheck/DepositWithFeeAction.lean`
    (emits `solidity/test/CrossCheck/fixtures/
    deposit_with_fee_action.json`, whose `expectedCbe` is computed
    by Lean's `Encoding.Action.encode`) consumed by
    `runtime/knomosis-l1-ingest/tests/cross_stack_lean_action.rs`,
    which byte-matches the Rust `encode_action` against the
    Lean-sourced bytes for all three GP-family constructors; four
    hand-pinned known-vector tests in `encoding.rs` additionally
    anchor the byte layouts to ground truth.  The fee-split event
    topic is baked as the `pub const`
    `DEPOSIT_WITH_FEE_INITIATED_TOPIC` (with the four sibling
    topics); `EventTopic::hash()` is a `const fn` returning the
    pinned constant, verified against `keccak256(signature)` by a
    test.  Adds the `FeeSplitInput` shape + `FeeSplitInput::split`
    arithmetic (`runtime/knomosis-l1-ingest/src/fixture.rs`),
    mirroring the L1 contract's recipe and the Lean side's
    `feeSplit` reference (conservation, pool-cap, budget-cap
    properties — pinned per-entry AND via `proptest`); the
    `wei_per_budget_unit = 0` guard returns `0`, matching Lean's
    `Nat.div_zero`.  Adds a new `FixtureKind::L1IngestFeeSplit`
    variant (on-disk tag 6) to `knomosis-cross-stack`.  Ships the
    cross-stack fixture corpus
    `runtime/tests/cross-stack/l1_ingest_fee_split.cxsf` (249
    entries: 240 from a 5 × 6 × 4 × 2 grid spanning
    `msg_value ∈ {1, 10⁹, 10¹², 10¹⁵, 10¹⁸}`,
    `chosen_fee_bps ∈ {0, 1, 100, 1000, 2500, 5000}`,
    `wei_per_budget_unit ∈ {1, 10⁶, 10¹², 10¹⁵}`,
    `resource_id ∈ {ETH=0, BOLD=1}`, plus 9 boundary cases
    including two `u64::MAX` entries (whole-on-user + both-legs-near-
    bound), rounding edges, budget clamp, and ETH/BOLD scale
    entries).  Generator example
    `runtime/knomosis-l1-ingest/examples/gen_fee_split_fixtures.rs`
    (with a `--check` drift gate wired into `ci-rust.yml`; panics
    rather than silently skips on an out-of-bounds entry) + consumer
    test `runtime/knomosis-l1-ingest/tests/cross_stack_fee_split.rs`
    (8 cases: round-trip, coverage threshold + ETH/BOLD presence,
    mathematical soundness, resource-parametric byte-equivalence,
    ETH/BOLD split-arithmetic parity, input round-trip, encoder
    determinism, per-record `DepositWithFee` tag pin).  Translation
    behaviour for `DepositWithFeeInitiated` events stays as
    `Translated::NoAction` per the MVP-scope semantics (deposit
    materialisation is the sequencer's responsibility, not the
    ingestor's; emitting an Action would diverge from Lean's
    `Bridge.Ingest.ingest`); the encoder additions stand alone,
    ready for future sequencer-side action emission.  The Rust-side
    workspace `cargo test --workspace --locked` reports ~1498 tests
    passing.
  * **GP.6.2** Rust-side `knomosis-host` per-actor budget admission
    gate.  New module `runtime/knomosis-host/src/budget.rs` mirrors
    the Lean budget ledger byte-for-byte: `BudgetPolicy`,
    `ActorBudget`, and `EpochBudgetState` (a `BTreeMap<u64, _>` so
    iteration is ascending-by-actor like the Lean `TreeMap`), each
    with an `encode()` byte-equal to its Lean counterpart
    (`BudgetPolicy.encode` / `ActorBudget.encode` / the
    `encodeSortedPairs` map form in `ExtendedState.encode`).
    Byte-equivalence is pinned non-circularly on BOTH sides via
    hand-computed known vectors — single-byte + multi-byte LE + an
    unsigned-`UInt64`-ordering pin at the 2^63 boundary (Rust
    `actor_budget_encode_known_vector` etc. + Lean
    `actorBudgetEncodeKnownVector` etc. in
    `LegalKernel/Test/Encoding/State.lean`, `encoding-state` 28 →
    33 cases).  `BudgetGate` + `decode_budget_view` mirror the
    budget-ledger portion of GP.3.2's
    `apply_admissible_with_budget` (bridge-actor consume-exemption,
    per-action consume, the three budget-grant arms, and the
    balance/policy-INDEPENDENT signer-correlation safety conjuncts);
    the balance- and consent-dependent conjuncts
    (`getBalance >= gasAmount`, `delegatedTopUpConsentBool`) are
    DEFERRED to the authoritative Lean kernel reached via
    `CommandKernel` (documented scope boundary — the mock gate is a
    faithful but strictly-weaker predicate).  `MockKernel` gains
    `set_budget_gate` / `set_budget_policy` / `budget_for`; an
    exhausted budget folds into `Verdict::NotAdmissible` with the
    wire-stable reason `"InsufficientBudget"` (OQ-GP-3).
    `CommandKernel::with_budget_policy` forwards `--budget-policy
    bounded --free-tier N --action-cost C --current-epoch E` to the
    `knomosis` binary, and `Main.lean`'s `parseGlobalFlags` (now a
    `GlobalFlags` bundle) consumes those flags and threads the
    assembled `BudgetPolicy` into every `demoGenesis`-consuming
    subcommand, so the gate GP.3.2 wired into
    `processSignedActionWith` / `replayWith` enforces the configured
    policy instead of the deny-all genesis default (`.bounded 0 1
    0`).  The `knomosis-host` daemon CLI also gains the four budget
    flags (`config.rs` → `build_kernel`), so an operator can enable
    the gate on either kernel.
  * **GP.6.2 (post-audit extensions).**  A follow-up audit pass
    closed the gaps the first GP.6.2 landing left, taking the
    workstream to its optimal form:
    - **Bidirectional CBE codec.**  `ActorBudget` / `BudgetPolicy` /
      `EpochBudgetState` gain `decode` siblings (mirroring the Lean
      decoders, incl. the `actionCost >= 1` + strictly-ascending-key
      canonical-form rejections), so the encoding round-trips; pinned
      by `proptest` round-trips over random inputs.
    - **Full-fidelity (strict) gate.**  `BudgetGate::with_strict_checks`
      + `set_balance` / `allow_delegate` oracles let the mock ALSO
      enforce the two previously-deferred conjuncts (`getBalance >=
      gasAmount`, `delegatedTopUpConsentBool`), upgrading it from a
      strictly-weaker to a faithful realisation of the Lean gate when
      a test supplies the data.  New reasons `BudgetGateInsufficientGas`
      / `BudgetGateDelegationNotAuthorized`.
    - **Epoch advancement (OQ-GP-4, L2-action-clock).**  The runtime
      advances the budget epoch as a deterministic function of the log
      index (`BudgetPolicy.advanceEpoch` / `ExtendedState.withAdvancedEpoch`),
      threaded through `processSignedActionWith` / `processPure` /
      `replayStepWith` (+ the snapshot path's absolute `startIdx`) via
      a `RuntimeState.epochLength` / replay `epochLength` param
      (default `0` ⇒ pre-existing fixed-epoch behaviour, so the gate +
      its 10 theorems are UNTOUCHED).  With `epochLength > 0` each
      actor's free tier is lazily replenished every `epochLength`
      admitted actions; deterministic replay reproduces every epoch
      (proven by `epochAdvanceReplenishesAndReplays`).  Surfaced via
      `--epoch-length N` on the `knomosis` binary + the `knomosis-host`
      CLI + `CommandKernel::with_epoch_length` + the mock gate's
      `with_epoch_length`.
    - **Budget-config persistence (sidecar).**  `LegalKernel.Runtime.
      BudgetSidecar` persists a non-default budget config to a
      `<log>.budgetcfg` sidecar after a successful bootstrap and
      cross-checks it on every log-touching subcommand (including the
      observer-facing `replay-up-to` / `export-cell-proofs`, so the
      off-chain truth oracle can never compute a state commit under the
      wrong budget policy), so a
      forgotten/changed budget flag on restart fails with a clear
      `budget-config error` (naming the original flags) instead of an
      opaque post-state-hash mismatch.  Default deployments write no
      sidecar (unchanged on-disk footprint).
    - **Test deltas.**  `knomosis-host` ~245 → ~276 (the strict-gate +
      codec round-trip + proptest + epoch-advancement + epoch-flag
      tests); Lean adds `runtime-budget-sidecar` (8 cases) +
      `runtime-loop-happy-path` epoch-advancement cases.  Workspace
      `cargo test --workspace --locked` reports ~1591 tests passing;
      `lake test` green; `lake build` warning-free; clippy / fmt /
      naming_audit / count_sorries / stub_audit / tcb_audit green.
  * **GP.6.3** `knomosis-event-subscribe` new event variants +
    **full RH-D closure** (Lean `Encodable Event` + the `knomosis
    extract-events` subcommand).  The event-subscription server is an
    opaque-byte *transport*: it tails the log, delegates extraction to
    the Lean wire-format authority, and forwards CBE-encoded `Event`
    payloads VERBATIM.  This WU lands four things:
    - **Event-type registry** (`event_type.rs`).  An `EventType`
      catalogue mirroring Lean's `Event.tag` over the full frozen
      space `0..=20` — incl. the GP family `depositWithFeeCredited`
      (16), `actionBudgetTopUp` (17), `gasPoolClaim` (18), the
      GP.3.4 `delegatedActionBudgetTopUp` (19), and the GP.6.4
      `budgetConsumed` (20).  (The WU title's
      "three new event variants" predates GP.3.4; the registry mirrors
      the CURRENT inductive, so it carries all five.)  `from_tag` is a
      drift-safe `const fn` scan of `ALL_EVENT_TYPES` (can't disagree
      with `tag()`); `name` returns the canonical Lean constructor
      names; `peek_event_tag` reads ONLY the leading 9-byte CBE uint
      head (no field decode → no drift); `EventClass::classify` is
      total + NON-rejecting (`Known` / `Unknown` / `Unparseable`, all
      streamed verbatim); `EventStreamStats` are per-type atomic
      stream counters the server tallies and summarises at shutdown.
    - **Lean `Encodable Event`** (`LegalKernel/Encoding/Event.lean`).
      The canonical CBE wire codec for `Event` (encode + decode +
      instance), matching `knomosis-indexer::decoder`'s field layout
      BYTE-FOR-BYTE — including tag 11 (`localPolicyDeclared`), whose
      `policy` is encoded as a CBE byte string wrapping
      `LocalPolicy.encodeAsBytes` (the indexer's "opaque policy bytes"
      `read_byte_string` contract; a structured `Encodable LocalPolicy`
      would not lead with the `0x02` byte-string tag and would fail to
      decode Rust-side).  Carries `Event.tag_matches_encode_tag` (every
      encoding leads with `Encodable.encode (T := Nat) (Event.tag e)` —
      the load-bearing soundness guarantee the registry's tag-peek
      relies on; `#print axioms` = `[propext]`).
    - **`knomosis extract-events --log LOG` subcommand**
      (`Main.lean::cmdExtractEvents` + the `extractEventsStepWith`
      core in `LegalKernel/Runtime/EventStream.lean`).  The stateful
      stdin/stdout streaming driver the production `SubprocessExtractor`
      shells out to: it threads running state across log-frame
      requests, reconstructs each frame's post-state via the FULL
      bridge-aware admission path (`replayStepWith` — NOT
      `kernelOnlyApply`, which would drop bridge events), and emits the
      events `Loop.processPure` would (proven byte-identical by the
      `runtime-extract-events` suite).  Uses the production `Verify`
      (real verifier at link time; the dev binary's opaque returns
      `false`, exactly like `replay-up-to`).
    - **Cross-stack differentials against REAL Lean `Event.encode`
      bytes** (fixture `event_subscribe_cbe.json`, 25 entries / all
      20 constructors).  Two consumers: (a)
      `knomosis-event-subscribe::tests::cross_stack_lean_event` —
      `peek_event_tag` / `classify` read the correct tag/name; (b)
      `knomosis-indexer::tests::cross_stack_lean_event` — the FULL
      field-level proof: the indexer's `decode_event` decodes tags
      0..15 and `encode_event` reproduces the Lean bytes byte-for-byte
      (a Lean→decode→re-encode round-trip; tags 16..19 decode to the
      typed `UnknownTag`, never a bogus event).  This (b) check is
      what mechanically guarantees the tag-11 byte-string layout
      matches the indexer.
    Tests: Lean adds `encoding-event` (10), `runtime-extract-events`
    (9, incl. the `beU64`/`beU32`/`beToNat`/`encodeExtractResponse`
    wire-framing pins — those pure helpers live in `EventStream` so
    they are unit-testable, not buried in `Main.lean`),
    `crosscheck-event-cbe` (5); the `knomosis-event-subscribe`
    suite grows 177 → 214 (lib +22-case `event_type` module incl.
    `EventStreamStats` + error-message pins; `cross_stack_lean_event`
    5; integration +stats end-to-end; `real_knomosis_extract_events`
    2 real-binary smoke tests); `knomosis-indexer` adds its 2-case
    `cross_stack_lean_event` round-trip.  The `extract-events` arm
    uses the same verify-parameterised / mockVerify test posture as
    `replay-up-to`.  `docs/abi.md` §5.3 + §11 updated for the GP-family
    event indices, the `Event` CBE Lean authority, and the
    `extract-events` subprocess protocol.
    - **GP.6.3 (PR #101 review fixes).**  An automated review of the
      extract-events subcommand surfaced three production-correctness
      gaps in how the daemon drove the subprocess; all fixed Rust-side
      (the Lean binary already accepted the relevant global flags):
      (1) the `SubprocessExtractor` now forwards the deployment config
      to the subprocess — the daemon gains `--deployment-id`,
      `--budget-policy` / `--free-tier` / `--action-cost` /
      `--current-epoch`, and `--epoch-length`, and
      `with_global_args` PREPENDS them before `extract-events` (a
      `Config::extractor_global_args` builds the argv) — so a
      non-empty-deployment-id log no longer fails signature replay and
      a budget-enabled log no longer trips the `<LOG>.budgetcfg`
      sidecar check; (2) `HARD_MAX_EVENT_COUNT` raised 1024 → 2^20
      (the old "~10 events/action" rationale was wrong for the
      multi-actor laws, which emit one `balanceChanged` per affected
      actor) + the count-driven pre-allocation clamped to a bounded
      `EVENT_BATCH_PREALLOC`; (3) a Unix test (`fake-knomosis` recording
      its argv) proves the global flags are spawned in the right
      position.  `knomosis-event-subscribe` suite 214 → 219 (config
      flag-parse + `extractor_global_args` ordering + invalid/missing
      flag rejection + the spawn-argv forwarding test + the raised-cap
      pin).
  * **GP.6.4** Rust-side `knomosis-indexer`
    per-actor budget view + per-resource (ETH / BOLD) gas-pool
    inflow views.  Widens the indexer's `Event` mirror
    (`runtime/knomosis-indexer/src/event.rs`) from the pre-GP.6.4
    tag range `0..=15` to the full `0..=20` — adding the four
    Workstream-GP gas-pool variants
    (`DepositWithFeeCredited` (16), `ActionBudgetTopUp` (17),
    `GasPoolClaim` (18), `DelegatedActionBudgetTopUp` (19)) plus
    the new kernel `BudgetConsumed` (20) +
    a `BudgetUnits` type alias + `RESOURCE_ID_ETH` /
    `RESOURCE_ID_BOLD` constants pinned at 0 / 1 to match
    `KnomosisBridge.sol` and the Lean side.  Extends
    `decoder.rs` with per-variant encoder + decoder arms
    byte-equivalent to Lean's `Encoding.Event.encode`
    (mechanically pinned via the `cross_stack_lean_event`
    differential, which now round-trips ALL 21 tags' REAL Lean
    bytes through the indexer's `decode_event` +
    `encode_event` — previously tags 16..=19 decoded to the
    typed `UnknownTag`; the `INDEXER_MAX_KNOWN_TAG` constant in
    `tests/cross_stack_lean_event.rs` is now 20).
    **Kernel side.**  Adds the new non-TCB `Event.budgetConsumed
    (actor, amount)` at frozen tag 20 (`Events/Types.lean`),
    emitted by `extractEvents` on every ADMITTED, non-bridge
    (`signer ≠ Bridge.bridgeActor`) action under a `.bounded
    freeTier actionCost _` policy with `actionCost > 0`; the
    `amount` is exactly the kernel's `actionCost`, because the
    admission gate consumes precisely that much on success and
    rejects when the budget is insufficient — so the indexer's
    per-epoch consumed tally is an EXACT mirror of the kernel's
    consumption (`extractEvents_emits_budgetConsumed_for_non_bridge_signer`,
    plus bridgeActor-exemption + zero-cost no-emission tests).
    **Storage side.**  Rather than kv keyspaces, the per-actor
    budget + per-pool views live in FIVE dedicated SQL tables
    created by `knomosis-storage`'s `migration_002_budget_views`
    (schema version 2): `actor_budgets` (lifetime grants),
    `actor_budgets_current_epoch_grants`,
    `actor_budgets_current_epoch_consumed`, `pool_balances_eth`,
    `pool_balances_bold` — each `(actor BLOB PRIMARY KEY, value
    BLOB) WITHOUT ROWID` with an 8-byte BE u64 key + 16-byte BE
    u128 value.  New modules `budget_storage.rs`
    (`BudgetStorage` / `BudgetStorageTransaction` traits) and
    `combined_transaction.rs` (`SqliteCombinedTransaction` +
    `CombinedStorage::begin_combined_tx`) let one `BEGIN
    IMMEDIATE` span BOTH the `kv` table (balances + cursor) AND
    the five budget tables.  All SQL uses `&'static str` table
    constants + bound `?N` params (no injection surface).
    **Indexer side.**  `Indexer::apply_batch` opens ONE
    `begin_combined_tx` and runs five passes (epoch-boundary
    reset → balance-semantic → balance-authoritative →
    GP budget/pool dispatch → cursor advance), committing the
    whole batch atomically.  Tag 16/17/19 credit lifetime
    `actor_budgets` AND `..._current_epoch_grants` (tag 19 to
    the RECIPIENT, not the signer — a load-bearing distinction
    from tag 17) plus the pool inflow ledger; tag 20 credits
    `..._current_epoch_consumed`; tag 18 (`GasPoolClaim`)
    DRAINS the pool when the daemon runs with `--gas-pool-actor
    <id>` (else gross-inflow no-op).  Budget / pool arithmetic
    is CHECKED — a `u128` overflow or pool underflow HALTS the
    batch (rolls back) rather than wrapping or saturating
    (matching the balance view's halt discipline).
    **Epoch resets** ("N actions remaining this epoch"): the
    indexer persists a `c/current_epoch` cell and computes
    `epoch_for_seq(seq) = (seq − 1) / epoch_length`, aligned
    EXACTLY to the kernel's `logIndex / epochLength` because the
    tail-reader `seq` is 1-indexed and `logIndex` is 0-indexed
    (`logIndex = seq − 1`); on a crossing the two per-epoch
    tables DELETE-reset inside the same combined transaction.
    `BudgetReadView::remaining_this_epoch(a) = freeTier +
    grants_this_epoch − consumed_this_epoch` (read in a single
    transaction so the two reads can't tear) equals the kernel's
    authoritative `currentBudget` exactly when `freeTier = 0` or
    the actor's carryover ≤ `freeTier`, and is a conservative
    lower bound otherwise.  **CLI.**  Three new one-shot
    subcommands (`query-budget` / `query-pool-eth` /
    `query-pool-bold`) + daemon flags `--gas-pool-actor`,
    `--epoch-length`, and `--verify-budget-against-knomosis`
    (an honest `NotImplemented`-exit stub, same posture as
    `--verify-against-knomosis`).  Atomicity proven by
    `apply_batch_atomicity_balance_failure_rolls_back_budget`
    (a mixed batch with a GP-family credit + an underflowing
    withdraw rolls back BOTH views); restart persistence by
    `restart_preserves_budget_view`; concurrency by a
    deterministic mpsc-rendezvous reader-blocks-during-writer
    test + monotone-atomic-update readers; correctness against a
    reference HashMap model by `proptest`.  Cross-stack:
    `gp_family_field_projections_consistent` pins
    `DelegatedActionBudgetTopUp`'s projection to Lean's
    `Event.actor` (recipient, not signer).  Workspace `cargo
    test --workspace --locked` reports ~1 739 tests passing.
  * **GP.6.5** BOLD-specific cross-stack fixture corpus — the
    tri-stack (Lean → Rust → Solidity) byte-equivalence closure of
    the BOLD-leg deposit path.  A single Lean generator
    (`LegalKernel/Test/Bridge/CrossCheck/BoldDeposit.lean`, suite
    `crosscheck-bold-deposit`, 21 cases) authors BOTH a rich JSON
    fixture (`solidity/test/CrossCheck/fixtures/bold_deposit.json`,
    `{ header, entries }` shape) and a binary `.cxsf` corpus
    (`runtime/tests/cross-stack/l1_ingest_bold.cxsf`, new
    `FixtureKind::L1IngestBold` / on-disk tag 7) from ONE 190-entry
    list: a 160-entry ETH+BOLD grid over `amount ∈ {1, 10⁹, 10¹⁵,
    10¹⁸}` × `chosenFeeBps ∈ {0, 100, 1000, 2500, 5000}` ×
    `weiPerBudgetUnitBold ∈ {1, 10⁹, 3·10¹⁵, 10¹⁸}`, plus 6
    single-leg boundary entries (the `u64::MAX` whale ceiling at
    `0 %` and `50 %`, and the `10¹⁸` explicit clamp — each mirrored
    on BOTH legs), plus 24 USD-calibrated cross-amount entries (12
    ETH/BOLD pairs; 95 ETH / 95 BOLD overall; 20 clamp-active, 80
    grid twin pairs, 12 calibration pairs).  The four-rate grid
    spans the budget-grant regime from saturated (rate 1, clamped at
    the cap) through proportional down to floored-to-zero (rate
    10¹⁸); the `3·10¹⁵` rate is the production USD-calibrated BOLD
    rate.  The 12 calibration pairs deposit `amount_eth` ETH at
    `rate 10¹²` and `3000·amount_eth` BOLD at `rate 3·10¹⁵` (the
    same USD value at the same USD-per-budget-unit rate); because the
    calibration is exact, the two legs' budget grants are EQUAL
    byte-for-byte — the spec's "calibration parity" deliverable
    (DIFFERENT amounts, equal grants), distinct from the grid twins'
    same-amount resource-agnosticism.  Each entry's expected bytes
    are the 72-byte CBE `Action.depositWithFee` concatenated with the
    18-byte CBE encoding of the recipient's **post-deposit
    `ActorBudget`** — the dimension this WU adds over GP.5.4 /
    GP.6.1, built through the real `EpochBudgetState.topUp` ledger.
    Two Lean theorems bind this to the PRODUCTION admission gate:
    `recipientBudgetCell_currentBudget` (the modelled ledger's
    recipient `currentBudget` = `budgetGrant`, via the kernel lemmas)
    and `recipientBudgetCell_matches_gate` (for any admitted
    `depositWithFee` under the genesis budget policy, the gate's
    `apply_admissible_with_budget` post-state `currentBudget` equals
    the corpus model — via the proven `depositWithFee_grants_budget`),
    so the corpus value IS the admission-gate result rather than a
    parallel re-derivation; a gate refactor breaks the build.  The
    Rust consumer
    (`runtime/knomosis-l1-ingest/tests/cross_stack_bold.rs`,
    11 tests) and the Solidity consumer
    (`solidity/test/CrossCheck/BoldDepositFixtures.t.sol`, 10 tests)
    INDEPENDENTLY recompute the split (`FeeSplitInput::split` /
    `FeeSplitMath.split`), the action CBE, and the recipient budget,
    and byte-match the Lean-authored values — including ETH/BOLD
    resource-parametric byte-equality (action bytes differ only at
    the resource-field byte; budget bytes identical), grid
    resource-agnosticism (exactly 80 same-amount twin pairs),
    USD-calibration parity (exactly 12 cross-amount pairs with equal
    budget grants), clamp coverage (exactly 20), and
    `recipientBudgetAfter == budgetGrant` (BOTH stacks decode the
    18-byte budget tail to `{0, budgetGrant}` byte-for-byte —
    previously the Solidity side only length/prefix-checked it).  The Solidity side
    additionally drives the LIVE `depositBoldWithFee` /
    `depositETHWithFee` contract paths per entry and asserts the
    emitted `(userAmount, poolAmount, budgetGrant)` equal the Lean
    values.  `knomosis-cross-stack` gains the `L1IngestBold` enum
    variant (`from_tag` / `to_tag` arms + enumeration / tag-7 pin
    tests).  The split / CBE / budget bytes are hash-independent, so
    the cross-checks run unconditionally (no keccak-binding gate).
    The whole tri-stack agrees byte-for-byte; Phase GP.6 is
    complete.
  * **GP.7.0** Exhaustive characterisation of the bridge-signable
    action set (`LegalKernel/Bridge/BridgeActor.lean`).  The pre-GP
    `bridgePolicy` already authorised `depositWithFee` (landed under
    GP.2.3); this WU (a) hardens `bridgeAuthorizedAction` into a
    wildcard-free exhaustive match and (b) adds three theorems that
    pin the bridge actor's authority surface in one statement each,
    replacing reliance on the one-constructor-at-a-time
    `bridgePolicy_authorizes_*` / `bridgePolicy_rejects_*` family:
    - `bridgeAuthorizedAction` is now an **exhaustive match with no
      `_ => false` catch-all** (the AR.17 discipline applied to the
      bridge classifier): all 22 `Action` constructors have an
      explicit `true`/`false` arm.  Adding a new constructor makes the
      `def` non-exhaustive and breaks the build until its
      bridge-authority is classified — the catch-all previously
      absorbed new constructors silently as "not authorised".
    - `bridgeAuthorizedAction_eq_true_iff` — the single source of
      truth: `bridgeActor` may sign EXACTLY `replaceKey`,
      `registerIdentity`, `deposit`, and `depositWithFee`, and nothing
      else.  Proven by exhaustive `cases` on `Action`.
    - `bridgePolicy_authorizes_all_bridge_actions` — the
      no-regression positive half (bundles the four
      `bridgePolicy_authorizes_*` theorems).
    - `bridgePolicy_rejects_non_bridgeable` — the exhaustive negative
      half (every action outside the authorised set is rejected for
      `bridgeActor`), derived from the iff so it inherits the same
      forcing function.

    **Two complementary forcing functions** guard against silent
    drift: a new `Action` constructor is caught by the exhaustive
    `bridgeAuthorizedAction` match itself; a verdict flip / new
    `=> true` arm without a matching iff disjunct is caught by
    `bridgeAuthorizedAction_eq_true_iff`'s `cases` proof (an unsolved
    `True ↔ False`).  When Workstream GP.11 adds `ammSwap`, the first
    fires immediately (forcing a `true`/`false` classification); if it
    is made bridge-signable, the second forces the matching iff
    disjunct.

    All three theorems depend only on `propext` / `Quot.sound` (zero
    TCB delta; `bridgePolicy_authorizes_all_bridge_actions` is now
    axiom-free).  The `bridge-actor` suite grows by 20 GP.7.0 cases
    (58 total), including **five END-TO-END admission cases** that run
    `BridgeAdmissibleWith` / `apply_bridge_admissible_with` under
    `bridgePolicy` itself (the WU's literal "admitted ✓" criterion —
    the pre-existing budget / runtime suites only exercised
    `AuthorityPolicy.unrestricted`): bridge-signed `depositWithFee` /
    `deposit` / `registerIdentity` admitted; bridge-signed `transfer`
    / `topUpActionBudget` rejected.  The `ammSwap` arm of the WU lands
    with Workstream GP.11 (the `ammSwap` constructor does not exist
    yet); the two forcing functions guarantee its bridge-authority
    classification is added in lockstep when it does.  Shipped names
    drop the plan's `v1_5` infix per the naming discipline (no version
    markers in identifiers).
  * **GP.7.1** Reserved gas-pool actors
    (`LegalKernel/Bridge/BridgeActor.lean` +
    `LegalKernel/Bridge/AddressBook.lean`).  Reserves two `ActorId`
    slots immediately after the bridge actor (`ActorId 0`):
    - `gasPoolActor` (`ActorId 1`) — holds the deposit fee-split skim
      + per-actor budget top-up payments at both `ResourceId 0` (ETH)
      and `ResourceId 1` (BOLD); its outflow is bounded by the
      (forthcoming) GP.7.2 `gasPoolPolicy`.
    - `sequencerActor` (`ActorId 2`) — the sole authorised recipient
      of `gasPoolActor` outflow under `gasPoolPolicy`, and the actor
      that submits L2 state roots to L1.

    The reservation is operational, like the bridge actor's: the
    genesis `AddressBook.empty.nextActorId` advances from `1` to `3`
    (pinned by `addressBook_empty_nextActorId : empty.nextActorId =
    3`), so — because a fresh `assign` returns exactly the current
    `nextActorId` (`assign_eq_of_lookup_none`) and only bumps it upward
    (`assign_fresh_actorId`) — an `empty` + `assign` chain never issues
    a reserved slot to a user-registered identity (the first user actor
    a fresh deployment registers is `ActorId 3`).  Three
    pairwise-distinctness theorems ship — `gasPoolActor_ne_bridgeActor`,
    `sequencerActor_ne_bridgeActor`, `sequencerActor_ne_gasPoolActor`
    (axiom-free `decide`) — which the GP.7.2 `gasPoolPolicy` recipient
    restriction rests on (a pool whose only permitted drain recipient
    coincided with itself could not be drained), plus the
    reservation-guarantee theorem `empty_assign_id_avoids_reserved`
    (the id `assign` issues for a fresh address is distinct from every
    reserved slot).  The `bridge-actor` suite grows by 13 GP.7.1 cases
    (71 total); the `bridge-address-book` (31) and `bridge-ingest` (28)
    value fixtures are rebased onto the new genesis id (`Bridge/Ingest.lean`
    itself is unchanged — it allocates from `nextActorId` abstractly).
    No kernel TCB delta; no new axioms (the disjointness theorems are
    axiom-free; `addressBook_empty_nextActorId` / `empty_assign_id_avoids_reserved`
    depend only on the canonical `{propext, Classical.choice, Quot.sound}`
    via `Std.TreeMap`).  **Runtime-adaptor lockstep — DONE (pulled
    forward from GP.10):** the Rust production adaptor
    `knomosis-l1-ingest::AddressBook` advances in lockstep
    (`INITIAL_NEXT_ACTOR_ID = 3`, with mirror `GAS_POOL_ACTOR_ID` (1) /
    `SEQUENCER_ACTOR_ID` (2) constants), so the adaptor that performs
    the actual `assign` honours the reservation — a fresh L1 identity
    registration is issued `ActorId 3`, never a reserved slot.  The
    state-file replay additionally rejects a persisted reserved-range
    id — for BOTH the legacy `AddressAssigned` and the atomic
    `Submitted.assigned` record paths — with an actionable migration
    diagnostic (it names the reserved range + points at the GP.10.4
    remapping migration, rather than the generic "gap or duplicate"
    message that would mislead an operator upgrading an existing node);
    pinned by `replay_rejects_reserved_actor_id` +
    `replay_rejects_reserved_actor_id_in_submitted_record`.  The
    regenerated `l1_ingest.cxsf` corpus + the `address_book` / `state` /
    `translation` / `watcher` / integration tests are rebased onto the
    genesis-3 allocation (a new `gas_pool_and_sequencer_ids_are_reserved`
    test mirrors the Lean guarantee).  This is the *fresh-genesis* half;
    the orthogonal migration of *existing* deployments that already
    allocated users in 1..3 remains Phase GP.10.4.
  * **GP.7.2** Canonical `gasPoolPolicy` declaration
    (`LegalKernel/Bridge/GasPoolPolicy.lean`).  The per-actor
    `LocalPolicy` (Workstream LP) the admission layer consults whenever
    `gasPoolActor` (GP.7.1 / `ActorId 1`) signs an action.  It bounds
    the pool's outflow to a single capability: a per-action-capped
    `transfer` to `sequencerActor` (GP.7.1 / `ActorId 2`).  Five
    conjunctive clauses — `denyTags gasPoolDeniedTags` (deny every
    Action tag except `transfer`) + `requireRecipientIn` / `capAmount`
    on each of `ResourceId 0` (ETH) and `ResourceId 1` (BOLD), with
    independent per-leg caps `maxDrainPerActionEth` /
    `maxDrainPerActionBold`.  `gasPoolDeniedTags = (List.range
    23).filter (· ≠ 0) = [1..22]` covers the frozen Action set (0..21)
    plus the reserved GP.11 `ammSwap` slot (22); the deny-list's
    coverage is mechanically enforced by `Action.tag_lt_denyListBound`
    (exhaustive `cases`, a build-time forcing function — appending a
    24th Action constructor without bumping the range breaks the
    proof).  Headline theorems: `gasPoolPolicy_denies_all_non_transfer`
    (the pool can never `mint` / `burn` / `withdraw` / top up budgets /
    sign any non-transfer action — closing attack-tree item 5's
    fund-rerouting and bounding item 4's drain),
    `gasPoolPolicy_requires_sequencer_recipient_eth` / `_bold` (a pool
    transfer to any non-`sequencerActor` recipient is denied per leg),
    `gasPoolPolicy_caps_per_action_eth` / `_bold` (the per-action
    amount is capped per leg) + their positive `_amount_le` extraction
    forms (the per-step ingredient the GP.7.3 inductive drain bound
    sums), `gasPoolPolicy_eth_bold_independent` (the two legs'
    resource-keyed clauses are vacuous on the other resource, so a
    legitimate BOLD transfer is never blocked by an ETH clause and vice
    versa), the happy-path `gasPoolPolicy_permits_sequencer_transfer_eth`
    / `_bold` (the legitimate capped sequencer claim is admitted), and
    the single-source-of-truth `gasPoolPolicy_permits_transfer_iff`
    (the exact permitted-transfer set).  Two boundaries are made
    explicit rather than glossed: (a)
    `gasPoolPolicy_permits_transfer_off_gas_legs` — the policy is
    SILENT on resources `≥ 2` (it carries no clause for them), so the
    pool's off-leg safety rests on a separate pool-balance invariant
    (documented; the GP.7.3 track); and (b) the
    **admission-layer reach + the LP.7 meta-action escape hatch**:
    `gasPoolPolicy_admission_permits_iff` characterises the kernel's
    `localPolicyPermits` conjunct (meta-action OR `.permits`), and
    `gasPoolPolicy_admission_permits_meta_actions` PROVES that a
    `LocalPolicy` structurally cannot bar `gasPoolActor` from
    `declareLocalPolicy` / `revokeLocalPolicy` — so a pool key could
    otherwise wipe its own restriction.  **That hole is closed in this
    WU** by the complementary `gasPoolAuthorityPolicy` (an
    `AuthorityPolicy`, intersected into the deployment policy at
    genesis): the `AuthorityPolicy` conjunct of `AdmissibleWith` has
    NO meta-action exemption, so `gasPoolAuthorityPolicy_rejects_meta`
    bars the escape hatch, while `gasPoolAuthorityPolicy_rejects_non_transfer`
    / `_rejects_off_gas_legs` / `_rejects_non_sequencer` /
    `_rejects_non_pool_sender` additionally enforce (at the authority
    layer) the resource-`≥ 2`, recipient, and SENDER restrictions the
    `LocalPolicy` could not.  The sender restriction (PR #106 review
    fix) is fund-safety-critical: the kernel `transfer` law debits the
    action's `sender` and `AdmissibleWith` checks only `st.signer`'s
    signature, so without binding `sender = gasPoolActor` a held pool
    key could sign `.transfer r victim sequencerActor amount` and drain
    an ARBITRARY victim's balance — `gasPoolActorAuthorized` now
    authorises a pool transfer ONLY when its `sender` is `gasPoolActor`
    itself (the pool moves only its OWN funds).  `_authorizes_sequencer_eth`
    / `_bold` (now with `sender` pinned to `gasPoolActor`) preserve the
    legitimate drain, and
    `gasPoolAuthorityPolicy_other_actors_unrestricted` /
    `_intersect_rejects_meta` prove the genesis intersection narrows
    ONLY `gasPoolActor` and bars its meta-actions under ANY base
    policy.  The encode prerequisites for GP.7.4 also ship:
    `gasPoolPolicy_fieldsBounded` + `gasPoolPolicy_roundtrip`
    (canonical CBE boundedness + decode∘encode round-trip, given
    `UInt64`-range caps).  All axiom-free beyond the canonical
    `{propext, Classical.choice, Quot.sound}` subset (the bare-policy
    + authority theorems use only `propext` / `Quot.sound`; the two
    admission-level theorems pull in `Classical.choice` via
    `ExtendedState`); no kernel TCB delta.  The `bridge-gas-pool-policy`
    suite ships 61 cases (per-leg recipient / cap boundary
    cross-products, the deny-list shape, the `maxDrainPerAction = 0`
    degenerate case, leg independence, the `permits_iff` ⇔ `decide`
    agreement sweep, the resource-`≥ 2` boundary, the admission-layer
    meta-action escape hatch + its end-to-end `AuthorityPolicy` fix
    (including a composition test against the genuinely-restrictive
    `bridgePolicy` base proving intersection only ever narrows, and the
    union-then-intersect GP.7.4 shape that admits the drain while
    barring meta-actions), the PR #106 victim-fund-drain rejection
    (gasPoolActor-signed transfer of another actor's balance denied
    both directly and end-to-end through the intersect wiring),
    `fieldsBounded` + round-trip, and term-level API stability for
    every headline theorem).  Lean-only; the per-epoch inductive drain
    bound is GP.7.3.  Note for GP.7.4: the genesis hook must declare
    `gasPoolPolicy` for `gasPoolActor` AND intersect
    `gasPoolAuthorityPolicy` into the deployment `AuthorityPolicy` —
    both are required; the `LocalPolicy` alone leaves the meta-action
    hole open.
  * **GP.7.3** Inductive pool-drain bound
    (`LegalKernel/Bridge/PoolDrainBound.lean`).  Promotes the GP.7.2
    per-action caps to a per-trace invariant: across any contiguous
    trace of `n` admitted `SignedAction`s respecting the gas-pool
    discipline, `gasPoolActor`'s `ResourceId 0` (ETH-leg) balance cannot
    have decreased by more than `n × maxDrainPerActionEth`.  The bound
    rests on the GP.7.2 `AuthorityPolicy`, NOT the bare `LocalPolicy`:
    `gasPoolPolicy` is sender-blind (cannot distinguish a pool-draining
    `transfer 0 gasPoolActor …` from a victim-draining one) and subject
    to the LP.7 meta-action exemption (cannot keep itself in force across
    a trace), so the per-step controlling facts are stated via
    `gasPoolAuthorityPolicy` (which binds `sender = gasPoolActor`, blocks
    meta-actions, forbids the off-leg surface) — exactly the GP.7.4
    genesis-wiring shape `deploymentPolicy.intersect (gasPoolAuthorityPolicy
    mEth mBold)`.  Shipped: the inductive `PoolBoundedTrace` (length-`n`
    indexed, the type-safe analogue of the plan's `applyTrace`) carrying
    the two per-step facts ((1) a pool-signed step is authorised by
    `gasPoolActorAuthorized`; (2) a non-pool step does not decrease the
    pool — the deployment's `sender = signer` obligation, NOT vacuous
    under `unrestricted`, dischargeable + PROVEN for the dominant
    transfer case incl. the credit-to-pool branch by
    `transfer_other_sender_pool_nondecreasing`); the heart
    `pool_signed_step_drain_le_eth` (ETH debit `amount ≤ mEth` from the
    cap + `amount ≤ balance` from the transfer precondition; BOLD-leg
    locality leaves resource 0 untouched); the combined per-step
    `pool_step_drain_le_eth`; the headline
    `pool_drain_bounded_by_action_count`; corollaries
    `pool_balance_lower_bound_via_trace` (surviving-balance floor) +
    `pool_cannot_drain_when_cap_zero` (`mEth = 0` ⇒ no ETH drain); the
    `gasPoolActorAuthorized_of_admissible_intersect` connector
    discharging fact (1) from the genesis-wiring policy; and the
    `apply_admissible_with_base` / `gasPoolActorAuthorized_gasPool_imp_transfer`
    supporting reductions.  **Optimal closure (also delivers the GP.7.5
    core):** the bound is proven **per-resource**
    (`pool_drain_bounded_by_action_count_per_resource`, cap `legCap mEth
    mBold rLeg`), with the ETH / BOLD legs as `simp`-specialisations
    (`…` / `…_bold`) — `mBold` is no longer vestigial — and the two legs
    proven independent accounting domains (`per_resource_pool_independence`,
    `pool_balance_eth_leg_independent_of_bold_actions` / `…_bold_…`); the
    non-pool obligation is discharged **exhaustively** over every `Action`
    constructor (`pool_nondecreasing_of_does_not_debit`, gated by the
    decidable `Action.doesNotDebitPoolAt`; the fold-of-credit laws via a
    per-actor fold-monotonicity lemma); the literal plan deliverable ships
    as the **executable** `applyTrace` fold (backed by a general,
    genuinely-computable `Decidable (AdmissibleWith …)` instance that
    lives with its subject in `Authority/SignedAction.lean`, with
    `applyTrace_drain_bounded_per_resource` + the
    `applyTrace_yields_poolBoundedTrace` bridge); and the per-step
    bounds **lift onto the budget-gated production runtime entry**
    (`pool_signed_step_drain_le_budget`,
    `pool_nondecreasing_of_does_not_debit_budget`).
    `apply_admissible_with_base` was relocated to its proper home in
    `Authority/SignedAction.lean`; the GP.4.2 `Accounting.lean`
    cross-references to `pool_balance_lower_bound_via_trace` were
    corrected (it is the outflow-cap floor, not the full
    solvency-reconciliation closure — the still-open `BridgeReachable`
    WU C.6.4 / C.6.5).  `omega`'s `Amount`-atomisation gap is worked
    around via `Nat`-parameter helper lemmas (the `transfer_arithmetic`
    pattern).  `bridge-pool-drain-bound` suite (21 cases).  Lean-only;
    no kernel TCB delta, no new axioms (`{propext, Classical.choice,
    Quot.sound}` only).
  * **GP.7.4** Genesis ratification of the gas-pool discipline
    (`LegalKernel/Bridge/GasPoolPolicy.lean` + a worked example
    deployment + a `knomosis` subcommand).  Wires the GP.7.2 surface
    into a deployment's genesis via the `gasPoolGenesis` hook, which
    bundles BOTH halves of the discipline so neither can be wired
    without the other: `gasPoolGenesisState` declares
    `gasPoolPolicy mEth mBold` for `gasPoolActor` in the genesis
    `localPolicies`, `gasPoolGenesisPolicy` intersects
    `gasPoolAuthorityPolicy mEth mBold` into the base `AuthorityPolicy`,
    and the `GasPoolGenesis` structure + `gasPoolGenesis` constructor
    make the "wire BOTH" contract hold by construction
    (`gasPoolGenesis_wires_both_halves`) — the half-less wiring (which
    would leave the LP.7 meta-action hole open) is unreachable through
    the constructor.  Twelve contract theorems: the state half
    (`gasPoolGenesisState_declares_policy`,
    `_preserves_other_localPolicies`, `_preserves_kernel_substates` —
    the wiring is surgical, only `localPolicies` changes) and the policy
    half (`gasPoolGenesisPolicy_rejects_meta` — the headline,
    `gasPoolActor` meta-actions barred under ANY base policy, closing
    the hole `gasPoolPolicy_admission_permits_meta_actions` exposed;
    `_other_actors_unrestricted` — the intersection narrows ONLY the
    pool; `_rejects_non_pool_sender` — the PR #106 fund-safety fix
    ratified at genesis; `_rejects_off_gas_legs` / `_rejects_non_sequencer`
    / `_rejects_non_transfer`; `_authorizes_sequencer_eth` / `_bold` —
    the legitimate capped claim still admitted).  The worked deployment
    `Deployments/Examples/GasPoolExample.lean` runs the full ETH + BOLD
    lifecycle (bridge-signed `depositWithFee` × 2 → user + pool credit +
    L2 budget grant → capped sequencer claim × 2) end-to-end through the
    production admission gate; `runGasPoolExamplePure` is the
    deterministic pure runner the test asserts against, and
    `runGasPoolExample` is the IO entry the new `knomosis gas-pool-demo`
    subcommand dispatches to (process → persisted log → `replayWith`
    round-trip → exit 0).  The example ships its own deterministic demo
    verifier because the dev binary's linked `Verify` returns `false` at
    the Lean level (a real deployment links ECDSA secp256k1 via
    `@[extern]`).  Engineering placement: the hook lives in
    `Bridge/GasPoolPolicy.lean` (the canonical gas-pool module) rather
    than the plan's tentative `Runtime/Replay.lean`, keeping the generic
    replay module bridge-agnostic.  Subsumes WU GP.7.5's worked-example
    deliverable (both legs are exercised).  **Production-CLI reach +
    config-driven opt-in.**  `GasPoolConfig` + the `*OfConfig` builders
    (`gasPoolGenesisStateOfConfig` / `…PolicyOfConfig` /
    `gasPoolGenesisOfConfig`) make the genesis wiring an opt-in
    `Option`-gated decision ("if the deployment's config says so" —
    `none` is the pre-GP.7.4 genesis, `some` wires both halves), with
    `_none`/`_some` contract theorems.  The generic `knomosis`
    subcommands (`process` / `replay` / `bootstrap` / `snapshot` /
    `replay-up-to` / `export-cell-proofs` / `export-terminate-bundle` /
    `extract-events`) gain
    `--gas-pool-eth-cap` / `--gas-pool-bold-cap` flags that build the
    gas-pool genesis (state + policy) via the hook and thread it through;
    the config is persisted to a `<log>.gaspoolcfg` `GasPoolSidecar`
    (`Runtime/GasPoolSidecar.lean`, mirroring the GP.6.2 `BudgetSidecar`)
    and cross-checked on every log-touching command (the gas-pool
    genesis `localPolicies` declaration participates in the post-state
    hash — and, for `export-terminate-bundle`, in `commitExtendedState`,
    which includes `commitLocalPolicies`, so the terminate bundle's
    `claimedPostCommit` + `cellProofs` are gas-pool-config-dependent —
    so a forgotten / changed / disabled cap fails loudly instead of an
    opaque hash mismatch or an L1-rejected bundle).  The Rust `knomosis-host`
    `CommandKernel` forwards the caps via `with_gas_pool_policy`
    (config `--gas-pool-eth-cap` / `--gas-pool-bold-cap` →
    `gas_pool_caps()` → the spawned `knomosis process` argv), mirroring
    its budget-flag forwarding.  **Theorem completeness:**
    `gasPoolGenesisPolicy_rejects_over_cap_eth` / `_bold` (the
    authority-layer per-action cap rejection) and
    `gasPoolGenesisPolicy_bars_self_declaration` (the structural-genesis
    necessity — once `gasPoolAuthorityPolicy` is in force the pool
    CANNOT install / replace its own `LocalPolicy` via a signed
    `declareLocalPolicy`, so the genesis declaration MUST be structural).
    New `deployments-gas-pool-example` suite (17 cases — the original 13
    plus a proof-carrying budget-grant tie via
    `depositWithFee_grants_budget_bridge`, an honest per-half
    contribution test (LocalPolicy caps the amount but is sender-blind +
    meta-exempt; the AuthorityPolicy is the binding enforcer), a
    restrictive-base composition against `bridgePolicy`, and a snapshot
    round-trip of the gas-pool genesis state) + new
    `runtime-gas-pool-sidecar` suite (9 cases — the sidecar codec +
    `checkConsistent` / `writeSidecarIfAbsent` discipline + the
    `*OfConfig` opt-in/opt-out builders).  No kernel TCB delta, no new
    axioms (the pure policy theorems use only `propext`; the state-half +
    example theorems use `{propext, Classical.choice, Quot.sound}` via
    `Std.TreeMap` / `ExtendedState`).
  * **GP.11.1** Embedded ETH↔BOLD AMM — L1 state variables + reserves
    (`solidity/src/contracts/KnomosisBridge.sol`).  The first sub-WU of
    Phase GP.11: the AMM's L1 scaffold, purely additive.  Adds two
    mutable reserve slots `ammReserveEth` / `ammReserveBold` (no direct
    setter — seeded on deposit in GP.11.2, mutated by `ammSwap` in
    GP.11.3), the immutable `ammSeedRatioBps` (the bps fraction of each
    pool-fee deposit routed to AMM liquidity, threaded as a new
    `ConstructorArgs.ammSeedRatioBps` field and validated
    `<= MAX_AMM_SEED_RATIO_BPS` at construction — `AmmSeedRatioExceedsMax`
    otherwise), and the two constitutional compile-time caps
    `AMM_SWAP_FEE_BPS = 30` (0.30%, the Uniswap-v2-standard swap fee) /
    `MAX_AMM_SEED_RATIO_BPS = 8000` (80%, the structural defence against
    starving sequencer free-pool claims).  GP.11.1 added only the storage
    scaffold (no seeding / swap logic — deposit-side seeding lands in
    GP.11.2, below); `ammSeedRatioBps = 0` disables the AMM and preserves
    the pre-v1.3 behaviour byte-for-byte (every existing `ConstructorArgs`
    initializer passes `0`).  The two new caps join the GP.5.2 source-level
    cap-audit gate (`scripts/audit_compile_time_caps.sh`, now 6 caps + 4
    address pins + 1 symbol pin; self-test 37 → 45 cases) AND a
    compiled-contract runtime pin
    (`AmmStorage.t.sol::test_ammCompileTimeCaps_pinned`).  The
    `test/AmmStorage.t.sol` suite (16 cases) pins the GP.11.1 storage
    surface: caps pinned, seed-ratio store/validate incl. the `> MAX` +
    `uint16`-max reverts + a `[0, MAX]`-accept / `(MAX, uint16Max]`-reject
    fuzz pair, reserves start at zero with the seed as their sole write
    path, the AMM has no admin setter (a no-AMM-setter-selector probe), the
    ratio-invariance of the canonical deposit event
    (`test_depositSplit_unchanged_acrossRatios`), and the constructor-guard
    ordering — plus minimal positive seeding sanity checks that GP.11.2
    updated in place (see below).  Solidity-only; the L2 mirror
    (`Action.ammSwap`) is GP.11.4 / GP.11.5.
  * **GP.11.2** Embedded ETH↔BOLD AMM — seeding on deposit (cross-stack:
    Solidity + Lean cross-check corpora + Rust ingestor).  The shared
    `_registerDepositWithFee` (`KnomosisBridge.sol`) now seeds the AMM from
    each fee-split deposit's pool fee via the new `private
    _seedAmmReserves(resourceId, poolAmount)` helper: `ammSeedAmount =
    floor(poolAmount * ammSeedRatioBps / 10000)` (0 when disabled, floored,
    or off the ETH/BOLD gas legs) grows the matching reserve (`ammReserveEth`
    / `ammReserveBold`); the free-pool remainder is the implicit `poolAmount
    - ammSeedAmount`.  Conservation holds end-to-end (`userAmount +
    ammSeedAmount + freePoolAmount == deposit`); the seed reclassifies value
    already counted in `totalLockedValue`, so `ammReserveEth + ammReserveBold
    <= totalLockedValue` (a Foundry invariant).  Checked arithmetic
    throughout (`ratio <= MAX_AMM_SEED_RATIO_BPS = 8000 < 10000` ⇒
    `ammSeedAmount <= poolAmount`; overflow reverts rather than wraps).  A
    `GP.11.10 hook point` comment marks where `emergencyDisableAmm()`'s
    early-out will go.  **Wire format (plan-literal):** the split is carried
    in the canonical `DepositWithFeeInitiated` event by inserting a `uint256
    ammSeedAmount` field after `poolAmount` and BOUND in the `receiptHash`
    (`keccak256(abi.encode(deploymentId, sender, resourceId, token,
    userAmount, poolAmount, ammSeedAmount, budgetGrant, depositorNonce))`),
    so the L2 reconstructs `freePoolAmount = poolAmount - ammSeedAmount` from
    one event and a replay with a tampered split is rejected (the receiptHash
    is sensitive to `ammSeedAmount`, pinned by
    `AmmDepositSeeding.t.sol::test_receiptHash_bindsAmmSeedAmount`).  This is
    the additive form (keep `poolAmount`, insert `ammSeedAmount`) — equally
    tamper-evident, preserving the total fee.  The change bumps the event
    topic-0 hash (`0xdffb2055…e4c8f5`) + the receiptHash preimage (9 fields
    / 288 bytes), accepted as the v1.3 wire addition and propagated
    cross-stack in lockstep: the Rust ingestor (`knomosis-l1-ingest::events`
    — pinned topic + signature + `decode_event` offsets + the
    `amm_seed_amount` variant field + `.cxsf` codec) and the
    `deposit_fee_split{,_bold}.json` receiptHash corpora (the Lean
    generators add the `ammSeed` reference + proof-carrying `ammSeed_le` /
    `ammSeed_conserves` bounds + per-entry `ammSeedRatioBps` / `ammSeedAmount`
    + the 9-field recipe; 6 AMM-enabled boundary corners (`ammcorner:*`) are
    appended (corpus 80 → 86) and the 64 randomised entries draw a random
    `ammSeedRatioBps ∈ [0, 8000]` so 69 of 86 carry NON-ZERO seeds whose
    binding is cross-stack-verified — pinned by a `countNonZeroSeed` header
    each consumer recounts + asserts `>= 50`; the Solidity consumers deploy
    each entry's bridge at its ratio and byte-match the emitted split +
    256-byte preimage tail).  `bold_deposit.json` (an L2 action + budget
    corpus) and the plain-deposit `DepositReceiptHash` corpus are unchanged
    (their consumers absorb the new zero `ammSeedAmount`).
    `test/utils/FeeSplitMath.sol` gains the `ammSeedSplit` reference (with a
    `ratio <= 10000` precondition guard) + threads `ammSeedAmount` through
    `receiptHash`.  New `test/AmmDepositSeeding.t.sol` (~26 cases: per-leg
    seeding via the event's `ammSeedAmount`, the disabled / zero-fee / dust
    `ammSeedAmount == 0` paths, the ETH + BOLD tamper-evidence tests, leg
    independence, monotonic accumulation, reserve-subset-of-TVL,
    `test_cappedDeposit_revertsAndDoesNotSeed` + `test_plainDepositETH_doesNotSeed`
    (negative paths), `test_seedAmmReserves_offLeg_seedsNothing` (the
    off-gas-leg branch via a `SeedHarness` over the now-`internal` helper),
    `test_ammSeedSplit_knownVectors` (non-circular reference anchor),
    `test_gas_seedingOverhead` (a COMPARATIVE gas pin), three conservation
    fuzz tests, and a 7-invariant stateful suite (reserve == sum-of-admitted-
    seeds per leg, global reserves <= TVL, the two per-currency bounds
    `ammReserveBold <= boldTotalLockedValue` / `ammReserveEth` within the ETH
    TVL portion (catch a wrong-leg seed), + the two REAL-TOKEN backing bounds
    `ammReserveEth <= address(bridge).balance` / `ammReserveBold <=
    BOLD.balanceOf(bridge)` (the reserve is backed by actual tokens, not just
    the TVL accounting — catches a TVL-vs-balance divergence)) over 128 000
    random ETH+BOLD deposits at a moderate cap so some revert) plus the
    AMM-enabled
    `BridgeFeeSplitBold.t.sol::test_e2e_ammReserveSurvivesBoldWithdrawal`
    end-to-end test (deposit seeds the reserve; a withdrawal drains all
    non-seed value, proving `reserve <= TVL` survives with the seed as the
    irreducible floor).
    `test/AmmStorage.t.sol`'s ratio-invariance test became
    `test_coreSplit_ratioInvariant_butAmmSeedScales` (the core
    user/pool/budget triple is ratio-invariant while the event's
    `ammSeedAmount` + receiptHash scale).  `forge build` warning-free; full
    `forge test` green; the GP.5.2 cap-audit gate + self-test (45 cases)
    stay green (no cap changed); full Lean + Rust gates green.  The L2
    `Action.ammSwap` mirror + `ammReserveActor` are GP.11.4 / GP.11.5; the
    deposit-side L2 reconstruction that consumes `ammSeedAmount` lands with
    the sequencer deposit-materialisation work.
  * **GP.11.3** Embedded ETH↔BOLD AMM — the constant-product swap function
    (`solidity/src/contracts/KnomosisBridge.sol` + the new pure
    `solidity/src/lib/AmmMath.sol`).  Adds the permissionless `ammSwap(
    fromResource, amountIn, minAmountOut, deadline) payable nonReentrant`
    entry point: a Uniswap v2-style ETH↔BOLD exchange against the GP.11.1/2
    reserves at the immutable `AMM_SWAP_FEE_BPS = 30` (0.30%) fee, RETAINED
    in the reserves so the product `k = ammReserveEth × ammReserveBold` is
    monotonically non-decreasing (strictly increasing per non-trivial swap —
    the fee accrues as LP yield for the gas pool).  Both directions: ETH→BOLD
    takes `msg.value` and sends BOLD via `safeTransfer`; BOLD→ETH pulls via
    `safeTransferFrom` with a `balanceOf`-delta check (fee-on-transfer
    defence, mirroring `depositBoldWithFee`) and sends ETH via a low-level
    `call`.  `minAmountOut` slippage + `deadline` MEV protection; a
    `ZeroSwapOutput` guard rejects a dust input that floors to a zero output
    (no donation-for-nothing); an `AmmEmpty` early-out covers the unseeded /
    BOLD-disabled pool.  Strict Checks-Effects-Interactions ordering under
    `nonReentrant`, plus a belt-and-braces on-chain k-monotonicity assertion
    (`AmmKInvariantViolated`) and the proven `amountOut < reserveOut` curve
    bound (`ReserveExhausted`) so a math regression fails closed rather than
    draining the pool.  The pure `AmmMath` library (`getAmountOut` /
    `getAmountIn`, fee-parameterised, self-validating, `internal` ⇒ inlined,
    checked arithmetic) is the reusable swap-math core, independently pinned
    against hand-computed vectors.  **Accounting (Option C):** a swap NEVER
    touches `totalLockedValue` / `boldTotalLockedValue` — the AMM is a
    self-contained, value-conserving sub-pool; solvency rides on the
    REAL-TOKEN-BACKING invariants `ammReserveEth ≤ address(this).balance` /
    `ammReserveBold ≤ BOLD.balanceOf(this)` (each reserve moves in exact
    lockstep with the matching real balance, so a swap touches only AMM
    reserves, never any L2 user's backing).  Event `AmmSwapExecuted` +
    eleven swap errors.  A `GP.11.10 hook point` comment marks where the
    `ammActive` modifier (revert once `emergencyDisableAmm()` is triggered)
    will attach.  Coverage (54 new cases over a shared `AmmTestBase`, all
    green): `AmmMath.t.sol` (20 — exact vectors + the headline k-monotonicity
    fuzz + the `getAmountIn` round-trip + the revert surface),
    `AmmSwap.t.sol` (13 — both directions, reserve / real-balance accounting,
    the TVL-untouched design pin, fee-accumulation, the full revert surface),
    `AmmReentrancy.t.sol` (3 — a malicious ETH recipient re-entering a
    would-succeed swap is blocked with NO double-spend, and a malicious BOLD
    token in the output path fails safe via `ReentrancyGuardReentrantCall`),
    `AmmInvariants.t.sol` (5 — the stateful k-never-decreases + reserves-stay-
    positive + real-token-backing + TVL-untouched harness over 128 000 random
    ETH↔BOLD swaps, 0 reverts), `AmmSlippage.t.sol` (9 — `minAmountOut` and
    `deadline` exact boundaries + protection), `AmmSandwich.t.sol` (4 — a
    front-run degrades execution, a full sandwich profits without protection,
    and `minAmountOut` deterministically stops it).  `MockBold.transfer` was
    made `virtual` so the swap-reentrancy mock can override it.  Solidity-only
    (the L2 `Action.ammSwap` mirror is GP.11.4); `forge build` warning-free,
    full `forge test` green, the GP.5.2 cap-audit gate + self-test (45 cases)
    unchanged (no constitutional cap added — the swap reuses
    `AMM_SWAP_FEE_BPS`; `AmmMath`'s `BPS_DENOMINATOR` lives outside the
    audited `KnomosisBridge.sol`).

Out of scope for this in-flight closure: the
GP.4.2 pool-solvency reconciliation's *deposit-fold* promotion (the
per-step deposit-case preservation
`pool_solvency_preserved_by_admitted_depositWithFee` ships; the GP.7.3
drain bound — now complete, per-resource — folds the *outflow*
discipline over a whole admitted trace via `PoolBoundedTrace` /
`applyTrace`; GP.7.5's per-resource bound + two-leg independence are
delivered with GP.7.3's optimal closure); the AMM-aware
strong-conservation extension (needs `Action.ammSwap` +
`ammReserveActor`, GP.11); the materialised
`bridgeEscrowBalance` RHS + full inductive accounting equation (the
WU C.6.4 / C.6.5 `BridgeReachable` follow-up; the `escrow` term stays
abstract in `bridge_accounting_equation_balanced_iff`); and GP.7.6 –
GP.10 plus GP.11.4 – GP.11.10 (sequencer integration, the L2
`Action.ammSwap` mirror, etc.; GP.11.1's L1 state scaffold + GP.11.2's
deposit-side seeding + GP.11.3's L1 constant-product swap have landed).
GP.5.1's ETH fee-split entry point,
GP.5.2's constitutional fee-split-cap audit gate, GP.5.3's L1
step-VM execution arm for `topUpActionBudgetFor` (variant 21),
GP.5.4's BOLD-currency fee-split entry point `depositBoldWithFee`,
and GP.5.5's BOLD-specific safety hardening (per-currency circuit
breaker + Liquity-V2 depeg auto-trigger + per-BOLD TVL cap) are
complete (above) — closing the GP.5 Solidity-side L1-mirror
arm.  GP.6.1's Rust-side encoder mirror, GP.6.2's
`knomosis-host` budget admission gate, GP.6.3's
`knomosis-event-subscribe` event-type registry, GP.6.4's
`knomosis-indexer` per-actor budget view + per-resource (ETH /
BOLD) gas-pool inflow views, and GP.6.5's BOLD-specific tri-stack
cross-stack fixture corpus (above) close all five sub-WUs of the
Phase-GP.6 Rust runtime amendment — Phase GP.6 is complete.

Phase GP.9.1 (refund-on-exit) has its **full L2 signable action**
landed — end-to-end "click-to-withdraw" through every layer of the
Lean runtime.  A user signs a `claimBudgetRefund` to retire EXACTLY
their remaining *purchased* action budget
(`currentBudget − actionCost − freeTier`, which EXCLUDES the free-tier
subsidy) for a `budgetUnits × weiPerBudgetUnit` gas payout out of
`gasPoolActor`, redesigning OQ-GP-10's earlier `poolAmount`+time sketch
(the per-actor `EpochBudgetState` already tracks remaining budget, so
there is no per-deposit state-bloat).  Shipped:
`Laws.claimBudgetRefund` (the `gasPoolActor → claimant` kernel leg —
the MIRROR of `topUpActionBudget` — with the full §4.11 classification
ladder); `Bridge.BudgetRefund` (the `refundableBudget` / `refundAmount`
functionals + the four soundness theorems: free-tier immunity,
round-trip non-profitability via floor division, no double refund,
free-tier preservation); the `Action.claimBudgetRefund` constructor at
frozen index 22 with full CBE codec / `Action.toTransition` /
`kernelOnlyApply` mirror / step-VM cell layout
(`actionKindByte`/`actionFieldsForL1`/`readOnlyCells`/`writeCells`) /
`bridgeAuthorizedAction => false` / the sound `doesNotDebitPoolAt` arm;
the §13.6 admission gate (`claimBudgetRefund_gate`, NINE safety
conjuncts: rate pin, refund-ENABLED check `1 ≤ weiPerBudgetUnit` — so
the default `refundRate = 0` genuinely rejects refunds rather than
burning budget for a zero payout — pool-actor pin, canonical-gas-leg
pin (`gasResource ∈ {0,1}`), free-tier-excluding bound, solvency,
consume-exempt / self-pool defences) on BOTH the
kernel and bridge-aware entries; the COMPANION `topUpRoundTripCheck`
gate on those same two entries seals the top-up → refund round-trip by
tying a top-up's `budgetIncrement` to its `gasAmount` at the refund
rate (`budgetIncrement × refundRate gasResource ≤ gasAmount`), so a
claimant cannot mint cheap budget via `topUpActionBudget` /
`topUpActionBudgetFor` and refund it at the pinned rate to drain the
pool (the rate pin alone bounded the price of a retired unit, not how
cheaply it was acquired) — vacuous at the default `refundRate = 0` so
pre-refund deployments stay byte-unchanged, and the bound is extracted
on both paths by
`topUpActionBudget{,For}_roundtrip_not_profitable{,_bridge}`; the
trusted per-resource rate is
threaded as
ADMISSION config (`refundRate : ResourceId → Nat`, NOT persisted — the
kernel step uses the action's logged `weiPerBudgetUnit`, so replay /
fault-proof stay deterministic); the headline admission theorems
(`claimBudgetRefund_gate_characterization`,
`admission_refund_consumes_budget`,
`admission_refund_preserves_free_tier`, the six
`refund_rejected_when_*` corollaries — incl.
`refund_rejected_when_non_canonical_resource` (the canonical-gas-leg
pin) and `refund_rejected_when_rate_disabled`, which pins that a `0`
rate genuinely rejects).  The two POSITIVE guarantees are mirrored on the
PRODUCTION (bridge-aware) path at an ARBITRARY deployment `refundRate`
— not only the disabled default — by
`admission_refund_consumes_budget_bridge` /
`admission_refund_preserves_free_tier_bridge`, which lift through the
now rate-generic agreement corollaries
(`apply_bridge_admissible_with_budget_{epochBudgets_eq,none_iff,
kernel_epochBudgets,base_bridge_eq}` all thread `refundRate`); this
closes a soundness gap where the original mirrors excluded refunds
(`hne_refund`) and proved bridge↔kernel agreement only at rate 0, so
the production path's refund correctness was unproven at the only
configuration in which refunds function.  Plus
`balanceChanged` + a widened `budgetConsumed`
(`actionCost + budgetUnits`) event emission (NO new `Event`
constructor); runtime threading of `RuntimeState.refundRate`
through `processSignedActionWith` / `processPure` / `replayStepWith` /
the full replay chain (`replayLoopWith` / `replayWith` /
`replayFromSeedWith`) AND the restart-reconstruction path (`bootstrap`
/ `replay`) AND event extraction (`extractEventsStepWith`); and the
**operator CLI + sidecar** — the `--wei-per-budget-unit-eth` /
`--wei-per-budget-unit-bold` flags thread the trusted rate into every
log-touching subcommand (`process` / `replay` / `bootstrap` /
`snapshot` / `replay-up-to` / `export-cell-proofs` /
`extract-events`), persisting a non-default rate to a
`<LOG>.refundratecfg` `RefundRateSidecar` cross-checked on every such
command (a forgotten / changed rate fails with a clear `refund-rate
error`, not a silently-dropped refund on replay; `export-terminate-bundle`
is refund-rate-independent — `kernelOnlyReplay`, no gate — and so
untouched).  Refunds DISABLED by default (rate 0, no sidecar).  The
standalone `knomosis-replay` auditor binary (which has no config flags)
RECONSTRUCTS the full deployment config from the three persisted sidecars
— budget policy + epoch via `BudgetSidecar.load`, gas-pool policy via
`GasPoolSidecar.load`, refund rate via `RefundRateSidecar.load` (each
`load`: absent ⇒ default, present ⇒ decoded, corrupt ⇒ loud error) — so a
config-bearing log audits to the SAME state hash the producer's `knomosis
replay` yields, instead of being rejected (a refund whose rate-pin is
unmet) or diverging (a budget / gas-pool genesis the deny-all default
omits).
Suites `bridge-budget-refund` (30 cases — incl. two END-TO-END
bridge-path admission cases driving `apply_bridge_admissible_with_budget`
at a nonzero rate + the kernel-path signed admission / disabled-rate
rejection / event emission, plus the four round-trip-seal cases: the
`topUpRoundTripCheck` value-level reject/accept/vacuous sweep and three
END-TO-END top-up admissions proving a cheap mint is rejected at an
active rate, the same mint is admitted at the disabled default rate, and
a fairly-priced mint is admitted) + `runtime-loop-happy-path` (+2, a refund
admitted / rejected through the literal `processSignedActionWith`) +
the new `runtime-refund-rate-sidecar` (10 — codec round-trip /
`toRefundRate` / `isDefault` / `checkConsistent` /
`writeSidecarIfAbsent` / the auditor `load`) + `encoding-action` (+4); all axioms ⊆ the
canonical three; no `gasPoolDeniedTags` bump needed (tag 22 ∈
`List.range 23`).  Two deployment sharp-edges are documented (not bugs):
cross-resource rate consistency (a single shared budget refunds at the
richest blessed leg — calibrate per-resource rates to equal value) and
the Solidity `_step22`'s `uint256` payout (the
`budgetUnits × weiPerBudgetUnit` product can reach ~2^128).  **The L1
step-VM execution arm + the Rust mirrors are now COMPLETE**: the Lean
`stepVMHash` kind-22 recipe (`stepCommitClaimBudgetRefund` + the
dispatcher arm + `stepVMHash_claimBudgetRefund_kind`;
`actionKindByteCases` → 22; `stepVMHash_unknown_kind_empty` re-pinned
at 23) + the parity theorems `coherence_claimBudgetRefund` /
`cellwrites_claimBudgetRefund`; the Solidity
`KnomosisStepVM._stepClaimBudgetRefund` (uint256 payout;
credit-claimant / debit-pool; pool-solvency guard); the cross-stack
`step_vm.json` corpus widened 248 → 258 (the keccak-gated driver
byte-matches all 158 happy fixtures under the linked build); and the
Rust mirrors (`knomosis-l1-ingest` `Action::ClaimBudgetRefund` encoder
byte-pinned against Lean via the `deposit_with_fee_action.json`
differential; the `knomosis-host` budget-gate refund arm — consume
`action_cost + budget_units`, the policy-independent rejections,
strict-mode pool solvency — + `CommandKernel::with_refund_rate`
forwarding of the `--wei-per-budget-unit-*` flags + the daemon config
flags; the `knomosis-faultproof-observer`
`ActionKind::ClaimBudgetRefund = 22`; and the `knomosis-indexer`, which
needs NO code change — the widened `budgetConsumed` flows through the
existing tag-20 decoder).  **No `KnomosisBridge` redemption path is
needed** — the refund is an L2 balance credit, withdrawn via the
existing `withdrawWithProof`.

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

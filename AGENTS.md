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
policies) complete; Workstream LX milestones M1 / M2 / M3 complete;
Workstream H (fault-proof migration) complete (Lean + Rust RH-G).
Phase 7 (Advanced Capabilities) is the next scoped work.  See
`docs/GENESIS_PLAN.md` §12 / §15B / §15D and the relevant plan
documents under `docs/planning/` for per-phase deliverables.
See "Implementation roadmap" below for the full status table.

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
lake test                           # full test suite
lake exe count_sorries              # zero-sorry kernel gate
lake exe tcb_audit                  # TCB allowlist gate
lake exe stub_audit                 # stub-detection gate
lake exe naming_audit               # content-name discipline gate
lake exe deferral_audit             # no-deferrals policy gate
lake exe mock_import_audit          # no-test-import-in-production gate
lake exe lex_lint                   # Lex registry + sidecar gate
lake exe lex_codegen --check        # Lex codegen-consistency gate
lake exe lex_diff <before> <after>  # Lex semantic-diff binary
lake exe lex_format <file>          # Lex pretty-printer
python3 scripts/regenerate_codemaps.py  # regenerate codemaps (CI gate)

# Runtime smoke test.
.lake/build/bin/knomosis info
.lake/build/bin/knomosis hash-check   # F-1 deploy gate: exit 1 on the
                                      # FNV-1a-64 fallback, 0 if a
                                      # production hash (BLAKE3/keccak)
                                      # is @[extern]-linked.
.lake/build/bin/knomosis verify-check # F-2 deploy gate: exit 1 on the
                                      # Lean-opaque verifier fallback, 0
                                      # if the secp256k1 adaptor is linked
                                      # AND passes the functional
                                      # self-test (Verify is @[extern]-
                                      # routed; the gate calls it on a
                                      # known-good secp256k1 vector).
.lake/build/bin/knomosis bootstrap /tmp/test.log
.lake/build/bin/knomosis-replay /tmp/test.log
.lake/build/bin/knomosis gas-pool-demo
.lake/build/bin/knomosis extract-events --log /tmp/test.log  < /dev/null

# Workstream E (Solidity contracts) — see solidity/README.md.
cd solidity && ./scripts/vendor-deps.sh   # one-time
cd solidity && forge build
cd solidity && forge test
cd solidity && make test-cross-stack          # F.1.x equivalence suite
cd solidity && make audit-caps                # GP.5.2 fee-split-cap audit gate
cd solidity && make audit-caps-selftest       # self-test for the cap gate
cd solidity && make snapshot-gas-check        # GP.11.9 gas-benchmark gate
cd solidity && make snapshot-gas              # regenerate gas baseline + runbook table
cd solidity && make snapshot-gas-selftest     # self-tests for the GP.11.9 gate
cd solidity && make testnet-acceptance-dryrun # F.3 in-memory dry-run
cd solidity && make devnet                    # F.3 LIVE anvil deploy +
                                              # verify vs deployed contracts

# Keccak-linked cross-stack verification (Lean <-> EVM byte-equivalence).
./scripts/verify_keccak_crossstack.sh

# F-2 production secp256k1-verifier link verification: proves
# `verify-check` flips fallback(exit 1) -> production(exit 0) when the
# real adaptor is linked, and records/verifies the staticlib SHA-256.
./scripts/verify_secp256k1_link.sh            # build + record + prove
./scripts/verify_secp256k1_link.sh --check    # build + verify SHA-256 snapshot

# F-1/F-2 production keccak256-hash link verification: proves
# `hash-check` flips fallback(exit 1) -> production(exit 0) when the real
# keccak adaptor is linked, and records/verifies the staticlib SHA-256
# (the hash-adaptor peer of the secp256k1 verifier pin above; together
# they pin BOTH FFI cdylibs named in the F-2 residual).
./scripts/verify_keccak_link.sh               # build + record + prove
./scripts/verify_keccak_link.sh --check       # build + verify SHA-256 snapshot

# Quantitative economic-incentive simulation (IC-1..IC-6 envelope +
# self-asserting invariant checks; companion to docs/economic_incentive_analysis.md).
python3 scripts/economic_simulation.py

# Workstream RH (Rust host runtime) — see runtime/README.md.
# Toolchain pin: runtime/rust-toolchain.toml (stable 1.83).
cd runtime && cargo build --workspace --all-targets
cd runtime && cargo test --workspace
cd runtime && cargo clippy --workspace --all-targets -- -D warnings
cd runtime && cargo fmt --all -- --check

# Workstream GW (gateway) — synchronous HTTP/JSON + SSE service
# (runtime/knomosis-gateway/; contract docs/api/gateway.openapi.yaml).
# Its Rust gates ride the --workspace commands above; run/test directly:
cd runtime && cargo run -p knomosis-gateway -- --help
cd runtime && cargo test -p knomosis-gateway
```

`lakefile.lean` is the source of truth for every build target,
executable, and `lean_lib`; consult it before adding new targets.

**Toolchain.** Lean 4 v4.29.1 (pinned in `lean-toolchain`).  Bumping
the toolchain requires recomputing the four
`LEAN_TOOLCHAIN_SHA256_*` archive constants in `scripts/setup.sh`
and landing both changes in the same PR.

## Module build verification (mandatory)

Before committing any `.lean` file, build the specific module:

```bash
lake build LegalKernel.<Module.Path>
lake build Lex.<Module.Path>           # for Lex DSL / tools / examples / tests
```

After any source change, also run:

* `lake test` — runs the `@[test_driver]` declared in `Tests.lean`.
  Catches semantic regressions that elaboration-only checks miss.
  Each post-Phase-0 theorem additionally has a term-level
  API-stability test whose elaboration fails if the theorem
  signature changes.
* `lake exe count_sorries` — fails on any `sorry` in proof position
  in a kernel-adjacent module (the `Tools.Common.kernelTcbFiles`
  list).  Masks comments, block comments, and string literals.
* `lake exe tcb_audit` — fails if a TCB-core module imports anything
  not on `tcb_allowlist.txt` or in `Tools.Common.tcbInternalImports`.
* `lake exe stub_audit` — catches placeholder-body stubs accompanied
  by red-flag docstring tokens.  Allowlist: `tools/stub_allowlist.txt`.
* `lake exe lex_lint` + `lake exe lex_codegen --check` — enforce
  the Lex action-index registry's append-only discipline and the
  byte-stability of codegen-input sidecars.
* `python3 scripts/regenerate_codemaps.py` — regenerates the
  per-language navigation maps under `codemaps/`; CI fails if the
  result differs from the committed tree.

CI (`.github/workflows/ci.yml`) runs all of the above on every PR.

## Source layout

```
knomosis/
├── lakefile.lean              -- Lake config (lean_lib, lean_exe, build deps)
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
│   ├── Conservation.lean      -- §8.1 / §5.3 economic invariants + classification
│   ├── Laws/                  -- one law per file (transfer, mint, burn, freeze,
│   │                             reward, distributeOthers, proportionalDilute,
│   │                             deposit, withdraw, replaceKey, registerIdentity,
│   │                             depositWithFee, topUpActionBudget,
│   │                             topUpActionBudgetFor, claimBudgetRefund,
│   │                             ammSwap, reclaimAmmReserves, dispute
│   │                             pipeline, local-policy laws)
│   ├── Authority/             -- Crypto, Action, Identity, Nonce, LocalPolicy,
│   │                             LocalPolicySemantics, SignedAction, ActorBudget
│   ├── Encoding/              -- CBE codec (CBOR, Encodable, Action, Event,
│   │                             SignedAction, State, SignInput, Disputes,
│   │                             LocalPolicy, *Injective siblings for EI.2–EI.7)
│   ├── DSL/                   -- Law.mk + `law` macro (base DSL)
│   ├── Events/                -- §8.9.2 Event inductive + extractEvents
│   ├── Runtime/               -- Hash, LogFile, Replay, EventStream, Snapshot,
│   │                             Loop, BudgetSidecar, GasPoolSidecar,
│   │                             RefundRateSidecar
│   ├── Disputes/              -- §8.4 four-stage pipeline (Phase 6)
│   ├── LocalPolicy/           -- Workstream LP classification typeclasses
│   ├── Bridge/                -- Workstreams A–D + GP + CA: crypto adaptors,
│   │                             identity, bridge laws, withdrawal proofs,
│   │                             gas-pool policy, pool-drain bound, AMM math,
│   │                             AMM reserve policy, budget refund, accounting,
│   │                             receipt-verified claim (GP.8.5 v2),
│   │                             BridgeReachable + chain-level conservation (CA)
│   ├── FaultProof/            -- Workstream H: state-commitment, bisection game,
│   │                             convergence/honesty/settlement theorems, SMT
│   │                             cell proofs, step-VM coherence
│   └── Test/                  -- IO-based test harness; one suite per module
├── Lex/                       -- Workstream LX — the Lex programming language
│   ├── IndexRegistry.txt      -- frozen action-index registry (append-only)
│   ├── DSL/                   -- Lex DSL macros
│   ├── Tools/                 -- Lex audit-binary libraries
│   ├── Bin/                   -- Lake lean_exe entry-point wrappers
│   ├── Inputs/                -- Lex codegen-input JSON sidecars
│   ├── Examples/              -- Lex-only demonstration laws
│   └── Test/                  -- Lex test modules
├── Deployments/Examples/      -- worked example deployments (UsdClearing, GasPool)
├── Tools/                     -- non-Lex audit binaries + shared Common library
├── solidity/                  -- Workstreams E + H + GP: L1 mirror contracts
│                                 (see solidity/README.md)
├── runtime/                   -- Workstream RH: Rust host runtime
│   ├── Cargo.toml             --   workspace manifest
│   ├── rust-toolchain.toml    --   pinned Rust channel (stable 1.83)
│   ├── knomosis-hash-fallback.c  --   AR.10 default fallback (lake-built)
│   ├── knomosis-cli-common/      --   shared CLI / logging helpers
│   ├── knomosis-cross-stack/     --   dev-dep fixture loader
│   ├── knomosis-verify-secp256k1/ --  ECDSA secp256k1 verifier (cdylib)
│   ├── knomosis-hash-keccak256/  --   keccak-256 hash adaptor (cdylib)
│   ├── knomosis-host/            --   TCP / TLS / Unix network adaptor
│   ├── knomosis-l1-ingest/       --   L1 event watcher daemon
│   ├── knomosis-event-subscribe/ --   event subscription server
│   ├── knomosis-storage/         --   Storage trait + SQLite impl
│   ├── knomosis-indexer/         --   SQLite event indexer daemon
│   ├── knomosis-faultproof-observer/ -- off-chain bisection-game observer
│   ├── knomosis-bench/           --   transfer-throughput benchmark
│   └── tests/cross-stack/     --   shared fixture corpus (.cxsf files)
├── scripts/
│   ├── setup.sh               -- SHA-256-verified toolchain installer
│   ├── verify_keccak_crossstack.sh -- keccak-linked cross-stack orchestration
│   ├── verify_secp256k1_link.sh -- F-2 production-verifier link proof + SHA-256
│   ├── verify_keccak_link.sh  -- F-1/F-2 production keccak256-hash link proof + SHA-256
│   └── economic_simulation.py -- IC-1..IC-6 quantitative incentive harness
├── .github/workflows/
│   ├── ci.yml                 -- Lean build + test + audits
│   ├── ci-rust.yml            -- Rust workspace gates (runtime/**)
│   ├── ci-solidity.yml        -- Solidity cap gate + forge gates (solidity/**)
│   ├── ci-keccak-crossstack.yml -- Lean<->EVM keccak256 byte-equivalence
│   ├── ci-verify-secp256k1.yml -- F-2 secp256k1-verifier production-link proof
│   └── ci-hash-keccak256-link.yml -- F-1/F-2 keccak256-hash production-link + SHA-256 pin
├── README.md                  -- project entry point
├── CLAUDE.md                  -- this file
└── docs/
    ├── GENESIS_PLAN.md          -- canonical design document
    ├── abi.md                   -- on-disk frame format + CLI ABI
    ├── fault_proof_runbook.md   -- Workstream H operator runbook
    ├── audits/                  -- per-area Lean audit reports
    └── planning/                -- engineering / workstream plans
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
                                Authority.Action imports Laws.*, Bridge.*,
                                and Disputes.Types for the Action inductive.)

LegalKernel.Encoding.*         (non-TCB; CBOR / Encodable foundation, then
                                Action → SignedAction → State → SignInput;
                                *Injective siblings host EI.2–EI.7 theorems.)

LegalKernel.DSL.{Law, LawSyntax}
Lex.DSL.{PreGrammar, ImplCalculus, ImplLowering,
          Events, Shim, Law, Property, Deployment}
Lex.Examples.ExampleLex
Lex                            (umbrella; re-exports the Lex DSL surface)

LegalKernel.Events.{Types, Extract}
LegalKernel.Runtime.{Hash, LogFile, Replay, EventStream,
                      Snapshot, AttestedSnapshot, Loop}

LegalKernel.Disputes.{Types, Filing, Evidence, Verdict,
                       LawClassification, MonotonicDeployment,
                       Rewards, Staking}

LegalKernel.LocalPolicy.LawClassification
LegalKernel.Bridge.*           (non-TCB; Workstreams A–D + GP)

LegalKernel                    (umbrella; re-exports everything)
Main / Replay / Tests          (executables)

Tools.Common                   (shared helpers for audit binaries)
Lex.Tools.Common               (shared helpers for Lex audit binaries)
Tools.{TcbAudit, CountSorries, StubAudit, NamingAudit, DeferralAudit}
Lex.Tools.{Lint, Codegen, Diff, Format}
Lex.Bin.{Lint, Codegen, Diff, Format}
```

The kernel has **zero** external Lean-package dependencies.
`Std.Data.TreeMap` is part of Lean core (since Lean ≥ 4.10), not a
separate Lake package, so the TCB equals exactly the Lean core
distribution plus `Kernel.lean` + `RBMapLemmas.lean`.  Every other
module is non-TCB deployment-facing infrastructure.

**Trust assumptions.**  Two non-Lean assumptions surface through
opaque declarations rather than axioms (so `#print axioms` stays at
exactly `propext`, `Classical.choice`, `Quot.sound`):

1. `Authority.Crypto.Verify` — the deployment-supplied signature
   scheme is EUF-CMA secure.  `@[extern "knomosis_verify_ecdsa"]`
   routes the compiled runtime call to the secp256k1 adaptor (fail-
   closed reject-all fallback for tests); the logical value stays
   opaque, so the trust assumption is preserved.
2. `Runtime.Hash.hashBytes` — the production hash function (BLAKE3
   via `@[extern]`; FNV-1a-64 fallback for tests) is
   collision-resistant.

## Reading large files

`docs/GENESIS_PLAN.md` is ~4200 lines / ~180 KB.  Read in chunks with
`Read(file_path, offset=…, limit=500)` rather than the whole file.
The table of contents at the top maps section numbers to line ranges.

When editing, read the specific region around the target lines first
(e.g., `offset=2580, limit=80`) so the `old_string` matches exactly.

## Writing and editing files

**Prefer the Edit tool for all changes to existing files**, regardless
of size.  The Write tool replaces an entire file and is error-prone
for files over ~100 lines.

**Rules for large-file changes:**

1. **Never rewrite a large file with Write.**  Use Edit with a
   precise `old_string`/`new_string` pair.
2. **One logical change per Edit call.**
3. **Read before you edit** so the `old_string` matches exactly.
4. **Adding large new sections:** break into multiple sequential Edit
   calls, anchoring each to existing context.
5. **Creating new large files:** use an initial Write (under 100
   lines) followed by Edit appends, or a Bash heredoc.
6. **Post-write verification:** spot-check the modified region and
   the file's last few lines.

## Handling large search and command output

- **Grep**: cap with `head_limit`; use `output_mode:
  "files_with_matches"` first, then drill in.
- **Glob**: scope with `path` instead of searching the whole repo.
- **Bash output**: pipe through `head` / `tail`.  For very large
  output, redirect to a temp file and `Read` in chunks.

**Rule of thumb:** if a command might return more than ~100 lines,
limit it upfront.

## Background-agent file-change protection

Background agents run concurrently and may finish after the
foreground agent has already modified the same files.

1. **Never delegate file writes to a background agent for files you
   may also edit.**
2. **Partition files strictly** across parallel agents.
3. **Use background agents only for read-only or independent-file
   tasks.**
4. **Check background results before acting on shared state.**
5. **When in doubt, run in foreground.**

## Implement-the-improvement rule

When an audit, code review, or any reading of the codebase surfaces a
discrepancy between the **code** and the **documentation, docstring,
comment, type signature, or design intent** that describes it, and the
description represents an *improvement* over the actual code (a more
complete behaviour, a more symmetric API, a stronger invariant, a
routed dispatch where the code is a stub, a function that "should"
exist but does not), the remediation is **always** to implement the
improvement so the description becomes true.

It is **forbidden** to weaken, dilute, qualify, or rewrite the
documentation to match inferior code. Documenting incorrect or
incomplete code in lieu of fixing it is not an acceptable engineering
outcome on this project.

Concretely:

- A comment referencing a function `X` that does not exist →
  **implement `X`**, never "remove the reference."
- A docstring describing a complete spec while the implementation is
  truncated → **complete the implementation**, never "document the
  truncation."
- A stub returning `NotImplemented` while the design says it should
  route to a verified entry point → **wire up the routing.**
- Two API call paths handling the same condition asymmetrically →
  **make them symmetric**, never "document the asymmetry."
- An implicit invariant maintained only by convention → **enforce it
  structurally** (record field, refinement type, smart-constructor
  obligation, opaque type whose constructors discharge the invariant),
  never "add an inline comment about the convention."
- A computed-and-proven data structure that the surrounding code does
  not consume → **wire it into the consumer** so the proof carries
  through to runtime, never "remove the unwired structure."
- Deferred items buried in source comments → **fix them** if the
  current scope permits; otherwise lift them into the project debt
  register (`docs/audits/`, `docs/WORKSTREAM_HISTORY.md`). Never leave
  in-source TODOs that age out with the surrounding workstream.
- A "first hardware target" or similar capability claim while the path
  is non-functional → **make the path functional**, never qualify the
  claim with a stub-status caveat.

The single legitimate exception is when the documentation describes a
**worse** state than the code (e.g. a stale `STATUS: staged` marker on
a file that has since been wired into production, or a deprecation note
on a function the project has decided to keep). In that direction the
documentation is the inferior artefact and updating it to match the
better code is correct.

## Key conventions

- **Two-reviewer rule for kernel-touching changes (ABSOLUTE).**  Any
  change to `LegalKernel/Kernel.lean` or
  `LegalKernel/RBMapLemmas.lean` requires two reviewers per Genesis
  Plan §13.6.  Law modules and tests require one reviewer.
  `.github/CODEOWNERS` auto-requests reviewers for TCB-core files.

- **No `sorry` in kernel-adjacent code (ABSOLUTE).**  The
  kernel-adjacent files (`Kernel.lean`, `RBMapLemmas.lean`,
  `Laws/Transfer.lean`) must not contain a `sorry` in proof position.
  `lake exe count_sorries` is the mechanical check; CI blocks the
  merge on a non-zero count.

- **No custom axioms (ABSOLUTE).**  The kernel may use Lean's
  built-in axioms (`propext`, `Classical.choice`, `Quot.sound`) but
  must not introduce its own.  Adding an `axiom` declaration is a
  Genesis-Plan amendment and triggers the two-reviewer gate.

- **Std-core only in the kernel TCB.**  The kernel imports
  `Std.Data.TreeMap` (Lean core) plus `LegalKernel.RBMapLemmas`.
  `lake exe tcb_audit` enforces the import allowlist.  Adding Mathlib
  or batteries is a TCB expansion requiring §13.6 amendment.

- **Strict linters project-wide.**  `lakefile.lean` sets:
  - `autoImplicit := false` (and `relaxedAutoImplicit := false`)
  - `linter.missingDocs := true` — public surfaces must have
    `/-- … -/` docstrings.
  - `linter.unusedVariables := true`
  - CI fails the build on any Lean `warning:` diagnostic line.
    Every `lean_lib` + `lean_exe` is `@[default_target]`, so no
    module's warnings can hide.

- **Decidability discipline (§13.6 step 2).**  Every
  `Transition.decPre` field should be definable as
  `fun _ => inferInstance` whenever the precondition is built from
  arithmetic comparisons, `Nat` operations, and finite conjunctions.

- **Naming conventions:**
  - Theorems and lemmas: `snake_case` — `impl_refines_spec`.
  - Structures and types: `CamelCase` — `Transition`, `Legal`.
  - Type variables: `α`, `β`, `γ`; states: `s`, `s'`; transitions: `t`.
  - Hypothesis names: `h`-prefixed — `hpre`, `hreach`, `h_init`.
  - Namespaces: `LegalKernel`, `LegalKernel.Laws`, `LegalKernel.Test`.
  - **Names describe content, never provenance.**  Forbidden tokens
    in declaration names: `wu`, `phase`, `audit`, `finding`, `f02`,
    `claude_`, `session_`, `old`, `new`, `v2`, `legacy`, `tmp`,
    `todo`, `fixme`.  Process markers may appear in docstrings and
    commit messages, never in identifiers.
  - **Enforcement:**
    ```bash
    git diff --cached -U0 -- '*.lean' \
      | grep -E '^\+(def|theorem|structure|class|instance|abbrev|lemma|noncomputable)' \
      | grep -iE 'workstream|\bws[0-9]|\bwu[0-9]|\bphase[0-9_]|audit|\bf[0-9]{2}\b|\btmp\b|\btodo\b|\bfixme\b|claude_|session_|_v[2-5]\b'
    ```
    A non-empty result is a review-blocking naming violation.
    `naming_audit`'s `forbiddenTokens` list mirrors this in CI.

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
    `transfer` is §4.11), say so in the docstring.

- **Import discipline:**  Import by full path within the project
  (`import LegalKernel.Kernel`).  Re-export top-level definitions
  via `LegalKernel.lean` (the umbrella module).

- **Git practices:**  One commit per completed work unit.  Commit
  messages may reference the WU number.  All commits must pass
  `lake build` AND `lake test`.

- **Patch-version bumps (DEFAULT).**  Each pull request bumps the
  patch component unless the user explicitly says otherwise.

  | Surface        | Bump location                                    |
  |----------------|--------------------------------------------------|
  | Lean kernel    | `lakefile.lean` `version` + `LegalKernel.lean` `kernelVersion` |
  | Rust workspace | `runtime/Cargo.toml` `[workspace.package] version` |
  | Solidity       | `solidity/foundry.toml` (if `version` present)   |
  | README banner  | `README.md` top-of-file `**Version:** vX.Y.Z`    |

  Lean and Rust versions are bumped in lockstep to the same value in
  every PR.  Use semver: patch (default) for bug fixes / refactors /
  tests; minor for new backwards-compatible functionality; major for
  breaking changes.

  *Mechanics:*
  ```toml
  # runtime/Cargo.toml
  [workspace.package]
  version = "0.5.6"     # <-- bump this; member crates inherit
  ```
  ```lean
  -- lakefile.lean
  package knomosis where
    version := v!"0.5.6"     -- <-- bump this in lockstep
  -- LegalKernel.lean  (mirrors lakefile.lean; surfaced by `knomosis info`)
  def kernelVersion : String := "0.5.6"
  ```
  `Cargo.lock` is regenerated automatically and must be committed.

  *When NOT to bump:* doc edits within an in-progress workstream that
  will bump on its own PR.  Standalone doc-only PRs still bump.

## Type-level design properties

The Genesis Plan promises a small set of type-level guarantees
(§1, §5).  Every guarantee is mechanised by a real Lean theorem
(no `sorry`, no custom axioms — only `propext`, `Classical.choice`,
`Quot.sound`).  Selected headline theorems by tier:

| Tier | Property | Headline theorem | File |
|------|----------|------------------|------|
| TCB | Determinism | typing of `step_impl` | `Kernel.lean` |
| TCB | No silent illegality | `impl_noop_if_not_pre` | `Kernel.lean` |
| TCB | Refinement | `impl_refines_spec` | `Kernel.lean` |
| TCB | Invariant preservation | `invariant_preservation` | `Kernel.lean` |
| TCB | Compositionality | `invariants_compose` | `Kernel.lean` |
| TCB | Certified ≡ executable | `apply_certified_eq_step_impl` | `Kernel.lean` |
| TCB | Reachability | `Reachable.refl`, `Reachable.trans` | `Kernel.lean` |
| TCB | Per-law-set invariant | `invariant_preservation_via_laws` | `Kernel.lean` |
| TCB | RBMap lemmas | `find?_insert_*`, `sumValues_*` | `RBMapLemmas.lean` |
| Phase 2 | Transfer conserves supply | `transfer_conserves` | `Laws/Transfer.lean` |
| Phase 2 | Conservation typeclass | `IsConservative`, `ConservativeLawSet` | `Conservation.lean` |
| Phase 2 | Global supply preservation | `total_supply_global` | `Conservation.lean` |
| Phase 3 | Action compilation injective | `Action.compile_injective` | `Authority/Action.lean` |
| Phase 3 | Nonce uniqueness | `nonce_uniqueness` | `Authority/SignedAction.lean` |
| Phase 3 | Replay impossible | `replay_impossible` | `Authority/SignedAction.lean` |
| Phase 4 | CBE round-trip + injectivity | `*_roundtrip`, `*_encode_injective` | `Encoding/*.lean` |
| Phase 4 | Domain-separated sign inputs | `signInput_*` | `Encoding/SignInput.lean` |
| EI.2–7 | Encoder injectivity ladder | `*.encode_injective` | `Encoding/*Injective.lean` |
| EI.8 | State-commit extensional eq | `commitExtendedState_subcommits_extensional_eq_under_collision_free` | `FaultProof/Commit.lean` |
| Phase 6 | Dispute filing rejects malformed | `fileDispute_rejects_*` | `Disputes/Filing.lean` |
| Phase 6 | Evidence verifiers deterministic | `checkEvidence_deterministic` | `Disputes/Evidence.lean` |
| LP | Meta-action independence | `localPolicy_meta_action_independent` | `Authority/SignedAction.lean` |
| E-A | EIP-712 wrap injectivity | `eip712Wrap_injective` | `Bridge/Eip712.lean` |
| E-B | Bridge policy characterisation | `bridgeAuthorizedAction_eq_true_iff` | `Bridge/BridgeActor.lean` |
| E-C | Deposit/withdraw replay impossible | `deposit_replay_blocked_by_consumed` | `Bridge/Admissible.lean` |
| E-D | SMT verifier completeness + soundness | `verifyProof_complete`, `verifyProof_sound` | `Bridge/WithdrawalRoot.lean` |
| GP.7.2 | Gas-pool outflow capped | `gasPoolPolicy_permits_transfer_iff` | `Bridge/GasPoolPolicy.lean` |
| GP.7.3 | Per-resource pool drain bound | `pool_drain_bounded_by_action_count_per_resource` | `Bridge/PoolDrainBound.lean` |
| GP.8.5 | Receipt-verified claim double bound | `receiptVerifiedClaim_capped_and_backed` | `Bridge/ReceiptVerifiedClaim.lean` |
| GP.8.5/OQ-GP-8b | BOLD-leg receipt double bound | `receiptVerifiedBoldClaim_capped_and_backed` | `Bridge/ReceiptVerifiedClaim.lean` |
| GP.11.6 | AMM reserve outflow restricted | `ammReservePolicy_permits_iff` | `Bridge/AmmReservePolicy.lean` |
| GP.11.8 | AMM state committed to bridge | `bridgeState_commit_includes_ammState` | `FaultProof/Commit.lean` |
| GP.11.8 | v1.2 backward compatibility | `bridgeState_commit_extends_v1_2` | `FaultProof/Commit.lean` |
| GP.11.8 | Encoding factoring | `bridgeState_encode_factored` | `FaultProof/Commit.lean` |
| GP.11.8 | AMM genesis suffix const | `bridgeState_amm_genesis_suffix_const` | `FaultProof/Commit.lean` |
| CA | Chain bridge conservation | `bridge_chain_conserves` | `Bridge/ChainAccounting.lean` |
| CA | Chain bridge solvency | `bridgeReachable_solvent` | `Bridge/ChainAccounting.lean` |
| CA | §7.6.4 escrow identity (unconditional) | `bridge_chain_accounting_equation` | `Bridge/ChainAccounting.lean` |
| H | Bisection convergence | `bisection_converges_after_enough_rounds` | `FaultProof/Convergence.lean` |
| H | Honest challenger wins | `honest_challenger_wins_against_invalid_state_root` | `FaultProof/Settlement.lean` |
| SC.1 | SMT cell-proof soundness | `smtCellProof_sound_under_collision_free` | `FaultProof/Smt.lean` |
| SVC | Step-VM dispatcher coherence | `stepVMHash_<variant>_kind` | `FaultProof/StepVMCoherence.lean` |

The full per-theorem catalogue lives in source — each module's
`/-! ... -/` docstring names the Genesis-Plan section it implements,
and `#print axioms` confirms each theorem depends only on the
canonical three Lean built-ins (or a strict subset).

Modifying any TCB-tier property triggers the two-reviewer gate;
modifying any non-TCB property needs one reviewer.

## Std core integration

Knomosis's kernel uses **Lean core only**, no Mathlib or batteries.
Key Std definitions used in the kernel:

| Std name              | Type                          | Role in Knomosis            |
|-----------------------|-------------------------------|--------------------------|
| `Std.TreeMap α β cmp` | structure                     | balanced ordered map (RB)|
| `TreeMap.empty`       | `TreeMap α β cmp`             | empty map                |
| `TreeMap.insert`      | `… → α → β → TreeMap …`       | insert / overwrite       |
| `m[k]?` / `find?`     | `… → α → Option β`            | lookup                   |
| `m[k]?.getD v`        | `… → α → β → β`               | lookup with default      |
| `TreeMap.foldl`       | `(δ → α → β → δ) → δ → … → δ` | order-determined fold    |

The full per-lemma audit lives in `docs/std_dependencies.md`.  Each
addition to the kernel's import set must update **both**
`tcb_allowlist.txt` and `docs/std_dependencies.md` in the same PR.

**Version strategy.**  Pin the Lean toolchain in `lean-toolchain`;
`scripts/setup.sh` validates archive SHA-256s.  Bump only when a
specific feature is needed, and recompute the SHAs in the same PR.

## Implementation roadmap

Genesis Plan §12 lays out eight phases (0–7) plus cross-cutting
work units.  Status:

| Phase | Title | Status |
|-------|-------|--------|
| 0–4 | Foundations through DSL/serialization | Complete |
| 5 | Runtime and extraction | Complete |
| 6 | Disputes and adjudication | Complete |
| E-A–G | Ethereum integration (7 workstreams) | Complete |
| LP | Actor-scoped policies | Complete (Lean side) |
| LX-M1–M3 | Lex language (3 milestones) | Complete |
| H | Fault-proof migration | Complete (Lean + Rust RH-G) |
| RH-H–G | Rust host runtime (11 workstreams) | Complete |
| SC.1–3 | SMT cell proofs (3 workstreams) | Complete |
| SVC | L1 step-VM coherence | Complete |
| FQ/GP.8 | Fair queuing (knomosis-host) | Tracks A + B + C complete; D documented; GP.8.5 v2 receipt-verified claim shipped — **both legs** (Lean + Rust); OQ-GP-8b closed (BOLD-leg ETH→BOLD oracle + independent-observer receipt-fetch) |
| GP | Unified gas pool / budgets / AMM | In progress (GP.0–7.4, GP.8 Tracks A–C, GP.8.5 v2 both legs incl. OQ-GP-8b, GP.9.1, GP.11.1–10 complete; GP.10 final ratification remaining — now gated only on the two-reviewer pass, see `unified_gas_pool_plan.md` §GP.10) |
| AR | Audit remediation | Complete (all findings closed; m-16 via CA) |
| CA | Chain-level bridge accounting | Complete (closes m-16; §7.6.4 / §7.6.5) |
| EI | Encoder injectivity | Complete |
| GW | Gateway (HTTP/JSON + SSE) | In progress (read-only slice shipped + hardened; submit track complete; events track underway: G0.1–G0.3/G1.0–G1.4/G1.6a/G1.6b/G1.7/G1.8/G1.9/G2.1a/G2.1b/G2.2/G2.3/G2.4/G2.5/events track complete (G3.1/G3.2/G3.3 + the full G3.4 SSE fan-out (ring/mux/dispatch/resume) + G3.5 `/v1/events/stream` wiring); G4 hardening: core complete (G4.1 rate-limit (early via G1.3) + G4.2 native in-process HTTPS/mTLS (rustls 0.23, TLS 1.3, alongside the plaintext socket, reusing the shared request core via a strict HTTP/1.1 reader) + G4.3 observability + G4.4 graceful shutdown + G4.5 dep-audit + G4.7 runbook; G4.6 partial (fan-out + no-leak soak; throughput-bench/high-concurrency deferred, tiny_http SSE-concurrency ceiling = OQ-GW-14)); G2.1c pipelining + G3.2c cross-stack pin deferred — `gateway_integration_plan.md`) |
| 7 | Advanced capabilities | Not started |

Read the Genesis Plan's per-phase work-unit breakdown and the
relevant workstream plan in `docs/planning/` before starting new work.

## Documentation rules

When changing behaviour, theorems, or formalisation status, update
in the same PR:

1. `docs/GENESIS_PLAN.md` — if the change affects the architecture,
   the formal model, the threat model, or the roadmap.
2. `README.md` — if project status, build commands, or quickstart
   change.
3. `CLAUDE.md` (and `AGENTS.md` — keep them byte-identical) — if
   conventions, build commands, or current-status summary change.

Canonical ownership: `docs/GENESIS_PLAN.md` owns the design; this
file owns engineering conventions; `README.md` owns the top-level
introduction.

**Don't extend audit narratives in this file.**  Per-audit and
per-WU completion details belong in commit messages and PR
descriptions.  This file describes the *current state*, not the
path that got us here.

## Pull request authoring policy (ABSOLUTE)

**Forbidden in PR summaries / descriptions / bodies:** session URLs
of the shape `https://claude.ai/code/session_*` (or any equivalent
agent-harness session permalink).

**Why:**  Privacy / opacity (PR readers cannot open it), link rot
(sessions expire), provenance leakage, citation discipline.

**Allowed alternatives:** Genesis-Plan section numbers, headline
theorem names + file paths, workstream-plan documents under `docs/`.

**Scope:** PR descriptions / bodies, PR review comments, PR-edit
`body` arguments.  Out of scope: local commit messages.

**Enforcement.**  Before invoking
`mcp__github__create_pull_request` or
`mcp__github__update_pull_request`, scan the prepared `body` for
`https?://(?:www\.)?claude\.ai/code/session_[A-Za-z0-9]+` and strip
every match.

## Current development status

**Runtime version** (`kernelVersion` in `LegalKernel.lean`): mirrors
the `lakefile.lean` `version` field (currently `0.8.4`) — the single
project-wide build identifier, surfaced by `knomosis info` and the
test driver.  It is bumped in lockstep with `lakefile.lean`,
`runtime/Cargo.toml`, and the `README.md` banner per the
"Patch-version bumps" table; there is no separate milestone tag and
no value-pinning regression test (the former `kernelBuildTag` was
removed as redundant once every PR bumps the version).

**Test counts.**  `lake test` is the canonical Lean query; `cargo
test --workspace` is the Rust canonical query.  Approximate counts
at the current version:

| Surface | Tests | Suites | Canonical query |
|---------|-------|--------|-----------------|
| Lean | ~3 050 | ~150 | `lake test` |
| Rust | ~1 960 | across 11 crates | `cargo test --workspace` |
| Solidity | ~867 passed | 58 forge suites | `cd solidity && forge test` |

Only monotonic growth is enforced — no global gate pins the count.

**Notable Lean suites** (selected; see `LegalKernel/Test/` for the
full catalogue):

- `authority-signed-budget` — GP.3.2 admission-gate theorems +
  five-round security hardening regression tests.
- `faultproof-stepvm-coherence` — 25-variant step-VM dispatcher
  byte-equivalence (kinds 0–24).
- `crosscheck-step-vm` — 278-entry cross-stack fixture corpus.
- `reclaim-amm-reserves` — GP.11.10 exact-sweep law + AMM-mirror
  trace-constancy theorems.
- `faultproof-smt` — SC.1 SMT cell-proof soundness.
- `encoding-injectivity` — EI.2–EI.8 injectivity ladder.
- `bridge-gas-pool-policy` — GP.7.2 gas-pool policy characterisation.
- `bridge-pool-drain-bound` — GP.7.3 inductive pool-drain bound.
- `bridge-receipt-verified-claim` — GP.8.5 v2 receipt-verified
  sequencer-reimbursement gate, both legs (the `min(cap, cost)` bound;
  ETH wei-exact + BOLD via the OQ-GP-8b ETH→BOLD oracle + the unified
  composer).
- `bridge-amm-reserve-policy` — GP.11.6 AMM reserve policy.
- `crosscheck-amm-swap` — GP.11.7 tri-stack AMM fixture corpus.
- `faultproof-amm-commit` — GP.11.8 AMM state-root commitment
  integration + GP.11.10 `ammDisabled` kill-switch mirror (28 cases).
- `deployments-gas-pool-example` — GP.7.4 end-to-end genesis ratification.
- `bridge-chain-accounting` — CA §7.6.4 / §7.6.5 chain conservation,
  solvency, and the unconditional escrow identity (closes m-16).

**Notable Rust crates by test count:**

| Crate | ~Tests | Role |
|-------|--------|------|
| `knomosis-host` | ~436 | Network adaptor + fair scheduler |
| `knomosis-faultproof-observer` | ~386 | Off-chain bisection-game observer |
| `knomosis-l1-ingest` | ~347 | L1 event watcher + encoder |
| `knomosis-event-subscribe` | ~219 | Event subscription server |
| `knomosis-indexer` | ~206 | SQLite event indexer |
| `knomosis-bench` | ~147 | Transfer-throughput benchmark |
| `knomosis-storage` | ~100 | Storage abstraction + SQLite |

**TCB audit.**  `#print axioms` on every kernel theorem returns a
subset of `[propext, Classical.choice, Quot.sound]`.  No custom
axioms exist.  `Verify`, `hashBytes`, `l1FaultProofVerifier`,
`l1GasReceiptVerifier`, and `l1EthBoldRateOracle` are `opaque`, not
`axiom`.

**TCB import discipline.**  `Tools.Common.tcbInternalImports`
enumerates the project-internal modules each TCB-core file may import
— only `LegalKernel.Kernel` and `LegalKernel.RBMapLemmas` themselves.

**Test patterns.**  Tests use two complementary patterns:

1. **Value-level**: assert `==` between expected and actual results
   (catches definitional drift at runtime).
2. **Term-level API stability**: ascribe a `let _proof : T :=
   theorem ...` binding (catches signature changes at elaboration
   time).

The `MockCrypto.lean` module supplies `mockVerify` / `mockSign` for
happy-path coverage that the production opaque `Verify` cannot
exercise.

## Workstream reference

Each workstream's detailed plan, design rationale, and per-WU
completion narrative live in the relevant `docs/planning/` document
and in git history (`git log --grep="WU"` / `git log --grep="audit"`).
This section is a concise index pointing to source and documentation.

### Knomosis Gateway (Workstream GW)

Plan: `docs/planning/gateway_integration_plan.md` · Contract:
`docs/api/gateway.openapi.yaml` · HTTP-layer decision:
`docs/audits/gateway_http_spike.md`.

A synchronous (no-`tokio`) HTTP/JSON + Server-Sent-Events service
(`runtime/knomosis-gateway/`) that fronts the binary host (§10),
event-subscribe (§11), and indexer SQLite (§11A) surfaces for a
browser-facing BFF, built on the vetted sync crate `tiny_http`
(G1.0).  **In progress:** G0.1–G0.3 (contract + OpenAPI-lint gate),
G1.0 (HTTP-layer spike), G1.1 (crate scaffold — `/healthz` over
`tiny_http`), G1.6a (the `knomosis-storage` read-only open path
+ the DEFERRED budget-read fix), G1.2 (the parse→dispatch→write HTTP
foundation + routing surface), and the read endpoints G1.6b (balances)
+ G1.7 (budget + pools — `GET /v1/actors/{id}/budget` and
`GET /v1/pools/{pool}?resource={0|1}`, with a `--gas-pool-actor` `net`
echo), G1.8 (the typed `/v1/info` — admission stage + wire protocol
versions + indexer cursor/schema + budget-policy echo — and `/readyz`
indexer + upstream TCP probes), G1.4 (the fail-closed
`subtle::ConstantTimeEq` bearer-token gate, applied before routing;
`/healthz` + `/readyz` exempt), G1.9 (the read-path integration
harness — read endpoints end-to-end behind auth, `ETag`/`304`
revalidation, a concurrent-write chaos case), G1.3 (read-path
hardening — per-credential token-bucket rate limiting → `429` +
`Retry-After`, and a fail-fast world-readable-token-file permission
check), and the **submit path** G2.1a (host wire codec) + G2.1b (bounded
persistent connection pool, no-double-submit) + G2.2 (`POST /v1/actions`
— content-negotiated octet-stream / json+base64 intake → opaque forward
→ §5 verdict mapping) + G2.3 (the backpressure matrix — deadline→`504`,
`Busy`/saturated→`503`+`Retry-After`, `413` body cap; a write-timeout is
treated as ambiguous-delivery and not retried) + G2.4 (the
`Idempotency-Key` replay cache — bounded, TTL'd, LRU-evicted; a cached
retry does no second host round-trip) + G2.5 (the submit test surface)
are complete — **the read-only slice is shipped + hardened and the submit
track is complete** (only the optional G2.1c pipelining is deferred).
The events (G3) track is underway with G3.1 (the resilient
`UpstreamSubscription` event-subscribe client — reconnect/backoff,
gap-surfacing, staleness watchdog) and G3.2 (the event decode → JSON
renderer `events/decode.rs::render_event` — the §6.2 envelope over
`knomosis-indexer::decoder::decode_event`: bigint→decimal string,
bytes→`0x`-hex, `outcome` name, forward-unknown for tags ≥23, fail-closed
`Corrupt` on a known-tag decode failure; the G3.2c cross-stack corpus pin
is deferred to the first endpoint that surfaces the JSON), and G3.3 (the
bounded, group-complete `GET /v1/events` backfill — `events/backfill.rs`
drains the unbounded `SUBSCRIBE` stream into a page bounded by the indexer
cursor "tip", `since=0` "from oldest" following the upstream `TRUNCATED`, a
concrete `since < oldest` → `409`+`oldestSeq`, soft-`limit` group-complete
rounding, a gateway-side `type` filter, and the fail-closed decode path;
wired end-to-end through auth → route(query) → dispatch → drain).  The
**G3.4 SSE fan-out** (`events/fanout/`) is complete: G3.4a the bounded
`(seq, index)`-keyed record `ring` (dedup/order guard, `last_evicted`
frontier, `records_after`/`position` queries, last-complete-group
watermark; `proptest`-oracle-verified); G3.4b the single-subscription
`mux` (one shared live-tail subscription feeds the ring, resubscribing on a
drop from the watermark — **not** the newest seq, so a mid-group drop loses
no record; the ring dedups the re-delivered head, a known-tag decode
failure fails closed); G3.4c the per-client `dispatch::run_stream`
(replay-then-live-tail composite `id: <seq>.<index>` records + no-`id:`
heartbeats, type-filtered, `lag_exceeded`/`decode_error` eviction, one
thread per client so a slow client never stalls a fast one); and G3.4d the
`resume` classifier (`Last-Event-ID`/`since` decomposition + the intra-seq
skip — a mid-seq-group resume redelivers exactly the unseen records, with
in-window/behind/truncated tiers).  G3.5 (`events/stream.rs`) wires the
live `GET /v1/events/stream` endpoint: it hijacks the connection
(`tiny_http::into_writer`) rather than returning a `RouteOutcome`, reserves
a bounded stream slot (atomic admission, `503` over cap), and runs the
per-client dispatch on its own thread (the handler-pool worker returns
immediately); the single mux is started in `serve`; `Last-Event-ID`/`since`
resume + `Cache-Control: no-store`.  **The events (G3) track is complete
(G3.1–G3.5).**  The G4 hardening track is underway: G4.1 (rate limiting —
shipped early as G1.3) and G4.3 (`observability.rs` — a per-request
`X-Request-Id` correlation id propagated to the response header, the RFC
9457 `problem.instance`, and a structured per-request log line (the
log-based metrics surface, OQ-GW-10), redaction-tested to never log a
bearer token) and G4.4 (graceful shutdown — a `signal_hook` SIGTERM/SIGINT
trigger sets the shared shutdown flag; `serve` drains the handler pool
under a deadline, and the mux + every live SSE stream stop on the flag, the
streams emitting a clean `server_shutdown` close with no mid-record
truncation) and G4.5 (the dependency audit — the repo's first
`runtime/deny.toml` cargo-deny policy (locally-verified licence allow-list,
advisory/ban/source rules), a dedicated `ci-cargo-deny.yml`, and the
supply-chain review `docs/audits/gateway_dependency_audit.md`) and G4.7 (the
operator runbook `docs/gateway_runbook.md`) and G4.2 (native in-process HTTPS
— `src/http/tls.rs`: a rustls 0.23 (TLS 1.3, ring) front-end with optional
mTLS (`--tls-listen`/`--tls-cert`/`--tls-key`/`--mtls-client-ca`/
`--tls-max-connections`) running ALONGSIDE the plaintext `--listen` socket and
reusing the EXACT shared request core (`http::handler`) through a strict,
smuggling-proof HTTP/1.1 reader — Transfer-Encoding + ambiguous Content-Length
rejected, body read exactly, every length bounded; the workspace's rustls
0.23, NOT tiny_http's bundled rustls 0.20; no new crate in the graph;
ServerConfig built + socket bound at startup, fail-fast on a bad cert/key/CA;
two openssl-cert handshake tests drive a real rustls client end-to-end incl.
mTLS reject/accept).  **The core G4 hardening track is complete (G4.1–G4.7);**
the lone remaining G4 item is the deferred G4.6 throughput / high-concurrency
bench (the tiny_http SSE ceiling = OQ-GW-14).
Design invariants: reads use pure `SQLITE_OPEN_READ_ONLY`; auth is
fail-closed (no token file ⇒ every non-exempt request denied) + the token
file must not be world-readable; the submit path forwards client-signed
`SignedAction` bytes opaquely (no key custody); the SSE fan-out
multiplexes one upstream subscription; native TLS terminates rustls 0.23
(TLS 1.3) in-process alongside the plaintext socket — same request core (no
security divergence) + optional mTLS — or is terminated at a co-located edge.

### Rust host runtime (Workstream RH)

Plan: `docs/planning/rust_host_runtime_plan.md`

| Workstream | Crate | Status | Key surface |
|------------|-------|--------|-------------|
| RH-H | workspace root | Complete | CI harness, `knomosis-cli-common`, `knomosis-cross-stack` (.cxsf format) |
| RH-A.1 | `knomosis-verify-secp256k1` | Complete | ECDSA secp256k1 cdylib; 210-record .cxsf corpus |
| RH-A.2 | `knomosis-hash-keccak256` | Complete | Keccak-256 cdylib; 51-record .cxsf corpus |
| RH-B | `knomosis-l1-ingest` | Complete | L1 event watcher; hand-rolled ABI decoder; re-org tolerance; raw-TCP submitter with opt-in signer hints |
| RH-C | `knomosis-host` | Complete | TCP/TLS/Unix listener; `MockKernel` + `CommandKernel`; bounded queue; two-tier DRR fair scheduler (default-OFF `--scheduler drr`); `--persistent-connections` pipelined mode |
| RH-D | `knomosis-event-subscribe` | Complete | Log-tail reader; `SubprocessExtractor` → `knomosis extract-events`; bounded-lag subscriber eviction; event-type registry (tags 0..22) |
| RH-E.0 | `knomosis-storage` | Complete | `Storage` trait; `SqliteStorage` (WAL, bundled rusqlite); migration framework |
| RH-E.1 | `knomosis-indexer` | Complete | Per-(actor, resource) balance view; budget/pool views; two-pass dispatch; epoch resets |
| RH-F | `knomosis-bench` | Complete | Deterministic fixture; concurrent driver; histogram; JSON report + regression check; ~7.5k ops/sec observed |
| RH-G | `knomosis-faultproof-observer` | Complete | Game state machine; honest strategy; L1 watcher; EIP-1559 submitter; persistence; chaos suite; 50-trace cross-stack corpus |

Workspace conventions: `unsafe_code = "forbid"` default;
`clippy::pedantic`; no `tokio`; stable 1.83.

### Unified gas pool / budgets / AMM (Workstream GP)

Plan: `docs/planning/unified_gas_pool_plan.md`

| Sub-WU | Status | Key surface |
|--------|--------|-------------|
| GP.1 | Complete | `ActorBudget` + `EpochBudgetState` (`Authority/ActorBudget.lean`) |
| GP.2.1–2.3 | Complete | `Laws.depositWithFee`, `Laws.topUpActionBudget`; `Action` indices 19/20; Events 16/17/18 |
| GP.3.1–3.2 | Complete | `BudgetPolicy`; admission gate with five-round security hardening |
| GP.3.3 | Complete | Step-VM dispatcher for kinds 19/20; cross-stack corpus widened |
| GP.3.4 | Complete | Delegated `topUpActionBudgetFor` (index 21); default-deny consent |
| GP.4.1–4.2 | Complete | `DepositRecord` widening; bridge accounting-equation split |
| GP.5.1–5.5 | Complete | Solidity: ETH+BOLD fee-split deposits, cap audit gate, step-VM kind 21, BOLD circuit breaker + Liquity auto-trigger + TVL cap |
| GP.6.1–6.5 | Complete | Rust: GP-family encoder, budget admission gate, event-type registry, indexer budget/pool views, BOLD cross-stack corpus |
| GP.7.0–7.4 | Complete | Bridge-policy characterisation, reserved actors, `gasPoolPolicy`, inductive drain bound, genesis ratification + CLI |
| GP.8.5 | Complete (both legs) | Receipt-verified claim gate: Lean `ReceiptVerifiedClaim` (`l1GasReceiptVerifier` + `l1EthBoldRateOracle` opaques, `SequencerReimbursementVerified{,Bold}` witnesses, `receiptVerifiedClaimAdmissible` + `…Bold…` + `receiptGatedAdmissibleUnified`, the `min(cap, cost)` double-bounds + pure-strengthening theorems) + Rust `build_receipt_backed{,_bold}` / `is_{,bold_}receipt_backed_by`. OQ-GP-8b closed: BOLD leg via the floored ETH→BOLD conversion + the independent-observer receipt-fetch binding (`knomosis-l1-ingest::receipt_verifier`: tx-keyed canonical binding hash, `derive_gas_receipt`, `verify_{eth,bold}_claim_independently{,_fresh}` with observer-path no-reuse keyed on the canonical re-derived hash, confirmation-depth re-org gate, batch-keyed `RateOracle` for BOLD, fail-closed `0x`/EIP-658 receipt parsing) |
| GP.9.1 | Complete | `claimBudgetRefund` (index 22); step-VM kind 22; Rust encoder + host gate |
| GP.11.1–11.7 | Complete | L1 AMM scaffold, deposit seeding, constant-product swap, L2 `ammSwap` (index 23), `ammReserveActor` reservation, AMM reserve policy, cross-stack AMM corpus |
| GP.11.8 | Complete | AMM state-root commitment integration: BridgeState encoder/decoder extended with 5 AMM fields, EI.7.e injectivity proof updated, `bridgeState_commit_includes_ammState` + `bridgeState_commit_extends_v1_2` + encoding-factoring theorems, strict Bool decoder, Solidity step-VM ammSwap handler, 268-entry cross-stack corpus, 19 acceptance tests |
| GP.11.9 | Complete | Gas-cost benchmarks for the v1.3 L1 operations + round-trip exit legs: 21 isolated-mode (tx-exact, refund-netted) benchmarks with exact calldata breakdowns (`solidity/test/BenchmarkGasV1_3.t.sol`, `forge test --isolate` + `vm.snapshotGasLastCall` + `vm.snapshotValue`, OZ-faithful `MockBoldOz`), committed baseline (`test/BenchmarkGasV1_3.gas-baseline.json`), one-sided >5%-increase CI gate + set-drift + runbook-sync checks (`scripts/check_gas_baseline.py`), generated runbook §9.2 table (`scripts/generate_gas_runbook_table.py`), self-tested via `make snapshot-gas-selftest` |
| GP.11.10 | Complete | AMM disaster recovery (quad-surface): single-purpose 3-of-N reference multisig `KnomosisAmmDisasterRecoveryMultisig.sol` (constructor-enforced `MIN_DISABLE_THRESHOLD = 3`, atomic threshold-th-confirm execution, revocation, 7-day group-expiry; 100% line/branch coverage, 7-invariant stateful suite, 2 gas benchmarks, cap-gate widened to the 3 multisig governance constants) + `IKnomosisAmmDisasterRecovery`; `ammDisabled` committed to the state root (Lean `BridgeState` 9th field, EI.7.e 9-way injectivity, `bridgeState_commit_extends_v1_3` + `commitBridgeState_reflects_ammDisabled` + `commitExtendedState_reflects_ammDisabled` theorems); L2 reserve-reclamation law `Laws.reclaimAmmReserves` (frozen `Action` index 24, `Event.ammReservesReclaimed` 22, exact-sweep precondition, `IsConservative`/`LocalTo`/`FreezePreserving` instances, bridge-admissibility conjunct gating on `ammDisabled = true` + reserved actors, step-VM kind 24 tri-stack, Rust l1-ingest/event-subscribe/indexer/observer mirrors, `AmmDisabled` L1-event ingest); AMM-mirror step-invariance (`amm_mirrors_constant_over_admitted_trace`); 278-entry step-VM corpus; post-disable deposit+withdraw degraded-mode tests; operator runbook §10 (invocation conditions, firing procedure, L2 reclamation flow, recovery decision tree) |

### Ethereum integration (Workstreams A–G)

Plan: `docs/planning/ethereum_integration_plan.md`

All seven Lean-side workstreams complete.  Solidity surface:
11 contracts + 7 libraries in `solidity/`.  Cross-stack: F.1.x
equivalence corpus + SC.3 SMT cell-proof corpus + SVC step-VM
corpus (278 entries / 170 happy).

### Fault-proof migration (Workstream H)

Plans: `docs/planning/fault_proof_migration_plan.md`,
`docs/fault_proof_design.md`, `docs/fault_proof_runbook.md`

Complete (Lean + Rust).  State-commitment scheme, bisection game,
convergence / honesty / settlement theorem chain, SMT cell proofs
(SC.1–SC.3), step-VM coherence (SVC), observer daemon (RH-G).

### Fair queuing (Workstream FQ / GP.8)

Plan: `docs/planning/GP.8_SEQUENCER_INTEGRATION_PLAN.md`

Track A complete: two-tier DRR fair scheduler in `knomosis-host`,
signer-hint wire protocol (`PROTOCOL_VERSION 2`), persistent
pipelined connections.  Track B (v1 reimbursement claim) complete:
`knomosis-l1-ingest::sequencer_claim::SequencerClaim::build` (capped,
sequencer-only, `Zeroizing` pool key; `abi.md` §10.2.6).  GP.8.5 v2
receipt-verified claim core complete: `LegalKernel.Bridge.ReceiptVerifiedClaim`
(the `l1GasReceiptVerifier` opaque + `SequencerReimbursementVerified`
witness + `receiptVerifiedClaimAdmissible` gate; headline
`receiptVerifiedClaim_capped_and_backed` = `min(cap, L1 wei cost)` bound;
`…_implies_gasPoolPolicy` = pure strengthening of v1) mirrored by
`SequencerClaim::build_receipt_backed{,_bold}` /
`is_{,bold_}receipt_backed_by`.  **OQ-GP-8b closed:** the BOLD leg is
receipt-verified via the `l1EthBoldRateOracle` opaque +
`boldReceiptReimbursement` (floored ETH→BOLD conversion) + the
`receiptVerifiedBoldClaim_*` / `receiptGatedAdmissibleUnified` theorems,
and the independent-observer receipt-fetch binding
(`knomosis-l1-ingest::receipt_verifier`) re-derives the receipt from L1
(`eth_getTransactionReceipt` + a canonical binding hash) so a third party
attests the backing without trusting the claim builder.  Track C complete: the action-clock
budget-epoch config note (`gas_pool_runbook.md` §8.1) + the
`--epoch-duration-seconds`-absence regression test (`knomosis-host`
`config::tests::epoch_duration_seconds_flag_does_not_exist`).  Track D
claim/fair-queuing ops in `gas_pool_runbook.md` §8 / §11.  Remaining:
GP.10 final ratification (the two-reviewer pass; §15E is already updated
for the BOLD oracle).

### Audit remediation (Workstream AR)

Plan: `docs/planning/audit_remediation_plan.md`

Complete.  Key contributions: `signedActionDomain`, deployment-id
threading, snapshot chain-anchor checks, `Action`/`Event` tag
regression pins, `@[extern]` hash annotations, CODEOWNERS.  The lone
deferred finding (m-16, chain-level accounting) is now closed by
Workstream CA below.

### Chain-level bridge accounting (Workstream CA)

Plan: `docs/planning/chain_level_accounting_plan.md`

Complete.  Closes audit finding m-16 (GENESIS_PLAN §7.6.4 / §7.6.5).
`Bridge/Reachable.lean` defines `BridgeReachable` (reachability over the
production `apply_bridge_admissible_with` stepper, restricted to the
bridge-state-mutating actions); `Bridge/ChainAccounting.lean` proves
`bridge_chain_conserves` (`totalWithdrawn + TotalSupply =
totalDeposited` from genesis), `bridgeReachable_solvent`, and the
unconditional escrow identity `bridge_chain_accounting_equation`.  The
escrow term `bridge_accounting_equation_balanced_iff` left abstract is
now the concrete `bridgeEscrowBalance` (`Bridge/Accounting.lean`).

### Encoder injectivity (Workstream EI)

Plan: `docs/planning/encoder_injectivity_plan.md`

Complete (EI.0–EI.8).  Headline: `State.encode_injective` →
`commitExtendedState_subcommits_extensional_eq_under_collision_free`.

### Lex language (Workstream LX)

Plan: `docs/planning/lex_implementation_plan.md`

Complete (M1–M3).  Macro skeleton + synthesiser, 17 re-expressed
kernel laws, deployment manifests + governance.

### Actor-scoped policies (Workstream LP)

Plan: `docs/planning/actor_scoped_policies_plan.md`

Complete (Lean side).  Classification typeclasses: `LocalTo`,
`FreezePreserving`, `RegistryPreserving`.

**Active development history.**  Per-audit and per-WU completion
narratives live in git history (see `git log --grep="WU"` /
`git log --grep="audit"`), not in this file.

## Vulnerability reporting

Knomosis is research-stage software.  If you discover a logic bug in
the kernel module (e.g. a counterexample to `impl_noop_if_not_pre`,
or a state advance that bypasses the `if` in `step_impl`), open an
issue with the `kernel-soundness` label.  Such reports gate any
in-flight PR; the two-reviewer rule applies to the fix.

For non-kernel issues (laws, tooling, documentation), the standard
issue tracker workflow applies.

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
lake exe lex_lint                   # Lex registry + sidecar gate
lake exe lex_codegen --check        # Lex codegen-consistency gate
lake exe lex_diff <before> <after>  # Lex semantic-diff binary
lake exe lex_format <file>          # Lex pretty-printer
python3 scripts/regenerate_codemaps.py  # regenerate codemaps (CI gate)

# Runtime smoke test.
.lake/build/bin/knomosis info
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
cd solidity && make testnet-acceptance-dryrun # F.3 local fork dry-run

# Keccak-linked cross-stack verification (Lean <-> EVM byte-equivalence).
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
│   │                             ammSwap, dispute pipeline, local-policy laws)
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
│   ├── Bridge/                -- Workstreams A–D + GP: crypto adaptors, identity,
│   │                             bridge laws, withdrawal proofs, gas-pool policy,
│   │                             pool-drain bound, AMM math, AMM reserve policy,
│   │                             budget refund, accounting
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
│   └── verify_keccak_crossstack.sh -- keccak-linked cross-stack orchestration
├── .github/workflows/
│   ├── ci.yml                 -- Lean build + test + audits
│   ├── ci-rust.yml            -- Rust workspace gates (runtime/**)
│   ├── ci-solidity.yml        -- Solidity cap gate + forge gates (solidity/**)
│   └── ci-keccak-crossstack.yml -- Lean<->EVM keccak256 byte-equivalence
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
   scheme is EUF-CMA secure.
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
  | Lean kernel    | `lakefile.lean` `version` field                  |
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
| GP.11.6 | AMM reserve outflow restricted | `ammReservePolicy_permits_iff` | `Bridge/AmmReservePolicy.lean` |
| GP.11.8 | AMM state committed to bridge | `bridgeState_commit_includes_ammState` | `FaultProof/Commit.lean` |
| GP.11.8 | v1.2 backward compatibility | `bridgeState_commit_extends_v1_2` | `FaultProof/Commit.lean` |
| GP.11.8 | Encoding factoring | `bridgeState_encode_factored` | `FaultProof/Commit.lean` |
| GP.11.8 | AMM genesis suffix const | `bridgeState_amm_genesis_suffix_const` | `FaultProof/Commit.lean` |
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
| FQ/GP.8 | Fair queuing (knomosis-host) | Track A complete; Tracks B–D future |
| GP | Unified gas pool / budgets / AMM | In progress (GP.0–7.4, GP.9.1, GP.11.1–8 complete) |
| AR | Audit remediation | Complete |
| EI | Encoder injectivity | Complete |
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

**Build tag** (`kernelBuildTag` in `LegalKernel.lean`):
`"knomosis-step-vm-coherence"` (SVC).  `Test/Umbrella.lean`,
`Lex/Test/M2.lean`, and `Lex/Test/ExampleLex.lean` all pin this
value in regression tests, so any phase / milestone bump must
update the constant and every pinning test in the same PR.

**Test counts.**  `lake test` is the canonical Lean query; `cargo
test --workspace` is the Rust canonical query.  Approximate counts
at the current build tag:

| Surface | Tests | Suites | Canonical query |
|---------|-------|--------|-----------------|
| Lean | ~2 990 | ~149 | `lake test` |
| Rust | ~1 950 | across 11 crates | `cargo test --workspace` |
| Solidity | ~791 passed | 20+ forge suites | `cd solidity && forge test` |

Only monotonic growth is enforced — no global gate pins the count.

**Notable Lean suites** (selected; see `LegalKernel/Test/` for the
full catalogue):

- `authority-signed-budget` — GP.3.2 admission-gate theorems +
  five-round security hardening regression tests.
- `faultproof-stepvm-coherence` — 24-variant step-VM dispatcher
  byte-equivalence (kinds 0–23).
- `crosscheck-step-vm` — 268-entry cross-stack fixture corpus.
- `faultproof-smt` — SC.1 SMT cell-proof soundness.
- `encoding-injectivity` — EI.2–EI.8 injectivity ladder.
- `bridge-gas-pool-policy` — GP.7.2 gas-pool policy characterisation.
- `bridge-pool-drain-bound` — GP.7.3 inductive pool-drain bound.
- `bridge-amm-reserve-policy` — GP.11.6 AMM reserve policy.
- `crosscheck-amm-swap` — GP.11.7 tri-stack AMM fixture corpus.
- `faultproof-amm-commit` — GP.11.8 AMM state-root commitment integration.
- `deployments-gas-pool-example` — GP.7.4 end-to-end genesis ratification.

**Notable Rust crates by test count:**

| Crate | ~Tests | Role |
|-------|--------|------|
| `knomosis-host` | ~426 | Network adaptor + fair scheduler |
| `knomosis-l1-ingest` | ~341 | L1 event watcher + encoder |
| `knomosis-faultproof-observer` | ~312 | Off-chain bisection-game observer |
| `knomosis-event-subscribe` | ~219 | Event subscription server |
| `knomosis-indexer` | ~205 | SQLite event indexer |
| `knomosis-bench` | ~147 | Transfer-throughput benchmark |
| `knomosis-storage` | ~100 | Storage abstraction + SQLite |

**TCB audit.**  `#print axioms` on every kernel theorem returns a
subset of `[propext, Classical.choice, Quot.sound]`.  No custom
axioms exist.  `Verify`, `hashBytes`, and `l1FaultProofVerifier` are
`opaque`, not `axiom`.

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

### Rust host runtime (Workstream RH)

Plan: `docs/planning/rust_host_runtime_plan.md`

| Workstream | Crate | Status | Key surface |
|------------|-------|--------|-------------|
| RH-H | workspace root | Complete | CI harness, `knomosis-cli-common`, `knomosis-cross-stack` (.cxsf format) |
| RH-A.1 | `knomosis-verify-secp256k1` | Complete | ECDSA secp256k1 cdylib; 210-record .cxsf corpus |
| RH-A.2 | `knomosis-hash-keccak256` | Complete | Keccak-256 cdylib; 51-record .cxsf corpus |
| RH-B | `knomosis-l1-ingest` | Complete | L1 event watcher; hand-rolled ABI decoder; re-org tolerance; raw-TCP submitter with opt-in signer hints |
| RH-C | `knomosis-host` | Complete | TCP/TLS/Unix listener; `MockKernel` + `CommandKernel`; bounded queue; two-tier DRR fair scheduler (default-OFF `--scheduler drr`); `--persistent-connections` pipelined mode |
| RH-D | `knomosis-event-subscribe` | Complete | Log-tail reader; `SubprocessExtractor` → `knomosis extract-events`; bounded-lag subscriber eviction; event-type registry (tags 0..21) |
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
| GP.9.1 | Complete | `claimBudgetRefund` (index 22); step-VM kind 22; Rust encoder + host gate |
| GP.11.1–11.7 | Complete | L1 AMM scaffold, deposit seeding, constant-product swap, L2 `ammSwap` (index 23), `ammReserveActor` reservation, AMM reserve policy, cross-stack AMM corpus |
| GP.11.8 | Complete | AMM state-root commitment integration: BridgeState encoder/decoder extended with 5 AMM fields, EI.7.e injectivity proof updated, `bridgeState_commit_includes_ammState` + `bridgeState_commit_extends_v1_2` + encoding-factoring theorems, strict Bool decoder, Solidity step-VM ammSwap handler, 268-entry cross-stack corpus, 19 acceptance tests |

### Ethereum integration (Workstreams A–G)

Plan: `docs/planning/ethereum_integration_plan.md`

All seven Lean-side workstreams complete.  Solidity surface:
10 contracts + 6 libraries in `solidity/`.  Cross-stack: F.1.x
equivalence corpus + SC.3 SMT cell-proof corpus + SVC step-VM
corpus (268 entries / 164 happy).

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
pipelined connections.  Tracks B–D (reimbursement, config, runbook)
future work.

### Audit remediation (Workstream AR)

Plan: `docs/planning/audit_remediation_plan.md`

Complete.  Key contributions: `signedActionDomain`, deployment-id
threading, snapshot chain-anchor checks, `Action`/`Event` tag
regression pins, `@[extern]` hash annotations, CODEOWNERS.

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

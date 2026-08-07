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
Workstream H (fault-proof migration) complete (Lean + Rust RH-G),
including the terminal step's adjudication and the deduplicating
pre-root multiproof it folds.  Workstream SB (batched state-root
submission + the user-facing L2 AMM) complete: one L1 record per
batch `[prevEnd, end)` with a per-batch actions-root SMT, the game
anchored inside the batch, the terminal action authenticated by
inclusion proof (~239 gas of amortised L1 per action at B=1000);
`Laws.reserveSwap` (Action 25, Events 23/24) priced in-kernel by
`AmmMath` over the reserve actor's live balances, funded by the
deposit fee-split's seed leg under the L2-primary pool topology;
plus the R1/R3/R4 revert recovery and the R6 game-to-bridge revert
forwarding, fixing two pre-existing defects.  Workstream AX
(L1-AMM excision) complete: the embedded L1 AMM was excised
entirely (pre-deployment, so nothing was stranded) — the L2 pool
is the ONE venue, `Action` index 23 / `Event` tag 21 are permanent
holes, and the kill-switch family is re-pointed at the L2 pool
(`reserveSwap` admission requires `ammDisabled = false`).
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
lake exe api_stability_audit        # term-level API-pin gate
lake exe lex_lint                   # Lex registry + sidecar gate
lake exe lex_codegen --check        # Lex codegen-consistency gate
lake exe lex_codegen --canonical --check  # Lex canonical-manifest gate
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
cd solidity && make deploy-sepolia-dryrun     # unified full-suite deploy
                                              # (in-memory; emits the manifest)
cd solidity && make deploy-sepolia            # REAL Sepolia broadcast + Etherscan
                                              # verify (needs SEPOLIA_RPC_URL /
                                              # a signer [KNOMOSIS_DEPLOYER_ACCOUNT
                                              # keystore, or PRIVATE_KEY] /
                                              # ETHERSCAN_API_KEY);
                                              # non-bundling, no
                                              # --disable-code-size-limit; emits
                                              # deployments/sepolia.json.  See
                                              # docs/sepolia_deployment_runbook.md
cd solidity && make deploy-local              # full BOLD+AMM suite vs live anvil

# Bring up the L2 daemon stack against a Sepolia manifest + expose the gateway
# for the Licio BFF (docs/sepolia_deployment_runbook.md).
./scripts/knomosis_l2_sepolia_stack.sh

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

# F-1/F-2 release gate: build ONE knomosis with BOTH production adaptors
# linked and require hash-check AND verify-check to pass on that single
# binary (the both-adaptors check the two single-adaptor scripts above
# cannot give; run by the ci-release-gate.yml release workflow).
./scripts/verify_release_crypto.sh

# Quantitative economic-incentive simulation (IC-1..IC-6 envelope +
# self-asserting invariant checks; companion to docs/economic_incentive_analysis.md).
python3 scripts/economic_simulation.py

# Workstream RH (Rust host runtime) — see runtime/README.md.
# Toolchain pin: runtime/rust-toolchain.toml (stable 1.97).
cd runtime && cargo build --workspace --all-targets
cd runtime && cargo test --workspace
cd runtime && cargo clippy --workspace --all-targets -- -D warnings
cd runtime && cargo fmt --all -- --check

# Coverage-guided fuzzing of the untrusted-input boundaries — the
# knomosis-fuzz crate (runtime/fuzz/; see runtime/fuzz/README.md).  A
# SEPARATE workspace (excluded from the stable `runtime` workspace);
# libFuzzer needs nightly + the LLVM sanitizer runtime, so it rides the
# dedicated ci-fuzz.yml lane, NOT the --workspace gates above.  Its
# stable-toolchain counterpart is the never-panics proptest fuzz in the
# host / l1-ingest / indexer `tests/property.rs` (which DO ride --workspace).
rustup toolchain install nightly --component rust-src   # one-time
cargo install cargo-fuzz --locked                       # one-time (pin 0.13.2)
cd runtime && cargo +nightly fuzz list                  # host / l1-ingest / indexer / observer
cd runtime && cargo +nightly fuzz build                 # compile all targets (API-drift guard)
cd runtime && cargo +nightly fuzz run l1_ingest_decode_event -- -max_total_time=60

# Workstream GW (gateway) — synchronous HTTP/JSON + SSE service
# (runtime/knomosis-gateway/; contract docs/api/gateway.openapi.yaml).
# Its Rust gates ride the --workspace commands above; run/test directly:
cd runtime && cargo run -p knomosis-gateway -- --help
cd runtime && cargo test -p knomosis-gateway
# Read-path throughput / latency bench (manual; G4.6) — numbers vary by
# machine, so it is NOT a CI gate (its deterministic tests ride --workspace):
cd runtime && cargo run -p knomosis-gateway-bench -- --help
cd runtime && cargo run -p knomosis-gateway-bench -- \
  --actors 1000 --resources 2 --requests 10000 --workers 32 --report bench.json
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
  Textual, and its own docstring says so; the elaborator-level check
  is the axiom-footprint gate below, which sees any `sorry` however
  spelled because every one introduces `sorryAx`.
* **The axiom-footprint gate** (`LegalKernel/Test/AxiomFootprint.lean`)
  — enforces "No custom axioms (ABSOLUTE)" mechanically.
  `#assert_canonical_axioms` is a *command*, so it runs at
  elaboration time and a violation is a BUILD error caught by the
  existing `lake build`; there is no separate binary to invoke.  It
  collects each headline theorem's real axiom footprint and fails on
  anything outside `[propext, Classical.choice, Quot.sound]`.  Add a
  line for every theorem promoted to the type-level-properties table.
* `lake exe tcb_audit` — fails if a TCB-core module imports anything
  not on `tcb_allowlist.txt` or in `Tools.Common.tcbInternalImports`.
* `lake exe stub_audit` — catches placeholder-body stubs accompanied
  by red-flag docstring tokens.  Allowlist: `tools/stub_allowlist.txt`.
* `lake exe api_stability_audit` — fails on any test-module
  term-level API pin of the form `let _ := @theoremName` that lacks
  a full type ascription (an unascribed pin elaborates against
  *whatever* the theorem's current signature is, so it cannot catch
  a signature change — the one job a pin exists for).  The
  historical unascribed pins are frozen in
  `tools/api_stability_allowlist.txt`; the allowlist must never be
  extended — new pins state the expected type explicitly.
* `lake exe lex_lint` + `lake exe lex_codegen --check` +
  `lake exe lex_codegen --canonical --check` — enforce
  the Lex action-index registry's append-only discipline, the
  byte-stability of codegen-input sidecars, and the canonical
  manifest's consistency with the registry.
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
│   │                             reclaimAmmReserves, reserveSwap, dispute
│   │                             pipeline, local-policy laws) plus
│   │                             AmountBound (the shared credit ceiling)
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
│   │                             cell proofs, step-VM coherence,
│   │                             BoundsReachable (discharges CanonicalBounds)
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
│   ├── rust-toolchain.toml    --   pinned Rust channel (stable 1.97)
│   ├── knomosis-hash-fallback.c  --   AR.10 default fallback (lake-built)
│   ├── knomosis-amount/          --   256-bit accounting scalar (Amount)
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
│   ├── knomosis-gateway/         --   Workstream GW: HTTP/JSON + SSE service
│   ├── knomosis-gateway-bench/   --   GW read-path throughput/latency bench (G4.6)
│   ├── fuzz/                     --   cargo-fuzz harness (SEPARATE workspace,
│   │                                 excluded; nightly libFuzzer, ci-fuzz.yml)
│   └── tests/cross-stack/     --   shared fixture corpus (.cxsf files)
├── scripts/
│   ├── setup.sh               -- SHA-256-verified toolchain installer
│   ├── verify_keccak_crossstack.sh -- keccak-linked cross-stack orchestration
│   ├── verify_secp256k1_link.sh -- F-2 production-verifier link proof + SHA-256
│   ├── verify_keccak_link.sh  -- F-1/F-2 production keccak256-hash link proof + SHA-256
│   ├── verify_release_crypto.sh -- F-1/F-2 release gate: both adaptors in one binary
│   └── economic_simulation.py -- IC-1..IC-6 quantitative incentive harness
├── .github/workflows/
│   ├── ci.yml                 -- Lean build + test + audits
│   ├── ci-rust.yml            -- Rust workspace gates (runtime/**)
│   ├── ci-fuzz.yml            -- nightly libFuzzer gate (runtime/fuzz/**)
│   ├── ci-solidity.yml        -- Solidity cap gate + forge gates (solidity/**)
│   ├── ci-keccak-crossstack.yml -- Lean<->EVM keccak256 byte-equivalence
│   ├── ci-verify-secp256k1.yml -- F-2 secp256k1-verifier production-link proof
│   ├── ci-hash-keccak256-link.yml -- F-1/F-2 keccak256-hash production-link + SHA-256 pin
│   └── ci-release-gate.yml    -- F-1/F-2 release/deploy gate (version tag / release)
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

**Trust assumptions.**  Two non-Lean assumptions surface as ordinary
Lean declarations rather than axioms (so `#print axioms` stays at
exactly `propext`, `Classical.choice`, `Quot.sound`):

1. `Authority.Crypto.Verify` — the deployment-supplied signature
   scheme is EUF-CMA secure.  Surfaced as an `opaque` declaration.
   `@[extern "knomosis_verify_ecdsa"]` routes the compiled runtime
   call to the secp256k1 adaptor (fail-closed reject-all fallback for
   tests); the logical value stays opaque, so the trust assumption is
   preserved.
2. `Runtime.Hash.hashBytes` — the production hash function (BLAKE3
   via `@[extern]`; FNV-1a-64 fallback for tests) is
   collision-resistant.  This one is **not** opaque: `hashBytes` has a
   real Lean body and `hashBytes_size` proves every output is 32
   bytes.  The assumption is therefore carried where it is used, as
   the explicit theorem hypothesis `Bridge.CollisionFreeOn S hashBytes`
   — `hashBytes` is injective on the finite pre-image set `S` that the
   theorem itself hashes.

   The scoping is load-bearing, not cosmetic.  A global-injectivity
   predicate (`∀ b₁ b₂, h b₁ = h b₂ → b₁ = b₂`) is *refutable inside
   Lean* once `hashBytes_size` is available — `ByteArray` is infinite
   and the 32-byte arrays are not — so every theorem conditioned on it
   would be vacuously true.  `CollisionFreeOn` is satisfiable, and the
   witnesses are exhibited (`Bridge.collisionFreeOn_id`,
   `Bridge.exists_uniformOutputSize_collisionFreeOn_of_ne`) rather
   than assumed.

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
  | README banner  | `README.md` version badge URL + the `| Version |` table row |

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
| C-3 | Credits stay under the head's modulus | `AmountBounded` (a conjunct of every crediting `pre`) | `Laws/AmountBound.lean` |
| C-3 | ...inductively, over the whole state | `balancesBounded_apply_impl` | `FaultProof/BoundsReachable.lean` |
| C-3 | ...so `CanonicalBounds.base_amt` is discharged, not assumed | `canonicalBounds_base_amt_of_reachable` | `FaultProof/BoundsReachable.lean` |
| C-3 | Trace-length bound on the 8-byte heads | `expectsNonce_le_of_reachableIn` | `FaultProof/BoundsReachable.lean` |
| Phase 3 | Action compilation injective | `Action.compile_injective` | `Authority/Action.lean` |
| Phase 3 | Nonce uniqueness | `nonce_uniqueness` | `Authority/SignedAction.lean` |
| Phase 3 | Replay impossible | `replay_impossible` | `Authority/SignedAction.lean` |
| Phase 4 | CBE round-trip + injectivity | `*_roundtrip`, `*_encode_injective` | `Encoding/*.lean` |
| Phase 4 | Domain-separated sign inputs | `signInput_*` | `Encoding/SignInput.lean` |
| EI.2–7 | Encoder injectivity ladder | `*.encode_injective` | `Encoding/*Injective.lean` |
| EI.8 | Concat-commit extensional eq (retired root) | `commitExtendedStateConcat_subcommits_extensional_eq_under_collision_free` | `FaultProof/Commit.lean` |
| B-3 | SMT root injectivity (EI.8 replacement) | `smtRootListAux_perm_of_eq_under_collision_free` | `FaultProof/SmtInjective.lean` |
| B-3 | Published root determines every cell | `commitExtendedState_determines_cells` | `FaultProof/StateCellsInjective.lean` |
| B-3 | Cell update proof-independent | `smtUpdateRoot_proof_independent` | `FaultProof/SmtInjective.lean` |
| B-3 | Canonical path walks to the root | `canonicalSiblings_walks_to_root` | `FaultProof/SmtInjective.lean` |
| B-3 | Absent cells open against the root | `canonicalSiblings_verifies_absent` | `FaultProof/StateCellsInjective.lean` |
| B-3 | One write lands on the post-state root | `updateStateCellRoot_eq_commit_of_canonical` | `FaultProof/StateCellsInjective.lean` |
| B-3 | Off-cell agreement discharges the update | `dropKey_stateCellEntries_perm_of_agree_off` | `FaultProof/StateCellsInjective.lean` |
| B-3 | The root is order-independent | `smtRootListAux_perm` | `FaultProof/SmtInjective.lean` |
| B-3 | Production-faithful semantic core | `apply_bridge_admissible_with_budget_eq` | `FaultProof/ProductionApply.lean` |
| M | Merged walk = the reference root | `multiWalk_eq_smtRootListAux` | `FaultProof/MultiProof.lean` |
| M | One wire, two roots | `multiFold_eq_commit_post` / `..._pre` | `FaultProof/MultiProof.lean` |
| M | The wire is blind to the leaves | `multiSiblings_key_congr` | `FaultProof/MultiProof.lean` |
| M | ...and to entries off the frontier | `multiSiblings_congr` | `FaultProof/MultiProof.lean` |
| M | Adjacent divergences are distinct | `adjacent_div_ne` | `FaultProof/Frontier.lean` |
| M | The gap count is a closed form | `gapCountClosed` | `FaultProof/Frontier.lean` |
| M | An alias cannot fork the plan | `plannedBalances_alias_consistent` | `FaultProof/Terminate.lean` |
| M | Honest fold = the published post root | `stepMultiFold_eq_commit_post` | `FaultProof/Terminate.lean` |
| M | Derived value = the post-state's | `derivedCellValue_correct` | `FaultProof/Terminate.lean` |
| M | The bundle reads back the state | `bundleValueAt_stepMultiBundle` | `FaultProof/Terminate.lean` |
| M | The bundle plans what the state plans | `plannedBalances_stepMultiBundle` | `FaultProof/Terminate.lean` |
| M | Path order is a strict total order | `pathLess_trans`, `pathLess_total` | `FaultProof/Frontier.lean` |
| M | Every frontier is strictly ascending | `pathSorted_frontierOf` | `FaultProof/Frontier.lean` |
| M | Cell keys always diverge | `keysSeparated_cellTags` | `FaultProof/Frontier.lean` |
| M | `ByteArray` `==` decides `=` | `instLawfulBEqByteArray` | `Encoding/CBOR.lean` |
| M | The wire round-trips | `expandMultiProof_buildMultiProof` | `FaultProof/MultiProof.lean` |
| M | An honest wire passes the shape check | `isWellFormedFor_buildMultiProof` | `FaultProof/MultiProof.lean` |
| M | An empty bundle is refused | `frontierShapeOk_nil_of_cons` | `FaultProof/Frontier.lean` |
| M | Path order is a strict total order | `pathLess_trans` / `pathLess_total` | `FaultProof/Frontier.lean` |
| M | The frontier is strictly ascending | `pathSorted_frontierOf` | `FaultProof/Frontier.lean` |
| M | ...hence its keys are distinct | `frontierOf_keys_nodup` | `FaultProof/Frontier.lean` |
| M | The honest bundle reads the state | `bundleValueAt_stepMultiBundle` | `FaultProof/Terminate.lean` |
| B-3 | Root observes exactly the cells | `commitExtendedState_eq_of_cells_agree` | `FaultProof/StateCellsInjective.lean` |
| B-3 | `setCell` round-trips the reader | `getCellValue_setCell_getCellValue` | `FaultProof/CellWrites.lean` |
| B-3 | A step's write set is complete | `writeSetComplete_productionApplyBudget` | `FaultProof/StepWriteSets.lean` |
| B-3 | The canonical opening verifies | `verifyStateCellProof_buildStateCellProof` | `FaultProof/CellWrites.lean` |
| B-3 | Writing one cell leaves the rest | `getCellValue_setCell_ne` | `FaultProof/CellStore.lean` |
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
| GP.11.8 | Mirror state committed to bridge | `bridgeState_commit_includes_mirrorState` | `FaultProof/Commit.lean` |
| GP.11.8 | v1.2 backward compatibility | `bridgeState_commit_extends_v1_2` | `FaultProof/Commit.lean` |
| GP.11.8 | Encoding factoring | `bridgeState_encode_factored` | `FaultProof/Commit.lean` |
| GP.11.8 | Mirror genesis suffix const | `bridgeState_mirror_genesis_suffix_const` | `FaultProof/Commit.lean` |
| CA | Chain bridge conservation | `bridge_chain_conserves` | `Bridge/ChainAccounting.lean` |
| CA | Chain bridge solvency | `bridgeReachable_solvent` | `Bridge/ChainAccounting.lean` |
| CA | §7.6.4 escrow identity (unconditional) | `bridge_chain_accounting_equation` | `Bridge/ChainAccounting.lean` |
| H | Bisection convergence | `bisection_converges_after_enough_rounds` | `FaultProof/Convergence.lean` |
| H | Honest challenger wins | `honest_challenger_wins_against_invalid_state_root` | `FaultProof/Settlement.lean` |
| SB | Terminate settles only authenticated actions | `terminate_ok_requires_authentication` | `FaultProof/Settlement.lean` |
| SB | Anchored challenger wins (committed spelling) | `anchored_challenger_wins` | `FaultProof/Settlement.lean` |
| F-A | Terminate's signature gate (model) | `signatureAdmissible` | `FaultProof/Game.lean` |
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
| H | Fault-proof migration | **Complete.**  The terminal step authenticates its action against the log-entry chain AND adjudicates the state transition: `terminateOnSingleStep` calls `executeStepToRootMulti`, which returns a state ROOT computed by folding the step's derived cell writes into the pre-root from a deduplicating pre-root multiproof.  Both the bespoke `stepVMHash` recipe and the chained fold that replaced it are retired.  See the Workstream H section below |
| RH-H–G | Rust host runtime (11 workstreams) | Complete |
| SB | Batched submission + user-facing L2 AMM | **Complete** (SB.0–SB.12, v0.14.0).  One L1 record per batch `[prevEnd, end)`: structural prev-hash (R5), one chain-link fold per batch over the batch's actions-root SMT (R8; leaf binds the 65-byte signature, R7), revert recovery (R1/R3/R4), game anchored at the batch start (R2), terminal action authenticated by inclusion proof, settlement forwarded game→V2→bridge (R6).  Measured ~239 gas of amortised L1 per action at B=1000 (`gas_pool_runbook.md` §9.5).  `Laws.reserveSwap` (Action 25; Events 23/24) is the user-signed L2 swap priced in-kernel over the reserve actor's live balances, `user = signer` bound at the AuthorityPolicy; the deposit fee-split's seed leg is credited on L2 (`depositWithFee` gained the appended `seedAmount`); the embedded L1 AMM was subsequently EXCISED entirely (Workstream AX below), so the L2 pool is the ONE venue; `knomosis-l1-ingest` materialises deposits opt-in (`--materialise-deposits`, content-derived deposit ids).  The Lean game-model actions-root anchor follow-up is closed (audit-22 MAJOR closed at the model level: `GameState.actionsRoot` + the `actionNotInBatch` terminate guard + `terminate_ok_requires_authentication` + `anchored_challenger_wins`, amendment 1.34); on-chain signature verification at terminate is BUILT on the L1 side (Workstream F-A: `SignInput.sol` rebuilds the §8.8.5 digest, `Secp256k1.sol` resolves the signer's registered key from a registry-cell opening against the pre-root, `ecrecover` must match, and an invalid signature adjudicates as the no-op — the Lean game-model mirror is BUILT too — `applyTransitionWith` carries the verifier, the terminate arm opens the signer's registry cell against the pre-root, and an unauthorised entry adjudicates as the no-op, so F-A is complete on both stacks); the L1→L2 swap-mirror ingest is a deliberate non-goal.  See GENESIS_PLAN §15E.12 + amendments 1.33/1.34/1.35/1.36 |
| AX | L1-AMM excision (one-AMM topology) | **Complete.**  The embedded L1 AMM was excised BEFORE any deployment existed (zero contracts live, no liquidity stranded): `KnomosisBridge.ammSwap`, the `ammReserveEth`/`ammReserveBold` books and their two `BridgeState` commitment segments (EI.7.e is 7-way again), the L2 bridge-attested mirror `Laws.ammSwap`, and every step-VM / Rust arm are gone.  Frozen `Action` index 23 and `Event` tag 21 are PERMANENT HOLES — every decoder on all three stacks refuses them like never-assigned tags, `StepWrites.isAdjudicable(23) = false`, and they must never be reused.  The kill-switch family survives re-pointed at the L2 pool: `emergencyDisableAmm` flips the committed `ammDisabled` flag only (`AmmDisabled(uint256)`), the reserveSwap admission gate requires `ammDisabled = false` (`reserveSwap_inadmissible_while_amm_disabled`), and `reclaimAmmReserves` (24) remains the post-disable sweep.  `ammReservePolicy` is deny-all on the reserve key's own signatures; the reserve moves only as the user swap's counterparty or via the bridge-signed sweep |
| SC.1–3 | SMT cell proofs (3 workstreams) | Complete |
| SVC | L1 step-VM coherence | Complete |
| FQ/GP.8 | Fair queuing (knomosis-host) | Tracks A + B + C complete; D documented; GP.8.5 v2 receipt-verified claim **built** — both legs (Lean gate + theorems, Rust builders/verifiers) — and OQ-GP-8b closed (BOLD-leg ETH→BOLD oracle + independent-observer receipt-fetch), but **not yet wired into a production admission path**: `receiptGatedAdmissibleUnified` has no non-test caller and `ConsumedReceipts` has no home in `BridgeState`, so the `min(cap, L1 wei cost)` bound is proved and available, not enforced.  Wiring it is workstream F1 (`docs/audits/19-findings-and-followups.md`) |
| GP | Unified gas pool / budgets / AMM | In progress (GP.0–7.4, GP.8 Tracks A–C, GP.8.5 v2 both legs incl. OQ-GP-8b, GP.9.1, GP.11.1–10 complete; GP.10 final ratification remaining — now gated only on the two-reviewer pass, see `unified_gas_pool_plan.md` §GP.10) |
| AR | Audit remediation | Complete (all findings closed; m-16 via CA) |
| CA | Chain-level bridge accounting | Complete (closes m-16; §7.6.4 / §7.6.5) |
| EI | Encoder injectivity | Complete |
| GW | Gateway (HTTP/JSON + SSE) | In progress (read-only + submit + events tracks complete; G4 hardening complete (G4.1–G4.7).  **The gateway owns its WHOLE HTTP stack** — the transport-neutral `http::conn` handler over the workspace rustls 0.23, **no `tiny_http`**: one thread per connection on both the plaintext and native-TLS listeners, each with a socket-owned timeout + a per-request read deadline; this closed OQ-GW-14 (concurrent-SSE ceiling = `--sse-max-streams`) and OQ-GW-15 (the `--sse-write-timeout-ms` write deadline now honoured on both transports).  The §9.2 surface is complete incl. `--mtls-crl` (mTLS revocation), `--cors-origin` (+ OPTIONS preflight), `--log-format`, `--dev` (in-process mock upstreams), and `--upstream-subscriptions`.  G3.2c cross-stack pin shipped: the Lean `Encodable Event` (`Encoding/Event.lean`) is the byte authority, pinned byte-for-byte by `knomosis-indexer` and lifted to the gateway §6.2 envelope by `knomosis-gateway/tests/cross_stack_lean_event.rs` (every frozen tag 0..=24).  Only G2.1c submit pipelining deferred — `gateway_integration_plan.md`) |
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
the `lakefile.lean` `version` field (currently `0.14.0`) — the single
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
| Lean | ~3 235 | 172 | `lake test` |
| Rust | ~2 483 | across 13 crates | `cargo test --workspace` |
| Solidity | ~909 passed | 64 forge suites | `cd solidity && forge test` |

(The Solidity count dropped from ~997 with the Workstream AX
excision — the six L1-AMM swap suites and the kind-23 corpus rows
went with the venue they exercised.)

`forge test` runs **909 passed / 0 failed / 0 skipped** — the
Lean<->EVM byte-equivalence corpus included.  It did not always: the
`solidity/test/CrossCheck/` suites gated themselves on the fixture
header's `isKeccak256Linked` flag and the committed fixtures carried
the FNV-1a-64 fallback, so a bare `forge test` reported green having
compared nothing.  Two changes closed that, and both are enforced
rather than conventional:

  * the hash-dependent corpora are keccak artifacts by construction —
    `writeHashDependentFixture` /`writeHashDependentGoldens`
    (`LegalKernel/Test/Bridge/CrossCheck/Framework.lean`, `Goldens.lean`)
    refuse to author one on a fallback-hash build, and the consuming
    suites call `_requireKeccakLinked` instead of skipping;
  * `gas_limit` is set in `[profile.default]`
    (`solidity/foundry.toml`).  `StepVM.t.sol`'s 278-entry replay needs
    well past foundry's ~1.07e9 default and failed `EvmError: OutOfGas`
    under it, so only `verify_keccak_crossstack.sh` — which passes
    `--gas-limit` — could ever run it.

`./scripts/verify_keccak_crossstack.sh` (the
`ci-keccak-crossstack.yml` lane) remains the belt-and-braces lane and
reports the same 909 / 0 / 0.  It is not redundant: a bare `lake test`
runs on the FALLBACK hash, where the hash-dependent Lean cross-stack
assertions report `SKIPPED` rather than comparing anything.  Under the
keccak lane that count is **zero** — every corpus is checked against
real keccak256 on both sides.

Only monotonic growth is enforced — no global gate pins the count.

**Notable Lean suites** (selected; see `LegalKernel/Test/` for the
full catalogue):

- `authority-signed-budget` — GP.3.2 admission-gate theorems +
  five-round security hardening regression tests.
- `axiom-footprint` — the presence marker for the build-time
  "No custom axioms (ABSOLUTE)" gate.  The gate itself is
  `#assert_canonical_axioms` in
  `LegalKernel/Test/AxiomFootprint.lean` and has already run by the
  time the suite executes; the case exists so a `lake test`
  transcript records that the check is present, since a silent gate
  and an absent one look identical in the log.
- `encoding-kernelstep` — the `CellTag` CBE codec, swept over every
  constructor off an arity-pinned list rather than a sample.  It
  exists because `CellTag.encode` emitted tags 0..14 while
  `CellTag.decode` handled 0..6, and nothing noticed: the module's
  only theorems were `*_encode_deterministic`
  (`t₁ = t₂ → encode t₁ = encode t₂`, true of every function), and
  no test called the decoder.  Carries the two negative controls
  that stop the sweep passing vacuously — an unknown tag must be
  refused, and no two constructors may share an encoding.
- `faultproof-terminate` — the openings-only verifier
  (`verifierPostRootMulti`) against the sequencer's fold on nineteen
  probes, plus the forgeries it must refuse: a forged pre-value, a wire
  short by one sibling, a mask bit set past the last gap, a bundle
  whose cells are not the step's, the two bulk variants.  And the one
  case the multiproof ACCEPTS that its chained predecessor refused: a
  permuted bundle reaches the identical root.  The calldata claim is
  measured here rather than asserted — 13 312 → 3 596 bytes over the
  probe set.
- `faultproof-frontier` / `faultproof-multiproof` — the merged walk's
  own suites: the same-cell case first (a duplicate is not
  representable), the gap-count closed form, `multiWalk` against the
  reference root, and the wire's exact shape.
- `crosscheck-smt-multi-proof` — the non-degenerate cross-stack pin for
  the MERGED walk (`smt_multi_proof.json`): six probes covering merges
  at two depths, an absent cell written, a present cell swept to
  absent, and one opening every live cell so the gap mask is all
  zeros.  The `m = 1` transitive pin exercises no merge, which is what
  this corpus exists for.
- `faultproof-smt-injective` — B-3 SMT root injectivity, cell
  updates, canonical-path coherence; includes the negative control
  showing a duplicate-keyed bucket hashes as if it were empty.
- `faultproof-cell-writes` — the write-list machinery: a later write
  to the same cell wins (the self-transfer shape), a write moves the
  published root and restoring the value restores it, each chain link
  opens against its OWN state (with the stale pre-state path shown to
  differ), and the negative control — an INCOMPLETE write set does not
  reproduce the post-state, so `WriteSetComplete` is a hypothesis
  something actually exercises.
- `faultproof-write-sets` — `WriteSetComplete` per action and the
  honest sequencer's bundle: the fold lands on the published root for
  every variant shape including `withdraw`'s state-keyed pending cell
  and both bulk variants; a bulk write set covers every cell the
  advance moves and over-declares none; and a FORGED post-value does
  not reach the honest root.
- `faultproof-substep` — the bulk decomposition, and the pin that a
  bulk step's post-state is a function of the pre-state ROOT: a live
  zero-balance entry is not a recipient (it has no leaf, so crediting
  it would let two root-identical pre-states reach different
  post-roots), the PRECONDITION is root-determined for the same reason
  (`BulkBounded` counts the recipient list, so under the retired rule a
  state carrying 300 swept-to-zero actors sat over the cap while its
  twin sat under it — one advances, one no-ops), both bulk laws agree
  on a state holding one, and — the negative control — the retired rule
  is rebuilt in the test and shown to fork the post-root on the same
  fixture pair, so nothing above passes vacuously.  Carries the closed
  form of finding C-3, which this suite recorded as an open obligation
  until v0.13.0: the `2^128` pair that used to share a root while
  reaching different post-roots is now root-DISTINCT, and the residual
  collision — any fixed-width encoder aliases at its own modulus — is
  unreachable rather than merely wider, since `Laws.AmountBounded` is
  exactly `< Laws.maxAmount` and so excludes precisely the first
  colliding value.
- `faultproof-bounds-reachable` — the C-3 discharge: the amount ceiling
  is exhibited as a real constraint (a state AT it is representable and
  unbounded) before anything is proved about it, then the laws are shown
  refusing to reach one — a crossing credit is a NO-OP, not a truncated
  write.  Includes the self-transfer corner that a conjunct stated over
  the pre-state would wrongly refuse.
- `events-extract` — per-action event emission, including the bulk-law
  path, which had no coverage at all until `Events.affectedActors` was
  found to be a fourth spelling of the recipient rule.  Its three cases
  build the post-state by APPLYING the kernel rather than by hand, so
  the events are checked against what the law did rather than against a
  fixture that agrees by construction.
- `faultproof-state-cells-injective` — cell determination, the
  well-formedness side conditions checked on a real state, and the
  write algebra: a single write lands on the post-state's published
  root (both leaf branches), the ordered multi-write fold lands on the
  last state's root, and a stale opening replayed after an earlier
  write is rejected.
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
browser-facing BFF.  Originally built on the vetted sync crate `tiny_http`
(G1.0), it now owns its **own** HTTP stack (the G4.2/G4.6 unification — see
below).  **Complete:** G0.1–G0.3 (contract + OpenAPI-lint gate),
G1.0 (HTTP-layer spike), G1.1 (crate scaffold — `/healthz`),
G1.6a (the `knomosis-storage` read-only open path
+ the DEFERRED budget-read fix), G1.2 (the parse→dispatch→write HTTP
foundation + routing surface), and the read endpoints G1.6b (balances)
+ G1.7 (budget + pools — `GET /v1/actors/{id}/budget` and
`GET /v1/pools/{pool}?resource={0|1}`, with a `--gas-pool-actor` `net`
echo), G1.8 (the typed `/v1/info` — admission stage + wire protocol
versions + indexer cursor/schema + budget-policy echo + the L2 chain id
(`l2ChainId`, `--l2-chain-id`) — and `/readyz`
indexer + upstream TCP probes), G1.4 (the fail-closed
`subtle::ConstantTimeEq` bearer-token gate, applied before routing;
`/healthz` + `/readyz` + the public wallet-discovery `/rpc` shim
(`eth_chainId`/`net_version`/`eth_blockNumber` for a browser wallet's
Add-Network) exempt), G1.9 (the read-path integration
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
`Corrupt` on a known-tag decode failure; the G3.2c cross-stack pin is
**shipped** — see the events-track summary below), and G3.3 (the
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
in-window/behind/truncated tiers).  G3.5 (`events/stream.rs`) is the live
`GET /v1/events/stream` streaming core: the `http::conn` handler hijacks the
connection (handing the socket writer to the per-client dispatch on its own
thread) rather than returning a `RouteOutcome`, reserving a bounded stream slot
(atomic admission, `503` over cap); the mux(es) are started in `serve`;
`Last-Event-ID`/`since` resume + `Cache-Control: no-store`.  **The events (G3)
track is complete (G3.1–G3.5).**  The G4 hardening track is complete: G4.1 (rate
limiting — shipped early as G1.3); G4.3 (`observability.rs` — a per-request
`X-Request-Id` correlation id propagated to the response header, the RFC
9457 `problem.instance`, and a structured per-request log line (the
log-based metrics surface, OQ-GW-10), redaction-tested to never log a
bearer token); G4.4 (graceful shutdown — a `signal_hook` SIGTERM/SIGINT
trigger sets the shared shutdown flag; `serve` drains the in-flight
connections under a deadline via the shared `active_connections` gauge, and
the mux + every live SSE stream stop on the flag, the streams emitting a clean
`server_shutdown` close with no mid-record truncation); G4.5 (the dependency
audit — the repo's first `runtime/deny.toml` cargo-deny policy
(locally-verified licence allow-list, advisory/ban/source rules), a dedicated
`ci-cargo-deny.yml`, and the supply-chain review
`docs/audits/gateway_dependency_audit.md`); G4.7 (the operator runbook
`docs/gateway_runbook.md`); and G4.2 (native in-process HTTPS + the
own-HTTP-stack unification — `src/http/{conn,plain,tls}.rs`: a rustls 0.23
(TLS 1.3, ring) front-end with optional mTLS + CRL revocation
(`--tls-listen`/`--tls-cert`/`--tls-key`/`--mtls-client-ca`/`--mtls-crl`/
`--tls-max-connections`) running ALONGSIDE the plaintext `--listen` socket and
sharing the EXACT transport-neutral connection handler (`http::conn`) + request
core (`http::handler`) — a strict, smuggling-proof HTTP/1.1 reader
(Transfer-Encoding + ambiguous Content-Length rejected, body read exactly,
every length bounded), one thread per connection with a socket-owned
read/write timeout + a per-request read deadline; the workspace's rustls 0.23,
**no `tiny_http`** anywhere; `ServerConfig` built + socket bound at startup,
fail-fast on a bad cert/key/CA; SIGHUP hot-reload; openssl-cert handshake tests
drive a real rustls client end-to-end incl. mTLS reject/accept/**revoke**).
G4.6 shipped the `knomosis-gateway-bench` crate — a read-path throughput/latency
harness (seeds a read-only indexer fixture, drives a real `spawn_plain_listener`
listener with concurrent raw-HTTP clients, reports throughput + a
reused-`knomosis-bench` histogram latency summary as a human table + JSON, with
`--baseline` regression detection; a manual tool, not a CI gate).  The
own-stack unification closed **OQ-GW-14** (concurrent-SSE ceiling =
`--sse-max-streams`) and **OQ-GW-15** (`--sse-write-timeout-ms` honoured on
both transports), and completed the §9.2 surface: `--cors-origin` (+ OPTIONS
preflight, `http/cors.rs`), `--log-format` (`http`-installed JSON/text
subscriber, `logging.rs`), `--dev` (in-process mock upstreams, `dev.rs`), and
`--upstream-subscriptions` (N shared subs feeding the single `(seq,index)`-dedup
ring).  The G3.2c cross-stack pin is **shipped**: the Lean `Encodable Event`
(`Encoding/Event.lean`) is the byte authority, pinned byte-for-byte by
`knomosis-indexer` and lifted to the gateway §6.2 envelope by
`knomosis-gateway/tests/cross_stack_lean_event.rs` (every frozen tag 0..=24).
The only remaining gateway item is the G2.1c submit pipelining (modest
optimisation).
Design invariants: the gateway owns its whole HTTP stack (thread per
connection on both transports, no `tiny_http`); reads use pure
`SQLITE_OPEN_READ_ONLY`; auth is fail-closed (no token file ⇒ every non-exempt
request denied) + the token file must not be world-readable; the submit path
forwards client-signed `SignedAction` bytes opaquely (no key custody); the SSE
fan-out multiplexes `--upstream-subscriptions` shared subscriptions (default 1)
into the single `(seq,index)`-dedup ring, its tunables (ring / streams / lag /
heartbeat / staleness / write-timeout) CLI-configurable via `--sse-*` (the lag
validated below the ring capacity), honoured identically on both stream paths;
browser CORS is off unless `--cors-origin` is set (then the OPTIONS preflight is
answered before auth and every response is decorated); `--dev` stands up
in-process mock upstreams for BFF iteration with no full stack; native TLS
terminates rustls 0.23 (TLS 1.3) in-process alongside the plaintext socket —
same connection handler + request core (no security divergence) + optional mTLS
(with `--mtls-crl` revocation), the certificate hot-reloaded on SIGHUP (zero
downtime) — or is terminated at a co-located edge.

### Rust host runtime (Workstream RH)

Plan: `docs/planning/rust_host_runtime_plan.md`

| Workstream | Crate | Status | Key surface |
|------------|-------|--------|-------------|
| RH-H | workspace root | Complete | CI harness, `knomosis-cli-common`, `knomosis-cross-stack` (.cxsf format) |
| RH-A.1 | `knomosis-verify-secp256k1` | Complete | ECDSA secp256k1 cdylib; 210-record .cxsf corpus |
| RH-A.2 | `knomosis-hash-keccak256` | Complete | Keccak-256 cdylib; 51-record .cxsf corpus |
| RH-B | `knomosis-l1-ingest` | Complete | L1 event watcher; hand-rolled ABI decoder; re-org tolerance; raw-TCP submitter with opt-in signer hints |
| RH-C | `knomosis-host` | Complete | TCP/TLS/Unix listener; `MockKernel` + `CommandKernel`; bounded queue; two-tier DRR fair scheduler (default-OFF `--scheduler drr`); `--persistent-connections` pipelined mode |
| RH-D | `knomosis-event-subscribe` | Complete | Log-tail reader; `SubprocessExtractor` → `knomosis extract-events`; bounded-lag subscriber eviction; event-type registry (tags 0..24) |
| RH-E.0 | `knomosis-storage` | Complete | `Storage` trait; `SqliteStorage` (WAL, bundled rusqlite); migration framework |
| RH-E.1 | `knomosis-indexer` | Complete | Per-(actor, resource) balance view; budget/pool views; two-pass dispatch; epoch resets |
| RH-F | `knomosis-bench` | Complete | Deterministic fixture; concurrent driver; histogram; JSON report + regression check; ~7.5k ops/sec observed |
| RH-G | `knomosis-faultproof-observer` | Complete | Game state machine; honest strategy; L1 watcher; EIP-1559 submitter; persistence; chaos suite; 50-trace cross-stack corpus |

Workspace conventions: `unsafe_code = "forbid"` default;
`clippy::pedantic`; no `tokio`; stable 1.97.

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
| GP.8.5 | Built, not wired (both legs) | Receipt-verified claim gate: Lean `ReceiptVerifiedClaim` (`l1GasReceiptVerifier` + `l1EthBoldRateOracle` opaques, `SequencerReimbursementVerified{,Bold}` witnesses, `receiptVerifiedClaimAdmissible` + `…Bold…` + `receiptGatedAdmissibleUnified`, the `min(cap, cost)` double-bounds + pure-strengthening theorems) + Rust `build_receipt_backed{,_bold}` / `is_{,bold_}receipt_backed_by`. OQ-GP-8b closed: BOLD leg via the floored ETH→BOLD conversion + the independent-observer receipt-fetch binding (`knomosis-l1-ingest::receipt_verifier`: tx-keyed canonical binding hash, `derive_gas_receipt`, `verify_{eth,bold}_claim_independently{,_fresh}` with observer-path no-reuse keyed on the canonical re-derived hash, confirmation-depth re-org gate, batch-keyed `RateOracle` for BOLD, fail-closed `0x`/EIP-658 receipt parsing) |
| GP.9.1 | Complete | `claimBudgetRefund` (index 22); step-VM kind 22; Rust encoder + host gate |
| GP.11.1–11.7 | Complete (L1 venue since EXCISED) | Deposit seed split + `ammSeedRatioBps` cap, `ammReserveActor` reservation, `AmmMath`, AMM reserve policy, `amm_getamountout` corpus.  The embedded L1 swap venue and its L2 `ammSwap` mirror (index 23) were excised under the one-AMM L2-primary topology — index 23 / event tag 21 are permanent holes |
| GP.11.8 | Complete (reserve books since EXCISED) | Mirror state-root commitment: BridgeState carries the three BOLD mirror fields (the two `ammReserve*` book segments left with the L1 venue — seven segments total), EI.7.e injectivity, `bridgeState_commit_includes_mirrorState` + `bridgeState_commit_extends_v1_2` + encoding-factoring theorems, strict Bool decoder |
| GP.11.9 | Complete | Gas-cost benchmarks for the v1.3 L1 operations + round-trip exit legs: 21 isolated-mode (tx-exact, refund-netted) benchmarks with exact calldata breakdowns (`solidity/test/BenchmarkGasV1_3.t.sol`, `forge test --isolate` + `vm.snapshotGasLastCall` + `vm.snapshotValue`, OZ-faithful `MockBoldOz`), committed baseline (`test/BenchmarkGasV1_3.gas-baseline.json`), one-sided >5%-increase CI gate + set-drift + runbook-sync checks (`scripts/check_gas_baseline.py`), generated runbook §9.2 table (`scripts/generate_gas_runbook_table.py`), self-tested via `make snapshot-gas-selftest` |
| GP.11.10 | Complete | AMM disaster recovery (quad-surface): single-purpose 3-of-N reference multisig `KnomosisAmmDisasterRecoveryMultisig.sol` (constructor-enforced `MIN_DISABLE_THRESHOLD = 3`, atomic threshold-th-confirm execution, revocation, 7-day group-expiry; 100% line/branch coverage, 7-invariant stateful suite, 2 gas benchmarks, cap-gate widened to the 3 multisig governance constants) + `IKnomosisAmmDisasterRecovery`; `ammDisabled` committed to the state root (Lean `BridgeState` 7th field post-excision, EI.7.e 7-way injectivity, `commitBridgeState_reflects_ammDisabled` + `commitExtendedState_reflects_ammDisabled` theorems); L2 reserve-reclamation law `Laws.reclaimAmmReserves` (frozen `Action` index 24, `Event.ammReservesReclaimed` 22, exact-sweep precondition, `IsConservative`/`LocalTo`/`FreezePreserving` instances, bridge-admissibility conjunct gating on `ammDisabled = true` + reserved actors, step-VM kind 24 tri-stack, Rust l1-ingest/event-subscribe/indexer/observer mirrors, `AmmDisabled(uint256)` L1-event ingest); mirror step-invariance (`amm_mirrors_constant_over_admitted_trace`) and the excision's new admission gate — `reserveSwap` requires `ammDisabled = false` (`reserveSwap_inadmissible_while_amm_disabled`); 278-entry step-VM corpus; post-disable deposit+withdraw degraded-mode tests; operator runbook §10 (invocation conditions, firing procedure, L2 reclamation flow, recovery decision tree) |

### Ethereum integration (Workstreams A–G)

Plan: `docs/planning/ethereum_integration_plan.md`

All seven Lean-side workstreams complete.  Solidity surface:
11 contracts + 7 libraries in `solidity/`.  Cross-stack: F.1.x
equivalence corpus + SC.3 SMT cell-proof corpus + SVC step-VM
corpus (278 entries / 170 happy).

### Fault-proof migration (Workstream H)

Plans: `docs/planning/fault_proof_migration_plan.md`,
`docs/fault_proof_design.md`, `docs/fault_proof_runbook.md`

Built (Lean + Rust).  State-commitment scheme, bisection game,
convergence / honesty / settlement theorem chain, SMT cell proofs
(SC.1–SC.3), step-VM coherence (SVC), observer daemon (RH-G).

**Closed — the terminal step adjudicates.**  It did not, and the
failure was structural rather than a bug: `initiateChallenge` anchors
both game endpoints to submitted state roots, so `g.low.commit` and
`g.high.commit` are `commitExtendedState`-shaped, while
`KnomosisStepVM.executeStep` returned — by its own header — "a step-VM-
specific 32-byte hash" that "is NOT byte-identical to" one.  The two
sides of the terminal comparison were different constructions, so it
never succeeded and an honest sequencer lost every game it correctly
defended.  The per-entry byte-equivalence assertion in
`solidity/test/CrossCheck/StepVM.t.sol` was skipped for exactly that
reason, which is why no suite reported it.

The Lean side compounded it with a vacuity — `kernelStepApply` returned
the responder's own `step.postStateCommit` whenever `verifyCellProofs`
passed, and that is `List.all` over the bundle, so an **empty** bundle
passed — after which the transition compared the value against the
responder's own claim.  Both halves are closed.  `kernelStepApply`
computes through `verifierPostRootMulti`, and `terminateOnSingleStep`
reads both the pre-state and the target from the game state.  The
midpoint is derived rather than caller-chosen on all three stacks, so
convergence is proved *logarithmically*
(`bisection_converges_in_log_rounds`).

Closing the recipe mismatch meant Merkleising the state root so a
post-root is recomputable from the pre-root plus the proven cell
writes.  The Lean side of that is complete.  `commitExtendedState`
**is** the SMT cell root (the
seven-component concatenation survives as
`commitExtendedStateConcat`, published by nothing); the cell space
covers all seven `ExtendedState` fields (tags 7–16); `smtCellKey` /
`StepVMMerkle.deriveCellSmtKey` derive the SMT key on-chain rather
than accepting one;
`smtRootListAux_perm_of_eq_under_collision_free` proves the published
root injective (the EI.8 replacement, so the swap did not downgrade
the headline guarantee) and `commitExtendedState_determines_cells`
composes it with the cell enumeration, giving the behavioural form the
game needs; a cell's leaf branches on absence (`cellLeaf`) so a cell
the state does not hold is openable at all, with completeness proved
both ways (`canonicalSiblings_verifies_present` /
`canonicalSiblings_verifies_absent`); and the write algebra is proved
against the root rather than merely well-defined —
`updateStateCellRoot_eq_commit_of_canonical` lands a single re-walked
opening on `commitExtendedState` of the post-state, and
`updateStateCellRoot_proof_independent` stops a responder steering it
by choosing among verifying openings.

What the fold owes per variant is `WriteSetComplete`: the advance
changes no cell the declaration omits.  `FaultProof/CellWrites.lean`
holds that obligation and the cell-write primitives it is stated over
(`getCellValue_setCell_getCellValue` supplies the write values across
all fifteen cell kinds).
`commitExtendedState_eq_of_cells_agree` is what makes that provable at
all.  `ExtendedState` equality is out of reach — the two paths build
their `Std.TreeMap`s in different insertion orders and core has no
pointwise lemma concluding `=` — but the deeper point is that map
agreement is the WRONG target: it is strictly stronger than what the
root observes, since `stateCellEntries` drops canonically-absent
cells, so a balance swept to zero and one never written are
cell-identical and root-identical with pointwise-different maps.
`reclaimAmmReserves` reaches that pair, so a map-level proof would be
assuming something false.  The reference apply has moved from `kernelOnlyApply`
to `ProductionApply`'s `productionApplyBudget`, and
`Action.writeCellsAt` fixes the one declaration that was genuinely
incomplete (`withdraw` creates a cell keyed by the pre-state's
`nextWdId`, which `writeCells` cannot name).

`WriteSetComplete` is now proved for all twenty-five actions
(`FaultProof/StepWriteSets.lean`), bulk included.  The bulk pair was
going to route through `SubStep.lean` on the grounds that its
footprint is unboundedly many cells; `Laws.BulkBounded` caps it in
both laws' preconditions, and the real obstacle was the ARITY of
`Action.writeCells` rather than the size — a recipient set is a
function of the state, so it belongs in `Action.stateWriteCells`
alongside `withdraw`'s `nextWdId`-keyed pending cell.  A bulk step
stays a single `executeStep`, with no sub-step index in the game's
addressing.

That is completeness of the HONEST bundle, and for the bulk pair it is
not the same as verifiability: an L1 holding only the pre-root cannot
tell a complete recipient set from one missing an entry, because the
missing cell's opening is simply absent and `smtCellKey` hashes the
cell identity so no subtree argument enumerates a resource's actors.
Non-bulk variants re-derive their tag list and are immune.  Pinned as
an `OBLIGATION:` case in `faultproof-write-sets`.  **Resolved by
exclusion**: `FaultProof.FaultProofAdjudicable` is a decidable
predicate, false on exactly those two
(`faultProofAdjudicable_eq_false_iff`), and a deployment leaning on
the fault proof must not authorise them — its `AuthorityPolicy`
already expresses that.  Chosen over a per-resource actor-set cell or
an explicit recipient list because it costs nothing and is reversible.
`stepMultiBundle` is the honest sequencer's side, and
`stepMultiFold_eq_commit_post` says the merged walk of THAT bundle
lands on the root the sequencer published.  On the L1 side
`StepVMMerkle.updateCellRoot` and `cellLeafHash` supply the fold's two
primitives.

**The wire is landed.**  Every production bundle is built by
`buildCellProofWithOpening`; `CellProof` carries `bytes proofData` (a
32-byte bitmask plus siblings) through the Lean CBE codec, the JSON
emitter, the Rust conduit's ABI encoder and the Solidity struct, which
shape-validates it at intake; the corpus publishes `proofDataHex` per
proof.  So is the action binding: `KnomosisStateRootSubmission`'s
log-entry chain now folds in an `actionCommit`
(`solidity/src/lib/LogChain.sol`, mirrored by
`StepVMCoherence.l1ActionCommit`), so `terminateOnSingleStep`
authenticates the `(actionKind, actionFields, signer)` triple it is
handed instead of executing whatever it is given.

**The verifier-side derivation is complete on the Lean side.**
`FaultProof/VerifierWrites.lean` derives EVERY cell kind a step can
write from proven pre-values alone, each with a `*_correct` theorem
against `getCellValue (productionApplyBudget es st idx)`: the nonce and
epoch-budget cells (uniform across all twenty-five variants), the
balances of all twelve variants that write one, and the registry /
local-policy / bridge cells of the eight that write those.  Two
properties run through all of it — the precondition is EVALUATED rather
than asserted (so a failing one is a no-op, not a revert), and the
reader is PARTIAL (so an omitted opening derives nothing rather than a
value of the responder's choosing).

**What remains** is the Solidity mirror, which is under way.
`solidity/src/lib/CBEEncode.sol` supplies the canonical value encoders
(`CBEDecode` had readers and no writers), pinned by the corpus's
`cbeEncoderGoldens` column and round-tripped against the step VM's own
decoder; `src/lib/StepWrites.sol` mirrors the two cells EVERY action
writes — the nonce and the three-branch epoch budget — pinned by
`uniformWriteGoldens`.  Those are precisely the cells `stepVMHash` is
silent about.  `StepWrites` also mirrors the per-variant BALANCE derivations
(`balanceWriteGoldens`, over a populated two-resource base — including
the self-transfer, the failing precondition and the same-actor chain,
which a happy-path corpus never reaches) and the registry /
local-policy / bridge cells (`recordWriteGoldens`).  **Every cell kind
now agrees byte-for-byte across both stacks.**  Left: `executeStep`
verifying each opening against the running root and returning the
fold's result instead of `stepVMHash`.

The verifier is `KnomosisStepVMRoot.executeStepToRootMulti`: it takes a
pre-root, the action, the signer, the log index and one deduplicating
pre-root multiproof, re-derives the cell list, re-derives every cell's
post-value, and folds to the post-state ROOT.  A NEW contract rather
than a bigger `KnomosisStepVM`, which was already large; retiring the
old recipe left one contract.

Why the DERIVATION and not the submitted values: computing a cell's new
value takes the pre-state and reads `productionApplyBudget` — that is
the SEQUENCER's computation.  A verifier holding only a pre-root and a
submitted bundle has neither, so folding what it is handed would let a
responder choose the resulting root.

`terminateOnSingleStep` calls it, so both sides of the terminal
comparison are state roots and `KnomosisFaultProofGame.t.sol`'s
honest-sequencer-wins test passes for the right reason — driven by a
REAL corpus probe (pre-root, action, frontier, wire, post-root),
because a fabricated `low` has no wire that reproduces it.
`FaultProof/Terminate.lean` is the Lean mirror
(`verifierPostRootMulti` / `stepMultiPostRoot`), pinned on nineteen
probes and refusing a forged pre-value, a short wire, a set padding
bit, a duplicate cell and the two bulk variants.

Every cell is opened ONCE against the pre-root and they share one
sibling list, which buys four properties the game relies on.  The
pre-root is checked once, in aggregate, so no intermediate root is
materialised or trusted.  A cell written twice — a self-transfer,
which anyone can submit — is opened once, so the responsible party is
not charged for a second walk that lands the value the first already
did.  Order carries no information (the verifier sorts by path index),
so a permuted bundle settles identically and nobody loses on a
formatting question — the chained arrangement's
`test_reordered_bundle_reverts` is now
`test_a_permuted_frontier_reaches_the_same_root`, inverted on purpose.
And the wire's length is DERIVED from the cell set (`G = (256+1) − m +
Σ divs`), so a truncated proof reverts rather than being padded out
with a placeholder hash and walked to some other root — the one thing
the single-cell verifier cannot do.

Measured over the twenty corpus probes: **−48% calldata**, and gas
+5.6% on a distinct-cell step against **−11.7%** on the duplicate-cell
shape the dedup exists for.  Getting there took three profiler-found
fixes rather than one design decision, and one of them —
`precomputeEmptySubtreeHashes` carrying its running hash on the stack
instead of paying two bounds-checked fixed-array accesses per level —
made the terminal step 15% cheaper on its own, before any multiproof.

`buildTerminateBundle` emits the frontier plus the wire
(`opened_cells` / `gap_mask_hex` / `siblings_hex`); the `witnessCommit`
word is gone from the wire on all three stacks — it was a claim only a
holder of the whole `ExtendedState` could check and a responder could
set freely — and the Rust conduit follows the terminate signature
(`method_selectors.json` regenerated from the compiled ABI, so a drift
breaks the build rather than the game).

`Step.kernelStepApply` — the Lean MODEL of the terminal step — routes
through `verifierPostRootMulti` too, so the model computes what the
contract computes.  `KernelStep` carries the log index and a
`MultiBundle` instead of a witness-state-bearing bundle, and an empty
one no longer verifies vacuously: the frontier always leads with the
read-only budget-policy cell, so `frontierShapeOk_nil_of_cons` refuses
it as a property of the list's shape.

**The old recipe is gone.**  `KnomosisStepVM.sol` and its test,
`SolidityStepVMCommit.lean`, `stepVMHash` / `stepVMHashFromAction` and
the 37 theorems pinning their per-variant arms, the corpus's
`expectedStepVMCommitHex` column and the 79 coherence cases that
consumed it — deleted once nothing referenced them.  What survives
from that surface is the L1 FIELD LAYOUT: `actionKindByte`,
`actionFieldsForL1`, the big-endian encoders (moved into
`StepVMCoherence.lean` when their file went) and the log-entry chain's
`l1ActionCommit`.  Those were never recipe-bound, and the
root-computing step VM reads them unchanged.
`docs/audits/19-findings-and-followups.md` records the blast radius
and `docs/planning/state_root_merkleisation_plan.md` §4 step 3 is the
specification.

**And so is the chained fold that replaced it.**
`KnomosisStepVMRoot.executeStepToRoot`, its `CellOpening` struct and
per-write derivation helpers, `StepVMMerkle.applyCellWrite`, the
`writeBundleGoldens` / `stepPostRootGoldens` corpus columns and the
Lean chained verifier (`verifierPostRoot`, `stepOpenings`,
`policyOpening`, `preStateValueAt` and their readers) are gone —
retired once the multiproof was pinned against Lean on the same twenty
probes AND against the chained entry point itself, which passed on all
twenty before its second operand was deleted.  What the corpus asserts
now is stronger than that agreement: `multiProofGoldens` publishes the
fold's root and `commitExtendedState (productionApplyBudget …)`
independently, so a verifier is right only if two separately-computed
numbers coincide.

**And so is the honest sequencer's chained write algebra.**
`stepWriteBundle` / `stepPostRoot`, `chainWrites`, `canonicalCellChain`,
`foldStateCellWrites`, `CellWriteChain` and `ChainCoherent` are gone.
They were kept through M8 on one ground — the multiproof's guarantee
was only VALUE-level, and retiring a headline theorem before its
replacement is proved is the wrong order.  `stepMultiFold_eq_commit_post`
removed that ground.

Deleting them was structural rather than a sweep, because the modules
mixed lifecycles: `CellWrites.lean` hosted the cell-write primitives,
the `WriteSetComplete` obligation the multiproof CONSUMES, and the
retired chain, so the cut ran between declarations rather than around a
file.  Two things were reclassified on the way.
`dropKey_stateCellEntries_perm_of_agree_off` stays — its last caller
was a chain link, but its ROLE is discharging
`updateStateCellRoot_eq_commit_of_canonical`'s hypothesis, and deleting
it would leave a headline theorem nobody can apply.
`verifyStateCellProof_buildStateCellProof` stays for the same reason in
the other direction: `buildStateCellProof` is a live production path
(it is what the observer puts on the wire as `proofData`), so a theorem
saying its opening verifies is a guarantee about something real; losing
its caller made it unconsumed, not untrue, and a test now pins it.
The two `OBLIGATION:` cases were restated on the merged walk rather
than dropped with the fold they were written against.

The multiproof's foundation:  `pathSorted (frontierOf …)` was a
value-level fact — two examples — while `frontierShapeOk`'s whole
argument rested on it; `pathLess_trans` / `pathLess_total` now make
path order a strict total order, `pathSorted_frontierOf` lifts it to
the frontier, `frontierOf_keys_nodup` turns sortedness into
distinctness, and `bundleValueAt_stepMultiBundle` bridges a submitted
bundle to `getCellValue`, which is what every `VerifierWrites`
correctness theorem is stated against.  That last one also corrected a
stack disagreement: `bundleValueAt` looked cells up by HASHED KEY while
`KnomosisStepVMRoot._findOpened` looks them up by tag, so Lean now
matches the contract.  What remains is a reader congruence for
`plannedBalances`, a `derivedCellValue_correct` over the twenty-five
variants, and the well-formedness side conditions.  Recorded in
`state_root_merkleisation_plan.md` §6.5 M8 / M9.

### Fair queuing (Workstream FQ / GP.8)

Plan: `docs/planning/GP.8_SEQUENCER_INTEGRATION_PLAN.md`

Track A complete: two-tier DRR fair scheduler in `knomosis-host`,
signer-hint wire protocol (`PROTOCOL_VERSION 2`), persistent
pipelined connections.  Track B (v1 reimbursement claim) complete:
`knomosis-l1-ingest::sequencer_claim::SequencerClaim::build` (capped,
sequencer-only, `Zeroizing` pool key; `abi.md` §10.2.6).  GP.8.5 v2
receipt-verified claim core built (not yet wired into a
production admission path — see the GP table row): `LegalKernel.Bridge.ReceiptVerifiedClaim`
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

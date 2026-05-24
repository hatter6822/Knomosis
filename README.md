<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Knomosis — A Societal Kernel

**Version:** v0.2.18 &nbsp;·&nbsp; **Build tag:** `knomosis-step-vm-coherence`
&nbsp;·&nbsp; **Toolchain:** Lean 4 v4.29.1 &nbsp;·&nbsp; **License:** GPL-3.0

Knomosis is a **proof-carrying state-transition system** written in Lean 4
with mechanically-equivalent Solidity (L1) and Rust (host) mirrors. The
kernel does not encode any specific economic rule. Instead it defines
*what it means* for a state change to be legal — and the build
mechanically rejects everything else. Specific rules (transfers, mints,
signed actions, deposits, withdrawals, disputes, actor-scoped policies)
are first-class values that compose with proof obligations the type
checker will not accept without discharge.

The trusted computing base is **two Lean modules** totalling ~750 lines.
Every kernel theorem `#print axioms` to exactly the three Lean built-ins
(`propext`, `Classical.choice`, `Quot.sound`) — there are zero
project-defined axioms. There is zero external Lake dependency: no
Mathlib, no batteries, just Lean core plus
`LegalKernel/{Kernel,RBMapLemmas}.lean`.

The architectural and mathematical blueprint is
[`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md). Engineering conventions
and the day-to-day developer workflow live in
[`CLAUDE.md`](CLAUDE.md) (mirrored byte-identically to `AGENTS.md`).

## Table of contents

1. [At a glance](#at-a-glance)
2. [Cross-stack architecture](#cross-stack-architecture)
3. [What's novel](#whats-novel)
4. [Performance and scale](#performance-and-scale)
5. [Quickstart](#quickstart)
6. [Repository layout](#repository-layout)
7. [How correctness is enforced](#how-correctness-is-enforced)
8. [Trust assumptions](#trust-assumptions)
9. [Phase and workstream status](#phase-and-workstream-status)
10. [Documentation map](#documentation-map)
11. [Reading order for new contributors](#reading-order-for-new-contributors)
12. [Headline theorems](#headline-theorems)
13. [Contributing](#contributing)
14. [License](#license)

## At a glance

| Metric                                  | Value                                                                  |
|-----------------------------------------|------------------------------------------------------------------------|
| Lean toolchain                          | `leanprover/lean4:v4.29.1` (pinned in `lean-toolchain`)                |
| Trusted core (TCB)                      | `LegalKernel/Kernel.lean` + `LegalKernel/RBMapLemmas.lean`             |
| Custom axioms                           | **0** — every kernel theorem `#print axioms` to the three Lean built-ins |
| `sorry` in TCB                          | **0**, mechanically enforced (`lake exe count_sorries`)                |
| External Lake dependencies              | **0** — Lean core only, no Mathlib, no batteries                       |
| Lean test mass                          | ~2 257 tests across 126 suites (`lake test`)                           |
| Solidity test mass                      | ~417 tests across 26 forge suites (`forge test` in `solidity/`)        |
| Rust test mass                          | ~1 400 tests across 11 workspace crates (`cargo test` in `runtime/`)   |
| Solidity surface                        | **10 contracts, 6 libraries, 5 interfaces** — immutable, no proxies, no admin |
| Rust workspace                          | **11 member crates** — Rust 1.83 stable                                |
| Lean executables (`lean_exe`)           | **13** — 2 runtime CLIs, 10 audit/codegen/tooling binaries, 1 test driver |
| Build tag (`LegalKernel.kernelBuildTag`)| `knomosis-step-vm-coherence`                                              |

A green CI run on `lake build`, `lake test`, `forge test`, and
`cargo test --workspace` plus the audit binaries below is the
authoritative signal that all phase-acceptance criteria still hold. The
two TCB files require **two reviewers** per PR (Genesis Plan §13.6);
non-TCB modules require one.

## Cross-stack architecture

Knomosis is a three-stack system. The Lean kernel is the source of truth;
Solidity and Rust mirrors are byte-equivalent reflections that cross-
stack fixture corpora ratify on every CI run.

```
┌────────────────────────────────────────────────────────────────────┐
│                  Lean 4  ·  THE SOURCE OF TRUTH                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ LegalKernel/Kernel.lean + RBMapLemmas.lean   (TCB, ~750 LOC) │  │
│  │   step_impl, impl_refines_spec, impl_noop_if_not_pre,        │  │
│  │   invariant_preservation, Reachable (§4.9 + §4.10)           │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  Laws · Authority · Encoding · DSL · Events · Runtime · Disputes   │
│  Bridge · FaultProof · LocalPolicy · Lex (M1/M2/M3)                │
└──────────────┬───────────────────────────────┬─────────────────────┘
               │ byte-equivalent CBE/EIP-712   │ byte-equivalent CBE
               │ + Withdrawal-tree + SMT       │ + L1-event ingest
               ▼                               ▼
┌─────────────────────────────┐   ┌──────────────────────────────────┐
│        Solidity L1          │   │      Rust host runtime           │
│  10 immutable contracts     │   │  11 workspace crates             │
│  6 libraries (incl.         │   │  knomosis-host (network adaptor)    │
│    SmtCellVerifier,         │   │  knomosis-l1-ingest (L1 watcher)    │
│    StepVMMerkle)            │   │  knomosis-event-subscribe           │
│  5 interfaces               │   │  knomosis-storage / knomosis-indexer   │
│  Fault-proof game arbiter   │   │  knomosis-faultproof-observer       │
│  ~417 forge tests           │   │  knomosis-bench (throughput)        │
│  (CrossCheck/* gated on     │   │  knomosis-verify-secp256k1 (RH-A.1) │
│   isKeccak256Linked)        │   │  knomosis-hash-keccak256   (RH-A.2) │
└─────────────────────────────┘   └──────────────────────────────────┘
```

Cross-stack equivalence is enforced by fixture corpora at
`runtime/tests/cross-stack/` (Rust ↔ Lean) and
`solidity/test/CrossCheck/fixtures/` (Solidity ↔ Lean):

| Cross-stack surface          | Fixture entries | Where                                                          |
|------------------------------|-----------------|----------------------------------------------------------------|
| ECDSA secp256k1 verification | 210 records     | `runtime/tests/cross-stack/ecdsa_secp256k1.cxsf`               |
| Keccak-256                   | 51 records      | `runtime/tests/cross-stack/keccak256.cxsf`                     |
| L1 event ingest              | 12 records      | `runtime/tests/cross-stack/l1_ingest.cxsf`                     |
| Withdrawal-tree SMT (E-F)    | F.1.x suite     | `solidity/test/CrossCheck/WithdrawalProof.t.sol` + fixtures    |
| SMT cell proofs (SC.3)       | 100 (50+50)     | `solidity/test/CrossCheck/SmtCellProof.t.sol` + fixtures       |
| Bisection game (H)           | F.1.x + SC.3    | `solidity/test/CrossCheck/BisectionGame.t.sol` + fixtures      |
| Step-VM coherence (SVC)      | 218 records     | `solidity/test/CrossCheck/StepVM.t.sol` + fixtures             |
| Observer game traces (RH-G)  | 50 traces       | `runtime/knomosis-faultproof-observer/tests/observer_game_traces.rs` |

## What's novel

Knomosis's distinguishing commitments — properties the build mechanically
enforces that comparable systems leave to convention or audit. Each
item is grounded in a Lean theorem the build will not accept with a
`sorry`. The full per-theorem catalogue lives in
[`CLAUDE.md`](CLAUDE.md); a curated subset is in
[Headline theorems](#headline-theorems) below.

| # | Property                                                  | Backing theorem(s)                                                                    |
|---|-----------------------------------------------------------|----------------------------------------------------------------------------------------|
| 1 | **Legality is a type, not a convention.**  A `Transition` carries a `Prop`-valued precondition, a constructive `Decidable` witness, and a total state transformer. The executable `step_impl` only advances state when the witness resolves; reading the kernel never depends on classical logic. | `impl_refines_spec`, `impl_noop_if_not_pre` |
| 2 | **Tiny TCB, three-axiom proof discipline.**  The trusted core is two modules. Every kernel theorem reduces to exactly `[propext, Classical.choice, Quot.sound]`. `Verify` and `hashBytes` are `opaque` (deployment-supplied), not `axiom`. | `#print axioms <theorem>` |
| 3 | **Type-level economic firewalls.**  `IsConservative` and `IsMonotonic` are typeclasses. A `ConservativeLawSet` or `MonotonicLawSet` deployment will not elaborate if a non-conservative or supply-destroying law is on its list. `mint_not_conservative`, `burn_not_conservative`, and `burn_not_monotonic` ship as the **negative witnesses** that make the firewall sound. | `ConservativeLawSet`, `MonotonicLawSet`, `total_supply_global` |
| 4 | **Replay protection as a Lean theorem.**  A successfully applied signed action is no longer admissible at the post-state; no two distinct admissible actions by the same signer share a nonce. Both follow from a per-actor strictly-monotone nonce ledger. | `replay_impossible`, `nonce_uniqueness`, `expectsNonce_strict_mono` |
| 5 | **Canonical, injective serialisation with domain separation.**  Every `Action`, `SignedAction`, `State`, and `ExtendedState` has a canonical CBE byte form with mechanically-proved round-trip and injectivity. The decoder rejects non-canonical inputs (unsorted / duplicate map keys). `signInput` prefixes a deployment-ID hash so signatures cannot replay across deployments. | `*_roundtrip`, `*_encode_injective`, `signInput_deterministic` |
| 6 | **Crash-consistent log + byte-identical replay.**  The on-disk log is an append-only frame stream with a per-frame integrity trailer. The standalone `knomosis-replay` binary reproduces the runtime's `StateHash` byte-for-byte from the same log on a separate machine with no shared state. | `replay_deterministic`, `hashBytes_deterministic` |
| 7 | **Pure dispute pipeline with type-level Stage-3 enforcement.**  Four pure-Lean stages (`fileDispute → checkEvidence → proposeVerdict → applyVerdict`) over a closed inductive of five claim variants. The safe `applyVerdict` requires a `VerdictPassedStage3` propositional witness; every error path is mechanically unreachable. | `applyVerdict_under_witness_succeeds`, `applyWithdraw_idempotent` |
| 8 | **Ethereum bridge with proven-correct withdrawal proofs.**  A height-64 sparse Merkle tree over `BridgeState.pending` produces a 32-byte withdrawal root. The L1 contracts (`solidity/`) port the verifier line-for-line and ship deployment-immutable (no proxies, no admin, no `Pausable`). | `verifyProof_complete`, `verifyProof_sound`, `eip712Wrap_injective` |
| 9 | **Actor-scoped policies (Workstream LP).**  Each actor declares a `LocalPolicy` (deny tags / require recipient ∈ set / cap amount) constraining their *own* outgoing actions, with a structural meta-action exemption that mechanically prevents lockout. | `localPolicy_meta_action_independent` |
| 10 | **Interactive fault-proof game (Workstream H).**  An on-L1 bisection game that converges to a single mis-stepped action under a 1-of-anyone-honest trust model. State commits are byte-equal to canonical sub-states under collision-freedom; an honest challenger always wins against an invalid state root. | `bisection_converges_after_enough_rounds`, `honest_challenger_wins_against_invalid_state_root` |
| 11 | **Lex law-declaration language with deployment manifests.**  A high-level surface (`lexlaw`) elaborates law declarations into Lean `Transition`s; the `deployment` macro emits deterministic manifest hashes. Governance tooling (`lex_diff` classifies `patch` / `minor` / `major` bumps, `lex_format` canonicalises clause order). All 17 kernel-built-in laws ship a Lex re-expression that is byte-equivalent to the hand-written form (verified at elaboration time via `rfl`). | `lex_law` macro + `deployment` macro |
| 12 | **Sparse-Merkle-tree cell proofs (Workstreams SC.1 / SC.2 / SC.3).**  A gas-efficient cell-proof scheme for the fault-proof game's bisection step: instead of submitting the full witness sub-state (`O(|sub-state|)` gas), the responder submits an SMT path (`O(log n)` gas). Under collision-resistance, no two valid proofs can witness different values for the same `(root, key)` pair — the load-bearing binding property the L1 contract relies on. The Solidity verifier (`SmtCellVerifier`, SC.2) walks the path on-chain in ≈ 35-50k gas; a 100-entry cross-stack corpus (SC.3) ratifies byte-for-byte agreement between the Lean and Solidity sides across 50 honest entries and 50 adversarial entries spanning six tamper classes. | `smtCellProof_sound_under_collision_free`, `smtCellProof_no_value_substitution`, `crosscheck-smt-cell-proof` (corpus) |

## Performance and scale

Knomosis is research-stage but actively measured. The Rust host runtime
ships a deterministic throughput benchmark (`knomosis-bench`, Workstream
RH-F) you can run locally; cross-stack corpora and per-PR CI gates
ratify byte-equivalence on every change.

### Throughput

| Workload                                    | p50    | p99    | Sustained throughput |
|---------------------------------------------|--------|--------|----------------------|
| Default `--standalone` (MockKernel)         | ~8 ms  | ~13 ms | ~7 500 ops/sec       |
| 1 000 actors × 10 000 signed transfers      |        |        | (developer workstation: Linux 6.18, opt-level=3, LTO=thin) |

`knomosis-bench` exposes JSON-report sidecars, baseline regression detection
(`--baseline`, fails on > 10 % drift), and absolute target gates
(`--target-tps`, `--target-p99-ms`) for CI. The bottleneck under the
current wire format is the one-shot-per-request connection pattern; a
persistent-connection wire-format amendment is on the Phase-7 roadmap.

Bench against the real Lean kernel by pointing `--connect` at a
knomosis-host running with the production `CommandKernel`; bench against an
in-process mock for isolating framing / queue / worker overhead. See
[`runtime/README.md`](runtime/README.md) for the day-to-day operator
guide.

### Build and test footprint

| Stack    | Source files                    | Tests        | Suites          | Cold build | Warm rebuild |
|----------|---------------------------------|--------------|-----------------|------------|--------------|
| Lean     | ~241 `.lean` files (~73k LOC)   | ~2 257       | 126             | minutes    | seconds      |
| Solidity | 10 contracts + 6 libs + 5 ifaces| ~417         | 26 forge suites | seconds    | sub-second   |
| Rust     | 11 workspace crates             | ~1 400       | per-crate       | minutes    | seconds      |

Cold-build numbers depend on machine; CI workflows
(`.github/workflows/ci.yml`, `.github/workflows/ci-rust.yml`) pass on a
GitHub-hosted runner.

### Determinism

Knomosis' runtime guarantees are **byte-identical**, not "semantically
equivalent". `replay_deterministic`, `hashBytes_deterministic`,
`state_encode_deterministic`, and `signInput_deterministic` together
imply that any two replicas given the same `(genesis, log)` produce the
same final state hash, the same encoded state bytes, the same per-action
sign-input bytes, and the same content-hash bytes — across
architectures. `knomosis-replay` validates this end-to-end on every PR.

## Quickstart

Knomosis depends only on a pinned Lean 4 toolchain — no Mathlib, no
external Lake packages. The toolchain version is read from
`lean-toolchain`.

```bash
# Recommended: SHA-256-verified setup.  Pins the toolchain integrity
# and (with --build) runs the full compile.
./scripts/setup.sh                       # idempotent
./scripts/setup.sh --build               # full setup + lake build

# Manual alternative (skips integrity verification):
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
  | sh -s -- -y --default-toolchain none
elan toolchain install "$(cat lean-toolchain)"

# Daily commands.
source ~/.elan/env
lake build                               # full project (default target)
lake build LegalKernel.<Module>          # fast incremental feedback
lake test                                # ~2 257 tests across 126 suites
```

### Audit / CI gates

Each is a separate `lake exe` binary; CI blocks merges on any non-zero
exit.

| Binary                              | What it enforces                                              |
|-------------------------------------|---------------------------------------------------------------|
| `lake exe count_sorries`            | Zero `sorry` in any kernel-TCB module                         |
| `lake exe tcb_audit`                | TCB import allowlist (`tcb_allowlist.txt`)                    |
| `lake exe stub_audit`               | No placeholder bodies under red-flag docstrings               |
| `lake exe naming_audit`             | Content-name discipline (no `wuN_*`, `phaseN_*`, etc.)        |
| `lake exe deferral_audit`           | No `DEFERRED` / `TODO` / "follow-up" markers                  |
| `lake exe mock_import_audit`        | No production module imports `Test/*`                         |
| `lake exe lex_lint`                 | Lex registry append-only discipline + sidecar consistency     |
| `lake exe lex_codegen --check`      | Lex codegen-input bytes match generated Lean                  |
| `lake exe lex_codegen --gen-property-tests --check` | Auto-generated property tests stay in sync   |
| `lake exe lex_diff <before> <after>`| Lex semantic diff + patch / minor / major bump classification |
| `lake exe lex_format <file>`        | Lex pretty-printer (canonical clause order)                   |

### Runtime smoke test

```bash
.lake/build/bin/knomosis info                       # build tag + phase
.lake/build/bin/knomosis bootstrap /tmp/test.log    # init an empty log
.lake/build/bin/knomosis-replay /tmp/test.log       # reproduce state hash
```

### Lex governance tooling (LX-M3)

```bash
.lake/build/bin/lex_diff <ref-a> <ref-b>         # semantic diff + bump class
.lake/build/bin/lex_diff --git HEAD~1 HEAD       # ...using git refs
.lake/build/bin/lex_format <file.lean>           # pretty-print + canonicalise
```

### Workstream-D withdrawal-proof CLI

```bash
.lake/build/bin/knomosis withdrawal-proof SNAP_PATH WITHDRAWAL_ID
```

### Workstream-H operator subcommands (RH-G observer)

```bash
.lake/build/bin/knomosis replay-up-to LOG IDX             # SubprocessTruthOracle truth fn
.lake/build/bin/knomosis export-cell-proofs LOG IDX SIG   # terminate-bundle JSON
```

### Solidity layer (Workstreams E + H)

See [`solidity/README.md`](solidity/README.md) for the day-to-day
developer guide.

```bash
cd solidity && ./scripts/vendor-deps.sh          # one-time: vendor OZ + forge-std
cd solidity && forge build                       # solc 0.8.20, via_ir
cd solidity && forge test                        # ~417 tests across 26 suites
cd solidity && make test-cross-stack             # F.1.x + SC.3 equivalence suites
cd solidity && make testnet-acceptance-dryrun    # F.3 local fork dry-run
```

### Rust host runtime (Workstream RH)

See [`runtime/README.md`](runtime/README.md) for the day-to-day
developer guide.

```bash
# Toolchain pinned in runtime/rust-toolchain.toml (stable 1.83).
cd runtime && cargo build --workspace --all-targets
cd runtime && cargo test --workspace
cd runtime && cargo clippy --workspace --all-targets -- -D warnings
cd runtime && cargo fmt --all -- --check
```

## Repository layout

```
knomosis/
├── LegalKernel.lean             — umbrella import; downstream consumers use this
├── Lex.lean                     — umbrella for the Lex language
├── Deployments.lean             — umbrella for example deployments
├── Main.lean                    — `knomosis` runtime CLI (Phase 5)
├── Replay.lean                  — `knomosis-replay` audit binary (Phase 5)
├── Tests.lean                   — @[test_driver]; entry point for `lake test`
├── lakefile.lean                — Lake config + strict lean options
├── lean-toolchain               — pinned Lean version
├── tcb_allowlist.txt            — TCB import allowlist (WU 1.11)
│
├── LegalKernel/                 — kernel + every non-TCB layer
│   ├── Kernel.lean              — §4.12 trusted core (TCB)
│   ├── RBMapLemmas.lean         — §8.3 RBMap proof library (TCB)
│   ├── Conservation.lean        — TotalSupply, IsConservative, IsMonotonic,
│   │                               LocalTo, FreezePreserving, …
│   ├── Laws/                    — one file per deployable law (hand-written
│   │                               form + co-located Lex re-expression)
│   ├── Authority/               — Crypto, Action, Identity, Nonce, LocalPolicy,
│   │                               SignedAction (replay_impossible)
│   ├── Encoding/                — CBE codec: CBOR, Encodable, Action,
│   │                               SignedAction, State, SignInput, Disputes,
│   │                               LocalPolicy, *Injective.lean (EI track)
│   ├── DSL/                     — base law DSL: Law (`Law.mk`), LawSyntax
│   ├── Events/                  — deployment-facing event log (16 ctors)
│   ├── Runtime/                 — Hash, LogFile, Replay, Snapshot,
│   │                               AttestedSnapshot, Loop, CellProofJson
│   ├── Disputes/                — four-stage pipeline + incentive amendment
│   ├── LocalPolicy/             — Workstream LP classification
│   ├── Bridge/                  — Workstreams A–D: crypto adaptors,
│   │                               identity, bridge laws, withdrawal proofs
│   ├── FaultProof/              — Workstream H: state commits, bisection
│   │                               game, convergence/honesty/settlement,
│   │                               witness, SMT cell proofs (SC.1), step-VM
│   │                               coherence (SVC), L1 observer reference
│   └── Test/                    — kernel + bridge + fault-proof test suites
│                                  (`lake test` is the canonical query)
│
├── Lex/                         — Workstream LX: the Lex language
│   ├── IndexRegistry.txt        — frozen action-index registry (LX.1)
│   ├── DSL/                     — `lex_law`, `lexlaw`, properties, deployments
│   ├── Tools/                   — Lex audit-binary libraries
│   ├── Bin/                     — Lake `lean_exe` entry-point wrappers
│   ├── Inputs/                  — codegen-input JSON sidecars + manifest
│   ├── Examples/                — Lex-only demonstration laws
│   └── Test/                    — Lex test modules
│
├── Deployments/Examples/        — LX-M3 worked example (UsdClearing)
│
├── Tools/                       — non-Lex audit binaries
│   ├── Common.lean              — shared constants
│   ├── TcbAudit.lean            — TCB allowlist enforcer (WU 1.11)
│   ├── CountSorries.lean        — zero-sorry gate (WU 1.12)
│   ├── StubAudit.lean           — placeholder-stub detector
│   ├── NamingAudit.lean         — content-name discipline
│   ├── DeferralAudit.lean       — no-deferrals policy
│   └── MockImportAudit.lean     — production-imports-test detector
│
├── solidity/                    — Workstreams E + H: L1 contracts (immutable,
│   ├── foundry.toml             —   no proxies, no admin, no `Pausable`)
│   ├── src/contracts/           — 10 contracts: KnomosisBridge,
│   │                               KnomosisDisputeVerifier{,V2}, KnomosisIdentity-
│   │                               Registry, KnomosisSequencerStake,
│   │                               KnomosisMigration, KnomosisStateRootSubmission,
│   │                               KnomosisFaultProofGame, KnomosisStepVM,
│   │                               KnomosisFaultProofMigration
│   ├── src/interfaces/          — 5 public interface files
│   ├── src/lib/                 — 6 libs: CBEDecode, SmtVerifier, SmtCellVerifier
│   │                               (SC.2), KnomosisEip712, CREATE3, StepVMMerkle
│   ├── test/                    — 26 forge suites (14 unit + 12 CrossCheck;
│   │                               includes SC.3 cross-stack SMT corpus consumer)
│   └── README.md                — day-to-day Solidity developer guide
│
├── runtime/                     — Workstream RH: Rust host-runtime workspace
│   ├── Cargo.toml               —   workspace manifest (11 members)
│   ├── rust-toolchain.toml      —   pinned Rust channel (stable 1.83)
│   ├── knomosis-hash-fallback.c    —   AR.10 default fallback forwarder
│   ├── knomosis-cli-common/        —   shared CLI helpers (RH-H)
│   ├── knomosis-cross-stack/       —   fixture loader dev-dep (RH-H)
│   ├── knomosis-verify-secp256k1/  —   ECDSA secp256k1 verifier (RH-A.1)
│   ├── knomosis-hash-keccak256/    —   Keccak-256 hash adaptor (RH-A.2)
│   ├── knomosis-l1-ingest/         —   L1 event watcher daemon (RH-B)
│   ├── knomosis-host/              —   TCP/TLS/Unix network adaptor (RH-C)
│   ├── knomosis-event-subscribe/   —   event subscription server (RH-D)
│   ├── knomosis-storage/           —   Storage trait + SQLite-backed impl (RH-E.0)
│   ├── knomosis-indexer/           —   SQLite event indexer daemon (RH-E.1)
│   ├── knomosis-bench/             —   transfer-throughput benchmark (RH-F)
│   ├── knomosis-faultproof-observer/ — off-chain fault-proof observer (RH-G)
│   ├── tests/cross-stack/       —   .cxsf fixture corpus
│   └── README.md                —   day-to-day Rust developer guide
│
├── scripts/setup.sh             — SHA-256-verified toolchain installer
├── .github/workflows/ci.yml     — Lean / Solidity CI gates
├── .github/workflows/ci-rust.yml — Rust workspace CI gates (path-filtered to
│                                   runtime/**)
├── .github/CODEOWNERS           — request-for-review surface for TCB-core files (AR.20)
│
├── docs/                        — see Documentation map below
├── CLAUDE.md / AGENTS.md        — engineering conventions (byte-identical)
├── README.md                    — this file
└── LICENSE                      — GPL-3.0
```

Per-file purpose lives in each file's `/-! ... -/` module docstring, not
duplicated here.

### Targeted module builds

For fast incremental feedback, build the layer you're editing:

```bash
lake build LegalKernel.Kernel                  # TCB core
lake build LegalKernel.RBMapLemmas             # §8.3 fold lemmas
lake build LegalKernel.Conservation            # economic-invariants framework
lake build LegalKernel.Laws.Transfer           # one law (hand-written + Lex)
lake build LegalKernel.Authority.SignedAction  # replay_impossible
lake build LegalKernel.Encoding.State          # canonical state encoder
lake build LegalKernel.Runtime.Loop            # Phase-5 runtime
lake build LegalKernel.Disputes.Verdict        # Phase-6 Stage-3 enforcement
lake build LegalKernel.Bridge.WithdrawalRoot   # Workstream-D SMT verifier
lake build LegalKernel.FaultProof.Game         # Workstream-H bisection game
lake build LegalKernel.FaultProof.Smt          # SC.1 SMT cell proofs
lake build Lex.DSL.Law                         # `lexlaw` macro
lake build Lex.DSL.Deployment                  # `deployment` macro
lake build Deployments.Examples.UsdClearing    # LX-M3 worked example
```

## How correctness is enforced

Knomosis's correctness story is *what the build will not accept*. Every
commit must clear the following gates before merge.

| Posture                                                              | Mechanism                                        |
|----------------------------------------------------------------------|--------------------------------------------------|
| All Lean test suites pass (`ALL TESTS PASSED`)                       | `lake test` (`Tests.lean` driver)                |
| All forge suites pass                                                | `forge test` in `solidity/`                      |
| Rust workspace builds + tests + clippy + fmt clean                   | `.github/workflows/ci-rust.yml`                  |
| Zero `sorry` in any kernel-TCB module                                | `lake exe count_sorries`                         |
| TCB imports stay on the allowlist                                    | `lake exe tcb_audit`                             |
| Stub / placeholder bodies flagged                                    | `lake exe stub_audit`                            |
| No content-name discipline violations                                | `lake exe naming_audit`                          |
| No deferral markers (`TODO`, `DEFERRED`, …)                          | `lake exe deferral_audit`                        |
| No production module imports `Test/*`                                | `lake exe mock_import_audit`                     |
| Lex registry well-formed + sidecars consistent                       | `lake exe lex_lint`                              |
| Generated codegen is byte-stable                                     | `lake exe lex_codegen --check`                   |
| Every public surface has a `/-- … -/` doc                            | `linter.missingDocs := true` (lakefile)          |
| No silent universe / type-variable creation                          | `autoImplicit := false` (lakefile)               |
| No dead bindings                                                     | `linter.unusedVariables := true` (lakefile)      |
| No build warnings                                                    | CI strict-warnings gate                          |
| Build, tests, and audits run on every PR                             | `.github/workflows/ci.yml`                       |

### Decidability discipline

Every `Transition.decPre` should be definable as `fun _ => inferInstance`
whenever the precondition is built from arithmetic comparisons, `Nat`
operations, and finite conjunctions. A law needing a hand-written
`Decidable` derivation is a signal to security-review the law (§14.8):
preconditions that resist `inferInstance` often hide an unbounded
quantifier or a non-computable predicate that would break the executable
path. See [`docs/decidability_discipline.md`](docs/decidability_discipline.md).

### Hash-function swap-point

The Lean fallback is FNV-1a-64 (deterministic, 32-byte output via
zero-padding for forward compatibility with the production BLAKE3 /
keccak256 swap). The fallback is **fail-fast** at the CLI boundary:
`knomosis-replay` aborts with `SNAPSHOT_DECODE_ERROR` rather than silently
proceeding when the linked hash is the fallback
(`--allow-fallback-hash` opts in for testing). See
[`docs/abi.md`](docs/abi.md) §11. Production deployments link the Rust
crate `knomosis-hash-keccak256` (Workstream RH-A.2) ahead of the fallback
to override the swap-point with keccak-256.

## Trust assumptions

Knomosis' authority and bridge guarantees are conditional on three
deployment-supplied surfaces. None are Lean axioms — `#print axioms` on
every kernel theorem returns a subset of the three Lean built-ins.

1. **`Verify` is EUF-CMA secure** (Phase 3 WU 3.4). The kernel's
   `replay_impossible` and `nonce_uniqueness` theorems hold against any
   signature scheme that satisfies EUF-CMA. The production ECDSA
   secp256k1 binding ships in Rust crate `knomosis-verify-secp256k1`
   (Workstream RH-A.1, complete); the EUF-CMA assumption is a property
   of the linked binding, not a deferred follow-up.
2. **The hash function is collision-resistant** (Phase 5 WU 5.1 +
   Workstream D). `verifyProof_sound`, `eip712Wrap_injective`,
   `smtCellProof_sound_under_collision_free`, and
   `smtCellProof_no_value_substitution` all hold under `CollisionFree H`.
   The production keccak256 binding ships in Rust crate
   `knomosis-hash-keccak256` (Workstream RH-A.2, complete); collision-
   resistance is a property of the linked binding, not a deferred
   follow-up.
3. **The L1 fault-proof verifier (`l1FaultProofVerifier`) reflects the
   on-chain bisection game** (Workstream H). The L1 contract under
   `solidity/` enforces this operationally; the Lean-side `opaque`
   surfaces it as a trust assumption. Cross-stack ratification: the F.1.x
   corpus (witness-state form) and the SC.3 100-entry corpus (SMT form)
   mechanically confirm both sides walk the same bytes.

Ethereum-deployment-specific trust assumptions (L1 finality, Solidity-
contract correctness, EIP-1271 contract correctness) are documented in
[`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md) §15D.2 and
[`docs/extraction_notes.md`](docs/extraction_notes.md) §2.

## Phase and workstream status

Every entry in the table below is **Complete** unless explicitly flagged
otherwise; the Phase-7 advanced-capability portfolio is the next scoped
work.

### Lean kernel — Phases 0 – 6

| Phase     | Title                                | Status                  |
|-----------|--------------------------------------|-------------------------|
| 0         | Foundations (kernel skeleton + CI)   | Complete                |
| 1         | Kernel completion (RBMap, §4.3, §4.9)| Complete                |
| 2         | Economic invariants (conservation)   | Complete                |
| 3         | Authority layer (signed actions)     | Complete                |
| 4-prelude | Positive-incentive mechanisms        | Complete                |
| 4         | DSL and serialisation (CBE)          | Complete                |
| 5         | Runtime and extraction               | Complete (Lean side; Rust host WUs 5.4 / 5.7 / 5.8 / 5.11 deferred — see RH below) |
| 6         | Disputes and adjudication            | Complete (incl. incentive amendment) |

### Ethereum integration — Workstreams A – G

| Workstream | Title                                | Status                                                     |
|------------|--------------------------------------|------------------------------------------------------------|
| E-A        | Cryptographic adaptors               | Complete (Lean + Rust RH-A.1 / RH-A.2)                     |
| E-B        | Identity and authority               | Complete (Lean + Rust RH-B)                                |
| E-C        | Bridge laws                          | Complete (Lean; chain-level §7.6.4 / §7.6.5 follow-up)     |
| E-D        | Withdrawal proofs                    | Complete                                                   |
| E-E        | Solidity contracts                   | Complete (10 immutable contracts)                          |
| E-F        | Cross-stack verification             | Complete (fixtures + goldens + testnet script + props)     |
| E-G        | Documentation + amendment            | Complete (GENESIS_PLAN §15D + ABI §16 + extraction_notes)  |

### Higher-order workstreams

| Workstream | Title                                | Status                                                     |
|------------|--------------------------------------|------------------------------------------------------------|
| LP         | Actor-scoped local policies          | Complete (Lean; Solidity mirror future work)               |
| LX-M1      | Lex: macro skeleton + synthesizer    | Complete                                                   |
| LX-M2      | Lex: re-express 17 kernel laws       | Complete (byte-equivalent at `rfl`)                        |
| LX-M3      | Lex: deployment manifests + governance| Complete (`lex_diff`, `lex_format`, autogen)              |
| H          | Fault-proof migration                | Complete (Lean) + RH-G observer                            |
| SC.1       | SMT cell proofs: Lean spec + soundness | Complete                                                 |
| SC.2       | SMT cell proofs: Solidity verifier   | Complete                                                   |
| SC.3       | SMT cell proofs: cross-stack corpus  | Complete (50 honest + 50 adversarial)                      |
| SVC        | L1 step-VM cross-stack coherence     | Complete (218-entry fixture corpus; 19 variants)           |

### Rust host runtime — Workstream RH

| Sub-unit | Crate                                | Status                                                     |
|----------|--------------------------------------|------------------------------------------------------------|
| RH-H     | (workspace + CI harness)             | Complete                                                   |
| RH-A.1   | `knomosis-verify-secp256k1`             | Complete                                                   |
| RH-A.2   | `knomosis-hash-keccak256`               | Complete                                                   |
| RH-B     | `knomosis-l1-ingest`                    | Complete                                                   |
| RH-C     | `knomosis-host`                         | Complete                                                   |
| RH-D     | `knomosis-event-subscribe`              | Complete (Rust framework; Lean `extract-events` subcommand deferred) |
| RH-E.0   | `knomosis-storage`                      | Complete                                                   |
| RH-E.1   | `knomosis-indexer`                      | Complete (Rust framework; `--verify-against-knomosis` deferred) |
| RH-F     | `knomosis-bench`                        | Complete (harness ships; observed ~7.5k ops/sec on default workload) |
| RH-G     | `knomosis-faultproof-observer`          | Complete (game state machine + honest strategy + L1 watcher + JSON-RPC EIP-1559 submitter + cross-stack corpus + chaos suite) |

### Next

| Phase | Title                                | Status                              |
|-------|--------------------------------------|-------------------------------------|
| 7     | Advanced capabilities                | **Not started** — next scoped work  |

The canonical phase scoping lives in
[`docs/GENESIS_PLAN.md` §12](docs/GENESIS_PLAN.md). The deferred-work
master index is
[`docs/planning/deferred_work_index.md`](docs/planning/deferred_work_index.md).
Per-WU completion narratives live in git history (`git log --grep="WU"`).

## Documentation map

Each document has a single, sharp scope. When facts disagree across
docs, the precedence is **`GENESIS_PLAN.md` > workstream plans
(Ethereum / Lex / LP / Fault-proof / SMT / RH / SVC) > module docstrings
> `CLAUDE.md` > `README.md` > everything else.** Any PR that changes
behaviour, theorems, or formalisation status must update the canonical
doc in the same PR (see CLAUDE.md "Documentation rules").

### Canonical design

| Document                                                                                  | Scope                                                                |
|-------------------------------------------------------------------------------------------|----------------------------------------------------------------------|
| [`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md)                                            | **Canonical design.** Formal model, threat model, phased roadmap.    |
| [`docs/planning/ethereum_integration_plan.md`](docs/planning/ethereum_integration_plan.md)| Engineering plan for Workstreams A – G of the Ethereum integration.  |
| [`docs/planning/ethereum_workstream_g_plan.md`](docs/planning/ethereum_workstream_g_plan.md) | Documentation amendment closeout (E-G).                            |
| [`docs/planning/fault_proof_migration_plan.md`](docs/planning/fault_proof_migration_plan.md) | Engineering plan for Workstream H (interactive fault-proof game).  |
| [`docs/fault_proof_design.md`](docs/fault_proof_design.md)                                | Plain-language design rationale for Workstream H.                    |
| [`docs/fault_proof_runbook.md`](docs/fault_proof_runbook.md)                              | Operator runbook for Workstream H (deploy, monitor, incident).       |
| [`docs/law_language_design.md`](docs/law_language_design.md)                              | Design of the high-level law-authoring surface ("Lex").              |
| [`docs/planning/lex_implementation_plan.md`](docs/planning/lex_implementation_plan.md)    | Engineering plan for Lex M1 / M2 / M3 milestones.                    |
| [`docs/planning/lex_v2_v3_roadmap_plan.md`](docs/planning/lex_v2_v3_roadmap_plan.md)      | Lex v2 / v3 forward roadmap.                                         |
| [`docs/planning/actor_scoped_policies_plan.md`](docs/planning/actor_scoped_policies_plan.md) | Engineering plan for Workstream LP (`LocalPolicy`).                |
| [`docs/planning/parameterized_laws_plan.md`](docs/planning/parameterized_laws_plan.md)    | Engineering plan for parameterised-law refinements.                  |
| [`docs/planning/smt_cell_proofs_plan.md`](docs/planning/smt_cell_proofs_plan.md)          | Engineering plan for Workstream SC (SMT cell proofs SC.1 – SC.3).    |
| [`docs/planning/rust_host_runtime_plan.md`](docs/planning/rust_host_runtime_plan.md)      | Engineering plan for Workstream RH (Rust host-runtime workspace).    |
| [`docs/planning/step_vm_coherence_plan.md`](docs/planning/step_vm_coherence_plan.md)      | Engineering plan for Workstream SVC (L1 step-VM coherence).          |
| [`docs/planning/phase_7_plan.md`](docs/planning/phase_7_plan.md)                          | Advanced-capability portfolio for Phase 7.                           |

### Engineering reference

| Document                                                                                  | Scope                                                                |
|-------------------------------------------------------------------------------------------|----------------------------------------------------------------------|
| [`docs/economic_invariants.md`](docs/economic_invariants.md)                              | Phase-2 + Phase-4-prelude: conservation, monotonicity, firewalls.    |
| [`docs/decidability_discipline.md`](docs/decidability_discipline.md)                      | The `decPre := fun _ => inferInstance` discipline (WU 1.6).          |
| [`docs/std_dependencies.md`](docs/std_dependencies.md)                                    | Per-toolchain-bump audit of every Lean-core lemma the TCB invokes.   |
| [`docs/extraction_notes.md`](docs/extraction_notes.md)                                    | What survives Lean's compilation pipeline into the runtime binary.   |
| [`docs/abi.md`](docs/abi.md)                                                              | On-disk frame format, hash trailer, CLI ABI, RH wire formats.        |
| [`docs/lex_amendment_walkthrough.md`](docs/lex_amendment_walkthrough.md)                  | LX-M3: walked-through example of bumping a law version.              |
| [`docs/planning/open_questions.md`](docs/planning/open_questions.md)                      | Master design-decision registry (OQ-* identifiers).                  |
| [`docs/planning/deferred_work_index.md`](docs/planning/deferred_work_index.md)            | Navigator across deferred-work plans.                                |
| [`docs/planning/audit_remediation_plan.md`](docs/planning/audit_remediation_plan.md)      | The AR remediation workstream (audit findings → in-tree fixes).      |
| [`docs/planning/encoder_injectivity_plan.md`](docs/planning/encoder_injectivity_plan.md)  | The EI proof-track plan (encoder-injectivity ladder, complete).      |
| [`docs/audits/`](docs/audits/)                                                            | Per-area Lean audit reports (19 files, indexed by `00-comprehensive-lean-audit-index.md`). |
| [`runtime/README.md`](runtime/README.md)                                                  | Day-to-day Rust developer guide.                                     |
| [`solidity/README.md`](solidity/README.md)                                                | Day-to-day Solidity developer guide.                                 |
| [`CLAUDE.md`](CLAUDE.md) / [`AGENTS.md`](AGENTS.md)                                       | Engineering conventions and contributor workflow (byte-identical).   |

## Reading order for new contributors

1. **Skim** [`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md) §1 – §4 for
   the formal model.
2. **Read** `LegalKernel/Kernel.lean` end-to-end — it is the §4.12
   listing in literal form, ~200 lines. Every kernel theorem in
   [Headline theorems](#headline-theorems) lives here.
3. **Pick a law** under `LegalKernel/Laws/` and read its precondition,
   `apply_impl`, and `IsConservative` / `IsMonotonic` instance to see
   how the typeclass firewalls compose. Then read its co-located
   `lexlaw` declaration to see the high-level surface.
4. **Pick a Bridge module** under `LegalKernel/Bridge/` to see how
   non-kernel infrastructure consumes the same proof discipline.
5. **Read** `LegalKernel/FaultProof/Game.lean` for the bisection game
   and its convergence theorem, then
   `LegalKernel/FaultProof/Settlement.lean` for the honest-challenger
   guarantee.
6. **Run** `lake test`; the test files under `LegalKernel/Test/` double
   as worked examples for every theorem.
7. **Read** `Deployments/Examples/UsdClearing.lean` and
   [`docs/lex_amendment_walkthrough.md`](docs/lex_amendment_walkthrough.md)
   for an end-to-end view of an actual deployment under the Lex surface
   plus the governance workflow.
8. **Read** [`CLAUDE.md`](CLAUDE.md) before making any change — it owns
   the engineering conventions, naming rules, and the two-reviewer gate
   for kernel-touching work.

## Headline theorems

A curated subset of the type-level guarantees the build enforces. The
full per-theorem table lives in [`CLAUDE.md`](CLAUDE.md) ("Type-level
design properties"). `#print axioms` on each returns only the three
Lean built-ins.

| Theorem                                                  | What it proves                                                | Where                                              |
|----------------------------------------------------------|---------------------------------------------------------------|----------------------------------------------------|
| `impl_refines_spec`                                      | every executed step satisfies its relational spec             | `LegalKernel/Kernel.lean`                          |
| `impl_noop_if_not_pre`                                   | failing the precondition leaves state unchanged               | `LegalKernel/Kernel.lean`                          |
| `invariant_preservation[_via_laws]`                      | inductive invariants hold across reachable states             | `LegalKernel/Kernel.lean`                          |
| `transfer_conserves`                                     | transfer preserves per-resource total supply (§4.11.1)        | `LegalKernel/Laws/Transfer.lean`                   |
| `total_supply_global[_via_law_set]`                      | per-resource conservation across reachable states (§5.3)      | `LegalKernel/Conservation.lean`                    |
| `total_supply_globally_nondecreasing`                    | monotonic-law-set deployments cannot lose value               | `LegalKernel/Conservation.lean`                    |
| `proportionalDilute_distributed_le_totalReward`          | floor-division dust bound for proportional reward             | `LegalKernel/Laws/ProportionalDilute.lean`         |
| `Action.compile_injective`                               | distinct serialised actions are distinct compiled values      | `LegalKernel/Authority/Action.lean`                |
| `expectsNonce_strict_mono`                               | per-actor expected nonce strictly increases on advance        | `LegalKernel/Authority/Nonce.lean`                 |
| `nonce_uniqueness`                                       | no two admissible actions by the same signer share a nonce    | `LegalKernel/Authority/SignedAction.lean`          |
| `replay_impossible`                                      | a successfully applied signed action is not re-admissible     | `LegalKernel/Authority/SignedAction.lean`          |
| `localPolicy_meta_action_independent`                    | LP meta-actions exempt from the actor's own policy            | `LegalKernel/Authority/SignedAction.lean`          |
| `action_roundtrip`                                       | every Action's CBE encoding decodes back to itself            | `LegalKernel/Encoding/Action.lean`                 |
| `state_encode_deterministic`                             | equal `State` values produce equal canonical bytes            | `LegalKernel/Encoding/State.lean`                  |
| `State.encode_injective`                                 | distinct extensionally-equal `State` values encode to distinct bytes (EI.2) | `LegalKernel/Encoding/StateInjective.lean` |
| `signInput_deterministic`                                | equal sign-input args produce equal sign-input bytes (§8.8.5) | `LegalKernel/Encoding/SignInput.lean`              |
| `replay_deterministic`                                   | equal `(genesis, log)` pairs produce equal replay outputs     | `LegalKernel/Runtime/Replay.lean`                  |
| `applyWithdraw_idempotent`                               | dispute withdrawal is idempotent on every status              | `LegalKernel/Disputes/Filing.lean`                 |
| `applyVerdict_under_witness_succeeds`                    | safe `applyVerdict` is provably total under Stage-3 witness   | `LegalKernel/Disputes/Verdict.lean`                |
| `verifyProof_complete`                                   | every populated withdrawal's canonical proof verifies (D.1.3) | `LegalKernel/Bridge/WithdrawalRoot.lean`           |
| `verifyProof_sound`                                      | a verifying proof matches the canonical construction (D.1.4)  | `LegalKernel/Bridge/WithdrawalRoot.lean`           |
| `eip712Wrap_injective`                                   | EIP-712 wrap is injective under collision-freedom             | `LegalKernel/Bridge/Eip712.lean`                   |
| `bridgePolicy_rejects_withdraw`                          | the bridge actor cannot sign user withdrawals                 | `LegalKernel/Bridge/BridgeActor.lean`              |
| `disputable_monotonic_total_supply_nondecreasing`        | dispute-enabled monotonic deployments preserve non-decrease   | `LegalKernel/Disputes/MonotonicDeployment.lean`    |
| `bisection_converges_after_enough_rounds`                | bisection game converges to a single mis-stepped action       | `LegalKernel/FaultProof/Convergence.lean`          |
| `honest_challenger_wins_against_invalid_state_root`      | honest challenger wins at settlement on any invalid root      | `LegalKernel/FaultProof/Settlement.lean`           |
| `faultProof_challenger_won_implies_state_root_wrong`     | a settled fault-proof witness implies the state root is wrong | `LegalKernel/FaultProof/Witness.lean`              |
| `smtCellProof_sound_under_collision_free`                | SMT cell-proof binding under CR (Workstream SC.1)             | `LegalKernel/FaultProof/Smt.lean`                  |
| `smtCellProof_no_value_substitution`                     | no two valid SMT proofs witness different values (SC.1.e)     | `LegalKernel/FaultProof/Smt.lean`                  |
| `verifySmtCellProof_walks_to_root`                       | every well-formed SMT proof verifies against its walked root (SC.1) | `LegalKernel/FaultProof/Smt.lean`            |
| `commitExtendedState_subcommits_extensional_eq_under_collision_free` | extensional sub-state equality under CR (EI.8 + H) | `LegalKernel/FaultProof/Commit.lean`           |
| `crosscheck-smt-cell-proof` (corpus)                     | 100 cross-stack entries (50 honest + 50 adversarial × 6 tamper classes) ratify byte-for-byte Lean ↔ Solidity agreement (Workstream SC.3) | `LegalKernel/Test/Bridge/CrossCheck/SmtCellProof.lean` + `solidity/test/CrossCheck/SmtCellProof.t.sol` |

## Contributing

Read [`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md) end-to-end first.
Every change beyond the trivial must reference a work unit (`WU x.y`)
and follow the runbooks in §13.6 – §13.9. Kernel-touching work units
require **two reviewers**; deployment-infrastructure work units (laws,
authority, conservation, bridge, dispute pipeline, local policies,
fault-proof, Lex tooling) require one. See [`CLAUDE.md`](CLAUDE.md) for
the engineering conventions any human or AI contributor must follow.

### Reporting issues

Knomosis is research-stage software. If you discover a logic bug in the
kernel module (e.g. a counterexample to `impl_noop_if_not_pre`, or a
state advance that bypasses the `if` in `step_impl`), open an issue
with the `kernel-soundness` label. Such reports gate any in-flight PR;
the two-reviewer rule applies to the fix.

For non-kernel issues (laws, tooling, documentation), the standard
issue tracker workflow applies.

## License

Knomosis is released under the GNU General Public License, version 3. See
[LICENSE](LICENSE) for the full text.

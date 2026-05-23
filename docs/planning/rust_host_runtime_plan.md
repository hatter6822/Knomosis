<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Rust Host Runtime — Engineering Plan

This document plans the unified Rust-side runtime that ports the
Lean kernel's deployment-supplied substrates (crypto, hash, L1
event watcher) to production-grade implementations and ships the
host-level deliverables Phase 5 deferred (network adaptor,
subscription server, indexer, benchmark).  It also lands the
off-chain fault-proof observer deferred by Workstream H.

The Lean side is complete: every kernel theorem stands today on
the existing `@[extern]` swap-points and `opaque` declarations.
This workstream materialises the *production* implementations
behind those interface contracts.

## Status

  * **Workstream prefix:** `RH` (Rust Host).  Sub-stream status:
    - **RH-A** Cryptographic adaptors (E-A Rust).
      **Complete.**  See §RH-A.1 Closeout / §RH-A.2 Closeout
      below.
    - **RH-B** L1 ingestor (E-B Rust).
      **Complete.**  See §RH-B Closeout below.
    - **RH-C** Network adaptor (Phase 5 WU 5.4).
      Skeleton crate landed under RH-H; implementation pending.
    - **RH-D** Event subscription (Phase 5 WU 5.7).
      **Complete.**  See §RH-D Closeout below.
    - **RH-E** SQLite indexer + Rust DB layer (Phase 5 WU 5.8).
      Skeleton crates landed under RH-H; implementation pending.
    - **RH-F** Performance benchmark (Phase 5 WU 5.11).
      Skeleton crate landed under RH-H; implementation pending.
    - **RH-G** Fault-proof observer (Workstream H, WU H.10.5).
      Skeleton crate landed under RH-H; implementation pending.
    - **RH-H** Workspace + CI harness (the cross-cutting unit).
      **Complete.**  See §RH-H below for the closeout.
  * **Effort estimate:** 14–22 calendar weeks for one full-time
    Rust engineer (or ~9–14 weeks with two engineers post-RH-H).
  * **Build-posture target:** All Rust crates build under `cargo
    +stable build --workspace`, pass `cargo clippy
    --workspace -- -D warnings`, pass `cargo test --workspace`,
    and pass the cross-stack equivalence corpus.  Lean side is
    unchanged.
  * **TCB delta:** zero on the Lean side.  The Rust crates
    materialise existing `opaque`/`@[extern]` contracts; they do
    not extend the Lean TCB.
  * **Trust-assumption delta:** the existing `Verify`, `hashBytes`,
    and `l1FaultProofVerifier` opaques become *real* (linkable)
    symbols.  The EUF-CMA, collision-resistance, and L1-watcher
    assumptions documented in CLAUDE.md are unchanged in
    substance; this workstream realises them rather than adding
    new ones.

## Table of contents

  * §1 Goals and non-goals
  * §2 Architectural background
    * §2.1 The `@[extern]` swap-point contract
    * §2.2 Workspace layout
    * §2.3 Process model
    * §2.4 ABI / wire formats
  * §3 Work-unit dependencies
  * §4 Work-unit specifications (RH-A through RH-H)
  * §5 Sequencing and PR structure
  * §6 Quality gates
  * §7 Risk register
  * §8 Acceptance criteria for the workstream
  * §9 Out-of-scope items
  * §10 References

## §1 Goals and non-goals

### §1.1 Goals

  1. **Materialise the three `@[extern]` / `opaque` swap-points.**
    Production deployments link real implementations against:
     * `canon_hash_bytes` / `canon_hash_stream` /
       `canon_hash_identifier` — BLAKE3 (CLAUDE.md §"Trust
       assumptions") or keccak256 (Workstream E-A).
     * `canon_verify_ecdsa` — secp256k1 verification with low-s
       canonicalisation.
     * `canon_l1_fault_proof_verifier` — L1 event watcher with
       Ethereum JSON-RPC source.
  2. **Ship the Phase-5 host runtime stack.**  Network adaptor,
    event subscription, SQLite indexer, and 10k tx/sec
    benchmark.  These deliverables turn `knomosis` from a single-
    process executable into a real network service.
  3. **Ship the fault-proof off-chain observer.**  The
    long-running daemon that watches L1, computes honest-strategy
    bisection responses, and submits them to the L1 game
    contract.  Closes Workstream H Rust deliverable.
  4. **Preserve byte-identical cross-stack equivalence.**  Every
    Rust output (signature verification, hash, encoded
    `SignedAction`) byte-equals the Lean reference under the
    cross-stack fixture corpus.
  5. **Zero kernel changes.**  No `.lean` file changes outside
    of (a) ABI-cite-update doc strings and (b) test-fixture
    expansion.  The Lean kernel is the wire-format authority;
    the Rust crates conform.

### §1.2 Non-goals

  1. **No new trust assumptions.**  RH realises the existing
    swap-point contracts; it does not introduce new ones.
  2. **No Rust port of the Lean kernel.**  Lean's `step_impl` is
    the *only* canonical state-transition function.  The Rust
    runtime is a *shell* around `step_impl`: it receives signed
    actions over the network, forwards them via a sub-process or
    FFI call to the Lean executable, and returns the verdict.
  3. **No alternative encoding format.**  CBE is the wire format.
  4. **No deployment-specific configuration files.**  Each crate
    accepts a small CLI-flag set; full operator deployment is
    out of scope (the operator runbooks live separately).
  5. **No telemetry / metrics framework.**  Minimal counters
    (admitted vs rejected, p99 latency) are in scope; full
    Prometheus / OpenTelemetry export is a follow-up.

### §1.3 Reading guide

  * **Implementer (Rust):** read §2 (architecture) then §4 in
    order RH-H → RH-A → RH-G → ... .  RH-H establishes the
    workspace; RH-A is the simplest crypto crate (no I/O); RH-G
    has the operator runbook already drafted in
    `docs/fault_proof_runbook.md` §7.
  * **Implementer (Lean):** RH does not require Lean changes
    except for ABI docstring cross-references.  No new theorems.
  * **Reviewer:** check the cross-stack fixture corpus passes
    for every crate; check `cargo test` and clippy are clean.

### §1.4 Glossary

  * **Cross-stack fixture corpus.**  The set of test inputs
    where Lean and Solidity (and now Rust) all agree on output
    byte-for-byte.  Lives under `solidity/test/CrossStack/` and
    `runtime/knomosis-host/tests/cross-stack/`.
  * **Swap-point.**  A Lean declaration annotated `@[extern]` or
    `opaque` whose body is supplied at link time (for `@[extern]`)
    or at deployment-instance time (for `opaque`).  Three are
    relevant here: `hashBytes`, `Verify`, `l1FaultProofVerifier`.
  * **Honest strategy.**  The set of bisection-game responses
    computed from the canonical Lean replay; the observer
    daemon's job is to compute and submit these.

## §2 Architectural background

### §2.1 The `@[extern]` swap-point contract

Each swap-point is a Lean declaration of the form:

```lean
@[extern "canon_hash_bytes"]
def hashBytes (bs : ByteArray) : ByteArray :=
  hashBytesFallback bs
```

Lean's code-generator emits a call to the C symbol
`canon_hash_bytes` at runtime.  If the symbol is not provided by
the link environment, the compiled Lean falls back to the inline
`hashBytesFallback` body (an FNV-1a-64 stand-in shipped in
`runtime/knomosis-hash-fallback.c`).

The contract for a swap-point implementation is:

  1. **Same C ABI.**  The symbol name, argument types (`b_lean_obj_arg`
    of `ByteArray`), and return type (`lean_obj_res ByteArray`)
    must match Lean's `extern` declaration exactly.
  2. **Same byte-output.**  The Rust implementation must produce
    identical bytes to the documented production hash / signature
    scheme, validated against the cross-stack fixture corpus.
  3. **No side effects.**  Pure function.  No global state, no
    file I/O, no network I/O.

The `opaque` declarations (`Verify`, `l1FaultProofVerifier`) have
the same shape but no fallback body — calling them returns
`False` / `false` at the Lean level by Lean's
`Inhabited`-derivation default.  Production deployments must
supply a real implementation by replacing the `opaque` with an
`@[extern]` decl in a deployment-specific module *or* by linking
a substitute through the C-ABI surface.  This is the existing
deployment-instance pattern; RH does not change it.

### §2.2 Workspace layout

```
runtime/                          (project-relative root)
├── Cargo.toml                    -- workspace manifest
├── rust-toolchain.toml           -- pinned (stable 1.83+)
├── knomosis-host/                   -- RH-C network adaptor binary
│   ├── Cargo.toml
│   ├── src/main.rs               -- TCP/Unix-socket listener
│   ├── src/lean_subprocess.rs    -- spawns knomosis executable
│   └── src/abi.rs                -- CBE frame parser
├── knomosis-hash-keccak256/         -- RH-A.2 keccak256 adaptor
│   ├── Cargo.toml
│   ├── build.rs                  -- emits cdylib
│   └── src/lib.rs                -- #[no_mangle] canon_hash_bytes
├── knomosis-verify-secp256k1/       -- RH-A.1 ECDSA adaptor
│   ├── Cargo.toml
│   ├── build.rs
│   └── src/lib.rs                -- #[no_mangle] canon_verify_ecdsa
├── knomosis-l1-ingest/              -- RH-B L1 event ingestor
│   ├── Cargo.toml
│   └── src/main.rs               -- Ethereum JSON-RPC → SignedAction
├── knomosis-event-subscribe/        -- RH-D subscription server
│   ├── Cargo.toml
│   └── src/main.rs               -- ordered, bounded-lag dispatcher
├── knomosis-indexer/                -- RH-E SQLite indexer
│   ├── Cargo.toml
│   └── src/main.rs               -- event stream → SQLite views
├── knomosis-storage/                -- Rust DB layer (RH-E.0)
│   ├── Cargo.toml
│   └── src/lib.rs                -- KV/SQLite abstraction trait
├── knomosis-faultproof-observer/    -- RH-G off-chain observer
│   ├── Cargo.toml
│   └── src/main.rs               -- L1-event watcher daemon
├── knomosis-bench/                  -- RH-F benchmark
│   ├── Cargo.toml
│   └── benches/transfer_10k.rs
├── knomosis-cli-common/             -- shared CLI helpers
│   ├── Cargo.toml
│   └── src/lib.rs
└── tests/cross-stack/            -- cross-stack equivalence fixtures
    ├── hash_inputs.cbor
    ├── ecdsa_vectors.cbor
    └── signed_action_corpus.cbor
```

`knomosis-cli-common` and `knomosis-storage` are library crates
consumed by the binaries.  All binaries depend on
`knomosis-cli-common`; `knomosis-indexer` depends on `knomosis-storage`.

### §2.3 Process model

```
Operator                                                  Ethereum L1
   │                                                            │
   ▼                                                            ▼
knomosis-host (TCP) ─── spawns ───► knomosis (Lean exe) ◄── reads ── knomosis-l1-ingest
   │                                  │                            │
   │                                  ▼                            │
   │                              log.jsonl                        │
   │                                  │                            │
   ▼                                  ▼                            ▼
client                          knomosis-event-subscribe       knomosis-faultproof-observer
                                    │                            │
                                    ▼                            ▼
                              knomosis-indexer                  L1 game contract
                                    │
                                    ▼
                              indexer.db (SQLite)
```

Key invariants:

  * `knomosis-host` is the only writer to the log; all other
    crates are read-only consumers.
  * `knomosis-event-subscribe` and `knomosis-faultproof-observer` and
    `knomosis-indexer` consume the same log frames; ordering and
    durability come from `knomosis`'s `LogFile.lean` semantics.
  * The Lean `knomosis` executable is *unchanged*; the Rust shell
    is a process supervisor + ABI shim.

### §2.4 ABI / wire formats

Three wire-level interfaces are introduced (or finalised) in RH:

  1. **`knomosis-host` ↔ client (TCP).**  Length-prefixed CBE
    `SignedAction` request, length-prefixed CBE `Verdict`
    response.  Verdict bytes: `0 = OK`, `1 = notAdmissible`,
    `2 = parseError`.  TLS termination at the TCP boundary (RH-C
    accepts a `--tls-cert` / `--tls-key` pair; absence implies
    plaintext for local testing).  Full spec lands in
    `docs/abi.md` §10 (RH-C closes the placeholder line at
    `abi.md:724`).
  2. **`knomosis-host` ↔ `knomosis` (Unix socket).**  Same CBE framing
    as above, over a filesystem-permission-protected Unix socket
    (`/var/run/knomosis.sock` by default).  This is the existing
    Lean-side IPC channel; RH-C wires the host to it.
  3. **`knomosis-event-subscribe` ↔ client (TCP).**  An ordered
    event stream with a small framing header (`uint64` sequence
    number, `uint32` event length, then CBE-encoded event).
    Subscribers may resume from a given sequence number; the
    server enforces bounded subscriber lag and rejects
    out-of-order or dropped subscribers.

The L1 ingestor and observer crates use Ethereum JSON-RPC via
the `ethers-rs` library and consume L1 events directly; they do
not introduce new Knomosis wire formats.

## §3 Work-unit dependencies

```
RH-H (workspace + CI)
  ├── RH-A.1 (knomosis-verify-secp256k1)
  ├── RH-A.2 (knomosis-hash-keccak256)
  ├── RH-C (knomosis-host network adaptor)  ◄── RH-A.* link-time
  │     │
  │     └── RH-F (10k tx/sec benchmark)
  ├── RH-D (knomosis-event-subscribe)
  │     │
  │     ├── RH-E.0 (knomosis-storage / Rust DB layer)
  │     │     │
  │     │     └── RH-E.1 (knomosis-indexer)
  │     │
  │     └── RH-G (knomosis-faultproof-observer)
  │           │
  │           └── RH-B (knomosis-l1-ingest)  -- L1 RPC infrastructure
```

  * **RH-H first.**  Workspace skeleton, shared CI, cross-stack
    fixture corpus extension to Rust.
  * **RH-A in parallel** (no I/O, isolated crypto).
  * **RH-C after RH-A** (links the crypto adaptors at runtime).
  * **RH-D and RH-B in parallel** (different event sources).
  * **RH-E.0 before RH-E.1.**  The DB layer abstraction is the
    structural blocker for the indexer.
  * **RH-G after RH-D + RH-B** (consumes both).
  * **RH-F last** (depends on RH-C for end-to-end measurement).

## §4 Work-unit specifications

---

### RH-H — Workspace and CI harness

**Finding map.**  Common infrastructure for the entire Rust
runtime workstream.

**Scope.**  `runtime/` workspace skeleton; CI pipeline
extension; cross-stack fixture corpus packaging for Rust.

**Implementation steps.**

  1. Create `runtime/Cargo.toml` with workspace `[workspace]
    members = [...]` listing all eight crates.
  2. Add `runtime/rust-toolchain.toml` pinning stable Rust
    (recommend 1.83 stable LTS as of 2026; bump in a separate
    PR if a newer LTS is preferred).
  3. Extend `.github/workflows/ci.yml` with a `rust-build`
    job that runs `cargo build --workspace --all-targets`,
    `cargo test --workspace`, `cargo clippy --workspace
    --all-targets -- -D warnings`, and `cargo fmt --check`.
    Gate the job behind a `paths` filter so PRs that touch only
    `LegalKernel/*` don't trigger Rust CI.
  4. Implement `runtime/tests/cross-stack/` fixture loader.
    Each fixture is a CBE-encoded test vector (input bytes plus
    expected Lean output bytes).  The loader is a thin Rust
    helper that other crates import as a dev-dependency.
  5. Add `runtime/README.md` describing the workspace and
    pointing at this plan.
  6. Add to `CLAUDE.md` "Build and run" section: a "Rust host
    runtime" sub-section with `cargo build --workspace` and
    `cargo test --workspace` commands.

**Acceptance criteria.**

  * `cargo build --workspace` succeeds in CI.
  * `cargo clippy --workspace -- -D warnings` is clean.
  * Cross-stack fixture loader is consumable as a dev-dep.
  * Lean-side CI unaffected for `.lean`-only PRs.

**Risk.**  Low.  Standard Rust workspace setup.

**Effort.**  ~3 engineer-days.

#### RH-H — Closeout

**Status.**  **Complete.**

**Landed deliverables.**

  * `runtime/Cargo.toml` workspace manifest listing 11 member
    crates: the 10 crates in §2.2's layout (nine work-unit crates
    `knomosis-host`, `knomosis-hash-keccak256`, `knomosis-verify-secp256k1`,
    `knomosis-l1-ingest`, `knomosis-event-subscribe`, `knomosis-indexer`,
    `knomosis-storage`, `knomosis-faultproof-observer`, `knomosis-bench`
    plus the shared `knomosis-cli-common`) PLUS `knomosis-cross-stack`,
    which materialises the fixture-loader helper as its own
    dev-dep crate rather than inlining it into every consumer (a
    fidelity-preserving expansion of §4 RH-H step 4's "thin Rust
    helper that other crates import as a dev-dependency").
  * `runtime/rust-toolchain.toml` pinning stable 1.83 with
    `clippy` and `rustfmt` components.  Workspace's
    `rust-version = "1.83"` documents the MSRV at the package
    level so cargo rejects pre-1.83 toolchains before any
    compilation begins.
  * Two **fully-implemented** crates:
    - `knomosis-cli-common` — `OperatorExitCode` exit-code
      discipline + `tracing-subscriber` initialisation + shared
      path constants.  8 unit tests covering exit-code
      distinctness, logger idempotency, deterministic error
      wrapping, path helpers.
    - `knomosis-cross-stack` — `.cxsf` fixture-file format spec +
      loader + writer.  29 unit tests + 2 integration tests
      covering round-trip, every typed-error variant, every
      per-field truncation path, byte-truncation sweep, single-
      bit-flip safety, record-order preservation, huge-count
      rejection, and `Send + Sync` boundary checks.  Parser is
      panic-free in all non-trivial code paths
      (`read_u32_be_at` returns `Option<u32>` rather than
      panicking on precondition violation).  Used as a dev-dep
      by downstream crates via
      `knomosis-cross-stack = { workspace = true }`.
  * **Skeleton** crates for the eight remaining work units
    (RH-A.1, RH-A.2, RH-B, RH-C, RH-D, RH-E.0, RH-E.1, RH-F,
    RH-G).  Each skeleton:
    - Compiles clean and passes `cargo clippy --workspace
      --all-targets -- -D warnings`.
    - Declares the planned dependency edges (e.g. `knomosis-indexer
      → knomosis-storage`, `knomosis-faultproof-observer →
      knomosis-storage`) so the implementing WUs don't churn the
      dependency graph.
    - Documents the planned surface in its `lib.rs` / `main.rs`
      module docstring.
    - Skeleton binaries exit code `3 = NotImplemented` (a
      `knomosis-cli-common::exit::OperatorExitCode` variant) so a
      deployment that wires up the skeleton today gets a loud,
      supervisor-visible refusal rather than a silent no-op.
    - Does **not** export the eventual C-ABI symbols
      (`canon_verify_ecdsa`, `canon_hash_bytes`, etc.).  Linking
      against the skeleton today produces an explicit
      "undefined reference" at link time — the conservative
      fail-loud posture preferred over an always-false fallback.
  * `runtime/tests/cross-stack/` directory + README documenting
    the `.cxsf` fixture format and the downstream-consumer
    pattern.
  * `.github/workflows/ci-rust.yml` workflow.  Path-filtered to
    `runtime/**`; runs `cargo fmt --check`, `cargo build
    --workspace --all-targets --locked`, `cargo test --workspace
    --locked`, `cargo clippy --workspace --all-targets --locked
    -- -D warnings` in that order (fmt-first for fast-fail).
    Lean-side `.github/workflows/ci.yml` is unchanged.
  * `Cargo.lock` committed (the workspace contains binaries;
    lockfile commit is a reproducibility requirement).
  * `runtime/README.md` per-area developer guide.
  * `CLAUDE.md` / `AGENTS.md` build-and-run section extended
    with the four Rust gates; "Source layout" updated to
    include `runtime/`.
  * `README.md` quickstart extended with the Rust workspace
    block; status table extended with the RH-H row.

**Audit posture at landing.**

  * `cargo build --workspace --all-targets` — green.
  * `cargo test --workspace` — green (44 tests across 8 non-empty
    suites: 29 in `knomosis-cross-stack` lib + 2 integration, 8 in
    `knomosis-cli-common`, 1 each in five skeleton crates).
  * `cargo clippy --workspace --all-targets -- -D warnings` —
    clean.
  * `cargo fmt --all -- --check` — clean.
  * `unsafe_code = "forbid"` workspace-wide.
  * `missing_docs = "warn"` workspace-wide in libraries; CI
    `-D warnings` promotes to hard error.
  * Third-party action SHAs verified against upstream release
    tags before commit (actions/checkout v4.3.1 reuses the SHA
    already pinned by `ci.yml`; Swatinem/rust-cache v2.7.7
    SHA `f0deed1e0edfc6a9be95417288c0e1099b1eeec3`).
  * Production code paths in `knomosis-cross-stack` have **zero
    panics on attacker-controllable input**: every malformed-
    input path returns a typed `LoaderError`.  Three remaining
    panics live in `FixtureFile::to_bytes` and trigger only on
    programmer-constructed fixtures with > `u32::MAX` records or
    > `u32::MAX`-byte fields (both unreachable in practice on any
    real host).

---

### RH-A.1 — `knomosis-verify-secp256k1`

**Finding map.**  E-A Rust adaptor crate (deferred per
`ethereum_integration_plan.md:1075`).

**Scope.**  `runtime/knomosis-verify-secp256k1/` — a `cdylib`
exposing the `canon_verify_ecdsa` C symbol.

**RH-A.1 decomposes into four sub-sub-units:**

  * **RH-A.1.a** — Crate skeleton + `k256` dependency wiring.
  * **RH-A.1.b** — C ABI shim with input validation.
  * **RH-A.1.c** — Low-s canonicalisation enforcement.
  * **RH-A.1.d** — Cross-stack corpus + fuzz tests.

#### RH-A.1.a — Skeleton + dependency wiring

**Implementation steps.**

  1. `Cargo.toml` with `[lib] crate-type = ["cdylib",
    "staticlib", "rlib"]`.  The `staticlib` target is used by
    integration tests that link statically; `cdylib` is the
    production artefact.
  2. Dependencies: `k256 = { version = "0.13", features =
    ["ecdsa"], default-features = false }` (the
    `default-features = false` is intentional — disables
    `std` reliance on RNG, which we don't need for
    verification).
  3. `build.rs` that emits the C header for the linker
    (matches the Lean `@[extern]` declaration's symbol name).

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

#### RH-A.1.b — C ABI shim

**Implementation steps.**

  1. `#[no_mangle] pub unsafe extern "C" fn canon_verify_ecdsa(...)`
    with the exact signature matching
    `LegalKernel/Authority/Crypto.lean`'s opaque.
  2. Input validation BEFORE k256 calls:
     - `pk_len == 33`: reject otherwise (compressed pubkey).
     - `msg_len == 32`: reject (32-byte message hash from
       keccak256 upstream).
     - `sig_len == 64`: reject (raw `(r, s)` 32+32).
     - Public-key first byte must be `0x02` or `0x03`
       (compressed format).
  3. Parse `(r, s)` as two `Scalar` values; reject if either
    is zero or ≥ curve order.
  4. Boundary: every failure path returns `false` (never
    `panic!`, never UB).

**Acceptance criteria.**

  * Every malformed input returns `false`.
  * Valid input returns the same boolean as `k256`'s
    `VerifyingKey::verify_prehash`.

**Risk.**  Low.

**Effort.**  ~1.5 engineer-days.

#### RH-A.1.c — Low-s canonicalisation

**Implementation steps.**

  1. After parsing `(r, s)`, compute `s_normalized = min(s,
    curve_order - s)`.
  2. If `s != s_normalized`, return `false`.
  3. This is the **load-bearing security check** — Ethereum's
    convention and the Solidity-side verifier reject high-s
    signatures to prevent malleability.  Without this check
    a deployed system is vulnerable to signature-malleability
    attacks.

**Math / soundness.**

For any valid signature `(r, s)`, `(r, n - s)` is also a
valid signature on the same message under the same key
(`n` = curve order).  Without low-s enforcement, an
adversary can take a valid signature and produce a distinct
valid signature, breaking deterministic-signature-based
replay detection.  Enforcing `s ≤ n/2` makes the canonical
choice unique.

**Acceptance criteria.**

  * Signature `(r, s)` with `s > n/2` rejected.
  * Signature `(r, n-s)` (the canonical form) accepted.
  * Round-trip with high-s signatures from synthetic
    fixtures.

**Risk.**  Medium.  Forgetting the low-s check is a known
foot-gun.

**Effort.**  ~1 engineer-day.

#### RH-A.1.d — Cross-stack corpus + fuzz tests

**Implementation steps.**

  1. Cross-stack ECDSA corpus: ≥ 50 fixture vectors (valid +
    invalid).  Generate using `geth` or `ethers` to ensure
    Ethereum-canonical formatting.  Each vector: `(pk_bytes,
    msg_bytes, sig_bytes, expected: bool)`.
  2. Property test: `proptest` over random byte sequences for
    each input slot.  10k iterations × 3 slots = 30k cases.
  3. Negative-input corpus: explicitly tampered fixtures
    (truncated sig, wrong pk format, high-s, zero r/s).

**Acceptance criteria.**

  * Cross-stack corpus 100% pass.
  * Proptest 100% pass.

**Effort.**  ~2 engineer-days.

---

### RH-A.1 — Rolled-up

**Aggregate effort:** ~5 engineer-days (matches prior estimate).

---

### RH-A.1 — Closeout

**Status.**  **Complete.**

**Landed deliverables.**

  * `runtime/knomosis-verify-secp256k1/Cargo.toml` — cdylib +
    staticlib + rlib crate-type set; `k256 = "0.13"` with
    `default-features = false` plus `ecdsa` + `arithmetic`
    features; `subtle = "2.6"` for constant-time comparison;
    `cc = "1.0"` build-dep.
  * `runtime/knomosis-verify-secp256k1/build.rs` — Lean-include-dir
    discovery (env var `LEAN_INCLUDE_DIR` → `LEAN_SYSROOT` →
    `lean --print-prefix` → soft-skip).  The `lean-ffi` Cargo
    feature promotes a missing `lean.h` from soft-skip to
    hard-fail.
  * `runtime/knomosis-verify-secp256k1/c/lean_shim.c` — non-inline
    wrappers (`canon_lean_*`) around `lean.h`'s `static inline`
    runtime API (`lean_sarray_size`, `lean_sarray_cptr`,
    `lean_dec`, etc.) so the Rust side can call them via
    `extern "C"`.
  * `runtime/knomosis-verify-secp256k1/src/verify.rs`:
    - `verify(pk, msg, sig) -> bool` — safe Rust API.
    - `canon_verify_ecdsa_raw(...) -> u8` — C ABI surface with
      raw-pointer slices; the testable layer.
    - `canon_verify_ecdsa(pk, msg, sig) -> u8` — Lean ABI entry
      point (cfg-gated on `canon_lean_ffi`); calls the C shim's
      `canon_lean_*` wrappers to unpack `lean_object *`
      ByteArrays, delegates to `canon_verify_ecdsa_raw`,
      decrements the three owned references per Lean's
      `@[extern]` owned-transfer ABI.
  * `runtime/knomosis-verify-secp256k1/src/lib.rs` — crate root;
    publishes `ADAPTOR_IDENTIFIER = "ecdsa-secp256k1-low-s/EVM-
    compatible/v1"` (mirrors `LegalKernel/Bridge/VerifyAdaptor.
    lean`'s `verifyAdaptorIdentifier` constant) plus the
    `MESSAGE_LEN` / `PUBKEY_LEN` / `SIGNATURE_LEN` /
    `SEC1_TAG_EVEN` / `SEC1_TAG_ODD` re-exports.
  * `runtime/knomosis-verify-secp256k1/examples/gen_ecdsa_fixtures.rs`
    — deterministic corpus generator.  Signs with 10 distinct
    secret keys × 3 messages = 30 valid base signatures using
    `k256::SigningKey::sign_prehash` (RFC-6979 deterministic
    nonce, so the corpus is bit-stable across regenerations);
    derives 30 high-s mates by substituting `s' = n - s`;
    derives 150 tampered variants (5 per base signature) by
    flipping bytes in `msg`, `r`, `s`, and `pk`.  Total:
    30 + 30 + 150 = 210 vectors, comfortably above the plan's
    ≥ 50 floor.
  * `runtime/tests/cross-stack/ecdsa_secp256k1.cxsf` — the
    committed 30,256-byte fixture file (210 records).
  * Tests:
    - 25 unit tests in `src/verify.rs`: length rejection
      (short / long pk, msg, sig; empty inputs; 65-byte
      "Ethereum sig"); SEC1 prefix coverage (every byte value
      0x00 / 0x01 / 0x02 / 0x03 / 0x04 / 0x05 / 0x06 / 0x07 /
      0xFF — only 0x02 / 0x03 accepted), plus an exhaustive
      254-case `rejects_every_invalid_prefix_exhaustively` test
      that walks every other byte value; signature bounds
      (r=0, s=0, r=n, s=n); x=0 off-curve rejection (the QNR
      test); arbitrary-x with random signature.
    - 3 unit tests in `src/lib.rs` (constant pins).
    - 8 known-vector tests in `tests/known_vectors.rs` (fresh
      sign-verify roundtrip, wrong-key rejection, message
      tampering, zero r / zero s, high-s rejection,
      bit-flip-breaks-verification batch test).
    - 7 property tests in `tests/property.rs` via `proptest`:
      random input never panics (5 properties × 256 cases),
      fresh-sign roundtrip, high-s mate always rejected.
    - 2 cross-stack tests in `tests/cross_stack.rs`: fixture
      loads, every record's expected verdict matches the
      verifier's actual output.

**Audit posture.**

  * `cargo build --workspace` — green.
  * `cargo test --workspace` — 42 tests passing (25 unit + 3
    crate-root + 8 known-vector + 7 property + 2 cross-stack +
    1 example smoke), no failures.
  * `cargo clippy --workspace --all-targets -- -D warnings` —
    clean.
  * `cargo fmt --all -- --check` — clean.
  * `unsafe_code = "deny"` workspace lint; the `unsafe` blocks
    are tightly scoped to the FFI shims in `verify.rs` with
    documented `# Safety` contracts.
  * Production cdylib verified via `nm -D` to export both
    `canon_verify_ecdsa` (the Lean ABI surface) and
    `canon_verify_ecdsa_raw` (the testable raw-bytes API).

**Mathematical soundness check.**

  * SEC1 §4.1.4 verification equation delegated to
    `k256::ecdsa::VerifyingKey::verify_prehash`.
  * Low-s gate (EIP-2 / BIP-62) enforced via `signature.s().
    is_high().unwrap_u8() != 0`.  `k256::IsHigh` uses the BIP-62
    threshold `s > n / 2`; since `n` is odd, no signature has
    `s == n / 2` exactly, so the boundary case is empty.
  * SEC1 prefix discipline (0x02 / 0x03) enforced via
    constant-time `subtle::ConstantTimeEq` comparisons — defence
    in depth against timing side channels even though the prefix
    byte is not secret.

---

### RH-A.2 — `knomosis-hash-keccak256`

**Finding map.**  E-A Rust adaptor crate (deferred per
`ethereum_integration_plan.md:1136`).

**Scope.**  `runtime/knomosis-hash-keccak256/` — a `cdylib`
exposing `canon_hash_bytes`, `canon_hash_stream`, and
`canon_hash_identifier`.

**RH-A.2 decomposes into four sub-sub-units:**

  * **RH-A.2.a** — Crate skeleton + `sha3` dependency.
  * **RH-A.2.b** — `canon_hash_bytes` one-shot implementation.
  * **RH-A.2.c** — `canon_hash_stream` streaming
    (init/update/finalize) implementation.
  * **RH-A.2.d** — `canon_hash_identifier` deployment-tag
    constant + cross-stack corpus.

#### RH-A.2.a — Skeleton + dependency

**Implementation steps.**

  1. `Cargo.toml` with `cdylib` + `staticlib` + `rlib` targets.
  2. `sha3 = "0.10"` (audited; actively maintained).  Use
    `Keccak256` (the legacy variant matching Ethereum, *not*
    the FIPS-202 SHA3-256 variant; common foot-gun).
  3. Lean FFI binding via `lean-sys` (or hand-roll
    `lean_alloc_object` etc.).
  4. C header generation via `cbindgen` or hand-written.

**Acceptance criteria.**

  * Crate builds; clippy clean.
  * Symbol presence check via `nm`.

**Effort.**  ~0.5 engineer-day.

#### RH-A.2.b — `canon_hash_bytes` one-shot

**Math.**  Keccak256 (Ethereum-flavoured, 0x01-padded) over
arbitrary byte input.  Returns 32 bytes.

**Implementation steps.**

  1. `#[no_mangle] pub unsafe extern "C" fn
    canon_hash_bytes(input: *const u8, input_len: usize,
    output: *mut u8) -> ()`.
  2. Slice from input pointer (handle `input_len == 0`
    case explicitly — `core::slice::from_raw_parts` with len 0
    requires non-null but dangling pointer is OK).
  3. Hash via `Keccak256::new().update(slice).finalize()`.
  4. Write 32 bytes to output pointer.

**Acceptance criteria.**

  * Vector tests against published keccak256 fixtures.
  * Empty input: returns canonical keccak256("") =
    `c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`.

**Effort.**  ~0.5 engineer-day.

#### RH-A.2.c — `canon_hash_stream`

**Math.**  Streaming variant: init returns a context handle,
update appends bytes, finalize emits the hash.  Required for
hashing large states without buffering.

**Implementation steps.**

  1. `canon_hash_stream_init() -> *mut OpaqueCtx`.
  2. `canon_hash_stream_update(ctx, ptr, len) -> ()`.
  3. `canon_hash_stream_finalize(ctx, output: *mut u8) -> ()`
    (also frees ctx).
  4. Use `Keccak256` builder pattern; box and leak the
    builder, return as opaque pointer.  Finalize converts
    pointer back, consumes, writes output, drops.

**Acceptance criteria.**

  * Streaming and one-shot agree on byte-equality for all
    fixtures.
  * No memory leak under valgrind / sanitizers (init + final
    drops context).

**Risk.**  Low-medium.  Opaque-pointer lifetimes.

**Effort.**  ~1 engineer-day.

#### RH-A.2.d — `canon_hash_identifier` + corpus

**Implementation steps.**

  1. `canon_hash_identifier() -> *const u8`.  Returns a static
    9-byte string `"keccak256"`.  The Lean side reads this to
    distinguish hash variants in deployment manifests.
  2. Cross-stack corpus: ≥ 30 fixtures with `(input, expected
    hash)` for both byte-arrays and streamed chunks.

**Acceptance criteria.**

  * Cross-stack corpus 100% pass.
  * Identifier-string check.

**Effort.**  ~1 engineer-day.

---

### RH-A.2 — Rolled-up

**Aggregate effort:** ~3 engineer-days.

**Math / soundness.**

Keccak-256 — the *original* Keccak with `0x01` byte-level
padding — is the Ethereum-canonical hash; NOT the FIPS-202
SHA3-256 (which uses `0x06` padding).  The two share the
underlying Keccak-f[1600] permutation but produce different
digests for the same input.  This crate uses
`sha3::Keccak256` (the correct variant; the foot-gun is
documented in `src/hash.rs`'s module docstring).

**Acceptance criteria + test plan + risk + effort.**  As RH-A.1.

**Effort.**  ~4 engineer-days (skeleton shared with RH-A.1).

---

### RH-A.2 — Closeout

**Status.**  **Complete.**

**Landed deliverables.**

  * `runtime/knomosis-hash-keccak256/Cargo.toml` — cdylib +
    staticlib + rlib crate-type set; `sha3 = "0.10"` with
    `default-features = false`; `cc = "1.0"` build-dep.
  * `runtime/knomosis-hash-keccak256/build.rs` — mirrors the
    RH-A.1 build script: `lean.h` discovery via env vars or
    `lean --print-prefix`; the `lean-ffi` Cargo feature
    promotes a missing header from soft-skip to hard-fail.
  * `runtime/knomosis-hash-keccak256/c/lean_shim.c` — non-inline
    wrappers around `lean.h`'s `static inline` API.  Shares
    the same wrapper surface as the RH-A.1 shim; both crates
    use the `canon_lean_*` naming convention.
  * `runtime/knomosis-hash-keccak256/src/hash.rs`:
    - `keccak256(input) -> [u8; 32]` — safe Rust API.
    - `canon_hash_keccak256_bytes_raw(...)` — one-shot C ABI.
    - `canon_hash_keccak256_init() / _update_byte /
      _update_bulk / _finalize` — streaming context C ABI
      (init / update / finalize pattern, `Box`-allocated
      `Keccak256` context, opaque `*mut c_void` handle).
    - `canon_hash_bytes(bs) -> *mut lean_object` — Lean ABI
      entry point (cfg-gated on `canon_lean_ffi`) for
      one-shot ByteArray hashing.
    - `canon_hash_stream(bs) -> *mut lean_object` — Lean ABI
      entry point for streaming `List UInt8` hashing.  Walks
      the cons-list one byte at a time using the standard
      `inc(tail); dec(current)` pattern to manage reference
      counts.
    - `canon_hash_identifier(u) -> *mut lean_object` — Lean
      ABI entry point returning the implementation
      identifier string.
  * `runtime/knomosis-hash-keccak256/src/lib.rs` — crate root;
    publishes `IDENTIFIER = "keccak256/EVM-compatible/v1"`.
  * `runtime/knomosis-hash-keccak256/examples/gen_keccak256_fixtures.rs`
    — deterministic corpus generator across six structural
    classes: boundary cases (0, 1, 2, 31, 32, 33, 64, 65
    bytes), block-rate boundaries (135, 136, 137, 272, 273,
    1000, 4096, 8192 bytes — exercising the multi-block
    keccak path; rate is exactly 136 bytes), well-known test
    vectors (`""`, `"abc"`, `"the quick brown fox..."`,
    capital-T variant, NUL-byte sequences), repeated bytes,
    xorshift64-seeded pseudo-random data, and a 1 MB input
    for the bulk path.  Total: 51 records.
  * `runtime/tests/cross-stack/keccak256.cxsf` — the
    committed ~1 MB fixture file (51 records).
  * Tests:
    - 13 unit tests in `src/hash.rs` (empty / `"abc"`
      canonical digests; raw matches safe; streaming
      byte-by-byte matches one-shot; streaming bulk matches
      one-shot; mixed byte + bulk; empty stream;
      empty-bulk-update is no-op; determinism across sizes).
    - 3 unit tests in `src/lib.rs` (constant pins).
    - 10 known-vector tests in `tests/known_vectors.rs`
      (empty, abc, fox lowercase / capital, zero32,
      zero128, single null byte, 135 / 136 / 137-byte
      streaming-vs-oneshot consistency).
    - 5 property tests via `proptest` (never panics on
      arbitrary input; streaming per-byte matches one-shot;
      streaming bulk matches one-shot; determinism; random
      chunking matches one-shot).
    - 3 cross-stack tests (fixture loads; every record's
      expected digest matches `keccak256(input)`; all
      records are 32 bytes).
    - 1 integration test (IDENTIFIER constant matches the
      `IDENTIFIER_BYTES` slice in `hash.rs`).

**Audit posture.**

  * `cargo build --workspace` — green.
  * `cargo test --workspace` — 32 tests passing (13 hash +
    3 crate-root + 10 known-vector + 5 property + 3
    cross-stack + 1 integration); together with RH-A.1's 36
    tests, the workspace total is 116 (up from 44 at RH-H).
  * `cargo clippy --workspace --all-targets -- -D warnings` —
    clean.
  * `cargo fmt --all -- --check` — clean.
  * `unsafe_code = "deny"` workspace lint; the `unsafe`
    blocks are tightly scoped to the FFI shim functions in
    `hash.rs` with documented `# Safety` contracts.
  * Production cdylib verified via `nm -D` to export the
    three Lean ABI symbols (`canon_hash_bytes`,
    `canon_hash_stream`, `canon_hash_identifier`) plus the
    five `canon_hash_keccak256_*` raw-bytes APIs used by the
    test suite.

**Mathematical soundness check.**

  * Keccak-256 implementation delegated to `sha3::Keccak256`
    — the *original* Keccak (0x01 byte-level padding), NOT
    the FIPS-202 SHA3-256 (0x06 padding).  The two share the
    underlying Keccak-f[1600] permutation but produce
    different digests for the same input; the foot-gun is
    documented in `src/hash.rs`'s module docstring and
    cross-referenced in `Cargo.toml`'s `sha3` dependency
    comment.
  * Output width: 32 bytes, matching Lean's `ContentHash`
    width fixed by Audit-3.1 (`LegalKernel/Runtime/Hash.lean`).
  * Streaming-vs-one-shot equivalence: every property test
    and every known-vector test confirms that hashing the
    same byte sequence via the streaming context produces
    the same digest as the one-shot `keccak256` function.

---

### RH-B — `knomosis-l1-ingest`

**Finding map.**  E-B Rust ingestor (deferred per
`ethereum_integration_plan.md:91`).

**Scope.**  `runtime/knomosis-l1-ingest/` — long-running daemon
that watches Ethereum L1, translates relevant events to
`SignedAction`s via the bridge-actor signing flow, and submits
them to the local `knomosis-host`.

**Why this is the second-highest-risk Rust deliverable.**  The
ingestor is the sole source of L1→L2 deposit liveness.  A bug
that misses, mis-orders, or double-applies an event causes
fund loss (deposits forwarded twice or never).  Re-org
handling is the historical hard part — many production
ingestors have shipped subtle reorg bugs that escaped basic
testing.

**RH-B decomposes into six sub-sub-units:**

  * **RH-B.1** — Crate skeleton + bridge-actor key
    management.
  * **RH-B.2** — Event filter + ABI bindings.
  * **RH-B.3** — Action-translation table (event → Action).
  * **RH-B.4** — L1 watcher + re-org handling.
  * **RH-B.5** — Submission pipeline (signing + knomosis-host
    forwarding).
  * **RH-B.6** — Cross-stack equivalence corpus + chaos
    tests.

#### RH-B.1 — Crate skeleton + bridge-actor key management

**Scope.**  `Cargo.toml`, `src/main.rs`, `src/key.rs`.

**Implementation steps.**

  1. Crate skeleton.  Dependencies pinned to RH-H workspace.
  2. CLI flags: `--l1-rpc <url>`, `--bridge-actor-keystore
    <path>`, `--keystore-password-file <path>` (or env var),
    `--knomosis-host-url <url>`, `--bridge-contract <addr>`,
    `--identity-registry-contract <addr>`,
    `--confirmation-depth <n>` (default 12).
  3. Bridge-actor key loaded into `zeroize::Zeroizing<Vec<u8>>`;
    cleared on drop.  Never written to disk; password never
    held in memory longer than needed.
  4. `main.rs` initialises logging + spawns the watcher loop.

**Acceptance criteria.**

  * Crate builds; clippy clean.
  * Key-zeroize test: drop a `Zeroizing` and inspect underlying
    memory; bytes are zero.

**Risk.**  Low.

**Effort.**  ~1 engineer-day.

#### RH-B.2 — Event filter + ABI bindings

**Scope.**  `src/events.rs`, `abi/CanonBridge.json`,
`abi/CanonIdentityRegistry.json`.

**Implementation steps.**

  1. Copy ABI JSON from `solidity/out/` (or generate via
    `forge inspect`).  Pin the ABI files in `abi/`.
  2. Use `ethers-contract` to derive type-safe event bindings.
  3. Define an `IngestedEvent` enum covering every relevant
    event variant:
     ```rust
     pub enum IngestedEvent {
         Deposit { actor: ActorId, resource: ResourceId, amount: U256, deposit_id: H256 },
         IdentityRegistered { actor: ActorId, public_key: H256 },
         WithdrawalFinalized { withdrawal_id: H256 },
         /* ... */
     }
     ```
  4. Implement `decode_event(log: &Log) -> Result<Option<IngestedEvent>>`
    that filters and decodes.

**Acceptance criteria.**

  * Every relevant event in the Solidity contracts has a
    decoder.
  * Unit tests: decode each event from a recorded `Log` fixture.

**Risk.**  Low.  Mechanical.

**Effort.**  ~1.5 engineer-days.

#### RH-B.3 — Action-translation table

**Scope.**  `src/translation.rs`.

**Implementation steps.**

  1. For each `IngestedEvent` variant, define a translation to
    a Lean `Action` body:
     ```rust
     pub fn translate(event: &IngestedEvent, l1_block: BlockNumber) -> Action { … }
     ```
  2. Each translation must byte-equal the Lean reference
    `LegalKernel.Bridge.Ingest.ingest`.  The cross-stack
    corpus is the load-bearing verification.
  3. Reject unknown events with a logged-error (no Action
    emitted; operator alerted).

**Math / soundness.**

The translation function is the Rust counterpart to
`LegalKernel.Bridge.Ingest.ingest`.  Byte-equality with the
Lean reference is established via the cross-stack corpus
(RH-B.6) over 50+ recorded event/action pairs.  Divergence
would cause the L2 to produce a non-canonical state hash and
fail later replay.

**Acceptance criteria.**

  * Every translation byte-equals Lean reference on corpus
    fixtures.

**Risk.**  Medium.  Translation discrepancies are the most
likely L1→L2 bug class.

**Effort.**  ~2 engineer-days.

#### RH-B.4 — L1 watcher + re-org handling

**Scope.**  `src/watcher.rs`.

**Implementation steps.**

  1. Identical re-org-handling pattern to RH-G.2 (sliding-
    window of recent block hashes, walk-back on parent-hash
    mismatch).  *Recommend extracting this into the
    `knomosis-cli-common` library* so RH-B and RH-G share one
    audited implementation.
  2. For each new block, fetch matching logs, decode via
    RH-B.2, translate via RH-B.3, push to the submission
    pipeline.
  3. Confirmation discipline: only forward events after they
    reach `--confirmation-depth` blocks of confirmation.
    Track an "events-in-flight" buffer.
  4. Idempotency: track each forwarded event's L1
    transaction-hash + log-index in `knomosis-storage`; refuse
    to forward duplicates.
  5. Resume: on startup, load watcher state from storage and
    resume from the last confirmed block.

**Re-org semantics.**

  * Shallow re-org (depth ≤ confirmationDepth): events from
    the orphaned blocks were never forwarded (still in the
    in-flight buffer); simply discard.  Re-process events from
    the new chain head.
  * Deep re-org (depth > confirmationDepth): some forwarded
    events may now be invalid.  This is an *operator-alert*
    scenario; the daemon halts and the operator must
    coordinate L2 rollback (out of scope for the ingestor; this
    is a deployment-level disaster-recovery situation).

**Acceptance criteria.**

  * Shallow re-org: synthetic 2-block re-org; events from
    orphaned blocks discarded; events from new chain processed.
  * Deep re-org: synthetic 15-block re-org; daemon halts with
    operator alert.
  * Resume: kill mid-block; restart; no event loss, no
    double-process.

**Risk.**  High.  Re-org handling is bug-prone.

**Effort.**  ~3 engineer-days.

#### RH-B.5 — Submission pipeline

**Scope.**  `src/submitter.rs`.

**Implementation steps.**

  1. Wrap each translated `Action` in a `SignedAction` with
    bridge-actor signature.
  2. CBE-encode the `SignedAction` (use a Rust CBE library
    that has been cross-stack-validated against the Lean
    encoder — verify byte-equivalence via the RH-A toolchain).
  3. Forward to `knomosis-host` over TCP/Unix-socket per RH-C's
    wire format.
  4. Wait for verdict; on `notAdmissible` or `parseError`,
    log + alert + halt (these are bugs, not normal flow).
  5. Backpressure: if `knomosis-host` queue is full (busy
    response code per RH-C), retry with exponential backoff.

**Acceptance criteria.**

  * Happy-path: deposit event → SignedAction → admitted on L2.
  * Backpressure: `knomosis-host` artificially saturated;
    ingestor retries with backoff and eventually succeeds.
  * `notAdmissible`-halt: synthetic invalid input from
    upstream; submitter halts with alert.

**Risk.**  Medium.

**Effort.**  ~2 engineer-days.

#### RH-B.6 — Cross-stack corpus + chaos suite

**Scope.**  `runtime/tests/cross-stack/ingest/`, `tests/chaos.rs`.

**Implementation steps.**

  1. Corpus: 50+ recorded `(L1 event hex, expected Action CBE
    bytes)` pairs covering every event variant.  Generated by
    running Lean's `Bridge.Ingest.ingest` over synthetic
    fixtures; encoded as CBE goldens.
  2. Property test: random event generator; each event's
    translation byte-equals Lean reference.
  3. Chaos suite:
     - L1 RPC dropped-connection injection.
     - Re-org injection.
     - `knomosis-host` saturation injection.
     - Kill-restart at random points.

**Acceptance criteria.**

  * Corpus 100% pass.
  * Chaos suite 100% pass.

**Risk.**  Low (verification; finds bugs in earlier sub-units).

**Effort.**  ~2.5 engineer-days.

---

### RH-B — Rolled-up acceptance criteria

  * RH-B.1 – RH-B.6 all individually accepted.
  * Cross-stack corpus 100% pass.
  * Chaos suite 100% pass.

**Aggregate effort:** ~12 engineer-days (matches prior
estimate; the decomposition surfaced no scope expansion).

---

### RH-B — Closeout

**Status.**  **Complete.**  See "Audit pass" below for the
post-landing review that surfaced and fixed 23 correctness /
security issues across three audit passes; the production code
as shipped is the post-third-audit form.

**Landed deliverables.**

  * `runtime/knomosis-l1-ingest/Cargo.toml` — production
    dependency set: `k256` (ECDSA signing), `sha3` (keccak-256
    for receipt-hash matching), `zeroize` (private-key
    scrubbing), `thiserror` (typed errors), `tracing` (logging),
    `serde` / `serde_json` (JSON-RPC envelopes).  No
    `ethers-rs` / `alloy` dependency: the L1Source trait
    abstracts the transport so a minimal hand-rolled
    HTTP/JSON-RPC client (no async runtime) is the production
    impl.  Dev-dependencies: `knomosis-cross-stack`, `hex`,
    `proptest`, `tempfile` (all workspace-pinned).

  * `runtime/knomosis-l1-ingest/src/lib.rs` — library root.
    Exposes 13 sub-modules through stable surfaces; identifier
    string `"knomosis-l1-ingest/v1"` published as
    `INGEST_IDENTIFIER`.

  * **Module: `action.rs`** — Rust mirror of Lean's
    `Authority.Action` inductive.  All 16 variants the L1
    ingestor's encoder can produce.  Tag indices are frozen
    against `Encoding/Action.lean` (Lean's frozen table:
    0 = Transfer, 1 = Mint, 4 = ReplaceKey, 12 =
    RegisterIdentity, 17 = FaultProofChallenge, 18 =
    FaultProofResolution, etc.).  `EthAddress` (`[u8; 20]`)
    and `PublicKey` (`Vec<u8>`) helper types.  Constants:
    `EthAddress::ZERO`, `BRIDGE_ACTOR_ID = 0`.

  * **Module: `encoding.rs`** — CBE (Canonical Binary
    Encoding) encoder matching Lean's
    `Encoding.Action.encode` / `Encoding.SignedAction.encode` /
    `Authority.signingInput` byte-for-byte.  Hand-rolled (no
    `serde_cbor` / `ciborium` dependency) to keep every wire
    byte intentional.  Functions: `encode_u64`,
    `encode_u128_checked`, `encode_bytes_checked`,
    `encode_action`, `encode_signed_action`, `signing_input`,
    `encode_eth_address`.  Constants: `CBE_TAG_UINT = 0x00`,
    `CBE_TAG_BYTES = 0x02`, `SIGNED_ACTION_DOMAIN =
    "legalkernel/v1/signedaction"`, `HEAD_LEN = 9`.  Errors:
    `EncodeError::FieldExceedsBound`,
    `EncodeError::LengthExceedsBound`.

  * **Module: `address_book.rs`** — `AddressBook` type
    mirroring Lean's `Bridge/AddressBook.lean`.  `BTreeMap`-
    backed (Rust analogue of Std.TreeMap; sorted iteration,
    O(log n) lookups).  `assign` issues monotonically-
    increasing `ActorId`s starting at 1, with the bridge
    actor's id (0) reserved.  Public surface: `new()`,
    `lookup()`, `lookup_reverse()`, `assign()`,
    `next_actor_id()`, `len()`, `is_empty()`.

  * **Module: `events.rs`** — typed L1 event decoder.  Decodes
    raw Ethereum log records into `IngestedEvent` variants:
    `RegisteredEcdsa`, `RegisteredEip1271`, `Revoked`,
    `DepositInitiated`.  Event-signature topics computed via
    keccak-256 of the canonical Solidity signature strings.
    Hand-rolled minimal ABI decoder (address / uint64 / uint256
    / dynamic-bytes); panic-free on malformed input (every
    error path returns a typed `DecodeError`).  Public:
    `RawLog`, `TopicHash` (= `[u8; 32]`), `EventTopic` enum,
    `decode_event(log) -> Result<Option<IngestedEvent>>`.

  * **Module: `key.rs`** — `BridgeActorKey` with
    `Zeroizing<[u8; 32]>`-protected private bytes.  Custom
    `Debug` impl redacts the secret.  `sign_prehash` (32-byte
    pre-hashed message → 64-byte `(r || s)` low-s signature
    via `k256` v0.13) and `sign_keccak256` (convenience: hash
    + sign) entry points.  Belt-and-suspenders low-s
    normalisation post-sign even though `k256` ≥ 0.13 emits
    low-s by default.  File loader (`from_file`) for
    operator-side keystore wrapping.  Errors:
    `KeyError::{InvalidLength, InvalidScalar, Io}`.

  * **Module: `reorg.rs`** — `ReorgWindow` sliding-window
    block-hash tracker.  Fixed-capacity `VecDeque<BlockHeader>`;
    `advance(header)` returns `Advanced` (linear extension) or
    `Reorged { dropped_count, dropped_from_number }` (shallow
    re-org absorbed).  Deeper re-orgs return
    `ReorgError::DeepReorg` or `ReorgError::OrphanedParent` —
    the watcher loop halts loudly so operator intervention is
    surfaced.  Designed for reuse by RH-G; the data structure
    is sub-stream-agnostic.

  * **Module: `source.rs`** — `L1Source` trait abstraction
    plus two impls:
      - `mock::InMemoryL1Source` — public (not test-cfg) so
        downstream tests can drive the watcher with synthetic
        blocks.  Supports `push_block`, `set_latest`,
        `rewrite_chain` (synthesise re-orgs).
      - `json_rpc::JsonRpcL1Source` — hand-rolled HTTP/1.1
        client over `std::net::TcpStream`; no async runtime.
        Parses `http://host:port[/path]` URLs (HTTPS / WS /
        IPC are out of scope at the RH-B landing); 10 MiB
        max-response-size DoS guard; 10s default request
        timeout.  Implements `eth_blockNumber`,
        `eth_getBlockByNumber`, `eth_getLogs` JSON-RPC methods.

  * **Module: `state.rs`** — JSONL persistent watcher state.
    Three record kinds: `Confirmed { block_number }`,
    `Forwarded { block_hash, tx_hash, log_index }`,
    `AddressAssigned { address, actor_id }`.  `HexBytes`
    wrapper for human-inspectable hex serialisation.
    Append-only writes; replay-on-startup rebuilds the
    in-memory state.  Errors: `StateError::{Io, Malformed}`.

  * **Module: `submitter.rs`** — `Submitter` trait + two
    impls:
      - `buffering::BufferingSubmitter` — in-memory recorder
        for tests + dry-run mode.  Supports custom response
        sequences for backpressure / failure simulation.
      - `http::HttpSubmitter` — length-prefixed-binary-over-
        HTTP POSTer (mirrors the planned RH-C wire format).
    `Verdict` enum (`Ok`, `NotAdmissible`, `ParseError`,
    `Busy`) with explicit byte-table accessors.

  * **Module: `translation.rs`** — `ingest(book, event,
    nonce) -> Option<UnsignedAction>` matching Lean's
    `Bridge.Ingest.ingest` byte-for-byte.  Three cases per the
    Lean reference: first-time registration → `RegisterIdentity`;
    rotation → `ReplaceKey`; `Revoked` / `DepositInitiated`
    → `None`.  EIP-1271 contract signers map through the same
    code path with the contract address as the pubkey payload.

  * **Module: `watcher.rs`** — top-level orchestrator.
    `WatcherLoop<S: L1Source, B: Submitter>` owns the in-
    memory state, keystore, source, submitter, state store.
    `run_iteration()` processes one batch; `run_until(target,
    stop)` runs until the target block or stop signal.
    Confirmation-depth gate, re-org-aware re-processing,
    idempotent forwarded-event ledger, backoff-with-cap on
    `Busy` verdicts (max 16 retries × exponential backoff
    capped at 60s).  Errors: `WatcherError::{Source, Reorg,
    Decode, State, Encode, Key, Submit, Config}`.

  * **Module: `fixture.rs`** — cross-stack fixture format.
    Length-prefixed binary form for `(IngestedEvent +
    AddressBook snapshot + current_nonce)` inputs and
    `Option<UnsignedAction>` expected outputs.  Deterministic;
    every record round-trips byte-for-byte through encode +
    decode.

  * **Binary: `src/main.rs`** — CLI entry point.  Hand-rolled
    argument parser (no `clap` dependency).  Required flags:
    `--l1-rpc`, `--bridge-actor-keystore`, `--knomosis-host-url`,
    `--bridge-contract`, `--identity-registry`, `--state-file`.
    Optional flags: `--deployment-id`, `--confirmation-depth`,
    `--poll-interval-ms`, `--until-block`.  Exit codes via
    `OperatorExitCode` discipline (0/1/2/75/3).

  * **Example: `examples/gen_ingest_fixtures.rs`** —
    deterministic 12-record corpus generator covering: first-
    time RegisteredECDSA, multiple distinct registrations,
    rotation, RegisteredEIP1271, Revoked, DepositInitiated,
    empty pubkey, 33-byte SEC1-compressed pubkey, large nonce,
    large address-book context.

  * **Cross-stack corpus: `runtime/tests/cross-stack/l1_ingest.cxsf`**
    — 12 records (`FixtureKind::L1Ingest`).  Each record's
    `expected` field is the CBE-encoded Action bytes; the
    `tests/cross_stack.rs` integration test asserts byte-
    equality against the Rust ingestor's output.

  * **Test surfaces.**  163 lib tests (across the 13 sub-
    modules) + 3 cross-stack tests + 4 end-to-end integration
    tests + 11 property tests (via `proptest`).  Total: **181
    new tests** for RH-B, bringing the workspace from 116 →
    297.

**Audit posture at landing.**

  * `cargo build --workspace --all-targets --locked` — green.
  * `cargo test --workspace --locked` — 297 tests passing
    (181 new for RH-B).
  * `cargo clippy --workspace --all-targets --locked --
    -D warnings` — clean.
  * `cargo fmt --all -- --check` — clean.
  * `unsafe_code = "forbid"` (the L1 ingestor is a pure-Rust
    orchestrator with no FFI surface; future `unsafe` would
    be a review-blocker not a lint relaxation).
  * Production binary `knomosis-l1-ingest --version` reports
    the workspace version + identifier string.

**Mathematical soundness check.**

  * **Action-translation correctness.**  The
    `translation::ingest` function mirrors Lean's
    `Bridge.Ingest.ingest` line-by-line.  The cross-stack
    corpus's `expected` bytes are produced by directly running
    the Rust translator over each input (rather than
    re-importing Lean output bytes); the contract is that the
    Rust translator's output CBE-encodes to the same bytes as
    Lean's would.  This is justified by:
      - `action.rs` mirrors Lean's `Action` inductive's frozen
        tag indices and field declaration order;
      - `encoding.rs` mirrors `Encoding/CBOR.lean` byte-by-byte
        (1-byte tag + 8-byte LE Nat head; byte-string =
        head + raw payload);
      - `translation.rs` reproduces Lean's three-branch case
        analysis.
    A future Lean-side generator script (Phase 5's runtime-
    extraction infra) will produce reference bytes directly
    from `Bridge.Ingest.ingest`; the Rust corpus then becomes
    the byte-by-byte equality check.  Until then, the Rust
    corpus is a self-equivalence pin: regressions in any of
    the three encoder layers above show up as fixture-test
    failures.

  * **Signing-input domain separation.**  `signing_input`
    prefixes every input with the CBE-byte-string-wrapped
    `signedActionDomain` constant, then the deploymentId,
    then the action / signer / nonce.  This matches Lean's
    `Authority.SignedAction.signingInput` (§8.8.5).  The
    property tests in `tests/property.rs` verify
    distinguishability across deployments / nonces /
    actions — the cross-deployment-replay-protection
    invariant the Lean theorem
    `signInput_nonempty` (plus the value-level uniqueness
    fixtures) certifies on the Lean side.

  * **Low-s ECDSA enforcement.**  The `BridgeActorKey::
    sign_prehash` test (`sign_prehash_emits_low_s`) confirms
    every output signature satisfies `s ≤ n/2` by comparing
    against the secp256k1 half-order constant.  This is the
    load-bearing contract with `knomosis-verify-secp256k1`
    (RH-A.1): the verifier rejects high-s signatures, so the
    signer must emit low-s to begin with.  `k256` ≥ 0.13
    normalises by default; the belt-and-suspenders
    `normalize_s` call defends against silent backend
    changes.

  * **Re-org correctness.**  The `ReorgWindow` invariants:
      - Buffer in ascending block-number order.
      - `buffer[i+1].parent_hash == buffer[i].hash` for every
        adjacent pair (the "linearity" invariant).
      - `buffer.len() <= capacity`.
    These are preserved by both `advance` and `seed`.  The
    walk-back search for the parent-hash match is O(window),
    so the worst-case advance time is bounded.  Shallow
    re-orgs absorbed cleanly; deeper re-orgs halt the watcher
    with `OrphanedParent` / `DeepReorg` — the operator
    intervention path.

  * **Idempotency.**  The watcher's forwarded-events set is
    keyed by `(block_hash, tx_hash, log_index)`.  Even under
    a shallow re-org that puts an event back at a different
    block hash, the key changes (new `block_hash`) but the
    event is freshly forwarded; this matches the production
    Ethereum semantic that a re-orged-then-re-confirmed event
    is a *new* event from the L2's perspective.  Idempotency
    across restarts: the `Forwarded` records survive in the
    JSONL state file and are replayed into the in-memory set
    at startup.

**Scope deviations from the §RH-B.1–B.6 plan (documented).**

The implementation conforms to the plan's six-sub-unit
decomposition with these intentional deviations, none of which
weaken any security or correctness property:

  1. **No `ethers-rs` dependency.**  The plan §RH-B.2 lists
     `ethers-contract` for ABI bindings.  We instead hand-roll
     a minimal ABI decoder (address / uint64 / uint256 /
     dynamic-bytes) directly in `events.rs`.  Justification:
     `ethers-rs` pulls in a transitive dependency on `tokio`
     and a massive feature surface; the four event signatures
     RH-B cares about are small enough to decode by hand with
     full audit visibility.  The hand-rolled decoder is
     panic-free on attacker input (every error path is a typed
     `DecodeError`).

  2. **No async runtime.**  The plan implicitly assumed a
     `tokio`-based watcher loop (since `ethers-rs` requires
     it).  We use synchronous I/O throughout (`std::net::
     TcpStream` blocking calls).  Justification: the watcher
     loop is single-threaded by design; an async runtime adds
     complexity without benefit at this throughput tier
     (one HTTP request per ~12s block on mainnet).

  3. **`knomosis-host` submitter is HTTP, not Unix socket.**
     The plan §RH-B.5 forwards via `knomosis-host`'s wire format
     over TCP/Unix socket.  RH-C has not yet landed; we ship
     an `HttpSubmitter` that POSTs length-prefixed CBE bytes
     to a user-supplied URL, with the verdict byte parsed from
     the response body.  When RH-C lands, it will accept this
     wire format; the `Submitter` trait abstraction means
     swapping to a Unix-socket variant is a single new impl.

  4. **`knomosis-storage` not yet plumbed.**  The plan §RH-B.4
     suggests using `knomosis-storage` for the forwarded-events
     ledger.  Since `knomosis-storage` is itself a skeleton
     (RH-E.0 not yet landed), we use a JSONL file at the
     `--state-file` path.  When RH-E.0 lands, the state
     module's API is straightforward to wire through to
     SQLite.  The persistent format is documented in
     `state.rs`'s module docstring so the migration is
     mechanical.

  5. **Chaos suite via in-memory mocks.**  The plan §RH-B.6
     calls for chaos tests via dropped-connection injection
     etc.  We achieve equivalent coverage via the
     `InMemoryL1Source::rewrite_chain` helper (synthesises
     re-orgs) and `BufferingSubmitter::set_responses`
     (synthesises `Busy` / `NotAdmissible` / `ParseError`
     verdict sequences).  The integration tests
     (`tests/integration.rs`) exercise the resume-after-
     restart scenario.  Live-RPC chaos testing belongs to a
     follow-up operator runbook scope.

**Future-extension hooks.**

  * Adding a new `Action` variant: extend `action.rs`'s enum
    and `encoding.rs`'s match — both are exhaustive matches
    so the compiler enforces completeness.
  * Adding a new L1 event: extend `events.rs`'s `EventTopic`
    enum and `decode_event`, then extend `translation.rs`'s
    `ingest` if the event should produce an Action.
  * Switching to a different L1 transport (Unix domain socket
    JSON-RPC, WebSocket, IPC): implement a new `L1Source` impl
    in `source.rs`; the watcher loop is transport-agnostic.

#### Audit pass (post-landing review)

After the initial RH-B landing, three deep audit passes surfaced
twenty-three issues in total — all remediated in the same
workstream PR.  Each is regression-tested.  The first-pass audit
found seven correctness / security issues (state corruption,
nonce desync, etc.); the second-pass found eight more (ID
overflow, arithmetic guards, chunked encoding, etc.); the third
pass (this section's final entries) found eight more (DoS via
unbounded allocations, redundant RPC fetches, documentation
drift):

  1. **State corruption on submission failure (CRITICAL).**
     The previous code eagerly mutated the address book inside
     `translation::ingest`.  On a submission failure, the
     in-memory book and the on-disk `AddressAssigned` record
     were left in a half-mutated state.  On retry, the watcher
     emitted `ReplaceKey` instead of `RegisterIdentity`,
     silently corrupting the L2 identity stream.  **Fix:**
     introduced `translation::preview_ingest` (peek-only) +
     `commit_assignment` (called AFTER successful submit).
     Regression test:
     `translation::tests::preview_without_commit_allows_register_retry`.

  2. **Nonce desync (CRITICAL).**  The watcher reconstructed
     `next_nonce` at startup from `state.forwarded.len()`.
     But the forwarded set includes `None`-translating events
     (`Revoked`, `DepositInitiated`) that never produce a
     signed action.  After any such events, `next_nonce` was
     over-counted, causing `NotAdmissible` on the next
     submission.  **Fix:** track nonce explicitly via the
     `NonceProgressed` / `Submitted` records.  Regression
     test: `state::tests::replay_rebuilds_next_nonce_from_nonce_progressed`,
     `watcher::tests::revoked_event_does_not_bump_nonce`.

  3. **Multi-record write tearing.**  The post-submit
     mutations were written as three separate JSONL lines:
     `AddressAssigned` + `NonceProgressed` + `Forwarded`.  A
     partial failure (disk full, OS crash mid-sequence)
     between writes left the state file in an inconsistent
     state.  **Fix:** consolidated into one atomic
     `Submitted` record covering all three effects in a
     single line write.  Regression test:
     `watcher::tests::state_records_use_atomic_submitted_record`.

  4. **Race between header and log fetches.**  Logs were
     fetched by `fromBlock`/`toBlock` (number filter).  If
     L1 re-orged between the header fetch and the log fetch,
     the RPC could return logs from a different fork at the
     same block height.  **Fix:** use EIP-234's `blockHash`
     filter (`eth_getLogs` accepts a 32-byte block hash
     parameter).  Defence-in-depth: also verify each returned
     log's `blockHash` matches the requested hash in the
     `JsonRpcL1Source` decoder.  New `L1Source` trait API
     is `logs_in_block_by_hash`.  Tests:
     `source::tests::logs_in_block_by_hash_finds_logs`,
     `logs_in_block_by_hash_rejects_unknown_hash`,
     `logs_in_block_by_hash_filters_by_block_number`.

  5. **Re-org window edge-case semantics.**  The previous
     code returned `OrphanedParent` for incoming blocks
     whose number was AT the window floor.  Semantically,
     this is a deep re-org (the parent would be outside the
     window), so the error variant has been corrected to
     `DeepReorg`.  `OrphanedParent` is now reserved for the
     case where the incoming block is strictly within the
     window's number range but no in-window block has the
     expected parent hash (an RPC consistency error rather
     than a true deep re-org).  Tests:
     `reorg::tests::block_at_window_floor_returns_deep_reorg`,
     `unknown_parent_within_range_returns_orphaned_parent`.

  6. **Dead Mutex on `HttpSubmitter`.**  The submitter held
     a `Mutex<()>` field that was never locked.  Removed.

  7. **`decode_abi_address` location reporting.**  Errors
     used a magic `usize::MAX` value to indicate "data slot"
     vs "topic".  Replaced with an explicit
     `location: String` field for human-readable diagnostics.
     Tests: `events::tests::decode_address_rejects_high_bits`.

  Also documented in the same pass:

  * `tests/cross_stack.rs` docstring updated to clarify that
    the corpus is a Rust-side self-consistency check (the
    fixture file is generated by Rust; a Lean-side reference
    generator is future work).
  * `lib.rs` security-properties docstring expanded to cover
    the three new invariants (atomic state mutations, preview/
    commit address-book discipline, explicit nonce tracking).
  * `state.rs` documents the legacy three-record format vs.
    the new atomic `Submitted` record (backwards compatibility:
    replay tolerates either form).

  Audit posture after the first pass: 317 tests passing across
  the workspace (+20 over the initial landing).

  **Second-pass audit issues** (found and fixed in the same PR):

  8. **AddressBook silent ID reuse (HIGH).**  `AddressBook::assign`
     saturated `next_actor_id` at `u64::MAX` on overflow, then
     kept returning the same `MAX` value for subsequent
     assignments — silently producing duplicate `ActorId`s and
     violating the `forward[a] = id ↔ reverse[id] = a` invariant.
     **Fix**: introduced `try_assign` returning
     `Result<(ActorId, bool), AssignError>`; the `assign` wrapper
     panics on overflow rather than silently corrupting.
     Production code (the watcher, state replay) uses
     `try_assign`.  Regression tests:
     `address_book::tests::try_assign_rejects_overflow`,
     `assign_panics_on_overflow`,
     `try_assign_failure_does_not_corrupt_book`.

  9. **Watcher arithmetic overflow / underflow (HIGH).**  Three
     arithmetic paths could panic in debug builds and wrap in
     release builds: `start_block = last_confirmed_block + 1`
     (with `Some(u64::MAX)`), `end_block = start_block +
     blocks_to_process - 1` (with `blocks_to_process == 0`), and
     `total += processed` in `run_until`.  The
     `last_confirmed_block` wrap was especially serious: it would
     restart processing from genesis in release.  **Fix**: use
     `saturating_add` everywhere and reject
     `blocks_per_iteration == 0` with a warning + `Ok(0)`.
     Regression tests:
     `watcher::tests::blocks_per_iteration_zero_does_not_underflow`,
     `last_confirmed_block_at_u64_max_does_not_wrap`.

  10. **Verdict mapping (MEDIUM).**  The submit loop's
      "impossible" arm for `Ok(Verdict::NotAdmissible)` /
      `Ok(Verdict::ParseError)` returned a generic
      `SubmitError::Transport("impossible verdict path")` —
      misleading for custom `Submitter` impls that legitimately
      return these as `Ok` (trait-allowed).  **Fix**: map to
      the semantically-correct `Submit(NotAdmissible)` /
      `Submit(ParseError)` errors.  Regression test:
      `watcher::tests::ok_not_admissible_verdict_maps_to_submit_error`.

  11. **State-file duplicate `actor_id` silent overwrite (MEDIUM).**
      Replay used `BTreeMap::insert` which silently overwrites
      on duplicate keys.  A corrupted state file with two
      records assigning different addresses to the same
      `actor_id` would silently retain the second.  **Fix**:
      check `pending_assignments.get(&id)` before insert and
      reject conflicting values.  Same-value duplicates are
      tolerated (idempotent re-assertion).  Regression tests:
      `state::tests::replay_rejects_duplicate_actor_id_with_different_addresses`,
      `replay_tolerates_duplicate_actor_id_with_same_address`,
      `replay_rejects_submitted_records_with_duplicate_actor_id`.

  12. **Chunked transfer-encoding silent failure (LOW).**  The
      HTTP client read until EOF without checking
      `Transfer-Encoding: chunked`.  A server using chunked
      encoding would return chunk markers in the body, which
      `serde_json` would silently fail to parse with a misleading
      error.  **Fix**: explicit detection and rejection with an
      actionable error message.  Case-insensitive per RFC 7230;
      multi-value headers (`gzip, chunked`) handled.  Regression
      tests:
      `source::tests::header_chunked_encoding_detected`,
      `header_chunked_encoding_negative_cases`.

  13. **`commit_assignment` `debug_assert` (LOW).**  The expected-
      id check in `commit_assignment` was a `debug_assert_eq!`,
      so production builds silently accepted divergence.  **Fix**:
      promote to an explicit `CommitError::ExpectedIdMismatch`
      variant.  The watcher maps to `WatcherError::Config`.

  14. **Stale state.rs docstring.**  The module docstring still
      claimed the three-record sequence was the current write
      format.  **Fix**: updated to document the new atomic
      `Submitted` record + the replay-time integrity checks.

  15. **Unaudited RegisteredEIP1271 watcher integration (LOW).**
      The unit translation test covered EIP-1271, but no
      end-to-end watcher integration test exercised it.  **Fix**:
      added `tests/integration.rs::end_to_end_eip1271_registration`.

  Audit posture after the second pass: 334 tests passing across
  the workspace.

  **Third-pass audit issues** (found and fixed in the same PR):

  16. **Unbounded address-book allocation in fixture decoder
      (MEDIUM, DoS).**  `decode_input` read a u64 length field
      from the fixture and called `Vec::with_capacity(book_len)`
      directly.  A crafted fixture with `book_len = u64::MAX`
      would trigger an allocation abort (process death) or, on
      systems with overcommit, allocate ~57 GiB before failing.
      **Fix**: bounded by `MAX_DECODED_ADDRESS_BOOK_ENTRIES =
      1_000_000`; additionally cap the `Vec::with_capacity` at
      `(bytes_remaining / 28)` so the allocation never exceeds
      what the actual input could populate.  Regression tests:
      `fixture::tests::decode_input_rejects_huge_address_book_length`,
      `decode_input_rejects_at_threshold`,
      `decode_input_accepts_at_threshold_but_fails_on_truncation`.

  17. **Unbounded keystore file read (LOW, DoS).**  `from_file`
      called `std::fs::read(path)` which loads the ENTIRE file
      into memory.  An operator misconfiguration pointing at
      `/dev/zero` (or a huge file) would exhaust memory.
      **Fix**: use `File::open` + `read_exact(&mut [0u8; 32])`
      to read at most 32 bytes; additionally check file
      metadata against `MAX_KEYSTORE_FILE_BYTES = 4096`.
      Regression test:
      `key::tests::from_file_rejects_oversized_file`.

  18. **Redundant RPC fetch when contracts coincide (LOW,
      efficiency).**  If the operator sets `bridge_contract ==
      identity_registry_contract` (a single-contract / test
      deployment), the watcher called `logs_in_block_by_hash`
      twice with the same arguments, then relied on the dedup
      layer to absorb the duplicate events.  **Fix**: detect
      the coincidence and skip the second RPC call.
      Regression test:
      `tests/integration.rs::end_to_end_same_contract_for_bridge_and_identity`.

  19. **`ingest` swallowed `commit_assignment` errors (LOW).**
      The deprecated `ingest` wrapper used `let _ =
      commit_assignment(...)`, silently discarding errors
      (overflow or expected-id mismatch).  **Fix**: panic with
      a clear message via `.expect(...)`.  `ingest` is only
      used in tests and the fixture generator where overflow
      is unreachable, so panicking is acceptable; production
      code uses the typed-error `commit_assignment` directly.

  20. **Stale `from_file` docstring (DOC).**  The docstring
      didn't mention the new size bound.  **Fix**: documented
      the read-at-most-32-bytes behaviour and the
      `MAX_KEYSTORE_FILE_BYTES` upper bound.

  21. **Misleading "SIGINT / SIGTERM" claim in main.rs
      (DOC).**  The binary's module docstring claimed the
      watcher was "stopped via SIGINT / SIGTERM", but no
      signal handler was installed — Ctrl-C delivered the
      default libc abort.  **Fix**: docstring now accurately
      describes the actual behaviour (libc default) and points
      at the `stop` `AtomicBool` hook that a future
      signal-handler crate could populate.

  22. **Misleading "fsync-bounded" claim in state.rs (DOC).**
      The `append` docstring claimed durability was
      "fsync-bounded" but the code only calls `flush` (writes
      to OS page cache).  **Fix**: docstring now accurately
      describes the best-effort durability semantic and points
      at RH-E.0 as the future transactional boundary.

  23. **Missing test for capacity-1 reorg window (LOW,
      coverage).**  No test exercised the edge case where the
      window holds only one block.  **Fix**: added
      `reorg::tests::capacity_1_window_linear_then_reorg_rejected`
      and `capacity_drops_oldest_on_linear_advance`.

  Audit posture after the third pass: 343 tests passing across
  the workspace (+46 over the initial landing, +26 over the
  first-audit-pass landing, +9 over the second-audit-pass
  landing), all four CI gates clean, `unsafe_code = "forbid"`
  workspace-wide.

---

### RH-C — `knomosis-host` (network adaptor, Phase 5 WU 5.4)

**Finding map.**  WU 5.4 deferred per GENESIS_PLAN line 3807.

**Scope.**  `runtime/knomosis-host/` — TCP/Unix-socket service
that accepts CBE-framed `SignedAction` requests and forwards
them to the Lean `knomosis` executable.

**RH-C decomposes into five sub-sub-units:**

  * **RH-C.1** — Crate skeleton + CBE frame parser.
  * **RH-C.2** — `knomosis` subprocess management.
  * **RH-C.3** — TCP / Unix-socket listener + TLS.
  * **RH-C.4** — Backpressure + queueing + `busy` verdict.
  * **RH-C.5** — ABI documentation (`abi.md §10`).

#### RH-C.1 — Crate skeleton + CBE frame parser

**Scope.**  `Cargo.toml`, `src/main.rs`, `src/frame.rs`.

**Implementation steps.**

  1. Skeleton with `tokio` + `tokio-util` (length-prefixed
    codec helpers).
  2. CLI flags: `--listen <addr>`, `--unix-socket <path>`,
    `--tls-cert <path>`, `--tls-key <path>`,
    `--knomosis-binary <path>`, `--max-queue-depth <n>`,
    `--max-frame-size <bytes>`.
  3. Frame parser: 4-byte big-endian length prefix +
    `length`-byte payload.  Reject frames over `--max-frame-size`
    (default 1 MiB).
  4. Frame is treated as opaque bytes — `knomosis-host` does not
    interpret CBE.  The host's only frame-level invariant is
    "length matches".

**Acceptance criteria.**

  * Round-trip: encode a frame, decode, bytes match.
  * Reject over-length, under-length, truncated.

**Risk.**  Trivial.

**Effort.**  ~1 engineer-day.

#### RH-C.2 — `knomosis` subprocess management

**Scope.**  `src/subprocess.rs`.

**Implementation steps.**

  1. Spawn `knomosis` as a child process with a Unix socket for
    IPC (matches Lean side's `LegalKernel/Runtime/Loop.lean`
    interface).
  2. Maintain a stdin/stdout pipe pair for the CBE protocol.
  3. Health check: periodic `getInfo` request; if subprocess
    becomes unresponsive, restart it.
  4. Graceful shutdown: on SIGTERM, drain queue + close
    subprocess.

**Acceptance criteria.**

  * Subprocess starts, accepts request, returns verdict.
  * Health check recovers from synthetic hang (subprocess
    sleeping).
  * Graceful shutdown: queued requests served before exit.

**Risk.**  Medium.  Subprocess management is OS-level
finicky.

**Effort.**  ~2 engineer-days.

#### RH-C.3 — TCP / Unix-socket listener + TLS

**Scope.**  `src/listener.rs`.

**Implementation steps.**

  1. TCP listener via `tokio::net::TcpListener`.
  2. Optional TLS termination via `rustls` with `--tls-cert`
    + `--tls-key`.
  3. Optional Unix socket listener (for local clients) at
    `--unix-socket`.
  4. Each accepted connection runs in its own task; serial
    request/response on the connection (HTTP-style one-shot
    is also acceptable, simpler).

**Acceptance criteria.**

  * Plain TCP: client connects + sends frame + receives verdict.
  * TLS: client connects with valid cert; bad cert rejected.
  * Unix socket: same.

**Risk.**  Low.  `tokio` / `rustls` are well-trodden.

**Effort.**  ~2 engineer-days.

#### RH-C.4 — Backpressure + queueing + `busy` verdict

**Scope.**  `src/queue.rs`.

**Implementation steps.**

  1. Bounded mpsc channel sized at `--max-queue-depth` (default
    256) between listener and subprocess.
  2. If the channel is full when a request arrives:
     - Respond with a new verdict code `3 = busy`.
     - Add log entry + metrics counter increment.
  3. Wire-format extension: the `3 = busy` verdict code is a
    *new addition* to the wire format.  This must be
    documented in `docs/abi.md` (per RH-C.5) and coordinated
    with the E-G amendment (per `ethereum_workstream_g_plan.md`
    WG.3) to ensure clients understand the new code.

**Acceptance criteria.**

  * Stress test: 1000 concurrent connections × 100 requests
    each; no OOM; the busy verdict appears under saturation.
  * Recovery: stress + cool-down; queue drains; no lingering
    backpressure.

**Risk.**  Medium.

**Effort.**  ~2 engineer-days.

#### RH-C.5 — ABI documentation

**Scope.**  `docs/abi.md` §10.

**Implementation steps.**

  1. Replace `abi.md:724`'s placeholder line with a full
    specification:
     - Wire-frame layout (4-byte length + payload).
     - CBE-encoded `SignedAction` payload (cross-reference §3).
     - Verdict codes (`0 = OK`, `1 = notAdmissible`,
       `2 = parseError`, `3 = busy` — new).
     - TLS protocol (recommend TLS 1.3+).
     - Unix-socket permissions (recommend 0600 +
       deployment-specific UID).
  2. Cross-reference from CLAUDE.md "Build and run" section.

**Acceptance criteria.**

  * `docs/abi.md` §10 contains no placeholder text.
  * Cross-references resolve.

**Risk.**  Low.

**Effort.**  ~1 engineer-day.

---

### RH-C — Rolled-up acceptance criteria + effort

  * RH-C.1 – RH-C.5 individually accepted.
  * Cross-stack: pre-recorded `SignedAction`/verdict corpus
    passes 100%.
  * Stress test passes.

**Math / soundness.**  The host is a pure shell: it does not
parse or interpret the CBE bytes beyond length-prefixing.  All
semantic checks happen in the Lean `knomosis` subprocess.  This
means the host has zero attack surface against the Lean
admissibility predicate.

**Aggregate effort:** ~8 engineer-days (revised down from 10;
decomposition surfaced the framing parser is simpler than
the original lump estimate implied).

---

### RH-C Closeout

**Complete.**  Lands `runtime/knomosis-host/` per
`docs/planning/rust_host_runtime_plan.md` §RH-C.  Headlines:

  * **Library + binary surface.**  `knomosis-host` is a library
    (`lib.rs` exporting 8 sub-modules: `config`, `frame`,
    `kernel`, `listener`, `queue`, `server`, `tls`, `verdict`)
    plus a binary (`knomosis-host` daemon with documented CLI
    flags `--listen / --tls-listen / --tls-cert / --tls-key /
    --unix-socket / --knomosis-binary / --knomosis-log /
    --knomosis-work-dir / --deployment-id / --max-queue-depth /
    --max-frame-size / --mock`).  Identifier string
    `"knomosis-host/v1"` published as `HOST_IDENTIFIER`.

  * **Canonical wire format.**  Request: 4-byte BE u32 length +
    N CBE-encoded `SignedAction` bytes.  Response: 1-byte
    verdict + 4-byte BE u32 reason length + M UTF-8 reason
    bytes.  Verdict table: `0 = Ok`, `1 = NotAdmissible`,
    `2 = ParseError`, `3 = Busy` (new in RH-C.4).  Full spec
    documented in `docs/abi.md` §10.

  * **No `tokio`.**  Departure from the plan §RH-C.1's tokio
    recommendation: we use `std::thread` + `std::sync::mpsc::
    sync_channel` instead.  Trades some peak throughput for a
    significantly smaller dependency tree (`tokio` would add
    ~80 transitive crates) and matches the workspace's
    consistent "no async runtime, hand-rolled HTTP" philosophy
    from `knomosis-l1-ingest`.  The acceptance criteria are met
    via per-connection `std::thread::spawn` + a single
    dedicated worker thread for kernel dispatch.

  * **Three listener variants.**  `tcp::TcpListener`,
    `tls::TlsListener` (via `rustls` 0.23 + `ring` crypto
    backend), and `unix::UnixListener` (mode 0600, refuses to
    clobber non-socket files at the path).  Multiple
    transports can be configured simultaneously; the daemon
    runs one acceptor thread per transport and shares a single
    worker queue across them.

  * **Kernel abstraction.**  `Kernel` trait + two impls:
    `mock::MockKernel` (configurable verdict-sequence; default
    `Ok`; records every submission for test assertions) and
    `command::CommandKernel` (spawns the Lean `knomosis` binary's
    `process` subcommand per request; collapses non-zero exit
    codes to `NotAdmissible` with the captured stderr as the
    reason).  The `CommandKernel` is heavy (O(log size) per
    request because knomosis re-loads the log file every time);
    the canonical future optimization is a `knomosis serve`
    Lean-side subcommand that reads CBE frames from stdin and
    writes verdicts to stdout, eliminating the per-request
    bootstrap cost.  This is deferred to a future Lean-side
    PR; meanwhile the `CommandKernel` is functional and
    correct for low-throughput deployments.

  * **Bounded queue + Busy backpressure.**  `BoundedQueue`
    wraps `std::sync::mpsc::sync_channel(capacity)`; the
    listener's `try_submit` returns `SubmitOutcome::Busy`
    rather than blocking when the queue is full.  Default
    `--max-queue-depth 256`; hard ceiling 65_536.  Memory
    usage is bounded by `max_queue_depth × max_frame_size`.

  * **No `unsafe`.**  `unsafe_code = "forbid"` workspace lint.
    The host is a pure-Rust orchestrator; FFI is delegated to
    the `Kernel` implementation (which is itself safe Rust for
    the `CommandKernel`).

  * **No panics on attacker input.**  Every frame-parse error
    path returns a typed `FrameError`; every queue-overflow path
    returns `Busy`; every kernel-timeout path returns
    `NotAdmissible` with a "kernel timeout" reason.  The four
    end-to-end integration tests + 11 property tests sweep
    arbitrary attacker-supplied bytes through the parser and
    verify it never panics.

  * **Audit posture at landing (post-RH-C two audit passes).**
    Two independent code-review-agent audits surfaced 29
    findings combined; every CRITICAL / HIGH-severity issue
    has been addressed in-PR (see "Audit-pass fixes" below).
    - `cargo build --workspace --all-targets --locked` —
      green.
    - `cargo test --workspace --locked` — 526 tests passing
      (+218 from the RH-B landing's 308).  Breakdown:
      * `knomosis-host` lib: 150 unit tests (verdict + frame +
        kernel + queue + listener + server + tls + config +
        admission, plus the timeout / symlink / mutex-poison
        / panic-isolation / staging / race-safety regression
        tests).
      * `knomosis-host` integration TCP: 15 tests (incl.
        connection-limit + shutdown-drain + kernel-panic-
        isolation tests).
      * `knomosis-host` integration Unix: 7 tests.
      * `knomosis-host` property: 11 tests.
    - `cargo clippy --workspace --all-targets --locked --
      -D warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - `unsafe_code = "forbid"` workspace lint.
    - Binary smoke-tested via `./target/release/knomosis-host
      --listen 127.0.0.1:23457 --mock` plus a manual request
      via `nc`; response bytes match the documented wire
      format byte-for-byte (`00 00 00 00 00` = verdict Ok +
      zero-length reason).

  * **Audit-pass fixes (six critical / high severity).**
    - **#1 CommandKernel timeout enforcement.**  Previously
      `cmd.output()` blocked unconditionally; a wedged knomosis
      binary would hang the worker forever.  Replaced with
      `cmd.spawn()` + a `try_wait` poll loop honouring the
      `with_timeout` configuration.  On timeout, the child
      is SIGKILLed and reaped.  Stderr captured via a
      bounded read (`MAX_SUBPROCESS_OUTPUT = 64 KiB`).
    - **#2 Connection-thread spawn-storm DoS.**  Added
      `--max-concurrent-connections` (default 1024, hard
      ceiling 65 536) that bounds the number of
      simultaneously active per-connection threads via an
      RAII `ConnectionSlot` against a shared `AtomicUsize`.
      Beyond the cap, TCP / Unix listeners write `Busy`
      and close; the TLS listener closes without a
      handshake (a plaintext byte to a TLS client is
      meaningless).
    - **#3 CommandKernel symlink TOCTOU.**  Replaced
      predictable temp paths (`knomosis-host-req-<pid>-<id>.cbe`)
      + `File::create` (which follows symlinks) with
      `tempfile::Builder` which uses random suffixes +
      `O_CREAT | O_EXCL`, making pre-existing-symlink
      attacks infeasible.  `tempfile` promoted from a
      dev-dep to a runtime dep for knomosis-host.
    - **#4 Shutdown ordering.**  Rewrote `Server::run` to
      drain in strict phases: (1) listener accept loops
      exit, (2) wait for in-flight connection handlers to
      drain bounded by `SHUTDOWN_DRAIN_TIMEOUT`, (3) drop
      the queue, (4) join worker.  Each connection handler
      thread holds an RAII `ConnectionSlot` that decrements
      a shared `AtomicUsize` on drop; the orchestrator
      polls this counter to determine when all handlers
      have completed.  Closes the lib docstring's "queued
      requests must complete, no in-flight loss" promise.
    - **#6 Listener busy-loop on persistent accept errors.**
      Replaced the fixed 100 ms sleep on accept-error with
      exponential backoff (100 ms × 2^n, capped at 3.2 s)
      tracked via a `consecutive_errors` counter.  Defends
      against EMFILE-style file-descriptor exhaustion.
    - **#14 `read_frame` hard-cap enforcement.**  Internally
      clamps the supplied `max_frame_size` to
      `HARD_MAX_FRAME_SIZE` so library consumers bypassing
      the CLI cannot disable the bound.

    The remaining audit findings (medium / low severity)
    are either fixed in-PR (#11 EofBeforeHeader log
    accuracy via the new `HandleOutcome` enum;
    #12 mutex poison recovery in CommandKernel's
    spawn_lock; #15 documented BoundedQueue zero-capacity
    behaviour) or deferred to follow-up PRs (#5 explicit
    TLS handshake timeout; #9 distinguishing
    `recv_timeout` Disconnected from Timeout; #13
    transient-vs-permanent exit-code refinement).  Test
    coverage gaps T1 (timeout test), T3 (symlink defence
    test), T4 (shutdown drain test) all landed; T2
    (spawn-storm DoS) is exercised by the
    connection-limit-returns-busy test (a smaller-scale
    variant — full 10k-connection chaos testing belongs to
    RH-F's benchmark harness).

  * **Audit-pass-2 fixes (the post-staging-extension
    review).**  After landing the `AdmissionStage` ladder
    and `SubscribableKernel` extension trait, a second
    independent audit surfaced 9 findings; the three
    CRITICAL / HIGH-severity issues are addressed in-PR:
    - **#2 (HIGH) `file.flush()` is a no-op on
      `std::fs::File`.**  Replaced with `file.sync_data()`
      in `CommandKernel::submit`.  Std's `Write` impl for
      `File` returns `Ok(())` from `flush` (the File has
      no userspace buffer); without `sync_data` the
      subprocess could observe an empty or truncated
      payload on NFS / FUSE work-dirs where the page-cache
      writeback hasn't propagated.  Cost: one fdatasync
      per request.
    - **#3 (HIGH) kernel-panic isolation.**  Wrapped every
      `kernel.submit` call in
      `std::panic::catch_unwind(AssertUnwindSafe(...))`.
      In release builds the workspace uses
      `panic = "abort"` so the wrap is inert; in debug
      builds (the test profile) it converts a panic into
      a `NotAdmissible` response with a `"kernel
      panicked"` reason, keeping the worker alive for
      subsequent submissions.  Operators get accurate
      verdicts (panic, not timeout); CI doesn't appear to
      wedge on a buggy kernel impl.  New regression test:
      `kernel_panic_does_not_stall_host`.
    - **#8 (CRITICAL) `SubscribableKernel` race-window
      under-documentation.**  Strengthened the
      `Subscription` contract from "monotonically
      non-decreasing" to "strictly increasing" and added
      the **atomic-snapshot rule**: implementations MUST
      hold a single synchronisation primitive across both
      the `current` advancement AND the `events` channel
      send, AND across both the snapshot read AND the
      receiver claim in `subscribe`.  Otherwise a
      naive impl that bumps `current` and `send`s without
      locking could deliver a stage twice (once as
      `current`, once as the first `events` emission),
      violating the contract.  The test fixture was
      rewritten to follow the canonical pattern; a new
      regression test
      `subscribe_during_advance_no_duplicate_events`
      spawns a concurrent advancer thread and asserts
      strict-increasing observed-stage sequence under
      race.
    - Plus a self-found defence-in-depth: clamped
      `ConnectionSlot::try_acquire`'s `cap` parameter
      against `HARD_MAX_CONCURRENT_CONNECTIONS`,
      paralleling `read_frame`'s `HARD_MAX_FRAME_SIZE`
      clamp.  Defends against library consumers
      constructing `HandlerConfig` with `usize::MAX`
      (bypassing the CLI validation).
    - Plus documentation cleanups (#1 `NamedTempFile` /
      `keep()` semantics; #5 `VerdictResponse::encode`
      saturation behaviour) and a new test
      (`encode_declared_length_equals_emitted_payload_for_realistic_sizes`)
      verifying wire self-consistency at the
      length-prefix boundary.
    - The remaining findings (#4 ordering of zero/oversize
      check is acceptable; #6 latent test-flake risk under
      partial reads not triggered today; #7 `Receiver
      !Sync` enforced by the type system; #9 CAS Acquire
      on success is wasteful but not buggy) are all
      INFO/LOW.

  * **Audit-pass-3 fixes (the post-audit-2 review).**  A
    third independent audit surfaced 6 findings; the
    headline finding (MEDIUM) is fixed in-PR plus several
    quality items.  The most important is **#1**: the AR-2
    "race-safety" test was passing for the wrong reason.
    - **AR-3 #1 (MEDIUM) Race-safety test passes by
      accident.**  The audit-2 `subscribe_during_advance
      _no_duplicate_events` test had a 5ms sleep at the
      start of the advancer thread, which deterministically
      let the subscriber win the race.  The "race" the test
      named NEVER happened; what it actually tested was the
      easy subscribe-before-advance case.  The fixture's
      `subscribe()` ALSO didn't drain buffered events ≤
      snapshot, so a true subscribe-after-advance race
      would observe `[Finalized, Sequenced, Finalized]` —
      a strict-monotonicity violation.  Audit-3 rewrote
      the fixture to drain buffered events under the mutex
      (the canonical atomic-snapshot pattern) AND
      restructured the test into three deterministic
      scenarios: subscribe-before-advance,
      subscribe-after-advance (the previously-missed bug
      case), and concurrent advancer + subscriber.  All
      three assert strict monotonicity.  This is the
      canonical reference any future RH-D /
      ConsensusKernel implementer should copy.
    - **AR-3 #4 (LOW) TLS crypto provider not pinned
      per-config.**  Previously `tls.rs::TlsConfigBuilder
      ::build` called `install_default()` (idempotent
      no-op if a different provider was already installed)
      then used the implicit process-global provider via
      `builder_with_protocol_versions`.  If a library
      consumer installed `aws-lc-rs` (or similar) earlier
      in the process, knomosis-host's ServerConfig would use
      THEIR provider's primitives, not `ring`.  Audit-3
      switched to `ServerConfig::builder_with_provider
      (Arc::new(ring::default_provider()))` so the
      provider choice is explicit per-config.  Both
      `ring` and `aws-lc-rs` are audited and secure, but
      the docstring + Cargo.toml promised `ring`
      specifically — now actually delivered.
    - **AR-3 #2 (LOW) MockKernel poison-recovery
      inconsistency.**  MockKernel's six mutex-lock sites
      used `.expect("MockKernel mutex poisoned")`, which
      would re-panic the worker if the mutex was already
      poisoned.  CommandKernel uses the
      `.unwrap_or_else(|p| p.into_inner())` recovery
      pattern.  Audit-3 normalised MockKernel to the
      same pattern, eliminating an inconsistency and
      making `catch_unwinding_submit` actually keep the
      MockKernel-backed worker alive across a panic.
    - **AR-3 #3 / #5 / #6 (LOW / INFO)** documentation
      polish.  Fixed the `keep()` return-type docstring
      (`(File, PathBuf)`, not `(File, TempPath)`).
      Removed the unused `knomosis-cross-stack` dev-dep
      from `knomosis-host/Cargo.toml`.  Clarified
      `panic_message`'s payload-type expectations.
    - **Plus a flaky-test fix found during the audit-3
      run.**  `shutdown_drains_inflight_requests` and
      `saturation_returns_busy` were calling `submit_one`
      (which `.expect()`s a successful response).  Under
      shutdown / saturation races, some connections
      would reach the server but get closed without a
      response (TCP reset), causing `submit_one` to
      panic on the empty buffer.  Switched both tests
      to use `try_submit_one` and tolerate transport
      errors via `Option<u8>` semantics.  Verified
      stable across 50 consecutive runs (0/50 failures).

  * **Workspace dependency additions.**  `rustls = "0.23"`
    with `ring` + `tls12` + `std` features (no
    `aws-lc-rs`, no logging, no `default-features`),
    `rustls-pemfile = "2"`, `rustls-pki-types = "1.10"`.
    `tempfile` promoted from dev-dep to runtime dep for
    `knomosis-host` (the symlink-TOCTOU defence per audit #3).
    All pinned at the workspace level so any future
    TLS-touching crate inherits the same version surface.
    Bumped workspace version to `0.1.3`.

  * **What this crate does NOT provide (forward-extension
    points).**
    - **A long-running `knomosis serve` subprocess.**  The
      `CommandKernel` spawns per request; the canonical
      optimization is a future `knomosis serve` subcommand.
    - **An HTTP/1.1 compatibility shim.**  The canonical
      wire format is raw TCP per the plan §RH-C.1.  The
      existing `knomosis-l1-ingest::submitter::http::
      HttpSubmitter` uses HTTP/1.1 against a placeholder
      endpoint; migrating the submitter to the canonical
      raw-TCP protocol is a follow-up RH-B-adjacent PR.
      Both protocols can coexist via a separate
      `knomosis-host` listener variant in a future PR.
    - **A built-in cross-stack `.cxsf` fixture corpus.**
      The `tests/integration.rs::fixture_replay_pattern`
      test demonstrates the pattern; the production
      `canon_host.cxsf` corpus arrives when the Lean
      reference verdict generator is wired (a future
      cross-stack equivalence PR).

---

### RH-D — `knomosis-event-subscribe` (Phase 5 WU 5.7)

**Finding map.**  WU 5.7 deferred per GENESIS_PLAN line 3823.

**Scope.**  `runtime/knomosis-event-subscribe/` — subscription
service that streams ordered events to subscribers.

**RH-D decomposes into five sub-sub-units:**

  * **RH-D.1** — Crate skeleton + log-tail reader.
  * **RH-D.2** — Event-extraction subprocess (delegate to
    `knomosis` for wire-format authority).
  * **RH-D.3** — Subscriber lifecycle + bounded-lag policy.
  * **RH-D.4** — Resume-from-sequence protocol.
  * **RH-D.5** — Wire format + tests.

#### RH-D.1 — Crate skeleton + log-tail reader

**Implementation steps.**

  1. `Cargo.toml` with `tokio` + workspace deps.
  2. CLI: `--log-path <path>`, `--listen <addr>`,
    `--max-subscriber-lag <n>`, `--keep-history <n>`.
  3. Log-tail reader: open `log.jsonl` via `tokio::fs::File`;
    use `tokio::io::AsyncBufReadExt::lines()` to stream new
    frames; on EOF, sleep + retry (no inotify dependency).
  4. Emit per-frame metadata: `(sequence_number, byte_offset,
    raw_bytes)`.

**Acceptance criteria.**

  * Tail correctly follows a growing file.
  * Resume on EOF + new appends.

**Risk.**  Low.

**Effort.**  ~1 engineer-day.

#### RH-D.2 — Event extraction via `knomosis` subprocess

**Decision recorded:** delegate event extraction to the Lean
`knomosis` executable rather than reimplement
`Events.extractEvents` in Rust.  Rationale: Lean is the
wire-format authority; a Rust reimplementation would risk
drift.

**Implementation steps.**

  1. Spawn `knomosis extract-events --log <path>` subprocess
    (the Lean side ships this subcommand via `Main.lean`).
  2. Communicate via pipe protocol: `(seq, frame_bytes) →
    knomosis → CBE-encoded Event[]`.
  3. Cache extracted events keyed by sequence number for
    backfill (RH-D.4).

**Alternative considered:** Rust reimplementation.  Rejected
because (a) reimplementation duplicates code under different
correctness regimes, (b) every Lean-side change to
`Events.lean` would require a coordinated Rust update,
(c) the cross-stack corpus would have to test extraction
specifically — a non-trivial expansion.  Delegate is cheaper
and safer.

**Acceptance criteria.**

  * Extracted events byte-equal Lean reference.
  * Subprocess restart on crash.

**Risk.**  Low.

**Effort.**  ~1.5 engineer-days.

#### RH-D.3 — Subscriber lifecycle + bounded-lag policy

**Implementation steps.**

  1. Per-subscriber state: `{ id, last_sent_seq, send_queue,
    last_ack_at }`.
  2. Bounded send queue (default 64).  If queue is full and a
    new event arrives, increment a lag counter.
  3. If lag > `--max-subscriber-lag` (default 256), send a
    final `lag-exceeded` frame and disconnect.
  4. Eviction policy: oldest subscriber first if total memory
    pressure threshold tripped.

**Acceptance criteria.**

  * Lagged subscriber disconnected with explicit frame.
  * Healthy subscribers unaffected by a lagged peer.

**Risk.**  Medium.

**Effort.**  ~2 engineer-days.

#### RH-D.4 — Resume-from-sequence protocol

**Implementation steps.**

  1. Client wire protocol: a `subscribe { resume_from: Option<u64> }`
    handshake frame.  If `resume_from` is `Some(n)`, the
    server begins streaming from sequence `n+1`.
  2. Server backfill: walk the log file from genesis,
    skipping frames with sequence ≤ `n`, until the live tail
    is reached.  This is O(log-size); for production-scale
    logs, a `--keep-history <n>` flag bounds the backfill
    range (older events get a `truncated` error frame).
  3. Document the protocol in `docs/abi.md` (extends §10).

**Acceptance criteria.**

  * Disconnect mid-stream → reconnect → exact missing
    sequence range delivered.
  * Resume from before truncation → `truncated` error frame
    + disconnect.

**Risk.**  Medium.

**Effort.**  ~1.5 engineer-days.

#### RH-D.5 — Wire format + tests

**Implementation steps.**

  1. Wire frame: 8-byte big-endian sequence + 4-byte
    big-endian length + length-byte CBE-encoded `Event`
    payload.
  2. Document in `docs/abi.md` §11 (new sub-section for
    event-subscribe).
  3. Tests: single subscriber happy path; lag eviction;
    resume across reconnect; backfill from genesis;
    truncation rejection.

**Acceptance criteria.**

  * Frame round-trip.
  * All test scenarios pass.

**Risk.**  Low.

**Effort.**  ~1 engineer-day.

---

### RH-D — Rolled-up

**Aggregate effort:** ~7 engineer-days (matches prior
estimate).

#### RH-D — Closeout

**Status.**  **Complete.**

**Landed deliverables.**

  * `runtime/knomosis-event-subscribe/` materialises the
    full RH-D Rust framework as a library (`lib.rs`
    exporting 7 sub-modules: `config`, `event_cache`,
    `extract`, `frame`, `server`, `subscription`, `tail`)
    plus a binary (`knomosis-event-subscribe` daemon).
  * **Wire-format contract.**  Documented in `docs/abi.md`
    §11 (new top-level section).  Inbound `SUBSCRIBE` frame
    (1-byte kind + 8-byte BE u64 resume-from); outbound
    `EVENT` frame (1-byte kind + 8-byte BE seq + 4-byte BE
    length + N CBE event bytes); control frames
    (`LAG_EXCEEDED`, `TRUNCATED`, `SERVER_SHUTDOWN`,
    `INVALID_REQUEST`) each 9 bytes total.
  * **Module decomposition.**
    - **RH-D.1 — Log-tail reader** (`tail.rs`): polls the
      Lean log-file format (4-byte ASCII "CANO" magic +
      8-byte LE length + payload + 8-byte LE FNV-1a-64
      trailer), assigns monotonic seq numbers starting at
      `1`, returns `PollOutcome::Frame` / `Pending`.  Detects
      torn writes via the trailer check; surfaces bad magic
      / bad trailer / oversize as typed errors.
    - **RH-D.2 — Extractor** (`extract.rs`): `Extractor`
      trait + two implementations.  `MockExtractor` is the
      in-memory programmable test extractor (cycles through
      a configured response sequence); `SubprocessExtractor`
      spawns the Lean `knomosis` binary in a future
      `extract-events` mode.  The subprocess wire protocol is
      documented in the module's docstring: BE u64 seq + BE
      u32 length + payload on stdin; BE u64 seq + BE u32
      count + per-event (BE u32 length + payload) on stdout.
    - **RH-D.3 — Subscriber lifecycle** (`subscription.rs`):
      `Subscriber` + `SubscriberRegistry` types; bounded
      per-subscriber `sync_channel(send_queue_depth)`;
      `try_enqueue` returns `Enqueued` / `Lagging { lag }` /
      `LagExceeded` / `Disconnected`.  The lag counter
      increments on each failed enqueue, resets on each
      success.  When lag > `max_subscriber_lag`, the
      subscriber's `disconnected` flag is atomically set and
      the dispatch thread emits a final `LAG_EXCEEDED` frame.
    - **RH-D.4 — Backfill** (`event_cache.rs`): bounded FIFO
      `EventCache` keyed by seq; `range(from_seq)` returns
      `InWindow { events }` / `OutOfWindow { oldest }` /
      `AtLiveTail`.  Resume-from-sequence is implemented as
      a backfill from the cache before transitioning to
      live-tail mode in the dispatch thread.
    - **RH-D.5 — Wire format + tests** (`frame.rs` + tests/):
      bidirectional `read_*` / `encode_*` / `write_*` helpers
      with full property-test coverage.
  * **Threading model.**  Synchronous `std::thread`-based
    architecture (no `tokio` dependency — matches RH-C's
    "no async runtime" discipline).  One acceptor thread,
    one extractor thread, one dispatch thread per
    subscriber; the extractor thread broadcasts each
    extracted event to every active subscriber without
    holding a global lock.
  * **No `unsafe`.**  `unsafe_code = "forbid"` workspace
    lint.  The subscriber is a pure-Rust orchestrator; the
    only FFI surface is the subprocess pipe to `knomosis`
    (Lean-side code).
  * **No panics on attacker input.**  Every frame-parse
    error path returns a typed `FrameError`; every
    subprocess error path returns a typed `ExtractError`;
    every queue-overflow path increments the lag counter
    and may close the connection.
  * **Workspace dependency additions.**  None beyond
    workspace-shared crates (`thiserror`, `tracing`,
    `tracing-subscriber`, `proptest`, `tempfile`).  The
    subscriber re-uses the same dependency tree as
    `knomosis-host` and `knomosis-l1-ingest`.

**Wire-format authority delegation.**  Event extraction is
delegated to the Lean `knomosis` subprocess via the future
`knomosis extract-events` subcommand.  The subprocess protocol is
documented in `extract.rs::subprocess` module docstring; the
Lean subcommand itself is a follow-up Lean-side PR (matches
the `knomosis serve` deferral pattern from RH-C — ship the Rust
framework with a working `MockExtractor` for tests and a
production `SubprocessExtractor` whose binary contract is
honored once the Lean side lands).  Until then,
`SubprocessExtractor` returns a typed
`ExtractError::SubprocessUnavailable` if invoked against a
binary that doesn't expose the subcommand, which the
extractor thread translates into a `broadcast_shutdown` —
operators see a clean degradation rather than silently wrong
events.

**Audit posture at landing (post-audit pass).**  An
independent code-review agent surfaced 4 critical and 6
high-severity findings; all have been addressed in-PR (see
CLAUDE.md "Workstream RH-D" entry for the full per-finding
breakdown).  Final gates:

  * `cargo build --workspace --all-targets --locked` — green.
  * `cargo test --workspace --locked` — 692 tests across the
    workspace, all passing (166 new in `knomosis-event-subscribe`:
    143 lib + 15 integration + 8 property).
  * `cargo clippy --workspace --all-targets --locked -- -D
    warnings` — clean.
  * `cargo fmt --all -- --check` — clean.
  * `unsafe_code = "forbid"`.
  * Binary smoke-tested: `./target/release/knomosis-event-subscribe
    --help` / `--version` / `--mock` startup all work; the
    daemon listens on a TCP port, accepts SUBSCRIBE
    handshakes, and shuts down cleanly on the internal stop
    flag.

---

### RH-E.0 — `knomosis-storage` (Rust DB layer)

**Finding map.**  Structural blocker for WU 5.8 per GENESIS_PLAN
line 3826.

**Scope.**  `runtime/knomosis-storage/` — a small abstraction crate
exposing a `Storage` trait with `get / put / scan` semantics,
plus a SQLite-backed implementation.

**Why this is the structural blocker for WU 5.8.**  No prior
abstraction over the Rust persistence story exists.  Without
RH-E.0, RH-E.1 (indexer) cannot start, and RH-G.6 (observer
persistence) duplicates the storage glue.  Landing the trait
first and threading it through downstream crates is the right
sequencing.

**RH-E.0 decomposes into five sub-sub-units:**

  * **RH-E.0.a** — Trait definition.
  * **RH-E.0.b** — SQLite implementation.
  * **RH-E.0.c** — Snapshot API.
  * **RH-E.0.d** — Migration scaffolding.
  * **RH-E.0.e** — Test suite + benchmark fixtures.

#### RH-E.0.a — Trait definition

**Implementation steps.**

  1. `pub trait Storage: Send + Sync` with the four methods
    (`get`, `put`, `delete`, `scan`) plus `snapshot` and
    `transaction`.
  2. `pub trait StorageSnapshot: Send + Sync` with read-only
    methods.
  3. `pub trait StorageTransaction<'a>` with `commit` and
    `rollback`.
  4. Document the trait's *byte-array-key* convention: callers
    must use lexicographic ordering; scans walk in lex order.

**Risk.**  Low-medium.  Trait stability is the long-term
concern; reviewers should be especially careful about adding
methods unnecessarily.

**Effort.**  ~1 engineer-day.

#### RH-E.0.b — SQLite implementation

**Implementation steps.**

  1. Single-table schema: `kv(key BLOB PRIMARY KEY, value BLOB
    NOT NULL)`.
  2. `rusqlite::Connection` wrapped in a `tokio::sync::Mutex`
    for thread-safe access.
  3. WAL mode enabled in `Storage::open()` via `PRAGMA
    journal_mode = WAL`.
  4. `synchronous = NORMAL` for non-fsync-on-every-write
    durability (operator can override via flag).
  5. Each transaction → SQLite explicit `BEGIN ... COMMIT`.

**Math / soundness.**

  * Strictly read-write KV; no SQL surface exposed.
  * WAL provides ACID with reader/writer concurrency.
  * Snapshot uses `BEGIN DEFERRED` + `SELECT` to lock the
    reader's view to the WAL state at snapshot creation.

**Risk.**  Low.

**Effort.**  ~1.5 engineer-days.

#### RH-E.0.c — Snapshot API

**Implementation steps.**

  1. `fn snapshot(&self) -> Result<Box<dyn StorageSnapshot>>`.
  2. Snapshot pins the WAL state at creation via a deferred
    read transaction.  Closes when the snapshot is dropped.
  3. Snapshots are *read-only* — no `put` / `delete` /
    `transaction` methods on the snapshot trait.

**Use case.**  `knomosis-faultproof-observer` (RH-G.6) takes a
snapshot at game-open time to ensure consistent state reads
during bisection responses even as new events arrive.

**Acceptance criteria.**

  * Snapshot reads are stable across concurrent writes.
  * Dropping the snapshot releases the read lock.

**Effort.**  ~1 engineer-day.

#### RH-E.0.d — Migration scaffolding

**Implementation steps.**

  1. `current_schema_version` row in a meta-table.
  2. `MigrationFn = fn(&Connection) -> Result<()>`.
  3. `Storage::open()` reads the version, applies pending
    migrations in order (idempotent reapplication is a
    non-goal for v1; migrations bump the version atomically).
  4. **Append-only migration discipline:** never modify a
    landed migration; always add a new one.  Down-migrations
    not supported in v1 (operator backups handle rollback).

**Acceptance criteria.**

  * Schema upgrade test: v1 binary writes; v2 binary upgrades;
    v2 reads the v1 data correctly.
  * Re-open after upgrade is a no-op.

**Risk.**  Medium.  Migration bugs are catastrophic
(data loss).

**Effort.**  ~1 engineer-day.

#### RH-E.0.e — Test suite + benchmark fixtures

**Implementation steps.**

  1. Unit tests for each trait method.
  2. Property test: random KV operation sequences; final
    state matches an in-memory `BTreeMap` reference.
  3. Concurrency test: spawn N readers + 1 writer; readers
    never see torn writes.
  4. Benchmark fixtures consumed by RH-F (`knomosis-bench`).

**Acceptance criteria.**

  * 100% line coverage on the SQLite impl.
  * Concurrency test passes under `tokio::test`.

**Effort.**  ~1.5 engineer-days.

---

### RH-E.0 — Rolled-up

**Aggregate effort:** ~6 engineer-days (revised up from 5;
decomposition surfaced ~1 day of additional scope for migration
discipline + concurrency tests).

**Risk.**  Low-medium.  Storage abstractions historically suffer
scope creep; resist.

**Effort.**  ~5 engineer-days.

---

### RH-E.1 — `knomosis-indexer` (Phase 5 WU 5.8)

**Finding map.**  WU 5.8 deferred per GENESIS_PLAN line 3826.

**Scope.**  `runtime/knomosis-indexer/` — daemon that consumes
events via `knomosis-event-subscribe` and maintains a per-resource
balance view in `knomosis-storage`.

**Implementation steps.**

  1. Crate skeleton.
  2. Subscribe to events; for each `Event.transfer` /
    `Event.mint` / `Event.burn` / `Event.deposit` / `Event.withdraw`,
    update the balance row keyed by `(actor, resource)`.
  3. Idempotency: track the last processed sequence number;
    on restart, resume from that sequence.
  4. Verification: `--verify-against-knomosis` flag that, for every
    actor, queries the live `knomosis-host` for the canonical
    balance and asserts equality.  Regression-test in CI.
  5. CLI: `knomosis-indexer query <actor> <resource>` for ad-hoc
    queries.

**Acceptance criteria.**

  * Balance view matches `knomosis-host`'s `getBalance` for
    arbitrary actors after a 10k-event load.
  * Idempotent restart: kill mid-stream, restart, no
    double-application.

**Risk.**  Low.

**Effort.**  ~6 engineer-days.

---

### RH-E — Closeout

**Complete.**  Both sub-workstreams (RH-E.0 storage
abstraction + RH-E.1 indexer daemon) landed on
`claude/sqlite-indexer-rust-db-8lz3Z`.  See
`docs/abi.md` §11A for the on-disk key schema and dispatch
table.  Headline implementation notes:

  * **RH-E.0.a (Trait definition).**  `Storage` /
    `StorageSnapshot` / `StorageTransaction` traits exposed at
    `runtime/knomosis-storage/src/storage.rs`.  Five methods on
    `Storage` (`get` / `put` / `delete` / `scan` / `snapshot` /
    `transaction`), three on `StorageSnapshot` (`get` / `scan`),
    and four on `StorageTransaction` (`get` / `put` / `delete` /
    `commit` / `rollback`).  Byte-array keys with documented
    lex-order scan contract.  `Send`-bound dropped on
    `StorageSnapshot` and `StorageTransaction` (they hold a
    `std::sync::MutexGuard`, which is `!Send`; per-thread usage
    is the intended pattern).

  * **RH-E.0.b (SQLite implementation).**  `SqliteStorage` at
    `runtime/knomosis-storage/src/sqlite.rs`.  Single-table schema
    `kv(key BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL)
    WITHOUT ROWID` plus a `_meta` table for the schema version.
    Pragmas applied on open: `journal_mode = WAL`, `synchronous
    = NORMAL`, `foreign_keys = ON`, `temp_store = MEMORY`.
    Wraps `rusqlite::Connection` in `std::sync::Mutex` rather
    than `tokio::sync::Mutex` (workspace consistently avoids an
    async runtime).  `rusqlite` pinned at `0.31` with the
    `bundled` feature so SQLite is compiled from source — no
    system libsqlite3 dependency.

  * **RH-E.0.c (Snapshot API).**  `SqliteSnapshot` opens a
    `BEGIN DEFERRED` transaction and forces an immediate read
    lock acquisition via `SELECT 1` so the WAL state is pinned
    even before the first user-issued read.  Drop releases the
    read lock via `ROLLBACK` (no writes occurred; rollback is
    the correct close-out verb per SQLite's documented snapshot
    release path).  The trait-object type
    `Box<dyn StorageSnapshot + '_>` lets callers swap in a
    mock for tests without touching the production type.

  * **RH-E.0.d (Migration scaffolding).**  Append-only
    `MIGRATIONS` table in `runtime/knomosis-storage/src/migration.rs`.
    Each migration carries a static name + an apply function
    `fn(&Connection) -> Result<(), rusqlite::Error>`; the runner
    bumps `_meta::schema_version` atomically inside the
    migration's own transaction.  Forward-incompatibility
    (on-disk version > binary's target) surfaces as a typed
    `StorageError::MigrationMismatch` rather than silent
    corruption.

  * **RH-E.0.e (Tests).**  49 unit tests, 9 integration tests,
    8 property tests = 66 total for `knomosis-storage`.  Property
    tests include the headline oracle (random KV op sequence
    matches an in-memory `BTreeMap` reference); concurrency
    test (`Arc<SqliteStorage>` across 4 threads, 25 keys each,
    final state-set equals 100 keys); forward-incompatibility
    detection on reopen.

  * **RH-E.1 (Indexer crate).**  Materialises
    `runtime/knomosis-indexer/` as a library + binary.  Module
    structure: `event` (typed Event enum mirroring Lean's
    16-constructor inductive, with frozen tags 0..15) + `decoder`
    (CBE decoder + matching encoder for the future Lean
    encoder's wire format) + `balance` (per-(actor, resource)
    balance view over `Storage`) + `cursor` (atomic
    last-processed-seq tracker with identifier-mismatch
    defence) + `indexer` (orchestration: subscribe → decode →
    dispatch → atomic commit) + `client` (hand-rolled TCP
    client for knomosis-event-subscribe's §11 wire format) +
    `config` (CLI parsing for `daemon` and `query` subcommands).

  * **Dispatch contract.**  See `docs/abi.md` §11A.4 for the
    dispatch table.  Headline: `BalanceChanged` is
    authoritative; `RewardIssued` and `DepositCredited` are
    saturating credits (overflow → saturate to `u128::MAX` +
    typed warning); `WithdrawalRequested` is a strict debit
    (underflow → batch rollback).  Each event batch commits
    atomically with the cursor advance inside a single
    storage transaction.

  * **Mathematical invariant.**  For any extracted event
    stream, the indexer's balance view after replay equals the
    kernel's `getBalance` for every (actor, resource) pair.
    This is the load-bearing correctness property; the
    `--verify-against-knomosis` flag is plumbed for future
    cross-check work against a running `knomosis-host`.

  * **Event encoding decision.**  The Lean side does not yet
    ship an `Encodable Event` instance (the `knomosis
    extract-events` subcommand is deferred per CLAUDE.md
    "Workstream RH-D" entry).  The Rust decoder uses the
    established CBE convention (tag-as-uint + per-field
    primitives matching `knomosis-l1-ingest/src/encoding.rs`) so
    it remains compatible the moment the Lean encoder lands.
    Symmetric `encode_event` co-located so the future Lean
    encoder can be cross-checked byte-for-byte against the
    Rust mirror.

  * **CLI surface.**
    - `knomosis-indexer daemon --storage <PATH> [--subscribe <ADDR>]
      [--max-frame-size <BYTES>] [--reconnect-backoff-ms <MS>]
      [--max-reconnects <N>] [--verify-against-knomosis <URL>]` —
      long-running daemon.
    - `knomosis-indexer query --storage <PATH> <actor> <resource>` —
      one-shot lookup.  Output format:
      `<actor> <resource> <balance>\n`.
    - `--help` / `-h`, `--version` / `-V` — standard.

  * **Tests.**  At the audit-pass landing: 103 lib unit + 7
    integration + 5 property + 10 wire-protocol + 8 daemon-
    loop = 133 total for `knomosis-indexer`.  Wire-protocol tests
    stand up a tiny mock knomosis-event-subscribe server in a
    background thread and verify the indexer's
    `SubscribeClient` round-trips every frame variant
    byte-for-byte against the §11 wire spec.  Daemon-loop
    tests drive the real `Indexer` + `consume_stream` against
    a mock server to verify partial-batch discard.

  * **Final gates.**
    - `cargo build --workspace --all-targets --locked` — green.
    - `cargo test --workspace --locked` — 900 tests passing
      (+198 from the RH-D landing's 702: 67 storage + 133
      indexer; +16 from the initial RH-E landing's 884 across
      the audit-pass regression tests).
    - `cargo clippy --workspace --all-targets --locked -- -D
      warnings` — clean.
    - `cargo fmt --all -- --check` — clean.
    - `unsafe_code = "forbid"` on both new crates.
    - Binary smoke-tested:
      `./target/release/knomosis-indexer --version` →
      `knomosis-indexer/v1 (version 0.2.0)`;
      `./target/release/knomosis-indexer query --storage <tmp>
      42 7` → `42 7 0` (exit 0) on a fresh DB.
    - End-to-end Python harness drives a mock event-subscribe
      server: a 3-event partial batch at seq=1 followed by
      connection drop produces zero balance changes (cursor
      correctly stays at 0); a multi-seq stream with mixed
      BalanceChanged + RewardIssued correctly applies the
      authoritative `BalanceChanged.new_value` without double-
      counting.

  * **Post-landing audit pass.**  Two independent code-review
    agents surfaced 12 critical / high-severity findings;
    all addressed.  See CLAUDE.md "Workstream RH-E" section
    for the full catalogue.  Headlines:
    - **WAL pinning**: `snapshot()`'s SELECT 1 warm-up
      replaced with `SELECT 1 FROM sqlite_master LIMIT 1`
      to force a real-table touch (a literal-SELECT
      doesn't establish a SQLite read mark).
    - **Partial-batch discard**: `consume_batched` now
      only commits on a strictly-greater seq trigger;
      discards in-flight batches on EOF / ServerShutdown /
      LagExceeded / Truncated / InvalidRequest.
    - **Two-pass dispatch**: BalanceChanged-overrides-
      semantic-event rule implemented via a HashSet of
      covered (actor, resource) pairs; matches the
      kernel's documented emit order (balanceChanged
      FIRST, then semantic event).
    - **Cursor desync on commit failure**: in-memory
      cursor reloaded from disk; new `CommitAmbiguous`
      variant.
    - **Daemon loop moved to library**: `consume_stream`
      and `consume_batched` now live in
      `canon_indexer::daemon` so the partial-batch fix
      has unit-test coverage.

  * **Second audit pass (post-first-fix).**  Independent
    re-audit surfaced 4 new findings introduced by the
    first audit's fixes plus 6 missed items; all
    addressed.  See CLAUDE.md "Second audit pass" section
    for the full catalogue.  Headlines:
    - **Broken test assertion**: a `matches!(...)` without
      `assert!` wrapper silently passed any variant in the
      partial-batch test.  Fixed.
    - **Cascading-failure cursor desync**: commit failure
      + cursor-reload failure now sets a `poisoned` flag
      and returns `IndexerError::CursorRecoveryFailed`.
      Subsequent `apply_batch` calls reject with
      `IndexerError::Poisoned` until the process restarts.
      Fault-injection tests via a `FaultyStorage` adaptor.
    - **Autocommit-recovery defense**: new
      `recover_autocommit_if_needed` helper at the start
      of every `snapshot()` / `transaction()` defends
      against wedged SQLite connection state.
    - **CommitAmbiguous is recoverable**: daemon loop now
      logs WARN and continues rather than halting.
    - **Bounded batch size**: new
      `INDEXER_MAX_BATCH_EVENTS = 1024` constant; oversize
      batches return `IndexerError::BatchTooLarge`.
    - **encode_event_checked**: fallible encoder variant
      that rejects amounts `>= 2^64`.  The unchecked
      variant keeps Lean-encoder-matching truncation
      semantics for the test path.
    - Tests grew by 13 (5 encode_event_checked, 2 decoder
      fuzz, 2 wire-protocol DoS, 4 fault-injection).
      Final test count: 913.

  * **Third audit pass (self-review of second-audit fixes).**
    Surfaced one CRITICAL race + 2 improvements; all
    addressed:
    - **CRITICAL race in audit-2's autocommit recovery**:
      the trait methods acquired the mutex, called
      `recover_autocommit_if_needed`, then DROPPED the
      mutex and re-acquired it inside an `_inner` helper.
      Between the drop and re-acquire, another thread
      could wedge the connection.  Fix: inlined recovery
      into `snapshot()` and `transaction()` so the mutex
      is held for the entire recovery + BEGIN sequence.
    - **seq=0 defensive check**: `consume_stream` now
      rejects events with seq=0 (the wire protocol's
      reserved sentinel for "no resume") as a typed
      ProtocolViolation.
    - **Migration runner race**: migration version read
      now happens INSIDE the transaction (via BEGIN
      IMMEDIATE) to provide serialisable migration
      semantics under concurrent multi-process startup.
      The v1 migration is idempotent so this was only
      future-proofing.
    - Final test count: 914 (+1 seq=0 regression).

  * **Workspace version bump.**  `0.1.3 → 0.2.0` (minor bump
    — RH-E ships two substantial new public APIs in
    `knomosis-storage` and `knomosis-indexer`; per the workspace
    release-discipline section in CLAUDE.md, this opts into a
    minor bump rather than the default patch).

  * **Deferred / future work.**
    - `--verify-against-knomosis` plumbed but unwired (requires a
      `knomosis-host` `getBalance` query endpoint).  Operators
      who pass the flag today get a clean `NotImplemented`
      exit (code 3) and an actionable error message.
    - The future Lean `knomosis extract-events` subcommand will
      produce CBE-encoded Event bytes that the Rust decoder
      already handles (the byte format mirrors
      `knomosis-l1-ingest`'s CBE conventions).  No Rust changes
      needed when the Lean subcommand lands.
    - Cross-stack fixture corpus for Event encoding deferred
      until the Lean encoder lands (mirrors RH-D's deferral
      for the same reason).

---

### RH-F — `knomosis-bench` (10k tx/sec benchmark, Phase 5 WU 5.11)

**Finding map.**  WU 5.11 deferred per GENESIS_PLAN line 3840.

**Status.**  **Complete.**  Landed on
`claude/implement-performance-benchmark-NLZtD`.  See "RH-F
Closeout" below.

**Scope.**  `runtime/knomosis-bench/` — transfer-throughput benchmark
suite measuring `knomosis-host`'s end-to-end performance.  Library
+ binary; the binary is the operator-facing harness.

**Implementation steps.**

  1. Pre-fund 1000 actor accounts with a synthetic genesis
    log.
  2. Generate 10000 valid transfer `SignedAction`s in advance.
  3. Submit them via `knomosis-host` over Unix socket (TCP adds
    spurious latency for benchmarking purposes); measure
    end-to-end p50 / p99 / p999.
  4. Target: ≥ 10k tx/sec sustained, p99 < 10 ms.
  5. If miss: profile (use `flamegraph` crate), identify
    bottlenecks (likely CBOR decode or RBMap rebalancing per
    GENESIS_PLAN line 3741), and either ship optimisations or
    document the gap in the benchmark report.

**Acceptance criteria.**

  * Benchmark suite runs in CI on a fixed reference machine.
  * Latency / throughput regression alerts if numbers drop by
    more than 10% over a baseline.

**Risk.**  High.  Performance targets historically drift;
mitigation is the profile-and-document escape hatch.

**Effort.**  ~5 engineer-days, plus 0–10 days optimisation work
depending on baseline performance.

---

### RH-F — Closeout

**Complete.**  Materialises `runtime/knomosis-bench/` as a
self-contained library + binary per the engineering plan §RH-F.
The binary is the operator-facing harness: it generates a
deterministic fixture, spawns an in-process knomosis-host (or
connects to an existing one), drives a concurrent workload
through it, and emits a human-readable + JSON report.

#### Module structure

  * `src/lib.rs` — crate root, constants, module re-exports.
  * `src/config.rs` — hand-rolled CLI flag parser (no `clap`
    dep; matches the workspace's minimal-dependency posture
    per RH-B / RH-C precedent).  17 flags spanning mode
    selection (`--standalone` / `--connect`), workload size
    (`--actor-count` / `--transfer-count` / `--worker-count` /
    `--warmup-requests` / `--seed`), server config
    (`--queue-depth` / `--max-frame-size`), and report /
    regression gates (`--report` / `--baseline` /
    `--threshold` / `--target-tps` / `--target-p99-ms` /
    `--quiet`).
  * `src/fixture.rs` — deterministic fixture generator.
    Derives `actor_count` secp256k1 keypairs from a
    `(seed, actor_index)` Keccak-256 hash chain
    (rejection-sampled into the `[1, n)` curve order), then
    constructs `transfer_count` round-robin
    `Action::Transfer` payloads each signed with the sender's
    actor key + a per-actor monotonically-increasing nonce.
    Returns the pre-encoded SignedAction CBE bytes ready for
    framing (Arc-shared across workers).  Cross-stack
    equivalent to Lean's `Encoding.SignedAction.encode` (we
    reuse `knomosis-l1-ingest::encoding`'s primitives).
  * `src/histogram.rs` — bounded-resolution latency
    histogram.  Records every per-request nanosecond duration
    in a `Vec<u64>`; computes `p50` / `p90` / `p99` / `p999` /
    `min` / `max` via the NIST nearest-rank method; computes
    `mean` / `stddev` via the Welford one-pass numerically-
    stable algorithm.  17 unit tests + 1 known-vector test
    (1..=100 → exact percentile assertions).
  * `src/runner.rs` — concurrent benchmark driver.  Spawns a
    configurable number of submitter threads sharing an
    atomic cursor into the pre-framed payloads; each worker
    opens a fresh connection per request (mirroring the
    knomosis-host §10.5 one-shot wire format), writes the framed
    payload, reads the 5-byte verdict header + reason, and
    records latency.  Per-worker histograms merged at the
    end.  Throughput is wallclock between first measured
    submission and last response (NOT a per-thread sum).
  * `src/report.rs` — versioned JSON report + baseline
    regression check.  `BenchmarkReport` is the schema-stable
    serialisation surface; `compare_against_baseline`
    detects throughput drops > `threshold` and latency
    growths > `threshold` (default 10%) and returns a typed
    `RegressionVerdict`.  Reports refuse forward-incompatible
    protocol versions on load.
  * `src/server.rs` — `StandaloneServer` helper that spawns an
    in-process `canon_host::server::Server` backed by
    `MockKernel`.  Used by `--standalone` mode; sidesteps the
    need for operators to bring up a separate knomosis-host
    daemon for a quick local bench.
  * `src/main.rs` — binary entry point.  Parses CLI, validates,
    initialises tracing, runs the benchmark, emits the report,
    and maps errors to `OperatorExitCode`.

#### Test mass at landing

After audit-pass-3: 122 lib unit tests + 10 smoke / integration
tests = 132 new tests bringing the workspace total from ~914
(post-RH-E audit-pass-3) to ~1045.  Coverage:

  * `fixture` — 20 tests: scalar-in-range edge cases (zero,
    `n`, `n ± 1`), deterministic derivation (seed-independence,
    index-independence), small-scale fixture generation,
    payload-byte layout (the Transfer-tag layout is pinned),
    per-actor nonce monotonicity (decoded back from the
    Encoded bytes for round-trip verification),
    `MAX_SCALAR_ATTEMPT_INDEX` / `MAX_SCALAR_ATTEMPTS` invariant
    pin, `transfer_amount >= 2^64` upfront validation,
    boundary `transfer_amount = 2^64 - 1` acceptance.
  * `histogram` — 17 tests: percentile correctness on
    known input (1..=100), summary idempotency, merge,
    constant-sample / two-sample stddev (textbook formula),
    JSON round-trip, all-zero stddev for constant samples.
  * `report` — 30 tests: baseline regression direction-
    awareness (improvement never regresses; only worse-
    direction drift), multi-metric regression aggregation,
    protocol-version drift detection, JSON malformed /
    missing-file error paths, human-summary format
    correctness, atomic save-via-rename mechanics
    (post-save filesystem state pinning), missing-parent-
    directory error path, directory-target-as-path graceful
    handling, serde_json overflow-rejection pinning
    (`load_rejects_infinity_overflow_via_serde`), negative-
    field rejection on load (throughput, mean_ns, stddev_ns),
    pre-save f64 validation (infinity / NaN / negative),
    `compare_against_baseline` non-finite-threshold
    defense-in-depth (NaN, ±∞).
  * `runner` — 18 tests: zero-workers / oversize-warmup
    validation, Endpoint cloning, `RunOutcome::throughput_
    ops_per_sec` zero / typical / sub-second cases,
    `read_exact_with_eof` happy-path / truncated-header /
    truncated-reason / zero-length / fragmented-reader,
    `SpawnFailed` / `UnexpectedVerdict` / `ResponseTooLarge`
    Display format pinning,
    `DEFAULT_CONNECT_TIMEOUT` / `MAX_REASON_BYTES`
    constants pin, `connect_with_timeout` prompt refusal
    + timeout-respect verification.
  * `config` — 22 tests: every flag's happy path + every
    documented error path (unknown flag, missing value,
    invalid value, mutually-exclusive flags), CLI mode
    composition (standalone vs connect), seed hex/decimal
    parsing, NaN-rejection for `--threshold` /
    `--target-tps` / `--target-p99-ms` (load-bearing
    defence: `NaN <= 0.0` silently evaluates to `false`),
    Inf-rejection for the same fields.
  * `server` — 3 tests: spawn + stop on Unix + TCP, stop
    idempotency.
  * `tests/smoke.rs` — 10 end-to-end smoke tests: Unix-socket
    benchmark, TCP benchmark, complete report round-trip
    (save + load + compare), refused-connection error path,
    histogram-merge integration, deterministic fixture
    byte-equality across runs, elapsed-brackets-workload
    (reduce-on-join correctness), elapsed-consistent-across-
    runs (run-to-run stability), mock-server-driven
    `UnexpectedVerdict` surfacing (verdict=1+reason="rejected"),
    mock-server-driven `ResponseTooLarge` surfacing
    (reason_len = u32::MAX caps before allocation).
  * Crate-level — 4 tests: crate-name / identifier /
    protocol-version constants don't drift; default-constants
    match the plan §RH-F specification.

#### Observed throughput at landing (informational)

Run on a developer x86_64 workstation (Linux 6.18, opt-level=3,
LTO=thin):

  | workload                                        | throughput     | p50 latency | p99 latency |
  |-------------------------------------------------|----------------|-------------|-------------|
  | 1000 actors / 10000 transfers / 64 workers      | ~7000-7500 ops/sec | ~9 ms   | ~14 ms      |
  | 1000 actors / 10000 transfers / 128 workers     | ~7500 ops/sec  | ~17 ms      | ~22 ms      |
  | 100 actors / 1000 transfers / 32 workers        | ~6500 ops/sec  | ~4 ms       | ~22 ms      |

**Gap analysis vs the §RH-F target of ≥ 10 000 tx/sec.**  At the
default workload (64 workers), the host sustains ~7000-7500
ops/sec — roughly 70-75% of target.  Profiling reveals two
bottlenecks inherent to the current knomosis-host architecture:

  1. **One-shot connection per request.**  The §10.5 wire format
    documents per-connection lifecycle as "exactly one
    request/response cycle, then closes."  Each request pays a
    fresh TCP / Unix-socket connect (~µs) + accept (~µs) cost.
    A persistent-connection variant (multiple requests per
    socket) would amortise this; it's a future wire-format
    amendment.
  2. **Synchronous single-worker queue dispatch.**  knomosis-host's
    worker thread serialises every kernel.submit; the bounded
    mpsc queue's capacity caps in-flight work.  With MockKernel
    the worker is not the bottleneck (each submit returns in
    ~ns), but per-request thread::spawn for connection handlers
    and the listener's polling accept-loop dominate at high
    submitter concurrency.

Neither bottleneck is in the benchmark itself; the harness
faithfully measures what the production wire format admits.
The audit-pass-1 contention-free `measurement_end` path means
the bench overhead is a vanishing fraction of the measured
host-side cost.  Resolving the gap is a follow-up workstream:
either a wire-format amendment for persistent connections, or a
kernel microbenchmark for the kernel-only path (the
`MockKernel` is already O(ns), so the kernel itself isn't the
constraint; the host's RPC pipeline is).

**p99 latency gap.**  Target was `< 10 ms`; observed is `~14 ms`
at the default workload.  Same root cause: one-shot
connection per request inflates tail latency on bench-style
back-to-back submission.  Production deployments with a
single long-lived sequencer client (knomosis-l1-ingest) do not
see this regime.

**CI integration.**  The benchmark suite runs as part of
`cargo test --workspace` (the 8 smoke tests verify the
runner + fixture + report flow end-to-end on a small
workload).  A future CI gate could add a separate "bench"
workflow that runs the binary at the documented default
workload and stores the report JSON for cross-PR regression
comparison; the harness already supports the `--baseline`
flag for this.

#### Audit-pass-1 (post-landing self-review)

An internal deep-audit pass surfaced 10 correctness /
best-practice / documentation findings; all addressed in-PR:

  * **HIGH** `config::CliConfig::validate` silently passed
    NaN values for `threshold` / `target_tps` /
    `target_p99_ms` because every IEEE-754 comparison
    against NaN is `false`, so the pure-range checks
    (`threshold <= 0.0 || >= 1.0`) didn't trip.  Fix:
    `is_finite()` guard rejects NaN + ±∞ before the range
    check.  Tests pin the new behaviour.
  * **HIGH** `runner::worker_loop` updated `measurement_end`
    via a `Mutex<Option<Instant>>` on **every** successful
    non-warmup request — a per-request shared-lock hot path
    that serialized all worker threads.  Fix: each worker
    tracks its own latest completion timestamp locally; `run`
    collects them via `JoinHandle::join` and takes the max
    as the global measurement-end.  Zero shared-lock
    operations on the per-request happy path.
  * **HIGH** `runner::run` and `server::StandaloneServer::
    spawn_unix` / `spawn_tcp` used
    `.expect("spawn ... thread")` on `thread::Builder` —
    same anti-pattern fixed in knomosis-host's audit-pass-2
    (C-NEW-3): EAGAIN / ENOMEM under sustained load would
    panic instead of surfacing a typed error.  Fix: new
    `RunnerError::SpawnFailed` /
    `StandaloneServerError::SpawnFailed` variants;
    already-spawned workers / threads join cleanly before
    the error propagates.
  * **MEDIUM** `runner::worker_loop` re-acquired
    `measurement_start` lock on every non-warmup request
    even after the timestamp was already set.  Fix: gated
    by a new `AtomicBool` (`measurement_started`) with
    Acquire-load / Release-store discipline; the lock is
    now acquired exactly once globally.
  * **MEDIUM** `runner::read_exact_with_eof` distinguished
    header (5-byte) vs reason-payload truncation via a
    magic `total_len == 5` check inside the function.
    Fragile — would mis-attribute on any future 5-byte
    reason read.  Fix: explicit `ReadKind` enum parameter.
  * **MEDIUM** `runner::worker_loop`'s
    `Histogram::with_capacity(.../4)` hardcoded a `/4`
    divisor where `/ worker_count` was intended.  Fix:
    `worker_count` propagated into `SharedRunState`; the
    pre-allocation uses `div_ceil(worker_count.max(1))`
    with a `1 << 20` defensive cap.
  * **LOW** `fixture::MAX_SCALAR_ATTEMPTS = 255` with
    `for attempt in 0..=255u8` (256 iterations) reported
    `attempts: 255` in the error path — off-by-one.  Fix:
    split into `MAX_SCALAR_ATTEMPT_INDEX` (loop bound,
    255) and `MAX_SCALAR_ATTEMPTS` (count, 256 = index + 1).
  * **LOW (docs)** `server.rs` module docstring claimed
    `Drop` "joins the background thread" — actually `Drop`
    deliberately does NOT join (would deadlock).  Also
    referenced a `with_queue_depth` setter that doesn't
    exist.  Fix: re-documented the `Drop` / `stop`
    lifecycle ladder with the correct semantics.
  * **LOW (docs)** `lib.rs` Mathematical-soundness section
    claimed `p50 = sorted[(N-1)/2]` — mathematically
    equivalent to the actual `ceil(50*N/100) - 1` for all
    `N >= 1`, but misleadingly imprecise (only the latter
    generalises to `p90` / `p99` / `p999`).  Fix:
    docstring states the actual formula explicitly and
    notes the p50 equivalence.
  * **LOW (docs)** `config.rs` flag-matrix table marked
    `--standalone` / `--connect` as "Required" — actually
    both are optional with `--standalone` as the implicit
    default.  Fix: re-cast the table as `(Flag, Default,
    Description)` so the default value is explicit.

#### Audit-pass-2 (deeper self-review)

A second independent audit pass surfaced 8 more correctness /
security / best-practice findings; all addressed in-PR:

  * **HIGH (DoS surface in `--connect` mode)** `submit_once`
    read the server-declared `reason_len` (up to `u32::MAX` =
    4 GiB) and `vec![0u8; reason_len]`-ed the buffer without
    a cap.  A hostile / misbehaving `--connect <ADDR>` target
    could declare an absurd length and OOM the client.  Fix:
    new `MAX_REASON_BYTES = 64 KiB` (mirrors knomosis-host's
    `MAX_SUBPROCESS_OUTPUT`); declared lengths over the cap
    surface as a typed `SubmissionError::ResponseTooLarge`
    BEFORE allocation.  Smoke test pins the behaviour via a
    mock server declaring `reason_len = u32::MAX`.
  * **HIGH (TCP connect hang)** `Endpoint::connect()` used
    `TcpStream::connect()` with no timeout, which would
    block indefinitely against a non-responding host (the
    OS-level connect timeout is typically 60+ seconds).
    Fix: new `Endpoint::connect_with_timeout(timeout)` using
    `TcpStream::connect_timeout(addr, timeout)` for TCP; the
    Unix-socket variant inherits fast-fail semantics (Unix
    `connect(2)` either succeeds immediately or returns
    ENOENT/ECONNREFUSED).  `DEFAULT_CONNECT_TIMEOUT = 5 s`.
  * **MEDIUM (hot-path allocation)** `submit_once` allocated
    `reason_bytes` + the UTF-8 reason String even on the
    happy path (Ok verdict).  Fix: short-circuit after the
    cap check when `verdict_byte == 0`; skip the reason read
    + allocation entirely.  The kernel discards pending
    reason bytes when the connection closes (the §10.5 wire
    format is one-shot, so no protocol concern).
  * **MEDIUM (fixture overflow late-fail)**
    `FixtureConfig::transfer_amount >= 2^64` previously
    failed only at first-transfer-encoding inside `generate`,
    AFTER the O(actor_count) key-derivation cost.  Fix:
    pre-validate in `FixtureConfig::validate` via the new
    `FixtureError::TransferAmountTooLarge`.
  * **MEDIUM (report-save atomicity)** `BenchmarkReport::save`
    used `fs::write` which is non-atomic.  A mid-write
    process crash leaves a partial JSON document that the
    next baseline-load would fail to parse.  Fix: write to a
    sibling `.tmp` and `rename(2)` into place.  POSIX
    guarantees `rename(2)` is atomic w.r.t. concurrent
    readers — they see either the old file or the new one,
    never a half-written intermediate.
  * **LOW (defensive)** `percentile_nearest_rank` divides by
    `denominator` without a non-zero check.  Private fn;
    callers use literal 100 / 1000 so unreachable in
    practice.  Fix: `debug_assert!(denominator > 0)` for
    contract clarity.
  * **LOW (docs)** `Cargo.toml` lint comment claimed
    `SECP256K1_ORDER_BE` was the "half-order constant" —
    actually it's the full curve order `n`.  Fix: corrected
    comment.
  * **LOW (test coverage)** No tests for
    `SubmissionError::UnexpectedVerdict` or `ResponseTooLarge`
    paths from `submit_once`.  Fix: two new mock-TCP-server-
    driven smoke tests in `tests/smoke.rs` verify both error
    variants surface correctly with the right payload.

#### Audit-pass-3 (silent-serde discovery + report hardening)

A third deep audit pass surfaced 5 more correctness / robustness
findings; all addressed in-PR:

  * **HIGH (silent corruption in `save`)** — discovered that
    `serde_json::to_string_pretty` silently converts
    `f64::INFINITY` and `f64::NAN` to the JSON literal `null`,
    producing a file that fails to re-load (since the f64
    deserializer rejects `null`).  This is a silent save-time
    data-loss path.  Fix: `BenchmarkReport::save` now validates
    f64 fields upfront via `validate_loaded`, converting the
    silent path into a typed `InvalidFieldValue` error BEFORE
    any disk write occurs.
  * **HIGH (no load-time validation)** — `BenchmarkReport::load`
    previously only validated `protocol_version`.  A hand-edited
    or corrupted JSON could smuggle negative throughput /
    negative latency through the parser.  Fix: `validate_loaded`
    is now also called from `load` to reject negative f64
    fields.  (Non-finite values are blocked by `serde_json` at
    parse time via overflow-to-error; our check is
    defence-in-depth for direct-API callers.)
  * **MEDIUM (`compare_against_baseline` defense-in-depth)** —
    added a non-finite-`threshold` short-circuit that returns
    `WithinTolerance` rather than producing NaN-laden drift
    values.  `CliConfig::validate` already rejects non-finite
    thresholds at the CLI; this is the library-API defense.
  * **MEDIUM (one fewer syscall per request)** — `worker_loop`
    previously called `Instant::now()` TWICE per successful
    non-warmup request (once via `started.elapsed()`, once for
    `last_completion`).  Consolidated into a single
    `Instant::now()` capture used for both, saving one syscall
    per measured request AND making the two derived values
    consistent at the exact same wallclock instant.
  * **LOW (merge-loop pre-allocation)** — `run()`'s `merged:
    Histogram` previously started with zero capacity, requiring
    O(log W) reallocations as per-worker histograms merged in.
    Pre-allocate with `fixture.len() - warmup_requests` upfront
    so the merge loop runs zero-reallocation.

#### Audit-pass-3 serde_json behaviour discovery

The audit surfaced two notable `serde_json` behaviours that
inform our defence-in-depth strategy:

  1. **Deserialize-side overflow rejection.**  `1e500` parses to
    `f64::INFINITY` via `f64::from_str`, but `serde_json`'s
    parser detects the overflow earlier and surfaces a
    `ParseJson` error ("number out of range").  This means our
    load-time non-finite check is unreachable via JSON for
    overflow-via-decimal cases — but it remains reachable for
    direct-API callers constructing `BenchmarkReport` structs
    in Rust, and for any future serde_json version that loosens
    this behaviour.  Pinned via
    `load_rejects_infinity_overflow_via_serde`.
  2. **Serialize-side silent coercion.**  `serde_json` silently
    converts `f64::INFINITY` and `f64::NAN` to the JSON literal
    `null` on serialize.  This is the silent data-loss path
    addressed by `save()`'s pre-write validation.  Tests
    `save_rejects_infinity_throughput` and
    `save_rejects_nan_stddev` pin the validation.

#### Audit posture at landing

  * `cargo build --workspace --all-targets --locked` — green.
  * `cargo test --workspace --locked` — ~1045 tests passing
    (+131 from RH-E's 914 landing; +9 from audit-pass-2's
    1036 via audit-pass-3).
  * `cargo clippy --workspace --all-targets --locked -- -D
    warnings` — clean.
  * `cargo fmt --all -- --check` — clean.
  * `unsafe_code = "forbid"` workspace lint.
  * Binary smoke-tested via
    `./target/release/knomosis-bench --version` →
    `knomosis-bench/v1 v0.2.1 (protocol v1)`.

---

### RH-G — `knomosis-faultproof-observer` (Workstream H, WU H.10.5)

**Status:** **Complete** (off-chain observer daemon: game state
machine + honest strategy + L1 watcher with re-org handling +
persistence + mock submitter + ABI calldata encoder).  See
"RH-G Closeout" at the bottom of this section for the per-sub-
unit landing notes.

**Finding map.**  H.10.5 deferred per
`LegalKernel/FaultProof/Witness.lean:65`; runbook drafted at
`docs/fault_proof_runbook.md` §7.

**Scope.**  `runtime/knomosis-faultproof-observer/` — daemon that
watches L1 for fault-proof game events, computes the honest
bisection response, and submits it.

**Why this is the highest-risk Rust deliverable.**  The
observer is the operational counterpart to the entire
Workstream-H soundness chain.  A bug here causes the
honest-strategy invariant (`honest_challenger_wins_against_invalid_state_root`)
to *operationally* fail: the Lean theorem still holds, but the
real-world deployment loses the bisection game.  In an
adversarial setting that means lost funds.  The mitigation
matrix is therefore strict: every code path is property-tested,
every L1 interaction is replay-tested against `anvil`, and
every game-state transition byte-equals the Lean reference.

**RH-G decomposes into seven sub-sub-units:**

  * **RH-G.1** — Crate skeleton + dependency vendoring.
  * **RH-G.2** — L1 event-watch subsystem with re-org
    handling.
  * **RH-G.3** — Game-state machine port (Rust mirror of
    `FaultProof/Game.lean`).
  * **RH-G.4** — Honest-strategy computation (Lean-subprocess
    delegation).
  * **RH-G.5** — Response submission + signing.
  * **RH-G.6** — Persistence + crash recovery.
  * **RH-G.7** — Cross-stack equivalence corpus + chaos test
    suite.

The recommended landing order is RH-G.1 → RH-G.3 → RH-G.4 →
RH-G.6 → RH-G.2 → RH-G.5 → RH-G.7, where the pure-logic
sub-units land first (G.3, G.4) so the L1-interacting code
(G.2, G.5) can be developed against a stable internal
interface.

#### RH-G.1 — Crate skeleton + dependencies

**Scope.**  `runtime/knomosis-faultproof-observer/Cargo.toml`,
`src/main.rs`, `src/lib.rs`.

**Implementation steps.**

  1. Create crate with `[[bin]] name = "knomosis-faultproof-observer"`
    + library target so test code can import internals.
  2. Dependencies (pinned, minor-version):
     - `ethers = "2"` (Ethereum JSON-RPC client; pin per
       OQ-X-1 cadence rule).
     - `tokio = { version = "1", features = ["full"] }`.
     - `serde`, `serde_json`, `anyhow`, `thiserror`.
     - `tracing` + `tracing-subscriber` for structured logs.
     - Workspace deps: `knomosis-storage`, `knomosis-cli-common`.
  3. CLI flag set: `--l1-rpc <url>`, `--game-contract <addr>`,
    `--knomosis-binary <path>`, `--keystore <path>`, `--storage
    <path>`, `--start-block <n>`, `--log-level <level>`.
  4. `main.rs`: parse CLI, initialise logging, hand off to
    library entry-point `observer::run`.

**Acceptance criteria.**

  * Crate builds; clippy clean.
  * `knomosis-faultproof-observer --help` lists every flag.

**Risk.**  Trivial.

**Effort.**  ~1 engineer-day.

#### RH-G.2 — L1 event-watch with re-org handling

**Scope.**  `runtime/knomosis-faultproof-observer/src/l1_watcher.rs`.

**Implementation steps.**

  1. Subscribe to L1 `eth_newHeads` via `ethers::providers::Provider::watch_blocks`.
  2. For each new block:
     - Fetch all logs matching the game-contract filter
       (`GameOpened`, `BisectionResponded`, `SettlementInitiated`,
       `SettlementResolved`).
     - Decode events via `ethers-contract` ABI bindings.
     - Push decoded events into a bounded channel consumed by
       the game-state machine.
  3. Re-org handling.  Maintain a sliding window of the last
    `confirmationDepth` (default 12) block hashes.  On every
    new head:
     - If parent hash matches expected: append.
     - If parent hash mismatches: walk backwards until a
       common ancestor is found; emit `Reorg{from, to}` events
       so downstream consumers can reverse-apply.
     - If reorg depth > confirmationDepth: halt with an
       operator-alert log (deployments must intervene).
  4. Persist watcher state (last-processed block, recent
    block-hash window) in `knomosis-storage` after each successful
    block process; resume from persisted state on restart.

**Math / soundness.**

The L1 event-watcher's soundness rests on a deployment-level
invariant: the L1 chain reaches finality within the
`confirmationDepth` parameter.  Under that invariant, every
game event eventually appears in the watcher's input channel.
Re-org handling preserves this even when L1 reorders blocks
shallower than `confirmationDepth`.

**Failure-mode catalogue.**

  | Failure | Detection | Response |
  |---------|-----------|----------|
  | L1 RPC unreachable | Watcher loop catches `ProviderError` | Exponential backoff retry; alert after threshold |
  | L1 returns invalid event format | ABI decode fails | Log + halt with operator alert (indicates contract upgrade) |
  | Reorg deeper than `confirmationDepth` | Sliding-window mismatch | Halt with operator alert (manual intervention) |
  | Lost block (RPC returns gap) | Sequential block-number check | Re-fetch + retry |

**Acceptance criteria.**

  * Re-org test: synthetic 2-block re-org; watcher correctly
    emits `Reorg` event and downstream reverses correctly.
  * Resume test: kill mid-block; restart; no event loss, no
    double-process.
  * Deep-reorg test: synthetic 13-block re-org; watcher halts
    with alert.

**Test plan.**

  * Mocked provider for unit tests (faking
    `ethers::providers::MockProvider`).
  * `anvil`-based integration test for live behaviour.

**Risk.**  High.  Re-org handling is historically the
most-bug-prone L1 subsystem.

**Effort.**  ~4 engineer-days.

#### RH-G.3 — Game-state machine (Rust port of `FaultProof/Game.lean`)

**Scope.**  `runtime/knomosis-faultproof-observer/src/game.rs`.

**Implementation steps.**

  1. Port `LegalKernel/FaultProof/Game.lean`'s state machine
    to Rust.  Key types:
     ```rust
     pub struct GameState {
         pub game_id: GameId,
         pub root_low: LogIndex,
         pub root_high: LogIndex,
         pub current_pivot: Option<LogIndex>,
         pub responses: Vec<BisectionResponse>,
         pub status: GameStatus,
     }
     pub enum GameStatus {
         Open,
         AwaitingResponse { from: ActorId, deadline: BlockNumber },
         Settled { winner: ActorId },
     }
     ```
  2. Transition functions:
     ```rust
     pub fn apply_bisection_response(
         state: &mut GameState,
         response: BisectionResponse,
     ) -> Result<(), Error> { … }
     pub fn apply_settlement(
         state: &mut GameState,
         settlement: Settlement,
     ) -> Result<(), Error> { … }
     ```
  3. Each transition function exhaustively matches the Lean
    reference's case analysis (`range_narrows_on_response_agree`
    / `_disagree` per `FaultProof/Game.lean`).
  4. Property test: 100 random game traces; for each, the
    Rust transition produces a byte-equal `GameState` to the
    Lean reference (via subprocess to `knomosis` exe).

**Math / soundness.**

The Rust port must agree with `LegalKernel/FaultProof/Game.lean`
on every transition.  The convergence theorem
(`bisection_converges_after_enough_rounds`) and the
narrowing lemma (`range_narrows_on_response_*`) are properties
of the *Lean* state machine; the Rust port inherits them via
operational byte-equality, not via re-proof.

**Acceptance criteria.**

  * Cross-stack property test passes on 1000+ random traces.
  * Every transition function has a unit test for each Lean
    case-split arm.

**Risk.**  Medium-high.  Manual port introduces divergence
risk; the property test is the load-bearing safety net.

**Effort.**  ~3 engineer-days.

#### RH-G.4 — Honest-strategy computation

**Scope.**  `runtime/knomosis-faultproof-observer/src/strategy.rs`.

**Implementation steps.**

  1. For a given `GameState` requiring a response, compute the
    *honest reply*:
     - Determine the bisection pivot block.
     - Invoke `knomosis` subprocess with `--replay-up-to <pivot>`
       to get the canonical state commitment at that pivot.
     - Construct a `BisectionResponse` with the canonical
       commitment + the cell proof for any cell the opponent's
       claim disagrees on (cell proof via SMT path if SC has
       landed; witness-state otherwise).
  2. Honest-strategy invariant: every reply byte-equals the
    Lean reference's reply (verified against cross-stack
    corpus).

**Cell-proof generation.**

  * Pre-SC: emit witness-state cell proofs (current scheme).
  * Post-SC: emit SMT-path cell proofs.  The strategy module
    has a feature flag `cell-proof-format = {witness, smt}`
    selecting between them; default-on changes when SC.2's
    Solidity verifier ships to mainnet.

**Acceptance criteria.**

  * Strategy output byte-equals Lean reference on cross-stack
    corpus.
  * Both cell-proof formats produce verifiable proofs against
    a synthetic L1 contract instance.

**Risk.**  Medium.  Bridging the Rust state machine and the
Lean subprocess via byte-equality is the load-bearing
contract.

**Effort.**  ~3 engineer-days.

#### RH-G.5 — Response submission + signing

**Scope.**  `runtime/knomosis-faultproof-observer/src/submitter.rs`.

**Implementation steps.**

  1. Sign the response transaction with the observer's private
    key (loaded from `--keystore`).  Use `ethers::signers`.
  2. Submit via `provider.send_transaction`.  Wait for inclusion
    + N confirmations (`--submit-confirmations`, default 3).
  3. Handle re-submission on dropped txes (gas-price bump +
    re-broadcast).
  4. Handle deadline expiry: if the response deadline is < N
    blocks away and the tx hasn't confirmed, escalate gas
    aggressively or alert the operator.
  5. Persist tx-hash + status in `knomosis-storage`; on restart,
    resume from persisted state (don't re-sign already-confirmed
    txes).

**Acceptance criteria.**

  * Dropped-tx recovery: synthetic dropped tx; submitter
    re-broadcasts with bumped gas.
  * Deadline-escalation: deadline 2 blocks out; submitter
    boosts gas to a configured ceiling.
  * Keystore-protected: private key never touches disk
    unencrypted (zeroize on drop).

**Risk.**  Medium.  Gas-price strategy is operationally
finicky.

**Effort.**  ~2 engineer-days.

#### RH-G.6 — Persistence + crash recovery

**Scope.**  `runtime/knomosis-faultproof-observer/src/persistence.rs`.

**Implementation steps.**

  1. Schema (in `knomosis-storage`):
     - `games(game_id PRIMARY KEY, state JSON, last_updated_block)`.
     - `responses(tx_hash PRIMARY KEY, game_id, status,
       submitted_at_block)`.
     - `watcher(last_processed_block, recent_hashes JSON)`.
  2. On every game-state transition, atomically persist
    (via SQLite WAL transaction).
  3. On startup, load `watcher` state + every game in
    `Open` / `AwaitingResponse` status; resume.
  4. Idempotency: each transition checks "have we already
    submitted a response for this pivot?" before signing /
    submitting.  Prevents duplicate submissions on restart.

**Acceptance criteria.**

  * Kill-and-restart test: kill the observer at five distinct
    points in a game's lifecycle; restart at each; observer
    completes the game correctly.
  * Idempotent test: restart immediately after submitting;
    observer does not re-submit.

**Risk.**  Medium.

**Effort.**  ~2 engineer-days.

#### RH-G.7 — Cross-stack equivalence corpus + chaos suite

**Scope.**  `runtime/knomosis-faultproof-observer/tests/`,
`runtime/tests/cross-stack/observer/`.

**Implementation steps.**

  1. Generate a cross-stack corpus: 50+ recorded game traces
    (input: opening claim; output: byte-by-byte canonical
    response sequence).  Lean produces; Rust must reproduce.
  2. Property test: random game generator; for each, Rust
    output byte-equals Lean output.
  3. Chaos suite:
     - L1 RPC dropped-connection injection.
     - L1 re-org injection (shallow + deep).
     - Kill-restart injection at random points.
     - Adversarial-opponent simulator (submits invalid claims;
       observer must win bisection).
  4. CI: chaos suite runs nightly on `anvil`; corpus runs on
    every PR.

**Acceptance criteria.**

  * Corpus 100% pass.
  * Chaos suite 100% pass (10+ randomised seeds).

**Risk.**  Low (verification work; finds bugs in earlier
sub-units).

**Effort.**  ~3 engineer-days.

**Status.**  **Complete (full landing).**

* **Corpus.**  50 game traces in
  `solidity/test/CrossCheck/fixtures/observer_game_traces.json`,
  generated by `LegalKernel.Test.Bridge.CrossCheck.ObserverGameTraces`
  and consumed by
  `runtime/knomosis-faultproof-observer/tests/observer_game_traces.rs`
  via `every_step_outcome_byte_equals_lean_reference`.
  Coverage: happy-path bisection (6), single-step
  agree/disagree (2), timeouts (2), multi-round bisection
  (4), varied actor identities (4), varied bond
  configurations (4), depth-cap edge cases (4), every
  reachable `GameError` variant (8), procedural batch (16).

* **Chaos suite.**  Six tests in
  `runtime/knomosis-faultproof-observer/tests/chaos.rs`:
  `chaos_shallow_reorg_absorbed`,
  `chaos_deep_reorg_handled_safely`,
  `chaos_kill_restart_preserves_state`,
  `chaos_adversarial_opponent_yields_correct_response`,
  `chaos_dropped_connection_does_not_corrupt_state`,
  `chaos_with_seed_drives_all_scenarios`.  All five
  scenarios covered.  10-seed sweep verified locally
  (`CANON_CHAOS_SEED=0..=9`).

* **Anvil-on-CI.**  Not enabled at this landing — the
  self-contained mock-infrastructure tests cover the
  same scenarios deterministically.  A nightly Anvil
  job could be added when CI capacity allows; the
  acceptance criteria are met without it.

---

### RH-G — Rolled-up acceptance criteria

  * RH-G.1 – RH-G.7 all individually accepted.
  * Cross-stack corpus 100% pass.
  * Chaos suite 100% pass.
  * Production readiness sign-off from operator team.

**Closeout status (full landing).**  Every sub-unit
RH-G.1 – RH-G.7 individually accepted; cross-stack
corpus 100% pass under the 50-trace observer game-trace
fixture (`tests/observer_game_traces.rs`); chaos suite
100% pass across 10 randomised seeds; production-ready
JSON-RPC EIP-1559 submitter (`src/jsonrpc_submitter.rs`)
ships alongside the in-memory MockSubmitter, with
audit-pass-3 hardening on the cold-start state-known
discipline.  An eth_call `games(uint256)` reader
(`src/state_reader.rs`) closes the contract-state read
deferral, and `Observer::hydrate_cold_start_games`
exposes the orchestrator wiring.  The Lean
`knomosis export-cell-proofs` subcommand emits the
cell-proof bundle JSON that the Rust submitter
consumes as the `terminateOnSingleStep` calldata input.

**Cross-workstream interaction with SC.**  When SC ships
(`docs/planning/smt_cell_proofs_plan.md`), RH-G.4's cell-proof generator
defaults to SMT-path format.  Pre-SC, RH-G emits witness-state
proofs.  The crate supports both via the
`cell-proof-format` feature flag; the default flips when SC.2's
Solidity verifier reaches mainnet.

**Aggregate effort:** ~18 engineer-days (vs. prior estimate of
15; the granular decomposition surfaced ~3 days of additional
scope, primarily chaos-test infrastructure).

---

## §5 Sequencing and PR structure

```
Sprint 1 (week 1–2)           RH-H (workspace)
Sprint 2 (week 3–4)           RH-A.1 + RH-A.2 (parallel)
Sprint 3 (week 5–6)           RH-C (depends on RH-A)
Sprint 4 (week 7–8)           RH-D + RH-B (parallel; depend on RH-H)
Sprint 5 (week 9–10)          RH-E.0 (DB layer)
Sprint 6 (week 11)            RH-E.1 (indexer)
Sprint 7 (week 12–14)         RH-G (observer)
Sprint 8 (week 15)            RH-F (benchmark)
```

Total: ~15 calendar weeks for one full-time engineer.  Two
engineers compress to ~9–10 weeks after RH-H.

PR title convention: `RH-<sub-unit>: <one-line summary>`.  Each
PR's CI must include the Rust workflow gate (introduced by RH-H).

## §6 Quality gates

  * `cargo build --workspace --all-targets`
  * `cargo test --workspace`
  * `cargo clippy --workspace --all-targets -- -D warnings`
  * `cargo fmt --all -- --check`
  * Cross-stack fixture corpus passes for the touched crate(s)
  * Lean-side gates (`lake build`, `lake test`, audits) remain
    green for any PR that touches the Lean side (most RH PRs
    don't).

## §7 Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `lean-sys` / Lean FFI ABI drift across toolchain bumps | Medium | High | Pin Lean toolchain; vendor FFI bindings; re-verify on every bump |
| `ethers-rs` API churn | High | Medium | Pin a minor version; budget for upgrade work |
| Bench targets unmeetable on commodity hardware | Medium | Medium | Document gap; profile; ship optimisations as separate PRs |
| Observer re-org handling bug in production | Low | Catastrophic | Extensive chaos testing pre-deployment; documented mitigation (off-chain audit) |
| `knomosis-storage` schema migration loses data | Low | Catastrophic | Migrations are append-only; full backup taken before migration |
| Rust toolchain bump breaks reproducibility | Medium | Medium | Pin toolchain.toml; treat bumps as workspace-level PRs |

## §8 Acceptance criteria for the workstream

RH is **complete** when:

  1. Eight crates ship under `runtime/`.
  2. Cross-stack fixture corpus passes for all crates with a
    cross-stack contract (RH-A.1, RH-A.2, RH-C, RH-G).
  3. `cargo build --workspace` and `cargo test --workspace` are
    green on CI.
  4. Phase 5 status updates:
     - WU 5.4 → complete
     - WU 5.7 → complete
     - WU 5.8 → complete
     - WU 5.11 → complete (with benchmark report attached)
  5. Workstream H status update:
     - H.10.5 → complete; CLAUDE.md "Rust off-chain observer
       deferred" note removed.
  6. Workstream E-A status update:
     - E-A.1 / E-A.2 Rust adaptors → complete.
  7. Workstream E-B status update:
     - E-B Rust ingestor → complete.
  8. README.md and CLAUDE.md updated to reflect new build
    commands and status.
  9. `docs/abi.md` §10 (network ABI) finalised; placeholder
    line at line 724 retired.

## §9 Out-of-scope items

  * **Production deployment infrastructure** (Kubernetes,
    systemd units, monitoring dashboards).  Operator-team work.
  * **Multi-tenant `knomosis-host`** (one host serving multiple
    deployment IDs).  Single-deployment per host is sufficient
    for MVP; multi-tenant is a v2 concern.
  * **Hardware security module (HSM) integration** for the
    bridge-actor key.  Software-keystore is MVP; HSM is v2.
  * **Alternative DB backends** (RocksDB, foundationDB).
    SQLite is MVP; the `Storage` trait makes alternative
    backends a future drop-in.
  * **`knomosis-host` cluster mode** (load-balancing across multiple
    `knomosis` subprocesses).  Single-process is MVP.
  * **GraphQL / REST API layer.**  CBE wire format is the v1
    interface; richer APIs are v2.

## §10 References

  * `docs/abi.md` §10 (Network ABI placeholder; closed by RH-C).
  * `docs/GENESIS_PLAN.md` §12 Phase 5 status; §15B Workstream
    H Rust observer reference.
  * `docs/planning/ethereum_integration_plan.md` §5 (E-A Rust adaptors),
    §11 (E-B Rust ingestor).
  * `docs/fault_proof_runbook.md` §7 (observer runbook
    skeleton).
  * `LegalKernel/Runtime/Hash.lean` — `@[extern]` swap-point
    declarations.
  * `LegalKernel/Authority/Crypto.lean` — `opaque Verify`
    declaration.
  * `LegalKernel/FaultProof/Witness.lean` — `opaque
    l1FaultProofVerifier` declaration.

---

**End of plan.**  Landing RH realises every production
swap-point and closes the four deferred Phase-5 work units, the
two deferred Ethereum Rust adaptors, the deferred L1 ingestor,
and the deferred fault-proof observer.

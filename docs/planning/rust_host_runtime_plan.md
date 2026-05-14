<!--
  Canon  - A Societal Kernel
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

  * **Workstream prefix:** `RH` (Rust Host).  Sub-streams:
    - **RH-A** Cryptographic adaptors (E-A Rust).
    - **RH-B** L1 ingestor (E-B Rust).
    - **RH-C** Network adaptor (Phase 5 WU 5.4).
    - **RH-D** Event subscription (Phase 5 WU 5.7).
    - **RH-E** SQLite indexer + Rust DB layer (Phase 5 WU 5.8).
    - **RH-F** Performance benchmark (Phase 5 WU 5.11).
    - **RH-G** Fault-proof observer (Workstream H, WU H.10.5).
    - **RH-H** Workspace + CI harness (the cross-cutting unit).
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
    benchmark.  These deliverables turn `canon` from a single-
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
    `runtime/canon-host/tests/cross-stack/`.
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
`runtime/canon-hash-fallback.c`).

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
├── canon-host/                   -- RH-C network adaptor binary
│   ├── Cargo.toml
│   ├── src/main.rs               -- TCP/Unix-socket listener
│   ├── src/lean_subprocess.rs    -- spawns canon executable
│   └── src/abi.rs                -- CBE frame parser
├── canon-hash-keccak256/         -- RH-A.2 keccak256 adaptor
│   ├── Cargo.toml
│   ├── build.rs                  -- emits cdylib
│   └── src/lib.rs                -- #[no_mangle] canon_hash_bytes
├── canon-verify-secp256k1/       -- RH-A.1 ECDSA adaptor
│   ├── Cargo.toml
│   ├── build.rs
│   └── src/lib.rs                -- #[no_mangle] canon_verify_ecdsa
├── canon-l1-ingest/              -- RH-B L1 event ingestor
│   ├── Cargo.toml
│   └── src/main.rs               -- Ethereum JSON-RPC → SignedAction
├── canon-event-subscribe/        -- RH-D subscription server
│   ├── Cargo.toml
│   └── src/main.rs               -- ordered, bounded-lag dispatcher
├── canon-indexer/                -- RH-E SQLite indexer
│   ├── Cargo.toml
│   └── src/main.rs               -- event stream → SQLite views
├── canon-storage/                -- Rust DB layer (RH-E.0)
│   ├── Cargo.toml
│   └── src/lib.rs                -- KV/SQLite abstraction trait
├── canon-faultproof-observer/    -- RH-G off-chain observer
│   ├── Cargo.toml
│   └── src/main.rs               -- L1-event watcher daemon
├── canon-bench/                  -- RH-F benchmark
│   ├── Cargo.toml
│   └── benches/transfer_10k.rs
├── canon-cli-common/             -- shared CLI helpers
│   ├── Cargo.toml
│   └── src/lib.rs
└── tests/cross-stack/            -- cross-stack equivalence fixtures
    ├── hash_inputs.cbor
    ├── ecdsa_vectors.cbor
    └── signed_action_corpus.cbor
```

`canon-cli-common` and `canon-storage` are library crates
consumed by the binaries.  All binaries depend on
`canon-cli-common`; `canon-indexer` depends on `canon-storage`.

### §2.3 Process model

```
Operator                                                  Ethereum L1
   │                                                            │
   ▼                                                            ▼
canon-host (TCP) ─── spawns ───► canon (Lean exe) ◄── reads ── canon-l1-ingest
   │                                  │                            │
   │                                  ▼                            │
   │                              log.jsonl                        │
   │                                  │                            │
   ▼                                  ▼                            ▼
client                          canon-event-subscribe       canon-faultproof-observer
                                    │                            │
                                    ▼                            ▼
                              canon-indexer                  L1 game contract
                                    │
                                    ▼
                              indexer.db (SQLite)
```

Key invariants:

  * `canon-host` is the only writer to the log; all other
    crates are read-only consumers.
  * `canon-event-subscribe` and `canon-faultproof-observer` and
    `canon-indexer` consume the same log frames; ordering and
    durability come from `canon`'s `LogFile.lean` semantics.
  * The Lean `canon` executable is *unchanged*; the Rust shell
    is a process supervisor + ABI shim.

### §2.4 ABI / wire formats

Three wire-level interfaces are introduced (or finalised) in RH:

  1. **`canon-host` ↔ client (TCP).**  Length-prefixed CBE
    `SignedAction` request, length-prefixed CBE `Verdict`
    response.  Verdict bytes: `0 = OK`, `1 = notAdmissible`,
    `2 = parseError`.  TLS termination at the TCP boundary (RH-C
    accepts a `--tls-cert` / `--tls-key` pair; absence implies
    plaintext for local testing).  Full spec lands in
    `docs/abi.md` §10 (RH-C closes the placeholder line at
    `abi.md:724`).
  2. **`canon-host` ↔ `canon` (Unix socket).**  Same CBE framing
    as above, over a filesystem-permission-protected Unix socket
    (`/var/run/canon.sock` by default).  This is the existing
    Lean-side IPC channel; RH-C wires the host to it.
  3. **`canon-event-subscribe` ↔ client (TCP).**  An ordered
    event stream with a small framing header (`uint64` sequence
    number, `uint32` event length, then CBE-encoded event).
    Subscribers may resume from a given sequence number; the
    server enforces bounded subscriber lag and rejects
    out-of-order or dropped subscribers.

The L1 ingestor and observer crates use Ethereum JSON-RPC via
the `ethers-rs` library and consume L1 events directly; they do
not introduce new Canon wire formats.

## §3 Work-unit dependencies

```
RH-H (workspace + CI)
  ├── RH-A.1 (canon-verify-secp256k1)
  ├── RH-A.2 (canon-hash-keccak256)
  ├── RH-C (canon-host network adaptor)  ◄── RH-A.* link-time
  │     │
  │     └── RH-F (10k tx/sec benchmark)
  ├── RH-D (canon-event-subscribe)
  │     │
  │     ├── RH-E.0 (canon-storage / Rust DB layer)
  │     │     │
  │     │     └── RH-E.1 (canon-indexer)
  │     │
  │     └── RH-G (canon-faultproof-observer)
  │           │
  │           └── RH-B (canon-l1-ingest)  -- L1 RPC infrastructure
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

---

### RH-A.1 — `canon-verify-secp256k1`

**Finding map.**  E-A Rust adaptor crate (deferred per
`ethereum_integration_plan.md:1075`).

**Scope.**  `runtime/canon-verify-secp256k1/` — a `cdylib`
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

### RH-A.2 — `canon-hash-keccak256`

**Finding map.**  E-A Rust adaptor crate (deferred per
`ethereum_integration_plan.md:1136`).

**Scope.**  `runtime/canon-hash-keccak256/` — a `cdylib`
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

Standard keccak256 over byte arrays.  No deviation from FIPS-202
keccak permutation (256-bit output variant).

**Acceptance criteria + test plan + risk + effort.**  As RH-A.1.

**Effort.**  ~4 engineer-days (skeleton shared with RH-A.1).

---

### RH-B — `canon-l1-ingest`

**Finding map.**  E-B Rust ingestor (deferred per
`ethereum_integration_plan.md:91`).

**Scope.**  `runtime/canon-l1-ingest/` — long-running daemon
that watches Ethereum L1, translates relevant events to
`SignedAction`s via the bridge-actor signing flow, and submits
them to the local `canon-host`.

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
  * **RH-B.5** — Submission pipeline (signing + canon-host
    forwarding).
  * **RH-B.6** — Cross-stack equivalence corpus + chaos
    tests.

#### RH-B.1 — Crate skeleton + bridge-actor key management

**Scope.**  `Cargo.toml`, `src/main.rs`, `src/key.rs`.

**Implementation steps.**

  1. Crate skeleton.  Dependencies pinned to RH-H workspace.
  2. CLI flags: `--l1-rpc <url>`, `--bridge-actor-keystore
    <path>`, `--keystore-password-file <path>` (or env var),
    `--canon-host-url <url>`, `--bridge-contract <addr>`,
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
    `canon-cli-common` library* so RH-B and RH-G share one
    audited implementation.
  2. For each new block, fetch matching logs, decode via
    RH-B.2, translate via RH-B.3, push to the submission
    pipeline.
  3. Confirmation discipline: only forward events after they
    reach `--confirmation-depth` blocks of confirmation.
    Track an "events-in-flight" buffer.
  4. Idempotency: track each forwarded event's L1
    transaction-hash + log-index in `canon-storage`; refuse
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
  3. Forward to `canon-host` over TCP/Unix-socket per RH-C's
    wire format.
  4. Wait for verdict; on `notAdmissible` or `parseError`,
    log + alert + halt (these are bugs, not normal flow).
  5. Backpressure: if `canon-host` queue is full (busy
    response code per RH-C), retry with exponential backoff.

**Acceptance criteria.**

  * Happy-path: deposit event → SignedAction → admitted on L2.
  * Backpressure: `canon-host` artificially saturated;
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
     - `canon-host` saturation injection.
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

### RH-C — `canon-host` (network adaptor, Phase 5 WU 5.4)

**Finding map.**  WU 5.4 deferred per GENESIS_PLAN line 3807.

**Scope.**  `runtime/canon-host/` — TCP/Unix-socket service
that accepts CBE-framed `SignedAction` requests and forwards
them to the Lean `canon` executable.

**RH-C decomposes into five sub-sub-units:**

  * **RH-C.1** — Crate skeleton + CBE frame parser.
  * **RH-C.2** — `canon` subprocess management.
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
    `--canon-binary <path>`, `--max-queue-depth <n>`,
    `--max-frame-size <bytes>`.
  3. Frame parser: 4-byte big-endian length prefix +
    `length`-byte payload.  Reject frames over `--max-frame-size`
    (default 1 MiB).
  4. Frame is treated as opaque bytes — `canon-host` does not
    interpret CBE.  The host's only frame-level invariant is
    "length matches".

**Acceptance criteria.**

  * Round-trip: encode a frame, decode, bytes match.
  * Reject over-length, under-length, truncated.

**Risk.**  Trivial.

**Effort.**  ~1 engineer-day.

#### RH-C.2 — `canon` subprocess management

**Scope.**  `src/subprocess.rs`.

**Implementation steps.**

  1. Spawn `canon` as a child process with a Unix socket for
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
semantic checks happen in the Lean `canon` subprocess.  This
means the host has zero attack surface against the Lean
admissibility predicate.

**Aggregate effort:** ~8 engineer-days (revised down from 10;
decomposition surfaced the framing parser is simpler than
the original lump estimate implied).

---

### RH-D — `canon-event-subscribe` (Phase 5 WU 5.7)

**Finding map.**  WU 5.7 deferred per GENESIS_PLAN line 3823.

**Scope.**  `runtime/canon-event-subscribe/` — subscription
service that streams ordered events to subscribers.

**RH-D decomposes into five sub-sub-units:**

  * **RH-D.1** — Crate skeleton + log-tail reader.
  * **RH-D.2** — Event-extraction subprocess (delegate to
    `canon` for wire-format authority).
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

#### RH-D.2 — Event extraction via `canon` subprocess

**Decision recorded:** delegate event extraction to the Lean
`canon` executable rather than reimplement
`Events.extractEvents` in Rust.  Rationale: Lean is the
wire-format authority; a Rust reimplementation would risk
drift.

**Implementation steps.**

  1. Spawn `canon extract-events --log <path>` subprocess
    (the Lean side ships this subcommand via `Main.lean`).
  2. Communicate via pipe protocol: `(seq, frame_bytes) →
    canon → CBE-encoded Event[]`.
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

---

### RH-E.0 — `canon-storage` (Rust DB layer)

**Finding map.**  Structural blocker for WU 5.8 per GENESIS_PLAN
line 3826.

**Scope.**  `runtime/canon-storage/` — a small abstraction crate
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

**Use case.**  `canon-faultproof-observer` (RH-G.6) takes a
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
  4. Benchmark fixtures consumed by RH-F (`canon-bench`).

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

### RH-E.1 — `canon-indexer` (Phase 5 WU 5.8)

**Finding map.**  WU 5.8 deferred per GENESIS_PLAN line 3826.

**Scope.**  `runtime/canon-indexer/` — daemon that consumes
events via `canon-event-subscribe` and maintains a per-resource
balance view in `canon-storage`.

**Implementation steps.**

  1. Crate skeleton.
  2. Subscribe to events; for each `Event.transfer` /
    `Event.mint` / `Event.burn` / `Event.deposit` / `Event.withdraw`,
    update the balance row keyed by `(actor, resource)`.
  3. Idempotency: track the last processed sequence number;
    on restart, resume from that sequence.
  4. Verification: `--verify-against-canon` flag that, for every
    actor, queries the live `canon-host` for the canonical
    balance and asserts equality.  Regression-test in CI.
  5. CLI: `canon-indexer query <actor> <resource>` for ad-hoc
    queries.

**Acceptance criteria.**

  * Balance view matches `canon-host`'s `getBalance` for
    arbitrary actors after a 10k-event load.
  * Idempotent restart: kill mid-stream, restart, no
    double-application.

**Risk.**  Low.

**Effort.**  ~6 engineer-days.

---

### RH-F — `canon-bench` (10k tx/sec benchmark, Phase 5 WU 5.11)

**Finding map.**  WU 5.11 deferred per GENESIS_PLAN line 3840.

**Scope.**  `runtime/canon-bench/benches/` — Criterion-style
benchmark suite measuring transfer-only throughput end-to-end.

**Implementation steps.**

  1. Pre-fund 1000 actor accounts with a synthetic genesis
    log.
  2. Generate 10000 valid transfer `SignedAction`s in advance.
  3. Submit them via `canon-host` over Unix socket (TCP adds
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

### RH-G — `canon-faultproof-observer` (Workstream H, WU H.10.5)

**Finding map.**  H.10.5 deferred per
`LegalKernel/FaultProof/Witness.lean:65`; runbook drafted at
`docs/fault_proof_runbook.md` §7.

**Scope.**  `runtime/canon-faultproof-observer/` — daemon that
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

**Scope.**  `runtime/canon-faultproof-observer/Cargo.toml`,
`src/main.rs`, `src/lib.rs`.

**Implementation steps.**

  1. Create crate with `[[bin]] name = "canon-faultproof-observer"`
    + library target so test code can import internals.
  2. Dependencies (pinned, minor-version):
     - `ethers = "2"` (Ethereum JSON-RPC client; pin per
       OQ-X-1 cadence rule).
     - `tokio = { version = "1", features = ["full"] }`.
     - `serde`, `serde_json`, `anyhow`, `thiserror`.
     - `tracing` + `tracing-subscriber` for structured logs.
     - Workspace deps: `canon-storage`, `canon-cli-common`.
  3. CLI flag set: `--l1-rpc <url>`, `--game-contract <addr>`,
    `--canon-binary <path>`, `--keystore <path>`, `--storage
    <path>`, `--start-block <n>`, `--log-level <level>`.
  4. `main.rs`: parse CLI, initialise logging, hand off to
    library entry-point `observer::run`.

**Acceptance criteria.**

  * Crate builds; clippy clean.
  * `canon-faultproof-observer --help` lists every flag.

**Risk.**  Trivial.

**Effort.**  ~1 engineer-day.

#### RH-G.2 — L1 event-watch with re-org handling

**Scope.**  `runtime/canon-faultproof-observer/src/l1_watcher.rs`.

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
    block-hash window) in `canon-storage` after each successful
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

**Scope.**  `runtime/canon-faultproof-observer/src/game.rs`.

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
    Lean reference (via subprocess to `canon` exe).

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

**Scope.**  `runtime/canon-faultproof-observer/src/strategy.rs`.

**Implementation steps.**

  1. For a given `GameState` requiring a response, compute the
    *honest reply*:
     - Determine the bisection pivot block.
     - Invoke `canon` subprocess with `--replay-up-to <pivot>`
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

**Scope.**  `runtime/canon-faultproof-observer/src/submitter.rs`.

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
  5. Persist tx-hash + status in `canon-storage`; on restart,
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

**Scope.**  `runtime/canon-faultproof-observer/src/persistence.rs`.

**Implementation steps.**

  1. Schema (in `canon-storage`):
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

**Scope.**  `runtime/canon-faultproof-observer/tests/`,
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

---

### RH-G — Rolled-up acceptance criteria

  * RH-G.1 – RH-G.7 all individually accepted.
  * Cross-stack corpus 100% pass.
  * Chaos suite 100% pass.
  * Production readiness sign-off from operator team.

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
| `canon-storage` schema migration loses data | Low | Catastrophic | Migrations are append-only; full backup taken before migration |
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
  * **Multi-tenant `canon-host`** (one host serving multiple
    deployment IDs).  Single-deployment per host is sufficient
    for MVP; multi-tenant is a v2 concern.
  * **Hardware security module (HSM) integration** for the
    bridge-actor key.  Software-keystore is MVP; HSM is v2.
  * **Alternative DB backends** (RocksDB, foundationDB).
    SQLite is MVP; the `Storage` trait makes alternative
    backends a future drop-in.
  * **`canon-host` cluster mode** (load-balancing across multiple
    `canon` subprocesses).  Single-process is MVP.
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

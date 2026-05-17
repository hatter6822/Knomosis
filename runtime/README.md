<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Canon Rust host-runtime workspace

This directory houses the Rust crates that materialise Canon's
deployment-supplied substrates (cryptographic adaptors, L1 event
watcher, off-chain fault-proof observer) and the host-level
services Phase 5 deferred (network adaptor, event subscription,
SQLite indexer, throughput benchmark).

The full design rationale lives in
[`docs/planning/rust_host_runtime_plan.md`](../docs/planning/rust_host_runtime_plan.md);
read it first.  This README is the day-to-day developer guide.

## Status

RH-H (Rust Host workspace + CI harness) landed first; RH-A
(cryptographic adaptors — RH-A.1 ECDSA + RH-A.2 keccak-256)
followed; RH-B (`canon-l1-ingest` L1 event watcher daemon) was
the previous landing; RH-C (`canon-host` network adaptor) is
the most recent.  Current state:

  * **`canon-cli-common`** — shared logging / exit-code / paths
    helpers.  Fully implemented (small surface, stable from day
    one).
  * **`canon-cross-stack`** — cross-stack fixture loader.  Fully
    implemented; other crates dev-dep on this for byte-equivalence
    assertions against the Lean reference.
  * **`canon-verify-secp256k1`** — RH-A.1 ECDSA secp256k1
    verifier.  Production cdylib exposing the `canon_verify_ecdsa`
    C ABI symbol.  Strict input validation, EIP-2 / BIP-62 low-s
    canonicalisation, k256 v0.13 backend.
  * **`canon-hash-keccak256`** — RH-A.2 Keccak-256 hash adaptor.
    Production cdylib exposing the `canon_hash_bytes` /
    `canon_hash_stream` / `canon_hash_identifier` C ABI symbols.
    sha3 v0.10 backend (Ethereum-flavoured keccak, NOT FIPS-202).
  * **`canon-l1-ingest`** — RH-B Ethereum L1 event watcher
    daemon.  Library + binary.  Watches `CanonBridge` /
    `CanonIdentityRegistry` event logs via Ethereum JSON-RPC,
    translates events to Canon `Action`s via the Rust mirror of
    `Bridge.Ingest.ingest`, signs with a zeroize-protected
    bridge-actor key, and forwards CBE-encoded `SignedAction`s
    to `canon-host` via length-prefixed HTTP.  Idempotent
    re-org-tolerant up to a configurable window depth.
    Cross-stack equivalence enforced by 12-record
    `l1_ingest.cxsf` corpus.
  * **`canon-host`** — RH-C network adaptor.  Library + binary.
    Listens on TCP / TLS-on-TCP (via `rustls` + `ring`) /
    Unix-socket and accepts length-prefixed CBE-encoded
    `SignedAction` frames; forwards each to a `Kernel`
    implementation (`MockKernel` for tests, `CommandKernel` that
    spawns the canon binary per request for MVP production use)
    and returns a verdict byte + optional UTF-8 reason.  Bounded
    mpsc queue with `Busy` overflow strategy.  See
    `docs/abi.md` §10 for the full wire-format spec.
  * **All other crates** — skeletons.  Each has a minimal
    `Cargo.toml` plus an `src/lib.rs` or `src/main.rs` documenting
    the symbol surface the implementing work unit will fill in.
    Skeleton binaries exit with code `3 = NotImplemented` so a
    deployment that wires them up today gets a loud,
    supervisor-visible refusal.

Work-unit status (per `docs/planning/rust_host_runtime_plan.md`):

| Work unit | Crate(s)                            | Status           |
|-----------|-------------------------------------|------------------|
| RH-H      | (workspace + CI)                    | **Complete**     |
| RH-A.1    | `canon-verify-secp256k1`            | **Complete**     |
| RH-A.2    | `canon-hash-keccak256`              | **Complete**     |
| RH-B      | `canon-l1-ingest`                   | **Complete**     |
| RH-C      | `canon-host`                        | **Complete**     |
| RH-D      | `canon-event-subscribe`             | **Complete**     |
| RH-E.0    | `canon-storage`                     | Skeleton; pending|
| RH-E.1    | `canon-indexer`                     | Skeleton; pending|
| RH-F      | `canon-bench`                       | Skeleton; pending|
| RH-G      | `canon-faultproof-observer`         | Skeleton; pending|

## Layout

```
runtime/
├── Cargo.toml                       — workspace manifest
├── rust-toolchain.toml              — pinned Rust channel (1.83)
├── README.md                        — this file
├── canon-hash-fallback.c            — pre-existing AR.10 fallback
│                                       (lake-built static library; not
│                                       part of the Cargo workspace)
│
├── canon-cli-common/                — shared library  (implemented)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── exit.rs                  — `OperatorExitCode` enum
│       ├── logging.rs               — `tracing-subscriber` wrapper
│       └── paths.rs                 — default socket / addr paths
│
├── canon-cross-stack/               — dev-dep library  (implemented)
│   ├── Cargo.toml
│   ├── src/lib.rs                   — fixture-file format + loader
│   └── tests/integration.rs         — downstream-consumer pattern
│
├── canon-verify-secp256k1/          — RH-A.1 ECDSA secp256k1 verifier
│   ├── Cargo.toml
│   ├── build.rs                     — finds lean.h, builds C shim
│   ├── c/lean_shim.c                — Lean runtime helpers (non-inline wrappers)
│   ├── src/
│   │   ├── lib.rs                   — crate root, ADAPTOR_IDENTIFIER
│   │   └── verify.rs                — verify() core + canon_verify_ecdsa entry
│   ├── examples/
│   │   └── gen_ecdsa_fixtures.rs    — corpus generator
│   └── tests/                       — known_vectors, cross_stack, property
│
├── canon-hash-keccak256/            — RH-A.2 Keccak-256 hash adaptor
│   ├── Cargo.toml
│   ├── build.rs                     — finds lean.h, builds C shim
│   ├── c/lean_shim.c                — Lean runtime helpers (non-inline wrappers)
│   ├── src/
│   │   ├── lib.rs                   — crate root, IDENTIFIER
│   │   └── hash.rs                  — keccak256() core + canon_hash_* entries
│   ├── examples/
│   │   └── gen_keccak256_fixtures.rs — corpus generator
│   └── tests/                       — known_vectors, cross_stack, property,
│                                       integration
├── canon-host/                      — RH-C network adaptor
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs                   — crate root, public API
│   │   ├── main.rs                  — binary entry point + CLI parser
│   │   ├── config.rs                — CLI flag parsing + validation
│   │   ├── frame.rs                 — wire-frame parser (4-byte BE len)
│   │   ├── kernel.rs                — Kernel trait + MockKernel + CommandKernel
│   │   ├── listener.rs              — TCP / TLS / Unix listener impls
│   │   ├── queue.rs                 — bounded mpsc queue + Busy overflow
│   │   ├── server.rs                — orchestrator wiring
│   │   ├── tls.rs                   — rustls server config loader
│   │   └── verdict.rs               — Verdict enum + VerdictResponse
│   └── tests/
│       ├── integration.rs           — end-to-end TCP request/response
│       ├── integration_unix.rs      — end-to-end Unix-socket tests
│       └── property.rs              — proptest invariants
│
├── canon-l1-ingest/                 — RH-B L1 event watcher daemon
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs                   — crate root
│   │   ├── main.rs                  — daemon entry point + CLI parser
│   │   ├── action.rs                — Rust mirror of Lean Action
│   │   ├── address_book.rs          — EthAddress → ActorId map
│   │   ├── encoding.rs              — CBE encoder for Action / SignedAction
│   │   ├── events.rs                — L1 log decoder
│   │   ├── fixture.rs               — cross-stack fixture format
│   │   ├── key.rs                   — bridge-actor keystore (zeroize)
│   │   ├── reorg.rs                 — sliding-window re-org tracker
│   │   ├── source.rs                — L1Source trait + JSON-RPC impl
│   │   ├── state.rs                 — JSONL persistent watcher state
│   │   ├── submitter.rs             — Submitter trait + HTTP impl
│   │   ├── translation.rs           — ingest(event) → Action
│   │   └── watcher.rs               — orchestrator loop
│   ├── examples/
│   │   └── gen_ingest_fixtures.rs   — cross-stack corpus generator
│   └── tests/
│       ├── cross_stack.rs           — `l1_ingest.cxsf` round-trip
│       ├── integration.rs           — end-to-end watcher flows
│       └── property.rs              — proptest invariants
├── canon-event-subscribe/           — RH-D event subscription server
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs                   — umbrella + identifier constants
│   │   ├── config.rs                — CLI flag parsing
│   │   ├── event_cache.rs           — bounded FIFO for backfill
│   │   ├── extract.rs               — Extractor trait (Mock + Subprocess)
│   │   ├── frame.rs                 — wire-frame parser/encoder
│   │   ├── server.rs                — top-level orchestrator
│   │   ├── subscription.rs          — subscriber state + bounded lag
│   │   ├── tail.rs                  — log-tail reader (FNV-1a-64 verified)
│   │   └── main.rs                  — daemon entry point
│   └── tests/
│       ├── integration.rs           — end-to-end pipeline scenarios
│       └── properties.rs            — proptest invariants
├── canon-storage/                   — RH-E.0 skeleton
├── canon-indexer/                   — RH-E.1 skeleton (binary)
├── canon-faultproof-observer/       — RH-G skeleton (binary + lib)
├── canon-bench/                     — RH-F skeleton
│
└── tests/cross-stack/               — fixture corpus
    ├── README.md                    — format + consumption guide
    └── *.cxsf                       — fixture files (added by RH-A.* …)
```

## Build and test

```bash
# From the project root or the runtime/ directory:
cd runtime/

# Build every member crate.  Reads rust-toolchain.toml; first run
# downloads the pinned 1.83 stable channel via rustup.
cargo build --workspace --all-targets

# Run every member crate's tests (483 tests at the RH-C landing —
# +175 from RH-B: 110 unit tests in the new `canon-host` library
# (verdict + frame + kernel + queue + listener + server + tls +
# config), 12 TCP integration tests, 7 Unix-socket integration
# tests, 11 property tests; up from 343 at the RH-B landing).
cargo test --workspace

# Lint gate: every clippy warning is promoted to a hard error.
cargo clippy --workspace --all-targets -- -D warnings

# Format gate: rustfmt against the workspace; --check is the CI
# variant (no in-place edits).
cargo fmt --all -- --check
```

CI (`.github/workflows/ci-rust.yml`) runs all four gates on every
PR that touches `runtime/`.  Lean-only PRs do not trigger the
Rust workflow at all.

### Regenerating cross-stack fixtures

The two crypto-adaptor crates ship deterministic fixture
generators under their `examples/` directories.  Re-run when
changing the input set or the underlying primitive:

```bash
# Regenerate the ECDSA corpus (30 valid + 30 high-s + 150
# tampered = 210 records).
cargo run --example gen_ecdsa_fixtures -p canon-verify-secp256k1

# Regenerate the keccak-256 corpus (51 records across six
# structural classes).
cargo run --example gen_keccak256_fixtures -p canon-hash-keccak256

# Regenerate the L1-ingest corpus (12 records covering every
# translatable event variant + edge cases).
cargo run --example gen_ingest_fixtures -p canon-l1-ingest -- \
    tests/cross-stack/l1_ingest.cxsf
```

Output goes to `runtime/tests/cross-stack/ecdsa_secp256k1.cxsf`,
`runtime/tests/cross-stack/keccak256.cxsf`, and
`runtime/tests/cross-stack/l1_ingest.cxsf`.  The generators use
fixed seeds (RFC-6979 deterministic ECDSA nonces; xorshift64
for the keccak random class; deterministic byte-pattern
addresses for the L1 ingestor) so the output is byte-stable
across re-generations.  Commit the resulting `.cxsf` files
alongside the change that motivated the regeneration.

### Lean `lean.h` discovery (production cdylib build)

The two crypto-adaptor crates' `build.rs` compiles a small C
shim that bridges Lean's `static inline` runtime API to non-
inline symbols Rust binds to via `extern "C"`.  The shim needs
`lean.h` at build time.  Discovery order:

  1. `LEAN_INCLUDE_DIR` environment variable (explicit override).
  2. `LEAN_SYSROOT` with `include/` appended.
  3. `lean --print-prefix` shell-out, with `include/` appended.
  4. Soft skip with a `cargo:warning=` — the rlib and staticlib
     still build, but the cdylib won't export `canon_verify_ecdsa`
     etc. (the production deployment surface).

For production builds, the `lean-ffi` Cargo feature promotes a
missing `lean.h` from soft-skip to hard-fail:

```bash
cargo build --release --features lean-ffi \
    -p canon-verify-secp256k1 -p canon-hash-keccak256
```

CI runs with Lean installed (via `scripts/setup.sh`), so the
shim builds in the default workflow.

## Cross-stack equivalence

Several Canon primitives are implemented in both Lean and Rust:

  * **Hash function** — Lean's `LegalKernel/Runtime/Hash.lean`
    swap-points (`canon_hash_bytes` / `canon_hash_stream` /
    `canon_hash_identifier`) plus the deployment-supplied Rust
    crate (`canon-hash-keccak256`, RH-A.2).
  * **ECDSA verification** — Lean's `Authority.Crypto.Verify`
    opaque plus the Rust adaptor (`canon-verify-secp256k1`,
    RH-A.1).
  * **CBE encoding of `Action` / `Verdict`** — Lean's
    `LegalKernel/Encoding/*.lean` plus the Rust host's CBE consumer
    (`canon-host`, RH-C; `canon-l1-ingest`, RH-B).
  * **Bisection-game state machine** — Lean's
    `LegalKernel/FaultProof/Game.lean` plus the off-chain observer
    mirror (`canon-faultproof-observer`, RH-G).

Byte-equality across these stacks is the load-bearing contract.
The `runtime/tests/cross-stack/` directory holds the canonical
reference vectors as `.cxsf` (Canon Cross-Stack Fixture) files;
consumer crates dev-dep on `canon-cross-stack` and load these via
[`canon_cross_stack::FixtureFile::load`](canon-cross-stack/src/lib.rs)
to assert their implementations match.

See [`tests/cross-stack/README.md`](tests/cross-stack/README.md)
for the file format and the downstream-consumer pattern.

## Pinned toolchain

The Rust channel is pinned in `rust-toolchain.toml` to **1.83
stable**, matching the workspace's `rust-version` MSRV.  Bumping
the channel is a workspace-level PR per the engineering plan §7
risk register; sub-streams cannot silently drift the toolchain.

A future bump must update both files in the same PR.

## Adding a new crate

If a future work unit introduces a new crate (uncommon — the 10
plan-defined crates plus `canon-cross-stack` exhaust the documented
architecture):

  1. Create the directory under `runtime/<crate-name>/`.
  2. Add `<crate-name>` to the `[workspace] members` list in
     `runtime/Cargo.toml`.
  3. Inherit the shared metadata via `version.workspace = true`
     etc.
  4. Add `[lints.clippy]` / `[lints.rust]` blocks matching the
     existing crates' discipline.
  5. Run the four CI gates locally before pushing.

## Audit posture

  * `unsafe_code = "forbid"` is the default for every skeleton
    crate.  Implementing work units that need `unsafe` (RH-A.1's
    C-ABI shim, RH-A.2's pointer-deref boundary) relax this to
    `unsafe_code = "deny"` and restrict `unsafe` blocks to the
    minimum surface.
  * `missing_docs` is a warn-level lint in every library crate.
    CI promotes it to error via `-D warnings`.
  * `clippy::pedantic` is enabled workspace-wide; specific
    pedantic-tier lints (`missing_errors_doc`,
    `missing_panics_doc`, `module_name_repetitions`) are
    explicitly allowed in `Cargo.toml`'s `[lints.clippy]` because
    we already require `missing_docs` at the rustc level and the
    pedantic variants are redundant under that discipline.

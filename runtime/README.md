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

The workspace landed under **RH-H** (Rust Host workspace + CI
harness).  At the RH-H landing:

  * **`canon-cli-common`** — shared logging / exit-code / paths
    helpers.  Fully implemented (small surface, stable from day
    one).
  * **`canon-cross-stack`** — cross-stack fixture loader.  Fully
    implemented (the load-bearing RH-H deliverable; other crates
    dev-dep on this for byte-equivalence assertions against the
    Lean reference).
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
| RH-A.1    | `canon-verify-secp256k1`            | Skeleton; pending|
| RH-A.2    | `canon-hash-keccak256`              | Skeleton; pending|
| RH-B      | `canon-l1-ingest`                   | Skeleton; pending|
| RH-C      | `canon-host`                        | Skeleton; pending|
| RH-D      | `canon-event-subscribe`             | Skeleton; pending|
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
├── canon-verify-secp256k1/          — RH-A.1 skeleton
├── canon-hash-keccak256/            — RH-A.2 skeleton
├── canon-host/                      — RH-C skeleton (binary)
├── canon-l1-ingest/                 — RH-B skeleton (binary)
├── canon-event-subscribe/           — RH-D skeleton (binary)
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

# Run every member crate's tests (44 tests at the RH-H landing).
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

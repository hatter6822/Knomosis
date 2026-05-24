<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Knomosis Rust host-runtime workspace

This directory houses the **11 workspace crates** that materialise
Knomosis's deployment-supplied substrates (cryptographic adaptors, L1
event watcher, off-chain fault-proof observer) and the host-level
services Phase 5 deferred (network adaptor, event subscription,
SQLite storage + indexer, throughput benchmark).

The full design rationale lives in
[`docs/planning/rust_host_runtime_plan.md`](../docs/planning/rust_host_runtime_plan.md);
read it first.  This README is the day-to-day developer guide.

## Status

Every Rust workstream RH-H, RH-A.1, RH-A.2, RH-B, RH-C, RH-D, RH-E.0,
RH-E.1, RH-F, and RH-G is **Complete**.  Two integration follow-ups
remain: the Lean `knomosis extract-events` subcommand (needed by RH-D's
`SubprocessExtractor`) and `knomosis-indexer`'s `--verify-against-knomosis`
wiring (needs a knomosis-host `getBalance` endpoint).  Current state:

  * **`knomosis-cli-common`** — shared logging / exit-code / paths
    helpers.  Fully implemented (small surface, stable from day
    one).
  * **`knomosis-cross-stack`** — cross-stack fixture loader.  Fully
    implemented; other crates dev-dep on this for byte-equivalence
    assertions against the Lean reference.
  * **`knomosis-verify-secp256k1`** — RH-A.1 ECDSA secp256k1
    verifier.  Production cdylib exposing the `knomosis_verify_ecdsa`
    C ABI symbol.  Strict input validation, EIP-2 / BIP-62 low-s
    canonicalisation, k256 v0.13 backend.
  * **`knomosis-hash-keccak256`** — RH-A.2 Keccak-256 hash adaptor.
    Production cdylib exposing the `knomosis_hash_bytes` /
    `knomosis_hash_stream` / `knomosis_hash_identifier` C ABI symbols.
    sha3 v0.10 backend (Ethereum-flavoured keccak, NOT FIPS-202).
  * **`knomosis-l1-ingest`** — RH-B Ethereum L1 event watcher
    daemon.  Library + binary.  Watches `KnomosisBridge` /
    `KnomosisIdentityRegistry` event logs via Ethereum JSON-RPC,
    translates events to Knomosis `Action`s via the Rust mirror of
    `Bridge.Ingest.ingest`, signs with a zeroize-protected
    bridge-actor key, and forwards CBE-encoded `SignedAction`s
    to `knomosis-host` via length-prefixed HTTP.  Idempotent
    re-org-tolerant up to a configurable window depth.
    Cross-stack equivalence enforced by 12-record
    `l1_ingest.cxsf` corpus.
  * **`knomosis-host`** — RH-C network adaptor.  Library + binary.
    Listens on TCP / TLS-on-TCP (via `rustls` + `ring`) /
    Unix-socket and accepts length-prefixed CBE-encoded
    `SignedAction` frames; forwards each to a `Kernel`
    implementation (`MockKernel` for tests, `CommandKernel` that
    spawns the knomosis binary per request for MVP production use)
    and returns a verdict byte + optional UTF-8 reason.  Bounded
    mpsc queue with `Busy` overflow strategy.  See
    `docs/abi.md` §10 for the full wire-format spec.
  * **`knomosis-event-subscribe`** — RH-D event-subscription
    server.  Library + binary.  Tails Knomosis's transition log,
    extracts deployment-facing events via the Lean `knomosis`
    subprocess (or a mock for tests), and streams them to
    subscribers in strict order with bounded-lag eviction.
    See `docs/abi.md` §11 for the wire format.
  * **`knomosis-storage`** — RH-E.0 storage abstraction.
    Library.  Exposes the `Storage` / `StorageSnapshot` /
    `StorageTransaction` traits plus a SQLite-backed
    `SqliteStorage` implementation (WAL mode, deferred-read
    snapshots, append-only migrations).  Used by
    `knomosis-indexer`; future home for `knomosis-faultproof-observer`
    persistence.
  * **`knomosis-indexer`** — RH-E.1 SQLite event indexer.
    Library + binary.  Daemon mode subscribes to
    `knomosis-event-subscribe` and maintains a per-(actor,
    resource) balance view in a `knomosis-storage` database;
    `knomosis-indexer query <actor> <resource>` provides ad-hoc
    lookups.  Idempotent restart via a stored cursor; each
    event-batch commits atomically with the cursor advance.
  * **`knomosis-bench`** — RH-F transfer-throughput benchmark.
    Library + binary.  Generates a deterministic fixture of
    pre-funded actors + pre-signed transfer `SignedAction`s,
    spawns an in-process knomosis-host (`--standalone`) or
    connects to an existing one (`--connect`), and drives a
    concurrent workload through it via Unix-socket / TCP.
    Reports p50 / p90 / p99 / p999 latency + sustained
    throughput.  Optional `--report` JSON sidecar + `--baseline`
    regression check + absolute `--target-tps` /
    `--target-p99-ms` gates for CI.
  * **`knomosis-faultproof-observer`** — RH-G.  Off-chain
    bisection-game observer daemon.  Watches L1 for
    `FaultProofGameOpened` / `BisectionMidpointSubmitted` /
    `BisectionResponseSubmitted` / `FaultProofGameSettled` /
    `StateRootSubmitted` events; maintains an in-memory game-
    state map mirroring the Lean reference
    (`LegalKernel.FaultProof.Game`) byte-for-byte; computes the
    honest move via a deployment-supplied truth oracle; submits
    responses via a pluggable submitter: the in-memory
    `MockSubmitter` for tests + dry-run, plus the production
    `JsonRpcSubmitter` (`src/jsonrpc_submitter.rs`) that
    builds + signs EIP-1559 typed-2 transactions via the
    audited `BridgeActorKey::sign_prehash` wrapper and
    broadcasts via `eth_sendRawTransaction`.  Persistence
    via `knomosis-storage` with atomic-batch commits.  Reuses
    `knomosis-l1-ingest`'s re-org window + JSON-RPC source +
    `BridgeActorKey` signing-key wrapper.  Cold-start games
    adopted from `FaultProofGameOpened` events start with
    `state_known = false`; `src/state_reader.rs`'s
    `ContractGameReader::read_and_validate` runs an
    `eth_call` to `games(uint256)` (an 18-slot ABI response)
    to learn the full state, and `Observer::hydrate_cold_start_games`
    flips `state_known` to `true` via the audited
    `mark_state_known` API (deployment-id cross-check +
    range non-degeneracy guards).  In-memory pivot dedup
    cache for O(1) duplicate-submission detection.
    `TerminateOnSingleStep` calldata builder refuses to emit
    the minimum-form selector that wouldn't match the deployed
    contract's full signature.  Hard upper bounds on every
    operator-tunable parameter (reorg_window_capacity,
    confirmation_depth, blocks_per_iteration) at 4096 to defend
    against memory-bomb scenarios.  Cross-stack ratification:
    50-trace observer game-trace corpus
    (`tests/observer_game_traces.rs`) replays Lean's
    `applyTransition` byte-for-byte; chaos suite
    (`tests/chaos.rs`) covers re-org / kill-restart /
    dropped-conn / adversarial-opponent scenarios.  The Lean
    `knomosis export-cell-proofs LOG IDX SIGNER` subcommand
    emits the cell-proof bundle JSON the Rust submitter
    consumes for `terminateOnSingleStep` calldata.  The Lean
    `knomosis replay-up-to LOG IDX` subcommand provides the
    in-production truth function the `SubprocessTruthOracle`
    shells out to.

Work-unit status (per `docs/planning/rust_host_runtime_plan.md`):

| Work unit | Crate(s)                            | Status           |
|-----------|-------------------------------------|------------------|
| RH-H      | (workspace + CI)                    | **Complete**     |
| RH-A.1    | `knomosis-verify-secp256k1`            | **Complete**     |
| RH-A.2    | `knomosis-hash-keccak256`              | **Complete**     |
| RH-B      | `knomosis-l1-ingest`                   | **Complete**     |
| RH-C      | `knomosis-host`                        | **Complete**     |
| RH-D      | `knomosis-event-subscribe`             | **Complete**     |
| RH-E.0    | `knomosis-storage`                     | **Complete**     |
| RH-E.1    | `knomosis-indexer`                     | **Complete**     |
| RH-F      | `knomosis-bench`                       | **Complete**     |
| RH-G      | `knomosis-faultproof-observer`         | **Complete**     |

## Layout

```
runtime/
├── Cargo.toml                       — workspace manifest
├── rust-toolchain.toml              — pinned Rust channel (1.83)
├── README.md                        — this file
├── knomosis-hash-fallback.c            — pre-existing AR.10 fallback
│                                       (lake-built static library; not
│                                       part of the Cargo workspace)
│
├── knomosis-cli-common/                — shared library  (implemented)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── exit.rs                  — `OperatorExitCode` enum
│       ├── logging.rs               — `tracing-subscriber` wrapper
│       └── paths.rs                 — default socket / addr paths
│
├── knomosis-cross-stack/               — dev-dep library  (implemented)
│   ├── Cargo.toml
│   ├── src/lib.rs                   — fixture-file format + loader
│   └── tests/integration.rs         — downstream-consumer pattern
│
├── knomosis-verify-secp256k1/          — RH-A.1 ECDSA secp256k1 verifier
│   ├── Cargo.toml
│   ├── build.rs                     — finds lean.h, builds C shim
│   ├── c/lean_shim.c                — Lean runtime helpers (non-inline wrappers)
│   ├── src/
│   │   ├── lib.rs                   — crate root, ADAPTOR_IDENTIFIER
│   │   └── verify.rs                — verify() core + knomosis_verify_ecdsa entry
│   ├── examples/
│   │   └── gen_ecdsa_fixtures.rs    — corpus generator
│   └── tests/                       — known_vectors, cross_stack, property
│
├── knomosis-hash-keccak256/            — RH-A.2 Keccak-256 hash adaptor
│   ├── Cargo.toml
│   ├── build.rs                     — finds lean.h, builds C shim
│   ├── c/lean_shim.c                — Lean runtime helpers (non-inline wrappers)
│   ├── src/
│   │   ├── lib.rs                   — crate root, IDENTIFIER
│   │   └── hash.rs                  — keccak256() core + knomosis_hash_* entries
│   ├── examples/
│   │   └── gen_keccak256_fixtures.rs — corpus generator
│   └── tests/                       — known_vectors, cross_stack, property,
│                                       integration
├── knomosis-host/                      — RH-C network adaptor
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
├── knomosis-l1-ingest/                 — RH-B L1 event watcher daemon
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
├── knomosis-event-subscribe/           — RH-D event subscription server
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
├── knomosis-storage/                   — RH-E.0 storage abstraction
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs                   — umbrella + identifier constants
│   │   ├── storage.rs               — Storage / Snapshot / Transaction traits
│   │   ├── sqlite.rs                — SqliteStorage impl + pragma options
│   │   └── migration.rs             — append-only MIGRATIONS table
│   └── tests/
│       ├── integration.rs           — end-to-end persistence / concurrency
│       └── property.rs              — random KV ops vs BTreeMap oracle
├── knomosis-indexer/                   — RH-E.1 SQLite event indexer
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs                   — umbrella + identifier constants
│   │   ├── main.rs                  — daemon entry point + CLI dispatch
│   │   ├── config.rs                — daemon/query CLI parsing
│   │   ├── event.rs                 — typed Event enum (16 frozen tags)
│   │   ├── decoder.rs               — CBE Event decoder + matching encoder
│   │   ├── balance.rs               — per-(actor, resource) balance view
│   │   ├── cursor.rs                — atomic seq tracker + identifier check
│   │   ├── indexer.rs               — orchestration (atomic batch commit,
│   │   │                              two-pass dispatch)
│   │   ├── daemon.rs                — consume_stream / consume_batched loop
│   │   │                              (partial-batch discard semantics)
│   │   └── client.rs                — TCP client for knomosis-event-subscribe
│   └── tests/
│       ├── integration.rs           — end-to-end pipeline scenarios
│       ├── property.rs              — decoder roundtrips + balance oracle
│       │                              + decoder fuzz
│       ├── wire_protocol.rs         — mock-server frame round-trips
│       │                              + DoS-bound regressions
│       ├── daemon_loop.rs           — partial-batch / two-pass regression
│       │                              tests against a mock server
│       └── fault_injection.rs       — cursor-recovery / commit-failure /
│                                      poisoning recovery via FaultyStorage
├── knomosis-faultproof-observer/       — RH-G observer daemon (binary + lib)
├── knomosis-bench/                     — RH-F (library + binary)
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs                   — crate root + constants
│   │   ├── main.rs                  — binary entry point
│   │   ├── config.rs                — CLI flag parser
│   │   ├── fixture.rs               — deterministic actor + transfer fixture
│   │   ├── histogram.rs             — latency histogram + percentile reporter
│   │   ├── report.rs                — JSON report + baseline regression check
│   │   ├── runner.rs                — concurrent benchmark driver
│   │   └── server.rs                — in-process knomosis-host helper
│   └── tests/
│       └── smoke.rs                 — end-to-end smoke (Unix + TCP)
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

# Run every member crate's tests (~1 400 tests across the 11 crates
# at the RH-G audit-pass-4-round-6 landing).  `cargo test --workspace`
# is the canonical query; per-crate breakdowns are recorded in
# CLAUDE.md's "Current development status" section.
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

### Running the benchmark

`knomosis-bench` (RH-F) materialises the transfer-throughput benchmark
suite per `docs/planning/rust_host_runtime_plan.md` §RH-F.  In
`--standalone` mode (default), the binary spawns its own
knomosis-host backed by `MockKernel` on an auto-allocated tempdir
Unix socket; the benchmark itself runs the documented workload
(`actor_count = 1000, transfer_count = 10000`, default workers =
64):

```bash
# Default workload (1000 actors / 10000 transfers / 64 workers).
cargo run --release -p knomosis-bench

# Smaller scale (for CI smoke or interactive iteration).
cargo run --release -p knomosis-bench -- \
    --actor-count 100 --transfer-count 500 --warmup-requests 50 \
    --worker-count 32

# Persist a JSON report for baseline regression detection.
cargo run --release -p knomosis-bench -- \
    --report /tmp/knomosis-bench-baseline.json

# Compare against an existing baseline (exits non-zero on
# > 10% drift).
cargo run --release -p knomosis-bench -- \
    --baseline /tmp/knomosis-bench-baseline.json

# Absolute target check (exits non-zero if the target is missed).
cargo run --release -p knomosis-bench -- \
    --target-tps 5000 --target-p99-ms 50

# Bench an existing knomosis-host instance (no in-process server).
cargo run --release -p knomosis-bench -- \
    --connect tcp:127.0.0.1:7654
```

The binary uses knomosis-host's MockKernel by default (returns Ok
in `O(µs)` per submission); this isolates the host's framing /
queue / worker overhead from any kernel-level cost.  Bench against
the real Lean kernel by pointing `--connect` at a separately-spawned
knomosis-host running with the production `CommandKernel`.

### Regenerating cross-stack fixtures

The two crypto-adaptor crates ship deterministic fixture
generators under their `examples/` directories.  Re-run when
changing the input set or the underlying primitive:

```bash
# Regenerate the ECDSA corpus (30 valid + 30 high-s + 150
# tampered = 210 records).
cargo run --example gen_ecdsa_fixtures -p knomosis-verify-secp256k1

# Regenerate the keccak-256 corpus (51 records across six
# structural classes).
cargo run --example gen_keccak256_fixtures -p knomosis-hash-keccak256

# Regenerate the L1-ingest corpus (12 records covering every
# translatable event variant + edge cases).
cargo run --example gen_ingest_fixtures -p knomosis-l1-ingest -- \
    tests/cross-stack/l1_ingest.cxsf
```

> Note: workspace member directories retain historical `knomosis-*` folder names,
> but Cargo package IDs are rebranded `knomosis-*`; use `-p knomosis-...`
> selectors in commands.

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
     still build, but the cdylib won't export `knomosis_verify_ecdsa`
     etc. (the production deployment surface).

For production builds, the `lean-ffi` Cargo feature promotes a
missing `lean.h` from soft-skip to hard-fail:

```bash
cargo build --release --features lean-ffi \
    -p knomosis-verify-secp256k1 -p knomosis-hash-keccak256
```

CI runs with Lean installed (via `scripts/setup.sh`), so the
shim builds in the default workflow.

## Cross-stack equivalence

Several Knomosis primitives are implemented in both Lean and Rust:

  * **Hash function** — Lean's `LegalKernel/Runtime/Hash.lean`
    swap-points (`knomosis_hash_bytes` / `knomosis_hash_stream` /
    `knomosis_hash_identifier`) plus the deployment-supplied Rust
    crate (`knomosis-hash-keccak256`, RH-A.2).
  * **ECDSA verification** — Lean's `Authority.Crypto.Verify`
    opaque plus the Rust adaptor (`knomosis-verify-secp256k1`,
    RH-A.1).
  * **CBE encoding of `Action` / `Verdict`** — Lean's
    `LegalKernel/Encoding/*.lean` plus the Rust host's CBE consumer
    (`knomosis-host`, RH-C; `knomosis-l1-ingest`, RH-B).
  * **Bisection-game state machine** — Lean's
    `LegalKernel/FaultProof/Game.lean` plus the off-chain observer
    mirror (`knomosis-faultproof-observer`, RH-G).

Byte-equality across these stacks is the load-bearing contract.
The `runtime/tests/cross-stack/` directory holds the canonical
reference vectors as `.cxsf` (Knomosis Cross-Stack Fixture) files;
consumer crates dev-dep on `knomosis-cross-stack` and load these via
[`knomosis_cross_stack::FixtureFile::load`](knomosis-cross-stack/src/lib.rs)
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
plan-defined crates plus `knomosis-cross-stack` exhaust the documented
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

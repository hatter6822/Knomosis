// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `knomosis-gateway-bench` — Workstream GW (G4.6).
//!
//! A read-path throughput / latency benchmark for `knomosis-gateway`, the
//! peer of `knomosis-bench` for the host.  It:
//!
//!   1. **Seeds a read-only indexer fixture** ([`fixture`]) — a SQLite
//!      database with `actors × resources` actor balances + a cursor, exactly
//!      the shape the gateway's `GET /v1/actors/{id}/balances` read consumes.
//!   2. **Drives a real gateway listener** ([`runner`]) — builds an
//!      [`knomosis_gateway::state::AppState`] over the fixture (read-only) +
//!      a bearer token, spawns the gateway's own `spawn_plain_listener` HTTP
//!      stack (thread-per-connection), and hits it with `--workers` concurrent
//!      **raw-HTTP** `GET` clients pulling from a shared request counter.
//!   3. **Reports** ([`report`]) — sustained end-to-end throughput
//!      (requests/sec, wallclock) + a latency percentile summary (reusing the
//!      host bench's [`knomosis_bench::histogram`]), as a human table + a JSON
//!      sidecar (`--report`), with optional baseline regression detection
//!      (`--baseline`).
//!
//! ## What it measures
//!
//! The **full gateway read path**: HTTP parse → fail-closed auth gate → route
//! → dispatch → the read-only `SqliteStorage` `BalanceView` read → JSON
//! response, over a real TCP socket.  This is dominated by the gateway's
//! single-SQLite-read-connection serialisation (OQ-GW-9 / OQ-GW-13): the read
//! backend takes the storage layer's connection mutex, so concurrent reads
//! serialise there.  The bench therefore characterises (and regression-guards)
//! that real bound, end to end.
//!
//! ## What it does **not** measure
//!
//!   * **Write / submit throughput** — the submit path forwards to the host
//!     (benchmarked by `knomosis-bench`); this harness is read-only.
//!   * **TLS overhead** — it drives the plaintext `--listen` socket; the
//!     native-TLS handshake cost is a separate concern.
//!   * **A high-concurrency SSE fan-out** — the gateway now serves each
//!     connection on its own thread (no `tiny_http` ceiling; OQ-GW-14 closed),
//!     but SSE-stream throughput is a separate concern, out of scope here.
//!
//! ## Not a CI throughput gate
//!
//! The throughput **numbers** vary by machine, so the binary is a *manual*
//! measurement tool (run it, eyeball the table, optionally `--baseline` two
//! runs on the *same* host).  Its deterministic unit + integration tests
//! (fixture determinism, the runner's correctness on a small workload, report
//! JSON round-trip + regression detection, config parsing) DO run under
//! `cargo test --workspace`.

pub mod config;
pub mod fixture;
pub mod report;
pub mod runner;

/// Crate name, mirrored from `Cargo.toml`.
pub const CRATE_NAME: &str = "knomosis-gateway-bench";

/// Diagnostic identifier the binary + the JSON report publish.
pub const BENCH_IDENTIFIER: &str = "knomosis-gateway-bench/v1";

/// The report-JSON schema / baseline-comparison protocol version.  Bumped if
/// the report shape or comparison semantics change incompatibly.
pub const PROTOCOL_VERSION: u32 = 1;

/// Default number of seeded actors (each with `--resources` balances).
pub const DEFAULT_ACTOR_COUNT: usize = 1_000;

/// Default number of resources seeded per actor.
pub const DEFAULT_RESOURCE_COUNT: usize = 2;

/// Default number of measured requests.
pub const DEFAULT_REQUEST_COUNT: usize = 10_000;

/// Default number of concurrent client worker threads.
pub const DEFAULT_WORKER_COUNT: usize = 32;

/// Default number of gateway handler-pool threads (the server side).
pub const DEFAULT_HANDLER_THREADS: usize = 16;

/// Default warmup-request count (excluded from the measurement window).
pub const DEFAULT_WARMUP_REQUESTS: usize = 1_000;

/// Default baseline regression threshold (±10%, mirroring `knomosis-bench`).
pub const DEFAULT_REGRESSION_THRESHOLD: f64 = 0.10;

/// The bearer token the harness configures + presents (a throwaway test
/// credential — the bench's gateway is loopback-only and ephemeral).
pub const BENCH_TOKEN: &str = "gateway-bench-token";

#[cfg(test)]
mod tests {
    use super::{BENCH_IDENTIFIER, CRATE_NAME, DEFAULT_REGRESSION_THRESHOLD, PROTOCOL_VERSION};

    #[test]
    fn identity_constants() {
        assert_eq!(CRATE_NAME, "knomosis-gateway-bench");
        assert_eq!(BENCH_IDENTIFIER, "knomosis-gateway-bench/v1");
        assert_eq!(PROTOCOL_VERSION, 1);
        assert!((DEFAULT_REGRESSION_THRESHOLD - 0.10).abs() < f64::EPSILON);
    }
}

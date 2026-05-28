// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `knomosis-bench` — RH-F transfer-throughput benchmark suite.
//!
//! Materialises the closing Phase-5 work unit per
//! `docs/planning/rust_host_runtime_plan.md` §RH-F: a Criterion-style
//! benchmark suite measuring `knomosis-host`'s end-to-end transfer
//! throughput.
//!
//! ## What this crate provides
//!
//!   * [`fixture`] — deterministic synthetic fixture generator.
//!     Pre-funds a configurable number of actor accounts (default
//!     1000) with secp256k1 keypairs and pre-generates a configurable
//!     number of valid transfer [`knomosis_l1_ingest::action::Action`]s
//!     (default 10000) signed with each sender's actor key.  Every
//!     `(Action, signer, nonce, deploymentId)` quadruple is signed
//!     via Lean's documented [`signing_input`] flow + keccak256 +
//!     low-s ECDSA, so the resulting bytes are wire-compatible with
//!     a real `knomosis` kernel.
//!   * [`histogram`] — bounded-resolution latency histogram for
//!     percentile reporting.  Records every per-request latency in
//!     a `Vec<u64>` (nanoseconds) and computes `p50` / `p90` /
//!     `p99` / `p999` / `min` / `max` / `mean` / `stddev` after
//!     post-run sort.  Linear-time insertion; O(N log N) report.
//!     Memory-bounded by the request count.
//!   * [`runner`] — concurrent benchmark driver.  Spawns a
//!     configurable number of submitter threads (default 64) that
//!     pull from a shared deque of pre-generated payloads and push
//!     each over a Unix-socket connection to a running `knomosis-host`.
//!     Each request opens, writes the framed payload, reads the
//!     verdict response, and closes the connection (the knomosis-host
//!     wire format is one-shot per connection per the §10.5 ABI).
//!     Per-request latency is reported back via a histogram-keyed
//!     mpsc channel.
//!   * [`report`] — JSON + human report formatter, plus an optional
//!     baseline regression check.  The JSON sidecar is the
//!     load-bearing CI artefact; a follow-up run with
//!     `--baseline <FILE>` compares the new throughput / p50 / p99
//!     against the stored baseline and surfaces a non-zero exit
//!     code if either drifts by more than the configured threshold
//!     (default ±10% per the plan §RH-F acceptance criterion).
//!   * [`server`] — helper that spawns an in-process
//!     [`knomosis_host::server::Server`] backed by
//!     [`knomosis_host::kernel::mock::MockKernel`].  Lets `--standalone`
//!     mode self-contain the benchmark without operators needing to
//!     bring up a separate knomosis-host daemon.
//!   * [`config`] — CLI flag parser.  Hand-rolled (no `clap`) to
//!     match the workspace's minimal-dependency posture; mirrors
//!     [`knomosis_host::config`]'s parser style.
//!
//! ## What this crate measures
//!
//! Per the plan §RH-F:
//!
//!   1. **Throughput.**  Sustained submissions per second over the
//!      configured workload.  Target: ≥ 10 000 tx/sec.
//!   2. **End-to-end latency.**  Time from client `connect()` to
//!      client receiving the verdict byte response.  Includes
//!      framing, queue dispatch, kernel.submit (MockKernel: ~ns),
//!      response framing.  Target: `p99 < 10 ms`.
//!
//! ## What this crate does **not** measure
//!
//!   * **Lean kernel throughput.**  The MockKernel returns `Ok`
//!     immediately; per-request CPU cost is dominated by frame
//!     parsing + queue dispatch.  Benchmarking against the real
//!     Lean kernel (CommandKernel today, or a future `knomosis serve`
//!     subprocess kernel) is a follow-up work unit; the harness
//!     supports it by accepting `--connect <ADDR>` flag pointing
//!     at any knomosis-host instance with any kernel.
//!   * **TLS overhead.**  The benchmark uses plain TCP (or Unix
//!     socket); TLS adds ~µs per handshake which is not the
//!     RH-F target's concern.
//!   * **Adversarial workloads.**  Every fixture is a valid
//!     transfer; the host's parse-error / oversize-frame /
//!     queue-saturation paths are exercised by the knomosis-host
//!     integration test suite (`runtime/knomosis-host/tests/`), not
//!     by this benchmark.
//!
//! ## Mathematical soundness
//!
//! Latency percentiles are computed from a sorted Vec of per-request
//! nanosecond durations via the NIST nearest-rank method.  For `N`
//! requests, the `k`-th percentile (with `k` in `[0..den]`) is:
//!
//! ```text
//!   p_k = sorted[max(ceil(k * N / den) - 1, 0)]   (when k > 0)
//!   p_0 = sorted[0]                                (special case)
//! ```
//!
//! with `den = 100` for `p50` / `p90` / `p99` and `den = 1000` for
//! `p999` (≡ `99.9th percentile`).  This is mathematically
//! equivalent to "the smallest observed value that exceeds k% of
//! the samples" and matches the convention used by Criterion /
//! HdrHistogram.  For p50 specifically, this evaluates to
//! `sorted[ceil(N/2) - 1]` which equals `sorted[(N-1)/2]` (the
//! lower median) for all `N >= 1` by integer-arithmetic
//! equivalence.
//!
//!   * `mean` and `stddev` use the [Welford][welford-link] one-pass
//!     numerically-stable algorithm, accumulating in f64 throughout.
//!     This avoids the catastrophic cancellation that the naive
//!     "sum of squares minus square of sums" formulation would
//!     exhibit at large sample counts.
//!   * `stddev` is the **population** standard deviation
//!     (`variance = M2 / N`, not `M2 / (N - 1)`).
//!
//! [welford-link]: https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance#Welford%27s_online_algorithm
//!
//! Throughput is `measured_requests * 1e9 / elapsed_ns`, where
//! `elapsed_ns` is the wallclock between the first non-warmup
//! request beginning and the latest non-warmup completion across
//! all workers.  This is the wallclock-measured ops/sec the
//! deployment achieves, NOT a per-thread sum (which would
//! mis-attribute speed-up to the benchmark's own parallelism).
//!
//! ## Reproducibility
//!
//! The fixture generator is deterministic given a `seed` (default
//! `0xC4_C4_C4_C4_C4_C4_C4_C4`).  Actor keys are derived from
//! `(seed, actor_index)` via a documented Keccak-256 hash chain;
//! signed actions are deterministic by RFC-6979.  Two runs with
//! the same `(seed, actor_count, transfer_count)` produce identical
//! payload bytes, so CI runs can verify byte-equivalence over
//! time.
//!
//! ## Crate-level invariants
//!
//!   1. **No panics on attacker input.**  Every fixture-, runner-,
//!      or report-level error path returns a typed error rather
//!      than panicking.  The CLI binary maps each error to an
//!      `OperatorExitCode` for supervisor visibility.
//!   2. **No `unsafe`.**  `unsafe_code = "forbid"` workspace lint.
//!   3. **Bounded memory.**  Pre-generated payloads × pre-generated
//!      latency samples × pre-generated reports.  No unbounded
//!      channels, no unbounded queues.  Memory ceiling is
//!      `actor_count × 33 (pubkey)
//!       + actor_count × 32 (private scalar)
//!       + transfer_count × 136 (Transfer payload) × 2
//!         (raw + 4-byte-prefixed framed copy)
//!       + transfer_count × 8 (latency sample u64)`.
//!      For the default `(1000, 10000)` workload this is ~3 MiB.

#![doc(html_root_url = "https://docs.rs/knomosis-bench/0.2.1")]

pub mod config;
pub mod fixture;
pub mod histogram;
pub mod report;
pub mod runner;
pub mod server;

/// Crate name, mirrored from `Cargo.toml`.
pub const CRATE_NAME: &str = "knomosis-bench";

/// Diagnostic identifier the binary publishes through startup
/// logging.  Operators read this to confirm at startup which
/// version of the benchmark harness is in use.
pub const BENCH_IDENTIFIER: &str = "knomosis-bench/v1";

/// The benchmark protocol version.  Bumped if the report-file
/// JSON schema, baseline comparison semantics, or fixture
/// generation algorithm changes in a way that breaks
/// version-N → version-(N+1) regression-test continuity.
pub const PROTOCOL_VERSION: u32 = 1;

/// Default actor count.  Per the plan §RH-F step 1.
pub const DEFAULT_ACTOR_COUNT: usize = 1000;

/// Default transfer count.  Per the plan §RH-F step 2.
pub const DEFAULT_TRANSFER_COUNT: usize = 10_000;

/// Default number of submitter worker threads.  Empirical optimum
/// against knomosis-host's single-worker-thread architecture: enough
/// concurrency to saturate the bounded queue, not so many that
/// thread-scheduling overhead dominates.
pub const DEFAULT_WORKER_COUNT: usize = 64;

/// Default warmup-request count.  Each warmup request is
/// pre-included in the workload but its latency is discarded.
/// 1000 warmup requests is enough to amortise OS-level connection-
/// caching effects.
pub const DEFAULT_WARMUP_REQUESTS: usize = 1_000;

/// Default fixture generator seed.  Constant chosen for
/// reproducibility; the seed is overridable via `--seed`.
pub const DEFAULT_SEED: u64 = 0xC4_C4_C4_C4_C4_C4_C4_C4;

/// Default regression-detection threshold (10% per the plan §RH-F
/// acceptance criterion).
pub const DEFAULT_REGRESSION_THRESHOLD: f64 = 0.10;

#[cfg(test)]
mod tests {
    use super::{
        BENCH_IDENTIFIER, CRATE_NAME, DEFAULT_ACTOR_COUNT, DEFAULT_REGRESSION_THRESHOLD,
        DEFAULT_SEED, DEFAULT_TRANSFER_COUNT, DEFAULT_WARMUP_REQUESTS, DEFAULT_WORKER_COUNT,
        PROTOCOL_VERSION,
    };

    /// Crate-name constant doesn't drift silently.
    #[test]
    fn crate_name_constant() {
        assert_eq!(CRATE_NAME, "knomosis-bench");
    }

    /// Identifier constant is the documented v1 string.
    #[test]
    fn identifier_constant() {
        assert_eq!(BENCH_IDENTIFIER, "knomosis-bench/v1");
    }

    /// Protocol version starts at 1 and is bumped by amendment.
    #[test]
    fn protocol_version_constant() {
        assert_eq!(PROTOCOL_VERSION, 1);
    }

    /// Default constants match the documented plan §RH-F values.
    /// Pinning these via `assert_eq!` (rather than only via the
    /// constants' definitions) catches accidental drift: a PR that
    /// bumps one without also bumping the documentation will fail
    /// this test.
    #[test]
    fn default_constants_match_plan() {
        assert_eq!(DEFAULT_ACTOR_COUNT, 1000);
        assert_eq!(DEFAULT_TRANSFER_COUNT, 10_000);
        assert_eq!(DEFAULT_WORKER_COUNT, 64);
        assert_eq!(DEFAULT_WARMUP_REQUESTS, 1_000);
        assert_eq!(DEFAULT_SEED, 0xC4_C4_C4_C4_C4_C4_C4_C4);
        // Threshold pinned to 10% per the plan §RH-F acceptance
        // criterion ("alerts if numbers drop by more than 10%").
        assert!(
            (DEFAULT_REGRESSION_THRESHOLD - 0.10).abs() < f64::EPSILON,
            "threshold drifted from 10%"
        );
    }
}

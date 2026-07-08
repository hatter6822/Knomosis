// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The benchmark driver: start a **real** gateway HTTP listener over the
//! fixture, then hit `GET /v1/actors/{id}/balances` with `--workers`
//! concurrent **raw-HTTP** clients and aggregate latency + throughput.
//!
//! Throughput is the **wallclock** rate (NIST/Criterion convention, matching
//! `knomosis-bench`): each worker tracks the earliest *measured*-request start
//! and the latest *measured*-request end (`Instant`s are monotonic +
//! cross-thread comparable in-process), and the global window is
//! `[min start, max end]` — so the figure is the rate the deployment achieves,
//! not a per-thread sum (which would mis-credit the benchmark's own
//! parallelism).  The first `--warmup` requests are excluded.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use knomosis_bench::histogram::Histogram;
use knomosis_gateway::config::{AdmissionStage, Config, LogFormat, SseConfig};
use knomosis_gateway::http::spawn_plain_listener;
use knomosis_gateway::state::AppState;

use crate::fixture::Fixture;
use crate::BENCH_TOKEN;

/// Per-request socket timeout (a wedged request is counted an error, never an
/// unbounded hang).
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// The measurement parameters (the fixture supplies the actor count).
#[derive(Clone, Copy, Debug)]
pub struct RunParams {
    /// Number of **measured** requests (after warmup).
    pub requests: usize,
    /// Number of warmup requests (latency discarded; they prime caches).
    pub warmup: usize,
    /// Number of concurrent client worker threads.
    pub workers: usize,
    /// Number of gateway handler-pool threads (the server side).
    pub handler_threads: usize,
}

/// The aggregate result of a benchmark run.
#[derive(Clone, Debug)]
pub struct RunOutcome {
    /// Wallclock across the measured-request window.
    pub elapsed: Duration,
    /// Number of measured requests that **succeeded** (HTTP 200).
    pub measured: usize,
    /// Number of requests (warmup or measured) that failed (connect / write /
    /// non-200).  A healthy run has zero.
    pub errors: usize,
    /// Sustained throughput over the measured window (requests/second).
    pub throughput: f64,
    /// The merged per-request latency histogram (measured requests only).
    pub latency: Histogram,
}

/// Errors running the benchmark.
#[derive(Debug, thiserror::Error)]
pub enum RunnerError {
    /// The gateway `AppState` could not be built (e.g. the fixture DB could not
    /// be opened read-only, or the token file was rejected).
    #[error("failed to build gateway state: {0}")]
    State(String),
    /// The benchmark HTTP listener could not be bound.
    #[error("failed to bind the benchmark listener: {0}")]
    Bind(String),
    /// A gateway handler thread could not be spawned.
    #[error("failed to spawn the gateway handler pool: {0}")]
    Spawn(String),
    /// A client worker thread could not be spawned, or panicked.
    #[error("benchmark client worker failed: {0}")]
    Worker(String),
    /// Every measured request failed — the run produced no usable sample.
    #[error("no measured request succeeded ({errors} errors); the gateway may be misconfigured")]
    NoSamples {
        /// The number of failed requests.
        errors: usize,
    },
}

/// Run the benchmark against `fixture` with `params`.  Starts the gateway,
/// drives the workers, aggregates, and cleanly stops the gateway.
///
/// # Errors
///
/// See [`RunnerError`].
pub fn run(fixture: &Fixture, params: RunParams) -> Result<RunOutcome, RunnerError> {
    let gateway = Gateway::start(fixture, params.handler_threads)?;
    let total = params.warmup.saturating_add(params.requests);
    let next = Arc::new(AtomicUsize::new(0));
    let actors = fixture.config.actors;
    let addr = gateway.addr;

    let mut handles = Vec::with_capacity(params.workers);
    for _ in 0..params.workers {
        let next = Arc::clone(&next);
        let handle = std::thread::Builder::new()
            .name("knx-gw-bench-client".to_string())
            .spawn(move || worker_loop(addr, &next, total, params.warmup, actors))
            .map_err(|e| RunnerError::Worker(e.to_string()))?;
        handles.push(handle);
    }

    let mut merged = Histogram::with_capacity(params.requests);
    let mut earliest: Option<Instant> = None;
    let mut latest: Option<Instant> = None;
    let mut measured = 0usize;
    let mut errors = 0usize;
    for handle in handles {
        let result = handle
            .join()
            .map_err(|_| RunnerError::Worker("panic".to_string()))?;
        merged.merge(&result.latency);
        measured += result.measured;
        errors += result.errors;
        earliest = min_opt(earliest, result.first_start);
        latest = max_opt(latest, result.last_end);
    }
    // The gateway is stopped here (Drop joins the handler pool).
    drop(gateway);

    if measured == 0 {
        return Err(RunnerError::NoSamples { errors });
    }
    let elapsed = match (earliest, latest) {
        (Some(s), Some(e)) => e.saturating_duration_since(s),
        _ => Duration::ZERO,
    };
    let throughput = if elapsed.as_nanos() == 0 {
        0.0
    } else {
        measured as f64 * 1e9 / elapsed.as_nanos() as f64
    };
    Ok(RunOutcome {
        elapsed,
        measured,
        errors,
        throughput,
        latency: merged,
    })
}

/// The minimum of two optional instants.
fn min_opt(a: Option<Instant>, b: Option<Instant>) -> Option<Instant> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (x, None) | (None, x) => x,
    }
}

/// The maximum of two optional instants.
fn max_opt(a: Option<Instant>, b: Option<Instant>) -> Option<Instant> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (x, None) | (None, x) => x,
    }
}

/// One client worker's result.
struct WorkerResult {
    latency: Histogram,
    measured: usize,
    errors: usize,
    first_start: Option<Instant>,
    last_end: Option<Instant>,
}

/// One client worker: pull request indices off the shared counter until
/// `total`, issue each as a one-shot `GET`, and record measured-request
/// latencies + the measured-window bounds.
fn worker_loop(
    addr: SocketAddr,
    next: &AtomicUsize,
    total: usize,
    warmup: usize,
    actors: usize,
) -> WorkerResult {
    let mut latency = Histogram::new();
    let mut measured = 0usize;
    let mut errors = 0usize;
    let mut first_start: Option<Instant> = None;
    let mut last_end: Option<Instant> = None;
    loop {
        let i = next.fetch_add(1, Ordering::Relaxed);
        if i >= total {
            break;
        }
        let actor = (i % actors) as u64;
        let is_measured = i >= warmup;
        let start = Instant::now();
        let ok = get_balances(addr, actor);
        let end = Instant::now();
        if !ok {
            errors += 1;
            continue;
        }
        if is_measured {
            latency.record(end.saturating_duration_since(start));
            first_start = Some(first_start.map_or(start, |s| s.min(start)));
            last_end = Some(last_end.map_or(end, |e| e.max(end)));
            measured += 1;
        }
    }
    WorkerResult {
        latency,
        measured,
        errors,
        first_start,
        last_end,
    }
}

/// Issue a single one-shot `GET /v1/actors/{actor}/balances` (bearer-authed,
/// `Connection: close`), read the full response, and return whether it was a
/// `200`.  Any connect / write / read error → `false` (counted an error).
fn get_balances(addr: SocketAddr, actor: u64) -> bool {
    let Ok(mut stream) = TcpStream::connect(addr) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(REQUEST_TIMEOUT));
    let _ = stream.set_write_timeout(Some(REQUEST_TIMEOUT));
    let _ = stream.set_nodelay(true);
    let request = format!(
        "GET /v1/actors/{actor}/balances HTTP/1.1\r\nHost: b\r\n\
         Authorization: Bearer {BENCH_TOKEN}\r\nConnection: close\r\n\r\n"
    );
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    // Read the full response to EOF (the server closes after `Connection:
    // close`); a balances response is small, so cap defensively.
    let mut buf = Vec::with_capacity(512);
    let mut chunk = [0u8; 4096];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.len() > 64 * 1024 {
                    break;
                }
            }
        }
    }
    buf.starts_with(b"HTTP/1.1 200")
}

/// A running gateway listener over the fixture (the gateway's own HTTP stack,
/// thread-per-connection).  Dropping it sets the shutdown flag and joins the
/// accept thread — no leaked threads across runs/tests.
struct Gateway {
    addr: SocketAddr,
    state: Arc<AppState>,
    accept: Option<JoinHandle<()>>,
}

impl Gateway {
    /// Build the gateway `AppState` over the fixture (read-only DB + the bench
    /// token, rate limiting disabled), and spawn its own-stack plaintext
    /// listener on an ephemeral port.  `max_connections` caps the server-side
    /// concurrency (the gateway serves each connection on its own thread).
    fn start(fixture: &Fixture, max_connections: usize) -> Result<Self, RunnerError> {
        let state = AppState::new(bench_config(fixture, max_connections))
            .map_err(|e| RunnerError::State(e.to_string()))?;
        let state = Arc::new(state);
        let (addr, accept) = spawn_plain_listener(&state.config, &state).map_err(|e| {
            let msg = e.to_string();
            if matches!(e, knomosis_gateway::http::ServeError::Bind { .. }) {
                RunnerError::Bind(msg)
            } else {
                RunnerError::Spawn(msg)
            }
        })?;
        Ok(Self {
            addr,
            state,
            accept: Some(accept),
        })
    }
}

impl Drop for Gateway {
    fn drop(&mut self) {
        self.state.shutdown.store(true, Ordering::SeqCst);
        if let Some(accept) = self.accept.take() {
            let _ = accept.join();
        }
    }
}

/// The gateway configuration the benchmark serves: the fixture's read-only DB +
/// bearer token, **rate limiting disabled** (else the shared bench credential
/// would be throttled to the default cap), no host / events / TLS.  The bench's
/// server-side concurrency knob maps to the gateway's `--max-connections`.
fn bench_config(fixture: &Fixture, max_connections: usize) -> Config {
    Config {
        listen: "127.0.0.1:0".parse().expect("loopback addr"),
        max_connections,
        indexer_db: Some(fixture.db_path.clone()),
        free_tier: 0,
        action_cost: 0,
        epoch_length: 0,
        gas_pool_actor: None,
        deployment_id: "knx-gw-bench".to_string(),
        ok_admission_stage: AdmissionStage::Finalized,
        host_addr: None,
        event_subscribe_addr: None,
        auth_token_file: Some(fixture.token_path.clone()),
        rate_limit_rps: 0, // the bench would otherwise self-throttle on one credential
        host_pool_size: 8,
        host_max_inflight: 8,
        request_deadline_ms: 5000,
        max_frame_size: 1024 * 1024,
        idempotency_ttl_secs: 0,
        sse: SseConfig::default(),
        tls: None,
        cors_origin: None,
        log_format: LogFormat::Json,
        dev: false,
        upstream_subscriptions: 1,
        l2_chain_id: 83572,
    }
}

#[cfg(test)]
mod tests {
    use super::{run, RunParams, RunnerError};
    use crate::fixture::{build, FixtureConfig};

    /// A small end-to-end run: a real gateway serves real concurrent HTTP
    /// clients over the fixture, all requests succeed, and the latency +
    /// throughput aggregate is well-formed.
    #[test]
    fn small_run_succeeds_end_to_end() {
        let fixture = build(FixtureConfig {
            actors: 8,
            resources: 2,
            seed: 1,
        })
        .expect("fixture");
        let outcome = run(
            &fixture,
            RunParams {
                requests: 60,
                warmup: 10,
                workers: 4,
                handler_threads: 4,
            },
        )
        .expect("run");
        assert_eq!(outcome.measured, 60, "every measured request was recorded");
        assert_eq!(
            outcome.errors, 0,
            "no request failed against a healthy gateway"
        );
        assert_eq!(outcome.latency.len(), 60);
        assert!(outcome.throughput > 0.0, "a positive sustained throughput");
        assert!(outcome.elapsed.as_nanos() > 0);
    }

    /// Zero measured requests (warmup-only) surfaces `NoSamples` rather than a
    /// divide-by-zero.
    #[test]
    fn warmup_only_run_has_no_samples() {
        let fixture = build(FixtureConfig {
            actors: 2,
            resources: 1,
            seed: 0,
        })
        .expect("fixture");
        let err = run(
            &fixture,
            RunParams {
                requests: 0,
                warmup: 5,
                workers: 2,
                handler_threads: 2,
            },
        )
        .unwrap_err();
        assert!(matches!(err, RunnerError::NoSamples { .. }));
    }
}

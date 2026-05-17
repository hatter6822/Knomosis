// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Concurrent benchmark driver.
//!
//! ## Workflow
//!
//!   1. Receive a generated [`crate::fixture::Fixture`] and a
//!      benchmark [`Endpoint`] (Unix-socket path or TCP address).
//!   2. Partition the pre-generated payloads across `worker_count`
//!      submitter threads via a shared `AtomicUsize` cursor.
//!   3. Each worker thread:
//!      - Repeatedly atomically fetches the next payload index.
//!      - Opens a fresh connection (one connection per request,
//!        per the canon-host wire-format §10.5 ABI).
//!      - Writes the framed payload (4-byte BE length + payload).
//!      - Reads the 5-byte verdict header + UTF-8 reason.
//!      - Records the elapsed wallclock as a latency sample in
//!        the worker's local [`crate::histogram::Histogram`].
//!   4. After every worker exits, merge per-worker histograms and
//!      compute the [`crate::histogram::LatencySummary`].
//!
//! ## Latency exclusion: warmup phase
//!
//! The first `warmup_requests` requests are still submitted but
//! their latencies are NOT included in the histogram.  This
//! amortises OS-level effects (connection cache warmup, page
//! faults, branch predictor convergence) that would otherwise
//! contaminate the steady-state measurement.
//!
//! ## Throughput calculation
//!
//! `throughput_ops_per_sec = measured_requests * 1e9 / elapsed_ns`
//!
//! Where `elapsed_ns` is the wallclock between the first non-warmup
//! submission and the last response received.  This is the
//! deployment-facing ops/sec; it is NOT a per-thread sum.
//!
//! ## Error policy
//!
//! Any non-Ok verdict from a submission, any I/O error, or any
//! malformed response halts the runner.  The benchmark is
//! configured to run against a known-Ok kernel (MockKernel by
//! default), so any failure is operator-actionable: a NotAdmissible
//! or ParseError verdict means the harness has a bug; a transport
//! error means the host isn't where we think it is.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::os::unix::net::UnixStream;

use crate::fixture::Fixture;
use crate::histogram::Histogram;

/// Where the benchmark connects to.
#[derive(Clone, Debug)]
pub enum Endpoint {
    /// Connect to a Unix-socket at the given path.  Unix-only.
    #[cfg(unix)]
    UnixSocket(PathBuf),
    /// Connect to a TCP address.
    Tcp(SocketAddr),
}

impl Endpoint {
    /// Establish a connection.  Returns a typed [`Connection`]
    /// implementing [`Read`] + [`Write`].
    ///
    /// # Errors
    ///
    /// Returns `std::io::Error` if `connect` fails.
    pub fn connect(&self) -> std::io::Result<Connection> {
        match self {
            #[cfg(unix)]
            Self::UnixSocket(path) => {
                let stream = UnixStream::connect(path)?;
                Ok(Connection::Unix(stream))
            }
            Self::Tcp(addr) => {
                let stream = TcpStream::connect(addr)?;
                Ok(Connection::Tcp(stream))
            }
        }
    }
}

/// A connection abstracting over Unix and TCP streams.
pub enum Connection {
    /// Unix-domain socket connection.
    #[cfg(unix)]
    Unix(UnixStream),
    /// TCP connection.
    Tcp(TcpStream),
}

impl Connection {
    /// Apply a read + write timeout.  Bounded by `timeout`.
    pub fn set_timeout(&self, timeout: Duration) -> std::io::Result<()> {
        match self {
            #[cfg(unix)]
            Self::Unix(stream) => {
                stream.set_read_timeout(Some(timeout))?;
                stream.set_write_timeout(Some(timeout))?;
                Ok(())
            }
            Self::Tcp(stream) => {
                stream.set_read_timeout(Some(timeout))?;
                stream.set_write_timeout(Some(timeout))?;
                // Disable Nagle's algorithm — we want each
                // request's bytes flushed immediately.  Without
                // this, the OS may buffer up to 200 ms waiting for
                // a co-payload, defeating the benchmark.
                stream.set_nodelay(true)?;
                Ok(())
            }
        }
    }

    /// Signal the half-close (no more writes) to the peer.  This
    /// matches canon-host's expected per-connection sequence.
    pub fn shutdown_write(&self) -> std::io::Result<()> {
        match self {
            #[cfg(unix)]
            Self::Unix(stream) => stream.shutdown(std::net::Shutdown::Write),
            Self::Tcp(stream) => stream.shutdown(std::net::Shutdown::Write),
        }
    }
}

impl Read for Connection {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            #[cfg(unix)]
            Self::Unix(stream) => stream.read(buf),
            Self::Tcp(stream) => stream.read(buf),
        }
    }
}

impl Write for Connection {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            #[cfg(unix)]
            Self::Unix(stream) => stream.write(buf),
            Self::Tcp(stream) => stream.write(buf),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            #[cfg(unix)]
            Self::Unix(stream) => stream.flush(),
            Self::Tcp(stream) => stream.flush(),
        }
    }
}

/// Configuration for the runner.
#[derive(Clone, Debug)]
pub struct RunnerConfig {
    /// Connect target.
    pub endpoint: Endpoint,
    /// Number of submitter worker threads.
    pub worker_count: usize,
    /// Number of warmup requests excluded from the measurement
    /// window.  The runner stops measuring elapsed time until the
    /// first non-warmup request begins.
    pub warmup_requests: usize,
    /// Per-request connect+request+response timeout.
    pub request_timeout: Duration,
}

impl RunnerConfig {
    /// Construct a default runner config given an endpoint.  Uses
    /// the documented [`crate::DEFAULT_WORKER_COUNT`] and
    /// [`crate::DEFAULT_WARMUP_REQUESTS`].
    #[must_use]
    pub fn defaults_for(endpoint: Endpoint) -> Self {
        Self {
            endpoint,
            worker_count: crate::DEFAULT_WORKER_COUNT,
            warmup_requests: crate::DEFAULT_WARMUP_REQUESTS,
            // Per-request timeout generously sized for both
            // microbenchmark conditions and a slow CI runner.
            // Per-request budget under the 10k tx/sec target is
            // 100µs, so 30s is 5+ orders of magnitude of margin.
            request_timeout: Duration::from_secs(30),
        }
    }
}

/// Errors surfaced by the runner.
#[derive(Debug, thiserror::Error)]
pub enum RunnerError {
    /// `worker_count` must be >= 1.
    #[error("worker_count must be >= 1, got 0")]
    NoWorkers,
    /// `warmup_requests` must be < fixture size so at least one
    /// request is measured.
    #[error("warmup_requests {warmup} must be less than fixture size {fixture_len}")]
    WarmupExceedsFixture {
        /// The configured warmup count.
        warmup: usize,
        /// The fixture's total request count.
        fixture_len: usize,
    },
    /// One of the workers panicked.
    #[error("worker thread panicked")]
    WorkerPanicked,
    /// One of the workers returned a typed transport error.  The
    /// runner returns the first such error and aborts the run; the
    /// remaining workers may continue running briefly until they
    /// observe the shared abort signal.
    #[error("worker submission failed: {0}")]
    SubmissionFailed(#[from] SubmissionError),
}

/// Per-request errors.  Distinguished from `RunnerError` so the
/// runner can attribute failure to a single submission rather than
/// a configuration issue.
#[derive(Debug, thiserror::Error)]
pub enum SubmissionError {
    /// I/O error connecting / writing / reading.
    #[error("transport I/O error: {0}")]
    Io(#[from] std::io::Error),
    /// The host returned a non-Ok verdict.  Since the benchmark is
    /// configured to expect Ok, any other verdict surfaces a bug
    /// in the harness.
    #[error("unexpected non-Ok verdict {verdict_byte}: {reason}")]
    UnexpectedVerdict {
        /// The verdict byte the host returned.
        verdict_byte: u8,
        /// The UTF-8 reason string.  Empty when none was supplied.
        reason: String,
    },
    /// The response header (5 bytes) was truncated.
    #[error("truncated response header: got {0} bytes")]
    TruncatedResponseHeader(usize),
    /// The response reason payload was shorter than the declared
    /// length.
    #[error("truncated response payload: got {got} bytes, declared {declared}")]
    TruncatedResponsePayload {
        /// Bytes actually read.
        got: usize,
        /// Bytes the header declared.
        declared: usize,
    },
}

/// The measurement result.  Returned by [`run`] after the workers
/// drain.
#[derive(Clone, Debug)]
pub struct RunOutcome {
    /// Wallclock elapsed between the first measured-phase
    /// submission and the last response.  Warmup time is
    /// excluded.
    pub elapsed: Duration,
    /// Number of requests counted in the measurement.
    pub measured_requests: usize,
    /// Merged histogram across all worker threads.
    pub histogram: Histogram,
}

impl RunOutcome {
    /// Compute throughput in ops per second.
    #[must_use]
    pub fn throughput_ops_per_sec(&self) -> f64 {
        let elapsed_ns = self.elapsed.as_nanos();
        if elapsed_ns == 0 {
            return 0.0;
        }
        (self.measured_requests as f64) * 1e9 / (elapsed_ns as f64)
    }
}

/// Per-worker shared state.
struct SharedRunState {
    /// Atomic cursor into the fixture's payloads Vec.  Workers
    /// `fetch_add(1)` to claim the next request.
    cursor: AtomicUsize,
    /// Total fixture size; workers exit when `cursor >= total`.
    total_requests: usize,
    /// Warmup-phase ceiling; below this index the latency sample
    /// is discarded.
    warmup_requests: usize,
    /// Pre-encoded payloads (4-byte length prefix + CBE bytes).
    /// `Arc`-shared snapshot of the fixture's framed wire bytes.
    framed_payloads: Arc<Vec<Vec<u8>>>,
    /// Submission start-of-measurement timestamp.  Captured by
    /// the first worker that begins a non-warmup request.  Used
    /// to compute throughput.
    measurement_start: Mutex<Option<Instant>>,
    /// Submission end-of-measurement timestamp.  Captured by every
    /// worker after each non-warmup completion; the last update
    /// wins.
    measurement_end: Mutex<Option<Instant>>,
    /// Number of non-warmup requests successfully completed.
    measured_count: AtomicUsize,
    /// Abort flag.  Set by any worker that hits an error so others
    /// can short-circuit.
    abort: std::sync::atomic::AtomicBool,
    /// First error observed (if any).  Carried out via the
    /// runner's return value.
    first_error: Mutex<Option<SubmissionError>>,
}

/// Run a benchmark.  Spawns workers, waits for them to drain, and
/// returns the merged outcome.
///
/// # Errors
///
/// See [`RunnerError`].
pub fn run(fixture: &Fixture, config: &RunnerConfig) -> Result<RunOutcome, RunnerError> {
    if config.worker_count == 0 {
        return Err(RunnerError::NoWorkers);
    }
    if config.warmup_requests >= fixture.len() {
        return Err(RunnerError::WarmupExceedsFixture {
            warmup: config.warmup_requests,
            fixture_len: fixture.len(),
        });
    }

    // 1. Frame every payload up-front.  Frame = 4-byte BE length +
    //    payload bytes.  Pre-framing means the runner hot path
    //    is one `write_all(framed_bytes)` per request — no
    //    per-request allocation, no per-request encoder call.
    let framed_payloads: Vec<Vec<u8>> = fixture
        .payloads
        .iter()
        .map(|p| {
            let len = u32::try_from(p.len()).expect("payload fits u32");
            let mut buf = Vec::with_capacity(4 + p.len());
            buf.extend_from_slice(&len.to_be_bytes());
            buf.extend_from_slice(p);
            buf
        })
        .collect();
    let framed_payloads = Arc::new(framed_payloads);

    let shared = Arc::new(SharedRunState {
        cursor: AtomicUsize::new(0),
        total_requests: fixture.len(),
        warmup_requests: config.warmup_requests,
        framed_payloads,
        measurement_start: Mutex::new(None),
        measurement_end: Mutex::new(None),
        measured_count: AtomicUsize::new(0),
        abort: std::sync::atomic::AtomicBool::new(false),
        first_error: Mutex::new(None),
    });

    // 2. Spawn workers.
    let mut handles: Vec<JoinHandle<Histogram>> = Vec::with_capacity(config.worker_count);
    for worker_id in 0..config.worker_count {
        let shared = Arc::clone(&shared);
        let endpoint = config.endpoint.clone();
        let timeout = config.request_timeout;
        let handle = std::thread::Builder::new()
            .name(format!("canon-bench-worker-{worker_id}"))
            .spawn(move || worker_loop(&shared, &endpoint, timeout))
            .expect("spawn worker thread");
        handles.push(handle);
    }

    // 3. Join workers.  Collect their per-worker histograms.
    let mut merged = Histogram::new();
    let mut any_panicked = false;
    for handle in handles {
        match handle.join() {
            Ok(h) => merged.merge(&h),
            Err(_) => {
                any_panicked = true;
            }
        }
    }
    if any_panicked {
        return Err(RunnerError::WorkerPanicked);
    }

    // 4. Drain the first error (if any).
    let mut first_err_guard = shared.first_error.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(err) = first_err_guard.take() {
        return Err(RunnerError::SubmissionFailed(err));
    }
    drop(first_err_guard);

    // 5. Compute the elapsed window.  Both endpoints must have
    //    been recorded (which they are after the first measured
    //    submission and the last completed submission).  If neither
    //    was recorded (no measured requests), elapsed is zero.
    let start = *shared
        .measurement_start
        .lock()
        .unwrap_or_else(|p| p.into_inner());
    let end = *shared
        .measurement_end
        .lock()
        .unwrap_or_else(|p| p.into_inner());
    let elapsed = match (start, end) {
        (Some(s), Some(e)) => e.saturating_duration_since(s),
        _ => Duration::ZERO,
    };

    let measured_requests = shared.measured_count.load(Ordering::Acquire);

    Ok(RunOutcome {
        elapsed,
        measured_requests,
        histogram: merged,
    })
}

/// Per-worker loop.  Pulls payloads from the shared cursor and
/// submits each over a fresh connection.
fn worker_loop(shared: &SharedRunState, endpoint: &Endpoint, timeout: Duration) -> Histogram {
    let mut local_hist =
        Histogram::with_capacity(shared.total_requests.saturating_sub(shared.warmup_requests) / 4);
    loop {
        if shared.abort.load(Ordering::Acquire) {
            return local_hist;
        }
        let idx = shared.cursor.fetch_add(1, Ordering::AcqRel);
        if idx >= shared.total_requests {
            return local_hist;
        }
        let framed = &shared.framed_payloads[idx];
        let is_warmup = idx < shared.warmup_requests;

        // Capture the measurement-start timestamp on the first
        // non-warmup request claimed by any worker.
        if !is_warmup {
            let mut guard = shared
                .measurement_start
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            if guard.is_none() {
                *guard = Some(Instant::now());
            }
            drop(guard);
        }

        let started = Instant::now();
        match submit_once(endpoint, framed, timeout) {
            Ok(()) => {
                let elapsed = started.elapsed();
                if !is_warmup {
                    local_hist.record(elapsed);
                    shared.measured_count.fetch_add(1, Ordering::AcqRel);
                    let mut guard = shared
                        .measurement_end
                        .lock()
                        .unwrap_or_else(|p| p.into_inner());
                    *guard = Some(Instant::now());
                    drop(guard);
                }
            }
            Err(e) => {
                // Record first error + signal abort.
                let mut guard = shared.first_error.lock().unwrap_or_else(|p| p.into_inner());
                if guard.is_none() {
                    *guard = Some(e);
                }
                drop(guard);
                shared.abort.store(true, Ordering::Release);
                return local_hist;
            }
        }
    }
}

/// Submit one pre-framed request and verify the response is Ok.
///
/// # Errors
///
/// See [`SubmissionError`].
fn submit_once(
    endpoint: &Endpoint,
    framed: &[u8],
    timeout: Duration,
) -> Result<(), SubmissionError> {
    let mut conn = endpoint.connect()?;
    conn.set_timeout(timeout)?;
    conn.write_all(framed)?;
    conn.flush()?;
    // Half-close to signal end-of-request to canon-host.
    let _ = conn.shutdown_write();

    // Read the 5-byte response header.
    let mut header = [0u8; 5];
    read_exact_with_eof(&mut conn, &mut header)?;
    let verdict_byte = header[0];
    let reason_len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;

    // Read the reason payload.
    let mut reason_bytes = vec![0u8; reason_len];
    if reason_len > 0 {
        read_exact_with_eof(&mut conn, &mut reason_bytes)?;
    }
    let reason = String::from_utf8_lossy(&reason_bytes).into_owned();

    // We expect Ok (verdict byte 0).  Anything else is a harness
    // failure (the host's MockKernel is configured to return Ok
    // for every submission; a NotAdmissible / ParseError / Busy
    // would mean the harness has wired up the wrong kernel or
    // the host's queue is saturated).
    if verdict_byte != 0 {
        return Err(SubmissionError::UnexpectedVerdict {
            verdict_byte,
            reason,
        });
    }
    Ok(())
}

/// Read exactly `buf.len()` bytes from `reader`, returning a typed
/// truncation error on EOF rather than the generic
/// `std::io::ErrorKind::UnexpectedEof`.
fn read_exact_with_eof<R: Read>(reader: &mut R, buf: &mut [u8]) -> Result<(), SubmissionError> {
    let total_len = buf.len();
    let mut filled = 0;
    while filled < total_len {
        let n = reader.read(&mut buf[filled..])?;
        if n == 0 {
            return if total_len == 5 {
                Err(SubmissionError::TruncatedResponseHeader(filled))
            } else {
                Err(SubmissionError::TruncatedResponsePayload {
                    got: filled,
                    declared: total_len,
                })
            };
        }
        filled += n;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Endpoint, RunnerConfig, RunnerError};
    use std::time::Duration;

    /// Default RunnerConfig has documented values.
    #[test]
    fn default_config_values() {
        let cfg = RunnerConfig::defaults_for(Endpoint::Tcp("127.0.0.1:0".parse().unwrap()));
        assert_eq!(cfg.worker_count, crate::DEFAULT_WORKER_COUNT);
        assert_eq!(cfg.warmup_requests, crate::DEFAULT_WARMUP_REQUESTS);
        assert_eq!(cfg.request_timeout, Duration::from_secs(30));
    }

    /// `run` rejects zero workers.
    #[test]
    fn run_rejects_zero_workers() {
        let cfg = crate::fixture::FixtureConfig {
            actor_count: 2,
            transfer_count: 4,
            ..Default::default()
        };
        let fixture = crate::fixture::generate(&cfg).unwrap();
        let mut runner_cfg =
            RunnerConfig::defaults_for(Endpoint::Tcp("127.0.0.1:65535".parse().unwrap()));
        runner_cfg.worker_count = 0;
        let result = crate::runner::run(&fixture, &runner_cfg);
        assert!(matches!(result, Err(RunnerError::NoWorkers)));
    }

    /// `run` rejects warmup >= fixture size.
    #[test]
    fn run_rejects_oversize_warmup() {
        let cfg = crate::fixture::FixtureConfig {
            actor_count: 2,
            transfer_count: 4,
            ..Default::default()
        };
        let fixture = crate::fixture::generate(&cfg).unwrap();
        let mut runner_cfg =
            RunnerConfig::defaults_for(Endpoint::Tcp("127.0.0.1:65535".parse().unwrap()));
        runner_cfg.warmup_requests = fixture.len();
        let result = crate::runner::run(&fixture, &runner_cfg);
        assert!(matches!(
            result,
            Err(RunnerError::WarmupExceedsFixture { .. })
        ));
    }

    /// Endpoint cloning is cheap.
    #[test]
    fn endpoint_clones() {
        let tcp = Endpoint::Tcp("127.0.0.1:1234".parse().unwrap());
        let _clone = tcp.clone();
    }
}

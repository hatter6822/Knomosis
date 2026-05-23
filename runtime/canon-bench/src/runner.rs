// Knomosis  - A Societal Kernel
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
//!   2. Frame every payload up-front (4-byte BE length prefix +
//!      raw CBE bytes) so the worker hot path is one
//!      `write_all(framed_bytes)` per request.
//!   3. Partition the pre-generated payloads across `worker_count`
//!      submitter threads via a shared `AtomicUsize` cursor.
//!   4. Each worker thread:
//!      - Repeatedly atomically fetches the next payload index.
//!      - Opens a fresh connection (one connection per request,
//!        per the knomosis-host wire-format §10.5 ABI).
//!      - Writes the framed payload.
//!      - Reads the 5-byte verdict header + UTF-8 reason.
//!      - Records the elapsed wallclock as a latency sample in
//!        the worker's local [`crate::histogram::Histogram`].
//!      - Tracks its own latest successful-completion timestamp
//!        in a worker-local `Option<Instant>`.
//!   5. After every worker exits (`JoinHandle::join`), merge
//!      per-worker histograms and take the max of per-worker
//!      latest-completion timestamps as the measurement-end
//!      wallclock.
//!
//! ## Hot-path discipline
//!
//! Per-request, the hot path touches exactly two shared atomics:
//!
//!   * `cursor.fetch_add(1, AcqRel)` — claim the next request index.
//!   * `abort.load(Acquire)` — check for an abort signal from a
//!     peer worker.
//!
//! Per-request, ZERO shared `Mutex` operations are performed on the
//! happy path.  The two `Mutex`-guarded fields in `SharedRunState`
//! (`measurement_start`, `first_error`) are accessed at most ONCE
//! per worker: `measurement_start` only the first time any worker
//! claims a non-warmup index (gated by a separate `AtomicBool`
//! fast-path flag); `first_error` only on the first transport-level
//! failure.  The `measurement_end` wallclock is tracked per-worker
//! locally and reduced on join, eliminating the per-request Mutex
//! contention an earlier (pre-audit) design exposed.
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
//! submission (`measurement_start`) and the latest non-warmup
//! completion across all workers (`measurement_end`, reduced from
//! per-worker `WorkerOutcome::last_completion` on join).  This is
//! the deployment-facing ops/sec; it is NOT a per-thread sum.
//!
//! ## Error policy
//!
//! Any non-Ok verdict from a submission, any I/O error, or any
//! malformed response halts the runner.  The benchmark is
//! configured to run against a known-Ok kernel (MockKernel by
//! default), so any failure is operator-actionable: a NotAdmissible
//! or ParseError verdict means the harness has a bug; a transport
//! error means the host isn't where we think it is.  Worker thread
//! spawn failures (`EAGAIN` / `ENOMEM`) surface as a typed
//! [`RunnerError::SpawnFailed`] rather than a panic; already-spawned
//! workers are joined cleanly before the error propagates.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::os::unix::net::UnixStream;

use crate::fixture::Fixture;
use crate::histogram::Histogram;

/// Defensive cap on the response reason-payload length.  The wire
/// format permits up to `u32::MAX` (~4 GiB) reason bytes; trusting
/// that without bounds is a DoS surface when running against
/// `--connect <ADDR>` targets the operator does not control.
///
/// 64 KiB matches `canon_host::kernel::command::MAX_SUBPROCESS_OUTPUT`,
/// which is the largest legitimate reason the production
/// `CommandKernel` will emit (captured subprocess stderr).  Anything
/// larger is either a misbehaving / malicious server or a future
/// kernel that needs the bound bumped intentionally.
pub const MAX_REASON_BYTES: usize = 64 * 1024;

/// Default TCP connect timeout for `Endpoint::connect()`.  Distinct
/// from `RunnerConfig::request_timeout`: the connect timeout bounds
/// just the TCP three-way handshake, not the full request/response
/// cycle.  A separate (smaller) bound matters because TCP
/// `connect()` blocks indefinitely against a non-responding host
/// (the kernel doesn't apply the read / write timeout until after
/// the handshake completes).  Unix-socket connects don't have a
/// connect-timeout API in `std`; they typically complete in
/// sub-millisecond time or fail immediately, so the missing bound
/// is acceptable.
pub const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

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
    /// Equivalent to
    /// `connect_with_timeout(DEFAULT_CONNECT_TIMEOUT)`.
    ///
    /// # Errors
    ///
    /// Returns `std::io::Error` if `connect` fails.
    pub fn connect(&self) -> std::io::Result<Connection> {
        self.connect_with_timeout(DEFAULT_CONNECT_TIMEOUT)
    }

    /// Establish a connection with an explicit connect-only timeout.
    /// Distinct from per-request read/write timeouts: bounds just
    /// the TCP three-way handshake (or Unix-socket open).
    ///
    /// ## Limitations
    ///
    /// `std::os::unix::net::UnixStream` doesn't expose a
    /// connect-with-timeout API in `std`.  For Unix-socket
    /// endpoints, the `timeout` argument is documented but ignored:
    /// Unix-socket connects typically complete in sub-millisecond
    /// time or fail immediately (the socket either exists and
    /// accepts, or `connect(2)` returns `ENOENT` /
    /// `ECONNREFUSED`).  TCP gets a real bound via
    /// [`TcpStream::connect_timeout`].
    ///
    /// # Errors
    ///
    /// Returns `std::io::Error` if `connect` fails or times out.
    pub fn connect_with_timeout(&self, timeout: Duration) -> std::io::Result<Connection> {
        match self {
            #[cfg(unix)]
            Self::UnixSocket(path) => {
                let _ = timeout; // see Limitations.
                let stream = UnixStream::connect(path)?;
                Ok(Connection::Unix(stream))
            }
            Self::Tcp(addr) => {
                let stream = TcpStream::connect_timeout(addr, timeout)?;
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
    /// matches knomosis-host's expected per-connection sequence.
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
    /// Worker thread spawn failed (typically `EAGAIN` /
    /// `ENOMEM` under sustained load).  The runner gracefully
    /// joins any already-spawned workers before returning.
    #[error("failed to spawn worker thread {worker_index}: {source}")]
    SpawnFailed {
        /// The zero-based index of the worker whose spawn failed.
        worker_index: usize,
        /// Underlying OS error.
        #[source]
        source: std::io::Error,
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
    /// The host's declared reason length exceeds [`MAX_REASON_BYTES`].
    /// Defends against a hostile / misbehaving `--connect <ADDR>`
    /// target sending a multi-gigabyte declared length to exhaust
    /// client memory.
    #[error("response reason length {declared} exceeds cap {max}")]
    ResponseTooLarge {
        /// The length the server declared.
        declared: usize,
        /// The configured per-response cap.
        max: usize,
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
///
/// ## Hot-path discipline
///
/// The per-request hot path touches `cursor` (one atomic
/// `fetch_add` per request) and `abort` (one atomic load per
/// iteration).  Both `measurement_start` and `first_error` are
/// guarded by `Mutex` but are accessed at most once per worker
/// (start: first non-warmup; error: first failure).  The
/// `measurement_end` field is **NOT** in `SharedRunState`
/// deliberately: each worker tracks its own latest completion
/// timestamp locally and reduces on join, eliminating the
/// per-request lock contention the previous design exposed.
struct SharedRunState {
    /// Atomic cursor into the fixture's payloads Vec.  Workers
    /// `fetch_add(1)` to claim the next request.
    cursor: AtomicUsize,
    /// Total fixture size; workers exit when `cursor >= total`.
    total_requests: usize,
    /// Warmup-phase ceiling; below this index the latency sample
    /// is discarded.
    warmup_requests: usize,
    /// `worker_count` snapshot.  Used by workers to size their
    /// local histogram pre-allocation (per-worker quota = ceil
    /// of `(total - warmup) / worker_count`).
    worker_count: usize,
    /// Pre-encoded payloads (4-byte length prefix + CBE bytes).
    /// `Arc`-shared snapshot of the fixture's framed wire bytes.
    framed_payloads: Arc<Vec<Vec<u8>>>,
    /// Submission start-of-measurement timestamp.  Captured by
    /// the first worker that begins a non-warmup request.  Used
    /// to compute throughput.
    ///
    /// The lock is gated by `measurement_started`: workers check
    /// the atomic boolean (Acquire) on every iteration; only the
    /// worker that observes `false` enters the critical section
    /// to write the timestamp.  Subsequent iterations see
    /// `true` and skip the lock entirely.  This is the textbook
    /// double-checked-locking pattern; the Release-Acquire pair
    /// guarantees the timestamp write is visible to every worker
    /// that observes `measurement_started == true`.
    measurement_start: Mutex<Option<Instant>>,
    /// Fast-path flag for `measurement_start`.  Set to `true` by
    /// the worker that first writes `measurement_start`; subsequent
    /// workers short-circuit without taking the lock.
    measurement_started: AtomicBool,
    /// Number of non-warmup requests successfully completed.
    measured_count: AtomicUsize,
    /// Abort flag.  Set by any worker that hits an error so others
    /// can short-circuit.
    abort: AtomicBool,
    /// First error observed (if any).  Carried out via the
    /// runner's return value.  Locked only on worker error
    /// (off the hot path).
    first_error: Mutex<Option<SubmissionError>>,
}

/// Per-worker return value: the local histogram plus the most-recent
/// successful-completion timestamp.  Aggregating these at join-time
/// (max of all `last_completion`s) yields the measurement-end
/// wallclock without per-request lock contention.
struct WorkerOutcome {
    histogram: Histogram,
    last_completion: Option<Instant>,
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
        worker_count: config.worker_count,
        framed_payloads,
        measurement_start: Mutex::new(None),
        measurement_started: AtomicBool::new(false),
        measured_count: AtomicUsize::new(0),
        abort: AtomicBool::new(false),
        first_error: Mutex::new(None),
    });

    // 2. Spawn workers.  Graceful handling on spawn failure
    //    (EAGAIN / ENOMEM under sustained load) matches the
    //    knomosis-host audit-pass-2 C-NEW-3 fix: surface the OS error
    //    as a typed `RunnerError::SpawnFailed` rather than panicking.
    let mut handles: Vec<JoinHandle<WorkerOutcome>> = Vec::with_capacity(config.worker_count);
    for worker_id in 0..config.worker_count {
        let shared_for_closure = Arc::clone(&shared);
        let endpoint = config.endpoint.clone();
        let timeout = config.request_timeout;
        match std::thread::Builder::new()
            .name(format!("knomosis-bench-worker-{worker_id}"))
            .spawn(move || worker_loop(&shared_for_closure, &endpoint, timeout))
        {
            Ok(handle) => handles.push(handle),
            Err(source) => {
                // Signal abort so already-spawned workers exit
                // promptly; then join them and discard their work.
                shared.abort.store(true, Ordering::Release);
                for handle in handles {
                    let _ = handle.join();
                }
                return Err(RunnerError::SpawnFailed {
                    worker_index: worker_id,
                    source,
                });
            }
        }
    }

    // 3. Join workers.  Each WorkerOutcome carries its local
    //    histogram + the worker's last successful-completion
    //    timestamp.  We merge histograms and take the max of
    //    per-worker last-completion timestamps as the
    //    measurement-end wallclock.  No per-request lock contention
    //    on the hot path.  Pre-allocate `merged` with the expected
    //    measurable-sample capacity (`total - warmup`) so the merge
    //    loop's `extend_from_slice` calls don't reallocate.
    let expected_samples = fixture.len().saturating_sub(config.warmup_requests);
    let mut merged = Histogram::with_capacity(expected_samples);
    let mut measurement_end: Option<Instant> = None;
    let mut any_panicked = false;
    for handle in handles {
        match handle.join() {
            Ok(outcome) => {
                merged.merge(&outcome.histogram);
                measurement_end = match (measurement_end, outcome.last_completion) {
                    (Some(a), Some(b)) => Some(a.max(b)),
                    (Some(a), None) => Some(a),
                    (None, Some(b)) => Some(b),
                    (None, None) => None,
                };
            }
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

    // 5. Compute the elapsed window.  `measurement_start` was
    //    captured when the first non-warmup request began;
    //    `measurement_end` is the max of all workers' last
    //    successful-completion timestamps.  If no measurement
    //    started (e.g., fixture exhausted by warmup), elapsed is
    //    zero.
    let start = *shared
        .measurement_start
        .lock()
        .unwrap_or_else(|p| p.into_inner());
    let elapsed = match (start, measurement_end) {
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
/// submits each over a fresh connection.  Returns a [`WorkerOutcome`]
/// carrying the per-worker histogram + the timestamp of this
/// worker's last successful non-warmup completion (used by `run` to
/// compute the global `measurement_end` via reduce-on-join, avoiding
/// per-request lock contention).
fn worker_loop(shared: &SharedRunState, endpoint: &Endpoint, timeout: Duration) -> WorkerOutcome {
    // Per-worker quota = ceil((total - warmup) / worker_count).  An
    // overestimate is cheaper than reallocations; an underestimate
    // is a no-op (Vec grows).
    let measurable = shared.total_requests.saturating_sub(shared.warmup_requests);
    let per_worker_cap = measurable
        .div_ceil(shared.worker_count.max(1))
        // Cap at a sane upper bound to avoid huge pre-allocations
        // on degenerate (worker_count == 1, total = millions) configs.
        // The Vec will grow if the cap is too small.
        .min(1 << 20);
    let mut local_hist = Histogram::with_capacity(per_worker_cap);
    let mut last_completion: Option<Instant> = None;

    loop {
        if shared.abort.load(Ordering::Acquire) {
            return WorkerOutcome {
                histogram: local_hist,
                last_completion,
            };
        }
        let idx = shared.cursor.fetch_add(1, Ordering::AcqRel);
        if idx >= shared.total_requests {
            return WorkerOutcome {
                histogram: local_hist,
                last_completion,
            };
        }
        let framed = &shared.framed_payloads[idx];
        let is_warmup = idx < shared.warmup_requests;

        // Capture the measurement-start timestamp on the first
        // non-warmup request claimed by any worker.  Fast path:
        // most iterations observe `measurement_started == true`
        // (Acquire-load) and skip the lock entirely.  Only the
        // first worker that observes `false` takes the lock to
        // write the timestamp + set the flag (Release-store).
        if !is_warmup && !shared.measurement_started.load(Ordering::Acquire) {
            let mut guard = shared
                .measurement_start
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            if guard.is_none() {
                *guard = Some(Instant::now());
                shared.measurement_started.store(true, Ordering::Release);
            }
            drop(guard);
        }

        let started = Instant::now();
        match submit_once(endpoint, framed, timeout) {
            Ok(()) => {
                if !is_warmup {
                    // Capture the completion instant ONCE and use it
                    // for both the per-request latency (`completion -
                    // started`) and the worker-local
                    // `last_completion` track.  Previously we called
                    // `Instant::now()` twice (once via
                    // `started.elapsed()`, once for the completion
                    // track); consolidating saves one syscall per
                    // measured request AND makes the two derived
                    // values consistent at the exact same wallclock
                    // instant.
                    let completion = Instant::now();
                    let elapsed = completion.duration_since(started);
                    local_hist.record(elapsed);
                    shared.measured_count.fetch_add(1, Ordering::AcqRel);
                    // Track this worker's last successful completion
                    // locally — no shared lock.  The runner's join
                    // path reduces these into a global max.
                    last_completion = Some(completion);
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
                return WorkerOutcome {
                    histogram: local_hist,
                    last_completion,
                };
            }
        }
    }
}

/// What `read_exact_with_eof` is reading; passed explicitly so the
/// truncation-error variant doesn't depend on a magic length check.
#[derive(Clone, Copy)]
enum ReadKind {
    /// The 5-byte response header (verdict byte + BE u32 reason
    /// length).
    Header,
    /// The UTF-8 reason payload.  Carries the declared length so
    /// the truncation error reports the original target.
    Reason { declared: usize },
}

/// Submit one pre-framed request and verify the response is Ok.
///
/// ## Hot-path discipline
///
/// On the happy path (`verdict_byte == 0`, the knomosis-host MockKernel's
/// always-Ok response), the function performs:
///   * One `connect()` + `set_timeout()` + `write_all()` + `flush()`
///     + `shutdown_write()` (the unavoidable I/O sequence).
///   * One 5-byte header read.
///   * Zero heap allocations after the connection's read-buffer
///     fill — no reason-payload allocation, no UTF-8 conversion,
///     no String construction.
///
/// The connection's pending reason bytes (if any) are NOT consumed
/// — the kernel discards them when we close the socket on function
/// return.  This is safe because the knomosis-host wire format is
/// one-shot per connection: no further requests / responses follow.
///
/// # Errors
///
/// See [`SubmissionError`].
fn submit_once(
    endpoint: &Endpoint,
    framed: &[u8],
    timeout: Duration,
) -> Result<(), SubmissionError> {
    let mut conn = endpoint.connect_with_timeout(DEFAULT_CONNECT_TIMEOUT)?;
    conn.set_timeout(timeout)?;
    conn.write_all(framed)?;
    conn.flush()?;
    // Half-close to signal end-of-request to knomosis-host.
    let _ = conn.shutdown_write();

    // Read the 5-byte response header.
    let mut header = [0u8; 5];
    read_exact_with_eof(&mut conn, &mut header, ReadKind::Header)?;
    let verdict_byte = header[0];
    let reason_len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;

    // Defensive cap on the declared reason length BEFORE allocating
    // the payload buffer.  Without this, a hostile / misbehaving
    // server could declare `reason_len = u32::MAX` (~4 GiB), causing
    // a client-side OOM on the `vec![0u8; reason_len]` allocation.
    // Checked BEFORE the verdict check so an Ok verdict with an
    // absurd declared length still surfaces as a typed error
    // (rather than being silently masked by the happy-path
    // short-circuit below).
    if reason_len > MAX_REASON_BYTES {
        return Err(SubmissionError::ResponseTooLarge {
            declared: reason_len,
            max: MAX_REASON_BYTES,
        });
    }

    // Happy-path fast exit: verdict==0 means the kernel admitted the
    // action; we don't need the reason text (it's diagnostic-only).
    // Skip the read + allocation entirely.  The kernel-side bytes
    // (if any) are discarded when the socket closes on function
    // return — knomosis-host's wire format is one-shot, so there's
    // no protocol concern.
    if verdict_byte == 0 {
        return Ok(());
    }

    // verdict != 0: read the reason payload + surface as a typed
    // error.  This path is off the hot loop (only triggered on
    // harness misconfiguration or kernel rejection).
    let mut reason_bytes = vec![0u8; reason_len];
    if reason_len > 0 {
        read_exact_with_eof(
            &mut conn,
            &mut reason_bytes,
            ReadKind::Reason {
                declared: reason_len,
            },
        )?;
    }
    let reason = String::from_utf8_lossy(&reason_bytes).into_owned();
    Err(SubmissionError::UnexpectedVerdict {
        verdict_byte,
        reason,
    })
}

/// Read exactly `buf.len()` bytes from `reader`, returning a typed
/// truncation error on EOF rather than the generic
/// `std::io::ErrorKind::UnexpectedEof`.  The `kind` parameter
/// disambiguates header-vs-reason truncation in the typed error.
fn read_exact_with_eof<R: Read>(
    reader: &mut R,
    buf: &mut [u8],
    kind: ReadKind,
) -> Result<(), SubmissionError> {
    let total_len = buf.len();
    let mut filled = 0;
    while filled < total_len {
        let n = reader.read(&mut buf[filled..])?;
        if n == 0 {
            return Err(match kind {
                ReadKind::Header => SubmissionError::TruncatedResponseHeader(filled),
                ReadKind::Reason { declared } => SubmissionError::TruncatedResponsePayload {
                    got: filled,
                    declared,
                },
            });
        }
        filled += n;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        read_exact_with_eof, Endpoint, ReadKind, RunOutcome, RunnerConfig, RunnerError,
        SubmissionError, DEFAULT_CONNECT_TIMEOUT, MAX_REASON_BYTES,
    };
    use crate::histogram::Histogram;
    use std::io::Cursor;
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

    /// `RunOutcome::throughput_ops_per_sec` returns 0.0 when elapsed
    /// is zero (e.g. degenerate run with no measured requests).
    #[test]
    fn throughput_zero_elapsed() {
        let outcome = RunOutcome {
            elapsed: Duration::ZERO,
            measured_requests: 0,
            histogram: Histogram::new(),
        };
        assert!((outcome.throughput_ops_per_sec() - 0.0).abs() < f64::EPSILON);
    }

    /// `RunOutcome::throughput_ops_per_sec` returns correct value
    /// for a typical (1 sec elapsed, 1000 reqs) case.
    #[test]
    fn throughput_typical() {
        let outcome = RunOutcome {
            elapsed: Duration::from_secs(1),
            measured_requests: 1000,
            histogram: Histogram::new(),
        };
        assert!((outcome.throughput_ops_per_sec() - 1000.0).abs() < 1e-6);
    }

    /// `RunOutcome::throughput_ops_per_sec` handles fractional
    /// elapsed times correctly.
    #[test]
    fn throughput_subsecond() {
        let outcome = RunOutcome {
            elapsed: Duration::from_millis(500),
            measured_requests: 1000,
            histogram: Histogram::new(),
        };
        // 1000 reqs in 0.5s = 2000 ops/sec.
        assert!((outcome.throughput_ops_per_sec() - 2000.0).abs() < 1e-6);
    }

    /// `read_exact_with_eof` happy path: returns Ok and fills the
    /// buffer.
    #[test]
    fn read_exact_with_eof_happy() {
        let data = [1u8, 2, 3, 4, 5];
        let mut reader = Cursor::new(data);
        let mut buf = [0u8; 5];
        read_exact_with_eof(&mut reader, &mut buf, ReadKind::Header).unwrap();
        assert_eq!(buf, data);
    }

    /// `read_exact_with_eof` on a truncated header (4 bytes when
    /// 5 expected) surfaces `TruncatedResponseHeader` carrying the
    /// observed-bytes count.
    #[test]
    fn read_exact_with_eof_truncated_header() {
        let data = [1u8, 2, 3, 4]; // 4 bytes only
        let mut reader = Cursor::new(data);
        let mut buf = [0u8; 5];
        let err = read_exact_with_eof(&mut reader, &mut buf, ReadKind::Header).unwrap_err();
        match err {
            SubmissionError::TruncatedResponseHeader(got) => assert_eq!(got, 4),
            other => panic!("expected TruncatedResponseHeader, got {other}"),
        }
    }

    /// `read_exact_with_eof` on a truncated reason payload surfaces
    /// `TruncatedResponsePayload` carrying both observed-bytes and
    /// declared-length.
    #[test]
    fn read_exact_with_eof_truncated_reason() {
        let data = [b'h', b'i']; // 2 bytes when 5 expected
        let mut reader = Cursor::new(data);
        let mut buf = [0u8; 5];
        let err = read_exact_with_eof(&mut reader, &mut buf, ReadKind::Reason { declared: 5 })
            .unwrap_err();
        match err {
            SubmissionError::TruncatedResponsePayload { got, declared } => {
                assert_eq!(got, 2);
                assert_eq!(declared, 5);
            }
            other => panic!("expected TruncatedResponsePayload, got {other}"),
        }
    }

    /// `read_exact_with_eof` with a zero-length buffer is a no-op
    /// (returns Ok immediately).
    #[test]
    fn read_exact_with_eof_zero_length() {
        let data = [0u8; 0];
        let mut reader = Cursor::new(data);
        let mut buf = [0u8; 0];
        read_exact_with_eof(&mut reader, &mut buf, ReadKind::Header).unwrap();
    }

    /// `RunnerError::SpawnFailed` has the documented Display format.
    /// We synthesise a fake io::Error since real spawn failures are
    /// hard to provoke deterministically.
    #[test]
    fn spawn_failed_display() {
        let err = RunnerError::SpawnFailed {
            worker_index: 7,
            source: std::io::Error::new(std::io::ErrorKind::WouldBlock, "EAGAIN"),
        };
        let display = format!("{err}");
        assert!(display.contains("failed to spawn worker thread 7"));
        assert!(display.contains("EAGAIN"));
    }

    /// `SubmissionError::UnexpectedVerdict` carries the verdict byte
    /// + reason in its Display format.
    #[test]
    fn unexpected_verdict_display() {
        let err = SubmissionError::UnexpectedVerdict {
            verdict_byte: 1,
            reason: "kernel rejected".to_string(),
        };
        let s = format!("{err}");
        assert!(s.contains("non-Ok verdict 1"));
        assert!(s.contains("kernel rejected"));
    }

    /// `read_exact_with_eof` handles a fragmented reader (split into
    /// multiple chunks) by accumulating until the buffer is full.
    /// We use a custom reader that yields one byte per `read` call.
    #[test]
    fn read_exact_with_eof_fragmented() {
        struct OneByteReader<'a> {
            data: &'a [u8],
            pos: usize,
        }
        impl std::io::Read for OneByteReader<'_> {
            fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
                if self.pos >= self.data.len() {
                    return Ok(0);
                }
                if buf.is_empty() {
                    return Ok(0);
                }
                buf[0] = self.data[self.pos];
                self.pos += 1;
                Ok(1)
            }
        }
        let mut reader = OneByteReader {
            data: &[1, 2, 3, 4, 5],
            pos: 0,
        };
        let mut buf = [0u8; 5];
        read_exact_with_eof(&mut reader, &mut buf, ReadKind::Header).unwrap();
        assert_eq!(buf, [1u8, 2, 3, 4, 5]);
    }

    /// `DEFAULT_CONNECT_TIMEOUT` is documented; pin to catch
    /// accidental drift.
    #[test]
    fn default_connect_timeout_pinned() {
        assert_eq!(DEFAULT_CONNECT_TIMEOUT, Duration::from_secs(5));
    }

    /// `MAX_REASON_BYTES` is documented; pin to catch accidental
    /// drift.  Mirrors the knomosis-host `MAX_SUBPROCESS_OUTPUT` cap
    /// (the largest legitimate reason `CommandKernel` will emit).
    #[test]
    fn max_reason_bytes_pinned() {
        assert_eq!(MAX_REASON_BYTES, 64 * 1024);
    }

    /// `SubmissionError::ResponseTooLarge` Display contains the
    /// declared length and the cap.
    #[test]
    fn response_too_large_display() {
        let err = SubmissionError::ResponseTooLarge {
            declared: 1_000_000_000,
            max: 64 * 1024,
        };
        let s = format!("{err}");
        assert!(s.contains("1000000000"));
        assert!(s.contains("65536"));
    }

    /// `Endpoint::connect_with_timeout` against a refused TCP
    /// address returns an error promptly (no hang).  Uses a port
    /// bound + dropped immediately so connect-time fails with
    /// ECONNREFUSED.
    #[test]
    fn connect_with_timeout_refuses_promptly() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);

        let endpoint = Endpoint::Tcp(addr);
        let started = std::time::Instant::now();
        let result = endpoint.connect_with_timeout(Duration::from_secs(30));
        let elapsed = started.elapsed();
        assert!(result.is_err(), "connect to closed port should fail");
        // ECONNREFUSED is immediate (sub-millisecond on Linux loopback);
        // we allow up to 1 second for slow CI runners but the 30-second
        // timeout MUST NOT fire.
        assert!(
            elapsed < Duration::from_secs(2),
            "connect failed in {elapsed:?}; expected sub-second ECONNREFUSED"
        );
    }

    /// `Endpoint::connect_with_timeout` honours the timeout.  We
    /// target `192.0.2.1` (TEST-NET-1 — guaranteed not to route)
    /// with a short timeout and assert the timeout fires.  This
    /// test is skipped if the system rejects the TEST-NET-1 route
    /// with an immediate error (e.g. some firewalls return
    /// ENETUNREACH instantly).
    #[test]
    fn connect_with_timeout_respects_timeout() {
        // TEST-NET-1: RFC 5737, reserved for documentation.  Should
        // not route anywhere; connect will hang until timeout.
        let addr: std::net::SocketAddr = "192.0.2.1:1".parse().unwrap();
        let endpoint = Endpoint::Tcp(addr);
        let timeout = Duration::from_millis(250);
        let started = std::time::Instant::now();
        let result = endpoint.connect_with_timeout(timeout);
        let elapsed = started.elapsed();
        assert!(result.is_err());
        // If the system immediately rejects the route (ENETUNREACH),
        // elapsed will be short; otherwise the timeout fires.  Either
        // way the call must NOT take much longer than the timeout.
        assert!(
            elapsed < timeout + Duration::from_secs(2),
            "connect took {elapsed:?}; expected <= {:?}",
            timeout + Duration::from_secs(2)
        );
    }
}

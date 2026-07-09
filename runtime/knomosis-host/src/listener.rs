// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Listener implementations for `knomosis-host`.
//!
//! Three listener variants share a common request/response cycle:
//!
//!   * [`tcp::TcpListener`] — plain TCP, suitable for local /
//!     trusted-network deployments.
//!   * [`tls::TlsListener`] — TCP + `rustls` termination.  Layer
//!     on top of TCP; requires a `TlsConfig` (`docs/abi.md` §10
//!     recommends TLS 1.3+).
//!   * [`unix::UnixListener`] — Unix domain socket, suitable for
//!     localhost-only deployments (the L1 ingestor co-located on
//!     the same host, for example).  Permission-protected at the
//!     filesystem layer (mode 0600).
//!
//! ## Connection lifecycle
//!
//! Each accepted connection runs in its own `std::thread`.  There are
//! two modes, selected by `--persistent-connections`:
//!
//! **One-shot (default).**  HTTP-style — simpler, and matches the plan's
//! §RH-C.3 "HTTP-style one-shot is also acceptable, simpler":
//!
//!   1. Read one wire frame via
//!      [`crate::frame::read_request_with_deadline`] (the whole read
//!      bounded by `connection_timeout` end-to-end — the slow-loris
//!      defence).
//!   2. Try to submit to the queue ([`crate::queue::QueueHandle`]).
//!   3. If the queue is full: respond `Busy` immediately, close.
//!   4. Otherwise: block on the reply channel (capacity 1).
//!   5. Write the response via [`crate::verdict::VerdictResponse::encode`].
//!   6. Close the connection.
//!
//! Under one-shot, every connection holds at most one in-flight request,
//! so two-tier DRR and FIFO coincide end-to-end regardless of scheduler
//! (`GP.8` §2.5 topology caveat).
//!
//! **Persistent + pipelined (`--persistent-connections`).**  A single
//! TCP / Unix connection may pipeline many in-flight requests — it does
//! NOT wait for each verdict before sending the next — so one flow can
//! hold multiple simultaneously-queued requests for the scheduler to
//! arbitrate.  This is the mode under which fair scheduling under
//! contention is actually exercised over the wire (see
//! [`run_persistent`]).  A dedicated writer thread delivers responses in
//! submission order (the §10.1 response framing is unchanged), and the
//! per-connection in-flight depth is bounded by `--max-conn-backlog`.
//! TLS connections always use the one-shot handler (the rustls session is
//! single-owner and cannot be split across reader/writer threads).

use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::frame::{read_request_with_deadline, ConnReader, FrameError};
use crate::kernel::KernelResponse;
use crate::queue::{ConnId, QueueHandle, SubmitOutcome};
use crate::verdict::{Verdict, VerdictResponse};

/// Default read / write timeout per connection — applied BOTH as the
/// socket's per-read/write timeout AND as the end-to-end per-request
/// frame-read deadline (see [`crate::frame::read_request_with_deadline`]).
///
/// The two limits compose: the socket timeout bounds each individual
/// read (an idle client is cut off within one window), while the
/// deadline bounds the request as a whole (a "slow-loris" client that
/// trickles one byte per window — resetting the socket timer forever —
/// is still cut off once the deadline passes).  10 seconds is generous
/// for a ≤ 1 MiB frame on any realistic link; operators with larger
/// frames or slower links tune `--connection-timeout`.
pub const DEFAULT_CONNECTION_TIMEOUT: Duration = Duration::from_secs(10);

/// Hard ceiling on `--connection-timeout`.  The per-request read deadline is
/// `Instant::now() + connection_timeout` (here and in the TLS `DeadlineStream`);
/// an unbounded operator value could overflow that `Instant` and **panic** the
/// handler thread on the first connection.  A full day is already pathological
/// for a single request, so cap far below any overflow.
pub const MAX_CONNECTION_TIMEOUT: Duration = Duration::from_secs(86_400);

/// Maximum time the connection handler will block waiting for the
/// kernel's reply.  Bounded so a wedged kernel doesn't hold
/// connection threads indefinitely.
pub const DEFAULT_KERNEL_REPLY_TIMEOUT: Duration = Duration::from_secs(60);

/// Default cap on the number of simultaneously-active connection
/// handler threads (across all listeners).  Defends against the
/// spawn-storm DoS where an attacker opens N TCP connections in
/// parallel to exhaust the host's thread / FD budget.  When the
/// limit is hit, the listener writes a `Busy` verdict to the
/// new connection and closes immediately rather than spawning
/// another thread.
///
/// Default sized to 4× the default queue depth (`256`) so a
/// healthy worker can keep up under load.  Operators tune via
/// `--max-concurrent-connections`.
pub const DEFAULT_MAX_CONCURRENT_CONNECTIONS: usize = 1024;

/// Hard ceiling on operator-configurable concurrent connections.
/// Above this the operator is doing something unusual — at 1 MiB
/// frame size, 65 536 simultaneous handlers could hold up to
/// 64 GiB of resident buffers.
pub const HARD_MAX_CONCURRENT_CONNECTIONS: usize = 65_536;

/// Shared connection-handler parameters.  Each connection thread
/// reads frames according to these limits and dispatches via the
/// shared `BoundedQueue`.
#[derive(Clone, Debug)]
pub struct HandlerConfig {
    /// Maximum frame size accepted from the client.  Forwarded to
    /// [`crate::frame::read_frame`].
    pub max_frame_size: usize,
    /// Read / write timeout for the underlying socket, ALSO used as
    /// the end-to-end per-request frame-read deadline (the slow-loris
    /// bound; see [`DEFAULT_CONNECTION_TIMEOUT`]).
    pub connection_timeout: Duration,
    /// Maximum time to wait for the kernel's reply before
    /// responding `NotAdmissible` with a "timeout" reason.
    pub kernel_reply_timeout: Duration,
    /// Maximum simultaneously-active connection handler threads.
    /// New connections beyond this limit receive `Busy` and the
    /// socket is closed immediately.
    pub max_concurrent_connections: usize,
    /// Whether to run TCP / Unix connections in persistent + pipelined
    /// mode (`--persistent-connections`).  When `false` (the default)
    /// every connection is one-shot (one frame → one verdict → close),
    /// byte-for-byte the historical behaviour.  When `true`, a TCP / Unix
    /// connection may pipeline many in-flight requests and receives one
    /// verdict per request in submission order ([`run_persistent`]); this
    /// is what makes two-tier DRR diverge from FIFO over the wire.  TLS
    /// connections are always one-shot regardless of this flag.
    pub persistent_connections: bool,
}

impl Default for HandlerConfig {
    fn default() -> Self {
        Self {
            max_frame_size: crate::frame::DEFAULT_MAX_FRAME_SIZE,
            connection_timeout: DEFAULT_CONNECTION_TIMEOUT,
            kernel_reply_timeout: DEFAULT_KERNEL_REPLY_TIMEOUT,
            max_concurrent_connections: DEFAULT_MAX_CONCURRENT_CONNECTIONS,
            persistent_connections: false,
        }
    }
}

/// A counted slot in the connection limiter.  Increments the
/// shared atomic counter on construction; decrements on drop.
/// Used as a RAII guard around the per-connection handler
/// thread so a panic anywhere in the handler still releases the
/// slot.
pub struct ConnectionSlot {
    counter: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

impl ConnectionSlot {
    /// Try to acquire a slot.  Returns `Some(slot)` on success or
    /// `None` if the active count already hit the cap.  This is
    /// the load-bearing DoS defence: when full, the listener
    /// responds `Busy` immediately without spawning a thread.
    ///
    /// `cap` is internally clamped to [`HARD_MAX_CONCURRENT_CONNECTIONS`]
    /// (defence-in-depth against library consumers constructing a
    /// `HandlerConfig` with `max_concurrent_connections = usize::MAX`,
    /// which would disable the protection entirely).  CLI-supplied
    /// values reach this function pre-clamped via `Config::validate`.
    ///
    /// Uses an atomic CAS so concurrent attempts on multiple
    /// listener threads stay coherent.
    pub fn try_acquire(
        counter: &std::sync::Arc<std::sync::atomic::AtomicUsize>,
        cap: usize,
    ) -> Option<Self> {
        use std::sync::atomic::Ordering;
        // Defence-in-depth clamp.  Parallel to `frame::read_frame`'s
        // `HARD_MAX_FRAME_SIZE` clamp.  Library consumers that
        // construct `HandlerConfig` directly cannot bypass.
        let cap = cap.min(HARD_MAX_CONCURRENT_CONNECTIONS);
        let mut current = counter.load(Ordering::Relaxed);
        loop {
            if current >= cap {
                return None;
            }
            match counter.compare_exchange_weak(
                current,
                current + 1,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Ok(_) => {
                    return Some(Self {
                        counter: std::sync::Arc::clone(counter),
                    })
                }
                Err(observed) => current = observed,
            }
        }
    }

    /// Active count snapshot.  Diagnostic only.
    pub fn active_count(counter: &std::sync::Arc<std::sync::atomic::AtomicUsize>) -> usize {
        counter.load(std::sync::atomic::Ordering::Relaxed)
    }
}

impl Drop for ConnectionSlot {
    fn drop(&mut self) {
        // Release the slot.  Use `Release` ordering so the slot's
        // associated state (the connection handler's work) is
        // ordered-before the decrement, matching the `Acquire` at
        // try_acquire.
        self.counter
            .fetch_sub(1, std::sync::atomic::Ordering::Release);
    }
}

/// Exponential backoff for persistent accept errors (e.g. EMFILE
/// / file-descriptor exhaustion).  Defends against the
/// busy-spin DoS where a listener thread retries `accept` at
/// 10× per second on a permanent error.
///
/// Sleep durations: 100 ms × 2^min(errors, 5), capped at 3.2 s.
/// Returns once the sleep completes; the caller's next iteration
/// will re-check the stop flag.
fn backoff_on_accept_error(consecutive_errors: u32) {
    let exp = consecutive_errors.saturating_sub(1).min(5);
    let ms = 100u64 << exp;
    std::thread::sleep(Duration::from_millis(ms));
}

/// Outcome of one [`handle_connection`] invocation.
///
/// Distinguishes between the operator-observable cases so the
/// per-listener wrappers can log accurately.  The wire-format
/// `Verdict` enum is bound to the response byte (`0..=3`); this
/// enum is broader because there are connection-level outcomes
/// that don't correspond to any single verdict byte (e.g. the
/// client closing cleanly before sending a frame).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HandleOutcome {
    /// A request was processed and the supplied verdict written
    /// to the client.
    Responded(Verdict),
    /// The client closed the connection cleanly before sending
    /// a request frame.  No response was owed.  This is the
    /// normal "client went away" case; not an error.
    ClientClosedBeforeRequest,
    /// A persistent connection closed after serving `served` requests
    /// (the pipelined `--persistent-connections` path).  `served` counts
    /// every frame the reader accepted (including ones answered `Busy`).
    PersistentClosed {
        /// Number of request frames served on this connection.
        served: u64,
    },
}

impl HandleOutcome {
    /// Human-readable name for log spans.  Stable; do not change
    /// without a `tracing` consumer update.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Responded(v) => v.name(),
            Self::ClientClosedBeforeRequest => "client_closed_before_request",
            Self::PersistentClosed { .. } => "persistent_closed",
        }
    }
}

/// Run a single request/response cycle on an established
/// readable+writable stream.
///
/// Returns the outcome (verdict written, or client closed cleanly)
/// so the caller can log accurately.  The function closes the
/// response cycle on its own; the caller is responsible for
/// closing the stream after this function returns.
///
/// Used by all three listener variants (TCP, TLS, Unix) — the
/// stream abstraction is `impl Read + Write` so each variant can
/// pass its native socket type.
///
/// `conn_id` is the connection's monotonic [`ConnId`] (FQ.3).  It is
/// forwarded to [`QueueHandle::submit`] as the *outer* DRR routing key,
/// alongside the per-frame advisory signer hint (Rung 1) — or
/// [`crate::queue::LEGACY_SIGNER_HINT`] for a legacy / un-hinted frame.
/// The FIFO arm ignores both, so the FIFO path is byte-for-byte
/// unchanged for legacy clients.  Both routing values are
/// *classification* hints only and never affect admissibility (`GP.8`
/// §2.6 invariants 1 & 2).
///
/// The Rung-1 negotiation ([`read_request_with_deadline`]) is performed
/// on EVERY path (FIFO and DRR), because it is a wire-format concern,
/// not a scheduler one: a v2 client's preamble + per-frame hint are
/// stripped and the opaque payload submitted regardless of scheduler,
/// so v2 clients interoperate with a FIFO host (gaining no fairness,
/// but working).
pub fn handle_connection<S: Read + Write>(
    stream: &mut S,
    handle: &QueueHandle,
    config: &HandlerConfig,
    conn_id: ConnId,
) -> HandleOutcome {
    // 1. Negotiate (one-time Rung-1 magic peek) + read the request frame
    //    and its advisory signer hint.  A legacy connection yields
    //    `LEGACY_SIGNER_HINT`; its payload bytes are byte-identical to a
    //    plain v1 `read_frame`, so the FIFO path is unchanged for it.
    //    The whole read is bounded by an ABSOLUTE deadline — the
    //    slow-loris defence: the socket's per-read timeout resets on
    //    every delivered byte, so a trickling client would otherwise
    //    hold this handler slot indefinitely.
    let read_deadline = Instant::now() + config.connection_timeout;
    let (signer_hint, payload) =
        match read_request_with_deadline(stream, config.max_frame_size, read_deadline) {
            Ok(p) => p,
            Err(FrameError::EofBeforeHeader) => {
                // Clean close before a frame arrived.  No response
                // owed; just bail.
                tracing::debug!("client closed before sending frame");
                return HandleOutcome::ClientClosedBeforeRequest;
            }
            Err(e) => {
                // Any other frame error → respond `ParseError` if we
                // can.  Failure to write the response is logged at
                // debug; the connection will close anyway.
                tracing::debug!(error = ?e, "frame read failure");
                let response =
                    VerdictResponse::with_reason(Verdict::ParseError, format!("frame read: {e}"));
                let _ = stream.write_all(&response.encode());
                let _ = stream.flush();
                return HandleOutcome::Responded(Verdict::ParseError);
            }
        };

    // 2. Try to submit through the scheduler-agnostic queue handle.
    //    The (connection id, signer hint) pair is the two-tier DRR
    //    routing key (both ignored by FIFO).
    let reply_rx = match handle.submit(conn_id, signer_hint, payload) {
        SubmitOutcome::Enqueued(rx) => rx,
        SubmitOutcome::Busy => {
            // Queue full → respond Busy.
            tracing::debug!("queue full; responding busy");
            let response = VerdictResponse::from_verdict(Verdict::Busy);
            let _ = stream.write_all(&response.encode());
            let _ = stream.flush();
            return HandleOutcome::Responded(Verdict::Busy);
        }
    };

    // 3. Block on the kernel reply (bounded by
    //    `kernel_reply_timeout`).
    let response = match reply_rx.recv_timeout(config.kernel_reply_timeout) {
        Ok(r) => r,
        Err(_) => {
            // Timeout or disconnected.  Either way: tell the
            // client the kernel didn't respond.  We use
            // NotAdmissible rather than a new "kernel timeout"
            // verdict because the wire-format is fixed at
            // RH-C.1; adding a new verdict requires a protocol
            // bump.
            tracing::warn!("kernel did not reply within deadline");
            VerdictResponse::with_reason(Verdict::NotAdmissible, "kernel timeout")
        }
    };

    // 4. Write the response.  Errors are logged but otherwise
    //    swallowed — the client may have disconnected.
    let verdict = response.verdict;
    let bytes = response.encode();
    if let Err(e) = stream.write_all(&bytes) {
        tracing::debug!(error = ?e, "failed to write response");
        return HandleOutcome::Responded(verdict);
    }
    if let Err(e) = stream.flush() {
        tracing::debug!(error = ?e, "failed to flush response");
    }
    HandleOutcome::Responded(verdict)
}

/// A response awaiting delivery on a persistent connection, queued in
/// strict submission order so the client reads one verdict per request
/// in the order it sent them (the §10.1 response framing is unchanged).
enum PendingResponse {
    /// The request was enqueued for the worker; await its verdict on this
    /// one-shot reply channel.
    Enqueued(Receiver<KernelResponse>),
    /// The request was rejected before the worker (queue `Busy`, or a
    /// fatal frame error); the verdict is already known.
    Immediate(VerdictResponse),
}

/// Run the persistent, **pipelined** request/response cycle over the
/// split read/write halves of one connection (TCP / Unix).
///
/// This is the mode under which two-tier DRR actually diverges from FIFO
/// *over the wire*.  A single connection may pipeline many in-flight
/// requests — it does NOT wait for each verdict before sending the next —
/// so one flow can hold multiple simultaneously-queued requests for the
/// scheduler to arbitrate.  Under the one-shot [`handle_connection`] every
/// connection has at most one queued request, so DRR and FIFO coincide
/// regardless of scheduler (`GP.8` §2.5 topology caveat); persistent +
/// pipelined is what makes the fairness mechanism live in production.
///
/// ## Concurrency (one extra thread per connection)
///
///   * The **reader** (this thread) loops [`ConnReader::read_next`] —
///     wiring the persistent path of the Rung-1 read-state machine
///     (negotiate once, then read frames per the fixed v1/v2
///     classification) — submitting each frame to the queue and pushing
///     the resulting [`PendingResponse`] onto an ordered channel.
///   * The **writer** ([`persistent_writer_loop`], a spawned thread)
///     drains that channel in order, resolving each pending verdict and
///     writing it to the client.  Responses are therefore delivered in
///     submission order even though the worker may DISPATCH them out of
///     order (the fairness reordering is invisible to the client, but the
///     cross-connection latency benefit — an honest connection not stuck
///     behind a flooder — is real).
///
/// ## Back-pressure (bounded memory)
///
/// The reader→writer hand-off is a BOUNDED `sync_channel` sized to the
/// queue's per-connection in-flight bound ([`QueueHandle::pipeline_capacity`]
/// — `max_conn_backlog` on the DRR path, the global queue depth on the
/// FIFO path).  When it fills, the reader BLOCKS on `send`, so it stops
/// reading frames; the OS receive buffer then fills and TCP flow control
/// stops the client from sending more.  This is the load-bearing memory
/// bound: without it, a client that pipelines frames but never reads its
/// responses would make the writer block on `write_all` (its recv buffer
/// full) while the reader kept pushing `PendingResponse`s, growing the
/// channel without bound (an OOM DoS).  The bounded channel converts that
/// into back-pressure instead.
///
/// ## Termination
///
///   * A clean inter-frame close (`EofBeforeHeader`) or an idle / slow
///     read timeout ends the read loop gracefully: the reader drops its
///     sender, the writer drains the already-queued responses in order,
///     then both exit.  A well-behaved pipelining client half-closes its
///     write side after its last frame, so the reader sees an immediate
///     EOF rather than waiting out the read timeout.  A slow-TRICKLE
///     client (whose every read makes progress, so the socket timeout
///     never fires) is instead cut off by the per-request end-to-end
///     deadline (`FrameError::DeadlineExceeded`) — a protocol error
///     answered with one final `ParseError` below, not a clean close.
///   * A fatal framing error writes one final `ParseError` (in order) and
///     ends the connection — the byte stream cannot be resynchronised.
///   * `stop` (graceful server shutdown) and a writer-side I/O error (the
///     shared `dead` flag) both end the read loop within one read timeout.
fn run_persistent<R, W>(
    mut read_half: R,
    write_half: W,
    handle: &QueueHandle,
    config: &HandlerConfig,
    conn_id: ConnId,
    stop: &Arc<AtomicBool>,
) -> HandleOutcome
where
    R: Read,
    W: Write + Send + 'static,
{
    // Ordered hand-off reader → writer, BOUNDED to the queue's
    // per-connection in-flight capacity.  This is the memory bound: when
    // the channel fills (a client that stops reading its responses, so
    // the writer blocks on `write_all`), the reader BLOCKS on `send` and
    // therefore stops reading frames — OS receive-buffer fill + TCP flow
    // control then bound total memory.  An unbounded channel here would
    // be an OOM DoS (the reader would keep pushing while the writer
    // stalled).  `.max(1)` avoids a degenerate rendezvous channel.
    let buffer = handle.pipeline_capacity().max(1);
    let (resp_tx, resp_rx) = std::sync::mpsc::sync_channel::<PendingResponse>(buffer);
    let kernel_reply_timeout = config.kernel_reply_timeout;
    // Shared "connection is dead" flag so a writer-side I/O error stops
    // the reader promptly (it stops submitting otherwise-discarded work).
    let dead = Arc::new(AtomicBool::new(false));
    let writer_dead = Arc::clone(&dead);
    let writer = std::thread::Builder::new()
        .name("knomosis-host-persist-writer".into())
        .spawn(move || {
            persistent_writer_loop(write_half, resp_rx, kernel_reply_timeout, &writer_dead);
        })
        .expect("spawn persistent writer thread");

    let mut reader = ConnReader::new();
    let mut served: u64 = 0;
    loop {
        if stop.load(Ordering::Relaxed) || dead.load(Ordering::Relaxed) {
            break;
        }
        // A FRESH end-to-end deadline per request: the connection may
        // live indefinitely across many pipelined frames, but each
        // individual frame's read is wall-clock-bounded (the
        // slow-loris defence — a trickling client resets the socket's
        // per-read timeout forever, this deadline it cannot reset).
        // An idle client still ends via the socket timeout below
        // (`WouldBlock`/`TimedOut` → graceful close): the deadline
        // only fires when reads keep making progress too slowly, which
        // is a protocol error (`ParseError`), not a clean close.
        let read_deadline = Instant::now() + config.connection_timeout;
        match reader.read_next_with_deadline(&mut read_half, config.max_frame_size, read_deadline) {
            Ok((signer_hint, payload)) => {
                let pending = match handle.submit(conn_id, signer_hint, payload) {
                    SubmitOutcome::Enqueued(rx) => PendingResponse::Enqueued(rx),
                    SubmitOutcome::Busy => {
                        PendingResponse::Immediate(VerdictResponse::from_verdict(Verdict::Busy))
                    }
                };
                if resp_tx.send(pending).is_err() {
                    break; // writer gone (it errored and returned)
                }
                served = served.saturating_add(1);
            }
            // Clean inter-frame close: the client is done sending.
            Err(FrameError::EofBeforeHeader) => break,
            // Idle / slow read timeout at a frame boundary (or mid-frame
            // for a stalled client): treat as end-of-requests.  A
            // well-behaved pipelining client half-closes after its last
            // frame and hits `EofBeforeHeader` first; this only bounds an
            // idle or slow-loris connection (and lets `stop` be observed).
            Err(FrameError::Io(ref e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                break;
            }
            // Fatal framing error: emit one final `ParseError` in order,
            // then stop (the byte stream cannot be resynchronised).
            Err(e) => {
                tracing::debug!(error = ?e, "persistent frame read failure");
                let resp =
                    VerdictResponse::with_reason(Verdict::ParseError, format!("frame read: {e}"));
                let _ = resp_tx.send(PendingResponse::Immediate(resp));
                break;
            }
        }
    }
    // Signal the writer that no more responses are coming; it drains the
    // remaining queued responses in order, then exits.
    drop(resp_tx);
    let _ = writer.join();
    tracing::debug!(served, "persistent connection closed");
    HandleOutcome::PersistentClosed { served }
}

/// The writer half of [`run_persistent`]: drain `resp_rx` in order,
/// resolving each pending verdict (blocking up to `kernel_reply_timeout`
/// on an enqueued request's reply channel) and writing it to the client.
///
/// On any write error the client is gone: set the shared `dead` flag (so
/// the reader stops) and return, abandoning the remaining responses.
fn persistent_writer_loop<W: Write>(
    mut write_half: W,
    resp_rx: Receiver<PendingResponse>,
    kernel_reply_timeout: Duration,
    dead: &AtomicBool,
) {
    while let Ok(pending) = resp_rx.recv() {
        let response = match pending {
            PendingResponse::Enqueued(rx) => match rx.recv_timeout(kernel_reply_timeout) {
                Ok(r) => r,
                Err(_) => {
                    // Kernel didn't reply in time (or the worker dropped
                    // the sender).  Mirror the one-shot handler's choice:
                    // a `NotAdmissible` with a timeout reason (the wire
                    // verdict set is fixed; no "kernel timeout" byte).
                    VerdictResponse::with_reason(Verdict::NotAdmissible, "kernel timeout")
                }
            },
            PendingResponse::Immediate(v) => v,
        };
        let bytes = response.encode();
        if write_half.write_all(&bytes).is_err() || write_half.flush().is_err() {
            // Client gone: stop the reader and abandon the rest.
            dead.store(true, Ordering::Relaxed);
            return;
        }
    }
}

/// Plain TCP listener.
pub mod tcp {
    use std::io::Write;
    use std::net::{TcpListener as StdTcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;

    use crate::queue::{ConnId, QueueHandle};
    use crate::verdict::{Verdict, VerdictResponse};

    use super::{backoff_on_accept_error, handle_connection, ConnectionSlot, HandlerConfig};

    /// A plain TCP listener.
    ///
    /// `accept_loop` blocks until `stop` flips to true, accepting
    /// connections and spawning a handler thread per connection
    /// up to the configured `max_concurrent_connections`.
    #[derive(Debug)]
    pub struct TcpListener {
        inner: StdTcpListener,
    }

    impl TcpListener {
        /// Bind to `addr` and prepare to accept connections.
        ///
        /// # Errors
        ///
        /// Surfaces `std::io::Error` from the OS bind.
        pub fn bind(addr: std::net::SocketAddr) -> std::io::Result<Self> {
            let inner = StdTcpListener::bind(addr)?;
            inner.set_nonblocking(true)?;
            Ok(Self { inner })
        }

        /// The local address the listener is bound to.  After
        /// binding to `:0`, this reflects the OS-assigned port.
        pub fn local_addr(&self) -> std::io::Result<std::net::SocketAddr> {
            self.inner.local_addr()
        }

        /// Run the accept loop.  Blocks the calling thread until
        /// `stop` is set.  Each accepted connection runs
        /// [`super::handle_connection`] on its own thread, gated by
        /// the shared `connection_counter` against
        /// `config.max_concurrent_connections`.
        ///
        /// `conn_seq` is the process-wide monotonic [`ConnId`] source
        /// (FQ.3): each accepted connection takes the next id and
        /// threads it to the submit call (the DRR routing key).
        pub fn accept_loop(
            &self,
            handle: QueueHandle,
            config: HandlerConfig,
            stop: Arc<AtomicBool>,
            connection_counter: Arc<AtomicUsize>,
            conn_seq: Arc<AtomicU64>,
        ) {
            let mut consecutive_errors = 0u32;
            while !stop.load(Ordering::Relaxed) {
                match self.inner.accept() {
                    Ok((stream, peer)) => {
                        consecutive_errors = 0;
                        // Try to acquire a connection slot.  If the
                        // limit is hit, respond Busy and close
                        // immediately rather than spawning.
                        match ConnectionSlot::try_acquire(
                            &connection_counter,
                            config.max_concurrent_connections,
                        ) {
                            Some(slot) => {
                                let conn_id = crate::queue::assign_conn_id(&conn_seq);
                                let handle = handle.clone();
                                let config = config.clone();
                                let conn_stop = Arc::clone(&stop);
                                thread::spawn(move || {
                                    handle_single_connection(
                                        stream, peer, handle, config, slot, conn_id, conn_stop,
                                    );
                                });
                            }
                            None => {
                                // Spawn a tiny inline writer so we
                                // don't block the accept loop on
                                // the slow client.  Acceptable: the
                                // write is a fixed 5-byte response.
                                tracing::warn!(
                                    peer = %peer,
                                    "max_concurrent_connections reached; responding Busy"
                                );
                                let mut stream = stream;
                                let _ = stream.set_write_timeout(Some(config.connection_timeout));
                                let bytes = VerdictResponse::from_verdict(Verdict::Busy).encode();
                                let _ = stream.write_all(&bytes);
                                let _ = stream.flush();
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        consecutive_errors = 0;
                        // No connection ready; sleep briefly and re-check stop.
                        thread::sleep(std::time::Duration::from_millis(50));
                    }
                    Err(e) => {
                        consecutive_errors = consecutive_errors.saturating_add(1);
                        tracing::warn!(
                            error = ?e,
                            consecutive_errors,
                            "TCP accept failed"
                        );
                        backoff_on_accept_error(consecutive_errors);
                    }
                }
            }
        }
    }

    fn handle_single_connection(
        mut stream: TcpStream,
        peer: std::net::SocketAddr,
        handle: QueueHandle,
        config: HandlerConfig,
        _slot: ConnectionSlot,
        conn_id: ConnId,
        stop: Arc<AtomicBool>,
    ) {
        // _slot is held for the lifetime of this function; the
        // RAII Drop releases the connection-counter slot when
        // the handler exits, regardless of panic / early return.
        let _ = stream.set_read_timeout(Some(config.connection_timeout));
        let _ = stream.set_write_timeout(Some(config.connection_timeout));
        let span = tracing::info_span!("conn", proto = "tcp", peer = %peer, conn = conn_id);
        let _enter = span.enter();
        let outcome = if config.persistent_connections {
            // Persistent + pipelined: split into independent read / write
            // halves (a second handle to the same socket; concurrent read
            // on one + write on the other is safe for TCP), then run the
            // pipelined reader/writer cycle.  On a `try_clone` failure fall
            // back to the one-shot path (correct, just not pipelined).
            match stream.try_clone() {
                Ok(write_half) => {
                    let _ = write_half.set_write_timeout(Some(config.connection_timeout));
                    super::run_persistent(stream, write_half, &handle, &config, conn_id, &stop)
                }
                Err(e) => {
                    tracing::warn!(error = ?e, "try_clone failed; one-shot fallback");
                    handle_connection(&mut stream, &handle, &config, conn_id)
                }
            }
        } else {
            handle_connection(&mut stream, &handle, &config, conn_id)
        };
        tracing::info!(outcome = outcome.name(), "connection handled");
    }
}

/// TLS-on-TCP listener.  Layered on top of [`tcp::TcpListener`]
/// with `rustls` termination.
pub mod tls {
    use std::io::{Read, Write};
    use std::net::{TcpListener as StdTcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    use rustls::{ServerConfig, ServerConnection, StreamOwned};

    use crate::queue::{ConnId, QueueHandle};

    use super::{backoff_on_accept_error, handle_connection, ConnectionSlot, HandlerConfig};

    /// A TLS-on-TCP listener.
    #[derive(Debug)]
    pub struct TlsListener {
        inner: StdTcpListener,
        tls_config: Arc<ServerConfig>,
    }

    impl TlsListener {
        /// Bind to `addr` with the supplied TLS server config.
        ///
        /// # Errors
        ///
        /// Surfaces `std::io::Error` from the OS bind.
        pub fn bind(
            addr: std::net::SocketAddr,
            tls_config: Arc<ServerConfig>,
        ) -> std::io::Result<Self> {
            let inner = StdTcpListener::bind(addr)?;
            inner.set_nonblocking(true)?;
            Ok(Self { inner, tls_config })
        }

        /// The local address the listener is bound to.
        pub fn local_addr(&self) -> std::io::Result<std::net::SocketAddr> {
            self.inner.local_addr()
        }

        /// Run the accept loop.  Blocks the calling thread until
        /// `stop` is set.
        ///
        /// `conn_seq` is the process-wide monotonic [`ConnId`] source
        /// (FQ.3), shared across all listeners.
        pub fn accept_loop(
            &self,
            handle: QueueHandle,
            config: HandlerConfig,
            stop: Arc<AtomicBool>,
            connection_counter: Arc<AtomicUsize>,
            conn_seq: Arc<AtomicU64>,
        ) {
            let mut consecutive_errors = 0u32;
            while !stop.load(Ordering::Relaxed) {
                match self.inner.accept() {
                    Ok((stream, peer)) => {
                        consecutive_errors = 0;
                        match ConnectionSlot::try_acquire(
                            &connection_counter,
                            config.max_concurrent_connections,
                        ) {
                            Some(slot) => {
                                let conn_id = crate::queue::assign_conn_id(&conn_seq);
                                let handle = handle.clone();
                                let config = config.clone();
                                let tls_config = Arc::clone(&self.tls_config);
                                thread::spawn(move || {
                                    handle_tls_connection(
                                        stream, peer, handle, config, tls_config, slot, conn_id,
                                    );
                                });
                            }
                            None => {
                                tracing::warn!(
                                    peer = %peer,
                                    "TLS: max_concurrent_connections reached; closing without TLS \
                                     handshake"
                                );
                                // Writing the plaintext Busy
                                // verdict to a TLS-expecting client
                                // is not meaningful (they'd parse
                                // it as TLS bytes); close the
                                // connection without writing
                                // anything.  Clients see this as
                                // an immediate close + retry-with-
                                // backoff at the TLS layer.
                                let _ = stream.shutdown(std::net::Shutdown::Both);
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        consecutive_errors = 0;
                        thread::sleep(std::time::Duration::from_millis(50));
                    }
                    Err(e) => {
                        consecutive_errors = consecutive_errors.saturating_add(1);
                        tracing::warn!(error = ?e, consecutive_errors, "TLS accept failed");
                        backoff_on_accept_error(consecutive_errors);
                    }
                }
            }
        }
    }

    /// A `Read + Write` adapter that bounds every underlying socket **read**
    /// by an absolute deadline, interposed UNDER `rustls` (it wraps the raw
    /// `TcpStream`, not the `StreamOwned`) so the TLS handshake + record I/O —
    /// the many raw socket reads a single `StreamOwned::read` performs — is
    /// bounded.  Before each read the socket read timeout is shrunk to the
    /// remaining budget, so the cumulative handshake + read time cannot exceed
    /// the deadline (not `deadline + one socket timeout`).
    ///
    /// This closes the slow-loris TLS sub-case the frame-read deadline
    /// [`handle_connection`] applies OVER `rustls` cannot catch: that deadline
    /// is only checked *between* `StreamOwned::read` calls, so a peer trickling
    /// handshake / record bytes inside one `read` evades it.  Writes pass
    /// through, bounded by the socket write timeout the caller sets (a stalled
    /// handshake write is a far weaker lever than a stalled read, and this
    /// one-shot path writes only a tiny verdict response).
    struct DeadlineStream {
        inner: TcpStream,
        deadline: Instant,
        per_read_cap: Duration,
    }

    impl DeadlineStream {
        /// Wrap `inner` with an absolute `deadline`; each read is additionally
        /// capped to `per_read_cap` (the per-read backstop, never widened).
        fn new(inner: TcpStream, deadline: Instant, per_read_cap: Duration) -> Self {
            Self {
                inner,
                deadline,
                per_read_cap,
            }
        }
    }

    impl Read for DeadlineStream {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            // Remaining budget; `None` (deadline in the past) or zero ⇒ expired.
            match self.deadline.checked_duration_since(Instant::now()) {
                Some(remaining) if !remaining.is_zero() => {
                    // Cap this read to the remaining budget so it cannot
                    // overshoot the deadline; clamp to the per-read backstop
                    // (never widen it) and a >= 1ms floor (`Duration::ZERO`
                    // reads as "block forever" to the OS, and `set_read_timeout`
                    // rejects a zero value).
                    let cap = remaining
                        .min(self.per_read_cap)
                        .max(Duration::from_millis(1));
                    let _ = self.inner.set_read_timeout(Some(cap));
                    self.inner.read(buf)
                }
                _ => Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "TLS connection read deadline exceeded",
                )),
            }
        }
    }

    impl Write for DeadlineStream {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.inner.write(buf)
        }
        fn flush(&mut self) -> std::io::Result<()> {
            self.inner.flush()
        }
    }

    fn handle_tls_connection(
        stream: TcpStream,
        peer: std::net::SocketAddr,
        handle: QueueHandle,
        config: HandlerConfig,
        tls_config: Arc<ServerConfig>,
        _slot: ConnectionSlot,
        conn_id: ConnId,
    ) {
        // _slot RAII releases the connection-counter slot.
        let _ = stream.set_read_timeout(Some(config.connection_timeout));
        let _ = stream.set_write_timeout(Some(config.connection_timeout));
        // Required to switch the socket back to blocking mode for
        // the synchronous `rustls::StreamOwned` adapter.
        let _ = stream.set_nonblocking(false);
        let span = tracing::info_span!("conn", proto = "tls", peer = %peer, conn = conn_id);
        let _enter = span.enter();
        // Build the TLS connection.  ServerConnection::new only
        // fails on `rustls` mis-configuration (impossible if the
        // ServerConfig was built via TlsConfigBuilder).
        let connection = match ServerConnection::new(tls_config) {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!(error = ?e, "TLS connection setup failed");
                return;
            }
        };
        // Interpose the absolute deadline UNDER rustls (wrapping the raw
        // socket) so the TLS handshake + record I/O is bounded, not merely the
        // decoded frames `handle_connection` bounds OVER rustls.  Without this
        // a peer trickling handshake / record bytes could hold the handler far
        // past `connection_timeout`: `StreamOwned::read` drives many raw socket
        // reads within one call, each only bounded by the (per-byte-resettable)
        // socket read timeout, and the frame-read deadline is checked only
        // *between* `StreamOwned::read` calls, so it never fires mid-handshake.
        // `DeadlineStream` shrinks the socket read timeout to the remaining
        // budget on every raw read, so the whole connection is bounded by
        // `connection_timeout`.
        let deadline = Instant::now() + config.connection_timeout;
        let bounded = DeadlineStream::new(stream, deadline, config.connection_timeout);
        let mut tls_stream = StreamOwned::new(connection, bounded);
        let outcome = handle_connection(&mut tls_stream, &handle, &config, conn_id);
        tracing::info!(outcome = outcome.name(), "request handled");
    }

    #[cfg(test)]
    mod deadline_tests {
        use super::DeadlineStream;
        use std::io::Read;
        use std::net::{TcpListener, TcpStream};
        use std::time::{Duration, Instant};

        /// A connected server-side `TcpStream`; the returned client end is kept
        /// alive by the caller (dropping it would close the connection and let
        /// `read` return `Ok(0)` instead of blocking).
        fn idle_server_stream() -> (TcpStream, TcpStream) {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
            let addr = listener.local_addr().expect("local_addr");
            let client = TcpStream::connect(addr).expect("connect loopback");
            let (server, _) = listener.accept().expect("accept");
            server.set_nonblocking(false).expect("blocking mode");
            (server, client)
        }

        #[test]
        fn read_past_the_deadline_is_timed_out_without_blocking() {
            let (server, _client) = idle_server_stream();
            let past = Instant::now()
                .checked_sub(Duration::from_secs(1))
                .expect("one second ago");
            let mut s = DeadlineStream::new(server, past, Duration::from_secs(10));
            let started = Instant::now();
            let err = s
                .read(&mut [0u8; 8])
                .expect_err("a past deadline must fail");
            assert_eq!(err.kind(), std::io::ErrorKind::TimedOut);
            // Fail-fast: no socket read is attempted once the deadline passed.
            assert!(started.elapsed() < Duration::from_millis(500));
        }

        #[test]
        fn an_idle_socket_read_is_bounded_by_the_deadline() {
            // The tightening: a peer that connects then trickles nothing (the
            // slow-loris limit case) is cut off at the deadline, NOT held for
            // the full per-read backstop — the socket read timeout is shrunk to
            // the remaining budget before the read.
            let (server, _client) = idle_server_stream();
            let deadline = Instant::now() + Duration::from_millis(200);
            // Per-read backstop deliberately far LONGER than the deadline, so
            // only the deadline-derived cap can bound the read.
            let mut s = DeadlineStream::new(server, deadline, Duration::from_secs(30));
            let started = Instant::now();
            let result = s.read(&mut [0u8; 8]);
            assert!(result.is_err(), "an idle read must not succeed");
            assert!(
                started.elapsed() < Duration::from_secs(5),
                "the read must be bounded by the 200ms deadline, not the 30s backstop"
            );
        }
    }
}

/// Unix-socket listener.  Conditionally compiled for Unix; Windows
/// support is out of scope for RH-C (the L1 ingestor and other
/// Knomosis binaries also assume Unix).
#[cfg(unix)]
pub mod unix {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener as StdUnixListener, UnixStream};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;

    use crate::queue::{ConnId, QueueHandle};
    use crate::verdict::{Verdict, VerdictResponse};

    use super::{backoff_on_accept_error, handle_connection, ConnectionSlot, HandlerConfig};

    /// A Unix-socket listener.
    ///
    /// Socket file is created with mode `0600` (owner read/write
    /// only) so a non-root local user cannot access the daemon's
    /// IPC channel.
    ///
    /// ## TOCTOU race window
    ///
    /// `std::os::unix::net::UnixListener::bind` creates the socket
    /// file with the calling process's umask applied (typically
    /// `0666 & ~umask`, i.e. `0644` for the default umask `0022`).
    /// We tighten to `0600` via `set_permissions` immediately after
    /// `bind` returns, but a microsecond-wide race window exists in
    /// which a fast local attacker could connect to the
    /// world-writable socket.  The kernel's accept queue would hold
    /// the attacker's connection until our `accept_loop` dequeued
    /// it.
    ///
    /// **Operator mitigation.**  Two complementary defences:
    ///
    ///   1. **Restrict the parent directory.**  Place the socket
    ///      inside a directory with mode `0700` (owner-only).  Even
    ///      if the socket file itself is briefly world-writable, a
    ///      non-root attacker cannot traverse the parent directory
    ///      to reach it.  Example:
    ///      ```text
    ///      install -d -m 0700 -o knomosis /var/run/knomosis
    ///      knomosis-host --unix-socket /var/run/knomosis/host.sock
    ///      ```
    ///
    ///   2. **Set the process umask.**  Invoke `knomosis-host` with
    ///      `umask 0177` so the kernel-created socket inherits
    ///      `0600` directly, eliminating the race window:
    ///      ```text
    ///      umask 0177
    ///      knomosis-host --unix-socket /var/run/knomosis.sock
    ///      ```
    ///
    /// A future improvement would call `libc::umask` around the
    /// `bind` to set the umask programmatically, but that requires
    /// `unsafe` which the workspace forbids.  See the comment on
    /// `bind` for the rationale.
    #[derive(Debug)]
    pub struct UnixListener {
        inner: StdUnixListener,
        path: PathBuf,
    }

    impl UnixListener {
        /// Bind to a filesystem path and prepare to accept
        /// connections.
        ///
        /// If `path` exists already (a leftover socket from a
        /// previous run), it is removed before binding.  This
        /// matches the canonical Unix-daemon discipline.
        ///
        /// ## Race-window note
        ///
        /// See the [`UnixListener`] struct-level docstring for the
        /// TOCTOU race between `bind` and `set_permissions`.
        /// Operators MUST mitigate via a restricted parent
        /// directory (preferred) or a process-level umask of `0177`.
        ///
        /// # Errors
        ///
        /// Surfaces `std::io::Error` from the OS unlink (if any)
        /// + bind.
        pub fn bind(path: impl AsRef<Path>) -> std::io::Result<Self> {
            let path = path.as_ref().to_path_buf();
            // Remove any stale socket file.  If the file doesn't
            // exist that's fine; surfaces a real error if it's a
            // non-socket file (avoiding accidental deletion of an
            // operator's data).
            match std::fs::metadata(&path) {
                Ok(meta) => {
                    // Refuse to unlink a regular file at the socket
                    // path — could be an operator's data file by
                    // accident.  Only remove if the existing entry
                    // is a Unix-domain socket.
                    use std::os::unix::fs::FileTypeExt;
                    if !meta.file_type().is_socket() {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::AlreadyExists,
                            format!("path {path:?} exists and is not a Unix socket"),
                        ));
                    }
                    std::fs::remove_file(&path)?;
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
            let inner = StdUnixListener::bind(&path)?;
            // Tighten permissions FIRST (best-effort against the
            // race documented on the struct).  Even though the
            // kernel-created socket might briefly be 0644, narrowing
            // before set_nonblocking + accept_loop start dequeueing
            // connections gives the smallest possible exposure.
            let perms = std::fs::Permissions::from_mode(0o600);
            std::fs::set_permissions(&path, perms)?;
            // Now switch to non-blocking mode so the accept_loop
            // can poll cooperatively.
            inner.set_nonblocking(true)?;
            Ok(Self { inner, path })
        }

        /// The filesystem path the socket is bound to.
        pub fn path(&self) -> &Path {
            &self.path
        }

        /// Run the accept loop.  Blocks the calling thread until
        /// `stop` is set.
        ///
        /// `conn_seq` is the process-wide monotonic [`ConnId`] source
        /// (FQ.3), shared across all listeners.
        pub fn accept_loop(
            &self,
            handle: QueueHandle,
            config: HandlerConfig,
            stop: Arc<AtomicBool>,
            connection_counter: Arc<AtomicUsize>,
            conn_seq: Arc<AtomicU64>,
        ) {
            let mut consecutive_errors = 0u32;
            while !stop.load(Ordering::Relaxed) {
                match self.inner.accept() {
                    Ok((stream, _peer)) => {
                        consecutive_errors = 0;
                        match ConnectionSlot::try_acquire(
                            &connection_counter,
                            config.max_concurrent_connections,
                        ) {
                            Some(slot) => {
                                let conn_id = crate::queue::assign_conn_id(&conn_seq);
                                let handle = handle.clone();
                                let config = config.clone();
                                let conn_stop = Arc::clone(&stop);
                                thread::spawn(move || {
                                    handle_single_unix_connection(
                                        stream, handle, config, slot, conn_id, conn_stop,
                                    );
                                });
                            }
                            None => {
                                tracing::warn!(
                                    "Unix: max_concurrent_connections reached; responding Busy"
                                );
                                let mut stream = stream;
                                let _ = stream.set_write_timeout(Some(config.connection_timeout));
                                let bytes = VerdictResponse::from_verdict(Verdict::Busy).encode();
                                let _ = stream.write_all(&bytes);
                                let _ = stream.flush();
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        consecutive_errors = 0;
                        thread::sleep(std::time::Duration::from_millis(50));
                    }
                    Err(e) => {
                        consecutive_errors = consecutive_errors.saturating_add(1);
                        tracing::warn!(error = ?e, consecutive_errors, "Unix accept failed");
                        backoff_on_accept_error(consecutive_errors);
                    }
                }
            }
        }
    }

    impl Drop for UnixListener {
        fn drop(&mut self) {
            // Best-effort cleanup; failure is logged at debug.
            // Operators relying on socket-file persistence across
            // restarts should arrange for it externally.
            if let Err(e) = std::fs::remove_file(&self.path) {
                if e.kind() != std::io::ErrorKind::NotFound {
                    tracing::debug!(path = ?self.path, error = ?e, "could not remove socket");
                }
            }
        }
    }

    fn handle_single_unix_connection(
        mut stream: UnixStream,
        handle: QueueHandle,
        config: HandlerConfig,
        _slot: ConnectionSlot,
        conn_id: ConnId,
        stop: Arc<AtomicBool>,
    ) {
        // _slot RAII releases the connection-counter slot.
        let _ = stream.set_read_timeout(Some(config.connection_timeout));
        let _ = stream.set_write_timeout(Some(config.connection_timeout));
        let span = tracing::info_span!("conn", proto = "unix", conn = conn_id);
        let _enter = span.enter();
        let outcome = if config.persistent_connections {
            // Persistent + pipelined (see the TCP handler / `run_persistent`).
            match stream.try_clone() {
                Ok(write_half) => {
                    let _ = write_half.set_write_timeout(Some(config.connection_timeout));
                    super::run_persistent(stream, write_half, &handle, &config, conn_id, &stop)
                }
                Err(e) => {
                    tracing::warn!(error = ?e, "try_clone failed; one-shot fallback");
                    handle_connection(&mut stream, &handle, &config, conn_id)
                }
            }
        } else {
            handle_connection(&mut stream, &handle, &config, conn_id)
        };
        tracing::info!(outcome = outcome.name(), "connection handled");
    }
}

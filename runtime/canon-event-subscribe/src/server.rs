// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Top-level orchestrator for the canon-event-subscribe daemon.
//!
//! ## Threading model
//!
//! ```text
//!  ┌─────────────────────────────────────────────────────────────┐
//!  │  Extractor thread                                            │
//!  │  ─ TailReader::poll() → LogFrame                             │
//!  │  ─ Extractor::extract() → [CachedEvent]                      │
//!  │  ─ EventCache::push                                          │
//!  │  ─ SubscriberRegistry::broadcast                             │
//!  └─────────────────────────────────────────────────────────────┘
//!                       │
//!                       ▼
//!  ┌─────────────────────────────────────────────────────────────┐
//!  │  TCP acceptor thread                                          │
//!  │  ─ accept()                                                   │
//!  │  ─ read SUBSCRIBE handshake                                   │
//!  │  ─ register subscriber + spawn dispatch thread                │
//!  └─────────────────────────────────────────────────────────────┘
//!                       │
//!                       ▼
//!  ┌─────────────────────────────────────────────────────────────┐
//!  │  Per-subscriber dispatch thread (one per connection)         │
//!  │  ─ backfill from EventCache                                  │
//!  │  ─ drain Subscriber's receiver                                │
//!  │  ─ write_outbound EVENT / LAG / SHUTDOWN                     │
//!  └─────────────────────────────────────────────────────────────┘
//! ```
//!
//! ## Shutdown semantics
//!
//! `Server::run` watches the supplied stop flag.  When the flag
//! flips:
//!   1. The acceptor thread exits (no new connections accepted).
//!   2. The extractor thread completes any in-progress extract
//!      call, then exits.
//!   3. The registry's `broadcast_shutdown` is called, sending a
//!      `Shutdown` sentinel to every active subscriber's
//!      dispatch thread.
//!   4. Each dispatch thread emits a `ServerShutdown` frame, then
//!      closes its socket.
//!   5. `Server::run` returns when all spawned threads have
//!      joined.

use std::io::Read;
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::event_cache::{EventCache, NewCacheError, RangeOutcome};
use crate::extract::{ExtractError, Extractor};
use crate::frame::{
    encode_outbound, read_inbound, write_outbound, InboundFrame, OutboundFrame, WriteFrameError,
};
use crate::subscription::{
    DeliveryEvent, EnqueueOutcome, RegisterError, Subscriber, SubscriberRegistry,
};
use crate::tail::{PollOutcome, TailError, TailReader};

/// How long the extractor thread waits for the subscribe to
/// stop before forcing a quick poll.  The smaller this is, the
/// faster shutdown converges (at the cost of CPU on idle).  100
/// ms matches the tail reader's default poll interval.
const EXTRACTOR_STOP_POLL_INTERVAL: Duration = Duration::from_millis(100);

/// Maximum time `Server::run` waits for in-flight dispatch
/// threads to drain after the acceptor exits.  After this the
/// remaining threads are abandoned (their `Subscriber.disconnected`
/// flag is set so the broadcast won't enqueue further events,
/// and the TCP socket close will surface on the next dispatch
/// I/O).
const SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_secs(15);

/// Maximum time `Server::run` waits for the extractor thread to
/// exit after the stop flag is set.  If the extractor is
/// wedged in subprocess I/O (subprocess hung, network FS
/// stall, etc.), we don't want shutdown to block forever.
/// Per H-NEW-4 audit fix.
const EXTRACTOR_JOIN_TIMEOUT: Duration = Duration::from_secs(10);

/// How long each dispatch thread waits for an event before
/// re-checking the disconnect flag.  Smaller = faster shutdown
/// convergence; larger = lower CPU when idle.  500 ms is a
/// reasonable compromise; the subscriber's TCP socket already
/// surfaces the disconnect via I/O error within ~1 second of
/// the peer closing.
const DISPATCH_POLL_INTERVAL: Duration = Duration::from_millis(500);

/// Server configuration.  Constructed by `crate::config::Config`'s
/// validation path; the main binary fills it in from the parsed
/// flags.
pub struct ServerConfig {
    /// Bound TCP listener.
    pub listener: TcpListener,
    /// Tail reader, already opened against the log file.
    pub tail: TailReader,
    /// Extractor implementation (Mock or Subprocess).
    pub extractor: Box<dyn Extractor>,
    /// Subscriber registry.
    pub registry: Arc<SubscriberRegistry>,
    /// Event cache for backfill.
    pub cache: Arc<Mutex<EventCache>>,
    /// Per-subscriber outbound queue depth.
    pub send_queue_depth: usize,
    /// Lag threshold above which a subscriber is disconnected.
    pub max_subscriber_lag: u64,
    /// Maximum event payload size emitted on the wire.
    pub max_frame_size: usize,
    /// Maximum simultaneous active dispatch threads.  Caps
    /// spawn-storm DoS independently of the subscriber-registry
    /// cap (`max_subscribers`).  Default
    /// [`DEFAULT_MAX_CONCURRENT_CONNECTIONS`].
    pub max_concurrent_connections: usize,
    /// TCP write timeout for outbound frames.  A client that
    /// refuses to read for this long is considered dead.  Default
    /// [`DEFAULT_WRITE_TIMEOUT`].
    pub write_timeout: Duration,
    /// TCP read timeout for the SUBSCRIBE handshake.  Default
    /// [`DEFAULT_HANDSHAKE_READ_TIMEOUT`].
    pub handshake_read_timeout: Duration,
    /// Tail-reader poll interval.
    pub poll_interval: Duration,
}

impl ServerConfig {
    /// Construct a minimal `ServerConfig` with sensible defaults
    /// for the timeouts and connection cap.  Builder-style; the
    /// caller wires up the load-bearing fields (listener, tail,
    /// extractor, registry, cache) and the tuning knobs.
    #[must_use]
    pub fn with_defaults(
        listener: TcpListener,
        tail: TailReader,
        extractor: Box<dyn Extractor>,
        registry: Arc<SubscriberRegistry>,
        cache: Arc<Mutex<EventCache>>,
    ) -> Self {
        Self {
            listener,
            tail,
            extractor,
            registry,
            cache,
            send_queue_depth: crate::subscription::DEFAULT_SEND_QUEUE_DEPTH,
            max_subscriber_lag: crate::subscription::DEFAULT_MAX_SUBSCRIBER_LAG,
            max_frame_size: crate::frame::DEFAULT_MAX_FRAME_SIZE,
            max_concurrent_connections: DEFAULT_MAX_CONCURRENT_CONNECTIONS,
            write_timeout: DEFAULT_WRITE_TIMEOUT,
            handshake_read_timeout: DEFAULT_HANDSHAKE_READ_TIMEOUT,
            poll_interval: crate::tail::DEFAULT_POLL_INTERVAL,
        }
    }
}

impl std::fmt::Debug for ServerConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ServerConfig")
            .field("listener", &self.listener)
            .field("tail", &self.tail)
            .field("extractor", &self.extractor.identifier())
            .field("send_queue_depth", &self.send_queue_depth)
            .field("max_subscriber_lag", &self.max_subscriber_lag)
            .field("max_frame_size", &self.max_frame_size)
            .field(
                "max_concurrent_connections",
                &self.max_concurrent_connections,
            )
            .field("write_timeout", &self.write_timeout)
            .field("handshake_read_timeout", &self.handshake_read_timeout)
            .field("poll_interval", &self.poll_interval)
            // `registry` (Arc<SubscriberRegistry>) and `cache`
            // (Arc<Mutex<EventCache>>) are elided to avoid printing
            // mutex-internal state in the operator log; the surface
            // fields above are sufficient for diagnostics.
            .finish_non_exhaustive()
    }
}

/// Errors during `ServerConfig` construction.
#[derive(Debug, thiserror::Error)]
pub enum ServerBuildError {
    /// TCP listener bind failed.
    #[error("TCP bind failed: {0}")]
    Bind(#[from] std::io::Error),
    /// Tail reader could not open the log file.
    #[error("tail reader open failed: {0}")]
    TailOpen(#[from] TailError),
    /// Cache construction failed.
    #[error("event cache construction failed: {0}")]
    Cache(#[from] NewCacheError),
}

/// Server orchestrator.
pub struct Server {
    config: ServerConfig,
}

impl Server {
    /// Construct from a fully-prepared ServerConfig.
    #[must_use]
    pub fn new(config: ServerConfig) -> Self {
        Self { config }
    }

    /// Bind a TCP listener at `addr`.  Sets the listener to
    /// non-blocking accept mode so the acceptor loop can poll
    /// the stop flag.
    ///
    /// # Errors
    ///
    /// Returns [`ServerBuildError::Bind`] on bind failure.
    pub fn bind(addr: SocketAddr) -> Result<TcpListener, ServerBuildError> {
        let listener = TcpListener::bind(addr)?;
        listener.set_nonblocking(true)?;
        Ok(listener)
    }

    /// Run the orchestrator until `stop` is set.  Blocks the
    /// calling thread.
    pub fn run(self, stop: Arc<AtomicBool>) {
        let ServerConfig {
            listener,
            mut tail,
            extractor,
            registry,
            cache,
            send_queue_depth,
            max_subscriber_lag,
            max_frame_size,
            max_concurrent_connections,
            write_timeout,
            handshake_read_timeout,
            poll_interval,
        } = self.config;

        let local_addr = listener.local_addr().ok();
        let extractor_id = extractor.identifier().to_string();
        tracing::info!(
            addr = ?local_addr,
            extractor = %extractor_id,
            send_queue_depth,
            max_subscriber_lag,
            max_frame_size,
            max_concurrent_connections,
            poll_interval_ms = poll_interval.as_millis(),
            "canon-event-subscribe starting"
        );

        // Per-server connection counter, shared between acceptor
        // and dispatch threads via RAII `ConnectionSlot`.
        let connection_counter = Arc::new(std::sync::atomic::AtomicUsize::new(0));

        // 1. Spawn the extractor thread.  H-2 fix: pass `stop` so
        //    the extractor can SET the stop flag on a fatal error
        //    (log corruption, subprocess unavailable).  Without
        //    this, the acceptor keeps accepting connections that
        //    can never be served.
        //
        //    Additional defence (post-second-audit): wrap the
        //    extractor body in `catch_unwind` so that a panic
        //    in the extractor still sets the stop flag.  Without
        //    this, a panicking extractor would unwind silently
        //    and the acceptor would keep running forever.
        let extractor_stop = Arc::clone(&stop);
        let extractor_cache = Arc::clone(&cache);
        let extractor_registry = Arc::clone(&registry);
        let extractor_spawn_result = thread::Builder::new()
            .name("canon-event-subscribe-extractor".into())
            .spawn(move || {
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    extractor_loop(
                        &mut tail,
                        extractor.as_ref(),
                        &extractor_cache,
                        &extractor_registry,
                        poll_interval,
                        &extractor_stop,
                    );
                }));
                if let Err(panic) = result {
                    // Ensure stop is set + subscribers notified
                    // even on panic.  AssertUnwindSafe is correct
                    // because the data we touch on panic (registry,
                    // stop atomic) are themselves Sync and resilient
                    // to partial-update.
                    tracing::error!(
                        "extractor thread panicked; halting daemon: {:?}",
                        panic_message(&panic)
                    );
                    extractor_registry.broadcast_shutdown();
                    extractor_stop.store(true, Ordering::Release);
                }
            });
        // H-3R-3 audit: do not panic on extractor-thread spawn
        // failure (EAGAIN / ENOMEM / RLIMIT_NPROC at startup
        // exhaustion).  Log + return cleanly so the operator
        // sees an exit code rather than a panic backtrace.
        let extractor_handle = match extractor_spawn_result {
            Ok(h) => h,
            Err(e) => {
                tracing::error!(
                    error = ?e,
                    "failed to spawn extractor thread at startup; aborting Server::run"
                );
                return;
            }
        };

        // 2. Run the acceptor loop in the current thread.  Each
        //    accepted connection spawns its own dispatch thread
        //    (gated by a connection-slot RAII guard).
        let mut dispatch_handles: Vec<JoinHandle<()>> = Vec::new();
        let dispatch_cfg = DispatchConfig {
            send_queue_depth,
            max_subscriber_lag,
            max_frame_size,
            max_concurrent_connections,
            write_timeout,
            handshake_read_timeout,
        };
        accept_loop(
            &listener,
            &registry,
            &cache,
            dispatch_cfg,
            &mut dispatch_handles,
            &connection_counter,
            &stop,
        );

        // 3. Stop flipped.  Broadcast shutdown to existing
        //    subscribers FIRST (per H-NEW-4 audit: previously
        //    we joined the extractor first, but if the extractor
        //    was wedged in subprocess I/O the join would block
        //    indefinitely and subscribers would never see
        //    ServerShutdown).  Now subscribers get the signal
        //    immediately even if the extractor is wedged.
        registry.broadcast_shutdown();

        // 4. Bounded wait for extractor to exit.  If the extractor
        //    is wedged in subprocess I/O without timeout, we
        //    cannot block shutdown indefinitely.  Poll
        //    is_finished + sleep instead of an unbounded join().
        if let Err(panic) = bounded_join(extractor_handle, EXTRACTOR_JOIN_TIMEOUT) {
            // panic_message extracts a human-readable string from
            // a panic payload OR the JoinTimeoutMarker (matching
            // canon-host's convention).  Without this the
            // `tracing::warn!(error = ?panic, ...)` would print
            // an opaque `Box<dyn Any>` shape with no diagnostic
            // value.
            tracing::warn!(
                reason = %panic_message(&panic),
                "extractor thread panicked or abandoned at shutdown"
            );
        }

        // 5. Wait for dispatch threads to drain (bounded).
        wait_for_dispatch_drain(
            &mut dispatch_handles,
            &connection_counter,
            SHUTDOWN_DRAIN_TIMEOUT,
        );

        tracing::info!("canon-event-subscribe stopped");
    }
}

/// Bounded `JoinHandle::join` via `is_finished` polling.  Returns
/// the join result on completion within `timeout`, or `Err` with
/// the abandonment payload if the deadline elapsed.  Used by
/// `Server::run` so a wedged extractor (e.g. blocked in
/// subprocess I/O without timeout) cannot block shutdown
/// indefinitely.
fn bounded_join(handle: JoinHandle<()>, timeout: Duration) -> std::thread::Result<()> {
    let deadline = Instant::now() + timeout;
    loop {
        if handle.is_finished() {
            return handle.join();
        }
        if Instant::now() >= deadline {
            // Abandon the handle (thread keeps running until
            // process exit).  Synthesise a marker payload so
            // the caller knows it timed out (vs a real panic).
            tracing::warn!("bounded_join timed out after {timeout:?}; thread abandoned");
            return Err(Box::new(JoinTimeoutMarker { timeout }));
        }
        thread::sleep(Duration::from_millis(50));
    }
}

/// Marker payload returned by `bounded_join` on timeout.  Lets
/// the caller distinguish a join timeout from a real thread
/// panic.
#[derive(Debug)]
struct JoinTimeoutMarker {
    timeout: Duration,
}
impl std::fmt::Display for JoinTimeoutMarker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "join timed out after {:?}", self.timeout)
    }
}
impl std::error::Error for JoinTimeoutMarker {}

/// Block until every spawned dispatch thread joins, or `timeout`
/// elapses.
///
/// Uses the connection counter (incremented on
/// [`ConnectionSlot::try_acquire`], decremented on Drop) as the
/// primary "still alive" signal.  When the counter reaches zero,
/// every dispatch thread has at least returned from its closure
/// body (slot drop runs at closure-exit).  Then joins any
/// handles whose threads report `is_finished` so panic info
/// surfaces in operator logs.  Stuck threads (e.g. blocked in
/// `write_all` despite the write timeout, or sleeping in a
/// dispatch-poll loop) are abandoned at the deadline rather than
/// blocking shutdown indefinitely — the OS will reap them on
/// process exit.  Per H-3 audit finding.
fn wait_for_dispatch_drain(
    handles: &mut Vec<JoinHandle<()>>,
    counter: &Arc<std::sync::atomic::AtomicUsize>,
    timeout: Duration,
) {
    let deadline = Instant::now() + timeout;
    // Phase 1: poll the counter until 0 or deadline.
    loop {
        let active = counter.load(Ordering::Acquire);
        if active == 0 {
            break;
        }
        if Instant::now() >= deadline {
            tracing::warn!(
                active,
                "dispatch drain deadline elapsed; {active} dispatch thread(s) still active"
            );
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    // Phase 2: drain `handles`, joining finished threads (to
    // surface panic info) and re-parking still-running ones (so
    // we can verify counts post-shutdown).
    let drained: Vec<JoinHandle<()>> = std::mem::take(handles);
    let mut joined = 0usize;
    let mut abandoned = 0usize;
    for h in drained {
        if h.is_finished() {
            if let Err(e) = h.join() {
                tracing::warn!(error = ?e, "dispatch thread panicked");
            }
            joined += 1;
        } else {
            // Re-park; the OS reaps these on process exit.
            handles.push(h);
            abandoned += 1;
        }
    }
    if abandoned > 0 {
        tracing::warn!(
            joined,
            abandoned,
            "dispatch drain: abandoned threads will be reaped on process exit"
        );
    }
}

/// Default maximum simultaneous active dispatch-thread count.
/// Caps spawn-storm DoS independently of the subscriber-registry
/// cap (`max_subscribers`).  Per H-NEW-3 audit: kept at 4× the
/// subscriber cap to allow for in-flight handshake +
/// post-shutdown drain, but no further multiplier — operators
/// who tune `max_subscribers` get a tighter implied
/// concurrent-connection cap.  Config validation enforces
/// `max_concurrent_connections >= max_subscribers`.
pub const DEFAULT_MAX_CONCURRENT_CONNECTIONS: usize = 1024;

/// Hard ceiling on operator-configurable simultaneous active
/// dispatch-thread count.  Mirrors canon-host's value.
pub const HARD_MAX_CONCURRENT_CONNECTIONS: usize = 65_536;

/// Default TCP write timeout for client connections.  A client
/// that refuses to read for this long is considered dead and the
/// connection is closed (mitigating slowloris-style DoS where a
/// client holds the connection open but never drains data).
/// 30 s is a generous default that tolerates legitimate
/// network hiccups.
pub const DEFAULT_WRITE_TIMEOUT: Duration = Duration::from_secs(30);

/// Default TCP read timeout for the SUBSCRIBE handshake.  A
/// client that doesn't send a complete handshake within this
/// window is dropped.  Defends against connection-holding DoS
/// where a client opens many TCP sockets without sending data.
pub const DEFAULT_HANDSHAKE_READ_TIMEOUT: Duration = Duration::from_secs(10);

/// A counted slot in the connection limiter.  RAII guard: the
/// shared atomic counter increments on construction, decrements
/// on drop.  Ensures even a panicked dispatch thread releases its
/// slot.  Mirrors `canon-host::listener::ConnectionSlot`.
struct ConnectionSlot {
    counter: Arc<std::sync::atomic::AtomicUsize>,
}

impl ConnectionSlot {
    /// Try to acquire a slot.  Returns `Some(slot)` on success
    /// or `None` if the active count already hit `cap`.  Internally
    /// clamped to [`HARD_MAX_CONCURRENT_CONNECTIONS`] as a
    /// defence-in-depth guard against library consumers passing
    /// `usize::MAX`.
    fn try_acquire(counter: &Arc<std::sync::atomic::AtomicUsize>, cap: usize) -> Option<Self> {
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
                        counter: Arc::clone(counter),
                    });
                }
                Err(observed) => current = observed,
            }
        }
    }
}

impl Drop for ConnectionSlot {
    fn drop(&mut self) {
        self.counter.fetch_sub(1, Ordering::Release);
    }
}

/// Dispatch-thread tunables.  Captures the per-subscriber
/// configuration so the acceptor + handle_connection signatures
/// stay tidy.
#[derive(Clone, Copy, Debug)]
struct DispatchConfig {
    send_queue_depth: usize,
    max_subscriber_lag: u64,
    max_frame_size: usize,
    max_concurrent_connections: usize,
    write_timeout: Duration,
    handshake_read_timeout: Duration,
}

/// The acceptor loop.  Owns the TCP listener; spawns dispatch
/// threads for each accepted connection (gated by a
/// connection-slot RAII guard for DoS resistance).
fn accept_loop(
    listener: &TcpListener,
    registry: &Arc<SubscriberRegistry>,
    cache: &Arc<Mutex<EventCache>>,
    dispatch_cfg: DispatchConfig,
    dispatch_handles: &mut Vec<JoinHandle<()>>,
    connection_counter: &Arc<std::sync::atomic::AtomicUsize>,
    stop: &Arc<AtomicBool>,
) {
    let mut backoff = Duration::from_millis(50);
    let backoff_max = Duration::from_millis(3200);
    loop {
        if stop.load(Ordering::Relaxed) {
            tracing::info!("acceptor stopping");
            return;
        }
        match listener.accept() {
            Ok((stream, peer)) => {
                backoff = Duration::from_millis(50);
                // Acquire a slot before spawning.  If we're at
                // capacity, reject the connection immediately
                // (close the socket without spawning a thread).
                // This is the load-bearing DoS defence: an
                // attacker opening 100k simultaneous TCP
                // connections cannot exhaust our thread budget
                // because they never get a thread to begin with.
                let slot = match ConnectionSlot::try_acquire(
                    connection_counter,
                    dispatch_cfg.max_concurrent_connections,
                ) {
                    Some(s) => s,
                    None => {
                        tracing::warn!(
                            peer = %peer,
                            "connection slot at capacity; rejecting"
                        );
                        // Best-effort: write a LagExceeded frame
                        // (semantically "server cannot serve you;
                        // back off") then close.  The client
                        // doesn't expect this to succeed —
                        // they'll likely see a connection
                        // reset.
                        let _ = write_capacity_rejection(&stream, dispatch_cfg.max_frame_size);
                        let _ = stream.shutdown(Shutdown::Both);
                        continue;
                    }
                };
                tracing::info!(peer = %peer, "new subscriber connection");
                let cache_clone = Arc::clone(cache);
                let registry_clone = Arc::clone(registry);
                let stop_clone = Arc::clone(stop);
                let cfg = dispatch_cfg;
                // C-NEW-3 audit fix: don't panic on spawn failure
                // (EAGAIN / ENOMEM / RLIMIT_NPROC).  An attacker
                // exhausting the OS thread budget could otherwise
                // crash the entire daemon.  Log, drop the slot
                // (closure consumed `slot`; Drop runs on Err),
                // and continue accepting.
                let spawn_result = thread::Builder::new()
                    .name(format!("canon-event-subscribe-dispatch-{peer}"))
                    .spawn(move || {
                        // `slot` is moved into the closure so its
                        // Drop runs when the dispatch thread
                        // exits — releasing the slot via RAII.
                        let _slot = slot;
                        if let Err(e) = handle_connection(
                            stream,
                            peer,
                            registry_clone,
                            cache_clone,
                            cfg,
                            stop_clone,
                        ) {
                            tracing::warn!(error = ?e, peer = %peer, "subscriber connection ended with error");
                        }
                    });
                match spawn_result {
                    Ok(handle) => dispatch_handles.push(handle),
                    Err(e) => {
                        // Slot is dropped via the consumed closure;
                        // counter decrements automatically.
                        tracing::error!(
                            error = ?e,
                            peer = %peer,
                            "failed to spawn dispatch thread; backing off"
                        );
                        // Briefly back off to avoid spin-looping
                        // on persistent thread-budget exhaustion.
                        thread::sleep(Duration::from_millis(100));
                    }
                }
                // C-NEW-4 audit fix: explicitly join finished
                // handles instead of silently dropping them, so
                // panics in dispatch threads surface in operator
                // logs.
                reap_finished_dispatch_handles(dispatch_handles);
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                // No connection waiting; sleep a short interval
                // before re-polling the listener.  M-NEW-7 audit
                // fix: reset the error-backoff on a clean
                // WouldBlock too (it's the "no-op success" case),
                // so the previous backoff state doesn't persist
                // across recoveries.
                backoff = Duration::from_millis(50);
                thread::sleep(Duration::from_millis(50));
            }
            Err(e) => {
                tracing::warn!(error = ?e, "accept error; backing off");
                thread::sleep(backoff);
                // Saturating-mul guards against the academic
                // Duration overflow edge case (L-NEW-5 audit).
                backoff = backoff.saturating_mul(2).min(backoff_max);
            }
        }
    }
}

/// Reap dispatch threads that have already finished by joining
/// them (so panics surface) and removing them from the handle
/// vector.  Per C-NEW-4 audit: the prior `retain(|h|
/// !h.is_finished())` silently dropped JoinHandles without
/// joining, swallowing any panic info.
fn reap_finished_dispatch_handles(handles: &mut Vec<JoinHandle<()>>) {
    let drained: Vec<JoinHandle<()>> = std::mem::take(handles);
    for h in drained {
        if h.is_finished() {
            if let Err(panic) = h.join() {
                tracing::error!(panic = ?panic, "dispatch thread panicked");
            }
        } else {
            // Still running — re-park.
            handles.push(h);
        }
    }
}

/// Write a `LagExceeded` rejection frame on a connection that
/// was refused at capacity.  Best-effort; the client may have
/// already disconnected.
///
/// Per M-NEW-8 audit fix: deadline is 250ms (down from 2s) so a
/// stalled client cannot tie up the acceptor thread on this
/// best-effort write.  The acceptor is single-threaded; long
/// rejection-writes are a DoS amplifier.
fn write_capacity_rejection(
    stream: &TcpStream,
    max_frame_size: usize,
) -> Result<(), WriteFrameError> {
    let bytes = encode_outbound(
        &OutboundFrame::LagExceeded {
            last_delivered_seq: 0,
        },
        max_frame_size,
    )?;
    let mut stream = stream;
    let _ = stream.set_write_timeout(Some(Duration::from_millis(250)));
    std::io::Write::write_all(&mut stream, &bytes)?;
    Ok(())
}

/// Errors from [`handle_connection`].
#[derive(Debug, thiserror::Error)]
enum ConnectionError {
    /// Frame parser error on the inbound handshake.
    #[error("frame parse: {0}")]
    Frame(#[from] crate::frame::FrameError),
    /// Underlying I/O error.
    #[error("I/O: {0}")]
    Io(#[from] std::io::Error),
    /// Subscriber registry rejected the connection (at-capacity).
    #[error("registry: {0}")]
    Register(#[from] RegisterError),
    /// Outbound frame write failed.
    #[error("write: {0}")]
    Write(#[from] WriteFrameError),
}

/// Handle one accepted connection.  Reads the handshake, registers
/// the subscriber, performs backfill, then enters the live-dispatch
/// loop.
fn handle_connection(
    mut stream: TcpStream,
    peer: SocketAddr,
    registry: Arc<SubscriberRegistry>,
    cache: Arc<Mutex<EventCache>>,
    cfg: DispatchConfig,
    stop: Arc<AtomicBool>,
) -> Result<(), ConnectionError> {
    let DispatchConfig {
        send_queue_depth,
        max_subscriber_lag,
        max_frame_size,
        write_timeout,
        handshake_read_timeout,
        ..
    } = cfg;
    // Drop non-blocking mode for the handshake; read_inbound
    // expects a blocking reader.
    stream.set_nonblocking(false)?;
    // Read timeout bounds the handshake parse — a client that
    // opens a socket and never sends SUBSCRIBE will be dropped
    // after this window (defends against slowloris-style
    // connection-holding DoS).
    stream.set_read_timeout(Some(handshake_read_timeout))?;
    // Write timeout bounds outbound writes — a client that
    // refuses to read for this long is considered dead.  Defends
    // against slowloris where a client holds the connection open
    // but never drains data.
    stream.set_write_timeout(Some(write_timeout))?;

    // 1. Parse the handshake.  On any parse error, send
    //    InvalidRequest then close.
    let handshake = match read_inbound(&mut stream) {
        Ok(f) => f,
        Err(e) => {
            tracing::warn!(error = ?e, peer = %peer, "invalid handshake; closing");
            let bytes = encode_outbound(&OutboundFrame::InvalidRequest, max_frame_size)
                .expect("InvalidRequest never fails to encode");
            let _ = std::io::Write::write_all(&mut stream, &bytes);
            let _ = stream.shutdown(Shutdown::Both);
            return Err(e.into());
        }
    };

    let resume_from = match handshake {
        InboundFrame::Subscribe { resume_from } => resume_from,
    };
    tracing::info!(peer = %peer, resume_from, "subscribe handshake accepted");

    // 2. Register the subscriber.  On at-capacity, send
    //    LagExceeded (re-using the lag-exceeded byte semantics for
    //    "server-side cannot accept you") and close.
    let (sub, rx) = match registry.register(send_queue_depth, max_subscriber_lag) {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!(error = ?e, peer = %peer, "registry rejected");
            let bytes = encode_outbound(
                &OutboundFrame::LagExceeded {
                    last_delivered_seq: 0,
                },
                max_frame_size,
            )
            .expect("LagExceeded never fails to encode");
            let _ = std::io::Write::write_all(&mut stream, &bytes);
            let _ = stream.shutdown(Shutdown::Both);
            return Err(e.into());
        }
    };

    // 3. Backfill from the cache.
    let backfill_outcome = {
        let cache_guard = cache.lock().unwrap_or_else(|p| p.into_inner());
        cache_guard.range(resume_from)
    };
    match backfill_outcome {
        RangeOutcome::OutOfWindow {
            oldest_available_seq,
        } => {
            tracing::info!(
                peer = %peer,
                resume_from,
                oldest_available_seq,
                "resume out-of-window; emitting Truncated"
            );
            let bytes = encode_outbound(
                &OutboundFrame::Truncated {
                    oldest_available_seq,
                },
                max_frame_size,
            )?;
            std::io::Write::write_all(&mut stream, &bytes)?;
            let _ = stream.shutdown(Shutdown::Both);
            registry.unregister(&sub);
            return Ok(());
        }
        RangeOutcome::InWindow { events } => {
            for event in events {
                // Write the event frame.
                let frame = OutboundFrame::Event {
                    seq: event.seq,
                    payload: event.payload.clone(),
                };
                match write_outbound(&mut stream, &frame, max_frame_size) {
                    Ok(()) => {
                        sub.record_delivered(event.seq);
                    }
                    Err(e) => {
                        tracing::warn!(error = ?e, peer = %peer, "backfill write failed");
                        sub.mark_disconnected();
                        registry.unregister(&sub);
                        return Err(e.into());
                    }
                }
            }
        }
        RangeOutcome::AtLiveTail => {
            // Nothing to backfill; proceed directly to live mode.
        }
    }

    // 3.5. Race-window check: between `registry.register` and
    // `Server::run`'s second `broadcast_shutdown`, a subscriber
    // can be registered AFTER `halt_extractor`'s first
    // `broadcast_shutdown` but BEFORE the second one.  If
    // `stop` is set right now, the second broadcast_shutdown
    // will set our `shutdown_requested` shortly.  We could
    // proactively check `stop` here and emit ServerShutdown
    // immediately, but doing so would race against
    // `broadcast_shutdown` which also sets the flag.  Letting
    // `dispatch_live` poll the shutdown flag handles both
    // cases uniformly with a single source of truth.  We do
    // check `stop` here to short-circuit the dispatch_live
    // setup costs (cheap optimization; safe because
    // `dispatch_live` would observe the flag via
    // broadcast_shutdown anyway).
    if stop.load(Ordering::Acquire) && !sub.is_shutdown_requested() {
        // Trigger our own shutdown without waiting for
        // broadcast_shutdown to reach us.  L-3R-1 audit: log
        // on Disconnected outcome (subscriber already gone, but
        // we noticed the shutdown signal) for observability.
        match sub.request_shutdown() {
            EnqueueOutcome::Enqueued | EnqueueOutcome::Lagging { .. } => {
                tracing::debug!(
                    peer = %peer,
                    "race-window shutdown trigger sent"
                );
            }
            EnqueueOutcome::Disconnected => {
                tracing::debug!(
                    peer = %peer,
                    "race-window shutdown trigger: subscriber already gone"
                );
            }
            EnqueueOutcome::LagExceeded => {
                // request_shutdown never returns LagExceeded.
                tracing::warn!(
                    peer = %peer,
                    "race-window shutdown trigger: unexpected LagExceeded"
                );
            }
        }
    }

    // 4. Live mode: drain the subscriber's receiver, writing
    //    each event as it arrives.  Loop until disconnect.
    dispatch_live(&mut stream, peer, &sub, &rx, max_frame_size, &stop);

    // 5. Cleanup.
    registry.unregister(&sub);
    Ok(())
}

/// Live-mode dispatch loop.  Blocks on the subscriber's receiver
/// until a `Shutdown` sentinel arrives or the subscriber is
/// marked disconnected (e.g. by lag eviction in the broadcast
/// thread).
///
/// ## Duplicate-suppression invariant (load-bearing)
///
/// On entry, `sub.last_delivered_seq()` is the highest seq the
/// connection handler delivered via backfill (`0` if no backfill
/// happened).  The channel may contain events with seq ≤
/// `max_backfilled` due to the registration→backfill race:
///
///   1. Subscriber is registered in `registry` (Time T1).
///   2. Extractor begins a batch: acquires the cache lock,
///      pushes every event in the batch to the cache, broadcasts
///      every event to every subscriber's channel (including this
///      one), and releases the cache lock.  This entire phase is
///      atomic under the cache lock (Time T2 > T1).
///   3. Subscriber's `handle_connection` acquires the cache lock
///      (blocking if the extractor is mid-batch), reads
///      `cache.range(resume_from)` (Time T3 ≥ T2's release).
///      Backfill includes the entire batch from T2.
///   4. Subscriber writes the batch to stream via backfill.
///   5. Subscriber enters `dispatch_live`.
///   6. **Without the drain below**: the channel still holds the
///      events from T2.  Dispatch would deliver them AGAIN.
///
/// The one-time drain at the top of this function discards every
/// pending channel event with `seq ≤ max_backfilled`.  Per
/// C-NEW-1 audit fix: this works correctly only because
/// `extractor_loop` holds the cache lock across BOTH the entire
/// batch push AND the entire batch broadcast.  Without that
/// atomicity, a subscriber could see a partial batch in cache
/// while the channel held additional events at the same seq —
/// the drain would incorrectly suppress those events as
/// "duplicates".
///
/// Post-fix invariant: any event with `seq ≤ max_backfilled`
/// found in the channel during the drain is GUARANTEED to be a
/// duplicate of a backfilled event, because the cache snapshot
/// at handle_connection time captured the entire batch atomically
/// with respect to the broadcast.
fn dispatch_live(
    stream: &mut TcpStream,
    peer: SocketAddr,
    sub: &Subscriber,
    rx: &std::sync::mpsc::Receiver<DeliveryEvent>,
    max_frame_size: usize,
    stop: &Arc<AtomicBool>,
) {
    // The `stop` flag is plumbed through but the dispatch loop
    // does not consult it directly.  Reason: the server's shutdown
    // path emits a `Shutdown` sentinel into every subscriber's
    // channel via `registry.broadcast_shutdown()`, and we want the
    // dispatch thread to emit the `ServerShutdown` frame in
    // response.  A direct stop-flag check here would race with the
    // sentinel arrival and could close the socket before the frame
    // was written.  Treating the sentinel as the canonical
    // shutdown signal keeps the wire-protocol promise.
    let _ = stop;

    // Step 1: drain duplicates left over from the registration →
    // backfill race.  See the function-level docstring.
    let max_backfilled = sub.last_delivered_seq();
    let mut pending: std::collections::VecDeque<DeliveryEvent> = std::collections::VecDeque::new();
    if max_backfilled > 0 {
        let mut suppressed = 0usize;
        loop {
            match rx.try_recv() {
                Ok(DeliveryEvent::Live(event)) => {
                    if event.seq > max_backfilled {
                        pending.push_back(DeliveryEvent::Live(event));
                    } else {
                        // Duplicate of a backfilled event.  Drop.
                        suppressed += 1;
                    }
                }
                Ok(DeliveryEvent::Shutdown) => {
                    // Shutdown sentinels are never duplicates;
                    // preserve them.
                    pending.push_back(DeliveryEvent::Shutdown);
                }
                Err(_) => break,
            }
        }
        if suppressed > 0 {
            tracing::debug!(
                peer = %peer,
                max_backfilled,
                suppressed,
                "dispatch: suppressed channel duplicates after backfill"
            );
        }
    }

    // Step 2: main dispatch loop.  Drain `pending` first
    // (already-validated to be deliverable), then the live
    // channel.
    loop {
        // Shutdown takes precedence over lag-eviction: if the
        // server requested shutdown, emit ServerShutdown even
        // if the subscriber was technically about-to-be-evicted.
        // The shutdown flag is the canonical signal — set by
        // `broadcast_shutdown` for every subscriber regardless
        // of channel capacity.
        if sub.is_shutdown_requested() {
            tracing::info!(
                peer = %peer,
                last_delivered_seq = sub.last_delivered_seq(),
                "subscriber received shutdown request; sending ServerShutdown"
            );
            let frame = OutboundFrame::ServerShutdown {
                last_delivered_seq: sub.last_delivered_seq(),
            };
            let _ = write_outbound(stream, &frame, max_frame_size);
            let _ = stream.shutdown(Shutdown::Both);
            return;
        }
        // Lag-eviction (set by the broadcast thread when the
        // subscriber's lag counter exceeded the threshold).
        if sub.is_disconnected() {
            tracing::info!(
                peer = %peer,
                last_delivered_seq = sub.last_delivered_seq(),
                "subscriber lag-evicted; sending LagExceeded"
            );
            let frame = OutboundFrame::LagExceeded {
                last_delivered_seq: sub.last_delivered_seq(),
            };
            let _ = write_outbound(stream, &frame, max_frame_size);
            let _ = stream.shutdown(Shutdown::Both);
            return;
        }
        // Pull the next event: pending queue first (post-drain
        // residue), then the live channel.
        let next = if let Some(p) = pending.pop_front() {
            p
        } else {
            match rx.recv_timeout(DISPATCH_POLL_INTERVAL) {
                Ok(e) => e,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    // No event in the last interval; re-check
                    // shutdown / disconnect flags via the loop.
                    // Also opportunistically probe the TCP
                    // socket to detect peer close.
                    if !is_connected(stream) {
                        tracing::info!(peer = %peer, "subscriber TCP socket closed");
                        sub.mark_disconnected();
                        return;
                    }
                    continue;
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    // Sender dropped; broadcast thread is gone.
                    // H-NEW-5 audit fix: emit ServerShutdown so
                    // the client can distinguish "server gone"
                    // from "network failure".  Reuse the
                    // ServerShutdown variant because operationally
                    // the upstream is gone — a server-shutdown is
                    // the closest existing signal.
                    tracing::info!(peer = %peer, "broadcast sender dropped; emitting ServerShutdown");
                    let frame = OutboundFrame::ServerShutdown {
                        last_delivered_seq: sub.last_delivered_seq(),
                    };
                    let _ = write_outbound(stream, &frame, max_frame_size);
                    sub.mark_disconnected();
                    let _ = stream.shutdown(Shutdown::Both);
                    return;
                }
            }
        };
        match next {
            DeliveryEvent::Live(event) => {
                let frame = OutboundFrame::Event {
                    seq: event.seq,
                    payload: event.payload,
                };
                match write_outbound(stream, &frame, max_frame_size) {
                    Ok(()) => {
                        sub.record_delivered(event.seq);
                    }
                    Err(e) => {
                        tracing::warn!(error = ?e, peer = %peer, "dispatch write failed");
                        sub.mark_disconnected();
                        let _ = stream.shutdown(Shutdown::Both);
                        return;
                    }
                }
            }
            DeliveryEvent::Shutdown => {
                tracing::info!(peer = %peer, "subscriber received Shutdown sentinel");
                let frame = OutboundFrame::ServerShutdown {
                    last_delivered_seq: sub.last_delivered_seq(),
                };
                let _ = write_outbound(stream, &frame, max_frame_size);
                let _ = stream.shutdown(Shutdown::Both);
                return;
            }
        }
    }
}

/// Probe the TCP stream for peer-close or post-handshake
/// protocol violation.  Sets a 1-millisecond read timeout,
/// attempts a 1-byte read into a discard buffer, and restores
/// the original timeout.
///
/// **Per M-2 audit fix:** any successful non-zero read is
/// treated as a protocol violation (the client should never
/// send data after SUBSCRIBE per §11.1).  Returns `false`
/// (closed) in that case so the dispatch loop emits the proper
/// shutdown sequence rather than silently dropping bytes.
fn is_connected(stream: &TcpStream) -> bool {
    // L-NEW-1 audit: if read_timeout() itself fails, the stream
    // is in a weird state — assume connected and skip the probe
    // to avoid corrupting timeout state.  The next iteration's
    // recv_timeout will surface any real disconnect.
    let prev_timeout = match stream.read_timeout() {
        Ok(t) => t,
        Err(_) => return true,
    };
    if stream
        .set_read_timeout(Some(Duration::from_millis(1)))
        .is_err()
    {
        return true; // benign — keep going
    }
    let mut buf = [0u8; 1];
    let mut probe = stream;
    let connected = match probe.read(&mut buf) {
        Ok(0) => false, // peer closed
        Ok(_) => {
            // Protocol violation: client sent data post-SUBSCRIBE.
            // Per §11.1 the connection is one-way after the
            // handshake.  Treat as a hard error and close.
            tracing::warn!("client sent data after SUBSCRIBE (protocol violation); closing");
            false
        }
        Err(e)
            // L-NEW-6 audit: Interrupted is a transient
            // signal-delivery; treat as "still connected".
            if e.kind() == std::io::ErrorKind::WouldBlock
                || e.kind() == std::io::ErrorKind::TimedOut
                || e.kind() == std::io::ErrorKind::Interrupted =>
        {
            true
        }
        Err(_) => false,
    };
    // Restore.
    let _ = stream.set_read_timeout(prev_timeout);
    connected
}

/// The extractor thread main loop.  Polls the tail reader,
/// extracts events, pushes them to the cache, and broadcasts
/// them to subscribers.
fn extractor_loop(
    tail: &mut TailReader,
    extractor: &dyn Extractor,
    cache: &Arc<Mutex<EventCache>>,
    registry: &Arc<SubscriberRegistry>,
    poll_interval: Duration,
    stop: &Arc<AtomicBool>,
) {
    let extractor_id = extractor.identifier().to_string();
    tracing::info!(extractor = %extractor_id, log_path = ?tail.path(), "extractor thread up");
    loop {
        if stop.load(Ordering::Relaxed) {
            tracing::info!("extractor stopping");
            return;
        }
        match tail.poll() {
            Ok(PollOutcome::Frame(frame)) => {
                tracing::debug!(seq = frame.seq, bytes = frame.payload.len(), "log frame");
                match extractor.extract(frame.seq, &frame.payload) {
                    Ok(events) => {
                        let event_count = events.len();
                        // C-NEW-1 audit fix: push the entire batch
                        // AND broadcast it under a single cache
                        // lock hold.  This makes the cache snapshot
                        // and channel state mutually consistent
                        // for any subscriber acquiring the cache
                        // lock: they will see either the full
                        // batch in cache + all corresponding
                        // channel events, OR none of this batch.
                        // A partial-batch snapshot is no longer
                        // possible.
                        //
                        // Without this atomicity, a subscriber's
                        // cache snapshot could see (event1) but
                        // channel could carry (event1, event2,
                        // event3), and the dispatch_live drain
                        // (suppressing seq ≤ max_backfilled)
                        // would incorrectly suppress event2 and
                        // event3 — silently dropping events.
                        //
                        // Trade-off: while we hold the cache
                        // lock, subscribers acquiring it for
                        // backfill snapshot block.  For typical
                        // small batches (1-3 events × ≤256
                        // subscribers × non-blocking try_send),
                        // this is fast (sub-ms).  For pathological
                        // batches (e.g. 100-event distributeOthers
                        // × 256 subscribers), it can reach ~25ms;
                        // still acceptable for a deployment-rare
                        // action.
                        let mut cache_guard = cache.lock().unwrap_or_else(|p| p.into_inner());
                        // Phase A: push entire batch to cache.
                        for event in &events {
                            if let Err(e) = cache_guard.push(event.clone()) {
                                tracing::error!(
                                    error = ?e,
                                    seq = event.seq,
                                    "cache push failed (extractor produced decreasing seq); halting"
                                );
                                drop(cache_guard);
                                halt_extractor(registry, stop);
                                return;
                            }
                        }
                        // Phase B: snapshot the subscriber set
                        // ONCE for this entire batch, then
                        // broadcast every event to the SAME
                        // snapshot.  C-3R-1 audit fix: this
                        // prevents a subscriber that registers
                        // mid-batch from receiving event[1..]
                        // without event[0] — an incomplete
                        // multi-event-per-frame batch the wire
                        // protocol cannot detect (events share
                        // a seq).  A mid-batch subscriber is
                        // uniformly EXCLUDED from this batch's
                        // broadcasts; they pick up these events
                        // via cache backfill on their handshake
                        // (for `resume_from > 0`) or skip them
                        // entirely (for `resume_from = 0`
                        // live-tail — the documented contract:
                        // "events produced AFTER the subscription
                        // is registered" with BATCH atomicity).
                        let snapshot = registry.snapshot();
                        let mut total_evicted = 0usize;
                        let mut total_enqueued = 0usize;
                        let mut total_lagging = 0usize;
                        for event in events {
                            let summary =
                                SubscriberRegistry::broadcast_to_snapshot(&snapshot, event);
                            total_evicted += summary.evicted;
                            total_enqueued += summary.enqueued;
                            total_lagging += summary.lagging;
                        }
                        drop(cache_guard);
                        if total_evicted > 0 {
                            tracing::warn!(
                                evicted = total_evicted,
                                enqueued = total_enqueued,
                                lagging = total_lagging,
                                seq = frame.seq,
                                "subscribers evicted for lag during batch broadcast"
                            );
                        }
                        if event_count == 0 {
                            tracing::trace!(seq = frame.seq, "log frame produced no events");
                        }
                    }
                    Err(ExtractError::SubprocessUnavailable { reason }) => {
                        // Permanent extractor failure.  H-2 fix:
                        // set the stop flag so the acceptor stops
                        // taking new connections (which it
                        // cannot serve anyway).
                        tracing::error!(
                            reason = %reason,
                            seq = frame.seq,
                            "extractor subprocess unavailable; halting"
                        );
                        halt_extractor(registry, stop);
                        return;
                    }
                    Err(ExtractError::Io(_)) => {
                        // Transient I/O error against the
                        // subprocess pipe (e.g. broken pipe on
                        // subprocess crash).  The
                        // SubprocessExtractor will respawn the
                        // child on the next call.  We DO NOT
                        // advance past this frame — the tail
                        // cursor has already advanced, so retrying
                        // means re-reading the next frame.  Per
                        // H-5: we cannot retry seq=N because
                        // tail.poll() already advanced past it.
                        // Instead, halt — silent gaps in the seq
                        // stream violate §11.4.
                        tracing::error!(
                            seq = frame.seq,
                            "extractor I/O error; cannot retry this frame, halting to avoid silent seq gap"
                        );
                        halt_extractor(registry, stop);
                        return;
                    }
                    Err(e) => {
                        // Other extractor errors (MalformedResponse,
                        // SequenceMismatch, TooManyEvents,
                        // EventPayloadOversize) indicate the
                        // subprocess is producing invalid output.
                        // Per H-5: skipping the frame would leave
                        // a gap in the seq stream.  Halt instead.
                        tracing::error!(
                            error = ?e,
                            seq = frame.seq,
                            "extractor protocol violation; halting to avoid silent seq gap"
                        );
                        halt_extractor(registry, stop);
                        return;
                    }
                }
            }
            Ok(PollOutcome::Pending { .. }) => {
                thread::sleep(poll_interval.min(EXTRACTOR_STOP_POLL_INTERVAL));
            }
            Err(TailError::BadMagic { .. })
            | Err(TailError::BadTrailer { .. })
            | Err(TailError::OversizeFrame { .. }) => {
                tracing::error!(
                    "log corruption detected; halting extractor loop and notifying subscribers"
                );
                halt_extractor(registry, stop);
                return;
            }
            Err(TailError::FileShrank { cursor, new_len }) => {
                tracing::error!(
                    cursor,
                    new_len,
                    "log file shrank under reader; halting (operator truncation / rotation)"
                );
                halt_extractor(registry, stop);
                return;
            }
            Err(TailError::Io { .. }) => {
                tracing::warn!("log I/O error; backing off");
                thread::sleep(poll_interval);
            }
        }
    }
}

/// Halt the extractor: notify all subscribers of shutdown AND
/// set the server stop flag so the acceptor stops taking new
/// connections.  Per H-2 audit finding.
fn halt_extractor(registry: &Arc<SubscriberRegistry>, stop: &Arc<AtomicBool>) {
    registry.broadcast_shutdown();
    stop.store(true, Ordering::Release);
}

/// Best-effort extraction of a panic payload's text content.
/// Matches `canon-host`'s `panic_message` for consistency.
fn panic_message(panic: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = panic.downcast_ref::<&'static str>() {
        (*s).to_string()
    } else if let Some(s) = panic.downcast_ref::<String>() {
        s.clone()
    } else if let Some(m) = panic.downcast_ref::<JoinTimeoutMarker>() {
        // `bounded_join` produces this on timeout; render via
        // Display rather than the opaque "non-string payload".
        m.to_string()
    } else {
        "<non-string panic payload>".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::extract::mock::{MockExtractor, MockResponse};
    use crate::frame::{encode_inbound, read_outbound, InboundFrame};
    use std::net::{SocketAddr, TcpStream};
    use std::sync::atomic::AtomicBool;
    use std::sync::Mutex;

    fn make_server_config(
        listener: TcpListener,
        log_path: &std::path::Path,
        extractor: Box<dyn Extractor>,
    ) -> ServerConfig {
        let mut cfg = ServerConfig::with_defaults(
            listener,
            TailReader::open(log_path).unwrap(),
            extractor,
            Arc::new(SubscriberRegistry::with_max_subscribers(64)),
            Arc::new(Mutex::new(EventCache::new(64).unwrap())),
        );
        cfg.send_queue_depth = 8;
        cfg.max_subscriber_lag = 100;
        cfg.max_frame_size = 64 * 1024;
        cfg.poll_interval = Duration::from_millis(20);
        cfg
    }

    fn empty_log() -> tempfile::NamedTempFile {
        tempfile::NamedTempFile::new().unwrap()
    }

    fn run_server_in_thread(
        cfg: ServerConfig,
    ) -> (Arc<AtomicBool>, SocketAddr, std::thread::JoinHandle<()>) {
        let addr = cfg.listener.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stop_clone = Arc::clone(&stop);
        let handle = std::thread::spawn(move || Server::new(cfg).run(stop_clone));
        // Give the server a moment to start up.
        std::thread::sleep(Duration::from_millis(50));
        (stop, addr, handle)
    }

    fn stop_server(stop: &Arc<AtomicBool>, handle: std::thread::JoinHandle<()>) {
        stop.store(true, Ordering::Relaxed);
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if handle.is_finished() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        handle.join().unwrap();
    }

    /// **Unit test for `bounded_join`: a wedged thread is
    /// abandoned after the timeout.**  Verifies the H-NEW-4
    /// audit fix.
    #[test]
    fn bounded_join_abandons_wedged_thread() {
        use std::sync::atomic::AtomicBool;
        let release = Arc::new(AtomicBool::new(false));
        let release_clone = Arc::clone(&release);
        let handle = std::thread::spawn(move || {
            // Wait until released — far longer than the join
            // timeout below.
            while !release_clone.load(Ordering::Acquire) {
                std::thread::sleep(Duration::from_millis(10));
            }
        });
        let start = Instant::now();
        let result = bounded_join(handle, Duration::from_millis(100));
        let elapsed = start.elapsed();
        // Should have abandoned after ~100ms.
        assert!(
            elapsed < Duration::from_millis(500),
            "bounded_join took {elapsed:?}, expected ~100ms"
        );
        match result {
            Err(_) => {} // expected: JoinTimeoutMarker (or panic)
            Ok(()) => panic!("expected timeout, got Ok"),
        }
        // Release the wedged thread so it cleans up.
        release.store(true, Ordering::Release);
    }

    /// **Unit test for `bounded_join`: a finished thread is
    /// joined cleanly.**
    #[test]
    fn bounded_join_returns_clean_for_finished_thread() {
        let handle = std::thread::spawn(|| {
            // Exits immediately.
        });
        // Give it a moment to finish.
        std::thread::sleep(Duration::from_millis(50));
        let result = bounded_join(handle, Duration::from_secs(1));
        assert!(result.is_ok(), "expected Ok, got {result:?}");
    }

    /// Empty log + subscribe → server starts, subscribe handshake
    /// accepted, no events delivered.  Verifies the acceptor +
    /// handshake plumbing.
    #[test]
    fn empty_log_subscribe_handshake() {
        let log = empty_log();
        let extractor = Box::new(MockExtractor::new());
        let listener = Server::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let cfg = make_server_config(listener, log.path(), extractor);
        let (stop, addr, handle) = run_server_in_thread(cfg);
        // Connect and send a SUBSCRIBE handshake.
        let mut stream = TcpStream::connect(addr).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let frame = InboundFrame::Subscribe { resume_from: 0 };
        let bytes = encode_inbound(&frame);
        std::io::Write::write_all(&mut stream, &bytes).unwrap();
        // We don't expect any events; the server doesn't write
        // anything until extractor produces events.  Verify
        // that the connection is alive by waiting a bit then
        // shutting down.
        std::thread::sleep(Duration::from_millis(100));
        stop_server(&stop, handle);
        // After shutdown, we should receive a ServerShutdown frame.
        let result = read_outbound(&mut stream, 64 * 1024);
        match result {
            // Server delivered the shutdown frame, OR closed the
            // socket before we could read it.  Both are acceptable;
            // the test asserts the server shut down cleanly, not
            // a specific frame.
            Ok(OutboundFrame::ServerShutdown { .. }) | Err(crate::frame::FrameError::Io(_)) => {}
            Ok(other) => panic!("expected ServerShutdown, got {other:?}"),
            Err(e) => panic!("unexpected error: {e:?}"),
        }
    }

    /// Single log frame appended AFTER subscribe → live subscriber
    /// receives the event.
    #[test]
    fn single_frame_event_delivered() {
        let log = empty_log();
        let log_path = log.path().to_path_buf();
        let extractor = Box::new(MockExtractor::new());
        extractor.set_responses(vec![MockResponse::Ok(vec![b"event-bytes".to_vec()])]);
        let listener = Server::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let cfg = make_server_config(listener, log.path(), extractor);
        let (stop, addr, handle) = run_server_in_thread(cfg);
        // Connect and subscribe FIRST so the subscriber is
        // registered before the event arrives.
        let mut stream = TcpStream::connect(addr).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let sub = InboundFrame::Subscribe { resume_from: 0 };
        std::io::Write::write_all(&mut stream, &encode_inbound(&sub)).unwrap();
        // Give the dispatch thread time to register the
        // subscriber and enter live mode.
        std::thread::sleep(Duration::from_millis(100));
        // Now append the log frame.  The extractor thread
        // (polling every 20 ms) will pick it up, run extract,
        // and broadcast.
        let mut log_file = std::fs::OpenOptions::new()
            .append(true)
            .open(&log_path)
            .unwrap();
        let payload = b"log-frame-payload".to_vec();
        std::io::Write::write_all(&mut log_file, &encode_test_frame(&payload)).unwrap();
        log_file.sync_data().unwrap();
        // Wait for the event to be delivered.
        let f = read_outbound(&mut stream, 64 * 1024).unwrap();
        match f {
            OutboundFrame::Event { seq, payload } => {
                assert_eq!(seq, 1);
                assert_eq!(payload, b"event-bytes");
            }
            other => panic!("expected Event, got {other:?}"),
        }
        stop_server(&stop, handle);
    }

    /// Resume-from-sequence delivers backfill from cache.
    #[test]
    fn resume_from_delivers_backfill() {
        let mut log = empty_log();
        // Write 3 log frames before starting the server.
        for i in 1..=3 {
            let payload = format!("frame-{i}").into_bytes();
            std::io::Write::write_all(log.as_file_mut(), &encode_test_frame(&payload)).unwrap();
        }
        log.as_file_mut().sync_data().unwrap();
        let extractor = Box::new(MockExtractor::new());
        extractor.set_responses(vec![
            MockResponse::Ok(vec![b"e1".to_vec()]),
            MockResponse::Ok(vec![b"e2".to_vec()]),
            MockResponse::Ok(vec![b"e3".to_vec()]),
        ]);
        let listener = Server::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let cfg = make_server_config(listener, log.path(), extractor);
        let (stop, addr, handle) = run_server_in_thread(cfg);
        // Give the extractor time to populate the cache.
        std::thread::sleep(Duration::from_millis(300));
        // Subscribe with resume_from=1; we should get events 2,3.
        let mut stream = TcpStream::connect(addr).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let sub = InboundFrame::Subscribe { resume_from: 1 };
        std::io::Write::write_all(&mut stream, &encode_inbound(&sub)).unwrap();
        let f1 = read_outbound(&mut stream, 64 * 1024).unwrap();
        let f2 = read_outbound(&mut stream, 64 * 1024).unwrap();
        match f1 {
            OutboundFrame::Event { seq, payload } => {
                assert_eq!(seq, 2);
                assert_eq!(payload, b"e2");
            }
            other => panic!("expected Event seq=2, got {other:?}"),
        }
        match f2 {
            OutboundFrame::Event { seq, payload } => {
                assert_eq!(seq, 3);
                assert_eq!(payload, b"e3");
            }
            other => panic!("expected Event seq=3, got {other:?}"),
        }
        stop_server(&stop, handle);
    }

    /// Resume from before cache window → Truncated frame.
    #[test]
    fn resume_before_cache_returns_truncated() {
        let mut log = empty_log();
        // Write 5 log frames; cache size will be smaller.
        for i in 1..=5 {
            let payload = format!("frame-{i}").into_bytes();
            std::io::Write::write_all(log.as_file_mut(), &encode_test_frame(&payload)).unwrap();
        }
        log.as_file_mut().sync_data().unwrap();
        let extractor = Box::new(MockExtractor::new());
        extractor.set_responses(vec![
            MockResponse::Ok(vec![b"e1".to_vec()]),
            MockResponse::Ok(vec![b"e2".to_vec()]),
            MockResponse::Ok(vec![b"e3".to_vec()]),
            MockResponse::Ok(vec![b"e4".to_vec()]),
            MockResponse::Ok(vec![b"e5".to_vec()]),
        ]);
        // Use a small cache (size 2) so seqs 1,2,3 are evicted.
        let listener = Server::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let mut cfg = make_server_config(listener, log.path(), extractor);
        cfg.cache = Arc::new(Mutex::new(EventCache::new(2).unwrap()));
        let (stop, addr, handle) = run_server_in_thread(cfg);
        std::thread::sleep(Duration::from_millis(300));
        // Subscribe with resume_from=1; we should get Truncated (oldest=4).
        let mut stream = TcpStream::connect(addr).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let sub = InboundFrame::Subscribe { resume_from: 1 };
        std::io::Write::write_all(&mut stream, &encode_inbound(&sub)).unwrap();
        let f = read_outbound(&mut stream, 64 * 1024).unwrap();
        match f {
            OutboundFrame::Truncated {
                oldest_available_seq,
            } => {
                assert_eq!(oldest_available_seq, 4); // events 4,5 still cached
            }
            other => panic!("expected Truncated, got {other:?}"),
        }
        stop_server(&stop, handle);
    }

    /// Invalid handshake → InvalidRequest then close.
    #[test]
    fn invalid_handshake_returns_invalid_request() {
        let log = empty_log();
        let extractor = Box::new(MockExtractor::new());
        let listener = Server::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let cfg = make_server_config(listener, log.path(), extractor);
        let (stop, addr, handle) = run_server_in_thread(cfg);
        let mut stream = TcpStream::connect(addr).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        // Send a single byte with an unknown kind tag.
        std::io::Write::write_all(&mut stream, &[0xff]).unwrap();
        // Read the InvalidRequest frame back.
        let f = read_outbound(&mut stream, 64 * 1024).unwrap();
        match f {
            OutboundFrame::InvalidRequest => {}
            other => panic!("expected InvalidRequest, got {other:?}"),
        }
        stop_server(&stop, handle);
    }

    /// Multiple subscribers each receive every event.
    #[test]
    fn multiple_subscribers_receive_events() {
        let log = empty_log();
        let log_path = log.path().to_path_buf();
        let extractor = Box::new(MockExtractor::new());
        extractor.set_responses(vec![MockResponse::Ok(vec![b"e1".to_vec()])]);
        let listener = Server::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let cfg = make_server_config(listener, log.path(), extractor);
        let (stop, addr, handle) = run_server_in_thread(cfg);
        // Two subscribers connect first so both are registered
        // before any event is produced.
        let make_sub = || {
            let mut s = TcpStream::connect(addr).unwrap();
            s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            let sub = InboundFrame::Subscribe { resume_from: 0 };
            std::io::Write::write_all(&mut s, &encode_inbound(&sub)).unwrap();
            s
        };
        let mut s1 = make_sub();
        let mut s2 = make_sub();
        std::thread::sleep(Duration::from_millis(100));
        // Now produce one log frame.
        let mut log_file = std::fs::OpenOptions::new()
            .append(true)
            .open(&log_path)
            .unwrap();
        std::io::Write::write_all(&mut log_file, &encode_test_frame(b"frame-1")).unwrap();
        log_file.sync_data().unwrap();
        // Wait for delivery.
        let f1 = read_outbound(&mut s1, 64 * 1024).unwrap();
        let f2 = read_outbound(&mut s2, 64 * 1024).unwrap();
        match f1 {
            OutboundFrame::Event { .. } => {}
            other => panic!("s1 expected Event, got {other:?}"),
        }
        match f2 {
            OutboundFrame::Event { .. } => {}
            other => panic!("s2 expected Event, got {other:?}"),
        }
        stop_server(&stop, handle);
    }

    /// Server shutdown delivers ServerShutdown frame to live subscribers.
    #[test]
    fn shutdown_delivers_shutdown_frame() {
        let log = empty_log();
        let extractor = Box::new(MockExtractor::new());
        let listener = Server::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let cfg = make_server_config(listener, log.path(), extractor);
        let (stop, addr, handle) = run_server_in_thread(cfg);
        // Subscribe.
        let mut stream = TcpStream::connect(addr).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let sub = InboundFrame::Subscribe { resume_from: 0 };
        std::io::Write::write_all(&mut stream, &encode_inbound(&sub)).unwrap();
        std::thread::sleep(Duration::from_millis(100));
        // Stop the server.
        stop_server(&stop, handle);
        // Read the ServerShutdown frame.
        let f = read_outbound(&mut stream, 64 * 1024).unwrap();
        match f {
            OutboundFrame::ServerShutdown { .. } => {}
            other => panic!("expected ServerShutdown, got {other:?}"),
        }
    }

    /// Test helper: encode a log frame matching Lean's
    /// `Runtime/LogFile.lean::encodeFrame`.
    fn encode_test_frame(payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&[
            crate::tail::FRAME_MAGIC_0,
            crate::tail::FRAME_MAGIC_1,
            crate::tail::FRAME_MAGIC_2,
            crate::tail::FRAME_MAGIC_3,
        ]);
        out.extend_from_slice(&(payload.len() as u64).to_le_bytes());
        out.extend_from_slice(payload);
        out.extend_from_slice(&crate::tail::fnv1a64(payload).to_le_bytes());
        out
    }
}

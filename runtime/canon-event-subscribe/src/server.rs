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
use crate::subscription::{DeliveryEvent, RegisterError, Subscriber, SubscriberRegistry};
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
    /// Tail-reader poll interval.
    pub poll_interval: Duration,
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
            poll_interval_ms = poll_interval.as_millis(),
            "canon-event-subscribe starting"
        );

        // 1. Spawn the extractor thread.
        let extractor_stop = Arc::clone(&stop);
        let extractor_cache = Arc::clone(&cache);
        let extractor_registry = Arc::clone(&registry);
        let extractor_handle = thread::Builder::new()
            .name("canon-event-subscribe-extractor".into())
            .spawn(move || {
                extractor_loop(
                    &mut tail,
                    extractor.as_ref(),
                    &extractor_cache,
                    &extractor_registry,
                    poll_interval,
                    &extractor_stop,
                );
            })
            .expect("spawn extractor thread");

        // 2. Run the acceptor loop in the current thread.  Each
        //    accepted connection spawns its own dispatch thread.
        let mut dispatch_handles: Vec<JoinHandle<()>> = Vec::new();
        let dispatch_cfg = DispatchConfig {
            send_queue_depth,
            max_subscriber_lag,
            max_frame_size,
        };
        accept_loop(
            &listener,
            &registry,
            &cache,
            dispatch_cfg,
            &mut dispatch_handles,
            &stop,
        );

        // 3. Stop flipped.  Signal the extractor to exit, then
        //    join it.
        if let Err(e) = extractor_handle.join() {
            tracing::warn!(error = ?e, "extractor thread panicked");
        }

        // 4. Broadcast shutdown to every live subscriber.  Each
        //    dispatch thread receives a Shutdown sentinel,
        //    emits its ServerShutdown frame, and closes.
        registry.broadcast_shutdown();

        // 5. Wait for dispatch threads to drain (bounded).
        wait_for_dispatch_drain(&mut dispatch_handles, SHUTDOWN_DRAIN_TIMEOUT);

        tracing::info!("canon-event-subscribe stopped");
    }
}

/// Block until every spawned dispatch thread joins, or
/// `timeout` elapses.
fn wait_for_dispatch_drain(handles: &mut Vec<JoinHandle<()>>, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while let Some(h) = handles.pop() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            // Drop the handle without joining; the underlying
            // thread keeps running until the OS reaps it.
            tracing::warn!("dispatch drain timeout; abandoning thread");
            break;
        }
        // We don't have a join-with-timeout API; just join
        // unconditionally.  Each dispatch thread bounds its own
        // wait on DISPATCH_POLL_INTERVAL so it converges
        // quickly to the disconnected state.
        if let Err(e) = h.join() {
            tracing::warn!(error = ?e, "dispatch thread panicked");
        }
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
}

/// The acceptor loop.  Owns the TCP listener; spawns dispatch
/// threads for each accepted connection.
fn accept_loop(
    listener: &TcpListener,
    registry: &Arc<SubscriberRegistry>,
    cache: &Arc<Mutex<EventCache>>,
    dispatch_cfg: DispatchConfig,
    dispatch_handles: &mut Vec<JoinHandle<()>>,
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
                tracing::info!(peer = %peer, "new subscriber connection");
                let cache_clone = Arc::clone(cache);
                let registry_clone = Arc::clone(registry);
                let stop_clone = Arc::clone(stop);
                let cfg = dispatch_cfg;
                let handle = thread::Builder::new()
                    .name(format!("canon-event-subscribe-dispatch-{peer}"))
                    .spawn(move || {
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
                    })
                    .expect("spawn dispatch thread");
                dispatch_handles.push(handle);
                // Reap any completed dispatch threads to keep the
                // handles vec bounded.
                dispatch_handles.retain(|h| !h.is_finished());
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                // No connection waiting; sleep a short interval
                // before re-polling the listener.
                thread::sleep(Duration::from_millis(50));
            }
            Err(e) => {
                tracing::warn!(error = ?e, "accept error; backing off");
                thread::sleep(backoff);
                backoff = (backoff * 2).min(backoff_max);
            }
        }
    }
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
    } = cfg;
    // Drop non-blocking mode for the handshake; read_inbound
    // expects a blocking reader.
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;

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
    loop {
        // Check the disconnect flag first (set by the broadcast
        // thread on lag-eviction).
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
        match rx.recv_timeout(DISPATCH_POLL_INTERVAL) {
            Ok(DeliveryEvent::Live(event)) => {
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
            Ok(DeliveryEvent::Shutdown) => {
                tracing::info!(peer = %peer, "subscriber received Shutdown sentinel");
                let frame = OutboundFrame::ServerShutdown {
                    last_delivered_seq: sub.last_delivered_seq(),
                };
                let _ = write_outbound(stream, &frame, max_frame_size);
                let _ = stream.shutdown(Shutdown::Both);
                return;
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                // No event in the last interval; re-check disconnect
                // and stop flags via the loop.  Also opportunistically
                // probe the TCP socket to detect peer close.
                if !is_connected(stream) {
                    tracing::info!(peer = %peer, "subscriber TCP socket closed");
                    sub.mark_disconnected();
                    return;
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                // Sender dropped; broadcast thread is gone (server
                // shutting down through an unhealthy path).
                tracing::info!(peer = %peer, "broadcast sender dropped");
                sub.mark_disconnected();
                let _ = stream.shutdown(Shutdown::Both);
                return;
            }
        }
    }
}

/// Probe the TCP stream for peer-close.  Sets a 1-millisecond
/// read timeout, attempts a 1-byte read into a discard buffer,
/// and restores the original timeout.
fn is_connected(stream: &TcpStream) -> bool {
    let prev_timeout = stream.read_timeout().ok().flatten();
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
        Ok(_) => true,  // unexpected data, but stream is alive
        Err(e)
            if e.kind() == std::io::ErrorKind::WouldBlock
                || e.kind() == std::io::ErrorKind::TimedOut =>
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
                        for event in events {
                            // Push to cache.
                            let mut cache_guard = cache.lock().unwrap_or_else(|p| p.into_inner());
                            if let Err(e) = cache_guard.push(event.clone()) {
                                tracing::warn!(
                                    error = ?e,
                                    seq = event.seq,
                                    "cache push failed; this is a bug — extractor produced an out-of-order seq"
                                );
                            }
                            drop(cache_guard);
                            // Broadcast.
                            let summary = registry.broadcast(event);
                            if summary.evicted > 0 {
                                tracing::warn!(
                                    evicted = summary.evicted,
                                    enqueued = summary.enqueued,
                                    lagging = summary.lagging,
                                    "subscribers evicted for lag"
                                );
                            }
                        }
                        if event_count == 0 {
                            tracing::trace!(seq = frame.seq, "log frame produced no events");
                        }
                    }
                    Err(ExtractError::SubprocessUnavailable { reason }) => {
                        tracing::error!(
                            reason = %reason,
                            seq = frame.seq,
                            "extractor subprocess unavailable; broadcasting shutdown"
                        );
                        registry.broadcast_shutdown();
                        return;
                    }
                    Err(e) => {
                        tracing::warn!(
                            error = ?e,
                            seq = frame.seq,
                            "extractor error on frame; skipping"
                        );
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
                registry.broadcast_shutdown();
                return;
            }
            Err(TailError::Io { .. }) => {
                tracing::warn!("log I/O error; backing off");
                thread::sleep(poll_interval);
            }
        }
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
        ServerConfig {
            listener,
            tail: TailReader::open(log_path).unwrap(),
            extractor,
            registry: Arc::new(SubscriberRegistry::with_max_subscribers(64)),
            cache: Arc::new(Mutex::new(EventCache::new(64).unwrap())),
            send_queue_depth: 8,
            max_subscriber_lag: 100,
            max_frame_size: 64 * 1024,
            poll_interval: Duration::from_millis(20),
        }
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

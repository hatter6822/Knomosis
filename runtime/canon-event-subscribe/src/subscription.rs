// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Per-subscriber state machine and bounded-lag policy.
//!
//! ## Why bounded
//!
//! A subscriber whose TCP socket is slower than the extractor's
//! event production rate would otherwise:
//!
//!   1. Accumulate events in the server's per-subscriber send queue.
//!   2. Drive the queue to consume unbounded memory.
//!   3. Eventually OOM the server.
//!
//! The bounded-lag policy disconnects slow subscribers cleanly
//! instead.  A subscriber whose queue overflows accumulates **lag
//! counter** units; when the counter exceeds the configured
//! threshold, the server sends a final `LagExceeded` frame and
//! closes the connection.  The subscriber can reconnect with a
//! `resume_from` to pick up where they left off (subject to the
//! backfill cache window).
//!
//! ## State machine
//!
//! Each subscriber starts in `Backfilling { events_remaining }`
//! state after a successful subscribe handshake.  The dispatch
//! thread drains the backfill queue first, then transitions to
//! `Live` state where new events arrive via the broadcast
//! channel.  At any time the subscriber may transition to
//! `LagExceeded` (the queue overflowed past the threshold) or
//! `Closed` (peer disconnected, server shutdown, etc.).
//!
//! ## Why per-subscriber state machine
//!
//! Each subscriber has independent backpressure semantics; one
//! slow subscriber must not delay events to fast subscribers.
//! Keeping state per-subscriber lets the server's broadcast
//! pipeline run lock-free in the steady state — each
//! subscriber's dispatch thread polls its own queue independently.

use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};

use crate::event_cache::CachedEvent;

/// Default per-subscriber send-queue depth.  Matches the plan
/// §RH-D.3 recommended default ("Bounded send queue (default 64)").
pub const DEFAULT_SEND_QUEUE_DEPTH: usize = 64;

/// Hard ceiling on operator-configurable send-queue depth.
pub const HARD_MAX_SEND_QUEUE_DEPTH: usize = 65_536;

/// Default lag threshold above which a subscriber is disconnected.
/// Matches the plan §RH-D.3 recommended default ("lag >
/// --max-subscriber-lag (default 256)").
pub const DEFAULT_MAX_SUBSCRIBER_LAG: u64 = 256;

/// Hard ceiling on operator-configurable lag threshold.
pub const HARD_MAX_SUBSCRIBER_LAG: u64 = 1_000_000;

/// A subscriber's life-cycle state.  Owned by the dispatch
/// thread; published to the broadcast thread atomically (via
/// the subscriber's atomic disconnect flag).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SubscriberState {
    /// The subscriber is backfilling from the cache (or about
    /// to start).  New live events go into the send queue but
    /// the dispatch thread drains the cache first.
    Backfilling,
    /// The subscriber is live: every new event from the
    /// extractor goes into the send queue, which the dispatch
    /// thread drains.
    Live,
    /// The subscriber's lag exceeded the threshold.  No more
    /// events will be sent; the dispatch thread sends a final
    /// `LagExceeded` frame and closes the socket.
    LagExceeded,
    /// The subscriber's TCP connection has been closed (peer
    /// disconnect, dispatch error, etc.).  Terminal state.
    Closed,
}

/// One event delivery handle from the broadcast thread to a
/// subscriber's dispatch thread.  Carries the (seq, payload)
/// pair plus a sentinel for the lag-eviction signal.
#[derive(Clone, Debug)]
pub enum DeliveryEvent {
    /// A new live event to send to the subscriber.
    Live(CachedEvent),
    /// The server is shutting down.  Dispatch thread should
    /// send a `ServerShutdown` frame and close.
    Shutdown,
}

/// Per-subscriber state used by the broadcast thread to decide
/// when to enqueue a new event (vs increment the lag counter).
/// Cloneable via `Arc`; the broadcast thread holds one clone,
/// the dispatch thread holds another.
pub struct Subscriber {
    /// Per-subscriber id (1-indexed within the server's lifetime).
    /// Used by tracing for per-subscriber diagnostics.
    pub id: u64,
    /// The bounded send queue.  Backed by `sync_channel` so
    /// `try_send` returns `Full` on overflow without blocking.
    sender: SyncSender<DeliveryEvent>,
    /// Lag counter: incremented each time `try_send` returns
    /// `Full`.  Reset to 0 each time a `try_send` succeeds
    /// (subscriber has caught up).
    lag: AtomicU64,
    /// Threshold above which the subscriber is disconnected.
    max_lag: u64,
    /// Last successfully-delivered sequence number.  Used for
    /// the `LagExceeded` / `ServerShutdown` diagnostic payload.
    last_delivered_seq: AtomicU64,
    /// Disconnect sentinel.  Once `true`, the broadcast thread
    /// stops trying to enqueue events.  Set by the dispatch
    /// thread on socket close or lag eviction.
    disconnected: std::sync::atomic::AtomicBool,
    /// Server-shutdown flag.  Set by `request_shutdown()`; checked
    /// by the dispatch thread in addition to the channel-borne
    /// `Shutdown` sentinel.  Decouples shutdown signalling from
    /// the bounded queue's capacity: a lagging subscriber whose
    /// queue is full will still observe shutdown via this flag
    /// without us needing to evict them.
    shutdown_requested: std::sync::atomic::AtomicBool,
}

impl std::fmt::Debug for Subscriber {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Subscriber")
            .field("id", &self.id)
            .field("max_lag", &self.max_lag)
            .field("lag", &self.lag.load(Ordering::Relaxed))
            .field(
                "last_delivered_seq",
                &self.last_delivered_seq.load(Ordering::Relaxed),
            )
            .field("disconnected", &self.disconnected.load(Ordering::Relaxed))
            .field(
                "shutdown_requested",
                &self.shutdown_requested.load(Ordering::Relaxed),
            )
            // `sender` is intentionally elided: a `SyncSender<DeliveryEvent>`
            // has no useful Debug representation, and including it would
            // expose channel-internal state without operator value.
            .finish_non_exhaustive()
    }
}

impl Subscriber {
    /// Construct a subscriber with the given queue depth + lag
    /// threshold.  Returns the subscriber handle (for the
    /// broadcast thread) plus the receiver (for the dispatch
    /// thread).
    ///
    /// Both `queue_depth` and `max_lag` are clamped to their
    /// hard ceilings.
    #[must_use]
    pub fn new(id: u64, queue_depth: usize, max_lag: u64) -> (Arc<Self>, Receiver<DeliveryEvent>) {
        let queue_depth = queue_depth.clamp(1, HARD_MAX_SEND_QUEUE_DEPTH);
        let max_lag = max_lag.min(HARD_MAX_SUBSCRIBER_LAG);
        let (sender, receiver) = sync_channel(queue_depth);
        let sub = Arc::new(Self {
            id,
            sender,
            lag: AtomicU64::new(0),
            max_lag,
            last_delivered_seq: AtomicU64::new(0),
            disconnected: std::sync::atomic::AtomicBool::new(false),
            shutdown_requested: std::sync::atomic::AtomicBool::new(false),
        });
        (sub, receiver)
    }

    /// Subscriber's id.
    #[must_use]
    pub fn id(&self) -> u64 {
        self.id
    }

    /// True iff the subscriber has been marked disconnected.
    #[must_use]
    pub fn is_disconnected(&self) -> bool {
        self.disconnected.load(Ordering::Acquire)
    }

    /// Mark the subscriber as disconnected.  Idempotent.
    pub fn mark_disconnected(&self) {
        self.disconnected.store(true, Ordering::Release);
    }

    /// Current lag counter value.
    #[must_use]
    pub fn lag(&self) -> u64 {
        self.lag.load(Ordering::Relaxed)
    }

    /// Last successfully-delivered sequence number.
    #[must_use]
    pub fn last_delivered_seq(&self) -> u64 {
        self.last_delivered_seq.load(Ordering::Relaxed)
    }

    /// Try to enqueue a new event for this subscriber.
    ///
    /// Returns:
    ///   * [`EnqueueOutcome::Enqueued`]: the event was placed in
    ///     the queue.  Lag counter reset to 0 (subscriber caught
    ///     up to live).
    ///   * [`EnqueueOutcome::Lagging`]: the queue is full.  Lag
    ///     counter incremented; if it now exceeds `max_lag`,
    ///     the subscriber is marked for eviction and a
    ///     `LagExceeded` flag is set.
    ///   * [`EnqueueOutcome::Disconnected`]: the subscriber is
    ///     already disconnected (either peer closed or lag-
    ///     evicted).  No-op; broadcast thread should drop the
    ///     event for this subscriber.
    pub fn try_enqueue(&self, event: CachedEvent) -> EnqueueOutcome {
        if self.is_disconnected() {
            return EnqueueOutcome::Disconnected;
        }
        match self.sender.try_send(DeliveryEvent::Live(event)) {
            Ok(()) => {
                // Reset lag counter; the subscriber kept up.
                self.lag.store(0, Ordering::Relaxed);
                EnqueueOutcome::Enqueued
            }
            Err(TrySendError::Full(_)) => {
                // Increment lag.  If it now exceeds max_lag, the
                // subscriber is evicted.  We do NOT close the socket
                // here — that happens in the dispatch thread via a
                // separate Shutdown / LagExceeded path.  We just
                // signal it via the atomic + a final Shutdown frame.
                //
                // M-8 audit fix: use `AcqRel` so the lag value
                // observed alongside `mark_disconnected`'s Release
                // store is consistent for a dispatch thread that
                // sees `disconnected = true` and then reads `lag`
                // for diagnostics.
                let new_lag = self.lag.fetch_add(1, Ordering::AcqRel) + 1;
                if new_lag > self.max_lag {
                    // Mark disconnected so no further enqueues happen.
                    // The dispatch thread will detect the disconnect
                    // and emit the LagExceeded frame.
                    self.mark_disconnected();
                    EnqueueOutcome::LagExceeded
                } else {
                    EnqueueOutcome::Lagging { lag: new_lag }
                }
            }
            Err(TrySendError::Disconnected(_)) => {
                // The dispatch thread closed its receiver; mark
                // disconnected so the broadcast thread stops
                // trying.
                self.mark_disconnected();
                EnqueueOutcome::Disconnected
            }
        }
    }

    /// Request server-side shutdown for this subscriber.  Sets
    /// the `shutdown_requested` flag AND best-effort enqueues a
    /// [`DeliveryEvent::Shutdown`] sentinel into the channel.
    ///
    /// The dispatch thread observes shutdown via *either*:
    ///   * the flag (preferred — works even when the channel is
    ///     full because the subscriber is lagging), OR
    ///   * the sentinel (faster wake-up when the channel has
    ///     headroom — the dispatch thread blocks on `recv_timeout`
    ///     so a sentinel arrival unblocks it immediately).
    ///
    /// This decouples shutdown signalling from queue capacity: a
    /// laggy subscriber whose channel is full at shutdown time
    /// still receives a `ServerShutdown` frame on the wire (via
    /// the dispatch thread's poll-on-timeout path), rather than
    /// being silently mis-evicted with `LagExceeded`.
    ///
    /// Returns:
    ///   * `Enqueued` — the sentinel was successfully enqueued.
    ///   * `Lagging` — the channel was full; the flag was set
    ///     and the dispatch thread will pick up the shutdown on
    ///     its next poll (bounded by `DISPATCH_POLL_INTERVAL`).
    ///     The carried `lag` is the current lag-counter value
    ///     for diagnostics only — we do NOT increment the
    ///     counter (this is shutdown traffic, not application
    ///     traffic).
    ///   * `Disconnected` — the subscriber was already gone
    ///     (peer closed, lag-evicted, etc).
    pub fn request_shutdown(&self) -> EnqueueOutcome {
        if self.is_disconnected() {
            return EnqueueOutcome::Disconnected;
        }
        // Set the flag FIRST so that even if the try_send below
        // races with the dispatch thread observing the channel,
        // the flag will guide the next dispatch iteration to
        // emit `ServerShutdown`.
        self.shutdown_requested.store(true, Ordering::Release);
        match self.sender.try_send(DeliveryEvent::Shutdown) {
            Ok(()) => EnqueueOutcome::Enqueued,
            Err(TrySendError::Full(_)) => {
                // Channel full; flag is set, dispatch will pick it
                // up on its next poll.  Do NOT mark disconnected —
                // the subscriber is still alive on the wire.
                EnqueueOutcome::Lagging {
                    lag: self.lag.load(Ordering::Relaxed),
                }
            }
            Err(TrySendError::Disconnected(_)) => {
                // Dispatch thread's receiver is dropped — they're
                // already exiting.  Idempotent.
                self.mark_disconnected();
                EnqueueOutcome::Disconnected
            }
        }
    }

    /// True iff the server has requested shutdown for this
    /// subscriber.  Set by `request_shutdown()`; checked by the
    /// dispatch thread.
    #[must_use]
    pub fn is_shutdown_requested(&self) -> bool {
        self.shutdown_requested.load(Ordering::Acquire)
    }

    /// Record that a sequence was successfully delivered.  Used
    /// by the dispatch thread to update the diagnostic field.
    /// Single-writer (dispatch thread); `Relaxed` ordering is
    /// sufficient.
    pub fn record_delivered(&self, seq: u64) {
        self.last_delivered_seq.store(seq, Ordering::Relaxed);
    }
}

/// Outcome of [`Subscriber::try_enqueue`].
#[derive(Debug, Eq, PartialEq)]
pub enum EnqueueOutcome {
    /// Event was placed in the queue; subscriber is keeping up.
    Enqueued,
    /// Queue is full; lag counter incremented but still within
    /// threshold.  Carries the new lag count for diagnostics.
    Lagging {
        /// Updated lag counter.
        lag: u64,
    },
    /// Lag exceeded threshold; subscriber marked disconnected.
    /// Dispatch thread will emit final frame and close.
    LagExceeded,
    /// Subscriber was already disconnected; no-op.
    Disconnected,
}

/// Set of active subscribers.  Owned by the server; the broadcast
/// thread holds an `Arc<Mutex<>>` clone.
///
/// **Locking discipline.**  The mutex is held only briefly:
///   * On `register`: insert a new Subscriber clone.
///   * On `broadcast`: take a snapshot of the Arc<Subscriber>
///     clones, release the lock, then call `try_enqueue` on
///     each without holding the lock.
///   * On `unregister`: remove a disconnected subscriber.
///
/// Holding the mutex during `try_enqueue` would serialise
/// enqueues across subscribers (defeating the purpose of the
/// per-subscriber bounded queues).
#[derive(Debug, Default)]
pub struct SubscriberRegistry {
    subscribers: Mutex<Vec<Arc<Subscriber>>>,
    /// Monotonically increasing subscriber id counter.
    next_id: AtomicU64,
    /// Cap on simultaneous subscribers.  `0` means unlimited
    /// (operator's choice; the default config sets a reasonable
    /// upper bound).
    max_subscribers: AtomicUsize,
}

impl SubscriberRegistry {
    /// Construct an empty registry with no cap on subscribers.
    /// Use [`Self::with_max_subscribers`] to set a cap.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the cap on simultaneous subscribers.  `0` means
    /// unlimited.  Mutating via interior atomic so the registry
    /// remains shareable behind `Arc`.
    pub fn set_max_subscribers(&self, max: usize) {
        self.max_subscribers.store(max, Ordering::Relaxed);
    }

    /// Construct a registry pre-configured with a subscriber cap.
    #[must_use]
    pub fn with_max_subscribers(max: usize) -> Self {
        let r = Self::default();
        r.set_max_subscribers(max);
        r
    }

    /// Allocate a new subscriber id and register it.
    ///
    /// Returns `(subscriber_handle, receiver)`.  The
    /// `subscriber_handle` is cloned and stored in the registry;
    /// the `receiver` is consumed by the dispatch thread.
    ///
    /// If the registry's subscriber cap is reached, returns
    /// [`RegisterError::AtCapacity`].
    ///
    /// # Errors
    ///
    /// See [`RegisterError`].
    pub fn register(
        &self,
        queue_depth: usize,
        max_lag: u64,
    ) -> Result<(Arc<Subscriber>, Receiver<DeliveryEvent>), RegisterError> {
        let mut subs = self.subscribers.lock().unwrap_or_else(|p| p.into_inner());
        let max = self.max_subscribers.load(Ordering::Relaxed);
        if max != 0 && subs.len() >= max {
            return Err(RegisterError::AtCapacity {
                active: subs.len(),
                max,
            });
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        let (sub, rx) = Subscriber::new(id, queue_depth, max_lag);
        subs.push(Arc::clone(&sub));
        Ok((sub, rx))
    }

    /// Remove a subscriber from the active set.  Called by the
    /// dispatch thread when it finishes (peer disconnect, lag
    /// eviction, etc.).  Idempotent.
    pub fn unregister(&self, sub: &Subscriber) {
        let mut subs = self.subscribers.lock().unwrap_or_else(|p| p.into_inner());
        subs.retain(|s| s.id != sub.id);
    }

    /// Number of registered subscribers.
    #[must_use]
    pub fn len(&self) -> usize {
        self.subscribers
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .len()
    }

    /// True iff no subscribers are registered.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.subscribers
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .is_empty()
    }

    /// Snapshot of every active subscriber.  Acquires the
    /// registry lock briefly; the returned vector is independent
    /// of the registry so the caller can iterate without
    /// holding the lock.
    #[must_use]
    pub fn snapshot(&self) -> Vec<Arc<Subscriber>> {
        self.subscribers
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
    }

    /// Broadcast an event to all registered subscribers.
    ///
    /// Returns a count of `(enqueued, lagging, evicted,
    /// disconnected)` for diagnostics.  The caller is the
    /// extractor thread.
    ///
    /// This convenience wrapper takes a fresh snapshot per call.
    /// For multi-event batches use [`Self::broadcast_to_snapshot`]
    /// with a pre-computed snapshot to ensure all events in the
    /// batch are delivered to the SAME set of subscribers
    /// (avoiding the C-3R-1 audit race where a subscriber
    /// registering mid-batch would receive only the tail of a
    /// multi-event-per-frame batch).
    pub fn broadcast(&self, event: CachedEvent) -> BroadcastSummary {
        let snapshot = self.snapshot();
        Self::broadcast_to_snapshot(&snapshot, event)
    }

    /// Broadcast `event` to a fixed snapshot of subscribers.
    /// Per C-3R-1 audit fix: the extractor's multi-event batch
    /// path uses this with a single snapshot taken at the
    /// START of the batch, so a subscriber registering DURING
    /// the batch is uniformly excluded from ALL events in the
    /// batch (and will pick them up via the cache backfill on
    /// the next handshake, or skip them entirely if they
    /// requested resume_from=0 — live tail).
    ///
    /// Without this discipline, the broadcast-per-event pattern
    /// would let a mid-batch subscriber receive event[1] +
    /// event[2] without event[0], creating an incomplete-batch
    /// delivery that the wire-protocol's resume mechanism
    /// cannot detect (events share a seq).
    pub fn broadcast_to_snapshot(
        snapshot: &[Arc<Subscriber>],
        event: CachedEvent,
    ) -> BroadcastSummary {
        let mut enqueued = 0usize;
        let mut lagging = 0usize;
        let mut evicted = 0usize;
        let mut disconnected = 0usize;
        for sub in snapshot {
            match sub.try_enqueue(event.clone()) {
                EnqueueOutcome::Enqueued => enqueued += 1,
                EnqueueOutcome::Lagging { .. } => lagging += 1,
                EnqueueOutcome::LagExceeded => evicted += 1,
                EnqueueOutcome::Disconnected => disconnected += 1,
            }
        }
        BroadcastSummary {
            enqueued,
            lagging,
            evicted,
            disconnected,
        }
    }

    /// Request shutdown for every subscriber.  Used by the
    /// server's shutdown path so each dispatch thread can emit a
    /// `ServerShutdown` frame before closing.
    ///
    /// Per [`Subscriber::request_shutdown`], this both sets the
    /// per-subscriber `shutdown_requested` flag AND best-effort
    /// enqueues a sentinel.  Even a laggy subscriber (full
    /// channel) will observe shutdown via the flag on its next
    /// dispatch poll.
    pub fn broadcast_shutdown(&self) {
        let snapshot = self.snapshot();
        for sub in &snapshot {
            let _ = sub.request_shutdown();
        }
    }
}

/// Diagnostic counts returned by [`SubscriberRegistry::broadcast`].
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct BroadcastSummary {
    /// Subscribers who accepted the event.
    pub enqueued: usize,
    /// Subscribers whose queue was full (lag incremented but
    /// still within threshold).
    pub lagging: usize,
    /// Subscribers who exceeded the lag threshold (evicted).
    pub evicted: usize,
    /// Subscribers already disconnected (no-op).
    pub disconnected: usize,
}

/// Errors from [`SubscriberRegistry::register`].
#[derive(Debug, thiserror::Error)]
pub enum RegisterError {
    /// The subscriber cap has been reached; refuse the new
    /// connection.
    #[error("at capacity: {active} subscribers active, max {max}")]
    AtCapacity {
        /// Currently active subscribers.
        active: usize,
        /// Configured cap.
        max: usize,
    },
}

#[cfg(test)]
mod tests {
    use super::{
        BroadcastSummary, DeliveryEvent, EnqueueOutcome, RegisterError, Subscriber,
        SubscriberRegistry, DEFAULT_MAX_SUBSCRIBER_LAG, DEFAULT_SEND_QUEUE_DEPTH,
        HARD_MAX_SEND_QUEUE_DEPTH, HARD_MAX_SUBSCRIBER_LAG,
    };
    use crate::event_cache::CachedEvent;
    use std::sync::Arc;

    fn make_event(seq: u64) -> CachedEvent {
        CachedEvent {
            seq,
            payload: format!("event-{seq}").into_bytes(),
        }
    }

    /// Default constants are documented values.
    #[test]
    fn defaults_stable() {
        assert_eq!(DEFAULT_SEND_QUEUE_DEPTH, 64);
        assert_eq!(DEFAULT_MAX_SUBSCRIBER_LAG, 256);
        assert_eq!(HARD_MAX_SEND_QUEUE_DEPTH, 65_536);
        assert_eq!(HARD_MAX_SUBSCRIBER_LAG, 1_000_000);
    }

    /// `Subscriber::new` returns a working sender/receiver pair.
    #[test]
    fn subscriber_basic_enqueue() {
        let (sub, rx) = Subscriber::new(1, 8, 100);
        assert_eq!(sub.id(), 1);
        assert!(!sub.is_disconnected());
        match sub.try_enqueue(make_event(1)) {
            EnqueueOutcome::Enqueued => {}
            other => panic!("expected Enqueued, got {other:?}"),
        }
        match rx.try_recv().unwrap() {
            DeliveryEvent::Live(e) => assert_eq!(e.seq, 1),
            DeliveryEvent::Shutdown => panic!("expected Live event"),
        }
    }

    /// Queue full → Lagging.
    #[test]
    fn subscriber_lagging_when_full() {
        let (sub, _rx) = Subscriber::new(1, 2, 10);
        // Fill the queue.
        for seq in 1..=2 {
            match sub.try_enqueue(make_event(seq)) {
                EnqueueOutcome::Enqueued => {}
                other => panic!("expected Enqueued (seq {seq}), got {other:?}"),
            }
        }
        // Next try: Lagging with lag=1.
        match sub.try_enqueue(make_event(3)) {
            EnqueueOutcome::Lagging { lag } => assert_eq!(lag, 1),
            other => panic!("expected Lagging, got {other:?}"),
        }
        // Another: Lagging with lag=2.
        match sub.try_enqueue(make_event(4)) {
            EnqueueOutcome::Lagging { lag } => assert_eq!(lag, 2),
            other => panic!("expected Lagging, got {other:?}"),
        }
    }

    /// Lag exceeding threshold → LagExceeded; subsequent calls →
    /// Disconnected.
    #[test]
    fn lag_threshold_triggers_eviction() {
        let (sub, _rx) = Subscriber::new(1, 1, 2);
        // Fill the queue (1 slot).
        sub.try_enqueue(make_event(1));
        // Lag #1 → Lagging.
        match sub.try_enqueue(make_event(2)) {
            EnqueueOutcome::Lagging { lag } => assert_eq!(lag, 1),
            other => panic!("expected Lagging, got {other:?}"),
        }
        // Lag #2 → Lagging.
        match sub.try_enqueue(make_event(3)) {
            EnqueueOutcome::Lagging { lag } => assert_eq!(lag, 2),
            other => panic!("expected Lagging, got {other:?}"),
        }
        // Lag #3 → LagExceeded (lag > max_lag = 2).
        match sub.try_enqueue(make_event(4)) {
            EnqueueOutcome::LagExceeded => {}
            other => panic!("expected LagExceeded, got {other:?}"),
        }
        assert!(sub.is_disconnected());
        // Further attempts: Disconnected.
        match sub.try_enqueue(make_event(5)) {
            EnqueueOutcome::Disconnected => {}
            other => panic!("expected Disconnected, got {other:?}"),
        }
    }

    /// Catching up: a successful enqueue resets the lag counter.
    #[test]
    fn lag_reset_on_successful_enqueue() {
        let (sub, rx) = Subscriber::new(1, 2, 100);
        sub.try_enqueue(make_event(1));
        sub.try_enqueue(make_event(2));
        // Lag #1.
        match sub.try_enqueue(make_event(3)) {
            EnqueueOutcome::Lagging { lag } => assert_eq!(lag, 1),
            _ => panic!("expected Lagging"),
        }
        assert_eq!(sub.lag(), 1);
        // Subscriber drains one event.
        rx.try_recv().unwrap();
        // Next enqueue succeeds; lag resets.
        match sub.try_enqueue(make_event(4)) {
            EnqueueOutcome::Enqueued => {}
            other => panic!("expected Enqueued, got {other:?}"),
        }
        assert_eq!(sub.lag(), 0);
    }

    /// Dispatch closes its receiver → Disconnected.
    #[test]
    fn disconnect_propagates() {
        let (sub, rx) = Subscriber::new(1, 8, 10);
        drop(rx);
        match sub.try_enqueue(make_event(1)) {
            EnqueueOutcome::Disconnected => {}
            other => panic!("expected Disconnected, got {other:?}"),
        }
        assert!(sub.is_disconnected());
    }

    /// `record_delivered` updates the diagnostic field.
    #[test]
    fn record_delivered_updates_field() {
        let (sub, _rx) = Subscriber::new(1, 8, 10);
        assert_eq!(sub.last_delivered_seq(), 0);
        sub.record_delivered(42);
        assert_eq!(sub.last_delivered_seq(), 42);
        sub.record_delivered(100);
        assert_eq!(sub.last_delivered_seq(), 100);
    }

    /// `request_shutdown` sets the flag AND sends the sentinel
    /// when the channel has space.
    #[test]
    fn request_shutdown_sets_flag_and_enqueues() {
        let (sub, rx) = Subscriber::new(1, 8, 10);
        assert!(!sub.is_shutdown_requested());
        match sub.request_shutdown() {
            EnqueueOutcome::Enqueued => {}
            other => panic!("expected Enqueued, got {other:?}"),
        }
        assert!(sub.is_shutdown_requested());
        match rx.try_recv().unwrap() {
            DeliveryEvent::Shutdown => {}
            DeliveryEvent::Live(_) => panic!("expected Shutdown"),
        }
    }

    /// `request_shutdown` on a full channel still sets the flag
    /// (the load-bearing audit fix: a laggy subscriber must
    /// still observe shutdown, not be silently mis-evicted).
    #[test]
    fn request_shutdown_full_channel_sets_flag_only() {
        let (sub, _rx) = Subscriber::new(1, 1, 100);
        // Fill the channel.
        sub.try_enqueue(make_event(1));
        // Now the channel is full.  request_shutdown should
        // return Lagging (not Disconnected), set the flag, and
        // NOT mark the subscriber disconnected.
        match sub.request_shutdown() {
            EnqueueOutcome::Lagging { .. } => {}
            other => panic!("expected Lagging, got {other:?}"),
        }
        assert!(sub.is_shutdown_requested());
        assert!(!sub.is_disconnected());
    }

    /// `request_shutdown` after disconnect is a no-op.
    #[test]
    fn request_shutdown_after_disconnect_no_op() {
        let (sub, rx) = Subscriber::new(1, 8, 10);
        drop(rx);
        sub.mark_disconnected();
        match sub.request_shutdown() {
            EnqueueOutcome::Disconnected => {}
            other => panic!("expected Disconnected, got {other:?}"),
        }
    }

    /// `request_shutdown` on a dropped receiver marks disconnected.
    #[test]
    fn request_shutdown_dropped_receiver_marks_disconnected() {
        let (sub, rx) = Subscriber::new(1, 8, 10);
        drop(rx);
        match sub.request_shutdown() {
            EnqueueOutcome::Disconnected => {}
            other => panic!("expected Disconnected, got {other:?}"),
        }
        assert!(sub.is_disconnected());
    }

    /// Queue-depth clamping.
    #[test]
    fn queue_depth_clamped() {
        let (_sub, _rx) = Subscriber::new(1, 0, 10);
        // Cap-to-1 clamping yields a working capacity-1 sender.
        let (sub2, _rx2) = Subscriber::new(1, usize::MAX, 10);
        // Doesn't panic; that's enough to assert.
        let _ = sub2;
    }

    /// Max-lag clamping.
    #[test]
    fn max_lag_clamped() {
        // u64::MAX clamps to HARD_MAX_SUBSCRIBER_LAG.  No panic.
        let (sub, _rx) = Subscriber::new(1, 8, u64::MAX);
        assert_eq!(sub.max_lag, HARD_MAX_SUBSCRIBER_LAG);
    }

    /// Registry empty by default.
    #[test]
    fn registry_default_empty() {
        let reg = SubscriberRegistry::new();
        assert!(reg.is_empty());
        assert_eq!(reg.len(), 0);
    }

    /// Registry register + unregister.
    #[test]
    fn registry_register_unregister() {
        let reg = SubscriberRegistry::new();
        let (sub1, _rx1) = reg.register(8, 100).unwrap();
        assert_eq!(reg.len(), 1);
        let (sub2, _rx2) = reg.register(8, 100).unwrap();
        assert_eq!(reg.len(), 2);
        reg.unregister(&sub1);
        assert_eq!(reg.len(), 1);
        reg.unregister(&sub2);
        assert!(reg.is_empty());
    }

    /// Registry: distinct ids.
    #[test]
    fn registry_distinct_ids() {
        let reg = SubscriberRegistry::new();
        let (sub1, _rx1) = reg.register(8, 100).unwrap();
        let (sub2, _rx2) = reg.register(8, 100).unwrap();
        assert_ne!(sub1.id(), sub2.id());
    }

    /// Registry: capacity cap is enforced.
    #[test]
    fn registry_capacity_cap() {
        let reg = SubscriberRegistry::with_max_subscribers(2);
        let (_sub1, _rx1) = reg.register(8, 100).unwrap();
        let (_sub2, _rx2) = reg.register(8, 100).unwrap();
        match reg.register(8, 100) {
            Err(RegisterError::AtCapacity { active, max }) => {
                assert_eq!(active, 2);
                assert_eq!(max, 2);
            }
            other => panic!("expected AtCapacity, got {other:?}"),
        }
    }

    /// Registry: `max_subscribers = 0` means unlimited.
    #[test]
    fn registry_unlimited_when_zero() {
        let reg = SubscriberRegistry::new();
        for _ in 0..10 {
            let _r = reg.register(8, 100).unwrap();
        }
        assert_eq!(reg.len(), 10);
    }

    /// **C-3R-1 audit regression: `broadcast_to_snapshot`
    /// delivers ONLY to subscribers in the snapshot, never to
    /// subscribers added afterwards.**
    ///
    /// Deterministic unit-level test of the snapshot-atomicity
    /// invariant.  Without this guarantee, a subscriber
    /// registering between broadcasts of a multi-event batch
    /// would receive only the tail of the batch (silent
    /// partial-batch delivery).
    #[test]
    fn broadcast_to_snapshot_excludes_post_snapshot_registrants() {
        let reg = SubscriberRegistry::new();
        // Register subscriber A FIRST.
        let (sub_a, rx_a) = reg.register(8, 100).unwrap();
        // Take a snapshot at this point.  A is in it.
        let snapshot = reg.snapshot();
        assert_eq!(snapshot.len(), 1);
        assert_eq!(snapshot[0].id(), sub_a.id());
        // Now register subscriber B AFTER the snapshot.
        let (sub_b, rx_b) = reg.register(8, 100).unwrap();
        assert_eq!(reg.len(), 2);
        // Broadcast event to the snapshot.  Only A should get it.
        let summary = SubscriberRegistry::broadcast_to_snapshot(&snapshot, make_event(42));
        assert_eq!(summary.enqueued, 1);
        // A receives.
        match rx_a.try_recv().unwrap() {
            DeliveryEvent::Live(e) => assert_eq!(e.seq, 42),
            DeliveryEvent::Shutdown => panic!("expected Live"),
        }
        // B did NOT receive (was not in snapshot).
        match rx_b.try_recv() {
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
            other => panic!("B should not have received any event; got {other:?}"),
        }
        let _ = sub_b;
    }

    /// **C-3R-1 audit regression: multi-event batch via
    /// `broadcast_to_snapshot` delivers all events to all
    /// snapshot subscribers, with no leakage to post-snapshot
    /// subscribers.**
    ///
    /// This simulates the extractor's Phase B: snapshot, then
    /// broadcast each event of a multi-event batch using the
    /// SAME snapshot.  A subscriber registering between
    /// snapshot and the last broadcast must receive ZERO
    /// events from this batch (uniform exclusion).
    #[test]
    fn broadcast_to_snapshot_multi_event_uniform_exclusion() {
        let reg = SubscriberRegistry::new();
        let (sub_a, rx_a) = reg.register(8, 100).unwrap();
        let snapshot = reg.snapshot();
        // Register B during the "batch broadcast window".
        let (sub_b, rx_b) = reg.register(8, 100).unwrap();
        // Broadcast 3 events at seq=5 using the SNAPSHOT.
        let events = [
            CachedEvent {
                seq: 5,
                payload: b"event-a".to_vec(),
            },
            CachedEvent {
                seq: 5,
                payload: b"event-b".to_vec(),
            },
            CachedEvent {
                seq: 5,
                payload: b"event-c".to_vec(),
            },
        ];
        for ev in events.iter().cloned() {
            SubscriberRegistry::broadcast_to_snapshot(&snapshot, ev);
        }
        // A receives all 3 events at seq=5.
        let mut a_count = 0;
        while let Ok(d) = rx_a.try_recv() {
            match d {
                DeliveryEvent::Live(e) => {
                    assert_eq!(e.seq, 5);
                    a_count += 1;
                }
                DeliveryEvent::Shutdown => break,
            }
        }
        assert_eq!(a_count, 3, "A should receive all 3 events of the batch");
        // B receives ZERO events from this batch.
        let mut b_count = 0;
        while rx_b.try_recv().is_ok() {
            b_count += 1;
        }
        assert_eq!(
            b_count, 0,
            "B should receive ZERO events (not in snapshot); got {b_count}"
        );
        let _ = sub_a;
        let _ = sub_b;
    }

    /// Registry: broadcast enqueues to all live subscribers.
    #[test]
    fn registry_broadcast_enqueues_all() {
        let reg = SubscriberRegistry::new();
        let (sub1, rx1) = reg.register(8, 100).unwrap();
        let (sub2, rx2) = reg.register(8, 100).unwrap();
        let summary = reg.broadcast(make_event(1));
        assert_eq!(
            summary,
            BroadcastSummary {
                enqueued: 2,
                lagging: 0,
                evicted: 0,
                disconnected: 0,
            }
        );
        let _ = rx1.try_recv().unwrap();
        let _ = rx2.try_recv().unwrap();
        let _ = sub1;
        let _ = sub2;
    }

    /// Registry: broadcast skips disconnected subscribers.
    #[test]
    fn registry_broadcast_skips_disconnected() {
        let reg = SubscriberRegistry::new();
        let (sub1, _rx1) = reg.register(8, 100).unwrap();
        let (sub2, _rx2) = reg.register(8, 100).unwrap();
        sub2.mark_disconnected();
        let summary = reg.broadcast(make_event(1));
        assert_eq!(summary.enqueued, 1);
        assert_eq!(summary.disconnected, 1);
        let _ = sub1;
    }

    /// Registry: broadcast counts lagging subscribers separately.
    #[test]
    fn registry_broadcast_counts_lagging() {
        let reg = SubscriberRegistry::new();
        let (_sub1, _rx1) = reg.register(1, 100).unwrap();
        // Fill subscriber 1's queue.
        reg.broadcast(make_event(1));
        let summary = reg.broadcast(make_event(2));
        // Subscriber 1 now lagging.
        assert_eq!(summary.lagging, 1);
        assert_eq!(summary.enqueued, 0);
    }

    /// Registry: `broadcast_shutdown` sets the flag on every
    /// subscriber AND best-effort enqueues the sentinel when
    /// the channel has space.
    #[test]
    fn registry_broadcast_shutdown() {
        let reg = SubscriberRegistry::new();
        let (sub1, rx1) = reg.register(8, 100).unwrap();
        let (sub2, rx2) = reg.register(8, 100).unwrap();
        reg.broadcast_shutdown();
        assert!(sub1.is_shutdown_requested());
        assert!(sub2.is_shutdown_requested());
        // Each receiver should get a Shutdown frame (channels
        // have space).
        match rx1.try_recv().unwrap() {
            DeliveryEvent::Shutdown => {}
            DeliveryEvent::Live(_) => panic!("expected Shutdown"),
        }
        match rx2.try_recv().unwrap() {
            DeliveryEvent::Shutdown => {}
            DeliveryEvent::Live(_) => panic!("expected Shutdown"),
        }
    }

    /// Registry: `broadcast_shutdown` on a laggy subscriber
    /// (full channel) sets the flag without evicting.  Audit fix:
    /// the prior `enqueue_shutdown` would have mis-marked this
    /// subscriber as Disconnected, losing the ServerShutdown
    /// wire signal.
    #[test]
    fn registry_broadcast_shutdown_laggy_subscriber_keeps_alive() {
        let reg = SubscriberRegistry::new();
        let (sub, _rx) = reg.register(1, 100).unwrap();
        // Fill the channel.
        reg.broadcast(make_event(1));
        // Now broadcast shutdown.  Subscriber is laggy (channel
        // is full).
        reg.broadcast_shutdown();
        assert!(sub.is_shutdown_requested());
        assert!(!sub.is_disconnected());
    }

    /// `Subscriber` is `Send + Sync` so it can be held in an
    /// `Arc<>` across threads.
    #[test]
    fn subscriber_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<Arc<Subscriber>>();
        assert_send_sync::<SubscriberRegistry>();
        assert_send_sync::<DeliveryEvent>();
        assert_send_sync::<BroadcastSummary>();
        assert_send_sync::<RegisterError>();
    }

    /// Registry broadcast under capacity cap: subscribers
    /// rejected at register time, not broadcast time.
    #[test]
    fn cap_rejection_at_register_not_broadcast() {
        let reg = SubscriberRegistry::with_max_subscribers(1);
        let (_sub, _rx) = reg.register(8, 100).unwrap();
        match reg.register(8, 100) {
            Err(RegisterError::AtCapacity { .. }) => {}
            other => panic!("expected AtCapacity, got {other:?}"),
        }
        // Broadcast still works for the registered subscriber.
        let summary = reg.broadcast(make_event(1));
        assert_eq!(summary.enqueued, 1);
    }
}

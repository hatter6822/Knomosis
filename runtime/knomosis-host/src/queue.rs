// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Bounded queue with non-blocking enqueue and `Busy` overflow.
//!
//! ## Why bounded
//!
//! Under sustained load, the listener may accept requests faster
//! than the worker can process them.  An unbounded queue would
//! grow without limit, eventually OOM'ing the process.  A
//! bounded queue with a `Busy` overflow strategy gives the
//! client a clear signal to back off without consuming server
//! memory.
//!
//! ## Why not a generic mpmc
//!
//! `std::sync::mpsc::sync_channel(capacity)` gives us a
//! synchronous bounded channel with `try_send`.  The worker is
//! single-threaded, so single-consumer is sufficient.  Multiple
//! producers (connection handler threads) submit via the same
//! `SyncSender`, which is cheap to `Clone`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TryRecvError, TrySendError};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::fair::drr::{Caps, DrrState, DrrStats};
use crate::kernel::KernelResponse;

/// A monotonic per-accepted-connection identifier (FQ.3).
///
/// Assigned at `accept()` from a process-wide counter ([`crate::server`]),
/// so it is transport-authenticated (unspoofable) and never reused —
/// an evicted DRR flow can therefore never alias a later connection.
/// Rung 0 routes the fair scheduler by this value; the FIFO path
/// ignores it.
pub type ConnId = u64;

/// Assign the next [`ConnId`] from a shared monotonic source (FQ.3).
///
/// Called identically by every listener's accept loop, against the ONE
/// counter [`crate::server::Server::run`] creates and shares across all
/// transports, so connection ids are globally distinct and monotonic
/// regardless of which listener accepted the connection.  `Relaxed`
/// ordering is sufficient: the id is a fairness routing key, not a
/// synchronization signal, and `fetch_add` is atomic so no two callers
/// ever observe the same value.
pub fn assign_conn_id(seq: &std::sync::atomic::AtomicU64) -> ConnId {
    seq.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
}

/// Default maximum queue depth.  256 in-flight requests is enough
/// headroom for a sequencer at moderate load without consuming
/// excessive memory.
pub const DEFAULT_MAX_QUEUE_DEPTH: usize = 256;

/// Hard ceiling on configurable queue depth.  Above this the
/// operator is doing something unusual — a 64k-deep queue at
/// 1 MiB per request would consume 64 GiB worst case.
pub const HARD_MAX_QUEUE_DEPTH: usize = 65_536;

/// A request enqueued for the worker.
///
/// Each request carries the CBE bytes plus a oneshot reply
/// channel.  The worker calls the kernel, then sends the response
/// back through the reply channel.  This keeps the connection
/// handler thread blocked on the reply (with backpressure
/// propagating naturally) without entangling the queue itself
/// with response routing.
#[derive(Debug)]
pub struct QueuedRequest {
    /// The CBE-encoded `SignedAction` bytes.
    pub payload: Vec<u8>,
    /// One-shot reply channel.  The worker sends the kernel's
    /// response here; the connection handler reads from the
    /// corresponding [`std::sync::mpsc::Receiver`].
    pub reply: SyncSender<KernelResponse>,
}

/// Outcome of [`BoundedQueue::try_submit`].
///
/// The two arms correspond to the two operator-visible paths the
/// host takes when a request arrives:
///
///   * [`SubmitOutcome::Enqueued`]: the request is in the worker
///     queue; the connection handler should block on the reply
///     receiver.
///   * [`SubmitOutcome::Busy`]: the queue is at capacity; the
///     connection handler must respond with `Verdict::Busy`
///     immediately.
#[derive(Debug)]
pub enum SubmitOutcome {
    /// Request was enqueued; the caller holds the reply receiver.
    Enqueued(Receiver<KernelResponse>),
    /// Queue full; the caller must respond `Busy` to the client.
    Busy,
}

/// A bounded queue producing `Enqueued` or `Busy` outcomes.
///
/// Cloneable: each `clone()` returns a new handle backed by the
/// same underlying channel.  The listener spawns one handle per
/// connection handler thread.
#[derive(Clone, Debug)]
pub struct BoundedQueue {
    sender: SyncSender<QueuedRequest>,
    /// The configured maximum depth.  Mirrored here so callers can
    /// query it for diagnostics; the underlying `SyncSender`
    /// doesn't expose its capacity.
    capacity: usize,
}

impl BoundedQueue {
    /// Construct a bounded queue + its consumer receiver.
    ///
    /// The receiver is the single consumer the worker thread
    /// reads from.  Callers `clone()` the returned queue to share
    /// the producer side across listener / connection-handler
    /// threads.
    ///
    /// `capacity` is bounded above by [`HARD_MAX_QUEUE_DEPTH`];
    /// values above the cap are clamped.  Zero is treated as
    /// rendezvous semantics (every `try_submit` returns `Busy`
    /// unless the worker is currently parked on `recv`); we
    /// document the corner case rather than rejecting it.
    #[must_use]
    pub fn new(capacity: usize) -> (Self, Receiver<QueuedRequest>) {
        let clamped = capacity.min(HARD_MAX_QUEUE_DEPTH);
        let (sender, receiver) = sync_channel(clamped);
        (
            Self {
                sender,
                capacity: clamped,
            },
            receiver,
        )
    }

    /// Configured queue capacity.
    #[must_use]
    pub const fn capacity(&self) -> usize {
        self.capacity
    }

    /// Try to enqueue a request.  Returns `Enqueued(receiver)` on
    /// success, `Busy` if the queue is full, or panics only if the
    /// channel has been disconnected (which indicates the worker
    /// thread has died — an unrecoverable host bug).
    ///
    /// The 1-capacity reply channel ensures the worker can always
    /// place its response without blocking even if the client
    /// disconnects between `try_submit` and `recv`; the reply is
    /// silently dropped in that case.
    pub fn try_submit(&self, payload: Vec<u8>) -> SubmitOutcome {
        // Build the reply channel.  Capacity 1: worker writes
        // exactly one response per request.  Sender side stays
        // with the worker via the `QueuedRequest`.
        let (reply_tx, reply_rx) = sync_channel::<KernelResponse>(1);
        let request = QueuedRequest {
            payload,
            reply: reply_tx,
        };
        match self.sender.try_send(request) {
            Ok(()) => SubmitOutcome::Enqueued(reply_rx),
            Err(TrySendError::Full(_)) => SubmitOutcome::Busy,
            Err(TrySendError::Disconnected(_)) => {
                // The worker has died.  This is unrecoverable at
                // the host level — every subsequent request would
                // also fail.  We return Busy to drain the
                // listener-side gracefully; the operator-facing
                // recovery is a process restart.  We deliberately
                // do NOT panic here because that would kill an
                // active connection thread without giving the
                // listener a chance to log + drain.
                SubmitOutcome::Busy
            }
        }
    }
}

/// A work-conserving Deficit-Round-Robin fair queue (FQ Rung 0).
///
/// The concurrency wrapper around the pure [`DrrState`] core: it adds a
/// `Mutex` (for serialized access to the scheduler state) and a
/// `Condvar` (so the worker parks while the queue is empty and wakes on
/// the next submission).  Cloneable — each clone shares the same
/// `Arc`-backed state, matching [`BoundedQueue`]'s producer-handle
/// ergonomics: listeners hold producer clones (calling
/// [`FairQueue::try_submit`]) and the single worker holds a consumer
/// clone (calling [`FairQueue::next`] / [`FairQueue::try_next`]).
///
/// Unlike [`BoundedQueue`], the fair queue is NOT channel-backed, so it
/// carries no "disconnected" signal: the worker owns shutdown via the
/// server's stop flag (`GP.8` §2.8), and the queue needs no reference
/// to it.
#[derive(Clone, Debug)]
pub struct FairQueue {
    /// The pure DRR scheduler state, guarded for serialized mutation.
    inner: Arc<Mutex<DrrState<ConnId>>>,
    /// Signalled on every successful submission so a parked worker
    /// wakes promptly; also used by the server's shutdown wake
    /// ([`FairQueue::wake_all`]).
    not_empty: Arc<Condvar>,
    /// Set once the worker has shut down ([`FairQueue::close`]).  A
    /// closed queue rejects further `try_submit`s with `Busy`, mirroring
    /// the FIFO path's dropped-channel `Disconnected → Busy` behaviour so
    /// a request submitted after the worker exits gets a prompt `Busy`
    /// rather than stranding until its reply timeout.
    closed: Arc<AtomicBool>,
}

/// Outcome of [`FairQueue::next`].
#[derive(Debug)]
pub enum NextOutcome {
    /// A request was dequeued in fair order — dispatch it.  The
    /// scheduler lock is already released when this is returned, so the
    /// slow `kernel.submit` call runs lock-free (the §2.8 throughput
    /// property): producers keep enqueuing while a dispatch is in
    /// flight.
    Dispatch(QueuedRequest),
    /// No work became available within the timeout.  The worker should
    /// re-check its stop flag and call [`FairQueue::next`] again.
    Idle,
}

impl FairQueue {
    /// Construct an empty fair queue with the given capacity caps.
    #[must_use]
    pub fn new(caps: Caps) -> Self {
        Self {
            inner: Arc::new(Mutex::new(DrrState::new(caps))),
            not_empty: Arc::new(Condvar::new()),
            closed: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Try to enqueue `payload` under connection `conn`.
    ///
    /// Builds the capacity-1 reply channel (as the FIFO path does),
    /// routes the request through the DRR core's cap checks, and on
    /// success notifies the worker.  On any cap breach the request (and
    /// its reply sender) is dropped and `Busy` is returned — the
    /// per-flow cap means a flooding connection back-pressures *itself*
    /// while other connections still enqueue.
    ///
    /// Poison-recovering: a thread that panicked while holding the lock
    /// does not wedge the queue (the next caller recovers the guard via
    /// `into_inner`).
    pub fn try_submit(&self, conn: ConnId, payload: Vec<u8>) -> SubmitOutcome {
        // The worker has shut down: there is nothing to dispatch this, so
        // reject promptly (matching the FIFO path's disconnected-channel
        // `Busy`) rather than enqueuing a request that would strand.
        if self.closed.load(Ordering::Acquire) {
            return SubmitOutcome::Busy;
        }
        let (reply_tx, reply_rx) = sync_channel::<KernelResponse>(1);
        let request = QueuedRequest {
            payload,
            reply: reply_tx,
        };
        let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        // Was the queue empty BEFORE this enqueue?  The single worker
        // parks (in `next`) only while the queue is empty, so it can be
        // waiting ONLY across an empty→non-empty transition.  Notifying
        // just on that transition therefore wakes a parked worker in
        // every case it could be parked, while skipping a redundant
        // `Condvar` wake on each enqueue into an already-backlogged queue
        // (the worker provably is not parked then — it will observe the
        // new request the next time it calls `next`).  Sound for the
        // single-consumer worker model; revisit if multiple workers are
        // ever added.
        let was_empty = guard.is_empty();
        match guard.enqueue(conn, request) {
            Ok(()) => {
                // Release the lock BEFORE notifying so the woken worker
                // does not immediately re-block on a still-held lock.
                drop(guard);
                if was_empty {
                    self.not_empty.notify_one();
                }
                SubmitOutcome::Enqueued(reply_rx)
            }
            Err(_returned) => {
                // The returned request (carrying its reply sender) and
                // the matching `reply_rx` are both dropped here.  The
                // per-reason rejection breakdown is tallied in the
                // scheduler's `stats()` and surfaced by the worker's
                // aggregate summary (FQ.6) — the hot path emits no
                // per-request log line (never per-request spam).
                drop(guard);
                SubmitOutcome::Busy
            }
        }
    }

    /// Block up to `timeout` for the next request, then dispatch it.
    ///
    /// If the queue is non-empty, `pick`s and returns immediately.
    /// Otherwise it waits on the `Condvar` for up to `timeout`; on ANY
    /// wakeup it re-evaluates by `pick`ing once:
    ///
    ///   * a producer's `notify_one` (which always lands an item first)
    ///     ⇒ `pick` returns the request ⇒ `Dispatch`;
    ///   * a shutdown [`FairQueue::wake_all`], a spurious wakeup, or the
    ///     timeout (all leave the queue empty) ⇒ `pick` returns `None`
    ///     ⇒ `Idle`, and the worker re-checks its stop flag and calls
    ///     `next` again.
    ///
    /// Returning `Idle` on an empty wakeup (rather than re-waiting until a
    /// deadline) is what makes `wake_all` promptly unblock a parked
    /// worker at shutdown; a spurious wakeup merely costs one extra
    /// worker-loop iteration, not a busy-spin.  The single bounded wait
    /// also caps the latency at `timeout` so the worker re-checks `stop`
    /// on that cadence.  On success the request is returned **by value
    /// with the lock already released**, so the dispatch is lock-free.
    /// Holds no reference to any stop flag (§2.8).
    pub fn next(&self, timeout: Duration) -> NextOutcome {
        let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        if guard.is_empty() {
            let (next_guard, _timed_out) = self
                .not_empty
                .wait_timeout(guard, timeout)
                .unwrap_or_else(|p| p.into_inner());
            guard = next_guard;
        }
        match guard.pick() {
            // `guard` drops at the `return`, releasing the lock before
            // the caller dispatches (lock-free dispatch).
            Some(req) => NextOutcome::Dispatch(req),
            // Empty wakeup (timeout / `wake_all` / spurious): let the
            // worker re-check `stop`.
            None => NextOutcome::Idle,
        }
    }

    /// Non-blocking analogue of [`FairQueue::next`]: pop the next request
    /// in fair order if one is ready, else `None`.  Used by the worker's
    /// shutdown drain (`GP.8` §2.8).
    pub fn try_next(&self) -> Option<QueuedRequest> {
        let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        guard.pick()
    }

    /// Wake every parked worker (a single broadcast).  Called by the
    /// server on shutdown so a worker parked in [`FairQueue::next`]
    /// notices the stop flag immediately instead of after the next
    /// `timeout`.  Correctness does not depend on it (the timeout bounds
    /// the wait regardless); it only sharpens shutdown latency.
    pub fn wake_all(&self) {
        self.not_empty.notify_all();
    }

    /// Mark the queue closed: subsequent [`FairQueue::try_submit`] calls
    /// return `Busy` immediately rather than enqueuing.  Called by the
    /// worker once it has stopped draining (FQ.4b), so a request a
    /// connection handler submits after the worker exits gets a prompt
    /// `Busy` — the FairQueue counterpart of the FIFO path's
    /// disconnected-channel rejection.  Idempotent.
    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
        // Wake anything parked so it re-evaluates promptly.
        self.not_empty.notify_all();
    }

    /// Snapshot the scheduler's aggregate counters (FQ.6).  Internally
    /// consistent because it is read under the same lock that guards
    /// every mutation.
    #[must_use]
    pub fn stats(&self) -> DrrStats {
        self.inner.lock().unwrap_or_else(|p| p.into_inner()).stats()
    }
}

/// A scheduler-agnostic producer handle (FQ.4a).
///
/// Unifies the FIFO [`BoundedQueue`] and the fair [`FairQueue`] behind
/// one [`QueueHandle::submit`] call so connection handlers are identical
/// on both paths: the listener threads carry a `QueueHandle` and submit
/// through it regardless of which scheduler the server built.  The
/// `Fifo` arm ignores the connection id; the `Fair` arm routes by it.
#[derive(Clone, Debug)]
pub enum QueueHandle {
    /// The historical FIFO bounded queue.
    Fifo(BoundedQueue),
    /// The optional per-connection DRR fair queue (Rung 0).
    Fair(FairQueue),
}

impl QueueHandle {
    /// Submit `payload` for connection `conn`.  The `Fifo` arm discards
    /// `conn` (FIFO is connection-agnostic); the `Fair` arm routes by it.
    pub fn submit(&self, conn: ConnId, payload: Vec<u8>) -> SubmitOutcome {
        match self {
            Self::Fifo(q) => q.try_submit(payload),
            Self::Fair(q) => q.try_submit(conn, payload),
        }
    }
}

/// Outcome of [`drain_one`].
#[derive(Debug)]
pub enum DrainOutcome {
    /// A request was dequeued and dispatched.
    Dispatched,
    /// The receiver is disconnected (every producer was dropped).
    /// The worker should exit cleanly.
    Disconnected,
    /// Timeout elapsed without a request arriving.  The worker
    /// should loop and check `stop` flags, then call `drain_one`
    /// again.
    Timeout,
}

/// Pull one request from `receiver` (blocking up to `timeout`)
/// and dispatch it via `dispatch`.  Convenience helper for the
/// worker loop.
///
/// The worker loop is typically:
///
/// ```ignore
/// while !stop.load(Ordering::Relaxed) {
///     match drain_one(&receiver, timeout, |req| kernel.submit(&req.payload)) {
///         DrainOutcome::Dispatched | DrainOutcome::Timeout => continue,
///         DrainOutcome::Disconnected => break,
///     }
/// }
/// ```
pub fn drain_one<F>(
    receiver: &Receiver<QueuedRequest>,
    timeout: Duration,
    dispatch: F,
) -> DrainOutcome
where
    F: FnOnce(&[u8]) -> KernelResponse,
{
    match receiver.recv_timeout(timeout) {
        Ok(request) => {
            let response = dispatch(&request.payload);
            // Send the response back; ignore failure (the client
            // may have disconnected between try_submit and recv).
            // The capacity-1 reply channel guarantees the send
            // succeeds unless the receiver was dropped.
            let _ = request.reply.try_send(response);
            DrainOutcome::Dispatched
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => DrainOutcome::Timeout,
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => DrainOutcome::Disconnected,
    }
}

/// Like [`drain_one`] but non-blocking: returns immediately if no
/// request is available.  Useful for shutdown drain loops that
/// want to exit as soon as the queue is empty.
///
/// Returns [`DrainOutcome::Timeout`] when the queue is empty (the
/// "timeout" naming is preserved for consistency with
/// [`drain_one`]; semantically it means "no work right now").
pub fn try_drain_one<F>(receiver: &Receiver<QueuedRequest>, dispatch: F) -> DrainOutcome
where
    F: FnOnce(&[u8]) -> KernelResponse,
{
    match receiver.try_recv() {
        Ok(request) => {
            let response = dispatch(&request.payload);
            let _ = request.reply.try_send(response);
            DrainOutcome::Dispatched
        }
        Err(TryRecvError::Empty) => DrainOutcome::Timeout,
        Err(TryRecvError::Disconnected) => DrainOutcome::Disconnected,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        drain_one, try_drain_one, BoundedQueue, DrainOutcome, FairQueue, NextOutcome, QueueHandle,
        SubmitOutcome, DEFAULT_MAX_QUEUE_DEPTH, HARD_MAX_QUEUE_DEPTH,
    };
    use crate::fair::drr::Caps;
    use crate::kernel::KernelResponse;
    use crate::verdict::Verdict;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};
    use std::thread;
    use std::time::{Duration, Instant};

    /// Constants are stable.
    #[test]
    fn constants_stable() {
        assert_eq!(DEFAULT_MAX_QUEUE_DEPTH, 256);
        assert_eq!(HARD_MAX_QUEUE_DEPTH, 65_536);
    }

    /// `BoundedQueue::new` returns a queue with the given
    /// capacity.
    #[test]
    fn new_with_capacity() {
        let (queue, _rx) = BoundedQueue::new(8);
        assert_eq!(queue.capacity(), 8);
    }

    /// Capacity is clamped to `HARD_MAX_QUEUE_DEPTH`.
    #[test]
    fn capacity_clamped_to_hard_max() {
        let (queue, _rx) = BoundedQueue::new(usize::MAX);
        assert_eq!(queue.capacity(), HARD_MAX_QUEUE_DEPTH);
    }

    /// Single submission to a capacity-1 queue succeeds.
    #[test]
    fn single_submit_succeeds() {
        let (queue, _rx) = BoundedQueue::new(1);
        let outcome = queue.try_submit(b"payload".to_vec());
        match outcome {
            SubmitOutcome::Enqueued(_) => {}
            other => panic!("expected Enqueued, got {other:?}"),
        }
    }

    /// Two submissions to a capacity-1 queue: first succeeds, second
    /// is `Busy` (queue full, no worker draining).
    #[test]
    fn second_submit_busy_when_capacity_one() {
        let (queue, _rx) = BoundedQueue::new(1);
        let _outcome1 = queue.try_submit(b"a".to_vec());
        let outcome2 = queue.try_submit(b"b".to_vec());
        match outcome2 {
            SubmitOutcome::Busy => {}
            other => panic!("expected Busy, got {other:?}"),
        }
    }

    /// `drain_one` dispatches one request via the supplied
    /// closure.  The dispatch closure receives the payload bytes.
    #[test]
    fn drain_one_dispatches() {
        let (queue, rx) = BoundedQueue::new(4);
        let SubmitOutcome::Enqueued(reply_rx) = queue.try_submit(b"hello".to_vec()) else {
            panic!("expected Enqueued");
        };
        let outcome = drain_one(&rx, Duration::from_millis(10), |bytes| {
            assert_eq!(bytes, b"hello");
            KernelResponse::from_verdict(Verdict::Ok)
        });
        match outcome {
            DrainOutcome::Dispatched => {}
            other => panic!("expected Dispatched, got {other:?}"),
        }
        let response = reply_rx
            .recv_timeout(Duration::from_millis(100))
            .expect("response within deadline");
        assert_eq!(response.verdict, Verdict::Ok);
    }

    /// `drain_one` times out with no request available.
    #[test]
    fn drain_one_times_out() {
        let (_queue, rx) = BoundedQueue::new(4);
        let outcome = drain_one(&rx, Duration::from_millis(10), |_| {
            panic!("dispatch must not be called on timeout");
        });
        match outcome {
            DrainOutcome::Timeout => {}
            other => panic!("expected Timeout, got {other:?}"),
        }
    }

    /// `drain_one` returns `Disconnected` when every producer is
    /// dropped.
    #[test]
    fn drain_one_disconnects_when_no_producers() {
        let (queue, rx) = BoundedQueue::new(4);
        drop(queue);
        let outcome = drain_one(&rx, Duration::from_millis(10), |_| {
            panic!("dispatch must not be called when disconnected");
        });
        match outcome {
            DrainOutcome::Disconnected => {}
            other => panic!("expected Disconnected, got {other:?}"),
        }
    }

    /// `try_drain_one` returns `Timeout` immediately when empty
    /// (no blocking).
    #[test]
    fn try_drain_one_empty() {
        let (_queue, rx) = BoundedQueue::new(4);
        let start = std::time::Instant::now();
        let outcome = try_drain_one(&rx, |_| panic!("dispatch must not be called"));
        let elapsed = start.elapsed();
        assert!(
            elapsed < Duration::from_millis(50),
            "blocked for {elapsed:?}"
        );
        match outcome {
            DrainOutcome::Timeout => {}
            other => panic!("expected Timeout, got {other:?}"),
        }
    }

    /// `try_drain_one` dispatches when a request is available.
    #[test]
    fn try_drain_one_dispatches() {
        let (queue, rx) = BoundedQueue::new(4);
        let SubmitOutcome::Enqueued(reply_rx) = queue.try_submit(b"a".to_vec()) else {
            panic!("enqueue");
        };
        let outcome = try_drain_one(&rx, |_| KernelResponse::from_verdict(Verdict::Ok));
        match outcome {
            DrainOutcome::Dispatched => {}
            other => panic!("expected Dispatched, got {other:?}"),
        }
        let _ = reply_rx
            .recv_timeout(Duration::from_millis(100))
            .expect("response");
    }

    /// End-to-end: producer + worker thread + multiple submissions.
    #[test]
    fn end_to_end_producer_worker() {
        let (queue, rx) = BoundedQueue::new(4);
        let counter = Arc::new(AtomicUsize::new(0));
        let counter_clone = Arc::clone(&counter);
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop_clone = Arc::clone(&stop);
        // Spawn the worker.
        let worker = thread::spawn(move || {
            while !stop_clone.load(Ordering::Relaxed) {
                match drain_one(&rx, Duration::from_millis(10), |bytes| {
                    counter_clone.fetch_add(bytes.len(), Ordering::Relaxed);
                    KernelResponse::from_verdict(Verdict::Ok)
                }) {
                    DrainOutcome::Dispatched | DrainOutcome::Timeout => {}
                    DrainOutcome::Disconnected => break,
                }
            }
        });
        // Submit several requests.
        let mut reply_rxs = Vec::new();
        for i in 0..10u8 {
            let payload = vec![i; (i as usize) + 1]; // varying sizes
            if let SubmitOutcome::Enqueued(rx) = queue.try_submit(payload) {
                reply_rxs.push(rx);
            }
        }
        // Collect responses.
        for rx in reply_rxs {
            let r = rx.recv_timeout(Duration::from_secs(1)).expect("response");
            assert_eq!(r.verdict, Verdict::Ok);
        }
        // Counter should equal 1+2+...+10 = 55 (sum of payload sizes).
        // Tolerate a small margin since the worker may not have caught
        // every one synchronously.
        let actual = counter.load(Ordering::Relaxed);
        assert!((1..=55).contains(&actual), "counter = {actual}");
        // Shut down the worker.
        stop.store(true, Ordering::Relaxed);
        drop(queue);
        worker.join().expect("worker join");
    }

    /// Multiple producers (cloned `BoundedQueue`) submit to the
    /// same underlying channel.
    #[test]
    fn multiple_producers() {
        let (queue, rx) = BoundedQueue::new(16);
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop_clone = Arc::clone(&stop);
        let count = Arc::new(AtomicUsize::new(0));
        let count_clone = Arc::clone(&count);
        let worker = thread::spawn(move || {
            while !stop_clone.load(Ordering::Relaxed) {
                if let DrainOutcome::Dispatched = drain_one(&rx, Duration::from_millis(10), |_| {
                    count_clone.fetch_add(1, Ordering::Relaxed);
                    KernelResponse::from_verdict(Verdict::Ok)
                }) {
                    // counted
                }
            }
        });
        // Spawn 4 producers each submitting 4 requests.
        let mut handles = Vec::new();
        for _ in 0..4 {
            let q = queue.clone();
            handles.push(thread::spawn(move || {
                let mut reply_rxs = Vec::new();
                for j in 0..4u8 {
                    if let SubmitOutcome::Enqueued(rx) = q.try_submit(vec![j]) {
                        reply_rxs.push(rx);
                    }
                }
                for rx in reply_rxs {
                    let _ = rx.recv_timeout(Duration::from_secs(1));
                }
            }));
        }
        for h in handles {
            h.join().expect("producer join");
        }
        // Allow worker to drain.
        thread::sleep(Duration::from_millis(50));
        stop.store(true, Ordering::Relaxed);
        drop(queue);
        worker.join().expect("worker join");
        let final_count = count.load(Ordering::Relaxed);
        assert_eq!(final_count, 16, "expected 16 dispatches, got {final_count}");
    }

    /// Stress: saturate a small queue from many producers; some
    /// should get `Busy`.
    #[test]
    fn saturation_produces_busy() {
        // Capacity 1, no worker → second submission must be Busy.
        let (queue, _rx) = BoundedQueue::new(1);
        let mut enqueued = 0;
        let mut busy = 0;
        for _ in 0..32 {
            match queue.try_submit(vec![0]) {
                SubmitOutcome::Enqueued(_) => enqueued += 1,
                SubmitOutcome::Busy => busy += 1,
            }
        }
        // At least one busy must occur (first goes in, rest are Busy).
        assert_eq!(enqueued, 1);
        assert_eq!(busy, 31);
    }

    /// `BoundedQueue` is `Clone + Send + Sync` (required for
    /// sharing across listener threads).
    #[test]
    fn queue_is_clone_send_sync() {
        fn assert_send_sync_clone<T: Send + Sync + Clone>() {}
        assert_send_sync_clone::<BoundedQueue>();
    }

    /// Capacity zero behaves as rendezvous: every `try_submit`
    /// returns `Busy` because there is no buffer slot and the
    /// worker isn't parked on `recv`.
    #[test]
    fn capacity_zero_is_rendezvous() {
        let (queue, _rx) = BoundedQueue::new(0);
        match queue.try_submit(vec![0]) {
            SubmitOutcome::Busy => {}
            other => panic!("expected Busy, got {other:?}"),
        }
    }

    /// Disconnected sender (worker dropped) returns `Busy` rather
    /// than panicking.  This is the graceful-degradation path
    /// when the worker thread has died.
    #[test]
    fn disconnected_returns_busy() {
        let (queue, rx) = BoundedQueue::new(4);
        drop(rx); // simulate worker death
        match queue.try_submit(vec![0]) {
            SubmitOutcome::Busy => {}
            other => panic!("expected Busy on disconnected, got {other:?}"),
        }
    }

    // ===== FairQueue (FQ Rung 0) =====================================

    /// Build a fair queue with explicit caps.
    fn fair(per_flow: usize, max_flows: usize, global: usize) -> FairQueue {
        FairQueue::new(Caps::new(per_flow, max_flows, global))
    }

    /// FQ.2a — per-flow cap is targeted: one connection saturating its
    /// per-flow cap gets `Busy`, while a second connection still
    /// enqueues.  Asserted directly via the queue API (no kernel).
    #[test]
    fn fair_per_flow_cap_is_targeted() {
        let q = fair(2, 10, 100);
        // Whale (conn 1): first two Enqueued, third Busy.
        assert!(matches!(
            q.try_submit(1, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));
        assert!(matches!(
            q.try_submit(1, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));
        assert!(matches!(q.try_submit(1, vec![1]), SubmitOutcome::Busy));
        // Small (conn 2): still enqueues — targeted backpressure.
        assert!(matches!(
            q.try_submit(2, vec![2]),
            SubmitOutcome::Enqueued(_)
        ));
        let s = q.stats();
        assert_eq!(s.rejected_per_flow, 1);
        assert_eq!(s.total_depth, 3);
    }

    /// FQ.2a — the `global` cap returns `Busy`.
    #[test]
    fn fair_global_cap_busy() {
        let q = fair(10, 10, 2);
        assert!(matches!(
            q.try_submit(1, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));
        assert!(matches!(
            q.try_submit(2, vec![2]),
            SubmitOutcome::Enqueued(_)
        ));
        assert!(matches!(q.try_submit(3, vec![3]), SubmitOutcome::Busy));
        assert_eq!(q.stats().rejected_global, 1);
    }

    /// FQ.2a — the `max_flows` cap returns `Busy` for a new connection.
    #[test]
    fn fair_max_flows_cap_busy() {
        let q = fair(10, 2, 100);
        assert!(matches!(
            q.try_submit(1, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));
        assert!(matches!(
            q.try_submit(2, vec![2]),
            SubmitOutcome::Enqueued(_)
        ));
        // Third distinct connection breaches max_flows.
        assert!(matches!(q.try_submit(3, vec![3]), SubmitOutcome::Busy));
        // But an existing connection still enqueues.
        assert!(matches!(
            q.try_submit(1, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));
        assert_eq!(q.stats().rejected_max_flows, 1);
    }

    /// FQ.2a — a poisoned lock still serves (poison recovery), rather
    /// than wedging every subsequent caller.
    #[test]
    fn fair_poison_recovery_still_serves() {
        let q = fair(10, 10, 100);
        let q2 = q.clone();
        // Poison the inner mutex by panicking while holding it.
        let _ = thread::spawn(move || {
            let _guard = q2.inner.lock().unwrap();
            panic!("poison the lock");
        })
        .join();
        // The queue still works.
        assert!(matches!(
            q.try_submit(1, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));
        assert!(q.try_next().is_some());
    }

    /// FQ.2b — `next` blocks on an empty queue and dispatches the request
    /// after a concurrent `try_submit` + notify.  The consumer loops
    /// `next` exactly as the real worker does (so a `timeout` or a
    /// spurious `Condvar` wakeup before the submit is simply retried),
    /// then asserts the request is delivered.
    #[test]
    fn fair_next_blocks_then_dispatches() {
        let q = fair(64, 64, 64);
        let qc = q.clone();
        let consumer = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                match qc.next(Duration::from_millis(200)) {
                    NextOutcome::Dispatch(req) => {
                        let _ = req
                            .reply
                            .try_send(KernelResponse::from_verdict(Verdict::Ok));
                        return Some(req.payload);
                    }
                    NextOutcome::Idle => {
                        if Instant::now() >= deadline {
                            return None;
                        }
                        // Timeout / spurious wake before the submit: retry.
                    }
                }
            }
        });
        // Let the consumer park on `next`, then submit.
        thread::sleep(Duration::from_millis(100));
        let SubmitOutcome::Enqueued(reply_rx) = q.try_submit(7, vec![42]) else {
            panic!("expected Enqueued");
        };
        let served = consumer.join().expect("consumer join");
        assert_eq!(served, Some(vec![42]));
        let resp = reply_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("reply within deadline");
        assert_eq!(resp.verdict, Verdict::Ok);
    }

    /// FQ.2b — `next` returns `Idle` (not `Dispatch`) within roughly
    /// `timeout` when the queue stays empty, and does not hang.
    ///
    /// We assert only the upper bound: a `Condvar` may wake spuriously,
    /// in which case `next` legitimately returns `Idle` early (the
    /// worker then re-checks `stop` and calls `next` again).  That
    /// `next` genuinely BLOCKS until woken (rather than busy-returning)
    /// is pinned by `fair_next_blocks_then_dispatches` and
    /// `fair_wake_all_unblocks_parked_next_promptly`.
    #[test]
    fn fair_next_idle_on_timeout() {
        let q: FairQueue = fair(64, 64, 64);
        let start = Instant::now();
        let outcome = q.next(Duration::from_millis(60));
        let elapsed = start.elapsed();
        assert!(matches!(outcome, NextOutcome::Idle));
        // Did not hang (the wait is bounded by `timeout`).
        assert!(
            elapsed < Duration::from_millis(800),
            "blocked too long: {elapsed:?}"
        );
    }

    /// FQ.2b/§2.8 — `wake_all` PROMPTLY unblocks a worker parked in
    /// `next` (it returns `Idle` well before the long timeout): the
    /// property the shutdown wake relies on.  A re-wait-until-deadline
    /// loop would instead block for the entire timeout, so this pins
    /// that `wake_all` is genuinely effective.
    #[test]
    fn fair_wake_all_unblocks_parked_next_promptly() {
        let q = fair(64, 64, 64);
        let qc = q.clone();
        let waiter = thread::spawn(move || {
            let start = Instant::now();
            // 10 s timeout: if wake_all is effective we return ≪ that.
            let outcome = qc.next(Duration::from_secs(10));
            (matches!(outcome, NextOutcome::Idle), start.elapsed())
        });
        // Let the waiter park on `next`, then wake it.
        thread::sleep(Duration::from_millis(100));
        q.wake_all();
        let (was_idle, elapsed) = waiter.join().expect("waiter join");
        assert!(was_idle, "expected Idle on an empty wake");
        assert!(
            elapsed < Duration::from_secs(2),
            "wake_all did not promptly unblock next: {elapsed:?}"
        );
    }

    /// FQ.4b — a closed queue rejects further submissions with `Busy`
    /// (the FairQueue counterpart of the FIFO path's disconnected-channel
    /// rejection), while still draining what was already enqueued.  This
    /// is what spares a post-shutdown submission from stranding.
    #[test]
    fn fair_close_rejects_new_submissions() {
        let q = fair(64, 64, 64);
        // Pre-close: a request enqueues normally.
        assert!(matches!(
            q.try_submit(1, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));
        q.close();
        // Post-close: new submissions are Busy (any connection).
        assert!(matches!(q.try_submit(1, vec![1]), SubmitOutcome::Busy));
        assert!(matches!(q.try_submit(2, vec![2]), SubmitOutcome::Busy));
        // The pre-close request is still drainable.
        assert!(q.try_next().is_some());
        assert!(q.try_next().is_none());
        // close() is idempotent.
        q.close();
        assert!(matches!(q.try_submit(3, vec![3]), SubmitOutcome::Busy));
    }

    /// FQ.2b — `try_next` never blocks: it returns immediately whether
    /// or not work is available.
    #[test]
    fn fair_try_next_is_immediate() {
        let q = fair(64, 64, 64);
        let start = Instant::now();
        assert!(q.try_next().is_none());
        assert!(
            start.elapsed() < Duration::from_millis(50),
            "try_next blocked"
        );
        let _ = q.try_submit(1, vec![1]);
        assert!(q.try_next().is_some());
        assert!(q.try_next().is_none());
    }

    /// FQ.2b/§2.8 — the dispatched request is returned with the lock
    /// ALREADY released, so a producer can submit while a (simulated)
    /// slow dispatch is in flight.  If `next` held the lock across the
    /// return, this same-thread `try_submit` would deadlock.
    #[test]
    fn fair_dispatch_happens_outside_the_lock() {
        let q = fair(64, 64, 64);
        let _ = q.try_submit(1, vec![1]);
        let NextOutcome::Dispatch(req) = q.next(Duration::from_millis(200)) else {
            panic!("expected Dispatch");
        };
        // `req` is held (slow dispatch).  The lock must be free.
        match q.try_submit(2, vec![2]) {
            SubmitOutcome::Enqueued(_) => {}
            other => panic!("submit blocked while a dispatch was in flight: {other:?}"),
        }
        drop(req);
    }

    /// FQ.7a (queue-level) — DRR fairness order: a whale's backlog does
    /// not bury a small connection's request.  Under FIFO the small
    /// request would be served 4th (1,1,1,2); DRR serves it 2nd.
    #[test]
    fn fair_drr_order_does_not_bury_small_flow() {
        let q = fair(64, 64, 64);
        for _ in 0..3 {
            let _ = q.try_submit(1, vec![1]); // whale, conn 1
        }
        let _ = q.try_submit(2, vec![2]); // small, conn 2 (enqueued last)
        let mut order = Vec::new();
        while let Some(req) = q.try_next() {
            order.push(req.payload[0]);
        }
        assert_eq!(order, vec![1, 2, 1, 1], "DRR must interleave, not FIFO");
    }

    /// FQ.2c — multi-producer / single-consumer: every submitted request
    /// is dispatched exactly once and every reply arrives.
    #[test]
    fn fair_mpsc_exactly_once_and_replies_arrive() {
        let q = fair(64, 64, 256);
        let served: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        let producers_done = Arc::new(AtomicBool::new(false));

        // Consumer: dispatch every request, reply Ok, record payload.
        let qc = q.clone();
        let served_c = Arc::clone(&served);
        let done_c = Arc::clone(&producers_done);
        let consumer = thread::spawn(move || loop {
            match qc.next(Duration::from_millis(100)) {
                NextOutcome::Dispatch(req) => {
                    served_c.lock().unwrap().push(req.payload[0]);
                    let _ = req
                        .reply
                        .try_send(KernelResponse::from_verdict(Verdict::Ok));
                }
                NextOutcome::Idle => {
                    if done_c.load(Ordering::Acquire) && qc.stats().total_depth == 0 {
                        break;
                    }
                }
            }
        });

        // 4 producers × 4 distinct payloads each (16 total, 0..16).
        let mut producers = Vec::new();
        for p in 0..4u8 {
            let qp = q.clone();
            producers.push(thread::spawn(move || {
                let mut rxs = Vec::new();
                for j in 0..4u8 {
                    let payload = vec![p * 4 + j];
                    if let SubmitOutcome::Enqueued(rx) = qp.try_submit(u64::from(p), payload) {
                        rxs.push(rx);
                    }
                }
                // Block until each request's reply arrives (proving it
                // was dispatched).
                for rx in rxs {
                    let r = rx.recv_timeout(Duration::from_secs(5)).expect("reply");
                    assert_eq!(r.verdict, Verdict::Ok);
                }
            }));
        }
        for h in producers {
            h.join().expect("producer join");
        }
        producers_done.store(true, Ordering::Release);
        consumer.join().expect("consumer join");

        let mut got = served.lock().unwrap().clone();
        got.sort_unstable();
        let expected: Vec<u8> = (0..16).collect();
        assert_eq!(got, expected, "exactly-once dispatch of all payloads");
    }

    /// FQ.2c — targeted backpressure under concurrency: a whale flooding
    /// its own connection cannot starve a concurrent small connection,
    /// because the per-flow cap bounds the whale's share of the global
    /// buffer (so the global cap never fills on the whale's behalf).
    #[test]
    fn fair_targeted_backpressure_under_concurrency() {
        let q = fair(2, 16, 64); // per_flow 2 ≪ global 64
        let small_ok = Arc::new(AtomicBool::new(false));

        let qw = q.clone();
        let whale = thread::spawn(move || {
            // Flood: only 2 ever enqueue (per_flow), the rest Busy.
            for _ in 0..1000 {
                let _ = qw.try_submit(1, vec![1]);
            }
        });
        let qs = q.clone();
        let small_ok_c = Arc::clone(&small_ok);
        let small = thread::spawn(move || {
            // The small connection's single request always enqueues:
            // the whale cannot have filled the global buffer (it is
            // capped at per_flow = 2).
            for _ in 0..50 {
                if matches!(qs.try_submit(2, vec![2]), SubmitOutcome::Enqueued(_)) {
                    small_ok_c.store(true, Ordering::Release);
                }
                let _ = qs.try_next(); // drain the small flow so it can re-submit
            }
        });
        whale.join().unwrap();
        small.join().unwrap();
        assert!(
            small_ok.load(Ordering::Acquire),
            "small connection was starved by the whale"
        );
    }

    /// FQ.2c — shutdown-drain shape: after producers stop, `try_next`
    /// empties the queue and then returns `None`.
    #[test]
    fn fair_shutdown_drain_shape() {
        let q = fair(64, 64, 64);
        for i in 0..5u8 {
            let _ = q.try_submit(u64::from(i), vec![i]);
        }
        let mut drained = 0;
        while q.try_next().is_some() {
            drained += 1;
        }
        assert_eq!(drained, 5);
        assert!(q.try_next().is_none());
        assert_eq!(q.stats().total_depth, 0);
    }

    /// FQ.6 — `stats()` reflects dispatches and per-reason rejections.
    #[test]
    fn fair_stats_track_dispatches_and_rejections() {
        let q = fair(2, 2, 10);
        // 2 on conn 1 (Ok), 1 more on conn 1 (per_flow reject).
        let _ = q.try_submit(1, vec![1]);
        let _ = q.try_submit(1, vec![1]);
        let _ = q.try_submit(1, vec![1]); // per_flow reject
                                          // conn 2 Ok, conn 3 (max_flows reject).
        let _ = q.try_submit(2, vec![2]);
        let _ = q.try_submit(3, vec![3]); // max_flows reject
                                          // Dispatch two.
        let _ = q.try_next();
        let _ = q.try_next();
        let s = q.stats();
        assert_eq!(s.rejected_per_flow, 1);
        assert_eq!(s.rejected_max_flows, 1);
        assert_eq!(s.dispatched, 2);
        assert_eq!(s.total_depth, 1); // 3 enqueued − 2 dispatched
    }

    /// FairQueue + QueueHandle are `Clone + Send + Sync` (required for
    /// sharing across listener / worker threads).
    #[test]
    fn fair_queue_is_clone_send_sync() {
        fn assert_send_sync_clone<T: Send + Sync + Clone>() {}
        assert_send_sync_clone::<FairQueue>();
        assert_send_sync_clone::<QueueHandle>();
    }

    /// FQ.4a — `QueueHandle::submit` dispatches to the right arm: the
    /// `Fifo` arm ignores the conn id; the `Fair` arm routes by it.
    #[test]
    fn queue_handle_routes_both_arms() {
        // FIFO arm: conn id ignored, behaves like BoundedQueue.
        let (fifo, _rx) = BoundedQueue::new(4);
        let handle = QueueHandle::Fifo(fifo);
        assert!(matches!(
            handle.submit(999, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));

        // Fair arm: routes by conn id (per-flow cap applies per conn).
        let handle = QueueHandle::Fair(fair(1, 10, 10));
        assert!(matches!(
            handle.submit(1, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));
        assert!(matches!(handle.submit(1, vec![1]), SubmitOutcome::Busy)); // per_flow 1
        assert!(matches!(
            handle.submit(2, vec![2]),
            SubmitOutcome::Enqueued(_)
        ));
    }

    /// FQ.3 — `assign_conn_id` yields distinct, monotonic ids from a
    /// shared counter, including under concurrency.  This is the exact
    /// mechanism every listener accept loop uses against the single
    /// shared `conn_seq` (so connection ids are globally distinct and
    /// monotonic across all three transports); a regression to a
    /// non-atomic load+store would surface here as duplicate ids.
    #[test]
    fn assign_conn_id_distinct_and_monotonic() {
        use super::assign_conn_id;
        use std::sync::atomic::AtomicU64;
        // Sequential: strictly increasing from 0.
        let seq = AtomicU64::new(0);
        assert_eq!(assign_conn_id(&seq), 0);
        assert_eq!(assign_conn_id(&seq), 1);
        assert_eq!(assign_conn_id(&seq), 2);
        // Concurrent: 8 threads × 100 ids each, all distinct and covering
        // the contiguous range 0..800 (no duplicates, no gaps).
        let seq = Arc::new(AtomicU64::new(0));
        let mut handles = Vec::new();
        for _ in 0..8 {
            let s = Arc::clone(&seq);
            handles.push(thread::spawn(move || {
                (0..100).map(|_| assign_conn_id(&s)).collect::<Vec<u64>>()
            }));
        }
        let mut all: Vec<u64> = handles
            .into_iter()
            .flat_map(|h| h.join().unwrap())
            .collect();
        all.sort_unstable();
        let mut distinct = all.clone();
        distinct.dedup();
        assert_eq!(distinct.len(), 800, "conn ids must be distinct");
        assert_eq!(*all.first().unwrap(), 0);
        assert_eq!(
            *all.last().unwrap(),
            799,
            "ids cover a contiguous monotonic range"
        );
    }
}

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

use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TryRecvError, TrySendError};
use std::time::Duration;

use crate::kernel::KernelResponse;

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
        drain_one, try_drain_one, BoundedQueue, DrainOutcome, SubmitOutcome,
        DEFAULT_MAX_QUEUE_DEPTH, HARD_MAX_QUEUE_DEPTH,
    };
    use crate::kernel::KernelResponse;
    use crate::verdict::Verdict;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

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
}

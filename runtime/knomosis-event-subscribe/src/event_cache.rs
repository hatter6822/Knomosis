// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Sequenced event cache for the resume-from-sequence protocol.
//!
//! ## What this provides
//!
//! Subscribers may request to resume from any sequence number; the
//! server must either deliver the requested range (`resume_from +
//! 1 ..= live`) or reject with [`crate::frame::OutboundFrame::Truncated`].
//!
//! The cache holds the **most recent** `--keep-history <n>` events
//! in memory, keyed by their assigned sequence number.  Older
//! events are evicted in FIFO order; reads outside the cached
//! window report `OutOfWindow` and the server translates that
//! to a `Truncated` control frame.
//!
//! ## Why bounded
//!
//! Without a bound, a long-running deployment with millions of
//! events would OOM.  256 events × ~1 KiB per event ≈ 256 KiB
//! per deployment-day on a low-volume system; the operator sets
//! a higher cap if their resume-tolerance window is longer.
//!
//! ## Concurrency model
//!
//! Wrapped in a `Mutex` at the server level.  The extractor
//! thread holds the mutex briefly on each `push`; subscriber
//! dispatch threads hold it briefly on each `range`.  Contention
//! is low because:
//!
//!   * The extractor is a single thread.
//!   * Each subscriber backfills exactly once, in its dispatch
//!     thread, then transitions to live-tail mode (where it
//!     receives events via a per-subscriber `mpsc` channel,
//!     not via the cache).
//!
//! See [`EventCache`] for the public API.

use std::collections::VecDeque;

/// Default cache capacity.  256 events is a generous default for
/// a typical deployment; operators tune via `--keep-history`.
pub const DEFAULT_KEEP_HISTORY: usize = 256;

/// Hard ceiling on `--keep-history`.  Above this the operator
/// is using the cache for log-shipping rather than backfill;
/// they should switch to a real indexer (RH-E.1).
pub const HARD_MAX_KEEP_HISTORY: usize = 1_000_000;

/// A single cached event entry.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CachedEvent {
    /// 1-indexed sequence number, identical to the one assigned
    /// by [`crate::tail::TailReader`].
    pub seq: u64,
    /// CBE-encoded event payload bytes.  Opaque to the cache;
    /// passed through verbatim to the wire format.
    pub payload: Vec<u8>,
}

/// Outcome of a [`EventCache::range`] call.
#[derive(Debug)]
pub enum RangeOutcome {
    /// The requested seq range is wholly within the cache.
    /// `events` are returned in seq order.
    InWindow {
        /// Events in seq order starting at `from_seq + 1`.
        events: Vec<CachedEvent>,
    },
    /// The requested `from_seq` is older than the oldest cached
    /// event, OR the cache's front is a partial multi-event
    /// batch.  Carries the smallest `resume_from` the client
    /// can pass on a retry to receive a valid (complete-batch)
    /// stream — NOT necessarily the oldest seq in the cache.
    /// See [`EventCache::range`] for the partial-batch case
    /// where this differs from `oldest_seq()`.
    OutOfWindow {
        /// Smallest `resume_from` the client can pass on retry
        /// to receive a valid (complete-batch) event stream.
        /// In the normal case this is the cache's `oldest_seq`;
        /// in the partial-batch-front case (M-1 audit) it is
        /// `partial_seq + 1` to skip the incomplete batch.
        oldest_available_seq: u64,
    },
    /// The requested `from_seq` is at or past the cache's live
    /// tail (no events to deliver yet).  This is the common case
    /// when a client subscribes "from the live tail" via
    /// `resume_from = 0` or `resume_from = current_live_seq`.
    AtLiveTail,
}

/// Bounded FIFO cache of recent events, keyed by sequence number.
///
/// ## Invariants
///
///   * Events are inserted in **monotonically non-decreasing**
///     seq order.  Equal seqs across consecutive pushes are
///     **allowed** because a single log frame can produce
///     multiple events (e.g. `Action.transfer` emits both
///     sender and receiver `balanceChanged` events).  Strictly
///     decreasing pushes return [`PushError::OutOfOrder`].
///   * Capacity is bounded; the oldest event is evicted when the
///     cache reaches capacity.
///   * Seq=0 is reserved (clients pass `resume_from = 0` to mean
///     "no resume").  `push` rejects seq=0 as a `OutOfOrder` error.
///   * **Partial-batch eviction detection** (second-audit fix):
///     when eviction cuts a multi-event-per-frame batch (i.e.
///     evicts one event but leaves others at the same seq in
///     the cache), `range(from_seq)` with `from_seq < partial_seq`
///     returns `OutOfWindow` rather than delivering a partial
///     batch.  Without this defence, a late-arriving subscriber
///     could see (K, b), (K, c), ... when the extractor actually
///     emitted (K, a), (K, b), (K, c), ... — missing the first
///     event silently.
#[derive(Debug)]
pub struct EventCache {
    buffer: VecDeque<CachedEvent>,
    capacity: usize,
    /// Last seq pushed.  Used to enforce monotonicity.  `0` if
    /// no events have been pushed yet.
    last_pushed_seq: u64,
    /// Seq of the most-recently-evicted event, or `None` if no
    /// event has been evicted yet.  Used to detect partial-batch
    /// front in `range()`.  Per second-audit finding.
    last_evicted_seq: Option<u64>,
}

/// Errors returned by [`EventCache::push`].
#[derive(Debug, thiserror::Error)]
pub enum PushError {
    /// Attempted to push a seq that is strictly less than the
    /// previous one, OR a `seq == 0` (reserved).  Indicates an
    /// extractor bug.  Equal seqs across consecutive pushes are
    /// **legal** (multiple events per log frame).
    #[error("out-of-order push: tried to insert seq {tried} after seq {previous}")]
    OutOfOrder {
        /// The seq that was attempted.
        tried: u64,
        /// The previous (highest) seq in the cache.
        previous: u64,
    },
}

impl EventCache {
    /// Construct a new cache with the given capacity.  Capacity
    /// is clamped to [`HARD_MAX_KEEP_HISTORY`] (a defence-in-depth
    /// measure against library consumers passing `usize::MAX`).
    /// A capacity of `0` is rejected; the caller must use at
    /// least `1` (matching `--keep-history 1`).
    ///
    /// # Errors
    ///
    /// Returns `Err(NewCacheError::ZeroCapacity)` if `capacity == 0`.
    pub fn new(capacity: usize) -> Result<Self, NewCacheError> {
        if capacity == 0 {
            return Err(NewCacheError::ZeroCapacity);
        }
        let capacity = capacity.min(HARD_MAX_KEEP_HISTORY);
        Ok(Self {
            buffer: VecDeque::with_capacity(capacity),
            capacity,
            last_pushed_seq: 0,
            last_evicted_seq: None,
        })
    }

    /// Effective capacity (after clamping).
    #[must_use]
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// Number of cached events.
    #[must_use]
    pub fn len(&self) -> usize {
        self.buffer.len()
    }

    /// True iff no events are cached.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.buffer.is_empty()
    }

    /// Sequence number of the **oldest** cached event, or `None`
    /// if empty.
    #[must_use]
    pub fn oldest_seq(&self) -> Option<u64> {
        self.buffer.front().map(|e| e.seq)
    }

    /// Sequence number of the **newest** cached event (a.k.a.
    /// "live seq"), or `None` if empty.
    #[must_use]
    pub fn newest_seq(&self) -> Option<u64> {
        self.buffer.back().map(|e| e.seq)
    }

    /// Push a new event onto the cache.  Evicts the oldest event
    /// if at capacity.
    ///
    /// # Errors
    ///
    /// Returns [`PushError::OutOfOrder`] if `event.seq` is
    /// strictly less than the previous-highest seq, OR if
    /// `event.seq == 0` (reserved for "no resume" in the wire
    /// protocol).  Equal seqs across consecutive pushes are
    /// **allowed**: a single log frame can produce multiple
    /// events (e.g. `Action.transfer` emits both sender and
    /// receiver `balanceChanged` events).  The cache stores them
    /// as separate entries with the same seq; `range` returns
    /// them in push order.
    pub fn push(&mut self, event: CachedEvent) -> Result<(), PushError> {
        if event.seq == 0 || event.seq < self.last_pushed_seq {
            return Err(PushError::OutOfOrder {
                tried: event.seq,
                previous: self.last_pushed_seq,
            });
        }
        // Evict oldest if at capacity.  Track the evicted seq so
        // `range()` can detect a partial batch at the front.
        if self.buffer.len() == self.capacity {
            if let Some(evicted) = self.buffer.pop_front() {
                self.last_evicted_seq = Some(evicted.seq);
            }
        }
        self.last_pushed_seq = event.seq;
        self.buffer.push_back(event);
        Ok(())
    }

    /// Seq of the most-recently-evicted event, or `None` if none.
    #[must_use]
    pub fn last_evicted_seq(&self) -> Option<u64> {
        self.last_evicted_seq
    }

    /// True iff the cache currently has a partial batch at its
    /// front: the oldest cached event shares its seq with the
    /// most-recently-evicted event.  When true, backfill at a
    /// `from_seq` strictly less than that seq would deliver a
    /// partial batch and is rejected by [`Self::range`].
    #[must_use]
    pub fn has_partial_front(&self) -> bool {
        match (self.last_evicted_seq, self.buffer.front()) {
            (Some(evicted), Some(front)) => evicted == front.seq,
            _ => false,
        }
    }

    /// Query the cache for events with `seq > from_seq`.
    ///
    /// Returns:
    ///   * [`RangeOutcome::InWindow`] with the matching events
    ///     in seq order.  Empty `events` vec means "no events
    ///     past `from_seq` are cached"; combined with
    ///     `from_seq < newest_seq` this indicates the cache
    ///     lost the events to eviction (handled by the next case).
    ///   * [`RangeOutcome::OutOfWindow`] if `from_seq + 1` is
    ///     strictly older than the oldest cached event, OR if
    ///     the cache's front is a **partial batch** (some events
    ///     at the same seq were evicted) and `from_seq` is less
    ///     than that partial-batch seq — delivering events would
    ///     surface an incomplete batch.  Per third-audit fix.
    ///   * [`RangeOutcome::AtLiveTail`] if the cache is empty OR
    ///     `from_seq >= newest_seq` (nothing to backfill yet).
    ///
    /// **Special case: `from_seq = 0`.**  Treated as "give me
    /// everything currently in the cache."  If the cache is
    /// non-empty, returns `InWindow` with the full contents.
    /// If empty, returns `AtLiveTail`.  This matches the
    /// wire-format spec: `resume_from = 0` means "no resume,
    /// start from the live tail" — the cache is empty at startup
    /// so the subscriber begins streaming from the next extracted
    /// event.
    #[must_use]
    pub fn range(&self, from_seq: u64) -> RangeOutcome {
        if self.buffer.is_empty() {
            return RangeOutcome::AtLiveTail;
        }
        // Safe: buffer is non-empty.
        let oldest = self.buffer.front().expect("non-empty").seq;
        let newest = self.buffer.back().expect("non-empty").seq;
        // `resume_from = 0` is a request for "live tail"; the
        // subscriber will pick up events as the extractor produces
        // them.  Do not backfill the entire cache window.
        if from_seq == 0 {
            return RangeOutcome::AtLiveTail;
        }
        // `from_seq >= newest`: we have nothing newer to deliver
        // (cache is "live tail" relative to this subscriber).
        if from_seq >= newest {
            return RangeOutcome::AtLiveTail;
        }
        // `from_seq + 1 < oldest`: client wants events that have
        // been evicted from the cache.  Note we use `from_seq + 1`
        // because seqs are 1-indexed; if from_seq=3 and oldest=10,
        // the client wants seqs 4..=newest, but 4 is no longer
        // in the cache.
        if from_seq.saturating_add(1) < oldest {
            return RangeOutcome::OutOfWindow {
                oldest_available_seq: oldest,
            };
        }
        // Partial-batch front check (third-audit fix).  If the
        // oldest cached event shares its seq with a previously-
        // evicted event, the cache front is an incomplete batch.
        // A subscriber requesting from_seq < partial_seq would
        // receive the partial batch — a soft data-loss event.
        // Reject with OutOfWindow pointing at the next safe
        // resume point (after the partial batch's seq).
        if self.has_partial_front() {
            let partial_seq = oldest;
            if from_seq < partial_seq {
                return RangeOutcome::OutOfWindow {
                    oldest_available_seq: partial_seq.saturating_add(1),
                };
            }
        }
        // In-window: extract all events with seq > from_seq.
        // Since the buffer is in seq order, the filter could use
        // binary search.  Simpler implementation: linear scan
        // from the front.  At capacity = 256 this is trivially
        // cheap.
        let events: Vec<CachedEvent> = self
            .buffer
            .iter()
            .filter(|e| e.seq > from_seq)
            .cloned()
            .collect();
        RangeOutcome::InWindow { events }
    }

    /// Lookup a single event by sequence number.  Returns `None`
    /// if the event is not in the cache (either too old or
    /// not yet recorded).  Used by tests and diagnostic surfaces.
    #[must_use]
    pub fn get(&self, seq: u64) -> Option<CachedEvent> {
        // Linear scan; the cache is small.
        self.buffer.iter().find(|e| e.seq == seq).cloned()
    }
}

/// Errors returned by [`EventCache::new`].
#[derive(Debug, thiserror::Error)]
pub enum NewCacheError {
    /// Caller passed `capacity = 0`.
    #[error("EventCache capacity cannot be zero")]
    ZeroCapacity,
}

#[cfg(test)]
mod tests {
    use super::{
        CachedEvent, EventCache, NewCacheError, PushError, RangeOutcome, DEFAULT_KEEP_HISTORY,
        HARD_MAX_KEEP_HISTORY,
    };

    fn make_event(seq: u64) -> CachedEvent {
        CachedEvent {
            seq,
            payload: format!("event-{seq}").into_bytes(),
        }
    }

    /// Capacity constants are documented values.
    #[test]
    fn capacity_constants() {
        assert_eq!(DEFAULT_KEEP_HISTORY, 256);
        assert_eq!(HARD_MAX_KEEP_HISTORY, 1_000_000);
    }

    /// `new(0)` is rejected.
    #[test]
    fn zero_capacity_rejected() {
        match EventCache::new(0) {
            Err(NewCacheError::ZeroCapacity) => {}
            other => panic!("expected ZeroCapacity, got {other:?}"),
        }
    }

    /// `new(usize::MAX)` is clamped to HARD_MAX_KEEP_HISTORY.
    #[test]
    fn usize_max_capacity_clamped() {
        let cache = EventCache::new(usize::MAX).unwrap();
        assert_eq!(cache.capacity(), HARD_MAX_KEEP_HISTORY);
    }

    /// Empty cache: `range` returns `AtLiveTail`.
    #[test]
    fn empty_cache_at_live_tail() {
        let cache = EventCache::new(10).unwrap();
        match cache.range(0) {
            RangeOutcome::AtLiveTail => {}
            other => panic!("expected AtLiveTail, got {other:?}"),
        }
        match cache.range(100) {
            RangeOutcome::AtLiveTail => {}
            other => panic!("expected AtLiveTail, got {other:?}"),
        }
    }

    /// Push + len + oldest/newest accessors.
    #[test]
    fn push_advances_state() {
        let mut cache = EventCache::new(10).unwrap();
        assert_eq!(cache.len(), 0);
        assert!(cache.is_empty());
        assert_eq!(cache.oldest_seq(), None);
        assert_eq!(cache.newest_seq(), None);
        cache.push(make_event(1)).unwrap();
        assert_eq!(cache.len(), 1);
        assert!(!cache.is_empty());
        assert_eq!(cache.oldest_seq(), Some(1));
        assert_eq!(cache.newest_seq(), Some(1));
        cache.push(make_event(2)).unwrap();
        assert_eq!(cache.len(), 2);
        assert_eq!(cache.oldest_seq(), Some(1));
        assert_eq!(cache.newest_seq(), Some(2));
    }

    /// Out-of-order push (strictly less): monotonicity violated.
    #[test]
    fn out_of_order_push_rejected() {
        let mut cache = EventCache::new(10).unwrap();
        cache.push(make_event(5)).unwrap();
        match cache.push(make_event(3)) {
            Err(PushError::OutOfOrder { tried, previous }) => {
                assert_eq!(tried, 3);
                assert_eq!(previous, 5);
            }
            other => panic!("expected OutOfOrder, got {other:?}"),
        }
    }

    /// Equal-seq push: ACCEPTED (multi-event-per-frame support).
    /// A single log frame can produce multiple events that share
    /// the same seq (e.g. `transfer` emits both sender and
    /// receiver `balanceChanged` events).  The cache must store
    /// these as separate entries.
    #[test]
    fn equal_seq_push_accepted() {
        let mut cache = EventCache::new(10).unwrap();
        cache.push(make_event(5)).unwrap();
        // Second push at the same seq: legal, both events live.
        let event_b = CachedEvent {
            seq: 5,
            payload: b"event-b".to_vec(),
        };
        cache.push(event_b.clone()).unwrap();
        assert_eq!(cache.len(), 2);
        assert_eq!(cache.oldest_seq(), Some(5));
        assert_eq!(cache.newest_seq(), Some(5));
        // Range from before the seq returns both events in
        // push order.
        match cache.range(4) {
            RangeOutcome::InWindow { events } => {
                assert_eq!(events.len(), 2);
                assert_eq!(events[0].seq, 5);
                assert_eq!(events[1].seq, 5);
                assert_eq!(events[1].payload, b"event-b");
            }
            other => panic!("expected InWindow, got {other:?}"),
        }
        // Range at the seq returns AtLiveTail (we delivered up
        // to seq=5; nothing new).
        match cache.range(5) {
            RangeOutcome::AtLiveTail => {}
            other => panic!("expected AtLiveTail, got {other:?}"),
        }
    }

    /// Seq=0 push: rejected (seq=0 reserved for the wire-protocol).
    #[test]
    fn seq_zero_rejected() {
        let mut cache = EventCache::new(10).unwrap();
        match cache.push(make_event(0)) {
            Err(PushError::OutOfOrder { tried, .. }) => assert_eq!(tried, 0),
            other => panic!("expected OutOfOrder, got {other:?}"),
        }
    }

    /// Eviction when capacity is reached.
    #[test]
    fn eviction_when_capacity_reached() {
        let mut cache = EventCache::new(3).unwrap();
        cache.push(make_event(1)).unwrap();
        cache.push(make_event(2)).unwrap();
        cache.push(make_event(3)).unwrap();
        assert_eq!(cache.len(), 3);
        cache.push(make_event(4)).unwrap();
        // Should still be len=3 with oldest=2, newest=4.
        assert_eq!(cache.len(), 3);
        assert_eq!(cache.oldest_seq(), Some(2));
        assert_eq!(cache.newest_seq(), Some(4));
        assert!(cache.get(1).is_none());
        assert!(cache.get(2).is_some());
    }

    /// In-window range: returns events past `from_seq` in order.
    #[test]
    fn in_window_range() {
        let mut cache = EventCache::new(10).unwrap();
        for seq in 1..=5 {
            cache.push(make_event(seq)).unwrap();
        }
        match cache.range(2) {
            RangeOutcome::InWindow { events } => {
                assert_eq!(events.len(), 3);
                assert_eq!(events[0].seq, 3);
                assert_eq!(events[1].seq, 4);
                assert_eq!(events[2].seq, 5);
            }
            other => panic!("expected InWindow, got {other:?}"),
        }
    }

    /// Out-of-window range: oldest_available carried in the
    /// outcome.
    #[test]
    fn out_of_window_range() {
        let mut cache = EventCache::new(3).unwrap();
        // Push 5 events into a cache of size 3.  Cache holds seqs 3..=5.
        for seq in 1..=5 {
            cache.push(make_event(seq)).unwrap();
        }
        assert_eq!(cache.oldest_seq(), Some(3));
        // Request resume from seq=1; we don't have seqs 2,3 (well, we
        // do have 3, but the client wants events strictly after 1,
        // which starts at 2 which is gone).
        match cache.range(1) {
            RangeOutcome::OutOfWindow {
                oldest_available_seq,
            } => {
                assert_eq!(oldest_available_seq, 3);
            }
            other => panic!("expected OutOfWindow, got {other:?}"),
        }
    }

    /// Boundary: `from_seq + 1 == oldest` is in-window.
    #[test]
    fn boundary_oldest_minus_one_is_in_window() {
        let mut cache = EventCache::new(3).unwrap();
        for seq in 1..=5 {
            cache.push(make_event(seq)).unwrap();
        }
        // oldest = 3, newest = 5.  range(2) means "events > 2" =
        // {3, 4, 5}, all of which are in the cache.
        match cache.range(2) {
            RangeOutcome::InWindow { events } => {
                assert_eq!(events.len(), 3);
                assert_eq!(events[0].seq, 3);
            }
            other => panic!("expected InWindow, got {other:?}"),
        }
    }

    /// **Third-audit regression: partial-batch front is detected
    /// and reported as OutOfWindow rather than delivering a
    /// partial batch silently.**
    ///
    /// When a multi-event batch is partially evicted (some events
    /// at seq=K remain in cache, others were evicted), a
    /// subscriber resuming from `from_seq < K` would receive an
    /// incomplete batch.  The `has_partial_front` check causes
    /// `range` to return `OutOfWindow { oldest_available_seq: K+1 }`
    /// so the subscriber retries cleanly.
    #[test]
    fn partial_batch_front_returns_out_of_window() {
        // Capacity 2.  Push 3 events all at seq=5.  Cache will hold
        // only 2 of 3 (one event evicted).  last_evicted_seq=5,
        // has_partial_front=true.
        let mut cache = EventCache::new(2).unwrap();
        cache
            .push(CachedEvent {
                seq: 5,
                payload: b"a".to_vec(),
            })
            .unwrap();
        cache
            .push(CachedEvent {
                seq: 5,
                payload: b"b".to_vec(),
            })
            .unwrap();
        cache
            .push(CachedEvent {
                seq: 5,
                payload: b"c".to_vec(),
            })
            .unwrap();
        assert_eq!(cache.len(), 2);
        assert_eq!(cache.oldest_seq(), Some(5));
        assert_eq!(cache.last_evicted_seq(), Some(5));
        assert!(cache.has_partial_front());
        // range(4) would include events at seq=5 — but the
        // batch is partial.  Reject.
        match cache.range(4) {
            RangeOutcome::OutOfWindow {
                oldest_available_seq,
            } => assert_eq!(oldest_available_seq, 6),
            other => panic!("expected OutOfWindow, got {other:?}"),
        }
        // range(5) returns AtLiveTail (from_seq >= newest=5).
        match cache.range(5) {
            RangeOutcome::AtLiveTail => {}
            other => panic!("expected AtLiveTail, got {other:?}"),
        }
    }

    /// **Third-audit regression: non-partial front still
    /// allows backfill at the boundary.**
    ///
    /// If eviction removed events at seq=K entirely (no
    /// events at seq=K remain), the front is at seq=K+1 (or
    /// later) and `has_partial_front` is false.  A subscriber
    /// resuming from `from_seq < K+1` is fine — they get the
    /// complete K+1 batch.
    #[test]
    fn complete_eviction_front_is_in_window() {
        // Capacity 2.  Push events at seqs 5, 6, 7.  Cache
        // evicts (5), then (6), holding [(6), (7)] then [(7)]
        // — wait, let me trace.
        let mut cache = EventCache::new(2).unwrap();
        cache.push(make_event(5)).unwrap();
        cache.push(make_event(6)).unwrap();
        // Capacity reached.  Next push evicts.
        cache.push(make_event(7)).unwrap();
        assert_eq!(cache.len(), 2);
        assert_eq!(cache.oldest_seq(), Some(6));
        assert_eq!(cache.last_evicted_seq(), Some(5));
        // Front is seq=6, last evicted is seq=5: different.
        // No partial.
        assert!(!cache.has_partial_front());
        // range(5) wants events > 5 = {6, 7}, both in cache.
        match cache.range(5) {
            RangeOutcome::InWindow { events } => {
                assert_eq!(events.len(), 2);
                assert_eq!(events[0].seq, 6);
                assert_eq!(events[1].seq, 7);
            }
            other => panic!("expected InWindow, got {other:?}"),
        }
    }

    /// Boundary: `from_seq == newest` returns AtLiveTail.
    #[test]
    fn from_seq_equals_newest_is_at_live_tail() {
        let mut cache = EventCache::new(10).unwrap();
        for seq in 1..=3 {
            cache.push(make_event(seq)).unwrap();
        }
        match cache.range(3) {
            RangeOutcome::AtLiveTail => {}
            other => panic!("expected AtLiveTail, got {other:?}"),
        }
    }

    /// Boundary: `from_seq > newest` returns AtLiveTail.
    #[test]
    fn from_seq_past_newest_is_at_live_tail() {
        let mut cache = EventCache::new(10).unwrap();
        for seq in 1..=3 {
            cache.push(make_event(seq)).unwrap();
        }
        match cache.range(100) {
            RangeOutcome::AtLiveTail => {}
            other => panic!("expected AtLiveTail, got {other:?}"),
        }
    }

    /// `from_seq = 0` (no-resume): treated as AtLiveTail even on
    /// a populated cache.
    #[test]
    fn from_seq_zero_is_at_live_tail() {
        let mut cache = EventCache::new(10).unwrap();
        for seq in 1..=3 {
            cache.push(make_event(seq)).unwrap();
        }
        match cache.range(0) {
            RangeOutcome::AtLiveTail => {}
            other => panic!("expected AtLiveTail, got {other:?}"),
        }
    }

    /// `get(seq)` returns the cached event or None.
    #[test]
    fn get_by_seq() {
        let mut cache = EventCache::new(10).unwrap();
        for seq in 1..=3 {
            cache.push(make_event(seq)).unwrap();
        }
        assert_eq!(cache.get(1), Some(make_event(1)));
        assert_eq!(cache.get(3), Some(make_event(3)));
        assert_eq!(cache.get(4), None);
        assert_eq!(cache.get(0), None);
    }

    /// Capacity-1 edge case: each push evicts the previous.
    #[test]
    fn capacity_1_eviction() {
        let mut cache = EventCache::new(1).unwrap();
        cache.push(make_event(1)).unwrap();
        cache.push(make_event(2)).unwrap();
        cache.push(make_event(3)).unwrap();
        assert_eq!(cache.len(), 1);
        assert_eq!(cache.oldest_seq(), Some(3));
        assert_eq!(cache.newest_seq(), Some(3));
    }

    /// Capacity-1 + range: out-of-window when from_seq + 1 <
    /// newest.
    #[test]
    fn capacity_1_range_after_eviction() {
        let mut cache = EventCache::new(1).unwrap();
        cache.push(make_event(1)).unwrap();
        cache.push(make_event(2)).unwrap();
        // Cache holds only seq=2.  Request from seq=0 (live-tail).
        match cache.range(0) {
            RangeOutcome::AtLiveTail => {}
            other => panic!("expected AtLiveTail, got {other:?}"),
        }
        // Request from seq=1 (everything after 1): out of window
        // because oldest = 2, from+1 = 2, which is NOT < 2.  So
        // this is in-window — we return [2].
        match cache.range(1) {
            RangeOutcome::InWindow { events } => {
                assert_eq!(events.len(), 1);
                assert_eq!(events[0].seq, 2);
            }
            other => panic!("expected InWindow, got {other:?}"),
        }
        // After pushing seq=3, cache holds {3}.  Request from
        // seq=1 wants {2,3} but oldest=3.  from_seq+1=2 < 3, so
        // OutOfWindow.
        cache.push(make_event(3)).unwrap();
        match cache.range(1) {
            RangeOutcome::OutOfWindow {
                oldest_available_seq,
            } => assert_eq!(oldest_available_seq, 3),
            other => panic!("expected OutOfWindow, got {other:?}"),
        }
    }

    /// EventCache + CachedEvent are `Send + Sync` (server holds
    /// them behind a Mutex).
    #[test]
    fn cache_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<EventCache>();
        assert_send_sync::<CachedEvent>();
        assert_send_sync::<PushError>();
        assert_send_sync::<NewCacheError>();
    }

    /// Range correctness under churn: push N events at capacity
    /// K, then verify the cache window equals [N-K+1, N].
    #[test]
    fn range_under_churn() {
        let mut cache = EventCache::new(5).unwrap();
        for seq in 1..=20 {
            cache.push(make_event(seq)).unwrap();
        }
        assert_eq!(cache.len(), 5);
        assert_eq!(cache.oldest_seq(), Some(16));
        assert_eq!(cache.newest_seq(), Some(20));
        // range(15) means events > 15 = {16..=20}, all in cache.
        match cache.range(15) {
            RangeOutcome::InWindow { events } => {
                assert_eq!(events.len(), 5);
                for (i, e) in events.iter().enumerate() {
                    assert_eq!(e.seq, 16 + i as u64);
                }
            }
            other => panic!("expected InWindow, got {other:?}"),
        }
        // range(10) wants events > 10 = {11..=20}, but 11..=15 are
        // evicted.  OutOfWindow with oldest=16.
        match cache.range(10) {
            RangeOutcome::OutOfWindow {
                oldest_available_seq,
            } => assert_eq!(oldest_available_seq, 16),
            other => panic!("expected OutOfWindow, got {other:?}"),
        }
    }
}

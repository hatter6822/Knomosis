// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

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
    /// event.  Carries the oldest sequence the client could
    /// successfully resume from.
    OutOfWindow {
        /// Oldest seq the cache still holds.
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
///   * Events are inserted in **strictly monotonically
///     increasing** seq order.  `push` enforces this; out-of-order
///     pushes return [`PushError::OutOfOrder`] rather than
///     silently breaking the FIFO discipline.
///   * Capacity is bounded; the oldest event is evicted when the
///     cache reaches capacity.
///   * Seq=0 is reserved (clients pass `resume_from = 0` to mean
///     "no resume").  `push` rejects seq=0 as a `OutOfOrder` error.
#[derive(Debug)]
pub struct EventCache {
    buffer: VecDeque<CachedEvent>,
    capacity: usize,
    /// Last seq pushed.  Used to enforce monotonicity.  `0` if
    /// no events have been pushed yet.
    last_pushed_seq: u64,
}

/// Errors returned by [`EventCache::push`].
#[derive(Debug, thiserror::Error)]
pub enum PushError {
    /// Attempted to push a seq that is not strictly greater than
    /// the previous one.  Indicates an extractor bug.
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
    /// Returns [`PushError::OutOfOrder`] if `event.seq` is not
    /// strictly greater than the previous-highest seq.  Note: a
    /// `seq = 0` push is treated as out-of-order regardless of
    /// the previous state (since seq=0 is reserved for "no
    /// resume").
    pub fn push(&mut self, event: CachedEvent) -> Result<(), PushError> {
        if event.seq == 0 || event.seq <= self.last_pushed_seq {
            return Err(PushError::OutOfOrder {
                tried: event.seq,
                previous: self.last_pushed_seq,
            });
        }
        // Evict oldest if at capacity.
        if self.buffer.len() == self.capacity {
            self.buffer.pop_front();
        }
        self.last_pushed_seq = event.seq;
        self.buffer.push_back(event);
        Ok(())
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
    ///     strictly older than the oldest cached event.
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
        // In-window: extract all events with seq > from_seq.
        // Since the buffer is in seq order, we can binary search.
        // Simpler implementation: linear scan from the front.  At
        // capacity = 256 this is trivially cheap.
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

    /// Out-of-order push: monotonicity violated.
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
        // Duplicate seq also rejected.
        match cache.push(make_event(5)) {
            Err(PushError::OutOfOrder { tried, previous }) => {
                assert_eq!(tried, 5);
                assert_eq!(previous, 5);
            }
            other => panic!("expected OutOfOrder, got {other:?}"),
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

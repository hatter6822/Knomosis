// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G3.4a fan-out ring buffer + cursor registry.
//!
//! A bounded, FIFO ring of the most recent fanned-out [`EventRecord`]s —
//! the shared backlog every SSE client reads from.  Records carry their
//! **`(seq, index)`** [`Cursor`] (the intra-seq `index` is load-bearing for
//! the §6.1 composite-id resume; a single log `seq` can carry several
//! events, §11.4) and the **precomputed `data:` JSON** (the §6.2 event,
//! serialized ONCE at ingest and shared across all clients via the `Arc`).
//!
//! Two invariants make the ring the safe foundation for resume (G3.4d) and
//! resubscribe (G3.4b):
//!
//!   * **Strictly increasing.**  [`EventRing::push`] inserts a record only
//!     when its cursor is strictly after the last inserted one, so the ring
//!     is always a gap-free, ordered, contiguous *suffix* of the ingested
//!     stream.  A not-newer record is a duplicate (a resubscribe re-delivers
//!     the open group's already-seen head, §G3.4b) and is dropped — the
//!     fail-safe dedup.
//!   * **Last-complete-group watermark.**  [`EventRing::watermark`] is the
//!     highest seq provably *whole*: a group is complete only once the next
//!     seq begins (§11.4), so the watermark is the highest seq strictly
//!     below the newest ingested seq.  It — not the newest seq — is the safe
//!     upstream resubscribe point (resuming from the newest would skip an
//!     open group's unseen tail, finding #4).

use std::collections::VecDeque;
use std::sync::Arc;

/// A per-client resume cursor: a `(seq, index)` pair ordered
/// lexicographically (seq first, then the intra-seq index).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct Cursor {
    /// The event's log sequence number.
    pub seq: u64,
    /// The 0-based position within the `seq` group (§11.4 / §6.1).
    pub index: u32,
}

impl Cursor {
    /// The origin cursor `(0, 0)` — strictly before every real record
    /// (seqs are 1-indexed), so a fresh client positioned here replays the
    /// whole retained window.
    pub const ORIGIN: Cursor = Cursor { seq: 0, index: 0 };

    /// A cursor at `(seq, index)`.
    #[must_use]
    pub fn new(seq: u64, index: u32) -> Self {
        Self { seq, index }
    }
}

/// A fanned-out event record: its [`Cursor`] key, the SSE `event:` type
/// name (also the type-filter key), and the precomputed `data:` JSON
/// (the §6.2 `EventJson` serialized once, shared via the ring's `Arc`).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EventRecord {
    /// The event's log sequence number.
    pub seq: u64,
    /// The intra-seq index.
    pub index: u32,
    /// The event-type name (the SSE `event:` field + the `?type=` filter).
    pub event_type: String,
    /// The serialized §6.2 `EventJson` (the SSE `data:` field).
    pub data: String,
}

impl EventRecord {
    /// This record's `(seq, index)` cursor.
    #[must_use]
    pub fn cursor(&self) -> Cursor {
        Cursor {
            seq: self.seq,
            index: self.index,
        }
    }
}

/// Where a resume cursor sits relative to the ring's retained window
/// (computed by [`EventRing::position`]; drives the G3.4d resume tiers).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CursorPosition {
    /// At or after the newest retained record — caught up; nothing to
    /// replay yet (live records will follow).
    AtTail,
    /// Within the retained window — the records strictly after the cursor
    /// are a gap-free suffix available for immediate replay.
    InWindow,
    /// Behind the window — a record after the cursor was evicted, so the
    /// client may have a gap; steer it to `GET /events` (the `behind`
    /// signal, §3.5 / finding #7), never an SSE `truncated`.
    Behind {
        /// The oldest seq still retained (the backfill resume hint).
        oldest_seq: u64,
    },
}

/// A bounded, FIFO ring of recent fanned-out records shared by all SSE
/// clients.  See the module docs for the two load-bearing invariants
/// (strictly increasing; the last-complete-group watermark).
#[derive(Debug)]
pub struct EventRing {
    capacity: usize,
    buf: VecDeque<Arc<EventRecord>>,
    /// The last inserted cursor (the newest record's); persists across
    /// eviction.  `None` until the first insert.
    last: Option<Cursor>,
    /// The cursor of the most-recently-evicted record (the immediate
    /// predecessor of the oldest retained); `None` until the first
    /// eviction.  Distinguishes "the client saw a still-retainable record"
    /// from "a record after the client's cursor was evicted" (→ `Behind`).
    last_evicted: Option<Cursor>,
    /// The highest provably-complete seq — the highest seq strictly below
    /// the newest ingested seq.  `None` until a second distinct seq lands.
    watermark: Option<u64>,
}

impl EventRing {
    /// A ring retaining the most recent `capacity` records (clamped to
    /// `≥ 1`).
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            buf: VecDeque::new(),
            last: None,
            last_evicted: None,
            watermark: None,
        }
    }

    /// The number of retained records.
    #[must_use]
    pub fn len(&self) -> usize {
        self.buf.len()
    }

    /// Whether the ring holds no records.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    /// The retention capacity.
    #[must_use]
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// The oldest retained cursor, or `None` if empty.
    #[must_use]
    pub fn oldest(&self) -> Option<Cursor> {
        self.buf.front().map(|r| r.cursor())
    }

    /// The oldest retained seq (the `Behind` backfill hint), or `None`.
    #[must_use]
    pub fn oldest_seq(&self) -> Option<u64> {
        self.buf.front().map(|r| r.seq)
    }

    /// The newest retained cursor, or `None` if empty.
    #[must_use]
    pub fn newest(&self) -> Option<Cursor> {
        self.buf.back().map(|r| r.cursor())
    }

    /// The last-complete-group watermark — the safe upstream resubscribe
    /// point (G3.4b).  `None` until a second distinct seq is ingested.
    #[must_use]
    pub fn watermark(&self) -> Option<u64> {
        self.watermark
    }

    /// Ingest a record.  Returns `true` if inserted, `false` if it is not
    /// strictly after the last inserted cursor (a resubscribe-replay
    /// duplicate or an out-of-order frame — dropped, fail-safe).
    pub fn push(&mut self, record: EventRecord) -> bool {
        let cursor = record.cursor();
        if let Some(last) = self.last {
            if cursor <= last {
                return false; // dedup / out-of-order guard
            }
            // The previous newest seq is provably complete once a strictly
            // higher seq begins.
            if cursor.seq > last.seq {
                self.watermark = Some(last.seq);
            }
        }
        self.last = Some(cursor);
        self.buf.push_back(Arc::new(record));
        while self.buf.len() > self.capacity {
            if let Some(evicted) = self.buf.pop_front() {
                self.last_evicted = Some(evicted.cursor());
            }
        }
        true
    }

    /// All retained records strictly after `cursor`, in `(seq, index)`
    /// order (a gap-free suffix when `cursor` is [`CursorPosition::InWindow`]).
    #[must_use]
    pub fn records_after(&self, cursor: Cursor) -> Vec<Arc<EventRecord>> {
        self.buf
            .iter()
            .filter(|r| r.cursor() > cursor)
            .cloned()
            .collect()
    }

    /// Classify a resume `cursor` against the retained window (the G3.4d
    /// resume-tier decision).
    ///
    /// `InWindow` iff the client's next-unseen record is still retained:
    /// either nothing has ever been evicted, or the cursor is at-or-after
    /// the most-recently-evicted record (so the client already saw
    /// everything that was dropped).  A cursor *before* an evicted record
    /// is `Behind` (a possible gap); a cursor at-or-after the newest is
    /// `AtTail` (caught up).
    #[must_use]
    pub fn position(&self, cursor: Cursor) -> CursorPosition {
        let Some(newest) = self.newest() else {
            return CursorPosition::AtTail; // empty ring → caught up
        };
        if cursor >= newest {
            return CursorPosition::AtTail;
        }
        match self.last_evicted {
            // Nothing evicted → the ring holds the full ingested history,
            // so any cursor below the newest is served from the window.
            None => CursorPosition::InWindow,
            // The client saw the last-evicted record (or a later one) → no
            // gap; everything after the cursor is retained.
            Some(ev) if cursor >= ev => CursorPosition::InWindow,
            // The cursor predates an evicted record → a possible gap.
            Some(_) => CursorPosition::Behind {
                oldest_seq: self.oldest_seq().unwrap_or(0),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Cursor, CursorPosition, EventRecord, EventRing};
    use proptest::prelude::*;

    /// A record carrying its cursor; `data` mirrors the cursor so tests can
    /// assert identity cheaply.
    fn rec(seq: u64, index: u32) -> EventRecord {
        EventRecord {
            seq,
            index,
            event_type: "balanceChanged".to_string(),
            data: format!("{seq}.{index}"),
        }
    }

    #[test]
    fn push_dedups_and_orders() {
        let mut ring = EventRing::new(8);
        assert!(ring.push(rec(5, 0)));
        assert!(ring.push(rec(5, 1)));
        assert!(ring.push(rec(6, 0)));
        // A not-strictly-newer cursor is dropped (resubscribe replay dedup).
        assert!(!ring.push(rec(6, 0)));
        assert!(!ring.push(rec(5, 1)));
        assert!(!ring.push(rec(4, 9)));
        assert_eq!(ring.len(), 3);
        let all = ring.records_after(Cursor::ORIGIN);
        let cursors: Vec<_> = all.iter().map(|r| r.cursor()).collect();
        assert_eq!(
            cursors,
            vec![Cursor::new(5, 0), Cursor::new(5, 1), Cursor::new(6, 0)]
        );
    }

    #[test]
    fn watermark_tracks_the_last_complete_group() {
        let mut ring = EventRing::new(16);
        assert_eq!(ring.watermark(), None); // empty
        ring.push(rec(10, 0));
        assert_eq!(ring.watermark(), None); // one distinct seq → none complete
        ring.push(rec(10, 1));
        assert_eq!(ring.watermark(), None); // still group 10, still open
        ring.push(rec(11, 0));
        assert_eq!(ring.watermark(), Some(10)); // 11 began → 10 is whole
        ring.push(rec(11, 1));
        assert_eq!(ring.watermark(), Some(10)); // still group 11
        ring.push(rec(12, 0));
        assert_eq!(ring.watermark(), Some(11));
    }

    #[test]
    fn records_after_is_a_strict_suffix() {
        let mut ring = EventRing::new(16);
        for (s, i) in [(5, 0), (5, 1), (6, 0), (7, 0), (7, 1)] {
            ring.push(rec(s, i));
        }
        let after = ring.records_after(Cursor::new(6, 0));
        let cursors: Vec<_> = after.iter().map(|r| r.cursor()).collect();
        assert_eq!(cursors, vec![Cursor::new(7, 0), Cursor::new(7, 1)]);
        // The intra-seq skip: resuming mid-group 5 yields only 5.1 onward.
        let after = ring.records_after(Cursor::new(5, 0));
        let cursors: Vec<_> = after.iter().map(|r| r.cursor()).collect();
        assert_eq!(
            cursors,
            vec![
                Cursor::new(5, 1),
                Cursor::new(6, 0),
                Cursor::new(7, 0),
                Cursor::new(7, 1)
            ]
        );
    }

    #[test]
    fn position_tiers() {
        let mut ring = EventRing::new(3);
        // Empty ring → AtTail.
        assert_eq!(ring.position(Cursor::ORIGIN), CursorPosition::AtTail);
        for (s, i) in [(5, 0), (6, 0), (7, 0)] {
            ring.push(rec(s, i));
        }
        // Nothing evicted yet → any sub-newest cursor is InWindow.
        assert_eq!(ring.position(Cursor::ORIGIN), CursorPosition::InWindow);
        assert_eq!(ring.position(Cursor::new(5, 0)), CursorPosition::InWindow);
        // At / past the newest → AtTail.
        assert_eq!(ring.position(Cursor::new(7, 0)), CursorPosition::AtTail);
        assert_eq!(ring.position(Cursor::new(9, 0)), CursorPosition::AtTail);

        // Overflow: evict (5,0); ring = [(6,0),(7,0),(8,0)], last_evicted=(5,0).
        ring.push(rec(8, 0));
        // A client that saw (5,0) — the evicted record — has no gap: its
        // next-unseen (6,0) is retained → InWindow.
        assert_eq!(ring.position(Cursor::new(5, 0)), CursorPosition::InWindow);
        // A client behind the evicted record → possible gap → Behind.
        assert_eq!(
            ring.position(Cursor::new(4, 0)),
            CursorPosition::Behind { oldest_seq: 6 }
        );
        assert_eq!(
            ring.position(Cursor::ORIGIN),
            CursorPosition::Behind { oldest_seq: 6 }
        );
    }

    /// Re-inserts on resubscribe (cursors `≤ last`) are dropped, so a
    /// client never receives a record twice across a reconnect.
    #[test]
    fn resubscribe_replay_is_deduped() {
        let mut ring = EventRing::new(16);
        for (s, i) in [(10, 0), (11, 0), (11, 1)] {
            ring.push(rec(s, i));
        }
        // Resubscribe from the watermark (10) re-delivers group 11's head.
        assert_eq!(ring.watermark(), Some(10));
        assert!(!ring.push(rec(11, 0))); // already present
        assert!(!ring.push(rec(11, 1))); // already present
        assert!(ring.push(rec(11, 2))); // the genuinely-new tail
        assert_eq!(ring.len(), 4);
    }

    // ---- Property tests against an oracle stream (the G3.4a acceptance) ----

    /// The oracle: replay the same dedup/insert rule the ring uses, so the
    /// expected retained set, watermark, and eviction frontier are
    /// independently derived from the raw `(seq, index)` stream.
    struct Oracle {
        inserted: Vec<Cursor>, // every accepted cursor, in order
    }

    impl Oracle {
        fn build(stream: &[(u64, u32)]) -> Self {
            let mut inserted: Vec<Cursor> = Vec::new();
            for &(seq, index) in stream {
                let c = Cursor::new(seq, index);
                if inserted.last().is_none_or(|&last| c > last) {
                    inserted.push(c);
                }
            }
            Self { inserted }
        }

        fn retained(&self, capacity: usize) -> &[Cursor] {
            let cap = capacity.max(1);
            let start = self.inserted.len().saturating_sub(cap);
            &self.inserted[start..]
        }

        /// The 2nd-highest distinct seq (the highest strictly below the max).
        fn watermark(&self) -> Option<u64> {
            let max = self.inserted.last()?.seq;
            self.inserted
                .iter()
                .map(|c| c.seq)
                .filter(|&s| s < max)
                .max()
        }
    }

    proptest! {
        /// Ordering + gap-freeness + integrity + watermark: the ring's
        /// retained records exactly equal the oracle's retained suffix (a
        /// strictly-increasing contiguous tail of the deduped stream), and
        /// the watermark matches the 2nd-highest distinct seq.
        #[test]
        fn ring_matches_the_oracle(
            stream in proptest::collection::vec((1u64..12, 0u32..4), 0..64),
            capacity in 1usize..16,
        ) {
            let oracle = Oracle::build(&stream);
            let mut ring = EventRing::new(capacity);
            for &(seq, index) in &stream {
                ring.push(rec(seq, index));
            }

            let got: Vec<Cursor> = ring
                .records_after(Cursor::ORIGIN)
                .iter()
                .map(|r| r.cursor())
                .collect();
            let want: Vec<Cursor> = oracle.retained(capacity).to_vec();
            prop_assert_eq!(&got, &want, "retained suffix mismatch");

            // Strictly increasing (ordering + gap-free as a set of cursors).
            for w in got.windows(2) {
                prop_assert!(w[0] < w[1], "not strictly increasing");
            }
            // Bounded by capacity.
            prop_assert!(ring.len() <= capacity);
            // Watermark correctness: never into a still-open group.
            prop_assert_eq!(ring.watermark(), oracle.watermark());
            if let (Some(w), Some(newest)) = (ring.watermark(), ring.newest()) {
                prop_assert!(w < newest.seq, "watermark advanced into the open group");
            }
        }

        /// `records_after` returns exactly the retained records strictly
        /// greater than the query cursor — a gap-free suffix — and a client
        /// stepping one record at a time visits each exactly once in order.
        #[test]
        fn records_after_is_gap_free_and_single_step(
            stream in proptest::collection::vec((1u64..12, 0u32..4), 0..48),
            capacity in 1usize..16,
            q_seq in 0u64..12,
            q_index in 0u32..4,
        ) {
            let mut ring = EventRing::new(capacity);
            for &(seq, index) in &stream {
                ring.push(rec(seq, index));
            }
            let all: Vec<Cursor> = ring
                .records_after(Cursor::ORIGIN)
                .iter()
                .map(|r| r.cursor())
                .collect();
            let query = Cursor::new(q_seq, q_index);
            let after: Vec<Cursor> = ring
                .records_after(query)
                .iter()
                .map(|r| r.cursor())
                .collect();
            // `after` is exactly the tail of `all` whose cursor > query.
            let want: Vec<Cursor> = all.iter().copied().filter(|&c| c > query).collect();
            prop_assert_eq!(&after, &want);

            // Single-step: advancing the cursor one record at a time over
            // `after` yields the same sequence (each visited exactly once).
            let mut cursor = query;
            let mut stepped = Vec::new();
            while let Some(next) = ring.records_after(cursor).first().map(|r| r.cursor()) {
                stepped.push(next);
                cursor = next;
            }
            prop_assert_eq!(&stepped, &want);
        }

        /// `position` agrees with the oracle: AtTail at/after the newest;
        /// Behind iff a record after the cursor was evicted; InWindow
        /// otherwise.
        #[test]
        fn position_matches_the_oracle(
            stream in proptest::collection::vec((1u64..12, 0u32..4), 1..48),
            capacity in 1usize..12,
            q_seq in 0u64..13,
            q_index in 0u32..4,
        ) {
            let oracle = Oracle::build(&stream);
            let mut ring = EventRing::new(capacity);
            for &(seq, index) in &stream {
                ring.push(rec(seq, index));
            }
            let query = Cursor::new(q_seq, q_index);
            let retained = oracle.retained(capacity);
            // The oracle's eviction frontier: the cursor just before the
            // retained suffix (None if nothing evicted).
            let evicted_frontier = {
                let kept = retained.len();
                let total = oracle.inserted.len();
                if total > kept {
                    Some(oracle.inserted[total - kept - 1])
                } else {
                    None
                }
            };
            let want = match retained.last() {
                None => CursorPosition::AtTail,
                Some(&newest) if query >= newest => CursorPosition::AtTail,
                Some(_) => match evicted_frontier {
                    None => CursorPosition::InWindow,
                    Some(ev) if query >= ev => CursorPosition::InWindow,
                    Some(_) => CursorPosition::Behind {
                        oldest_seq: retained[0].seq,
                    },
                },
            };
            prop_assert_eq!(ring.position(query), want);
        }
    }
}

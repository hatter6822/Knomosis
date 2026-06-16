// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G3.4d SSE resume semantics + the intra-seq skip.
//!
//! Decomposes the resume request — the WHATWG `Last-Event-ID` header (which
//! takes precedence) or the `since` query parameter (§3.5 step 1) — into a
//! ring [`Cursor`], then classifies it against the live fan-out ring:
//!
//!   * **In-window / caught-up** → [`ResumeAction::Stream`] from just after
//!     the cursor.  The **intra-seq skip** is exactly the cursor comparison
//!     `(seq, index) > (resume_seq, resume_index)` ([`EventRing::records_after`]
//!     in G3.4c) — so a reconnect mid seq-group redelivers the group's unseen
//!     tail with **no loss and no duplication**, and **no upstream re-read**
//!     (§6.1): a resume only repositions a cursor in the already-shared ring,
//!     so it never adds an upstream subscription (the G3.4b O(1) invariant
//!     holds across reconnects).
//!   * **Behind the ring** → [`ResumeAction::Behind`] with the oldest ring
//!     seq: steer the client to the `GET /events` backfill (which owns the
//!     larger, authoritative history window), **never** an SSE `truncated`
//!     (only `GET /events` can determine genuine upstream truncation,
//!     finding #7).
//!   * **Older than the upstream history** → [`ResumeAction::Truncated`],
//!     reachable only when the caller supplies a known upstream-oldest seq
//!     proving even the backfill cannot serve the point.
//!
//! A composite `Last-Event-ID = "<seq>.<index>"` resumes mid-group; a **bare**
//! seq (`"<seq>"` or `since=S`) excludes `S`'s *whole* group (`seq > S`),
//! encoded as the cursor `(S, u32::MAX)`.

use super::ring::{Cursor, CursorPosition, EventRing};

/// A parsed SSE resume point.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResumePoint {
    /// No resume (no `Last-Event-ID`, and `since` absent or `0`): start from
    /// the live tail — only records produced from now on, no backfill.
    LiveTail,
    /// Resume strictly after this cursor.
    After(Cursor),
}

/// What to do with a resume point against the current ring.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResumeAction {
    /// Stream records strictly after this cursor (in-window / caught-up /
    /// live-tail).  Hand this to the G3.4c `run_stream`.
    Stream(Cursor),
    /// The resume point predates the ring; emit `event: error{behind}` and
    /// steer the client to the `GET /events` backfill (§3.5 / finding #7).
    Behind {
        /// The oldest seq still in the ring (the backfill resume hint).
        oldest_seq: u64,
    },
    /// The resume point predates the upstream history entirely; emit
    /// `event: error{truncated}` (only reachable with a known upstream-oldest
    /// seq — see [`classify_resume`]).
    Truncated,
}

/// Decompose the resume request: the `last_event_id` header (precedence)
/// else `since`.  A malformed `Last-Event-ID` falls through to `since`
/// (lenient — a browser may echo an opaque value).
#[must_use]
pub fn parse_resume(last_event_id: Option<&str>, since: Option<u64>) -> ResumePoint {
    if let Some(cursor) = last_event_id.and_then(parse_event_id) {
        return ResumePoint::After(cursor);
    }
    match since {
        None | Some(0) => ResumePoint::LiveTail,
        // A bare seq excludes its whole group: `seq > S`.
        Some(seq) => ResumePoint::After(Cursor::new(seq, u32::MAX)),
    }
}

/// Parse a `Last-Event-ID` value: `"<seq>.<index>"` (mid-group resume) or a
/// bare `"<seq>"` (excludes the whole group, via index `u32::MAX`).  `None`
/// for any malformed value.
fn parse_event_id(id: &str) -> Option<Cursor> {
    let id = id.trim();
    match id.split_once('.') {
        Some((seq, index)) => Some(Cursor::new(seq.parse().ok()?, index.parse().ok()?)),
        None => Some(Cursor::new(id.parse().ok()?, u32::MAX)),
    }
}

/// Classify a resume point against the current `ring`.
///
/// `upstream_oldest` is an optional known oldest seq still in the *upstream*
/// history: when supplied and the resume point predates it, the point is
/// [`ResumeAction::Truncated`] (even the backfill cannot serve it).  When
/// `None` (the default SSE path), a behind-ring point is always
/// [`ResumeAction::Behind`] — the steer to `GET /events`, never an SSE
/// `truncated` (finding #7).
#[must_use]
pub fn classify_resume(
    ring: &EventRing,
    point: ResumePoint,
    upstream_oldest: Option<u64>,
) -> ResumeAction {
    let cursor = match point {
        // Live-tail: stream only future records (from the current newest).
        ResumePoint::LiveTail => {
            return ResumeAction::Stream(ring.newest().unwrap_or(Cursor::ORIGIN));
        }
        ResumePoint::After(cursor) => cursor,
    };
    match ring.position(cursor) {
        CursorPosition::InWindow | CursorPosition::AtTail => ResumeAction::Stream(cursor),
        CursorPosition::Behind { oldest_seq } => match upstream_oldest {
            Some(upstream) if cursor.seq < upstream => ResumeAction::Truncated,
            _ => ResumeAction::Behind { oldest_seq },
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{classify_resume, parse_resume, ResumeAction, ResumePoint};
    use crate::events::fanout::ring::{Cursor, EventRecord, EventRing};

    fn rec(seq: u64, index: u32) -> EventRecord {
        EventRecord {
            seq,
            index,
            event_type: "balanceChanged".to_string(),
            data: format!("{seq}.{index}"),
        }
    }

    fn ring_with(records: &[(u64, u32)], capacity: usize) -> EventRing {
        let mut ring = EventRing::new(capacity);
        for &(s, i) in records {
            ring.push(rec(s, i));
        }
        ring
    }

    #[test]
    fn parses_composite_and_bare_resume_ids() {
        // Composite: mid-group resume.
        assert_eq!(
            parse_resume(Some("104233.2"), None),
            ResumePoint::After(Cursor::new(104_233, 2))
        );
        // Bare seq: excludes the whole group (index = MAX).
        assert_eq!(
            parse_resume(Some("104233"), None),
            ResumePoint::After(Cursor::new(104_233, u32::MAX))
        );
        // Whitespace is tolerated.
        assert_eq!(
            parse_resume(Some(" 7.1 "), None),
            ResumePoint::After(Cursor::new(7, 1))
        );
    }

    #[test]
    fn last_event_id_takes_precedence_over_since() {
        assert_eq!(
            parse_resume(Some("9.0"), Some(3)),
            ResumePoint::After(Cursor::new(9, 0))
        );
    }

    #[test]
    fn since_and_live_tail_fallbacks() {
        // A bare since excludes its group.
        assert_eq!(
            parse_resume(None, Some(5)),
            ResumePoint::After(Cursor::new(5, u32::MAX))
        );
        // No resume / since=0 → live tail.
        assert_eq!(parse_resume(None, None), ResumePoint::LiveTail);
        assert_eq!(parse_resume(None, Some(0)), ResumePoint::LiveTail);
    }

    #[test]
    fn malformed_last_event_id_falls_through_to_since() {
        // Non-numeric / partial ids are ignored; `since` is used instead.
        assert_eq!(
            parse_resume(Some("not-a-cursor"), Some(4)),
            ResumePoint::After(Cursor::new(4, u32::MAX))
        );
        assert_eq!(parse_resume(Some("5."), None), ResumePoint::LiveTail);
        assert_eq!(parse_resume(Some(".1"), None), ResumePoint::LiveTail);
        assert_eq!(parse_resume(Some("1.2.3"), None), ResumePoint::LiveTail);
    }

    #[test]
    fn mid_seq_group_resume_redelivers_exactly_the_unseen_records() {
        // THE headline correctness case (§6.1): a client that last saw
        // (5, 1) resumes mid-group 5; it must receive exactly 5.2 then 6.0 —
        // no loss (5.2 not skipped), no dup (5.0 / 5.1 not re-sent).
        let ring = ring_with(&[(5, 0), (5, 1), (5, 2), (6, 0)], 64);
        let point = parse_resume(Some("5.1"), None);
        let action = classify_resume(&ring, point, None);
        let cursor = match action {
            ResumeAction::Stream(c) => c,
            other => panic!("expected Stream, got {other:?}"),
        };
        let unseen: Vec<Cursor> = ring
            .records_after(cursor)
            .iter()
            .map(|r| r.cursor())
            .collect();
        assert_eq!(unseen, vec![Cursor::new(5, 2), Cursor::new(6, 0)]);
    }

    #[test]
    fn bare_seq_resume_excludes_the_whole_group() {
        // Last-Event-ID "5" (bare) resumes at seq > 5 — group 5 fully
        // excluded, group 6 delivered.
        let ring = ring_with(&[(5, 0), (5, 1), (6, 0)], 64);
        let action = classify_resume(&ring, parse_resume(Some("5"), None), None);
        let cursor = match action {
            ResumeAction::Stream(c) => c,
            other => panic!("expected Stream, got {other:?}"),
        };
        let unseen: Vec<Cursor> = ring
            .records_after(cursor)
            .iter()
            .map(|r| r.cursor())
            .collect();
        assert_eq!(unseen, vec![Cursor::new(6, 0)]);
    }

    #[test]
    fn live_tail_streams_only_future_records() {
        let ring = ring_with(&[(5, 0), (6, 0)], 64);
        let action = classify_resume(&ring, ResumePoint::LiveTail, None);
        let cursor = match action {
            ResumeAction::Stream(c) => c,
            other => panic!("expected Stream, got {other:?}"),
        };
        // The cursor is the current newest, so the backlog is excluded.
        assert_eq!(cursor, Cursor::new(6, 0));
        assert!(ring.records_after(cursor).is_empty());
    }

    #[test]
    fn caught_up_cursor_streams_future_records() {
        // A resume at/after the newest is caught up → Stream (await future).
        let ring = ring_with(&[(5, 0), (6, 0)], 64);
        let action = classify_resume(&ring, parse_resume(Some("6.0"), None), None);
        assert_eq!(action, ResumeAction::Stream(Cursor::new(6, 0)));
    }

    #[test]
    fn behind_ring_steers_to_backfill_not_truncated() {
        // A small ring evicts; a resume before the retained window is
        // `Behind` (steer to GET /events) — NEVER an SSE `truncated` when the
        // upstream-oldest is unknown (finding #7).
        let ring = ring_with(&[(1, 0), (2, 0), (3, 0), (4, 0), (5, 0)], 2);
        // Ring now retains [(4,0),(5,0)]; a resume from (1,0) is behind.
        let action = classify_resume(&ring, parse_resume(Some("1.0"), None), None);
        assert_eq!(action, ResumeAction::Behind { oldest_seq: 4 });
    }

    #[test]
    fn older_than_upstream_is_truncated_only_with_a_known_floor() {
        let ring = ring_with(&[(10, 0), (11, 0), (12, 0), (13, 0)], 2);
        // Ring retains [(12,0),(13,0)] (evicted frontier (11,0)); a resume
        // from seq 5 is behind the ring. With a known upstream-oldest of 9,
        // seq 5 < 9 → Truncated.
        let action = classify_resume(&ring, parse_resume(Some("5.0"), None), Some(9));
        assert_eq!(action, ResumeAction::Truncated);
        // A resume from (10,0) is behind the evicted frontier (a gap at the
        // evicted (11,0)) but seq 10 >= the upstream-oldest 9, so the
        // backfill can still serve it → only Behind, not Truncated.
        let action = classify_resume(&ring, parse_resume(Some("10.0"), None), Some(9));
        assert_eq!(action, ResumeAction::Behind { oldest_seq: 12 });
    }

    #[test]
    fn classify_is_pure_over_the_ring_no_upstream_subscription() {
        // The O(1)-across-reconnects invariant (G3.4b): a resume only
        // repositions a cursor in the shared ring — `classify_resume` takes
        // only `&EventRing` (no upstream handle), so it cannot, by
        // construction, open an upstream subscription.  Determinism witnesses
        // the purity.
        let ring = ring_with(&[(5, 0), (5, 1), (6, 0)], 64);
        let point = parse_resume(Some("5.0"), None);
        let a = classify_resume(&ring, point, None);
        let b = classify_resume(&ring, point, None);
        assert_eq!(a, b);
        assert_eq!(a, ResumeAction::Stream(Cursor::new(5, 0)));
    }
}

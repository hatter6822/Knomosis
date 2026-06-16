// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G3.3 bounded event backfill: a *cursor-paginated page* over the
//! *unbounded* event-subscribe SUBSCRIBE stream (§11.3), the catch-up
//! complement of the live SSE stream (G3.4).
//!
//! A naïve "open a subscription, drain to `limit`" is wrong three ways;
//! this module addresses each (plan §G3.3, findings #2 / #5):
//!
//!   * **Bounded by a captured tip.**  The scan stops at the `tip` the
//!     caller captured at request start (the indexer cursor), so it
//!     **never blocks** waiting for future live events the subscription
//!     would otherwise hand back.  `has_more = false` means "caught up to
//!     that tip".  A short read-idle timeout is the belt-and-braces
//!     fallback when the upstream cache is momentarily behind the tip (it
//!     goes silent at its own live tail rather than sending a frame).
//!   * **Group-complete pages.**  One `seq` may carry several events
//!     (§11.4); a page never ends mid seq-group.  The drain rounds up to
//!     the next seq boundary at-or-after `limit`, so `next_cursor` is
//!     always a *completed-group* seq — resuming from it neither skips a
//!     group's tail nor redelivers its head.  `limit` is thus a **soft
//!     lower bound**.
//!   * **`since` semantics.**  `since = S ≥ 1` resumes at `seq > S`.
//!     `since = 0` means "from the oldest retained" (NOT live-tail, which
//!     §11.3 reserves for `resume_from = 0`): the drain resumes from `1`
//!     and transparently follows the upstream's `TRUNCATED` to the oldest
//!     cached seq.  A `TRUNCATED` for a *concrete* `since ≥ 1` is the
//!     contract's `409` ([`BackfillError::Truncated`]).
//!
//! A decode failure on a **known** tag is corruption and **fails closed**
//! ([`BackfillError::Render`] → a `503` problem) — never silently skipped
//! or mislabelled (§2 principle 7, mirroring the SSE `decode_error`).

use std::net::SocketAddr;
use std::time::Duration;

use serde_json::json;

use super::decode::{render_event, DecodeError, EventJson};
use super::subscribe::{ReconnectReason, StreamItem, UpstreamSubscription};

/// How many consecutive non-progress reconnects (connect failure, drop,
/// server shutdown, lag, protocol error) the drain tolerates before
/// giving up with [`BackfillError::Upstream`].  An [`StreamItem::Event`]
/// resets the budget (progress was made); a `StaleTimeout` is the
/// caught-up stop, not a failure.
const RECONNECT_BUDGET: u32 = 4;

/// How many `TRUNCATED`-driven resumes a `since = 0` ("from oldest")
/// drain tolerates before treating the upstream as pathologically
/// flapping ([`BackfillError::Upstream`]).  A healthy upstream truncates
/// at most once (then the resumed cursor is in-window).
const MAX_GAPS: u32 = 2;

/// A backfill page request, parsed + validated by the router
/// (`since`/`limit`/`type` query parameters).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BackfillRequest {
    /// Return events with `seq` strictly greater than this; `0` = "from
    /// the oldest retained".
    pub since: u64,
    /// Soft lower bound on the page size (the drain rounds up to a
    /// complete seq-group).  The router clamps it to the contract's
    /// `1..=1000`.
    pub limit: usize,
    /// Optional event-type-name filter (empty = all types).  Applied
    /// gateway-side against the rendered `type`.
    pub types: Vec<String>,
}

/// A rendered backfill page: the contract's `EventPage`
/// (`{events, nextCursor, hasMore}`).  (`EventJson` carries a
/// `serde_json::Value`, so the page is not `Eq`/`PartialEq` — tests
/// assert on its fields.)
#[derive(Clone, Debug)]
pub struct EventPage {
    /// The rendered events in `(seq, index)` order.
    pub events: Vec<EventJson>,
    /// The seq to pass as the next `since` (a completed-group seq, or the
    /// request's `since` when nothing was drained).
    pub next_cursor: u64,
    /// Whether more events `≤ tip` remain (the page hit `limit` before the
    /// tip); `false` = caught up to the captured tip.
    pub has_more: bool,
}

impl EventPage {
    /// Serialize to the contract `EventPage` JSON (`nextCursor` is a
    /// decimal string per the §2 bigint-as-string rule).  Infallible in
    /// practice; falls back to an empty page on the impossible serde
    /// error so the path stays panic-free (§3.2).
    #[must_use]
    pub fn to_json(&self) -> String {
        serde_json::to_string(&json!({
            "events": self.events,
            "nextCursor": self.next_cursor.to_string(),
            "hasMore": self.has_more,
        }))
        .unwrap_or_else(|_| r#"{"events":[],"nextCursor":"0","hasMore":false}"#.to_string())
    }
}

/// A backfill failure mapped to an HTTP problem by the dispatcher.
#[derive(Debug, thiserror::Error)]
pub enum BackfillError {
    /// The requested concrete cursor predates the upstream history window
    /// (the §11 `TRUNCATED` frame) — the contract's `409`.
    #[error("cursor predates history window; oldest resumable seq is {oldest_seq}")]
    Truncated {
        /// The oldest still-resumable seq (the `oldestSeq` extension).
        oldest_seq: u64,
    },
    /// An upstream event could not be rendered (a known-tag decode
    /// failure — corruption — or an unparseable head): fail closed.
    #[error("event render failed: {detail}")]
    Render {
        /// The decode diagnostic.
        detail: String,
    },
    /// The upstream was unreachable, rejected the handshake, or was too
    /// unstable to drain a page — the contract's `503`.
    #[error("event-subscribe upstream unavailable: {reason}")]
    Upstream {
        /// The failure diagnostic.
        reason: String,
    },
}

/// Drain a bounded page from the event-subscribe upstream at `addr`.
///
/// `tip` bounds the scan from above (the indexer cursor captured at
/// request start); `None` (no indexer configured) drains until caught up
/// to the live tail.  `idle_timeout` is the per-read staleness watchdog
/// that detects "caught up" (the server goes silent at its live tail).
///
/// # Errors
///
/// [`BackfillError::Truncated`] when a concrete `since ≥ 1` predates the
/// history window; [`BackfillError::Render`] when an upstream event fails
/// to decode (fail closed); [`BackfillError::Upstream`] when the upstream
/// is unreachable / rejecting / too unstable.
pub fn backfill(
    addr: SocketAddr,
    tip: Option<u64>,
    max_frame_size: usize,
    idle_timeout: Duration,
    req: &BackfillRequest,
) -> Result<EventPage, BackfillError> {
    // `resume_from = 0` is reserved for live-tail; "from oldest" resumes
    // from 1 and follows the upstream's TRUNCATED to the oldest cached seq.
    let resume_from = if req.since == 0 { 1 } else { req.since };
    let mut sub = UpstreamSubscription::new(addr, resume_from, max_frame_size, Some(idle_timeout));
    let mut builder = PageBuilder::new(req.since, req.limit, tip, &req.types);
    let mut reconnect_budget = RECONNECT_BUDGET;
    let mut gaps_seen = 0u32;

    loop {
        match sub.recv() {
            StreamItem::Event { seq, payload } => {
                reconnect_budget = RECONNECT_BUDGET; // progress resets the budget
                if matches!(builder.offer(seq, &payload)?, Flow::Stop) {
                    break;
                }
            }
            StreamItem::Gap {
                oldest_available_seq,
            } => {
                // A concrete cursor predating the window is the 409; for
                // "from oldest" (`since = 0`) the resume-from-oldest is the
                // expected path, not an error.
                if req.since != 0 {
                    return Err(BackfillError::Truncated {
                        oldest_seq: oldest_available_seq,
                    });
                }
                gaps_seen += 1;
                if gaps_seen > MAX_GAPS {
                    return Err(BackfillError::Upstream {
                        reason: "history truncated repeatedly".to_string(),
                    });
                }
            }
            StreamItem::Reconnecting { reason } => {
                if reason == ReconnectReason::StaleTimeout {
                    builder.caught_up(); // silent live tail → caught up
                    break;
                }
                reconnect_budget = reconnect_budget.saturating_sub(1);
                if reconnect_budget == 0 {
                    return Err(BackfillError::Upstream {
                        reason: format!("upstream unstable ({reason:?})"),
                    });
                }
            }
            StreamItem::Rejected => {
                return Err(BackfillError::Upstream {
                    reason: "subscription handshake rejected".to_string(),
                });
            }
        }
    }
    Ok(builder.into_page())
}

/// Whether the drain loop should keep reading or stop.
enum Flow {
    /// Keep draining.
    Continue,
    /// Stop: the builder has set `has_more` and finalised its groups.
    Stop,
}

/// Accumulates drained events into group-complete pages, applying the
/// soft `limit`, the `tip` bound, and the gateway-side type filter.
///
/// **Group discipline.**  Events are buffered per seq-group; a group is
/// flushed into the page only once it is known complete (a higher seq
/// arrived, the tip was passed, or the stream caught up).  The per-event
/// `index` counts over the *full* (pre-filter) group, so the SSE composite
/// resume id (`seq.index`, G3.4) stays consistent even when a type filter
/// drops some of a group's events from the REST page.
struct PageBuilder<'a> {
    limit: usize,
    tip: Option<u64>,
    types: &'a [String],
    /// Completed, flushed events.
    events: Vec<EventJson>,
    /// The current (possibly incomplete) group's kept events.
    group: Vec<EventJson>,
    /// The seq of the current group, or `None` before the first event.
    group_seq: Option<u64>,
    /// The count of events seen in the current group *before* filtering
    /// (the next event's `index`).
    group_index: u32,
    /// The last completed-group seq (the next cursor); seeded with `since`.
    next_cursor: u64,
    has_more: bool,
}

impl<'a> PageBuilder<'a> {
    fn new(since: u64, limit: usize, tip: Option<u64>, types: &'a [String]) -> Self {
        Self {
            limit,
            tip,
            types,
            events: Vec::new(),
            group: Vec::new(),
            group_seq: None,
            group_index: 0,
            next_cursor: since,
            has_more: false,
        }
    }

    /// Offer one drained event; decide whether to continue or stop.
    fn offer(&mut self, seq: u64, payload: &[u8]) -> Result<Flow, BackfillError> {
        // 1. Beyond the captured tip → every group ≤ tip is complete; we
        //    have caught up to the tip (more may exist beyond it, but this
        //    request is bounded by the tip it captured).
        if let Some(t) = self.tip {
            if seq > t {
                self.flush();
                self.has_more = false;
                return Ok(Flow::Stop);
            }
        }
        // 2. A new seq closes the previous group; apply the soft limit at
        //    this safe boundary (never mid-group).
        if self.group_seq.is_some_and(|gs| gs != seq) {
            self.flush();
            if self.events.len() >= self.limit {
                self.has_more = true; // the just-arrived event (≤ tip) remains
                return Ok(Flow::Stop);
            }
        }
        // 3. Render + accumulate.  The index counts over the full group;
        //    the type filter only decides REST-page inclusion.
        let index = self.group_index;
        self.group_index += 1;
        let rendered =
            render_event(payload, seq, index).map_err(|e: DecodeError| BackfillError::Render {
                detail: e.to_string(),
            })?;
        if self.types.is_empty() || self.types.iter().any(|t| *t == rendered.event_type) {
            self.group.push(rendered);
        }
        self.group_seq = Some(seq);
        Ok(Flow::Continue)
    }

    /// The stream caught up to the live tail: the current group is
    /// complete and nothing more remains within the window.
    fn caught_up(&mut self) {
        self.flush();
        self.has_more = false;
    }

    /// Move the current (now-complete) group into the page and advance the
    /// cursor to its seq.  A no-op before the first event.
    fn flush(&mut self) {
        if let Some(gs) = self.group_seq {
            self.events.append(&mut self.group);
            self.next_cursor = gs;
        }
        self.group_index = 0;
    }

    fn into_page(self) -> EventPage {
        EventPage {
            events: self.events,
            next_cursor: self.next_cursor,
            has_more: self.has_more,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{backfill, BackfillError, BackfillRequest};
    use knomosis_indexer::client::KIND_EVENT;
    use knomosis_indexer::client::{KIND_INVALID_REQUEST, KIND_TRUNCATED};
    use knomosis_indexer::decoder::encode_event;
    use knomosis_indexer::event::Event;
    use std::io::{Read, Write};
    use std::net::{SocketAddr, TcpListener};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    /// A short idle timeout so the "caught up" (server-silent) path
    /// resolves quickly in tests.
    const TEST_IDLE: Duration = Duration::from_millis(150);

    /// One scripted server frame.
    #[derive(Clone)]
    enum Frame {
        /// An event frame at `seq` carrying a real CBE `Event` payload.
        Event(u64, Event),
        /// A `TRUNCATED` control frame (oldest resumable seq).
        Truncated(u64),
        /// An `INVALID_REQUEST` (handshake rejection).
        Reject,
        /// Keep the connection open + idle (→ the client's read times out,
        /// surfacing the caught-up "StaleTimeout"); held until test stop.
        Hold,
    }

    fn encode_frame(frame: &Frame) -> Option<Vec<u8>> {
        match frame {
            Frame::Event(seq, ev) => {
                let payload = encode_event(ev);
                let mut v = vec![KIND_EVENT];
                v.extend_from_slice(&seq.to_be_bytes());
                #[allow(clippy::cast_possible_truncation)]
                v.extend_from_slice(&(payload.len() as u32).to_be_bytes());
                v.extend_from_slice(&payload);
                Some(v)
            }
            Frame::Truncated(s) => Some(one_u64(KIND_TRUNCATED, *s)),
            Frame::Reject => Some(one_u64(KIND_INVALID_REQUEST, 0)),
            Frame::Hold => None,
        }
    }

    fn one_u64(kind: u8, v: u64) -> Vec<u8> {
        let mut out = vec![kind];
        out.extend_from_slice(&v.to_be_bytes());
        out
    }

    /// A mock event-subscribe server: each connection is served the next
    /// scripted batch (recording the handshake `resume_from`), then either
    /// holds the connection open + idle (a `Hold` frame) or closes it
    /// (EOF).  A stop flag tears it down cleanly regardless of how many
    /// connections the client made.
    struct MockServer {
        addr: SocketAddr,
        stop: Arc<AtomicBool>,
        handshakes: std::sync::mpsc::Receiver<u64>,
        handle: Option<thread::JoinHandle<()>>,
    }

    impl Drop for MockServer {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(h) = self.handle.take() {
                let _ = h.join();
            }
        }
    }

    fn mock_server(scripts: Vec<Vec<Frame>>) -> MockServer {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let addr = listener.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let halt = Arc::clone(&stop);
        let (tx, rx) = std::sync::mpsc::channel();
        let handle = thread::spawn(move || {
            let mut scripts = scripts.into_iter();
            while !halt.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        let mut handshake = [0u8; 9];
                        if stream.read_exact(&mut handshake).is_err() {
                            continue;
                        }
                        let _ = tx.send(u64::from_be_bytes(handshake[1..9].try_into().unwrap()));
                        serve(&mut stream, &scripts.next().unwrap_or_default(), &halt);
                    }
                    Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });
        MockServer {
            addr,
            stop,
            handshakes: rx,
            handle: Some(handle),
        }
    }

    /// Write a connection's frames; on `Hold`, park (keeping the stream
    /// open + idle) until the stop flag fires.
    fn serve(stream: &mut std::net::TcpStream, frames: &[Frame], halt: &AtomicBool) {
        for frame in frames {
            if let Some(bytes) = encode_frame(frame) {
                if stream.write_all(&bytes).is_err() {
                    return;
                }
            } else {
                // Hold: keep the stream alive + idle until stop.
                while !halt.load(Ordering::Relaxed) {
                    thread::sleep(Duration::from_millis(5));
                }
                return;
            }
        }
        // End of script with no Hold → drop `stream` (EOF).
    }

    fn balance(seq: u64, actor: u64) -> Frame {
        Frame::Event(
            seq,
            Event::BalanceChanged {
                resource: 0,
                actor,
                old_value: 1000,
                new_value: 900,
            },
        )
    }

    fn req(since: u64, limit: usize, types: &[&str]) -> BackfillRequest {
        BackfillRequest {
            since,
            limit,
            types: types.iter().map(|s| (*s).to_string()).collect(),
        }
    }

    #[test]
    fn drains_a_simple_page_up_to_the_tip() {
        // Events 11, 12, 13; tip = 13. After 13's group, the next event
        // (14 > tip) stops the scan → has_more = false (caught up to tip).
        let server = mock_server(vec![vec![
            balance(11, 1),
            balance(12, 2),
            balance(13, 3),
            balance(14, 4), // beyond tip → stop
        ]]);
        let page = backfill(
            server.addr,
            Some(13),
            1 << 20,
            TEST_IDLE,
            &req(10, 100, &[]),
        )
        .unwrap();
        assert_eq!(page.events.len(), 3);
        assert_eq!(page.next_cursor, 13);
        assert!(!page.has_more, "reached the captured tip");
        assert_eq!(page.events[0].seq, "11");
        assert_eq!(page.events[2].seq, "13");
        assert_eq!(server.handshakes.recv().unwrap(), 10); // since=10 → resume_from 10
    }

    #[test]
    fn caught_up_via_idle_timeout_without_hanging() {
        // No event beyond the tip; the server holds open + idle after the
        // last event → the read times out → caught up (has_more = false).
        let server = mock_server(vec![vec![balance(5, 1), balance(6, 2), Frame::Hold]]);
        let page = backfill(server.addr, Some(99), 1 << 20, TEST_IDLE, &req(4, 100, &[])).unwrap();
        assert_eq!(page.events.len(), 2);
        assert_eq!(page.next_cursor, 6);
        assert!(!page.has_more);
    }

    #[test]
    fn never_splits_a_seq_group_across_a_page() {
        // seq 20 carries THREE events (a multi-event frame, §11.4); with
        // limit = 2 the page must still include all of group 20 (rounding
        // up to the group boundary) and stop before group 21.
        let server = mock_server(vec![vec![
            balance(20, 1),
            balance(20, 2),
            balance(20, 3),
            balance(21, 4), // a new group → boundary; limit (2) already met
            balance(21, 5),
            Frame::Hold,
        ]]);
        let page = backfill(server.addr, Some(99), 1 << 20, TEST_IDLE, &req(19, 2, &[])).unwrap();
        // The whole of group 20 is delivered (3 events ≥ the limit of 2),
        // and the page stops at the 20→21 boundary.
        assert_eq!(page.events.len(), 3, "group 20 not split");
        assert!(page.events.iter().all(|e| e.seq == "20"));
        // The per-group index runs 0,1,2 over the full group.
        assert_eq!(page.events[0].index, 0);
        assert_eq!(page.events[1].index, 1);
        assert_eq!(page.events[2].index, 2);
        assert_eq!(page.next_cursor, 20, "a completed-group cursor");
        assert!(page.has_more, "group 21 remains");
    }

    #[test]
    fn concrete_since_below_window_is_truncated() {
        // since = 7 (concrete) but the cache truncated to oldest = 50.
        let server = mock_server(vec![vec![Frame::Truncated(50)]]);
        let err = backfill(server.addr, Some(99), 1 << 20, TEST_IDLE, &req(7, 100, &[]))
            .expect_err("truncated");
        assert!(matches!(err, BackfillError::Truncated { oldest_seq: 50 }));
    }

    #[test]
    fn since_zero_follows_truncation_to_the_oldest_retained() {
        // since = 0 ("from oldest"): the first connection (resume_from = 1)
        // truncates to oldest = 50; the drain transparently resumes from 50
        // and delivers 51, 52 — no 409.
        let server = mock_server(vec![
            vec![Frame::Truncated(50)],
            vec![balance(51, 1), balance(52, 2), Frame::Hold],
        ]);
        let page = backfill(server.addr, Some(99), 1 << 20, TEST_IDLE, &req(0, 100, &[])).unwrap();
        assert_eq!(page.events.len(), 2);
        assert_eq!(page.events[0].seq, "51");
        assert_eq!(page.next_cursor, 52);
        assert!(!page.has_more);
        assert_eq!(server.handshakes.recv().unwrap(), 1); // since=0 → resume_from 1
        assert_eq!(server.handshakes.recv().unwrap(), 50); // resumed from oldest
    }

    #[test]
    fn type_filter_keeps_index_over_the_full_group() {
        // Group 30 carries a balanceChanged then a nonceAdvanced; a
        // `type=nonceAdvanced` filter keeps only the second, but its index
        // is 1 (its position in the FULL group), so the SSE resume id stays
        // consistent.
        let server = mock_server(vec![vec![
            balance(30, 1),
            Frame::Event(
                30,
                Event::NonceAdvanced {
                    actor: 1,
                    old_nonce: 4,
                    new_nonce: 5,
                },
            ),
            Frame::Hold,
        ]]);
        let page = backfill(
            server.addr,
            Some(99),
            1 << 20,
            TEST_IDLE,
            &req(29, 100, &["nonceAdvanced"]),
        )
        .unwrap();
        assert_eq!(page.events.len(), 1);
        assert_eq!(page.events[0].event_type, "nonceAdvanced");
        assert_eq!(page.events[0].index, 1, "index over the full group");
        assert_eq!(page.next_cursor, 30);
    }

    #[test]
    fn corrupt_known_tag_fails_closed() {
        // A KIND_EVENT frame whose payload is a valid 9-byte head for tag 0
        // (balanceChanged) but with NO field bytes → a known-tag decode
        // failure → fail closed (Render), not a silent skip.
        let mut payload = vec![0x00];
        payload.extend_from_slice(&0u64.to_le_bytes()); // tag 0, no body
        let mut framed = vec![KIND_EVENT];
        framed.extend_from_slice(&5u64.to_be_bytes());
        #[allow(clippy::cast_possible_truncation)]
        framed.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        framed.extend_from_slice(&payload);
        // Hand-script the raw frame via a tiny one-shot server.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            if let Ok((mut s, _)) = listener.accept() {
                let mut hs = [0u8; 9];
                let _ = s.read_exact(&mut hs);
                let _ = s.write_all(&framed);
            }
        });
        let err =
            backfill(addr, Some(99), 1 << 20, TEST_IDLE, &req(4, 100, &[])).expect_err("corrupt");
        assert!(matches!(err, BackfillError::Render { .. }));
        let _ = handle.join();
    }

    #[test]
    fn empty_page_when_already_at_the_live_tail() {
        // The server holds open immediately (no events) → caught up → an
        // empty page with the request's `since` as the cursor.
        let server = mock_server(vec![vec![Frame::Hold]]);
        let page = backfill(
            server.addr,
            Some(99),
            1 << 20,
            TEST_IDLE,
            &req(40, 100, &[]),
        )
        .unwrap();
        assert!(page.events.is_empty());
        assert_eq!(page.next_cursor, 40);
        assert!(!page.has_more);
    }

    #[test]
    fn rejected_handshake_is_an_upstream_error() {
        let server = mock_server(vec![vec![Frame::Reject]]);
        let err = backfill(server.addr, Some(99), 1 << 20, TEST_IDLE, &req(4, 100, &[]))
            .expect_err("rejected");
        assert!(matches!(err, BackfillError::Upstream { .. }));
    }

    #[test]
    fn unreachable_upstream_is_an_error_not_a_hang() {
        // Bind then drop a listener → an address nothing listens on.
        let probe = TcpListener::bind("127.0.0.1:0").unwrap();
        let dead: SocketAddr = probe.local_addr().unwrap();
        drop(probe);
        let err = backfill(dead, Some(99), 1 << 20, TEST_IDLE, &req(4, 100, &[]))
            .expect_err("unreachable");
        assert!(matches!(err, BackfillError::Upstream { .. }));
    }

    #[test]
    fn page_serializes_to_the_contract_shape() {
        let server = mock_server(vec![vec![balance(11, 161), Frame::Hold]]);
        let page = backfill(
            server.addr,
            Some(99),
            1 << 20,
            TEST_IDLE,
            &req(10, 100, &[]),
        )
        .unwrap();
        let v: serde_json::Value = serde_json::from_str(&page.to_json()).unwrap();
        assert_eq!(v["nextCursor"], "11");
        assert_eq!(v["hasMore"], false);
        assert_eq!(v["events"][0]["type"], "balanceChanged");
        assert_eq!(v["events"][0]["actor"], "161");
        assert_eq!(v["events"][0]["seq"], "11");
    }
}

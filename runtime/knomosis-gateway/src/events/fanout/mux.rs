// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G3.4b upstream multiplexer: a shared live-tail event-subscribe
//! subscription feeds the shared ring, fanned out to many SSE clients (each
//! reads the ring; none holds its own upstream socket — the
//! O(1)-subscribers-in-N-clients property, finding #6).
//!
//! Each [`Mux`] runs **one** subscription.  `--upstream-subscriptions N` (the
//! default `1`) makes [`crate::http::serve`] spawn `N` muxes that all feed the
//! **same** ring — a redundancy / availability knob: because the ring `push`
//! dedups on `(seq, index)` (below), `N > 1` loses no record and delivers none
//! twice, it just ingests each event up to `N` times into the dedup gate.
//!
//! **Resubscribe from the watermark, not the newest seq (finding #4).**  On
//! any interruption the mux recreates the subscription from the ring's
//! last-complete-group [`watermark`](super::ring::EventRing::watermark) (or,
//! before any group has completed, from the oldest seen seq minus one to
//! replay the open group from its start) — **never** the newest delivered
//! seq, which (after a mid-group drop) would ask for `seq > M` and skip
//! group `M`'s unseen tail for every downstream client.  Resuming from the
//! watermark re-delivers the open group's already-ingested head; the ring's
//! strictly-increasing [`push`](super::ring::EventRing::push) **dedups** it
//! on `(seq, index)`, so no record is lost and none is delivered twice.
//!
//! A `TRUNCATED` (the resume point fell out of the upstream's history)
//! resumes from the oldest still-available seq instead — a client spanning
//! that discontinuity is classified [`Behind`](super::ring::CursorPosition)
//! by the ring and steered to the `GET /events` backfill (§3.5).
//!
//! A known-tag decode failure is corruption and **fails closed**: the mux
//! records the fault on the shared [`FanoutState`] and stops ingesting,
//! rather than silently skipping or mislabelling a record (§2 principle 7).

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use super::ring::EventRecord;
use super::FanoutState;
use crate::events::decode::{render_event, DecodeError};
use crate::events::subscribe::{StreamItem, UpstreamSubscription};

/// The first reconnect-backoff delay after a non-progress epoch.
const BACKOFF_BASE: Duration = Duration::from_millis(100);
/// The reconnect-backoff cap.
const BACKOFF_CAP: Duration = Duration::from_secs(5);
/// The granularity at which an interruptible backoff sleep re-checks the
/// shutdown flag (so shutdown stays responsive during a backoff).
const SHUTDOWN_POLL: Duration = Duration::from_millis(20);

/// The single-subscription multiplexer feeding the shared fan-out ring.
pub struct Mux {
    addr: SocketAddr,
    max_frame_size: usize,
    /// The upstream-read staleness timeout: a live-tail read blocks until a
    /// frame OR this elapses (then the mux reconnects a possibly-dead
    /// socket from the watermark).  Generous in production (quiet periods
    /// are normal); short in tests.  Also bounds shutdown responsiveness.
    stale_timeout: Duration,
    state: Arc<FanoutState>,
}

/// How one subscription epoch ended.
enum EpochEnd {
    /// Recreate the subscription from `resume_from`; `progressed` is whether
    /// any event was ingested this epoch (drives the backoff).
    Resubscribe {
        /// The resume point for the next epoch.
        resume_from: u64,
        /// Whether any event landed this epoch.
        progressed: bool,
    },
    /// Stop the mux: a fail-closed decode fault was recorded.
    Fault,
}

impl Mux {
    /// A multiplexer to `addr` feeding `state`'s ring, bounding event
    /// payloads at `max_frame_size`, with the given upstream-read staleness
    /// timeout.
    #[must_use]
    pub fn new(
        addr: SocketAddr,
        max_frame_size: usize,
        stale_timeout: Duration,
        state: Arc<FanoutState>,
    ) -> Self {
        Self {
            addr,
            max_frame_size,
            stale_timeout,
            state,
        }
    }

    /// Spawn the ingest loop on a dedicated thread.  Setting `shutdown`
    /// stops it within (at most) `stale_timeout` — or immediately if the
    /// upstream connection closes.
    #[must_use]
    pub fn spawn(self, shutdown: Arc<AtomicBool>) -> JoinHandle<()> {
        std::thread::spawn(move || self.run(shutdown.as_ref()))
    }

    /// Run the ingest loop until `shutdown` is set or a fail-closed decode
    /// fault occurs.  Blocking; intended for a dedicated thread.
    pub fn run(&self, shutdown: &AtomicBool) {
        let mut resume_from = 0u64; // live-tail initially
        let mut backoff = BACKOFF_BASE;
        while !shutdown.load(Ordering::Relaxed) {
            match self.run_epoch(resume_from, shutdown) {
                EpochEnd::Fault => return,
                EpochEnd::Resubscribe {
                    resume_from: next,
                    progressed,
                } => {
                    resume_from = next;
                    if progressed {
                        backoff = BACKOFF_BASE; // a live upstream → no backoff next time
                    } else {
                        sleep_interruptible(backoff, shutdown);
                        backoff = (backoff * 2).min(BACKOFF_CAP);
                    }
                }
            }
        }
    }

    /// One subscription lifecycle: connect, ingest until the first
    /// interruption (or a decode fault), and report how to resume.
    fn run_epoch(&self, resume_from: u64, shutdown: &AtomicBool) -> EpochEnd {
        let mut sub = UpstreamSubscription::new(
            self.addr,
            resume_from,
            self.max_frame_size,
            Some(self.stale_timeout),
        );
        let mut index = IndexCounter::new(); // reset per subscription (re-derives indices)
        let mut progressed = false;
        loop {
            if shutdown.load(Ordering::Relaxed) {
                return EpochEnd::Resubscribe {
                    resume_from,
                    progressed,
                };
            }
            match sub.recv() {
                StreamItem::Event { seq, payload } => {
                    progressed = true;
                    let idx = index.next(seq);
                    match render_record(seq, idx, &payload) {
                        Ok(record) => {
                            self.state.ring().push(record); // dedups on (seq, index)
                        }
                        Err(err) => {
                            // Fail closed: a known-tag decode failure is
                            // corruption — record it and stop ingesting.
                            self.state.set_fault(err.to_string());
                            return EpochEnd::Fault;
                        }
                    }
                }
                StreamItem::Gap {
                    oldest_available_seq,
                } => {
                    // History truncated: resume from the oldest available,
                    // NOT the watermark (which predates the window). The ring
                    // classifies a client spanning the gap as `Behind`.
                    return EpochEnd::Resubscribe {
                        resume_from: oldest_available_seq,
                        progressed,
                    };
                }
                StreamItem::Reconnecting { .. } | StreamItem::Rejected => {
                    // A drop / staleness / shutdown / rejection: resubscribe
                    // from the last-complete-group watermark (finding #4).
                    return EpochEnd::Resubscribe {
                        resume_from: self.next_resume(resume_from),
                        progressed,
                    };
                }
            }
        }
    }

    /// The watermark-based resume point after a drop: the last-complete-group
    /// watermark; else (only an open group seen) the oldest seq minus one,
    /// to replay that group from its start; else the previous resume point.
    fn next_resume(&self, previous: u64) -> u64 {
        let ring = self.state.ring();
        ring.watermark()
            .or_else(|| ring.oldest_seq().map(|s| s.saturating_sub(1)))
            .unwrap_or(previous)
    }
}

/// Derives the intra-seq `index` (the §6.1 composite-id component) from the
/// stream of frame seqs: 0 for the first event of a seq, then 1, 2, … for
/// each subsequent same-seq event.  Reset per subscription so a watermark
/// resubscribe re-derives the *same* `(seq, index)` for re-delivered
/// records (the ring then dedups them).
struct IndexCounter {
    seq: Option<u64>,
    index: u32,
}

impl IndexCounter {
    fn new() -> Self {
        Self {
            seq: None,
            index: 0,
        }
    }

    /// The next index for `seq`, advancing the counter.
    fn next(&mut self, seq: u64) -> u32 {
        if self.seq != Some(seq) {
            self.seq = Some(seq);
            self.index = 0;
        }
        let idx = self.index;
        self.index += 1;
        idx
    }
}

/// Render a frame to a ring record: decode to the §6.2 `EventJson`
/// ([G3.2](crate::events::decode)) and precompute its serialized `data:`
/// payload + `event:` type name (once, shared across all clients).
fn render_record(seq: u64, index: u32, payload: &[u8]) -> Result<EventRecord, DecodeError> {
    let json = render_event(payload, seq, index)?;
    let data = serde_json::to_string(&json).unwrap_or_default();
    Ok(EventRecord {
        seq,
        index,
        event_type: json.event_type,
        data,
    })
}

/// Sleep for `dur`, re-checking `shutdown` every [`SHUTDOWN_POLL`] so a
/// backoff never delays a shutdown by more than that granularity.
fn sleep_interruptible(dur: Duration, shutdown: &AtomicBool) {
    let mut slept = Duration::ZERO;
    while slept < dur && !shutdown.load(Ordering::Relaxed) {
        let step = SHUTDOWN_POLL.min(dur.checked_sub(slept).unwrap());
        std::thread::sleep(step);
        slept += step;
    }
}

#[cfg(test)]
mod tests {
    use super::{render_record, IndexCounter, Mux};
    use crate::events::fanout::ring::Cursor;
    use crate::events::fanout::FanoutState;
    use knomosis_indexer::client::KIND_EVENT;
    use knomosis_indexer::decoder::encode_event;
    use knomosis_indexer::event::Event;
    use std::io::{Read, Write};
    use std::net::{SocketAddr, TcpListener};
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    const TEST_STALE: Duration = Duration::from_millis(150);

    fn balance_payload(actor: u64) -> Vec<u8> {
        encode_event(&Event::BalanceChanged {
            resource: 0,
            actor,
            old_value: 1000,
            new_value: 900,
        })
    }

    /// One scripted server frame.
    #[derive(Clone)]
    enum Frame {
        /// An `EVENT` frame at `seq` (the payload content is immaterial to
        /// the ring's `(seq, index)` keying; the mux derives the index).
        Event(u64),
        /// Close the connection (a drop → the mux resubscribes).
        Close,
        /// Hold the connection open + idle until test stop.
        Hold,
    }

    fn encode_frame(frame: &Frame) -> Option<Vec<u8>> {
        match frame {
            Frame::Event(seq) => {
                let payload = balance_payload(*seq);
                let mut v = vec![KIND_EVENT];
                v.extend_from_slice(&seq.to_be_bytes());
                v.extend_from_slice(&u32::try_from(payload.len()).unwrap().to_be_bytes());
                v.extend_from_slice(&payload);
                Some(v)
            }
            Frame::Close | Frame::Hold => None,
        }
    }

    /// A mock event-subscribe server: serves each connection the next
    /// scripted batch (recording the handshake `resume_from` + counting
    /// accepts), holding open after an exhausted script so the mux blocks
    /// rather than hot-looping.
    struct MockUpstream {
        addr: SocketAddr,
        accepts: Arc<AtomicUsize>,
        handshakes: std::sync::Mutex<std::sync::mpsc::Receiver<u64>>,
        stop: Arc<AtomicBool>,
        handle: Option<thread::JoinHandle<()>>,
    }

    impl Drop for MockUpstream {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(h) = self.handle.take() {
                let _ = h.join();
            }
        }
    }

    impl MockUpstream {
        fn start(scripts: Vec<Vec<Frame>>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let addr = listener.local_addr().unwrap();
            let accepts = Arc::new(AtomicUsize::new(0));
            let stop = Arc::new(AtomicBool::new(false));
            let (tx, rx) = std::sync::mpsc::channel();
            let halt = Arc::clone(&stop);
            let acc = Arc::clone(&accepts);
            let handle = thread::spawn(move || {
                let mut scripts = scripts.into_iter();
                while !halt.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            stream.set_nonblocking(false).unwrap();
                            let mut hs = [0u8; 9];
                            if stream.read_exact(&mut hs).is_err() {
                                continue;
                            }
                            acc.fetch_add(1, Ordering::Relaxed);
                            let _ = tx.send(u64::from_be_bytes(hs[1..9].try_into().unwrap()));
                            // An exhausted script Holds (blocks) so the mux
                            // does not hot-loop reconnect.
                            let script = scripts.next().unwrap_or_else(|| vec![Frame::Hold]);
                            serve(&mut stream, &script, &halt);
                        }
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(5));
                        }
                        Err(_) => break,
                    }
                }
            });
            Self {
                addr,
                accepts,
                handshakes: std::sync::Mutex::new(rx),
                stop,
                handle: Some(handle),
            }
        }

        fn accept_count(&self) -> usize {
            self.accepts.load(Ordering::Relaxed)
        }

        fn next_handshake(&self, timeout: Duration) -> Option<u64> {
            self.handshakes.lock().unwrap().recv_timeout(timeout).ok()
        }
    }

    fn serve(stream: &mut std::net::TcpStream, frames: &[Frame], halt: &AtomicBool) {
        for frame in frames {
            if let Some(bytes) = encode_frame(frame) {
                if stream.write_all(&bytes).is_err() {
                    return;
                }
            } else if matches!(frame, Frame::Hold) {
                while !halt.load(Ordering::Relaxed) {
                    thread::sleep(Duration::from_millis(5));
                }
                return;
            } else {
                return; // Close
            }
        }
    }

    /// Poll `f` until it is true or `deadline` elapses.
    fn wait_until(deadline: Duration, mut f: impl FnMut() -> bool) -> bool {
        let start = Instant::now();
        while start.elapsed() < deadline {
            if f() {
                return true;
            }
            thread::sleep(Duration::from_millis(5));
        }
        f()
    }

    #[test]
    fn index_counter_derives_intra_seq_indices() {
        let mut c = IndexCounter::new();
        assert_eq!(c.next(5), 0);
        assert_eq!(c.next(5), 1);
        assert_eq!(c.next(5), 2);
        assert_eq!(c.next(6), 0); // a new seq resets the index
        assert_eq!(c.next(6), 1);
    }

    #[test]
    fn render_record_carries_seq_index_type_and_json() {
        let rec = render_record(7, 1, &balance_payload(42)).expect("renders");
        assert_eq!(rec.seq, 7);
        assert_eq!(rec.index, 1);
        assert_eq!(rec.event_type, "balanceChanged");
        // The `data:` is the §6.2 envelope carrying the same (seq, index).
        let v: serde_json::Value = serde_json::from_str(&rec.data).unwrap();
        assert_eq!(v["seq"], "7");
        assert_eq!(v["index"], 1);
        assert_eq!(v["type"], "balanceChanged");
        assert_eq!(v["actor"], "42");
    }

    #[test]
    fn ingests_a_simple_live_tail_into_the_ring() {
        let mock = MockUpstream::start(vec![vec![Frame::Event(5), Frame::Event(6), Frame::Hold]]);
        let state = FanoutState::new(64);
        let mux = Mux::new(mock.addr, 1 << 20, TEST_STALE, Arc::clone(&state));
        let shutdown = Arc::new(AtomicBool::new(false));
        let handle = mux.spawn(Arc::clone(&shutdown));

        assert!(
            wait_until(Duration::from_secs(2), || state.ring().len() == 2),
            "both events ingested"
        );
        let cursors: Vec<Cursor> = state
            .ring()
            .records_after(Cursor::ORIGIN)
            .iter()
            .map(|r| r.cursor())
            .collect();
        assert_eq!(cursors, vec![Cursor::new(5, 0), Cursor::new(6, 0)]);
        assert_eq!(mock.next_handshake(Duration::from_secs(1)), Some(0)); // live-tail

        shutdown.store(true, Ordering::Relaxed);
        drop(mock); // unblock the mux's held read → fast join
        let _ = handle.join();
    }

    #[test]
    fn mid_group_drop_loses_no_record_and_resubscribes_from_watermark() {
        // The headline finding-#4 chaos case: connection 1 delivers group 5's
        // head (5.0, 5.1) then DROPS before 5.2; the mux must resubscribe
        // from the watermark — here, with no completed group yet, from
        // oldest-1 = 4 — and connection 2 re-delivers the full group 5.0/5.1
        // (deduped) + 5.2 (the previously-unseen tail).
        let mock = MockUpstream::start(vec![
            vec![Frame::Event(5), Frame::Event(5), Frame::Close],
            vec![
                Frame::Event(5),
                Frame::Event(5),
                Frame::Event(5),
                Frame::Hold,
            ],
        ]);
        let state = FanoutState::new(64);
        let mux = Mux::new(mock.addr, 1 << 20, TEST_STALE, Arc::clone(&state));
        let shutdown = Arc::new(AtomicBool::new(false));
        let handle = mux.spawn(Arc::clone(&shutdown));

        assert!(
            wait_until(Duration::from_secs(3), || state.ring().len() == 3),
            "the unseen tail (5,2) was recovered"
        );
        let cursors: Vec<Cursor> = state
            .ring()
            .records_after(Cursor::ORIGIN)
            .iter()
            .map(|r| r.cursor())
            .collect();
        // No loss, no duplication across the resubscribe.
        assert_eq!(
            cursors,
            vec![Cursor::new(5, 0), Cursor::new(5, 1), Cursor::new(5, 2)]
        );
        // The resubscribe resumed from the watermark fallback (oldest-1 = 4),
        // NOT the newest delivered seq (5, which would skip 5.2).
        assert_eq!(mock.next_handshake(Duration::from_secs(1)), Some(0)); // initial live-tail
        assert_eq!(mock.next_handshake(Duration::from_secs(2)), Some(4)); // resubscribe

        shutdown.store(true, Ordering::Relaxed);
        drop(mock);
        let _ = handle.join();
    }

    #[test]
    fn resubscribe_from_a_completed_group_uses_the_watermark() {
        // Connection 1: group 5 (complete) then group 6's head, then drop.
        // The watermark is 5, so the resubscribe resumes from 5 (seq > 5 =
        // group 6), re-delivering 6.0 (deduped) + 6.1.
        let mock = MockUpstream::start(vec![
            vec![Frame::Event(5), Frame::Event(6), Frame::Close],
            vec![Frame::Event(6), Frame::Event(6), Frame::Hold],
        ]);
        let state = FanoutState::new(64);
        let mux = Mux::new(mock.addr, 1 << 20, TEST_STALE, Arc::clone(&state));
        let shutdown = Arc::new(AtomicBool::new(false));
        let handle = mux.spawn(Arc::clone(&shutdown));

        assert!(
            wait_until(Duration::from_secs(3), || state.ring().len() == 3),
            "5.0, 6.0, 6.1"
        );
        let cursors: Vec<Cursor> = state
            .ring()
            .records_after(Cursor::ORIGIN)
            .iter()
            .map(|r| r.cursor())
            .collect();
        assert_eq!(
            cursors,
            vec![Cursor::new(5, 0), Cursor::new(6, 0), Cursor::new(6, 1)]
        );
        assert_eq!(mock.next_handshake(Duration::from_secs(1)), Some(0));
        assert_eq!(
            mock.next_handshake(Duration::from_secs(2)),
            Some(5),
            "resubscribed from the watermark (last complete group)"
        );

        shutdown.store(true, Ordering::Relaxed);
        drop(mock);
        let _ = handle.join();
    }

    #[test]
    fn one_upstream_subscription_regardless_of_reader_count() {
        // The O(1)-in-N property: a single upstream connection feeds the
        // ring; N concurrent ring readers add ZERO upstream connections.
        let mock = MockUpstream::start(vec![vec![Frame::Event(5), Frame::Event(6), Frame::Hold]]);
        let state = FanoutState::new(64);
        // A long staleness timeout: the single connection persists for the
        // whole (short) assertion window — no reconnect inflates the count.
        let mux = Mux::new(
            mock.addr,
            1 << 20,
            Duration::from_secs(5),
            Arc::clone(&state),
        );
        let shutdown = Arc::new(AtomicBool::new(false));
        let mux_handle = mux.spawn(Arc::clone(&shutdown));

        // N concurrent readers hammering the shared ring.
        let stop_readers = Arc::new(AtomicBool::new(false));
        let readers: Vec<_> = (0..32)
            .map(|_| {
                let st = Arc::clone(&state);
                let stop = Arc::clone(&stop_readers);
                thread::spawn(move || {
                    while !stop.load(Ordering::Relaxed) {
                        let _ = st.ring().records_after(Cursor::ORIGIN);
                        thread::sleep(Duration::from_millis(1));
                    }
                })
            })
            .collect();

        assert!(
            wait_until(Duration::from_secs(2), || state.ring().len() == 2),
            "both events ingested under reader load"
        );
        // Exactly one upstream subscription despite 32 readers.
        assert_eq!(mock.accept_count(), 1);

        stop_readers.store(true, Ordering::Relaxed);
        shutdown.store(true, Ordering::Relaxed);
        drop(mock);
        for r in readers {
            let _ = r.join();
        }
        let _ = mux_handle.join();
    }

    #[test]
    fn corrupt_known_tag_event_fails_closed_and_stops_ingest() {
        // A KIND_EVENT frame whose payload is a valid tag-0 head with no
        // body → a known-tag decode failure → the mux records the fault and
        // stops (no silent skip).
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            if let Ok((mut s, _)) = listener.accept() {
                let mut hs = [0u8; 9];
                let _ = s.read_exact(&mut hs);
                // tag 0 (balanceChanged) head, zero body.
                let mut payload = vec![0x00];
                payload.extend_from_slice(&0u64.to_le_bytes());
                let mut framed = vec![KIND_EVENT];
                framed.extend_from_slice(&5u64.to_be_bytes());
                framed.extend_from_slice(&u32::try_from(payload.len()).unwrap().to_be_bytes());
                framed.extend_from_slice(&payload);
                let _ = s.write_all(&framed);
                // Hold briefly so the mux reads the frame before EOF.
                thread::sleep(Duration::from_millis(300));
            }
        });
        let state = FanoutState::new(64);
        let mux = Mux::new(addr, 1 << 20, TEST_STALE, Arc::clone(&state));
        let shutdown = Arc::new(AtomicBool::new(false));
        let handle = mux.spawn(Arc::clone(&shutdown));

        assert!(
            wait_until(Duration::from_secs(2), || state.fault().is_some()),
            "the decode fault was recorded"
        );
        assert!(
            state.ring().is_empty(),
            "the corrupt record was not ingested"
        );

        shutdown.store(true, Ordering::Relaxed);
        let _ = handle.join();
        let _ = server.join();
    }
}

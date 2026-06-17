// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G3.4c per-client SSE dispatch + eviction.
//!
//! One [`run_stream`] call drives **one** SSE client: it replays the shared
//! ring's records after the client's cursor and then live-tails new ones,
//! formatting each as a §6.1 Server-Sent-Events record
//!
//! ```text
//! id: <seq>.<index>
//! event: <eventType>
//! data: <JSON §6.2 event>
//! ```
//!
//! and emitting periodic **heartbeats** (`:\n` comment lines that carry **no
//! `id:`**, so a reconnect's resume cursor is unmoved).  Because each client
//! runs on its **own** thread writing to its **own** socket (the G3.5 HTTP
//! handler owns the thread), a slow client only ever blocks itself — the
//! shared ring is read under a brief lock, never held across a write.
//!
//! **Eviction (fail-fast, never a silent stall).**  A client that falls more
//! than `max_client_lag` records behind the ring — or whose cursor the ring
//! has already evicted ([`CursorPosition::Behind`]) — is dropped with an
//! `event: error` carrying `lag_exceeded` (§11.2); a write that times out
//! (a wedged socket) closes the stream.  A fail-closed
//! [`FanoutState`](super::FanoutState) decode fault closes every stream with
//! `decode_error` (§2 principle 7).

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use super::ring::{Cursor, CursorPosition, EventRecord};
use super::FanoutState;

/// Per-client dispatch tunables.
#[derive(Clone, Copy, Debug)]
pub struct StreamConfig {
    /// Evict a client more than this many records behind the ring's newest
    /// (proactive: kept below the ring capacity so the `lag_exceeded` error
    /// is delivered while the socket is still writable).
    pub max_client_lag: usize,
    /// Emit a heartbeat comment after this much idle (no records) time.
    pub heartbeat: Duration,
    /// How long to wait between ring polls when caught up.
    pub poll: Duration,
}

impl Default for StreamConfig {
    fn default() -> Self {
        Self {
            max_client_lag: 4096,
            heartbeat: Duration::from_secs(15),
            poll: Duration::from_millis(100),
        }
    }
}

/// Why a [`run_stream`] loop ended.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StreamEnd {
    /// The client socket closed or a write failed (best-effort close).
    Disconnected,
    /// The client was evicted for falling too far behind (`lag_exceeded`
    /// was emitted while the socket was still writable).
    Evicted,
    /// A fail-closed decode fault closed the stream (`decode_error` emitted).
    Fault,
    /// The gateway is shutting down.
    ShuttingDown,
}

/// Drive one SSE client: replay the ring after `start`, then live-tail,
/// writing §6.1 records (filtered to `types`, empty = all) + heartbeats to
/// `sink`, until the client disconnects, is evicted, a decode fault occurs,
/// or `shutdown` is set.
///
/// `sink`'s write deadline is the **caller's** responsibility, and the two
/// transports differ (OQ-GW-15): the **native-TLS** path
/// ([`crate::http::tls`]) owns its `TcpStream` and sets a per-connection write
/// timeout, so a stalled-reader write surfaces as an error →
/// [`StreamEnd::Disconnected`] and the slot is released; the **plaintext**
/// `tiny_http` path **cannot** set one (`Request::into_writer` yields a
/// type-erased `Box<dyn Write>` with no socket handle), so there a wedged
/// reader blocks this stream's write until it disconnects — prefer the
/// native-TLS path for untrusted SSE clients.
pub fn run_stream<W: Write>(
    sink: &mut W,
    state: &FanoutState,
    start: Cursor,
    types: &[String],
    config: &StreamConfig,
    shutdown: &AtomicBool,
) -> StreamEnd {
    let mut cursor = start;
    let mut last_write = Instant::now();
    loop {
        // Graceful shutdown (§G4.4): emit a clean `server_shutdown` close so
        // the client reconnects elsewhere.  Checked at the loop top — between
        // whole records — so a record is never truncated mid-write.
        if shutdown.load(Ordering::Relaxed) {
            let _ = write_stream_error(sink, "server_shutdown", None);
            return StreamEnd::ShuttingDown;
        }
        // A fail-closed decode fault compromises every stream (§2 principle 7).
        if state.fault().is_some() {
            let _ = write_stream_error(sink, "decode_error", None);
            return StreamEnd::Fault;
        }
        let (records, behind) = {
            let ring = state.ring();
            (
                ring.records_after(cursor),
                matches!(ring.position(cursor), CursorPosition::Behind { .. }),
            )
        };
        // Evict a client whose unseen records were evicted, or whose backlog
        // exceeds the lag bound — with the `lag_exceeded` signal (§11.2).
        if behind || records.len() > config.max_client_lag {
            let _ = write_stream_error(sink, "lag_exceeded", None);
            return StreamEnd::Evicted;
        }
        if records.is_empty() {
            if last_write.elapsed() >= config.heartbeat {
                if write_heartbeat(sink).is_err() {
                    return StreamEnd::Disconnected;
                }
                last_write = Instant::now();
            }
            std::thread::sleep(config.poll);
            continue;
        }
        for record in records {
            // The cursor advances over EVERY record (so a type filter never
            // re-examines a skipped one); only matching records are written
            // (and only those carry an `id:` the client resumes from).
            if types.is_empty() || types.iter().any(|t| *t == record.event_type) {
                if write_record(sink, &record).is_err() {
                    return StreamEnd::Disconnected;
                }
                last_write = Instant::now();
            }
            cursor = record.cursor();
        }
    }
}

/// Write one §6.1 SSE record: the composite `id: <seq>.<index>`, the
/// `event:` type, and the `data:` JSON.  A blank line terminates the record.
fn write_record<W: Write>(sink: &mut W, record: &EventRecord) -> std::io::Result<()> {
    write!(
        sink,
        "id: {}.{}\nevent: {}\ndata: {}\n\n",
        record.seq, record.index, record.event_type, record.data
    )?;
    sink.flush()
}

/// Write a heartbeat: an SSE comment line (`:\n`).  It carries **no `id:`**,
/// so it never moves the client's `Last-Event-ID` resume cursor.
fn write_heartbeat<W: Write>(sink: &mut W) -> std::io::Result<()> {
    sink.write_all(b":\n")?;
    sink.flush()
}

/// Write a terminal `event: error` carrying the §15B `EventStreamError`
/// (`{error, oldestSeq?}`).  No `id:` — an error is not a resume point.
/// Reused by the G3.5 stream handler for the pre-stream `behind` /
/// `truncated` resume errors.
pub(crate) fn write_stream_error<W: Write>(
    sink: &mut W,
    code: &str,
    oldest_seq: Option<u64>,
) -> std::io::Result<()> {
    let data = match oldest_seq {
        Some(seq) => format!(r#"{{"error":"{code}","oldestSeq":"{seq}"}}"#),
        None => format!(r#"{{"error":"{code}"}}"#),
    };
    write!(sink, "event: error\ndata: {data}\n\n")?;
    sink.flush()
}

#[cfg(test)]
mod tests {
    use super::{run_stream, write_stream_error, StreamConfig, StreamEnd};
    use crate::events::fanout::ring::{Cursor, EventRecord};
    use crate::events::fanout::FanoutState;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    fn rec(seq: u64, index: u32, ty: &str) -> EventRecord {
        EventRecord {
            seq,
            index,
            event_type: ty.to_string(),
            data: format!(r#"{{"seq":"{seq}","index":{index},"type":"{ty}"}}"#),
        }
    }

    /// A config that streams briskly and never heartbeats during the test.
    fn brisk(max_lag: usize) -> StreamConfig {
        StreamConfig {
            max_client_lag: max_lag,
            heartbeat: Duration::from_secs(3600),
            poll: Duration::from_millis(5),
        }
    }

    /// A thread-safe in-memory sink so a backlogged-then-live `run_stream`
    /// (which never returns on its own with an in-memory sink) can be
    /// inspected from the test thread, then stopped via the shutdown flag.
    #[derive(Clone)]
    struct SharedSink(Arc<std::sync::Mutex<Vec<u8>>>);

    impl Write for SharedSink {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// Run `run_stream` on a thread writing to a [`SharedSink`]; poll the
    /// sink until `done` (the rendered text satisfies it) or a 2s deadline,
    /// then stop the stream and return the captured output.
    fn capture(
        state: &Arc<FanoutState>,
        types: &[String],
        config: StreamConfig,
        done: impl Fn(&str) -> bool,
    ) -> String {
        let shared = Arc::new(std::sync::Mutex::new(Vec::<u8>::new()));
        let shutdown = Arc::new(AtomicBool::new(false));
        let handle = {
            let (st, data, sd, tys) = (
                Arc::clone(state),
                Arc::clone(&shared),
                Arc::clone(&shutdown),
                types.to_vec(),
            );
            thread::spawn(move || {
                let mut sink = SharedSink(data);
                run_stream(&mut sink, &st, Cursor::ORIGIN, &tys, &config, &sd)
            })
        };
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        loop {
            let text = String::from_utf8(shared.lock().unwrap().clone()).unwrap();
            if done(&text) || std::time::Instant::now() >= deadline {
                shutdown.store(true, Ordering::Relaxed);
                let _ = handle.join();
                return String::from_utf8(shared.lock().unwrap().clone()).unwrap();
            }
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn replays_the_backlog_as_composite_id_records() {
        let state = FanoutState::new(64);
        {
            let mut ring = state.ring();
            ring.push(rec(5, 0, "balanceChanged"));
            ring.push(rec(5, 1, "nonceAdvanced"));
            ring.push(rec(6, 0, "balanceChanged"));
        }
        let out = capture(&state, &[], brisk(64), |t| t.contains("id: 6.0"));
        assert!(out.contains("id: 5.0\nevent: balanceChanged\ndata: {"));
        assert!(out.contains("id: 5.1\nevent: nonceAdvanced\ndata: {"));
        assert!(out.contains("id: 6.0\nevent: balanceChanged\ndata: {"));
        // Exactly three composite-id records (the `capture` helper stops the
        // stream via the shutdown flag, which appends a clean
        // `server_shutdown` close — counting `id:` lines ignores it).
        assert_eq!(out.matches("id: ").count(), 3);
        assert!(out.contains("\"error\":\"server_shutdown\""));
    }

    #[test]
    fn type_filter_writes_only_matching_records() {
        let state = FanoutState::new(64);
        {
            let mut ring = state.ring();
            ring.push(rec(5, 0, "balanceChanged"));
            ring.push(rec(5, 1, "nonceAdvanced"));
            ring.push(rec(6, 0, "balanceChanged"));
        }
        // Wait until the (filtered) nonceAdvanced record and a later
        // unfiltered record (6.0) have both been processed, so we know the
        // filter dropped the balanceChanged records rather than lagging.
        let out = capture(&state, &["nonceAdvanced".to_string()], brisk(64), |t| {
            t.contains("id: 5.1")
        });
        assert!(out.contains("id: 5.1\nevent: nonceAdvanced"));
        assert!(!out.contains("balanceChanged"));
        // Exactly one record (the filtered nonceAdvanced); the trailing
        // `server_shutdown` close carries no `id:`.
        assert_eq!(out.matches("id: ").count(), 1);
    }

    #[test]
    fn lag_exceeded_evicts_with_the_error_event() {
        let state = FanoutState::new(64);
        {
            let mut ring = state.ring();
            for s in 1..=10u64 {
                ring.push(rec(s, 0, "balanceChanged"));
            }
        }
        // max_client_lag = 3, but the client (cursor ORIGIN) is 10 records
        // behind → evicted before any record is written.
        let mut sink: Vec<u8> = Vec::new();
        let shutdown = Arc::new(AtomicBool::new(false));
        let end = run_stream(&mut sink, &state, Cursor::ORIGIN, &[], &brisk(3), &shutdown);
        assert_eq!(end, StreamEnd::Evicted);
        let out = String::from_utf8(sink).unwrap();
        assert!(out.contains("event: error\ndata: {\"error\":\"lag_exceeded\"}"));
        // No id: line was emitted (the error is not a resume point).
        assert!(!out.contains("id: "));
    }

    #[test]
    fn behind_ring_cursor_is_evicted() {
        // A small ring that evicts: the client's cursor (ORIGIN) falls
        // behind the retained window → Behind → lag_exceeded.
        let state = FanoutState::new(2);
        {
            let mut ring = state.ring();
            for s in 1..=6u64 {
                ring.push(rec(s, 0, "balanceChanged"));
            }
        }
        let mut sink: Vec<u8> = Vec::new();
        let shutdown = Arc::new(AtomicBool::new(false));
        let end = run_stream(
            &mut sink,
            &state,
            Cursor::ORIGIN,
            &[],
            &brisk(1000), // not a count-lag eviction; this is the Behind path
            &shutdown,
        );
        assert_eq!(end, StreamEnd::Evicted);
        assert!(String::from_utf8(sink)
            .unwrap()
            .contains("\"error\":\"lag_exceeded\""));
    }

    #[test]
    fn decode_fault_closes_the_stream() {
        let state = FanoutState::new(64);
        state.ring().push(rec(5, 0, "balanceChanged"));
        state.set_fault("event decode failed (tag 0)".to_string());
        let mut sink: Vec<u8> = Vec::new();
        let shutdown = Arc::new(AtomicBool::new(false));
        let end = run_stream(
            &mut sink,
            &state,
            Cursor::ORIGIN,
            &[],
            &brisk(64),
            &shutdown,
        );
        assert_eq!(end, StreamEnd::Fault);
        assert!(String::from_utf8(sink)
            .unwrap()
            .contains("event: error\ndata: {\"error\":\"decode_error\"}"));
    }

    #[test]
    fn shutdown_emits_server_shutdown_and_closes() {
        // Graceful shutdown (§G4.4): the flag is observed at the loop top
        // (between whole records), so the stream emits a clean
        // `server_shutdown` close — never a truncated mid-record.
        let state = FanoutState::new(64);
        state.ring().push(rec(5, 0, "balanceChanged"));
        let mut sink: Vec<u8> = Vec::new();
        let shutdown = Arc::new(AtomicBool::new(true)); // already draining
        let end = run_stream(
            &mut sink,
            &state,
            Cursor::ORIGIN,
            &[],
            &brisk(64),
            &shutdown,
        );
        assert_eq!(end, StreamEnd::ShuttingDown);
        let out = String::from_utf8(sink).unwrap();
        assert!(out.contains("event: error\ndata: {\"error\":\"server_shutdown\"}"));
        // No record was written (shutdown took precedence); no truncation.
        assert!(!out.contains("id: 5.0"));
    }

    #[test]
    fn stream_error_with_oldest_seq_formats_the_behind_steer() {
        let mut sink: Vec<u8> = Vec::new();
        write_stream_error(&mut sink, "behind", Some(98123)).unwrap();
        let out = String::from_utf8(sink).unwrap();
        assert_eq!(
            out,
            "event: error\ndata: {\"error\":\"behind\",\"oldestSeq\":\"98123\"}\n\n"
        );
    }

    /// The headline concurrency property: a slow (non-reading) client does
    /// not stall a fast client.  Two clients stream from real sockets on
    /// their own threads; the fast one drains everything while the slow one
    /// (never reads) is evicted — and the fast one's delivery is unaffected.
    #[test]
    fn slow_client_does_not_stall_a_fast_client() {
        let state = FanoutState::new(1024);
        for s in 1..=50u64 {
            state.ring().push(rec(s, 0, "balanceChanged"));
        }
        let shutdown = Arc::new(AtomicBool::new(false));

        // Spawn a dispatch thread bound to a freshly-accepted socket.
        let spawn_client = |max_lag: usize| {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let addr = listener.local_addr().unwrap();
            let st = Arc::clone(&state);
            let sd = Arc::clone(&shutdown);
            let server = thread::spawn(move || {
                let (mut sock, _) = listener.accept().unwrap();
                sock.set_write_timeout(Some(Duration::from_millis(200)))
                    .ok();
                run_stream(
                    &mut sock,
                    &st,
                    Cursor::ORIGIN,
                    &[],
                    &StreamConfig {
                        max_client_lag: max_lag,
                        heartbeat: Duration::from_secs(3600),
                        poll: Duration::from_millis(5),
                    },
                    &sd,
                )
            });
            (addr, server)
        };

        // Fast client: a generous lag bound; it reads everything.
        let (fast_addr, fast_server) = spawn_client(1024);
        let mut fast = TcpStream::connect(fast_addr).unwrap();
        fast.set_read_timeout(Some(Duration::from_secs(2))).ok();

        // Slow client: a tight lag bound and it NEVER reads → evicted.
        let (slow_addr, slow_server) = spawn_client(4);
        let _slow = TcpStream::connect(slow_addr).unwrap(); // connected, never read

        // The fast client drains the 50-record backlog without stalling.
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while std::time::Instant::now() < deadline {
            match fast.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    buf.extend_from_slice(&chunk[..n]);
                    if String::from_utf8_lossy(&buf).contains("id: 50.0") {
                        break;
                    }
                }
            }
        }
        let out = String::from_utf8_lossy(&buf);
        assert!(out.contains("id: 1.0"), "fast client got the first record");
        assert!(out.contains("id: 50.0"), "fast client got the last record");

        // The slow client is evicted (lag_exceeded), independently.
        let slow_end = slow_server.join().unwrap();
        assert_eq!(slow_end, StreamEnd::Evicted);

        shutdown.store(true, Ordering::Relaxed);
        drop(fast);
        let _ = fast_server.join();
    }
}

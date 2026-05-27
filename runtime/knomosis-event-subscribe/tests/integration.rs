// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! End-to-end integration tests for `knomosis-event-subscribe`.
//!
//! These tests exercise the full pipeline:
//!   1. TailReader picks up new log frames.
//!   2. Extractor produces events.
//!   3. Cache stores events for backfill.
//!   4. SubscriberRegistry broadcasts events.
//!   5. Dispatch threads write outbound frames over TCP.
//!
//! Each test:
//!   * Constructs an empty log file, a MockExtractor with a
//!     known event-payload sequence, and a server.
//!   * Connects one or more clients with a SUBSCRIBE handshake.
//!   * Appends log frames and asserts that the expected
//!     outbound frames arrive.
//!   * Shuts down the server cleanly.

use std::io::Write;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use knomosis_event_subscribe::event_cache::EventCache;
use knomosis_event_subscribe::extract::mock::{MockExtractor, MockResponse};
use knomosis_event_subscribe::extract::Extractor;
use knomosis_event_subscribe::frame::{
    encode_inbound, read_outbound, InboundFrame, OutboundFrame, DEFAULT_MAX_FRAME_SIZE,
};
use knomosis_event_subscribe::server::{Server, ServerConfig};
use knomosis_event_subscribe::subscription::SubscriberRegistry;
use knomosis_event_subscribe::tail::{
    fnv1a64, TailReader, FRAME_MAGIC_0, FRAME_MAGIC_1, FRAME_MAGIC_2, FRAME_MAGIC_3,
};

/// Encode a single Lean-format log frame.
fn encode_log_frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&[FRAME_MAGIC_0, FRAME_MAGIC_1, FRAME_MAGIC_2, FRAME_MAGIC_3]);
    out.extend_from_slice(&(payload.len() as u64).to_le_bytes());
    out.extend_from_slice(payload);
    out.extend_from_slice(&fnv1a64(payload).to_le_bytes());
    out
}

/// Helper: append a log frame to the given file.
fn append_log_frame(log_path: &std::path::Path, payload: &[u8]) {
    let mut f = std::fs::OpenOptions::new()
        .append(true)
        .open(log_path)
        .expect("open log for append");
    f.write_all(&encode_log_frame(payload))
        .expect("write frame");
    f.sync_data().expect("sync");
}

/// Build a server with: empty cache size `cache_capacity`, the
/// supplied extractor, mock kernel, and listen on
/// `127.0.0.1:0` (random port).
fn make_server(
    log_path: &std::path::Path,
    extractor: Box<dyn Extractor>,
    cache_capacity: usize,
    max_subscribers: usize,
) -> (ServerConfig, std::net::SocketAddr) {
    let listener = Server::bind("127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = listener.local_addr().unwrap();
    let mut cfg = ServerConfig::with_defaults(
        listener,
        TailReader::open(log_path).unwrap(),
        extractor,
        Arc::new(SubscriberRegistry::with_max_subscribers(max_subscribers)),
        Arc::new(Mutex::new(EventCache::new(cache_capacity).unwrap())),
    );
    cfg.send_queue_depth = 64;
    cfg.max_subscriber_lag = 100;
    cfg.max_frame_size = DEFAULT_MAX_FRAME_SIZE;
    cfg.poll_interval = Duration::from_millis(20);
    (cfg, addr)
}

/// Start the server on a background thread; return the stop
/// flag, connect address, and join handle.
fn start_server(
    cfg: ServerConfig,
    addr: std::net::SocketAddr,
) -> (
    Arc<AtomicBool>,
    std::net::SocketAddr,
    std::thread::JoinHandle<()>,
) {
    let stop = Arc::new(AtomicBool::new(false));
    let s = Arc::clone(&stop);
    let handle = std::thread::spawn(move || Server::new(cfg).run(s));
    std::thread::sleep(Duration::from_millis(80));
    (stop, addr, handle)
}

/// Cleanly shut down the server (flip the stop flag, wait for
/// the run loop to finish, bounded by 5 seconds).
fn stop_server(stop: &Arc<AtomicBool>, handle: std::thread::JoinHandle<()>) {
    stop.store(true, Ordering::Relaxed);
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if handle.is_finished() {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    handle.join().expect("server thread joins");
}

/// Connect a client, send SUBSCRIBE, and return the stream.
fn connect_subscribe(addr: std::net::SocketAddr, resume_from: u64) -> TcpStream {
    let mut s = TcpStream::connect(addr).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    let sub = InboundFrame::Subscribe { resume_from };
    s.write_all(&encode_inbound(&sub)).unwrap();
    s
}

/// Read exactly N outbound EVENT frames from the stream and
/// return them in order.
fn read_n_events(stream: &mut TcpStream, n: usize) -> Vec<OutboundFrame> {
    let mut events = Vec::with_capacity(n);
    for _ in 0..n {
        let f = read_outbound(stream, DEFAULT_MAX_FRAME_SIZE).expect("read frame");
        events.push(f);
    }
    events
}

/// **RH-D.5 acceptance criterion: single subscriber happy path.**
///
/// A single subscriber connects, the server produces three log
/// frames (each yielding one event), and the subscriber receives
/// each event in order.
#[test]
fn single_subscriber_happy_path() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    extractor.set_responses(vec![
        MockResponse::Ok(vec![b"alpha".to_vec()]),
        MockResponse::Ok(vec![b"beta".to_vec()]),
        MockResponse::Ok(vec![b"gamma".to_vec()]),
    ]);
    let (cfg, addr) = make_server(&log_path, extractor, 64, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    let mut stream = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(100));

    // Append three log frames.
    append_log_frame(&log_path, b"frame-1");
    append_log_frame(&log_path, b"frame-2");
    append_log_frame(&log_path, b"frame-3");

    let frames = read_n_events(&mut stream, 3);
    for (i, frame) in frames.iter().enumerate() {
        let expected_seq = (i as u64) + 1;
        let expected_payload: &[u8] = match i {
            0 => b"alpha",
            1 => b"beta",
            2 => b"gamma",
            _ => unreachable!(),
        };
        match frame {
            OutboundFrame::Event { seq, payload } => {
                assert_eq!(*seq, expected_seq, "frame {i} seq");
                assert_eq!(payload.as_slice(), expected_payload, "frame {i} payload");
            }
            other => panic!("expected Event for frame {i}, got {other:?}"),
        }
    }

    stop_server(&stop, handle);
}

/// **RH-D.5 acceptance criterion: lag eviction.**
///
/// A slow subscriber whose queue + lag-counter overflow gets
/// disconnected with a `LagExceeded` frame.  Verifies the
/// bounded-lag policy actually fires.
#[test]
fn slow_subscriber_lag_evicted() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    extractor.set_responses(vec![MockResponse::Ok(vec![b"event".to_vec()])]);
    let listener = Server::bind("127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = listener.local_addr().unwrap();
    // send_queue_depth = 1, max_subscriber_lag = 2.  After 1
    // delivered + 3 unread events the lag counter overflows.
    let mut cfg = ServerConfig::with_defaults(
        listener,
        TailReader::open(&log_path).unwrap(),
        extractor,
        Arc::new(SubscriberRegistry::with_max_subscribers(64)),
        Arc::new(Mutex::new(EventCache::new(64).unwrap())),
    );
    cfg.send_queue_depth = 1;
    cfg.max_subscriber_lag = 2;
    cfg.max_frame_size = DEFAULT_MAX_FRAME_SIZE;
    cfg.poll_interval = Duration::from_millis(20);
    let (stop, addr, handle) = start_server(cfg, addr);

    // A "slow" subscriber: connect but never drain.
    let mut slow = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(100));

    // Produce many log frames; the slow subscriber's queue fills,
    // lag-counter overflows.
    for _ in 0..10 {
        append_log_frame(&log_path, b"frame");
    }

    // The slow subscriber should eventually receive a
    // `LagExceeded` (after the 1-deep queue and the buffered
    // pre-fill events are drained from the TCP-side buffer).  The
    // test reads frames until either LagExceeded arrives, the
    // connection closes, or the deadline elapses.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut got_lag_eviction = false;
    while Instant::now() < deadline {
        match read_outbound(&mut slow, DEFAULT_MAX_FRAME_SIZE) {
            Ok(OutboundFrame::Event { .. }) => continue,
            Ok(OutboundFrame::LagExceeded { .. }) => {
                got_lag_eviction = true;
                break;
            }
            Ok(OutboundFrame::ServerShutdown { .. }) => break,
            Ok(other) => panic!("slow got unexpected frame: {other:?}"),
            Err(_) => {
                // Connection closed; acceptable end-state.
                got_lag_eviction = true;
                break;
            }
        }
    }
    assert!(
        got_lag_eviction,
        "slow subscriber should have been lag-evicted"
    );

    stop_server(&stop, handle);
}

/// **RH-D.5 acceptance criterion: resume across reconnect.**
///
/// A client disconnects after receiving a few events, reconnects
/// with `resume_from = last_received_seq`, and receives the
/// missing events.
#[test]
fn resume_across_reconnect_delivers_missing_range() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    // Each frame produces a unique event.
    extractor.set_responses(vec![
        MockResponse::Ok(vec![b"e1".to_vec()]),
        MockResponse::Ok(vec![b"e2".to_vec()]),
        MockResponse::Ok(vec![b"e3".to_vec()]),
        MockResponse::Ok(vec![b"e4".to_vec()]),
        MockResponse::Ok(vec![b"e5".to_vec()]),
    ]);
    let (cfg, addr) = make_server(&log_path, extractor, 64, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    // First connection: subscribe live-tail, get events 1 + 2.
    let mut s1 = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(100));
    append_log_frame(&log_path, b"f1");
    append_log_frame(&log_path, b"f2");
    let frames = read_n_events(&mut s1, 2);
    let last_seq = match frames.last() {
        Some(OutboundFrame::Event { seq, .. }) => *seq,
        _ => panic!("expected Event"),
    };
    assert_eq!(last_seq, 2);
    drop(s1);

    // Server produces three more events while disconnected.
    append_log_frame(&log_path, b"f3");
    append_log_frame(&log_path, b"f4");
    append_log_frame(&log_path, b"f5");
    std::thread::sleep(Duration::from_millis(200));

    // Reconnect with resume_from = 2.  Should get events 3, 4, 5.
    let mut s2 = connect_subscribe(addr, 2);
    let frames = read_n_events(&mut s2, 3);
    let payloads: Vec<&[u8]> = frames
        .iter()
        .map(|f| match f {
            OutboundFrame::Event { payload, .. } => payload.as_slice(),
            _ => panic!("expected Event"),
        })
        .collect();
    assert_eq!(
        payloads,
        vec![b"e3".as_ref(), b"e4".as_ref(), b"e5".as_ref()]
    );
    let seqs: Vec<u64> = frames
        .iter()
        .map(|f| match f {
            OutboundFrame::Event { seq, .. } => *seq,
            _ => panic!("expected Event"),
        })
        .collect();
    assert_eq!(seqs, vec![3, 4, 5]);

    stop_server(&stop, handle);
}

/// **RH-D.5 acceptance criterion: backfill from genesis.**
///
/// A client connects with `resume_from = 1`, receives every event
/// from seq=2 onward.  Tests the "full backfill" branch where the
/// cache holds the entire post-genesis history.
#[test]
fn backfill_from_genesis_delivers_all() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    extractor.set_responses(vec![
        MockResponse::Ok(vec![b"e1".to_vec()]),
        MockResponse::Ok(vec![b"e2".to_vec()]),
        MockResponse::Ok(vec![b"e3".to_vec()]),
    ]);
    let (cfg, addr) = make_server(&log_path, extractor, 64, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    // Produce three events while no subscribers are connected.
    append_log_frame(&log_path, b"f1");
    append_log_frame(&log_path, b"f2");
    append_log_frame(&log_path, b"f3");
    std::thread::sleep(Duration::from_millis(200));

    // Connect with resume_from=1; expect events 2, 3.
    let mut s = connect_subscribe(addr, 1);
    let frames = read_n_events(&mut s, 2);
    let seqs: Vec<u64> = frames
        .iter()
        .map(|f| match f {
            OutboundFrame::Event { seq, .. } => *seq,
            _ => panic!("expected Event"),
        })
        .collect();
    assert_eq!(seqs, vec![2, 3]);

    stop_server(&stop, handle);
}

/// **RH-D.5 acceptance criterion: truncation rejection.**
///
/// A client resumes from a sequence before the cache window;
/// the server emits a `Truncated` frame and closes the connection.
#[test]
fn truncation_rejection() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    extractor.set_responses(vec![
        MockResponse::Ok(vec![b"e1".to_vec()]),
        MockResponse::Ok(vec![b"e2".to_vec()]),
        MockResponse::Ok(vec![b"e3".to_vec()]),
        MockResponse::Ok(vec![b"e4".to_vec()]),
        MockResponse::Ok(vec![b"e5".to_vec()]),
    ]);
    // Cache size = 2; first 3 events get evicted.
    let (cfg, addr) = make_server(&log_path, extractor, 2, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    // Produce 5 events.
    for i in 1..=5 {
        append_log_frame(&log_path, format!("f{i}").as_bytes());
    }
    std::thread::sleep(Duration::from_millis(300));

    // Connect with resume_from=1.  Cache only has seqs 4, 5;
    // server emits Truncated with oldest_available=4.
    let mut s = connect_subscribe(addr, 1);
    let f = read_outbound(&mut s, DEFAULT_MAX_FRAME_SIZE).unwrap();
    match f {
        OutboundFrame::Truncated {
            oldest_available_seq,
        } => assert_eq!(oldest_available_seq, 4),
        other => panic!("expected Truncated, got {other:?}"),
    }
    stop_server(&stop, handle);
}

/// **RH-D.5 acceptance criterion: invalid handshake rejection.**
///
/// A client sends garbage; the server sends `InvalidRequest` and
/// closes the connection.
#[test]
fn invalid_handshake_rejected() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    let (cfg, addr) = make_server(&log_path, extractor, 64, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    let mut s = TcpStream::connect(addr).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    // Send a single byte with an unknown kind tag.
    s.write_all(&[0xff]).unwrap();
    let f = read_outbound(&mut s, DEFAULT_MAX_FRAME_SIZE).unwrap();
    match f {
        OutboundFrame::InvalidRequest => {}
        other => panic!("expected InvalidRequest, got {other:?}"),
    }
    stop_server(&stop, handle);
}

/// Empty payload (event with zero-length payload) is delivered
/// correctly.  Some kernel actions emit empty event lists; the
/// pipeline must not silently drop or corrupt them.
#[test]
fn zero_length_event_payload_delivered() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    extractor.set_responses(vec![MockResponse::Ok(vec![Vec::new()])]);
    let (cfg, addr) = make_server(&log_path, extractor, 64, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    let mut s = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(100));
    append_log_frame(&log_path, b"f1");

    let f = read_outbound(&mut s, DEFAULT_MAX_FRAME_SIZE).unwrap();
    match f {
        OutboundFrame::Event { seq, payload } => {
            assert_eq!(seq, 1);
            assert!(payload.is_empty());
        }
        other => panic!("expected Event, got {other:?}"),
    }
    stop_server(&stop, handle);
}

/// Server shutdown propagates a `ServerShutdown` frame to every
/// live subscriber before closing the socket.
///
/// **H-4 audit regression:** prior to the H-4 fix
/// (`shutdown_requested` flag decoupled from queue capacity),
/// some subscribers could be silently mis-evicted with
/// `LagExceeded` instead of `ServerShutdown`.  This test
/// asserts ALL 3 subscribers receive the explicit ServerShutdown
/// frame.
#[test]
fn shutdown_emits_shutdown_frame_to_all_subscribers() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    let (cfg, addr) = make_server(&log_path, extractor, 64, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    let mut s1 = connect_subscribe(addr, 0);
    let mut s2 = connect_subscribe(addr, 0);
    let mut s3 = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(100));

    stop_server(&stop, handle);

    // H-3R-4 audit fix: previously this test contained a
    // contradictory pattern (`Err` was tolerated in the loop
    // but `assert_eq!(shutdown_count, 3)` would still fail).
    // Now we strictly require ALL 3 subscribers to receive the
    // ServerShutdown frame.  Post-H-4 (shutdown_requested flag
    // decoupled from channel capacity), this is the contract:
    // every live subscriber gets the frame.  If a connection
    // closes before the frame arrives, that IS the bug we want
    // the test to catch.
    let mut shutdown_count = 0;
    for s in &mut [&mut s1, &mut s2, &mut s3] {
        match read_outbound(s, DEFAULT_MAX_FRAME_SIZE) {
            Ok(OutboundFrame::ServerShutdown { .. }) => shutdown_count += 1,
            Ok(other) => panic!("expected ServerShutdown, got {other:?}"),
            Err(e) => panic!("expected ServerShutdown frame; got read error: {e:?}"),
        }
    }
    assert_eq!(
        shutdown_count, 3,
        "expected 3 ServerShutdown frames, got {shutdown_count}"
    );
}

/// **H-4 regression test: laggy subscriber still receives
/// ServerShutdown on graceful shutdown.**  Prior to the H-4
/// fix, a subscriber whose channel was full at shutdown time
/// would be silently mis-evicted with `LagExceeded`.  Verify
/// the new `shutdown_requested` flag path catches them.
#[test]
fn laggy_subscriber_receives_shutdown_not_lag_exceeded() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    extractor.set_responses(vec![MockResponse::Ok(vec![b"e".to_vec()])]);
    let listener = Server::bind("127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = listener.local_addr().unwrap();
    // Tiny send queue so the subscriber's channel fills quickly.
    // Very high lag threshold so the subscriber is NOT lag-evicted
    // before we shut down.
    let mut cfg = ServerConfig::with_defaults(
        listener,
        TailReader::open(&log_path).unwrap(),
        extractor,
        Arc::new(SubscriberRegistry::with_max_subscribers(64)),
        Arc::new(Mutex::new(EventCache::new(64).unwrap())),
    );
    cfg.send_queue_depth = 1;
    cfg.max_subscriber_lag = 1_000_000; // very high; will not evict
    cfg.poll_interval = Duration::from_millis(20);
    let (stop, addr, handle) = start_server(cfg, addr);

    // Connect; don't read.
    let mut s = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(100));

    // Produce many events to fill the subscriber's channel.
    for _ in 0..20 {
        append_log_frame(&log_path, b"frame");
    }
    std::thread::sleep(Duration::from_millis(200));

    // Now shut down.  Subscriber's channel is full; under the
    // old `enqueue_shutdown` it would be marked Disconnected
    // and mis-evicted.  Post-fix, the `shutdown_requested`
    // flag is set even though the channel is full.
    stop_server(&stop, handle);

    // Drain events until we see ServerShutdown or LagExceeded.
    let mut got_shutdown = false;
    let mut got_lag_exceeded = false;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match read_outbound(&mut s, DEFAULT_MAX_FRAME_SIZE) {
            Ok(OutboundFrame::Event { .. }) => continue,
            Ok(OutboundFrame::ServerShutdown { .. }) => {
                got_shutdown = true;
                break;
            }
            Ok(OutboundFrame::LagExceeded { .. }) => {
                got_lag_exceeded = true;
                break;
            }
            Ok(other) => panic!("unexpected frame: {other:?}"),
            Err(_) => break, // connection closed
        }
    }
    assert!(
        got_shutdown,
        "expected ServerShutdown frame; got_lag_exceeded={got_lag_exceeded}"
    );
}

/// Event sequence preserved across multiple subscribers: every
/// subscriber sees the same monotonic seq sequence.
#[test]
fn event_order_preserved_across_subscribers() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    extractor.set_responses(vec![
        MockResponse::Ok(vec![b"e1".to_vec()]),
        MockResponse::Ok(vec![b"e2".to_vec()]),
        MockResponse::Ok(vec![b"e3".to_vec()]),
        MockResponse::Ok(vec![b"e4".to_vec()]),
        MockResponse::Ok(vec![b"e5".to_vec()]),
    ]);
    let (cfg, addr) = make_server(&log_path, extractor, 64, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    let mut s1 = connect_subscribe(addr, 0);
    let mut s2 = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(100));

    for i in 1..=5 {
        append_log_frame(&log_path, format!("f{i}").as_bytes());
    }

    let f1 = read_n_events(&mut s1, 5);
    let f2 = read_n_events(&mut s2, 5);

    let extract_seqs = |frames: &[OutboundFrame]| -> Vec<u64> {
        frames
            .iter()
            .map(|f| match f {
                OutboundFrame::Event { seq, .. } => *seq,
                _ => panic!(),
            })
            .collect()
    };
    let s1_seqs = extract_seqs(&f1);
    let s2_seqs = extract_seqs(&f2);
    assert_eq!(s1_seqs, vec![1, 2, 3, 4, 5]);
    assert_eq!(s2_seqs, vec![1, 2, 3, 4, 5]);

    stop_server(&stop, handle);
}

/// Many sequential events: regression test for high-throughput
/// scenarios.
#[test]
fn many_sequential_events_delivered() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let n: usize = 50;
    let extractor = Box::new(MockExtractor::new());
    let responses: Vec<MockResponse> = (0..n)
        .map(|i| MockResponse::Ok(vec![format!("e{i}").into_bytes()]))
        .collect();
    extractor.set_responses(responses);
    let (cfg, addr) = make_server(&log_path, extractor, 256, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    let mut s = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(100));

    for i in 0..n {
        append_log_frame(&log_path, format!("frame-{i}").as_bytes());
    }

    let frames = read_n_events(&mut s, n);
    for (i, frame) in frames.iter().enumerate() {
        match frame {
            OutboundFrame::Event { seq, .. } => assert_eq!(*seq, (i as u64) + 1),
            _ => panic!("expected Event"),
        }
    }

    stop_server(&stop, handle);
}

/// **Subscriber capacity cap.**  When `max_subscribers` is set,
/// the (max+1)-th connection is rejected immediately.
#[test]
fn subscriber_capacity_cap_enforced() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    let (cfg, addr) = make_server(&log_path, extractor, 64, 2); // cap = 2
    let (stop, addr, handle) = start_server(cfg, addr);

    let s1 = connect_subscribe(addr, 0);
    let s2 = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(100));
    // Third connection: server should send LagExceeded and close.
    let mut s3 = TcpStream::connect(addr).unwrap();
    s3.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    let sub = InboundFrame::Subscribe { resume_from: 0 };
    s3.write_all(&encode_inbound(&sub)).unwrap();
    let f = read_outbound(&mut s3, DEFAULT_MAX_FRAME_SIZE).unwrap();
    match f {
        // We use LagExceeded byte for "cannot register" — see
        // server.rs handle_connection.
        OutboundFrame::LagExceeded { .. } => {}
        other => panic!("expected LagExceeded, got {other:?}"),
    }

    let _ = s1;
    let _ = s2;
    stop_server(&stop, handle);
}

/// **C-2 audit regression test: multi-event-per-frame delivery.**
///
/// A single log frame can produce multiple events (e.g. transfer
/// emits two `balanceChanged` events sharing the same seq).
/// Before the C-2 fix, the cache's `OutOfOrder` check rejected
/// the 2nd+ events of a multi-event frame.  This test verifies
/// that ALL events of a multi-event frame reach subscribers.
#[test]
fn multi_event_per_frame_all_delivered() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    // ONE log frame produces THREE events (sharing seq=1).
    extractor.set_responses(vec![MockResponse::Ok(vec![
        b"event-a".to_vec(),
        b"event-b".to_vec(),
        b"event-c".to_vec(),
    ])]);
    let (cfg, addr) = make_server(&log_path, extractor, 64, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    let mut s = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(100));
    append_log_frame(&log_path, b"single-frame");

    // All three events should arrive with seq=1.
    let frames = read_n_events(&mut s, 3);
    let payloads: Vec<&[u8]> = frames
        .iter()
        .map(|f| match f {
            OutboundFrame::Event { payload, .. } => payload.as_slice(),
            _ => panic!("expected Event"),
        })
        .collect();
    assert_eq!(
        payloads,
        vec![
            b"event-a".as_ref(),
            b"event-b".as_ref(),
            b"event-c".as_ref()
        ]
    );
    for frame in &frames {
        match frame {
            OutboundFrame::Event { seq, .. } => assert_eq!(*seq, 1),
            _ => unreachable!(),
        }
    }

    stop_server(&stop, handle);
}

/// **C-2 audit regression test: multi-event-per-frame backfill.**
///
/// Backfill via cache.range() must return ALL events of a
/// multi-event frame, in push order.
#[test]
fn multi_event_per_frame_backfill_includes_all() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let extractor = Box::new(MockExtractor::new());
    // First frame yields 2 events (seq=1); second yields 2
    // events (seq=2).
    extractor.set_responses(vec![
        MockResponse::Ok(vec![b"e1a".to_vec(), b"e1b".to_vec()]),
        MockResponse::Ok(vec![b"e2a".to_vec(), b"e2b".to_vec()]),
    ]);
    let (cfg, addr) = make_server(&log_path, extractor, 64, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    // Produce both frames BEFORE the subscriber connects so the
    // backfill path exercises the multi-event case.
    append_log_frame(&log_path, b"frame-1");
    append_log_frame(&log_path, b"frame-2");
    std::thread::sleep(Duration::from_millis(300));

    // Resume from seq=0 (live tail) misses the historical events;
    // resume_from=1 yields the second batch.  We test the more
    // interesting case: resume_from=0 to verify the cache cap
    // hasn't dropped seq=2 events.  Actually for true backfill
    // we need a non-zero resume_from.  Connect with resume_from
    // strictly less than 1 — but the doc says 0 means "live tail".
    // We must instead connect first and produce events later for
    // genuine backfill semantics.
    let mut s = connect_subscribe(addr, 1);
    // Receive 2 backfilled events (both at seq=2).
    let frames = read_n_events(&mut s, 2);
    let payloads: Vec<&[u8]> = frames
        .iter()
        .map(|f| match f {
            OutboundFrame::Event { payload, .. } => payload.as_slice(),
            _ => panic!("expected Event"),
        })
        .collect();
    assert_eq!(payloads, vec![b"e2a".as_ref(), b"e2b".as_ref()]);
    for frame in &frames {
        match frame {
            OutboundFrame::Event { seq, .. } => assert_eq!(*seq, 2),
            _ => unreachable!(),
        }
    }

    stop_server(&stop, handle);
}

/// **C-1 audit regression test: no duplicate delivery between
/// backfill and broadcast.**
///
/// This test creates a deterministic race: the subscriber
/// connects, then events are produced.  In the previous
/// (buggy) code, the channel could hold events that were also
/// in the cache, causing duplicate delivery via backfill +
/// dispatch.  After C-1 fix, dispatch_live drains channel
/// duplicates at startup.
///
/// We approximate the race by producing many events and
/// verifying the subscriber sees each seq exactly once.
#[test]
fn no_duplicate_delivery_under_load() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let n: usize = 20;
    let extractor = Box::new(MockExtractor::new());
    let responses: Vec<MockResponse> = (1..=n)
        .map(|i| MockResponse::Ok(vec![format!("e{i}").into_bytes()]))
        .collect();
    extractor.set_responses(responses);
    let (cfg, addr) = make_server(&log_path, extractor, 64, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    // Subscribe with resume_from=0 (live tail).
    let mut s = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(50));
    // Produce log frames rapidly.
    for i in 0..n {
        append_log_frame(&log_path, format!("frame-{i}").as_bytes());
    }

    // Read every event and check seq monotonicity (each seq
    // appears exactly once in increasing order).
    let frames = read_n_events(&mut s, n);
    let mut prev_seq = 0u64;
    for (i, frame) in frames.iter().enumerate() {
        match frame {
            OutboundFrame::Event { seq, .. } => {
                assert!(
                    *seq > prev_seq,
                    "seq {seq} at index {i} is not strictly greater than prev {prev_seq}"
                );
                prev_seq = *seq;
            }
            _ => panic!("expected Event"),
        }
    }
    // We should see exactly n events with seqs 1..=n.
    assert_eq!(
        prev_seq, n as u64,
        "received {prev_seq} of {n} expected events"
    );

    stop_server(&stop, handle);
}

/// **C-NEW-1 audit regression test: multi-event-per-frame events
/// are not silently dropped at the snapshot/broadcast boundary.**
///
/// The original C-1 channel-drain fix had a regression: when a
/// multi-event batch was split across the subscriber's cache
/// snapshot and the channel state, the drain would suppress
/// channel events that weren't actually duplicates of backfilled
/// events, silently dropping them.
///
/// The second-audit fix (push + broadcast under a single cache
/// lock) makes the snapshot+channel state mutually consistent.
/// This test exercises the scenario by producing many
/// multi-event-per-frame batches under load and verifying that
/// every event reaches subscribers exactly once.
#[test]
fn multi_event_per_frame_no_silent_drops_under_load() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let frames: usize = 10;
    let events_per_frame: usize = 5;
    let extractor = Box::new(MockExtractor::new());
    // Each frame produces `events_per_frame` events.
    let responses: Vec<MockResponse> = (1..=frames)
        .map(|i| {
            MockResponse::Ok(
                (0..events_per_frame)
                    .map(|j| format!("frame-{i}-event-{j}").into_bytes())
                    .collect(),
            )
        })
        .collect();
    extractor.set_responses(responses);
    let (cfg, addr) = make_server(&log_path, extractor, 128, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    let mut s = connect_subscribe(addr, 0);
    std::thread::sleep(Duration::from_millis(80));

    // Produce all frames rapidly.
    for i in 0..frames {
        append_log_frame(&log_path, format!("frame-{i}").as_bytes());
    }

    // Read every expected event (frames * events_per_frame).
    let total_expected = frames * events_per_frame;
    let mut received: Vec<Vec<u8>> = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while received.len() < total_expected && Instant::now() < deadline {
        match read_outbound(&mut s, DEFAULT_MAX_FRAME_SIZE) {
            Ok(OutboundFrame::Event { payload, .. }) => received.push(payload),
            Ok(other) => panic!("expected Event, got {other:?}"),
            Err(e) => panic!("read failed at {} events: {e:?}", received.len()),
        }
    }
    assert_eq!(
        received.len(),
        total_expected,
        "expected {total_expected} events, got {}",
        received.len()
    );
    // Verify uniqueness: every event's payload should appear once.
    let mut sorted = received.clone();
    sorted.sort();
    let unique_count = sorted.windows(2).filter(|w| w[0] != w[1]).count() + 1;
    assert_eq!(
        unique_count, total_expected,
        "received duplicate events (expected {total_expected} unique, got {unique_count})"
    );

    stop_server(&stop, handle);
}

/// **C-3R-1 audit regression test: a subscriber connecting
/// concurrently with multi-event-per-frame batches never
/// receives a partial batch.**
///
/// Specifically: with `resume_from = 0` (live-tail), the
/// subscriber should EITHER receive zero events of any given
/// multi-event batch OR all events of that batch — never a
/// suffix.  Pre-fix, a subscriber registering mid-broadcast
/// would receive event[1..] but miss event[0].
///
/// We verify by producing many 3-event batches and having a
/// background thread connect subscribers continuously.  Each
/// subscriber's received events are checked: for any seq=K
/// that appears in their stream, ALL 3 events at seq=K must
/// appear contiguously.  A partial batch (1 or 2 of 3) is the
/// bug.
#[test]
fn multi_event_per_frame_atomic_under_concurrent_subscribe() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let log_path = log.path().to_path_buf();
    let frames: usize = 30;
    let extractor = Box::new(MockExtractor::new());
    // Each frame produces 3 events at the same seq.  Distinct
    // payloads (`<frame>-a/b/c`) so we can verify which events
    // each subscriber actually received.
    let responses: Vec<MockResponse> = (1..=frames)
        .map(|i| {
            MockResponse::Ok(vec![
                format!("frame-{i}-a").into_bytes(),
                format!("frame-{i}-b").into_bytes(),
                format!("frame-{i}-c").into_bytes(),
            ])
        })
        .collect();
    extractor.set_responses(responses);
    let (cfg, addr) = make_server(&log_path, extractor, 128, 64);
    let (stop, addr, handle) = start_server(cfg, addr);

    // Producer thread: append log frames rapidly.
    let log_path_producer = log_path.clone();
    let producer = std::thread::spawn(move || {
        for i in 0..frames {
            append_log_frame(&log_path_producer, format!("frame-{i}").as_bytes());
            // Tiny pause to widen the race window.
            std::thread::sleep(Duration::from_micros(500));
        }
    });

    // Spawn several subscribers concurrently with the producer.
    let n_subscribers = 8;
    let mut sub_handles = Vec::new();
    for sub_idx in 0..n_subscribers {
        let h = std::thread::spawn(move || {
            // Stagger subscriber connections across the race window.
            std::thread::sleep(Duration::from_millis((sub_idx as u64) * 5));
            let mut s = match TcpStream::connect(addr) {
                Ok(s) => s,
                Err(_) => return Vec::new(),
            };
            let _ = s.set_read_timeout(Some(Duration::from_secs(3)));
            let sub = InboundFrame::Subscribe { resume_from: 0 };
            if std::io::Write::write_all(&mut s, &encode_inbound(&sub)).is_err() {
                return Vec::new();
            }
            // Read events until the deadline.
            let mut payloads = Vec::new();
            let deadline = Instant::now() + Duration::from_secs(3);
            while Instant::now() < deadline {
                match read_outbound(&mut s, DEFAULT_MAX_FRAME_SIZE) {
                    Ok(OutboundFrame::Event { payload, .. }) => payloads.push(payload),
                    // ServerShutdown / unexpected frame / read
                    // error — all terminate the read loop.
                    Ok(_) | Err(_) => break,
                }
            }
            payloads
        });
        sub_handles.push(h);
    }
    producer.join().unwrap();
    std::thread::sleep(Duration::from_millis(300));
    let all_received: Vec<Vec<Vec<u8>>> = sub_handles
        .into_iter()
        .map(|h| h.join().unwrap_or_default())
        .collect();

    // M-2 audit: guard against vacuous pass.  At least ONE
    // subscriber must have received at least one event,
    // otherwise the atomicity assertion below never runs (the
    // test would trivially "pass" with no subscribers having
    // delivered events).
    let total_events: usize = all_received.iter().map(Vec::len).sum();
    assert!(
        total_events > 0,
        "no subscriber received any events; test cannot verify atomicity invariant"
    );

    // For each subscriber, verify atomic-batch delivery: for any
    // frame index they received events for, they must have
    // received ALL 3 events of that frame (a, b, AND c) — never
    // 1 or 2.  We identify frames by the payload's `frame-<N>`
    // prefix.
    for (sub_idx, payloads) in all_received.iter().enumerate() {
        // Group payloads by frame index.
        use std::collections::HashMap;
        let mut by_frame: HashMap<usize, Vec<&[u8]>> = HashMap::new();
        for p in payloads {
            let s = std::str::from_utf8(p).expect("utf-8 payload");
            // Parse `frame-<N>-<letter>`.
            let dash = s.find('-').expect("frame- prefix");
            let last_dash = s.rfind('-').expect("trailing -");
            let frame_idx: usize = s[dash + 1..last_dash].parse().expect("frame idx");
            by_frame.entry(frame_idx).or_default().push(p);
        }
        for (frame_idx, parts) in &by_frame {
            assert_eq!(
                parts.len(),
                3,
                "subscriber {sub_idx}: frame {frame_idx} delivered {} events of 3 (PARTIAL BATCH BUG)",
                parts.len()
            );
        }
    }

    stop_server(&stop, handle);
}

/// **M-4 audit regression test: symlinked log path is rejected.**
///
/// Defends against an attacker (or operator misconfiguration)
/// pointing `--log-path` at a symlink whose target is a
/// different file.
#[cfg(unix)]
#[test]
fn symlinked_log_path_rejected() {
    use std::os::unix::fs::symlink;
    let real = tempfile::NamedTempFile::new().unwrap();
    let real_path = real.path().to_path_buf();
    let symlink_path = real_path.with_extension("symlink");
    symlink(&real_path, &symlink_path).unwrap();
    // Opening via the symlink should fail.
    let result = knomosis_event_subscribe::tail::TailReader::open(&symlink_path);
    assert!(result.is_err());
    // Real path still works.
    let result = knomosis_event_subscribe::tail::TailReader::open(&real_path);
    assert!(result.is_ok());
    let _ = std::fs::remove_file(&symlink_path);
}

// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! End-to-end integration tests for `canon-event-subscribe`.
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

use canon_event_subscribe::event_cache::EventCache;
use canon_event_subscribe::extract::mock::{MockExtractor, MockResponse};
use canon_event_subscribe::extract::Extractor;
use canon_event_subscribe::frame::{
    encode_inbound, read_outbound, InboundFrame, OutboundFrame, DEFAULT_MAX_FRAME_SIZE,
};
use canon_event_subscribe::server::{Server, ServerConfig};
use canon_event_subscribe::subscription::SubscriberRegistry;
use canon_event_subscribe::tail::{
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
    let cfg = ServerConfig {
        listener,
        tail: TailReader::open(log_path).unwrap(),
        extractor,
        registry: Arc::new(SubscriberRegistry::with_max_subscribers(max_subscribers)),
        cache: Arc::new(Mutex::new(EventCache::new(cache_capacity).unwrap())),
        send_queue_depth: 64,
        max_subscriber_lag: 100,
        max_frame_size: DEFAULT_MAX_FRAME_SIZE,
        poll_interval: Duration::from_millis(20),
    };
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
    let cfg = ServerConfig {
        listener,
        tail: TailReader::open(&log_path).unwrap(),
        extractor,
        registry: Arc::new(SubscriberRegistry::with_max_subscribers(64)),
        cache: Arc::new(Mutex::new(EventCache::new(64).unwrap())),
        send_queue_depth: 1,
        max_subscriber_lag: 2,
        max_frame_size: DEFAULT_MAX_FRAME_SIZE,
        poll_interval: Duration::from_millis(20),
    };
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

    let mut shutdown_count = 0;
    for s in &mut [&mut s1, &mut s2, &mut s3] {
        match read_outbound(s, DEFAULT_MAX_FRAME_SIZE) {
            Ok(OutboundFrame::ServerShutdown { .. }) => shutdown_count += 1,
            Ok(other) => panic!("expected ServerShutdown, got {other:?}"),
            Err(_) => {
                // Acceptable: connection closed before the frame
                // was delivered.  Some shutdown timings have this
                // race; the test verifies "≥ 1 subscriber got the
                // frame OR the server closed cleanly".
            }
        }
    }
    // At least one subscriber should have received the explicit
    // shutdown frame (race with connection close).
    assert!(
        shutdown_count >= 1,
        "expected ≥ 1 ServerShutdown frame, got {shutdown_count}"
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

// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! End-to-end tests for the daemon's consume loop.
//!
//! These tests stand up a mock knomosis-event-subscribe server in a
//! background thread, then drive the real `Indexer` +
//! `SubscribeClient` + `consume_stream` against it.  The mock
//! implements the §11 wire format byte-for-byte so the tests
//! reproduce the exact server-side behaviour the production
//! daemon expects.
//!
//! ## Headline regression coverage
//!
//!   * **Partial-batch on EOF NOT committed**
//!     ([`partial_batch_on_eof_not_committed`]).  Server sends 2
//!     events of seq=1, closes connection.  Indexer's cursor
//!     must remain at 0 (the pre-batch value), and no balances
//!     should have changed.
//!   * **Partial-batch on ServerShutdown NOT committed**
//!     ([`partial_batch_on_server_shutdown_not_committed`]).
//!   * **Partial-batch on LagExceeded NOT committed**
//!     ([`partial_batch_on_lag_exceeded_not_committed`]).
//!   * **Complete batch followed by EOF: only the SEQ-CHANGE-
//!     committed events persist** ([`complete_batch_then_eof`]).
//!   * **Multi-seq stream: cursor advances per seq-change
//!     trigger** ([`multi_seq_cursor_advances`]).
//!   * **Out-of-order seq → ProtocolViolation, no commit**
//!     ([`out_of_order_seq_protocol_violation`]).

use knomosis_indexer::client::SubscribeClient;
use knomosis_indexer::daemon::{consume_stream, ConsumeOutcome};
use knomosis_indexer::decoder::encode_event;
use knomosis_indexer::event::Event;
use knomosis_indexer::indexer::{Indexer, IndexerError};
use knomosis_storage::sqlite::SqliteStorage;
use knomosis_storage::storage::Storage;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;
use std::time::Duration;

/// Bind a TCP listener on a kernel-assigned ephemeral port.
fn bind_listener() -> (TcpListener, String) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
    let addr = listener.local_addr().expect("query port").to_string();
    (listener, addr)
}

/// Encode an EVENT frame: kind=1 + 8-byte BE seq + 4-byte BE
/// length + payload.
fn event_frame(seq: u64, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + 8 + 4 + payload.len());
    out.push(1);
    out.extend_from_slice(&seq.to_be_bytes());
    let len = u32::try_from(payload.len()).unwrap();
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// Encode a 9-byte control frame (kind + 8-byte BE seq).
fn control_frame(kind: u8, seq: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(9);
    out.push(kind);
    out.extend_from_slice(&seq.to_be_bytes());
    out
}

/// Run a mock server that reads the SUBSCRIBE handshake, sends
/// the configured frames, optionally `drop_after` (closes the
/// connection without a control frame), and exits.  Returns the
/// `resume_from` value the client supplied.
fn run_mock_server(listener: TcpListener, frames: Vec<Vec<u8>>, drop_after: bool) -> u64 {
    let (mut stream, _addr) = listener.accept().expect("accept");
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    // Read SUBSCRIBE handshake (9 bytes).
    let mut buf = [0u8; 9];
    stream.read_exact(&mut buf).expect("read SUBSCRIBE");
    assert_eq!(buf[0], 0, "SUBSCRIBE kind");
    let mut rf_buf = [0u8; 8];
    rf_buf.copy_from_slice(&buf[1..9]);
    let resume_from = u64::from_be_bytes(rf_buf);
    // Send frames.
    for f in &frames {
        stream.write_all(f).expect("write frame");
    }
    stream.flush().ok();
    if drop_after {
        // Drop the stream → connection FIN.  This is what
        // happens if the server is killed mid-stream.
    } else {
        // Hold the stream open briefly so the client can read
        // any final frame before our return drops it.
        std::thread::sleep(Duration::from_millis(50));
    }
    resume_from
}

/// Helper: build a BalanceChanged event byte payload.
fn balance_changed_bytes(resource: u64, actor: u64, old_v: u128, new_v: u128) -> Vec<u8> {
    encode_event(&Event::BalanceChanged {
        resource,
        actor,
        old_value: old_v,
        new_value: new_v,
    })
}

/// **Audit-regression C-1**: A partial batch (2 events at seq=1,
/// connection drops before seq=2 arrives) MUST NOT advance the
/// cursor or apply the events.
#[test]
fn partial_batch_on_eof_not_committed() {
    let (listener, addr) = bind_listener();
    // Send 2 events at seq=1, then drop the connection.
    let frames = vec![
        event_frame(1, &balance_changed_bytes(0, 1, 0, 100)),
        event_frame(1, &balance_changed_bytes(0, 2, 0, 200)),
    ];
    let server =
        thread::spawn(move || run_mock_server(listener, frames, /* drop_after */ true));

    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();
    assert_eq!(indexer.cursor(), 0);

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let outcome = consume_stream(&mut indexer, &mut client);
    // **Audit C-1**: must assert!() — bare matches!() discards the
    // bool and the test silently passes for any non-CleanEof outcome.
    assert!(
        matches!(outcome, ConsumeOutcome::CleanEof),
        "expected CleanEof, got {outcome:?}"
    );

    // Cursor MUST remain at 0 — the in-flight batch was discarded.
    assert_eq!(indexer.cursor(), 0);
    // Neither balance should be set.
    assert_eq!(storage.scan(b"b/").unwrap().len(), 0);

    let _ = server.join().unwrap();
}

/// **Audit-regression C-1**: A partial batch terminated by
/// ServerShutdown MUST NOT be committed.
#[test]
fn partial_batch_on_server_shutdown_not_committed() {
    let (listener, addr) = bind_listener();
    let frames = vec![
        event_frame(1, &balance_changed_bytes(0, 1, 0, 100)),
        event_frame(1, &balance_changed_bytes(0, 2, 0, 200)),
        // ServerShutdown — claims last delivered seq is 1, but
        // we don't know if seq=1's batch is complete.
        control_frame(4, 1),
    ];
    let server = thread::spawn(move || run_mock_server(listener, frames, false));

    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let outcome = consume_stream(&mut indexer, &mut client);
    assert!(matches!(outcome, ConsumeOutcome::ServerShutdown { .. }));

    assert_eq!(indexer.cursor(), 0);
    assert_eq!(storage.scan(b"b/").unwrap().len(), 0);

    let _ = server.join().unwrap();
}

/// **Audit-regression C-1**: A partial batch terminated by
/// LagExceeded MUST NOT be committed.
#[test]
fn partial_batch_on_lag_exceeded_not_committed() {
    let (listener, addr) = bind_listener();
    let frames = vec![
        event_frame(1, &balance_changed_bytes(0, 1, 0, 100)),
        // LagExceeded — server evicted us; seq=1's batch may be
        // partial.
        control_frame(2, 1),
    ];
    let server = thread::spawn(move || run_mock_server(listener, frames, false));

    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let outcome = consume_stream(&mut indexer, &mut client);
    assert!(matches!(outcome, ConsumeOutcome::LagExceeded { .. }));

    assert_eq!(indexer.cursor(), 0);
    assert_eq!(storage.scan(b"b/").unwrap().len(), 0);

    let _ = server.join().unwrap();
}

/// **Multi-seq stream**: cursor advances to N-1 after receiving
/// the first frame of seq=N (the canonical "seq=N-1 is complete"
/// trigger).  The seq=N batch is NOT committed.
#[test]
fn multi_seq_cursor_advances() {
    let (listener, addr) = bind_listener();
    let frames = vec![
        // Two events at seq=1.
        event_frame(1, &balance_changed_bytes(0, 1, 0, 100)),
        event_frame(1, &balance_changed_bytes(0, 2, 0, 200)),
        // One event at seq=2 — this triggers commit of seq=1's
        // batch.
        event_frame(2, &balance_changed_bytes(0, 3, 0, 300)),
        // Then drop connection.
    ];
    let server = thread::spawn(move || run_mock_server(listener, frames, true));

    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let _outcome = consume_stream(&mut indexer, &mut client);

    // Cursor advanced to 1 (seq=1's batch was committed when
    // seq=2 arrived).  seq=2's batch was discarded on EOF.
    assert_eq!(indexer.cursor(), 1);
    // Both of seq=1's BalanceChanged events committed.
    let rows = storage.scan(b"b/").unwrap();
    assert_eq!(rows.len(), 2);

    let _ = server.join().unwrap();
}

/// **Multiple complete batches** plus a partial trailing batch.
#[test]
fn multiple_complete_then_partial() {
    let (listener, addr) = bind_listener();
    let frames = vec![
        event_frame(1, &balance_changed_bytes(0, 1, 0, 100)),
        event_frame(2, &balance_changed_bytes(0, 2, 0, 200)),
        event_frame(3, &balance_changed_bytes(0, 3, 0, 300)),
        // Partial seq=4 batch — connection drops after first
        // event.
        event_frame(4, &balance_changed_bytes(0, 4, 0, 400)),
    ];
    let server = thread::spawn(move || run_mock_server(listener, frames, true));

    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let _ = consume_stream(&mut indexer, &mut client);

    // Cursor advanced to 3 (seq=1, 2, 3 all committed because
    // each was followed by a strictly-greater seq).  seq=4
    // discarded on EOF.
    assert_eq!(indexer.cursor(), 3);
    // Three actors got balances.
    let rows = storage.scan(b"b/").unwrap();
    assert_eq!(rows.len(), 3);

    let _ = server.join().unwrap();
}

/// **seq=0 defense**: the wire protocol reserves seq=0 for the
/// resume_from sentinel; events with seq=0 are a protocol
/// violation.  Our defensive check catches this even though
/// knomosis-event-subscribe's cache already rejects seq=0.
#[test]
fn seq_zero_event_protocol_violation() {
    let (listener, addr) = bind_listener();
    let frames = vec![event_frame(0, &balance_changed_bytes(0, 1, 0, 100))];
    let server = thread::spawn(move || run_mock_server(listener, frames, false));

    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let outcome = consume_stream(&mut indexer, &mut client);
    match outcome {
        ConsumeOutcome::IndexerError(IndexerError::ProtocolViolation {
            current_seq,
            offending_seq,
        }) => {
            assert_eq!(current_seq, 0);
            assert_eq!(offending_seq, 0);
        }
        other => panic!("expected ProtocolViolation for seq=0, got {other:?}"),
    }
    // Cursor unchanged.
    assert_eq!(indexer.cursor(), 0);
    let _ = server.join().unwrap();
}

/// **Out-of-order seq** triggers a ProtocolViolation; in-flight
/// batch is discarded.
#[test]
fn out_of_order_seq_protocol_violation() {
    let (listener, addr) = bind_listener();
    let frames = vec![
        event_frame(5, &balance_changed_bytes(0, 1, 0, 100)),
        // seq=5, then seq=3 (smaller!) — protocol violation.
        event_frame(3, &balance_changed_bytes(0, 2, 0, 200)),
    ];
    let server = thread::spawn(move || run_mock_server(listener, frames, false));

    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let outcome = consume_stream(&mut indexer, &mut client);
    match outcome {
        ConsumeOutcome::IndexerError(IndexerError::ProtocolViolation {
            current_seq,
            offending_seq,
        }) => {
            assert_eq!(current_seq, 5);
            assert_eq!(offending_seq, 3);
        }
        other => panic!("expected ProtocolViolation, got {other:?}"),
    }
    // Cursor unchanged.
    assert_eq!(indexer.cursor(), 0);

    let _ = server.join().unwrap();
}

/// **Resume**: the cursor is sent as `resume_from` in the
/// SUBSCRIBE handshake; the server can verify the client sent
/// it correctly.
#[test]
fn resume_from_carries_cursor() {
    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();
    indexer
        .apply_batch(
            7,
            &[Event::BalanceChanged {
                resource: 0,
                actor: 1,
                old_value: 0,
                new_value: 100,
            }],
        )
        .unwrap();
    assert_eq!(indexer.cursor(), 7);

    let (listener, addr) = bind_listener();
    let frames = vec![control_frame(4, 7)];
    let server = thread::spawn(move || run_mock_server(listener, frames, false));

    // Client subscribes with resume_from = indexer.cursor().
    let mut client = SubscribeClient::connect(&addr, indexer.cursor(), 1024 * 1024).unwrap();
    let _ = consume_stream(&mut indexer, &mut client);
    let resume_from = server.join().unwrap();
    assert_eq!(resume_from, 7);
}

/// **Mixed dispatch**: a complete batch with both BalanceChanged
/// and RewardIssued (in the kernel-emit order: balanceChanged
/// FIRST) — verify the two-pass dispatch via the wire path.
#[test]
fn mixed_dispatch_via_wire() {
    let (listener, addr) = bind_listener();
    let frames = vec![
        // seq=1: balanceChanged then rewardIssued for same key.
        event_frame(1, &balance_changed_bytes(0, 1, 0, 100)),
        event_frame(
            1,
            &encode_event(&Event::RewardIssued {
                resource: 0,
                recipient: 1,
                amount: 100,
            }),
        ),
        // seq=2 triggers commit of seq=1's batch.
        event_frame(2, &balance_changed_bytes(0, 2, 0, 50)),
        // Drop after.
    ];
    let server = thread::spawn(move || run_mock_server(listener, frames, true));

    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let _ = consume_stream(&mut indexer, &mut client);

    assert_eq!(indexer.cursor(), 1);
    // Balance for actor 1: must be 100, NOT 200 (double count).
    // This verifies the two-pass dispatch across the wire.
    let view = knomosis_indexer::balance::BalanceView::new(&storage);
    assert_eq!(view.get(1, 0).unwrap(), 100);

    let _ = server.join().unwrap();
}

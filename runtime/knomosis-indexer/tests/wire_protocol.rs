// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Wire-protocol integration tests for `knomosis-indexer`.
//!
//! These tests stand up a tiny mock knomosis-event-subscribe server
//! in a background thread, then exercise the indexer's
//! [`SubscribeClient`] against it.  The mock implements the
//! §11 wire format byte-for-byte so the test reproduces the
//! exact server-side behaviour the production indexer expects.
//!
//! We do NOT depend on `knomosis-event-subscribe` here — see the
//! `client.rs` module docstring for the rationale (the wire
//! protocol is small enough to re-implement on both sides
//! independently; pulling in the full subscription server
//! would drag in the entire subscriber-registry stack for no
//! testing benefit).

use knomosis_indexer::client::{ClientError, ServerFrame, SubscribeClient};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;
use std::time::Duration;

/// Bind a TCP listener on a kernel-assigned ephemeral port.
/// Avoids any chance of collision with other tests running in
/// parallel (including across cargo-test processes on the same
/// host) — the kernel guarantees uniqueness.
fn bind_listener() -> (TcpListener, String) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port on 127.0.0.1");
    let addr = listener
        .local_addr()
        .expect("query ephemeral port assignment")
        .to_string();
    (listener, addr)
}

/// Read the client's SUBSCRIBE handshake from `stream` and
/// return the `resume_from` value.
fn read_subscribe(stream: &mut TcpStream) -> u64 {
    let mut buf = [0u8; 9];
    stream.read_exact(&mut buf).expect("read SUBSCRIBE");
    assert_eq!(buf[0], 0, "expected SUBSCRIBE kind");
    let mut rf_buf = [0u8; 8];
    rf_buf.copy_from_slice(&buf[1..9]);
    u64::from_be_bytes(rf_buf)
}

/// Encode an EVENT frame.  Mirrors
/// `knomosis-event-subscribe::frame::encode_outbound`.
fn encode_event(seq: u64, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + 8 + 4 + payload.len());
    out.push(1); // KIND_EVENT
    out.extend_from_slice(&seq.to_be_bytes());
    let len = u32::try_from(payload.len()).unwrap();
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// Encode a 9-byte control frame (kind + 8-byte seq).
fn encode_control(kind: u8, seq: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(9);
    out.push(kind);
    out.extend_from_slice(&seq.to_be_bytes());
    out
}

/// Mock server that accepts one connection, reads the SUBSCRIBE
/// handshake, then sends the configured `frames` and closes
/// the connection.
fn run_mock_server(listener: TcpListener, frames: Vec<Vec<u8>>) -> u64 {
    let (mut stream, _addr) = listener.accept().expect("accept");
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let resume_from = read_subscribe(&mut stream);
    for f in &frames {
        stream.write_all(f).expect("write frame");
    }
    stream.flush().ok();
    // Drop the stream → server side closes the connection.
    resume_from
}

/// Round-trip: server sends two EVENT frames + ServerShutdown,
/// the client reads them all back correctly.
#[test]
fn round_trip_event_then_shutdown() {
    let (listener, addr) = bind_listener();
    let frames = vec![
        encode_event(1, b"event-payload-1"),
        encode_event(2, b"event-payload-2"),
        encode_control(4, 2), // KIND_SERVER_SHUTDOWN
    ];

    let server_thread = thread::spawn(move || run_mock_server(listener, frames));

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let f1 = client.read_frame().unwrap();
    assert_eq!(
        f1,
        ServerFrame::Event {
            seq: 1,
            payload: b"event-payload-1".to_vec(),
        }
    );
    let f2 = client.read_frame().unwrap();
    assert_eq!(
        f2,
        ServerFrame::Event {
            seq: 2,
            payload: b"event-payload-2".to_vec(),
        }
    );
    let f3 = client.read_frame().unwrap();
    assert_eq!(
        f3,
        ServerFrame::ServerShutdown {
            last_delivered_seq: 2
        }
    );

    let resume_from = server_thread.join().unwrap();
    assert_eq!(resume_from, 0);
}

/// Resume-from: client sends a non-zero resume_from in the
/// handshake; server reads it correctly.
#[test]
fn resume_from_threaded_through_handshake() {
    let (listener, addr) = bind_listener();
    let frames = vec![encode_control(4, 42)]; // SHUTDOWN

    let server_thread = thread::spawn(move || run_mock_server(listener, frames));

    let mut client = SubscribeClient::connect(&addr, 42, 1024 * 1024).unwrap();
    let _ = client.read_frame().unwrap();

    let resume_from = server_thread.join().unwrap();
    assert_eq!(resume_from, 42);
}

/// LagExceeded frame round-trips.
#[test]
fn lag_exceeded_round_trips() {
    let (listener, addr) = bind_listener();
    let frames = vec![encode_control(2, 100)]; // KIND_LAG_EXCEEDED

    let server_thread = thread::spawn(move || run_mock_server(listener, frames));

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let f = client.read_frame().unwrap();
    assert_eq!(
        f,
        ServerFrame::LagExceeded {
            last_delivered_seq: 100
        }
    );
    let _ = server_thread.join().unwrap();
}

/// Truncated frame round-trips.
#[test]
fn truncated_round_trips() {
    let (listener, addr) = bind_listener();
    let frames = vec![encode_control(3, 7)]; // KIND_TRUNCATED

    let server_thread = thread::spawn(move || run_mock_server(listener, frames));

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let f = client.read_frame().unwrap();
    assert_eq!(
        f,
        ServerFrame::Truncated {
            oldest_available_seq: 7
        }
    );
    let _ = server_thread.join().unwrap();
}

/// InvalidRequest round-trips.
#[test]
fn invalid_request_round_trips() {
    let (listener, addr) = bind_listener();
    let frames = vec![encode_control(5, 0)]; // KIND_INVALID_REQUEST

    let server_thread = thread::spawn(move || run_mock_server(listener, frames));

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let f = client.read_frame().unwrap();
    assert_eq!(f, ServerFrame::InvalidRequest);
    let _ = server_thread.join().unwrap();
}

/// Clean EOF: server sends nothing then closes.
#[test]
fn clean_eof() {
    let (listener, addr) = bind_listener();
    let frames = Vec::new();

    let server_thread = thread::spawn(move || run_mock_server(listener, frames));

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let result = client.read_frame();
    assert!(matches!(result, Err(ClientError::Eof)));
    let _ = server_thread.join().unwrap();
}

/// Oversize frame rejected by the client.
#[test]
fn oversize_frame_rejected() {
    let (listener, addr) = bind_listener();
    // Construct an EVENT frame with a declared length of 100, but
    // configure the client's max_frame_size at 50.
    let mut frame = vec![1u8]; // KIND_EVENT
    frame.extend_from_slice(&42u64.to_be_bytes()); // seq
    frame.extend_from_slice(&100u32.to_be_bytes()); // declared length
                                                    // Don't actually send the 100 bytes; the client should
                                                    // reject on the length prefix alone.
    let frames = vec![frame];

    let server_thread = thread::spawn(move || run_mock_server(listener, frames));

    let mut client = SubscribeClient::connect(&addr, 0, 50).unwrap();
    let result = client.read_frame();
    match result {
        Err(ClientError::OversizeFrame { declared, max }) => {
            assert_eq!(declared, 100);
            assert_eq!(max, 50);
        }
        other => panic!("expected OversizeFrame, got {other:?}"),
    }
    let _ = server_thread.join().unwrap();
}

/// Unknown frame kind rejected.
#[test]
fn unknown_kind_rejected() {
    let (listener, addr) = bind_listener();
    let mut frame = vec![0x99u8]; // unknown kind
    frame.extend_from_slice(&0u64.to_be_bytes());
    let frames = vec![frame];

    let server_thread = thread::spawn(move || run_mock_server(listener, frames));

    let mut client = SubscribeClient::connect(&addr, 0, 1024).unwrap();
    let result = client.read_frame();
    match result {
        Err(ClientError::UnknownKind { kind }) => assert_eq!(kind, 0x99),
        other => panic!("expected UnknownKind, got {other:?}"),
    }
    let _ = server_thread.join().unwrap();
}

/// Truncated mid-frame (server drops the connection mid-payload).
#[test]
fn truncated_mid_payload() {
    let (listener, addr) = bind_listener();
    // EVENT frame claiming 100-byte payload, but only 10 bytes
    // actually sent.
    let mut frame = vec![1u8];
    frame.extend_from_slice(&1u64.to_be_bytes());
    frame.extend_from_slice(&100u32.to_be_bytes());
    frame.extend_from_slice(&[0xAA; 10]); // only 10 of the 100 bytes
    let frames = vec![frame];

    let server_thread = thread::spawn(move || run_mock_server(listener, frames));

    let mut client = SubscribeClient::connect(&addr, 0, 1024).unwrap();
    let result = client.read_frame();
    match result {
        Err(ClientError::Truncated { .. }) => {}
        other => panic!("expected Truncated, got {other:?}"),
    }
    let _ = server_thread.join().unwrap();
}

/// Connect to a non-existent endpoint surfaces an Io error.
#[test]
fn connect_failure() {
    // Use an unbound port at a high number.  Race window is
    // negligible since we pick a port that's not in our test
    // allocation range.
    let result = SubscribeClient::connect("127.0.0.1:1", 0, 1024);
    assert!(matches!(result, Err(ClientError::Io(_))));
}

/// **Empty-payload regression**: a zero-length EVENT frame
/// (declared length = 0) decodes without panicking.  The
/// resulting `Event` payload is an empty byte vector — the
/// indexer's decoder will reject it as `Truncated` (since the
/// constructor tag head requires 9 bytes), but the client
/// itself MUST NOT panic on `vec![0u8; 0]`.
#[test]
fn empty_payload_zero_length_frame() {
    let (listener, addr) = bind_listener();
    // EVENT frame with declared length = 0 and no payload bytes.
    let mut frame = vec![1u8]; // KIND_EVENT
    frame.extend_from_slice(&7u64.to_be_bytes()); // seq=7
    frame.extend_from_slice(&0u32.to_be_bytes()); // length=0
                                                  // No payload bytes.
    let frames = vec![frame];

    let server_thread = thread::spawn(move || run_mock_server(listener, frames));

    let mut client = SubscribeClient::connect(&addr, 0, 1024 * 1024).unwrap();
    let result = client.read_frame().unwrap();
    match result {
        ServerFrame::Event { seq, payload } => {
            assert_eq!(seq, 7);
            assert_eq!(payload.len(), 0);
        }
        other => panic!("expected Event{{seq=7, payload=[]}}, got {other:?}"),
    }
    let _ = server_thread.join().unwrap();
}

/// **DoS bound**: a server claiming an oversize declared length
/// (just under the configured max) doesn't actually allocate
/// that much memory unless we read the payload.  We can't
/// directly assert on allocation, but we can verify the
/// declared-length check fires before the read attempts to
/// pre-allocate.
#[test]
fn oversize_declared_length_rejected_before_allocation() {
    let (listener, addr) = bind_listener();
    // Declared length = 2x configured max.  The client should
    // reject without reading any payload bytes.
    let max_frame = 1024;
    let mut frame = vec![1u8];
    frame.extend_from_slice(&1u64.to_be_bytes());
    frame.extend_from_slice(&((max_frame * 2) as u32).to_be_bytes());
    // No payload bytes — we never read them, so the check must
    // fire on the length prefix alone.
    let frames = vec![frame];

    let server_thread = thread::spawn(move || run_mock_server(listener, frames));

    let mut client = SubscribeClient::connect(&addr, 0, max_frame).unwrap();
    let result = client.read_frame();
    match result {
        Err(ClientError::OversizeFrame { declared, max }) => {
            assert_eq!(declared, max_frame * 2);
            assert_eq!(max, max_frame);
        }
        other => panic!("expected OversizeFrame, got {other:?}"),
    }
    let _ = server_thread.join().unwrap();
}

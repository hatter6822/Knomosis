// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! End-to-end integration tests for the `eth_call`-based
//! game-state reader.  These tests stand up a mock JSON-RPC
//! server in a background thread, point the reader at it, and
//! verify the full request/response cycle (calldata encoding,
//! `eth_call` invocation, response parsing, deployment-id
//! cross-check).

use canon_faultproof_observer::game::{GameStatus, TurnSide};
use canon_faultproof_observer::state_reader::{
    decode_game_state, encode_games_calldata, ContractGameReader, GameStateReadError,
    GAMES_RESPONSE_BYTES,
};
use canon_l1_ingest::source::json_rpc::JsonRpcL1Source;
use serde_json::Value;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

/// A handle to a running mock JSON-RPC server.  Drop joins the
/// thread (after the test's last request).
struct MockRpcServer {
    /// The endpoint URL clients connect to.
    url: String,
    /// Captured request bodies for assertion.
    captured_requests: Arc<Mutex<Vec<String>>>,
    /// The next response body the server will return.  Set via
    /// [`Self::set_response`].
    next_response_hex: Arc<Mutex<String>>,
    handle: Option<JoinHandle<()>>,
    stop: Arc<std::sync::atomic::AtomicBool>,
}

impl MockRpcServer {
    fn spawn() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral");
        let addr = listener.local_addr().expect("local_addr");
        let url = format!("http://{addr}");
        let captured: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let next_response: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let captured_clone = captured.clone();
        let next_response_clone = next_response.clone();
        let stop_clone = stop.clone();
        listener
            .set_nonblocking(true)
            .expect("set listener nonblocking");
        // Synchronisation: ensure the accept loop has entered its
        // first iteration before `spawn()` returns.  Without this
        // barrier, under heavy parallel-test load (`cargo test
        // --workspace` runs hundreds of tests concurrently), the
        // scheduler can delay the accept thread's first poll past
        // the client's connect-and-send window, causing intermittent
        // request-timeout flakes.  A buffered-capacity-1 channel
        // pins the ordering: spawn() returns only AFTER the accept
        // thread has sent its ready signal.  Capacity 1 (vs 0
        // rendezvous) means the sender doesn't block, so a
        // timeout in `recv_timeout` doesn't leave the thread
        // stuck blocked-on-send.
        let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel::<()>(1);
        let handle = thread::spawn(move || {
            // Signal that the accept loop is about to start.
            let _ = ready_tx.send(());
            while !stop_clone.load(std::sync::atomic::Ordering::Acquire) {
                match listener.accept() {
                    Ok((stream, _peer)) => {
                        let cap = captured_clone.clone();
                        let resp = next_response_clone.clone();
                        if let Err(e) = handle_request(stream, &cap, &resp) {
                            eprintln!("mock server error: {e}");
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(e) => {
                        eprintln!("mock server accept error: {e}");
                        break;
                    }
                }
            }
        });
        // Wait up to 5 s for the accept thread to signal ready.
        // The blocking `recv` here pairs with the `send` above
        // and synchronises happens-before on the listener.
        ready_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("mock server accept thread did not start within 5 s");
        Self {
            url,
            captured_requests: captured,
            next_response_hex: next_response,
            handle: Some(handle),
            stop,
        }
    }

    fn set_response_hex(&self, hex: &str) {
        *self.next_response_hex.lock().unwrap() = hex.to_string();
    }

    fn captured(&self) -> Vec<String> {
        self.captured_requests.lock().unwrap().clone()
    }
}

impl Drop for MockRpcServer {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Release);
        if let Some(h) = self.handle.take() {
            // Give the accept loop one polling-period to exit.
            let _ = h.join();
        }
    }
}

fn handle_request(
    mut stream: TcpStream,
    captured: &Arc<Mutex<Vec<String>>>,
    next_response: &Arc<Mutex<String>>,
) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    let mut buf = [0u8; 8192];
    let n = stream.read(&mut buf)?;
    let raw = String::from_utf8_lossy(&buf[..n]).to_string();
    // Extract the JSON body after the empty-line header terminator.
    let body = if let Some(idx) = raw.find("\r\n\r\n") {
        raw[idx + 4..].to_string()
    } else {
        raw.clone()
    };
    captured.lock().unwrap().push(body.clone());
    let result_hex = next_response.lock().unwrap().clone();
    let resp_json = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "result": result_hex,
    });
    let resp_body = serde_json::to_string(&resp_json).unwrap();
    let response = format!(
        "HTTP/1.1 200 OK\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\r\n{}",
        resp_body.len(),
        resp_body
    );
    stream.write_all(response.as_bytes())?;
    stream.flush()?;
    Ok(())
}

fn synth_game_state_bytes(deployment_id: [u8; 32], low_idx: u64, high_idx: u64) -> Vec<u8> {
    let mut out = vec![0u8; GAMES_RESPONSE_BYTES];
    // Slot 0: sequencer = 0x1111 (low 8 bytes).
    out[24..32].copy_from_slice(&0x1111u64.to_be_bytes());
    // Slot 1: challenger = 0x2222.
    out[32 + 24..32 + 32].copy_from_slice(&0x2222u64.to_be_bytes());
    // Slot 2: low.idx
    out[2 * 32 + 24..2 * 32 + 32].copy_from_slice(&low_idx.to_be_bytes());
    // Slot 3: low.commit = [0x33; 32]
    out[3 * 32..4 * 32].copy_from_slice(&[0x33u8; 32]);
    // Slot 4: high.idx
    out[4 * 32 + 24..4 * 32 + 32].copy_from_slice(&high_idx.to_be_bytes());
    // Slot 5: high.commit = [0x44; 32]
    out[5 * 32..6 * 32].copy_from_slice(&[0x44u8; 32]);
    // Slot 6: hasPendingMidpoint = false
    // Slot 7-8: pendingMidpoint (zeroed)
    // Slot 9: depth = 3
    out[9 * 32 + 24..9 * 32 + 32].copy_from_slice(&3u64.to_be_bytes());
    // Slot 10: turn = 0 (Sequencer)
    // Slot 11: turnDeadline = 1000
    out[11 * 32 + 24..11 * 32 + 32].copy_from_slice(&1000u64.to_be_bytes());
    // Slot 12: sequencerBond = 1 ETH (1e18)
    out[12 * 32 + 16..12 * 32 + 32].copy_from_slice(&1_000_000_000_000_000_000u128.to_be_bytes());
    // Slot 13: challengerBond = 1 ETH
    out[13 * 32 + 16..13 * 32 + 32].copy_from_slice(&1_000_000_000_000_000_000u128.to_be_bytes());
    // Slot 14: status = 0 (InProgress)
    // Slot 15: deploymentId
    out[15 * 32..16 * 32].copy_from_slice(&deployment_id);
    // Slot 16: lastStepBlock = 5000
    out[16 * 32 + 24..16 * 32 + 32].copy_from_slice(&5000u64.to_be_bytes());
    // Slot 17: disputedLogIndex = high_idx
    out[17 * 32 + 24..17 * 32 + 32].copy_from_slice(&high_idx.to_be_bytes());
    out
}

#[test]
fn end_to_end_eth_call_round_trip() {
    let server = MockRpcServer::spawn();
    let deployment_id = [0xCDu8; 32];
    let response_bytes = synth_game_state_bytes(deployment_id, 100, 200);
    let response_hex = format!("0x{}", hex::encode(&response_bytes));
    server.set_response_hex(&response_hex);

    let rpc = JsonRpcL1Source::new(&server.url).expect("rpc source");
    let contract_addr = [0xABu8; 20];
    let reader = ContractGameReader::new(&rpc, contract_addr);

    let state = reader.read_game(42).expect("read_game");
    assert_eq!(state.sequencer, 0x1111);
    assert_eq!(state.challenger, 0x2222);
    assert_eq!(state.range.low.idx, 100);
    assert_eq!(state.range.high.idx, 200);
    assert_eq!(state.depth, 3);
    assert_eq!(state.turn, TurnSide::Sequencer);
    assert_eq!(state.sequencer_bond, 1_000_000_000_000_000_000);
    assert_eq!(state.status, GameStatus::InProgress);
    assert_eq!(state.deployment_id, deployment_id);

    // The mock server saw exactly one request.
    let reqs = server.captured();
    assert_eq!(reqs.len(), 1, "expected exactly one request");
    let req: Value = serde_json::from_str(&reqs[0]).expect("parse json");
    assert_eq!(req["jsonrpc"], "2.0");
    assert_eq!(req["method"], "eth_call");
    // Verify calldata matches what we'd produce locally.
    let expected_calldata = encode_games_calldata(42);
    let expected_calldata_hex = format!("0x{}", hex::encode(expected_calldata));
    assert_eq!(req["params"][0]["data"], expected_calldata_hex);
    // Verify "to" address matches.
    let expected_to = format!("0x{}", hex::encode(contract_addr));
    assert_eq!(req["params"][0]["to"], expected_to);
    // Verify block tag is "latest".
    assert_eq!(req["params"][1], "latest");
}

#[test]
fn read_and_validate_accepts_matching_deployment_id() {
    let server = MockRpcServer::spawn();
    let deployment_id = [0xEFu8; 32];
    let response_bytes = synth_game_state_bytes(deployment_id, 50, 150);
    server.set_response_hex(&format!("0x{}", hex::encode(response_bytes)));

    let rpc = JsonRpcL1Source::new(&server.url).expect("rpc source");
    let reader = ContractGameReader::new(&rpc, [0xABu8; 20]);
    let state = reader
        .read_and_validate(7, deployment_id)
        .expect("validate ok");
    assert_eq!(state.deployment_id, deployment_id);
}

#[test]
fn read_and_validate_rejects_mismatched_deployment_id() {
    let server = MockRpcServer::spawn();
    let contract_deployment_id = [0x11u8; 32];
    let observer_expected = [0x22u8; 32];
    let response_bytes = synth_game_state_bytes(contract_deployment_id, 50, 150);
    server.set_response_hex(&format!("0x{}", hex::encode(response_bytes)));

    let rpc = JsonRpcL1Source::new(&server.url).expect("rpc source");
    let reader = ContractGameReader::new(&rpc, [0xABu8; 20]);
    let err = reader.read_and_validate(7, observer_expected);
    assert!(matches!(
        err,
        Err(GameStateReadError::DeploymentIdMismatch { .. })
    ));
}

#[test]
fn read_and_validate_rejects_degenerate_range() {
    let server = MockRpcServer::spawn();
    let deployment_id = [0x77u8; 32];
    // low.idx == high.idx is degenerate.
    let response_bytes = synth_game_state_bytes(deployment_id, 100, 100);
    server.set_response_hex(&format!("0x{}", hex::encode(response_bytes)));

    let rpc = JsonRpcL1Source::new(&server.url).expect("rpc source");
    let reader = ContractGameReader::new(&rpc, [0xABu8; 20]);
    let err = reader.read_and_validate(7, deployment_id);
    assert!(matches!(
        err,
        Err(GameStateReadError::DegenerateRange { .. })
    ));
}

#[test]
fn malformed_response_surfaces_typed_error() {
    let server = MockRpcServer::spawn();
    // Set a malformed (too-short) response.
    server.set_response_hex("0xdeadbeef");
    let rpc = JsonRpcL1Source::new(&server.url).expect("rpc source");
    let reader = ContractGameReader::new(&rpc, [0xABu8; 20]);
    let err = reader.read_game(7);
    assert!(
        matches!(err, Err(GameStateReadError::WrongLength { .. })),
        "expected WrongLength error from 4-byte response, got {err:?}",
    );
}

/// Audit-pass-4-round-5 HIGH regression: the round-3 fix added
/// `ZeroSequencer` / `ZeroChallenger` / `SequencerChallengerCollision`
/// invariant checks in `read_and_validate`.  Round-4 added tests
/// for the ACCEPTANCE side but not the REJECTION side.  Round-5
/// adds the rejection-path tests below to close that gap.

#[test]
fn read_and_validate_rejects_zero_sequencer_address() {
    let server = MockRpcServer::spawn();
    let deployment_id = [0xCDu8; 32];
    let mut response = synth_game_state_bytes(deployment_id, 100, 200);
    // Zero out sequencer's full 20-byte address (slot[12..32] of slot 0).
    for b in &mut response[12..32] {
        *b = 0;
    }
    server.set_response_hex(&format!("0x{}", hex::encode(&response)));
    let rpc = JsonRpcL1Source::new(&server.url).expect("rpc source");
    let reader = ContractGameReader::new(&rpc, [0xABu8; 20]);
    let err = reader.read_and_validate(7, deployment_id);
    assert!(
        matches!(err, Err(GameStateReadError::ZeroSequencer)),
        "expected ZeroSequencer, got {err:?}"
    );
}

#[test]
fn read_and_validate_rejects_zero_challenger_address() {
    let server = MockRpcServer::spawn();
    let deployment_id = [0xCDu8; 32];
    let mut response = synth_game_state_bytes(deployment_id, 100, 200);
    // Zero out challenger's full 20-byte address (slot[12..32] of slot 1).
    for b in &mut response[32 + 12..32 + 32] {
        *b = 0;
    }
    server.set_response_hex(&format!("0x{}", hex::encode(&response)));
    let rpc = JsonRpcL1Source::new(&server.url).expect("rpc source");
    let reader = ContractGameReader::new(&rpc, [0xABu8; 20]);
    let err = reader.read_and_validate(7, deployment_id);
    assert!(
        matches!(err, Err(GameStateReadError::ZeroChallenger)),
        "expected ZeroChallenger, got {err:?}"
    );
}

#[test]
fn read_and_validate_rejects_sequencer_challenger_collision() {
    let server = MockRpcServer::spawn();
    let deployment_id = [0xCDu8; 32];
    let mut response = synth_game_state_bytes(deployment_id, 100, 200);
    // Set both sequencer and challenger to the SAME full 20-byte
    // address (non-zero high bytes + non-zero low bytes).  This
    // would NOT be caught by the old low-8 projection if the low
    // bytes happened to differ, but the new full-address check
    // catches identical full addresses.
    let common_addr: [u8; 20] = [
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x01, 0x02, 0x03, 0x04, 0x05,
    ];
    response[12..32].copy_from_slice(&common_addr);
    response[32 + 12..32 + 32].copy_from_slice(&common_addr);
    server.set_response_hex(&format!("0x{}", hex::encode(&response)));
    let rpc = JsonRpcL1Source::new(&server.url).expect("rpc source");
    let reader = ContractGameReader::new(&rpc, [0xABu8; 20]);
    let err = reader.read_and_validate(7, deployment_id);
    assert!(
        matches!(
            err,
            Err(GameStateReadError::SequencerChallengerCollision(_))
        ),
        "expected SequencerChallengerCollision, got {err:?}"
    );
}

#[test]
fn decode_helpers_round_trip() {
    let deployment_id = [0xAAu8; 32];
    let bytes = synth_game_state_bytes(deployment_id, 0, 1024);
    let gs = decode_game_state(&bytes).expect("decode");
    assert_eq!(gs.range.low.idx, 0);
    assert_eq!(gs.range.high.idx, 1024);
    assert_eq!(gs.deployment_id, deployment_id);
}

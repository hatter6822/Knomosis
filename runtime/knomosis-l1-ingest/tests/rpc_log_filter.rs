// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `JsonRpcL1Source::logs_in_block_by_hash` trusts its RPC to honour
//! the filter it was given — and then verifies the answer anyway.
//! These tests are the coverage for that verification.
//!
//! The `address` and `blockHash` filters both go out in the
//! `eth_getLogs` request, so a correct provider never trips either
//! check, and a mock is the only way to exercise them.  They are not
//! symmetric in consequence.  A log returned from the WRONG BLOCK is
//! a provider bug or a re-org artefact.  A log returned from the
//! WRONG CONTRACT is an attacker's: every downstream decoder keys on
//! `topics[0]`, and anyone can deploy a contract emitting the
//! bridge's event signatures, so an unchecked address turns a
//! provider bug into forged deposits and forged state roots that
//! arrive on the contract's own log stream and read as genuine.

use knomosis_l1_ingest::action::EthAddress;
use knomosis_l1_ingest::source::json_rpc::JsonRpcL1Source;
use knomosis_l1_ingest::source::{L1Source, SourceError};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

/// A mock JSON-RPC endpoint that answers every request with one
/// canned `result` value.
struct MockRpc {
    url: String,
    next_result: Arc<Mutex<Value>>,
    handle: Option<JoinHandle<()>>,
    stop: Arc<AtomicBool>,
}

impl MockRpc {
    fn spawn() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral");
        let url = format!("http://{}", listener.local_addr().expect("local_addr"));
        listener.set_nonblocking(true).expect("nonblocking");
        let next_result = Arc::new(Mutex::new(Value::Null));
        let stop = Arc::new(AtomicBool::new(false));
        let result_clone = next_result.clone();
        let stop_clone = stop.clone();
        // Barrier: return only once the accept loop is live, so a
        // client connecting immediately cannot race it.
        let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel::<()>(1);
        let handle = thread::spawn(move || {
            let _ = ready_tx.send(());
            while !stop_clone.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let r = result_clone.lock().unwrap().clone();
                        if let Err(e) = respond(stream, &r) {
                            eprintln!("mock rpc: {e}");
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(e) => {
                        eprintln!("mock rpc accept: {e}");
                        break;
                    }
                }
            }
        });
        ready_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("mock rpc did not start");
        Self {
            url,
            next_result,
            handle: Some(handle),
            stop,
        }
    }

    fn set_result(&self, v: Value) {
        *self.next_result.lock().unwrap() = v;
    }
}

impl Drop for MockRpc {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

/// Drain the whole request before answering, then half-close the
/// write side.  Responding while request bytes are still inbound
/// makes the close emit a RST, which the client sees as a mid-
/// response connection reset.
fn respond(mut stream: TcpStream, result: &Value) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    let mut data: Vec<u8> = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        if let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            let want: usize = String::from_utf8_lossy(&data[..end])
                .to_ascii_lowercase()
                .lines()
                .find_map(|l| {
                    l.strip_prefix("content-length:")
                        .and_then(|r| r.trim().parse().ok())
                })
                .unwrap_or(0);
            if data.len() - (end + 4) >= want {
                break;
            }
        }
        let n = stream.read(&mut buf)?;
        if n == 0 {
            break;
        }
        data.extend_from_slice(&buf[..n]);
    }
    let body = serde_json::to_string(&json!({
        "jsonrpc": "2.0", "id": 1, "result": result,
    }))
    .unwrap();
    write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )?;
    stream.flush()?;
    let _ = stream.shutdown(Shutdown::Write);
    Ok(())
}

const REQUESTED: [u8; 20] = [0xAA; 20];
const IMPOSTOR: [u8; 20] = [0xBB; 20];
const BLOCK_HASH: [u8; 32] = [0xCC; 32];
const OTHER_BLOCK: [u8; 32] = [0xDD; 32];

/// One `eth_getLogs` entry, with the emitting contract and the
/// block it claims to come from both under the test's control.
fn log_entry(address: [u8; 20], block_hash: [u8; 32]) -> Value {
    json!({
        "address":         format!("0x{}", hex::encode(address)),
        "topics":          [format!("0x{}", hex::encode([0xEEu8; 32]))],
        "data":            "0x",
        "blockNumber":     "0x64",
        "transactionHash": format!("0x{}", hex::encode([0x11u8; 32])),
        "logIndex":        "0x0",
        "blockHash":       format!("0x{}", hex::encode(block_hash)),
    })
}

fn read_logs(server: &MockRpc) -> Result<Vec<knomosis_l1_ingest::events::RawLog>, SourceError> {
    let src = JsonRpcL1Source::new(&server.url).expect("rpc source");
    src.logs_in_block_by_hash(&BLOCK_HASH, &EthAddress(REQUESTED))
}

/// Baseline: a well-behaved provider's answer is accepted, so the
/// rejections below are rejecting something specific rather than
/// everything.
#[test]
fn an_honest_providers_log_is_accepted() {
    let server = MockRpc::spawn();
    server.set_result(json!([log_entry(REQUESTED, BLOCK_HASH)]));

    let logs = read_logs(&server).expect("honest log accepted");

    assert_eq!(logs.len(), 1);
    assert_eq!(logs[0].address, EthAddress(REQUESTED));
}

/// **The forged-event case.**  A provider that ignores the `address`
/// filter hands back a log from a contract the caller never asked
/// about.  Downstream, `topics[0]` is the whole identity of an
/// event, so an impostor contract emitting the bridge's signatures
/// would be ingested as the bridge.
#[test]
fn a_log_from_another_contract_is_refused() {
    let server = MockRpc::spawn();
    server.set_result(json!([log_entry(IMPOSTOR, BLOCK_HASH)]));

    let err = read_logs(&server).expect_err("impostor contract must be refused");

    let msg = err.to_string();
    assert!(
        msg.contains(&hex::encode(IMPOSTOR)) && msg.contains(&hex::encode(REQUESTED)),
        "the error should name both the returned and requested contracts: {msg}"
    );
}

/// One good log does not launder a bad one: the batch is rejected
/// whole, so a provider cannot slip a forged entry in behind
/// genuine ones.
#[test]
fn one_impostor_rejects_the_whole_batch() {
    let server = MockRpc::spawn();
    server.set_result(json!([
        log_entry(REQUESTED, BLOCK_HASH),
        log_entry(IMPOSTOR, BLOCK_HASH),
    ]));

    read_logs(&server).expect_err("a batch containing an impostor must be refused");
}

/// The peer check, previously also uncovered: a log claiming a
/// different block than the one the filter named.
#[test]
fn a_log_from_another_block_is_refused() {
    let server = MockRpc::spawn();
    server.set_result(json!([log_entry(REQUESTED, OTHER_BLOCK)]));

    let err = read_logs(&server).expect_err("wrong-block log must be refused");

    assert!(
        err.to_string().contains(&hex::encode(OTHER_BLOCK)),
        "the error should name the returned blockHash: {err}"
    );
}

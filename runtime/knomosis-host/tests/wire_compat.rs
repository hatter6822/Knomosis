// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Wire back-compatibility + Rung-1 negotiation interop (Workstream
//! GP.8, Track A / FQ — Rung 1, FQ.14b).
//!
//! These tests are the end-to-end evidence that the FQ.9 collision
//! argument and the §2.6(3) "legacy clients degrade safely" invariant
//! hold in practice, over REAL TCP against a running host:
//!
//!   * a legacy (v1) client and a Rung-1 (v2) client both work against
//!     one host instance, on BOTH the FIFO and the DRR scheduler (the
//!     negotiation is a wire-format concern, not a scheduler one);
//!   * the negotiation never mis-parses (assorted leading-byte
//!     sequences classify correctly; a non-magic over-`max_frame_size`
//!     length is an over-length `ParseError`, never a hint preamble);
//!   * v1 and v2 connections under concurrent mixed load all get the
//!     correct verdict.
//!
//! The fairness SIGNAL itself lives in `tests/fair_queue.rs` (queue
//! level), because the one-shot-per-connection server makes every TCP
//! connection a single-request flow (`GP.8` §2.5).  Here we prove only
//! that the wire format de-frames correctly for both client generations.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use knomosis_host::config::Scheduler;
use knomosis_host::frame::{
    encode_frame, encode_hinted_frame, HARD_MAX_FRAME_SIZE, KNH2_MAGIC, KNH2_PREAMBLE,
};
use knomosis_host::kernel::mock::MockKernel;
use knomosis_host::kernel::Kernel;
use knomosis_host::listener::tcp::TcpListener;
use knomosis_host::server::{Server, ServerConfigBuilder};
use knomosis_host::verdict::Verdict;

/// Spawn a host on a random TCP port with the given scheduler.
fn spawn_server(scheduler: Scheduler) -> (SocketAddr, Arc<AtomicBool>, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = listener.local_addr().unwrap();
    let cfg = ServerConfigBuilder::new()
        .scheduler(scheduler)
        .max_queue_depth(64)
        .tcp(listener)
        .build(Box::new(MockKernel::new()) as Box<dyn Kernel>)
        .unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let server_stop = Arc::clone(&stop);
    let handle = thread::spawn(move || Server::new(cfg).run(server_stop));
    thread::sleep(Duration::from_millis(100));
    (addr, stop, handle)
}

/// Stop a server and join it within a deadline (fails loudly on a hang).
fn join_server(stop: &Arc<AtomicBool>, handle: JoinHandle<()>) {
    stop.store(true, Ordering::Relaxed);
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if handle.is_finished() {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    assert!(handle.is_finished(), "server failed to shut down (hang)");
    handle.join().expect("server join");
}

/// Connect, write `bytes` (a complete request), half-close, and return
/// the leading verdict byte (or `None` on a short read / transport
/// failure).
fn submit_raw(addr: SocketAddr, bytes: &[u8]) -> Option<u8> {
    let mut stream = TcpStream::connect(addr).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .ok()?;
    stream.write_all(bytes).ok()?;
    stream.flush().ok()?;
    let _ = stream.shutdown(std::net::Shutdown::Write);
    let mut response = Vec::new();
    let _ = stream.read_to_end(&mut response);
    if response.len() >= 5 {
        Some(response[0])
    } else {
        None
    }
}

/// Submit a legacy (v1) frame: `[4-byte len][payload]`.
fn submit_v1(addr: SocketAddr, payload: &[u8]) -> Option<u8> {
    submit_raw(addr, &encode_frame(payload).unwrap())
}

/// Submit a Rung-1 (v2) request: the `KNH2` preamble once, then one
/// `[8-byte hint][4-byte len][payload]` hinted frame.
fn submit_v2(addr: SocketAddr, signer: u64, payload: &[u8]) -> Option<u8> {
    let mut bytes = KNH2_PREAMBLE.to_vec();
    bytes.extend_from_slice(&encode_hinted_frame(signer, payload).unwrap());
    submit_raw(addr, &bytes)
}

// ===== FQ.14b — back-compat on BOTH schedulers ======================

/// A legacy v1 client and a v2 client BOTH get `Ok` against one host —
/// on the FIFO scheduler (the default) AND the DRR scheduler.  The
/// negotiation strips the v2 preamble + hint and submits the same opaque
/// payload regardless of scheduler, so v2 clients interoperate with a
/// FIFO host (gaining no fairness, but working — §2.6(3)).
#[test]
fn v1_and_v2_both_work_on_fifo_and_drr() {
    for scheduler in [Scheduler::Fifo, Scheduler::Drr] {
        let (addr, stop, handle) = spawn_server(scheduler);
        assert_eq!(
            submit_v1(addr, b"legacy-body"),
            Some(Verdict::Ok.to_byte()),
            "v1 client failed on {scheduler:?}"
        );
        assert_eq!(
            submit_v2(addr, 0x0102_0304_0506_0708, b"hinted-body"),
            Some(Verdict::Ok.to_byte()),
            "v2 client failed on {scheduler:?}"
        );
        join_server(&stop, handle);
    }
}

/// A v2 client may hint ANY `u64` (including the legacy sentinel `0` and
/// `u64::MAX`); the hint is advisory routing only and never affects the
/// verdict.
#[test]
fn v2_arbitrary_hints_all_admit() {
    let (addr, stop, handle) = spawn_server(Scheduler::Drr);
    for hint in [0u64, 1, 2, u64::from(u32::MAX), u64::MAX] {
        assert_eq!(
            submit_v2(addr, hint, b"x"),
            Some(Verdict::Ok.to_byte()),
            "hint {hint} did not admit"
        );
    }
    join_server(&stop, handle);
}

// ===== FQ.14b — negotiation robustness ==============================

/// THE FQ.9 invariant, pinned: the hard frame-size ceiling is strictly
/// below the magic, so a valid v1 length can never collide with the
/// preamble.
#[test]
fn hard_max_frame_size_below_magic_invariant() {
    assert!(
        (HARD_MAX_FRAME_SIZE as u64) < u64::from(KNH2_MAGIC),
        "HARD_MAX_FRAME_SIZE {HARD_MAX_FRAME_SIZE} must be < KNH2_MAGIC {KNH2_MAGIC}"
    );
}

/// A NON-magic leading u32 that exceeds `max_frame_size` is rejected as
/// an over-length frame (`ParseError`), exactly as in v1 — it is NEVER
/// mistaken for the v2 preamble.  We send `0x1000_0000` (256 MiB):
/// distinct from the magic, far above the host's frame cap.
#[test]
fn oversize_non_magic_length_is_parse_error_not_preamble() {
    let (addr, stop, handle) = spawn_server(Scheduler::Drr);
    let over: u32 = 0x1000_0000; // 256 MiB — not the magic, over the cap.
    assert_ne!(over.to_be_bytes(), KNH2_PREAMBLE);
    assert!(u64::from(over) < u64::from(KNH2_MAGIC));
    // Send just the 4-byte length (no body); the host classifies it as a
    // legacy length prefix and rejects it as oversize.
    let verdict = submit_raw(addr, &over.to_be_bytes());
    assert_eq!(
        verdict,
        Some(Verdict::ParseError.to_byte()),
        "oversize non-magic length must be a ParseError, not a preamble"
    );
    join_server(&stop, handle);
}

/// Assorted leading-byte sequences classify correctly: a normal v1
/// length prefix is read as a v1 frame; only the exact preamble bytes
/// trigger the v2 path.
#[test]
fn assorted_leading_bytes_classify_correctly() {
    let (addr, stop, handle) = spawn_server(Scheduler::Drr);
    // A small v1 frame: classified legacy, admitted.
    assert_eq!(submit_v1(addr, b"a"), Some(Verdict::Ok.to_byte()));
    // The exact preamble + a hinted frame: classified v2, admitted.
    assert_eq!(submit_v2(addr, 5, b"a"), Some(Verdict::Ok.to_byte()));
    // A 4-byte prefix that is ALMOST the magic (last byte differs) is
    // classified legacy; with no body it is a truncated-payload
    // ParseError.
    let mut almost = KNH2_PREAMBLE;
    almost[3] = almost[3].wrapping_add(1);
    assert_ne!(almost, KNH2_PREAMBLE);
    assert_eq!(
        submit_raw(addr, &almost),
        Some(Verdict::ParseError.to_byte()),
        "an almost-magic prefix must be treated as a (here invalid) v1 length"
    );
    join_server(&stop, handle);
}

/// A v2 connection that sends the preamble then a TRUNCATED hint
/// (fewer than 8 bytes) then closes is a `ParseError` — the host never
/// reads into a non-existent body.
#[test]
fn v2_truncated_hint_is_parse_error() {
    let (addr, stop, handle) = spawn_server(Scheduler::Drr);
    let mut bytes = KNH2_PREAMBLE.to_vec();
    bytes.extend_from_slice(&[0u8; 3]); // 3 of 8 hint bytes, then close.
    assert_eq!(
        submit_raw(addr, &bytes),
        Some(Verdict::ParseError.to_byte())
    );
    join_server(&stop, handle);
}

/// A v2 connection that sends the preamble + a COMPLETE 8-byte hint then
/// closes before the length header is a committed-but-truncated request:
/// the host answers `ParseError` (a written response), NOT a silent
/// clean-close.  Sending the hint commits the client to a request, so an
/// EOF now is a protocol violation, not a benign disconnect.  (Without
/// the post-hint EOF re-map this would yield no response at all.)
#[test]
fn v2_full_hint_then_close_is_parse_error() {
    let (addr, stop, handle) = spawn_server(Scheduler::Drr);
    let mut bytes = KNH2_PREAMBLE.to_vec();
    bytes.extend_from_slice(&42u64.to_be_bytes()); // full hint, no length header.
    assert_eq!(
        submit_raw(addr, &bytes),
        Some(Verdict::ParseError.to_byte()),
        "a committed-but-truncated v2 request must get a ParseError, not a silent close"
    );
    join_server(&stop, handle);
}

// ===== FQ.14b — mixed concurrent load ===============================

/// v1 and v2 connections concurrently against one DRR host: every
/// connection that gets a verdict gets the correct one (`Ok`), proving
/// the negotiation is per-connection and thread-safe.
#[test]
fn mixed_v1_v2_concurrent_load() {
    let (addr, stop, handle) = spawn_server(Scheduler::Drr);
    let oks = Arc::new(Mutex::new(0usize));
    let mut clients = Vec::new();
    for i in 0..32u64 {
        let oks = Arc::clone(&oks);
        clients.push(thread::spawn(move || {
            // Even clients speak v1, odd clients speak v2.
            let verdict = if i % 2 == 0 {
                submit_v1(addr, format!("v1-{i}").as_bytes())
            } else {
                submit_v2(addr, i, format!("v2-{i}").as_bytes())
            };
            if let Some(v) = verdict {
                // Only Ok or Busy are legitimate under load.
                assert!(
                    v == Verdict::Ok.to_byte() || v == Verdict::Busy.to_byte(),
                    "unexpected verdict {v} from client {i}"
                );
                if v == Verdict::Ok.to_byte() {
                    *oks.lock().unwrap() += 1;
                }
            }
        }));
    }
    for c in clients {
        c.join().expect("client join");
    }
    assert!(
        *oks.lock().unwrap() > 0,
        "no client succeeded under mixed load"
    );
    join_server(&stop, handle);
}

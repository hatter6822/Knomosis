// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! FQ.13a — end-to-end + byte-equivalence tests for the raw-TCP
//! `knomosis-host` submitter in `knomosis-l1-ingest`.
//!
//! Two guarantees, both depending on `knomosis-host` as a DEV-only
//! dependency:
//!
//!   * **Single source of truth.**  The submitter's hand-rolled wire
//!     framing is byte-for-byte identical to the canonical
//!     `knomosis_host::frame` encoders (`encode_frame` /
//!     `encode_hinted_frame` / `KNH2_PREAMBLE`) — so a layout drift
//!     fails the build rather than only being caught at integration.
//!   * **It actually talks to a real host.**  A live in-process
//!     `knomosis-host` (MockKernel, DRR scheduler) admits both legacy
//!     (v1) and hinted (v2) submissions from the `RawTcpSubmitter`,
//!     proving the framing is wire-compatible with the host's
//!     `read_request` negotiation end-to-end.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use knomosis_host::config::Scheduler;
use knomosis_host::frame::{encode_frame, encode_hinted_frame, KNH2_PREAMBLE};
use knomosis_host::kernel::mock::MockKernel;
use knomosis_host::kernel::Kernel;
use knomosis_host::listener::tcp::TcpListener;
use knomosis_host::server::{Server, ServerConfigBuilder};

use knomosis_l1_ingest::action::{Action, PublicKey};
use knomosis_l1_ingest::submitter::raw_tcp::RawTcpSubmitter;
use knomosis_l1_ingest::submitter::{SignedActionForSubmit, Submitter, Verdict};
use knomosis_l1_ingest::translation::UnsignedAction;

/// A fully-signed action whose `SignedAction.signer` is `signer` (the
/// value the Rung-1 hint mirrors).
fn signed_action(signer: u64) -> SignedActionForSubmit {
    SignedActionForSubmit {
        unsigned: UnsignedAction {
            action: Action::RegisterIdentity {
                actor: 1,
                pk: PublicKey::from_bytes(&[0xab, 0xcd]),
            },
            signer,
            nonce: 0,
        },
        signature: [0x22; 64],
    }
}

/// The hand-rolled framing is byte-for-byte the canonical
/// `knomosis_host::frame` encoders — the single-source-of-truth pin.
#[test]
fn frames_match_canonical_encoders() {
    let signer = 0xA1B2_C3D4_E5F6_0718u64;
    let action = signed_action(signer);
    let body = action.encode().unwrap();

    // Legacy frame == encode_frame(body).
    let legacy = RawTcpSubmitter::new("127.0.0.1:1")
        .unwrap()
        .build_request(&action)
        .unwrap();
    assert_eq!(
        legacy,
        encode_frame(&body).unwrap(),
        "legacy framing drifted from knomosis_host::frame::encode_frame"
    );

    // Hinted frame == KNH2 preamble ++ encode_hinted_frame(signer, body).
    let hinted = RawTcpSubmitter::new("127.0.0.1:1")
        .unwrap()
        .with_emit_hints(true)
        .build_request(&action)
        .unwrap();
    let mut expected = KNH2_PREAMBLE.to_vec();
    expected.extend_from_slice(&encode_hinted_frame(signer, &body).unwrap());
    assert_eq!(
        hinted, expected,
        "hinted framing drifted from knomosis_host::frame::encode_hinted_frame"
    );
}

/// Spawn an in-process `knomosis-host` (MockKernel, DRR scheduler) on a
/// random TCP port.
fn spawn_host() -> (SocketAddr, Arc<AtomicBool>, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = listener.local_addr().unwrap();
    let cfg = ServerConfigBuilder::new()
        .scheduler(Scheduler::Drr)
        .tcp(listener)
        .build(Box::new(MockKernel::new()) as Box<dyn Kernel>)
        .unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let server_stop = Arc::clone(&stop);
    let handle = thread::spawn(move || Server::new(cfg).run(server_stop));
    thread::sleep(Duration::from_millis(100));
    (addr, stop, handle)
}

/// Stop a host and join it within a deadline (fails loudly on a hang).
fn join_host(stop: &Arc<AtomicBool>, handle: JoinHandle<()>) {
    stop.store(true, Ordering::Relaxed);
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if handle.is_finished() {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    assert!(handle.is_finished(), "host failed to shut down (hang)");
    handle.join().expect("host join");
}

/// A legacy (default, no hints) submission is admitted by a real host.
#[test]
fn raw_tcp_legacy_submits_ok_to_real_host() {
    let (addr, stop, handle) = spawn_host();
    let submitter = RawTcpSubmitter::new(addr.to_string()).unwrap();
    assert!(!submitter.emits_hints());
    let verdict = submitter
        .submit(&signed_action(0))
        .expect("submit succeeds");
    assert_eq!(verdict, Verdict::Ok);
    join_host(&stop, handle);
}

/// A hinted (v2) submission is de-framed by the host's negotiation and
/// admitted — across several distinct signer hints (the hint is advisory;
/// the MockKernel admits every well-formed frame).
#[test]
fn raw_tcp_hinted_submits_ok_to_real_host() {
    let (addr, stop, handle) = spawn_host();
    let submitter = RawTcpSubmitter::new(addr.to_string())
        .unwrap()
        .with_emit_hints(true);
    assert!(submitter.emits_hints());
    for signer in [0u64, 1, 7, u64::MAX] {
        let verdict = submitter
            .submit(&signed_action(signer))
            .unwrap_or_else(|e| panic!("hinted submit for signer {signer} failed: {e}"));
        assert_eq!(verdict, Verdict::Ok, "signer {signer} not admitted");
    }
    join_host(&stop, handle);
}

/// Legacy and hinted submitters against the SAME host both succeed —
/// the host's per-connection negotiation classifies each independently
/// (v1/v2 interop, mirroring the host's own `wire_compat` suite, now
/// driven by a real l1-ingest client).
#[test]
fn raw_tcp_v1_and_v2_interop_against_one_host() {
    let (addr, stop, handle) = spawn_host();
    let v1 = RawTcpSubmitter::new(addr.to_string()).unwrap();
    let v2 = RawTcpSubmitter::new(addr.to_string())
        .unwrap()
        .with_emit_hints(true);
    assert_eq!(v1.submit(&signed_action(3)).unwrap(), Verdict::Ok);
    assert_eq!(v2.submit(&signed_action(3)).unwrap(), Verdict::Ok);
    assert_eq!(v1.submit(&signed_action(4)).unwrap(), Verdict::Ok);
    join_host(&stop, handle);
}

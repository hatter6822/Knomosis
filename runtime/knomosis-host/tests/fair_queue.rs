// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Behavioural, stress, parity, and throughput tests for the optional
//! DRR fair scheduler (Workstream GP.8, Track A / FQ — Rung 0).
//!
//! Two granularities:
//!
//!   * **Queue-level (FQ.7a)** — drive a [`FairQueue`] directly,
//!     dispatching each served request through a `MockKernel`, and
//!     assert on the *served order*.  This is deterministic (no TCP, no
//!     thread-scheduling nondeterminism), so the fairness, targeted-
//!     backpressure, work-conserving, and no-starvation properties are
//!     pinned exactly.  It is the right place for the fairness signal:
//!     the host is one-shot-per-connection, so a multi-request flow only
//!     arises when one connection submits repeatedly — exactly what the
//!     queue API lets us construct.
//!   * **End-to-end (FQ.4b / FQ.7b)** — spin up the full server on the
//!     `Drr` path and exercise it over real TCP: request/response works,
//!     stress holds, shutdown-under-load drains cleanly, and the verdict
//!     stream matches FIFO (Track A only reorders — §2.6 invariant 1).
//!
//! FQ.7c (throughput parity) is a microbench with a loose,
//! machine-independent bound; it prints the observed ratio for the
//! closeout note rather than gating CI on a tight number.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use knomosis_host::config::Scheduler;
use knomosis_host::fair::drr::Caps;
use knomosis_host::frame::encode_frame;
use knomosis_host::kernel::mock::MockKernel;
use knomosis_host::kernel::{Kernel, KernelResponse};
use knomosis_host::listener::tcp::TcpListener;
use knomosis_host::queue::{drain_one, BoundedQueue, FairQueue, SubmitOutcome};
use knomosis_host::server::{Server, ServerConfigBuilder};
use knomosis_host::verdict::Verdict;

// ===== queue-level helpers ==========================================

/// Build a fair queue with explicit caps.
fn fair(per_flow: usize, max_flows: usize, global: usize) -> FairQueue {
    FairQueue::new(Caps::new(per_flow, max_flows, global))
}

/// Drain `q` fully via `try_next`, dispatching every request to
/// `kernel` (and replying), returning the served payloads in order.
fn drain_all_through(q: &FairQueue, kernel: &dyn Kernel) -> Vec<Vec<u8>> {
    let mut order = Vec::new();
    while let Some(req) = q.try_next() {
        let resp = kernel.submit(&req.payload);
        let _ = req.reply.try_send(resp);
        order.push(req.payload);
    }
    order
}

// ===== FQ.7a — behavioural fairness (queue-level, MockKernel) =======

/// Fairness under contention: a whale's backlog on one connection does
/// not bury a small connection's request.  The small request is served
/// within `O(active_flows)` dispatches — under FIFO it would wait
/// behind the whole backlog.
#[test]
fn fairness_whale_does_not_bury_small() {
    let q = fair(64, 64, 256);
    let kernel = MockKernel::new();
    // Whale = conn 1 (payload 1), 10 deep.  Small = conn 2 (payload 2).
    for _ in 0..10 {
        assert!(matches!(
            q.try_submit(1, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));
    }
    assert!(matches!(
        q.try_submit(2, vec![2]),
        SubmitOutcome::Enqueued(_)
    ));

    let order = drain_all_through(&q, &kernel);
    let small_pos = order
        .iter()
        .position(|p| p == &vec![2])
        .expect("small served");
    // Served within active_flows (= 2) dispatches, NOT 11th (FIFO).
    assert!(
        small_pos <= 1,
        "small served at position {small_pos}, expected ≤ 1"
    );
    // The kernel saw the same order the queue dispatched.
    assert_eq!(kernel.recorded(), order);
    // Exactly the 11 requests were served.
    assert_eq!(order.len(), 11);
}

/// Targeted backpressure: a whale saturating its per-flow cap gets
/// `Busy` on the overflow, while the small connection still enqueues
/// and is served.
#[test]
fn targeted_backpressure_whale_busy_small_ok() {
    let q = fair(2, 64, 256); // per_flow = 2
    let kernel = MockKernel::new();
    let mut whale_busy = 0;
    for _ in 0..5 {
        if matches!(q.try_submit(1, vec![1]), SubmitOutcome::Busy) {
            whale_busy += 1;
        }
    }
    assert_eq!(whale_busy, 3, "whale over-submission must be Busy past cap");
    assert!(matches!(
        q.try_submit(2, vec![2]),
        SubmitOutcome::Enqueued(_)
    ));

    let order = drain_all_through(&q, &kernel);
    assert!(order.contains(&vec![2]), "small connection was served");
    assert_eq!(order.iter().filter(|p| p == &&vec![1]).count(), 2);
}

/// Work-conserving: with only one connection active (no contention), it
/// is served at the full worker rate — every `try_next` yields work
/// until the flow drains, with no artificial throttle / idle gap.
#[test]
fn work_conserving_single_flow_full_rate() {
    let q = fair(64, 64, 256);
    let kernel = MockKernel::new();
    for i in 0..20u8 {
        assert!(matches!(
            q.try_submit(1, vec![i]),
            SubmitOutcome::Enqueued(_)
        ));
    }
    let mut served = 0;
    // Every pull returns work until drained — no Idle in between.
    while q.try_next().is_some() {
        served += 1;
    }
    assert_eq!(served, 20);
    let _ = kernel; // dispatch is exercised by the other tests
}

/// No-starvation bound: with K active connections, every connection's
/// head is served within the first K dispatches.
#[test]
fn no_starvation_each_head_within_k() {
    let k = 6u64;
    let q = fair(64, 64, 256);
    let kernel = MockKernel::new();
    for c in 0..k {
        // Two requests each so no flow drains within the first K.
        let _ = q.try_submit(c, vec![c as u8]);
        let _ = q.try_submit(c, vec![c as u8]);
    }
    let order = drain_all_through(&q, &kernel);
    let first_k: std::collections::BTreeSet<u8> =
        order[..k as usize].iter().map(|p| p[0]).collect();
    assert_eq!(
        first_k.len() as u64,
        k,
        "each of the K connections served once within the first K dispatches"
    );
}

// ===== end-to-end server helpers ====================================

/// A MockKernel that sleeps before responding, to build a backlog and
/// to exercise shutdown-under-load deterministically.
struct SlowMockKernel {
    delay: Duration,
}

impl SlowMockKernel {
    fn new(delay: Duration) -> Self {
        Self { delay }
    }
}

impl Kernel for SlowMockKernel {
    fn submit(&self, _bytes: &[u8]) -> KernelResponse {
        thread::sleep(self.delay);
        KernelResponse::from_verdict(Verdict::Ok)
    }
    fn identifier(&self) -> &str {
        "slow-mock/v1"
    }
}

/// Spawn a server with a given scheduler + TCP listener.
fn spawn_server(
    kernel: Box<dyn Kernel>,
    scheduler: Scheduler,
    queue_depth: usize,
) -> (SocketAddr, Arc<AtomicBool>, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = listener.local_addr().unwrap();
    let cfg = ServerConfigBuilder::new()
        .scheduler(scheduler)
        .max_queue_depth(queue_depth)
        .tcp(listener)
        .build(kernel)
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

/// Submit one frame over TCP and return the verdict byte (or None on a
/// transport failure / short read).
fn submit_verdict(addr: SocketAddr, payload: &[u8]) -> Option<u8> {
    let mut stream = TcpStream::connect(addr).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .ok()?;
    let frame = encode_frame(payload).ok()?;
    stream.write_all(&frame).ok()?;
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

// ===== FQ.4b — end-to-end DRR path ==================================

/// End-to-end on the `Drr` path: connect, submit, receive a verdict
/// (parity with FIFO for a single actor).
#[test]
fn drr_end_to_end_request_response() {
    let (addr, stop, handle) = spawn_server(Box::new(MockKernel::new()), Scheduler::Drr, 16);
    let verdict = submit_verdict(addr, b"hello").expect("verdict");
    assert_eq!(verdict, Verdict::Ok.to_byte());
    join_server(&stop, handle);
}

// ===== FQ.7b — parity, stress, shutdown-under-load ==================

/// Verdict parity: the same sequential workload returns identical
/// verdicts on `--scheduler fifo` and `--scheduler drr` (Track A only
/// reorders, never changes admissibility — §2.6 invariant 1).
#[test]
fn fifo_drr_verdict_parity_sequential() {
    let n = 8;
    // A response cycle the kernel walks by dispatch order.
    let cycle = || {
        vec![
            KernelResponse::from_verdict(Verdict::Ok),
            KernelResponse::with_reason(Verdict::NotAdmissible, "no"),
        ]
    };

    let collect = |scheduler: Scheduler| -> Vec<u8> {
        let kernel = MockKernel::new();
        kernel.set_responses(cycle());
        let (addr, stop, handle) = spawn_server(Box::new(kernel), scheduler, 16);
        // Sequential submission (one connection at a time): no Busy, and
        // both schedulers dispatch in arrival order.
        let verdicts: Vec<u8> = (0..n)
            .map(|i| submit_verdict(addr, &[i]).expect("verdict"))
            .collect();
        join_server(&stop, handle);
        verdicts
    };

    let fifo = collect(Scheduler::Fifo);
    let drr = collect(Scheduler::Drr);
    assert_eq!(fifo, drr, "DRR changed the verdict stream vs FIFO");
    // Sanity: the cycle actually produced a mix.
    assert!(fifo.contains(&Verdict::Ok.to_byte()));
    assert!(fifo.contains(&Verdict::NotAdmissible.to_byte()));
}

/// Stress: many concurrent one-shot connections on the `Drr` path.  No
/// hang / OOM; every connection that gets a verdict gets a valid one,
/// and at least some succeed.
#[test]
fn drr_stress_many_connections() {
    let (addr, stop, handle) = spawn_server(Box::new(MockKernel::new()), Scheduler::Drr, 64);
    let ok = Arc::new(Mutex::new(0usize));
    let mut threads = Vec::new();
    for i in 0..64u8 {
        let ok = Arc::clone(&ok);
        threads.push(thread::spawn(move || {
            if let Some(v) = submit_verdict(addr, &[i]) {
                // Only Ok or Busy are legitimate here.
                assert!(
                    v == Verdict::Ok.to_byte() || v == Verdict::Busy.to_byte(),
                    "unexpected verdict {v}"
                );
                if v == Verdict::Ok.to_byte() {
                    *ok.lock().unwrap() += 1;
                }
            }
        }));
    }
    for t in threads {
        t.join().expect("client join");
    }
    assert!(
        *ok.lock().unwrap() > 0,
        "no connection succeeded under stress"
    );
    join_server(&stop, handle);
}

/// Shutdown under load: flip `stop` while a slow-kernel DRR server has
/// requests in flight; the server must drain and join cleanly (no
/// Condvar hang, no lost worker).
#[test]
fn drr_shutdown_under_load() {
    let kernel = Box::new(SlowMockKernel::new(Duration::from_millis(20)));
    let (addr, stop, handle) = spawn_server(kernel, Scheduler::Drr, 64);

    // Fire a burst of concurrent clients (don't wait for replies).
    let mut clients = Vec::new();
    for i in 0..32u8 {
        clients.push(thread::spawn(move || {
            let _ = submit_verdict(addr, &[i]);
        }));
    }
    // Let some land in the queue, then stop mid-flight.
    thread::sleep(Duration::from_millis(50));
    // join_server asserts a clean, bounded shutdown.
    join_server(&stop, handle);
    for c in clients {
        let _ = c.join();
    }
}

// ===== FQ.7c — throughput parity (microbench, loose bound) ==========

/// Single-actor throughput: FIFO (`BoundedQueue` + `drain_one`) vs DRR
/// (`FairQueue` + `try_next`).  With no contention the only DRR overhead
/// is the `Mutex`/`Condvar` vs the `sync_channel`.  This asserts a
/// LOOSE, machine-independent bound (catches a catastrophic
/// lock-serialization regression — the §2.8 risk FQ.7c exists to guard)
/// and prints the observed ratio for the closeout note, rather than
/// gating CI on a tight number.
#[test]
fn throughput_parity_single_actor() {
    let iters = 20_000u32;

    // FIFO: submit + drain one, repeatedly.
    let (fifo, rx) = BoundedQueue::new(4);
    let fifo_start = Instant::now();
    for _ in 0..iters {
        if let SubmitOutcome::Enqueued(_) = fifo.try_submit(vec![0u8]) {
            let _ = drain_one(&rx, Duration::from_millis(0), |_| {
                KernelResponse::from_verdict(Verdict::Ok)
            });
        }
    }
    let fifo_elapsed = fifo_start.elapsed();

    // DRR: submit + try_next, repeatedly, single connection (conn 0).
    let drr = fair(64, 64, 256);
    let drr_start = Instant::now();
    for _ in 0..iters {
        if let SubmitOutcome::Enqueued(_) = drr.try_submit(0, vec![0u8]) {
            if let Some(req) = drr.try_next() {
                let _ = req
                    .reply
                    .try_send(KernelResponse::from_verdict(Verdict::Ok));
            }
        }
    }
    let drr_elapsed = drr_start.elapsed();

    let ratio = drr_elapsed.as_secs_f64() / fifo_elapsed.as_secs_f64().max(1e-9);
    eprintln!("FQ.7c throughput: fifo={fifo_elapsed:?} drr={drr_elapsed:?} (drr/fifo={ratio:.2}x)");
    // Loose bound: a healthy DRR is comparable; a 5× blowup would mean
    // the global Mutex is serializing the hot path (the regression this
    // guard exists to catch).  Machine-independent.
    assert!(
        drr_elapsed < fifo_elapsed * 5 + Duration::from_millis(50),
        "DRR single-actor throughput regressed catastrophically: {ratio:.2}x"
    );
}

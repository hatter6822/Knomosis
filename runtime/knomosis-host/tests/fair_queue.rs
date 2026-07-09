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

use std::collections::BTreeMap;
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
use knomosis_host::queue::{
    drain_one, BoundedQueue, FairQueue, NextOutcome, SubmitOutcome, LEGACY_SIGNER_HINT,
};
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
            q.try_submit(1, LEGACY_SIGNER_HINT, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));
    }
    assert!(matches!(
        q.try_submit(2, LEGACY_SIGNER_HINT, vec![2]),
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
        if matches!(
            q.try_submit(1, LEGACY_SIGNER_HINT, vec![1]),
            SubmitOutcome::Busy
        ) {
            whale_busy += 1;
        }
    }
    assert_eq!(whale_busy, 3, "whale over-submission must be Busy past cap");
    assert!(matches!(
        q.try_submit(2, LEGACY_SIGNER_HINT, vec![2]),
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
            q.try_submit(1, LEGACY_SIGNER_HINT, vec![i]),
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
        let _ = q.try_submit(c, LEGACY_SIGNER_HINT, vec![c as u8]);
        let _ = q.try_submit(c, LEGACY_SIGNER_HINT, vec![c as u8]);
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
    fn identifier(&self) -> &'static str {
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

/// Submit one frame over TCP and return `(verdict_byte, reason)`.
fn submit_verdict_reason(addr: SocketAddr, payload: &[u8]) -> Option<(u8, String)> {
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
    if response.len() < 5 {
        return None;
    }
    let reason_len =
        u32::from_be_bytes([response[1], response[2], response[3], response[4]]) as usize;
    let reason =
        String::from_utf8_lossy(&response[5..(5 + reason_len).min(response.len())]).into_owned();
    Some((response[0], reason))
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

// ===== FQ.7c — throughput parity =====================================

/// Queue-op overhead IN ISOLATION: FIFO (`BoundedQueue` + `drain_one`)
/// vs DRR (`FairQueue` + `try_next`) with a no-op kernel.  This
/// deliberately measures only the per-op queue machinery (the `Mutex` +
/// `Condvar` + `BTreeMap` DRR carries vs the `sync_channel`), so the DRR
/// figure is its WORST case — there is no dispatch work to amortise it
/// against.  It is NOT end-to-end throughput (see
/// `throughput_parity_end_to_end_single_actor` for that, where the
/// per-request cost is dispatch/connection-dominated and the two paths
/// are on par).  The bound here is loose + machine-independent: it
/// exists only to catch the catastrophic lock-serialization regression
/// (the §2.8 risk), and the observed ratio is printed for the closeout.
#[test]
fn throughput_queue_op_overhead_isolated() {
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
        if let SubmitOutcome::Enqueued(_) = drr.try_submit(0, LEGACY_SIGNER_HINT, vec![0u8]) {
            if let Some(req) = drr.try_next() {
                let _ = req
                    .reply
                    .try_send(KernelResponse::from_verdict(Verdict::Ok));
            }
        }
    }
    let drr_elapsed = drr_start.elapsed();

    let ratio = drr_elapsed.as_secs_f64() / fifo_elapsed.as_secs_f64().max(1e-9);
    eprintln!(
        "FQ.7c queue-op overhead (isolated, no-op kernel): fifo={fifo_elapsed:?} \
         drr={drr_elapsed:?} (drr/fifo={ratio:.2}x)"
    );
    // Loose bound: a 5× blowup would mean the global Mutex is serializing
    // the hot path (the regression this guard exists to catch).
    assert!(
        drr_elapsed < fifo_elapsed * 5 + Duration::from_millis(50),
        "DRR queue-op overhead regressed catastrophically: {ratio:.2}x"
    );
}

/// FQ.7c (Rung 1) — TWO-TIER queue-op overhead in ISOLATION: the DRR path
/// routing across many `(conn, signer)` pairs (exercising BOTH the outer
/// `ConnId` tier and the inner `SignerHint` tier `BTreeMap`s per op) vs
/// the FIFO `sync_channel`, no-op kernel.  This is the Rung-1 counterpart
/// of `throughput_queue_op_overhead_isolated`: it measures the cost the
/// SECOND tier adds — each op now does two map `entry`/insert + two
/// pop/evict steps instead of one.  The ratio is printed for the closeout
/// note; the bound is loose + machine-independent (it exists only to
/// catch a catastrophic two-tier regression, not to gate CI on a number).
#[test]
fn throughput_two_tier_queue_op_overhead() {
    let iters = 20_000u32;

    // FIFO baseline: submit + drain one, repeatedly.
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

    // DRR two-tier: rotate across 16 connections × 8 signer hints, so
    // every op routes through BOTH tiers (outer conn map + inner signer
    // map).
    let drr = fair_with_signers(64, 1024, 256, 4096);
    let drr_start = Instant::now();
    for i in 0..iters {
        let conn = u64::from(i % 16);
        let signer = u64::from((i / 16) % 8);
        if let SubmitOutcome::Enqueued(_) = drr.try_submit(conn, signer, vec![0u8]) {
            if let Some(req) = drr.try_next() {
                let _ = req
                    .reply
                    .try_send(KernelResponse::from_verdict(Verdict::Ok));
            }
        }
    }
    let drr_elapsed = drr_start.elapsed();

    let ratio = drr_elapsed.as_secs_f64() / fifo_elapsed.as_secs_f64().max(1e-9);
    eprintln!(
        "FQ.7c two-tier queue-op overhead (isolated, no-op kernel, 16 conns × 8 signers): \
         fifo={fifo_elapsed:?} drr={drr_elapsed:?} (drr/fifo={ratio:.2}x)"
    );
    // Loose, machine-independent guard: the inner tier must not blow up
    // the per-op cost.  Two nested BTreeMaps (each tiny, ≤ 16 / ≤ 8
    // entries) are a small constant over the single-tier path; an 8×
    // blowup would signal a real regression.
    assert!(
        drr_elapsed < fifo_elapsed * 8 + Duration::from_millis(100),
        "two-tier queue-op overhead regressed catastrophically: {ratio:.2}x"
    );
}

/// END-TO-END single-actor throughput through the full server: FIFO vs
/// DRR, one client submitting `n` sequential requests over TCP.  This is
/// the "single-actor throughput" FQ.7c targets.  The per-request cost is
/// dominated by the connection + the listener's 50 ms accept-poll +
/// dispatch (identical on both paths); the scheduler difference is a
/// tiny fraction, so DRR is on par with FIFO — comfortably within the
/// plan's ≥90% intent.
///
/// `#[ignore]`d: FQ.7c is explicitly "not a hard CI gate (numbers are
/// machine-dependent)", and the sequential one-shot pattern is slow
/// (the 50 ms accept-poll dominates each request).  Run manually with
/// `cargo test -p knomosis-host --test fair_queue -- --ignored
/// --nocapture`; the observed ratio is recorded in the FQ closeout
/// snapshot.  The fast, always-on `throughput_queue_op_overhead_isolated`
/// guards the catastrophic-regression case in CI.
#[ignore = "manual benchmark; FQ.7c is not a CI gate (machine-dependent + slow)"]
#[test]
fn throughput_parity_end_to_end_single_actor() {
    let n = 200u32;
    let measure = |scheduler: Scheduler| -> Duration {
        let (addr, stop, handle) = spawn_server(Box::new(MockKernel::new()), scheduler, 64);
        // Warm up (JIT-free, but primes the listener / OS connection path).
        for _ in 0..20 {
            let _ = submit_verdict(addr, b"warm");
        }
        let start = Instant::now();
        for _ in 0..n {
            assert_eq!(
                submit_verdict(addr, b"x").expect("verdict"),
                Verdict::Ok.to_byte()
            );
        }
        let elapsed = start.elapsed();
        join_server(&stop, handle);
        elapsed
    };
    let fifo = measure(Scheduler::Fifo);
    let drr = measure(Scheduler::Drr);
    let fifo_ops = f64::from(n) / fifo.as_secs_f64();
    let drr_ops = f64::from(n) / drr.as_secs_f64();
    let throughput_ratio = drr_ops / fifo_ops;
    eprintln!(
        "FQ.7c end-to-end single-actor: fifo={fifo_ops:.0} ops/s, drr={drr_ops:.0} ops/s \
         (drr/fifo throughput={throughput_ratio:.2})"
    );
    // End-to-end throughput is connection/dispatch-dominated and equal on
    // both paths, so DRR is on par with FIFO.  Loose, machine-independent
    // guard against a catastrophic regression (not a tight 90% CI gate).
    assert!(
        drr < fifo * 2,
        "DRR end-to-end single-actor throughput regressed: drr/fifo time {:.2}",
        drr.as_secs_f64() / fifo.as_secs_f64().max(1e-9)
    );
}

// ===== FQ.7b — DRR reorders but preserves the verdict multiset =======

/// DRR genuinely reorders dispatch relative to FIFO, yet the *multiset*
/// of admissibility verdicts is identical — Track A only reorders, it
/// never changes which outcomes the kernel produces (§2.6 invariant 1).
///
/// This is the reordering-exercising counterpart to the sequential
/// end-to-end parity test: at the queue level we can give one connection
/// MULTIPLE queued requests (impossible through the one-shot server), so
/// DRR's round-robin actually diverges from FIFO's contiguous order.
#[test]
fn drr_reorders_but_preserves_verdict_multiset() {
    let response_cycle = || {
        vec![
            KernelResponse::from_verdict(Verdict::Ok),
            KernelResponse::with_reason(Verdict::NotAdmissible, "no"),
        ]
    };
    let conn1: Vec<u8> = (10..15).collect();
    let conn2: Vec<u8> = (20..25).collect();

    // FIFO: dispatch order == enqueue order (all of conn1, then conn2).
    let kfifo = MockKernel::new();
    kfifo.set_responses(response_cycle());
    let (fifo_q, fifo_rx) = BoundedQueue::new(16);
    for &p in conn1.iter().chain(conn2.iter()) {
        let _ = fifo_q.try_submit(vec![p]);
    }
    let mut fifo_pairs: Vec<(u8, u8)> = Vec::new();
    for _ in 0..10 {
        drain_one(&fifo_rx, Duration::from_millis(10), |payload| {
            let r = kfifo.submit(payload);
            fifo_pairs.push((payload[0], r.verdict.to_byte()));
            r
        });
    }

    // DRR: dispatch order round-robins across the two connections.
    let kdrr = MockKernel::new();
    kdrr.set_responses(response_cycle());
    let drr_q = fair(64, 64, 64);
    for &p in &conn1 {
        let _ = drr_q.try_submit(1, LEGACY_SIGNER_HINT, vec![p]);
    }
    for &p in &conn2 {
        let _ = drr_q.try_submit(2, LEGACY_SIGNER_HINT, vec![p]);
    }
    let mut drr_pairs: Vec<(u8, u8)> = Vec::new();
    while let Some(req) = drr_q.try_next() {
        let r = kdrr.submit(&req.payload);
        drr_pairs.push((req.payload[0], r.verdict.to_byte()));
        let _ = req.reply.try_send(r);
    }

    // 1. The dispatch ORDERS differ — DRR genuinely reordered.
    let fifo_order: Vec<u8> = fifo_pairs.iter().map(|(p, _)| *p).collect();
    let drr_order: Vec<u8> = drr_pairs.iter().map(|(p, _)| *p).collect();
    assert_eq!(fifo_order, vec![10, 11, 12, 13, 14, 20, 21, 22, 23, 24]);
    assert_eq!(drr_order, vec![10, 20, 11, 21, 12, 22, 13, 23, 14, 24]);
    assert_ne!(fifo_order, drr_order);

    // 2. The per-request verdict ASSIGNMENT differs (reorder changed
    //    which request got which verdict).
    let fifo_map: BTreeMap<u8, u8> = fifo_pairs.iter().copied().collect();
    let drr_map: BTreeMap<u8, u8> = drr_pairs.iter().copied().collect();
    assert_ne!(
        fifo_map, drr_map,
        "reorder must change the per-request assignment"
    );

    // 3. ...yet the verdict MULTISET is identical (admissibility outcomes
    //    are unchanged — only their order/assignment differs).
    let mut fifo_multiset: Vec<u8> = fifo_map.values().copied().collect();
    fifo_multiset.sort_unstable();
    let mut drr_multiset: Vec<u8> = drr_map.values().copied().collect();
    drr_multiset.sort_unstable();
    assert_eq!(
        fifo_multiset, drr_multiset,
        "DRR changed the verdict multiset"
    );
}

// ===== FQ.4b — kernel-panic firewall on the fair path ================

/// A kernel that panics on every submission, to exercise the worker's
/// `catch_unwind` firewall on the DRR path (debug/test profile, where
/// `panic = "unwind"`).
struct PanickingKernel;

impl Kernel for PanickingKernel {
    fn submit(&self, _bytes: &[u8]) -> KernelResponse {
        panic!("boom in kernel");
    }
    fn identifier(&self) -> &'static str {
        "panicking-mock/v1"
    }
}

/// The kernel-panic firewall works on the fair worker exactly as on the
/// FIFO worker: a panicking `kernel.submit` is caught and reported as
/// `NotAdmissible` (with a "panicked" reason), and the worker SURVIVES —
/// a subsequent request is still served.
#[test]
fn drr_kernel_panic_is_contained() {
    let (addr, stop, handle) = spawn_server(Box::new(PanickingKernel), Scheduler::Drr, 16);

    let (v1, reason1) = submit_verdict_reason(addr, b"first").expect("response 1");
    assert_eq!(v1, Verdict::NotAdmissible.to_byte());
    assert!(
        reason1.contains("panic"),
        "expected a panic reason, got: {reason1:?}"
    );

    // The worker survived the panic: a second request still gets a
    // response (it would time out / hang if the worker had died).
    let (v2, _reason2) = submit_verdict_reason(addr, b"second").expect("response 2");
    assert_eq!(v2, Verdict::NotAdmissible.to_byte());

    join_server(&stop, handle);
}

// ===== FQ.2b / §2.8 — dispatch is lock-free under concurrent load ====

/// Under load, a slow in-flight dispatch must NOT serialise producers:
/// `next` returns the request with the scheduler lock already released,
/// so concurrent `try_submit`s proceed while the dispatch is held.  If
/// the lock were held across the dispatch, the producers would block
/// until the held request is dropped (after they finish) — a deadlock
/// the harness would surface as a hang.
#[test]
fn fair_dispatch_does_not_serialise_producers_under_load() {
    let q = fair(64, 64, 4096);
    let _ = q.try_submit(0, LEGACY_SIGNER_HINT, vec![0]);
    // Pop a request (lock released on return) and "dispatch" it slowly by
    // holding it across the producers' work.
    let NextOutcome::Dispatch(held) = q.next(Duration::from_millis(200)) else {
        panic!("expected Dispatch");
    };

    let start = Instant::now();
    let mut producers = Vec::new();
    for c in 0..8u64 {
        let q = q.clone();
        producers.push(thread::spawn(move || {
            for _ in 0..200 {
                let _ = q.try_submit(c, LEGACY_SIGNER_HINT, vec![c as u8]);
            }
        }));
    }
    for p in producers {
        p.join().expect("producer join");
    }
    let elapsed = start.elapsed();
    // The 1600 concurrent submits completed while the dispatch was held,
    // so they did not wait on it.  Generous, machine-independent bound.
    assert!(
        elapsed < Duration::from_secs(3),
        "producers serialised behind the held dispatch: {elapsed:?}"
    );
    drop(held);
}

// ===== FQ.6 — stats() is consistent under concurrent load ============

/// `stats()` never panics and always returns coherent (cap-respecting)
/// values while the queue is churned concurrently by producers and a
/// consumer.
#[test]
fn fair_stats_consistent_under_concurrency() {
    let q = fair(8, 16, 64);
    let stop = Arc::new(AtomicBool::new(false));

    // Poller hammers stats() and checks the cap invariants.
    let qp = q.clone();
    let sp = Arc::clone(&stop);
    let poller = thread::spawn(move || {
        while !sp.load(Ordering::Relaxed) {
            let s = qp.stats();
            assert!(
                s.total_depth <= 64,
                "total_depth {} exceeds global",
                s.total_depth
            );
            assert!(
                s.active_flows <= 16,
                "active_flows {} exceeds max_flows",
                s.active_flows
            );
            assert!(s.active_flows <= s.total_depth || s.total_depth == 0);
        }
    });

    // Producers churn the queue...
    let mut producers = Vec::new();
    for c in 0..8u64 {
        let q = q.clone();
        producers.push(thread::spawn(move || {
            for _ in 0..200 {
                let _ = q.try_submit(c, LEGACY_SIGNER_HINT, vec![c as u8]);
            }
        }));
    }
    // ...while a consumer drains it.
    let qc = q.clone();
    let consumer = thread::spawn(move || {
        for _ in 0..1600 {
            let _ = qc.try_next();
        }
    });

    for p in producers {
        p.join().expect("producer join");
    }
    consumer.join().expect("consumer join");
    stop.store(true, Ordering::Relaxed);
    poller.join().expect("poller join");

    // Final stats are coherent.
    let s = q.stats();
    assert!(s.dispatched <= 1600);
}

// ===== FQ.14a — Rung-1 two-tier fairness + spoof-resistance ==========
//
// As in Rung 0, the fairness SIGNAL is pinned at the queue API (where a
// connection can carry multiple in-flight requests across multiple
// signer hints), not through the one-shot TCP server (under which every
// connection is a single-request flow and DRR coincides with FIFO —
// `GP.8` §2.5).  `tests/wire_compat.rs` covers the v1/v2 wire
// negotiation end-to-end (FQ.14b); these cover the two-tier scheduling.

/// Build a fair queue with an explicit per-connection signer cap.
fn fair_with_signers(
    per_flow: usize,
    max_flows: usize,
    max_signers: usize,
    global: usize,
) -> FairQueue {
    FairQueue::new(Caps::new(per_flow, max_flows, global).with_max_signers(max_signers))
}

/// Build a fair queue with an explicit per-connection AGGREGATE backlog
/// cap (Rung 1.5), with generous leaf / signer caps so the aggregate is
/// the binding constraint.
fn fair_with_conn_backlog(max_conn_backlog: usize, global: usize) -> FairQueue {
    FairQueue::new(
        Caps::new(64, 64, global)
            .with_max_signers(64)
            .with_max_conn_backlog(max_conn_backlog),
    )
}

/// Two-tier fairness: one connection multiplexing MANY signer hints does
/// not starve a second connection.  Conn 1 floods 5 hints × 2 requests
/// (10 total); conn 2 sends one.  The outer round-robin alternates
/// conn1/conn2, so conn 2 is served within the first outer cycle — never
/// buried behind conn 1's multi-hint backlog.
#[test]
fn rung1_one_conn_many_hints_does_not_starve_another() {
    let q = fair(64, 64, 256);
    let kernel = MockKernel::new();
    for hint in 0..5u64 {
        for _ in 0..2 {
            assert!(matches!(
                q.try_submit(1, 100 + hint, vec![1]),
                SubmitOutcome::Enqueued(_)
            ));
        }
    }
    assert!(matches!(
        q.try_submit(2, 200, vec![2]),
        SubmitOutcome::Enqueued(_)
    ));
    let order = drain_all_through(&q, &kernel);
    let pos = order
        .iter()
        .position(|p| p == &vec![2])
        .expect("conn 2 served");
    assert!(
        pos <= 1,
        "conn 2 served at position {pos}, expected within the outer cycle (≤ 1)"
    );
    assert_eq!(order.iter().filter(|p| *p == &vec![1]).count(), 10);
}

/// Spoof-resistance, end-to-end at the queue level (the §2.6(2)
/// guarantee, FQ.14a): connection C floods 8 hints spoofing many
/// victim ids; the REAL victim V on a different connection sends 4
/// requests and is served within the bounded outer cycle — its requests
/// land in the first 8 dispatches (one per outer cycle), wholly
/// unaffected by C's 32-request multi-hint flood.
#[test]
fn rung1_spoofed_hints_do_not_starve_the_real_victim() {
    let q = fair(64, 64, 256);
    let kernel = MockKernel::new();
    // Attacker conn 1: 8 forged hints × 4 requests = 32.
    for hint in 0..8u64 {
        for _ in 0..4 {
            assert!(matches!(
                q.try_submit(1, 9000 + hint, vec![1]),
                SubmitOutcome::Enqueued(_)
            ));
        }
    }
    // Real victim conn 2: 4 requests under one hint.
    for _ in 0..4 {
        assert!(matches!(
            q.try_submit(2, 7, vec![2]),
            SubmitOutcome::Enqueued(_)
        ));
    }
    let order = drain_all_through(&q, &kernel);
    let victim_positions: Vec<usize> = order
        .iter()
        .enumerate()
        .filter(|(_, p)| *p == &vec![2])
        .map(|(i, _)| i)
        .collect();
    assert_eq!(victim_positions.len(), 4, "all 4 victim requests served");
    assert!(
        victim_positions.iter().max().unwrap() < &8,
        "victim buried behind the spoofer's multi-hint flood: {victim_positions:?}"
    );
    // The spoofer still got served (work-conserving) — it just couldn't
    // exceed its single outer share while the victim contended.
    assert_eq!(order.iter().filter(|p| *p == &vec![1]).count(), 32);
}

/// `--max-signers-per-conn` is enforced at the FairQueue level and is
/// targeted: the offending connection's (cap+1)-th distinct hint gets
/// `Busy`, while a second connection opens its own hints freely.
#[test]
fn rung1_max_signers_cap_is_targeted_at_queue_level() {
    let q = fair_with_signers(64, 64, 2, 256); // max_signers = 2 per conn
    assert!(matches!(
        q.try_submit(1, 10, vec![1]),
        SubmitOutcome::Enqueued(_)
    ));
    assert!(matches!(
        q.try_submit(1, 11, vec![1]),
        SubmitOutcome::Enqueued(_)
    ));
    // Conn 1's THIRD distinct hint → Busy (max_signers = 2).
    assert!(matches!(q.try_submit(1, 12, vec![1]), SubmitOutcome::Busy));
    assert_eq!(q.stats().rejected_max_signers, 1);
    // An existing hint on conn 1 still enqueues (cap is on distinct hints).
    assert!(matches!(
        q.try_submit(1, 10, vec![1]),
        SubmitOutcome::Enqueued(_)
    ));
    // Conn 2 opens its own two hints freely (per-connection cap).
    assert!(matches!(
        q.try_submit(2, 20, vec![2]),
        SubmitOutcome::Enqueued(_)
    ));
    assert!(matches!(
        q.try_submit(2, 21, vec![2]),
        SubmitOutcome::Enqueued(_)
    ));
    assert_eq!(q.stats().rejected_max_signers, 1, "conn 2 unaffected");
    assert_eq!(q.stats().active_signers, 4, "2 hints on each of 2 conns");
}

/// `--max-conn-backlog` (Rung 1.5) is enforced at the FairQueue level
/// and is per-connection: a connection that spreads a flood across many
/// distinct hints — each leaf far under `per_flow`, the hint count under
/// `max_signers` — is still confined to its aggregate cap, while a
/// second connection is unaffected.
#[test]
fn rung1_5_max_conn_backlog_is_targeted_at_queue_level() {
    let q = fair_with_conn_backlog(3, 1000); // aggregate cap = 3 per conn
                                             // Conn 1: three requests across three DISTINCT hints (each leaf
                                             // depth 1, three hints) — fills the aggregate.
    assert!(matches!(
        q.try_submit(1, 10, vec![1]),
        SubmitOutcome::Enqueued(_)
    ));
    assert!(matches!(
        q.try_submit(1, 11, vec![1]),
        SubmitOutcome::Enqueued(_)
    ));
    assert!(matches!(
        q.try_submit(1, 12, vec![1]),
        SubmitOutcome::Enqueued(_)
    ));
    // A FOURTH distinct hint — under per_flow AND max_signers, but the
    // connection's aggregate is at the cap ⇒ Busy.
    assert!(matches!(q.try_submit(1, 13, vec![1]), SubmitOutcome::Busy));
    assert_eq!(q.stats().rejected_conn_backlog, 1);
    assert_eq!(q.stats().rejected_per_flow, 0, "leaf cap did not fire");
    assert_eq!(q.stats().rejected_max_signers, 0, "signer cap did not fire");
    // A second connection opens its own aggregate freely (per-connection).
    assert!(matches!(
        q.try_submit(2, 20, vec![2]),
        SubmitOutcome::Enqueued(_)
    ));
    assert!(matches!(
        q.try_submit(2, 21, vec![2]),
        SubmitOutcome::Enqueued(_)
    ));
    assert!(matches!(
        q.try_submit(2, 22, vec![2]),
        SubmitOutcome::Enqueued(_)
    ));
    assert_eq!(q.stats().rejected_conn_backlog, 1, "conn 2 unaffected");
}

/// A legacy connection (all requests under the sentinel hint) behaves
/// EXACTLY as Rung 0: the two-tier scheduler with one inner flow per
/// connection collapses to per-connection round-robin (`GP.8` §2.6
/// invariant 3).  Mirrors `fairness_whale_does_not_bury_small`.
#[test]
fn rung1_legacy_sentinel_hint_is_rung0_behaviour() {
    let q = fair(64, 64, 256);
    let kernel = MockKernel::new();
    for _ in 0..10 {
        assert!(matches!(
            q.try_submit(1, LEGACY_SIGNER_HINT, vec![1]),
            SubmitOutcome::Enqueued(_)
        ));
    }
    assert!(matches!(
        q.try_submit(2, LEGACY_SIGNER_HINT, vec![2]),
        SubmitOutcome::Enqueued(_)
    ));
    let order = drain_all_through(&q, &kernel);
    let small_pos = order
        .iter()
        .position(|p| p == &vec![2])
        .expect("small served");
    assert!(
        small_pos <= 1,
        "legacy small served at {small_pos}, expected ≤ 1"
    );
    // Each connection has exactly one (sentinel) signer flow.
    let _ = kernel;
}

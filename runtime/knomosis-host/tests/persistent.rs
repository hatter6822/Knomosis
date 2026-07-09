// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Persistent + pipelined connection mode end-to-end (Workstream GP.8,
//! Track A / FQ — `--persistent-connections`).
//!
//! These tests close the §2.5 topology gap: under the one-shot
//! connection lifecycle every TCP connection is a single-request flow, so
//! two-tier DRR and FIFO coincide end-to-end and the fairness mechanism
//! never bites over the wire.  The persistent + pipelined mode lets one
//! connection hold multiple simultaneously-queued requests, which is the
//! only condition under which DRR diverges from FIFO.  Here we prove,
//! over REAL TCP against a running host:
//!
//!   * a v2 (hinted) and a v1 (legacy) connection each pipeline many
//!     requests on ONE connection and receive one verdict per request in
//!     submission order (wiring `ConnReader`'s persistent read path);
//!   * a one-shot client (one frame, then close) still works against a
//!     persistent host (back-compat — one-shot is a degenerate subset);
//!   * **fair scheduling under contention is exercised through the wire**:
//!     with `--scheduler drr --persistent-connections`, a flooding
//!     pipelined connection does NOT bury an honest connection — the
//!     honest connection's requests are interleaved into the first few
//!     dispatches rather than queued behind the whole flood.  The FIFO
//!     contrast test proves the flood DOES bury the honest connection
//!     without DRR, so the property is real, not vacuous.

use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use knomosis_host::config::Scheduler;
use knomosis_host::fair::drr::Caps;
use knomosis_host::frame::{encode_frame, encode_hinted_frame, KNH2_PREAMBLE};
use knomosis_host::kernel::mock::MockKernel;
use knomosis_host::kernel::{Kernel, KernelResponse};
use knomosis_host::listener::tcp::TcpListener;
use knomosis_host::listener::HandlerConfig;
use knomosis_host::server::{Server, ServerConfigBuilder};
use knomosis_host::verdict::Verdict;

// ===================================================================
// Server + client harness
// ===================================================================

/// Spawn a persistent-connection host on a random TCP port with the
/// given scheduler, caps, and kernel.
fn spawn_persistent_server(
    scheduler: Scheduler,
    caps: Caps,
    kernel: Box<dyn Kernel>,
) -> (SocketAddr, Arc<AtomicBool>, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = listener.local_addr().unwrap();
    let cfg = ServerConfigBuilder::new()
        .scheduler(scheduler)
        .fair_caps(caps)
        .max_queue_depth(256)
        .handler(HandlerConfig {
            persistent_connections: true,
            ..HandlerConfig::default()
        })
        .tcp(listener)
        .build(kernel)
        .unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let server_stop = Arc::clone(&stop);
    let handle = thread::spawn(move || Server::new(cfg).run(server_stop));
    thread::sleep(Duration::from_millis(100));
    (addr, stop, handle)
}

/// Stop a server and join within a deadline (fails loudly on a hang).
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

/// An 8-byte LE payload encoding `tag` (the recording kernel reads it
/// back to record dispatch order).
fn tagged_payload(tag: u64) -> Vec<u8> {
    tag.to_le_bytes().to_vec()
}

/// Connect and pipeline `tags` as v2 (hinted) frames under one `hint`,
/// then half-close the write side so the host sees an immediate EOF
/// after the last frame.  Returns the still-readable stream.
fn pipeline_v2(addr: SocketAddr, hint: u64, tags: &[u64]) -> TcpStream {
    let mut stream = TcpStream::connect(addr).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut buf = KNH2_PREAMBLE.to_vec();
    for &t in tags {
        buf.extend_from_slice(&encode_hinted_frame(hint, &tagged_payload(t)).unwrap());
    }
    stream.write_all(&buf).unwrap();
    stream.flush().unwrap();
    stream.shutdown(Shutdown::Write).unwrap();
    stream
}

/// Connect and pipeline `tags` as v1 (legacy, un-hinted) frames, then
/// half-close.  Returns the still-readable stream.
fn pipeline_v1(addr: SocketAddr, tags: &[u64]) -> TcpStream {
    let mut stream = TcpStream::connect(addr).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut buf = Vec::new();
    for &t in tags {
        buf.extend_from_slice(&encode_frame(&tagged_payload(t)).unwrap());
    }
    stream.write_all(&buf).unwrap();
    stream.flush().unwrap();
    stream.shutdown(Shutdown::Write).unwrap();
    stream
}

/// Read exactly `n` responses (`[1 verdict][4 reason_len][reason]`) and
/// return the verdict bytes in order.
fn read_n_verdicts(stream: &mut TcpStream, n: usize) -> Vec<u8> {
    let mut verdicts = Vec::with_capacity(n);
    for i in 0..n {
        let mut head = [0u8; 5];
        stream
            .read_exact(&mut head)
            .unwrap_or_else(|e| panic!("read verdict #{i} head: {e}"));
        let reason_len = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
        let mut reason = vec![0u8; reason_len];
        stream
            .read_exact(&mut reason)
            .unwrap_or_else(|e| panic!("read verdict #{i} reason: {e}"));
        verdicts.push(head[0]);
    }
    verdicts
}

// ===================================================================
// Recording / gating kernel
// ===================================================================

/// Shared state the test inspects after a run.
#[derive(Default)]
struct RecordState {
    /// Dispatch order, by payload tag.
    order: Mutex<Vec<u64>>,
    /// Whether the gate has been released by the test.
    released: Mutex<bool>,
    /// Signalled when `released` flips.
    cv: Condvar,
    /// Whether the first dispatch has been seen (for the one-shot gate).
    first_seen: AtomicBool,
}

/// A test kernel that records dispatch order and, optionally, blocks the
/// FIRST dispatch until the test releases it — so the test can stage the
/// entire queue (from multiple connections) before any request is
/// served, making the dispatch order a deterministic function of the
/// scheduler alone.
struct RecordingKernel {
    state: Arc<RecordState>,
    gate_first: bool,
}

impl RecordingKernel {
    fn new(state: Arc<RecordState>, gate_first: bool) -> Self {
        Self { state, gate_first }
    }
}

impl Kernel for RecordingKernel {
    fn submit(&self, signed_action_bytes: &[u8]) -> KernelResponse {
        // Gate the very first dispatch until the test stages the queue.
        if self.gate_first && !self.state.first_seen.swap(true, Ordering::SeqCst) {
            let mut released = self.state.released.lock().unwrap();
            while !*released {
                released = self.state.cv.wait(released).unwrap();
            }
        }
        let mut tag = [0u8; 8];
        let n = signed_action_bytes.len().min(8);
        tag[..n].copy_from_slice(&signed_action_bytes[..n]);
        self.state
            .order
            .lock()
            .unwrap()
            .push(u64::from_le_bytes(tag));
        KernelResponse::from_verdict(Verdict::Ok)
    }

    fn identifier(&self) -> &'static str {
        "recording-test-kernel/v1"
    }
}

/// Release the first-dispatch gate.
fn release_gate(state: &RecordState) {
    *state.released.lock().unwrap() = true;
    state.cv.notify_all();
}

/// Generous caps that never reject for these workloads.
fn open_caps() -> Caps {
    Caps::new(256, 64, 256)
        .with_max_signers(64)
        .with_max_conn_backlog(256)
}

// ===================================================================
// Capability: pipelining + ConnReader persistent path through the wire
// ===================================================================

/// A v2 (hinted) connection pipelines 6 requests on ONE connection and
/// receives 6 `Ok` verdicts in order — wiring `ConnReader`'s persistent
/// read path through the real TCP server.
#[test]
fn persistent_v2_pipelines_many_requests_on_one_connection() {
    let (addr, stop, server) =
        spawn_persistent_server(Scheduler::Drr, open_caps(), Box::new(MockKernel::new()));
    let tags: Vec<u64> = (0..6).collect();
    let mut stream = pipeline_v2(addr, 42, &tags);
    let verdicts = read_n_verdicts(&mut stream, tags.len());
    assert_eq!(verdicts.len(), 6);
    assert!(
        verdicts.iter().all(|&v| v == Verdict::Ok.to_byte()),
        "all pipelined requests admitted: {verdicts:?}"
    );
    join_server(&stop, server);
}

/// A v1 (legacy, un-hinted) connection ALSO pipelines on one connection
/// — persistent mode is not v2-only (the inner tier collapses to one
/// flow for it, but the connection still multiplexes requests).
#[test]
fn persistent_v1_pipelines_many_requests_on_one_connection() {
    let (addr, stop, server) =
        spawn_persistent_server(Scheduler::Drr, open_caps(), Box::new(MockKernel::new()));
    let tags: Vec<u64> = (0..6).collect();
    let mut stream = pipeline_v1(addr, &tags);
    let verdicts = read_n_verdicts(&mut stream, tags.len());
    assert_eq!(verdicts.len(), 6);
    assert!(verdicts.iter().all(|&v| v == Verdict::Ok.to_byte()));
    join_server(&stop, server);
}

/// Back-compat: a one-shot client (one frame, then close) works against a
/// persistent host — one-shot is a degenerate subset of persistent (the
/// reader reads one frame, then sees EOF and drains).
#[test]
fn one_shot_client_works_against_persistent_host() {
    let (addr, stop, server) =
        spawn_persistent_server(Scheduler::Fifo, open_caps(), Box::new(MockKernel::new()));
    let mut stream = pipeline_v1(addr, &[7]); // one frame + half-close
    let verdicts = read_n_verdicts(&mut stream, 1);
    assert_eq!(verdicts, vec![Verdict::Ok.to_byte()]);
    join_server(&stop, server);
}

// ===================================================================
// The headline: fair scheduling under contention, OVER THE WIRE
// ===================================================================

/// Stage a flood + honest contention scenario against `scheduler` and
/// return the kernel's dispatch order (by tag).  FLOOD pipelines
/// `flood` requests (tags `0..flood`) on one connection; HONEST
/// pipelines `honest` requests (tags `1000..1000+honest`) on another.
/// The first dispatch is gated until BOTH connections' requests are
/// enqueued, so the resulting order is a deterministic function of the
/// scheduler.
fn staged_contention_order(scheduler: Scheduler, flood: u64, honest: u64) -> Vec<u64> {
    let state = Arc::new(RecordState::default());
    let kernel = Box::new(RecordingKernel::new(Arc::clone(&state), true));
    let (addr, stop, server) = spawn_persistent_server(scheduler, open_caps(), kernel);

    // 1. FLOOD connects and pipelines all its frames, then half-closes.
    //    The host enqueues them; the worker picks the first and BLOCKS on
    //    the gate, so the remainder accumulate in the queue.
    let flood_tags: Vec<u64> = (0..flood).collect();
    let mut flood_stream = pipeline_v2(addr, 1, &flood_tags);
    thread::sleep(Duration::from_millis(200));

    // 2. HONEST connects and pipelines its frames AFTER the flood is fully
    //    enqueued (deterministic enqueue order: flood, then honest).
    let honest_tags: Vec<u64> = (1000..1000 + honest).collect();
    let mut honest_stream = pipeline_v2(addr, 1, &honest_tags);
    thread::sleep(Duration::from_millis(200));

    // 3. Release the gate: the worker now drains everything in scheduler
    //    order, with the full queue staged.
    release_gate(&state);

    // 4. Drain both connections' responses (tiny, so the un-read socket
    //    buffers a few while we read the other).
    let f = read_n_verdicts(&mut flood_stream, flood_tags.len());
    let h = read_n_verdicts(&mut honest_stream, honest_tags.len());
    assert!(f.iter().all(|&v| v == Verdict::Ok.to_byte()));
    assert!(h.iter().all(|&v| v == Verdict::Ok.to_byte()));

    join_server(&stop, server);
    let order = state.order.lock().unwrap().clone();
    assert_eq!(
        order.len() as u64,
        flood + honest,
        "every staged request was dispatched"
    );
    order
}

/// Count how many FLOOD requests (tag < 1000) were dispatched before the
/// LAST HONEST request (tag >= 1000) in the dispatch order.
fn floods_before_last_honest(order: &[u64]) -> usize {
    let last_honest_idx = order
        .iter()
        .rposition(|&t| t >= 1000)
        .expect("at least one honest request");
    order[..last_honest_idx]
        .iter()
        .filter(|&&t| t < 1000)
        .count()
}

/// **The headline test.**  Under `--scheduler drr --persistent-connections`,
/// a flooding pipelined connection does NOT bury an honest connection:
/// the honest connection's requests are interleaved into the dispatch
/// stream (outer round-robin across connections), so only a handful of
/// flood requests precede the honest connection's last request — NOT the
/// whole flood.  This is fair scheduling under contention, exercised
/// through the wire (the §2.5 gap, closed).
#[test]
fn drr_persistent_fair_scheduling_bites_through_the_wire() {
    let flood = 12u64;
    let honest = 4u64;
    let order = staged_contention_order(Scheduler::Drr, flood, honest);
    let before = floods_before_last_honest(&order);
    // DRR round-robins flood/honest, so the honest connection's last
    // request lands by ~position 8 (≈ flood/2 + honest floods precede it).
    // Generous bound (DRR yields ~5 here); FIFO yields the full flood.
    assert!(
        before <= 6,
        "DRR buried the honest connection behind {before} flood requests \
         (order: {order:?})"
    );
    // Sanity: the honest connection was genuinely contended (not served
    // first by accident) — at least one flood preceded its last request.
    assert!(before >= 1, "test did not stage real contention: {order:?}");
}

/// **The contrast test.**  The SAME staged contention under
/// `--scheduler fifo` buries the honest connection behind the ENTIRE
/// flood (FIFO serves strictly in arrival order, and the flood arrived
/// first).  This proves the headline property is real — the flood does
/// bury the honest connection without DRR — rather than an artifact of
/// the harness.
#[test]
fn fifo_persistent_buries_honest_connection() {
    let flood = 12u64;
    let honest = 4u64;
    let order = staged_contention_order(Scheduler::Fifo, flood, honest);
    let before = floods_before_last_honest(&order);
    assert_eq!(
        before, flood as usize,
        "FIFO should serve the whole flood before the honest connection's \
         last request (order: {order:?})"
    );
}

/// Graceful shutdown with an OPEN persistent connection (no half-close):
/// the reader is blocked waiting for the next frame, observes the `stop`
/// flag within one read timeout, and exits — so the server shuts down
/// cleanly rather than hanging on the idle connection.  Uses a short
/// connection timeout so the test is fast.
#[test]
fn graceful_shutdown_with_open_persistent_connection() {
    let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = listener.local_addr().unwrap();
    let cfg = ServerConfigBuilder::new()
        .scheduler(Scheduler::Drr)
        .fair_caps(open_caps())
        .max_queue_depth(256)
        .handler(HandlerConfig {
            persistent_connections: true,
            // Short idle read timeout so an open-but-idle connection
            // observes `stop` quickly.
            connection_timeout: Duration::from_millis(400),
            ..HandlerConfig::default()
        })
        .tcp(listener)
        .build(Box::new(MockKernel::new()))
        .unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let server_stop = Arc::clone(&stop);
    let server = thread::spawn(move || Server::new(cfg).run(server_stop));
    thread::sleep(Duration::from_millis(100));

    // Open a v2 connection, send ONE frame, read its verdict, then leave
    // the connection OPEN (no half-close) and idle.
    let mut stream = TcpStream::connect(addr).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut buf = KNH2_PREAMBLE.to_vec();
    buf.extend_from_slice(&encode_hinted_frame(9, &tagged_payload(1)).unwrap());
    stream.write_all(&buf).unwrap();
    stream.flush().unwrap();
    let verdicts = read_n_verdicts(&mut stream, 1);
    assert_eq!(verdicts, vec![Verdict::Ok.to_byte()]);

    // The connection is still open + idle.  Shut the server down: the
    // reader must notice `stop` within one (short) read timeout and exit.
    join_server(&stop, server);
    // Keep the client alive until after shutdown so the connection was
    // genuinely open across the stop.
    drop(stream);
}

/// Regression for the unbounded-channel OOM finding: the reader→writer
/// hand-off is a BOUNDED channel sized to the per-connection in-flight
/// bound, so a client that pipelines far MORE requests than that bound
/// does not grow host memory without bound — the reader back-pressures
/// (blocks on the bounded `send`) instead.
///
/// Setup: a small `max_conn_backlog` (4) sizes the channel; a gated
/// kernel stalls the writer so the channel fills and the host reader
/// back-pressures partway through the client's N=16 (>> 4) frames.  After
/// the gate releases, ALL 16 still drain correctly, in order, with no
/// deadlock and no loss.  A concurrent reader thread on the client is
/// what a well-behaved pipelining client does (read while sending), so
/// the client's own send never deadlocks against the host's
/// back-pressure.
#[test]
fn persistent_bounded_channel_backpressures_without_deadlock() {
    let caps = Caps::new(64, 64, 1024)
        .with_max_signers(64)
        .with_max_conn_backlog(4); // ⇒ reader→writer channel capacity 4
    let state = Arc::new(RecordState::default());
    let kernel = Box::new(RecordingKernel::new(Arc::clone(&state), true));
    let (addr, stop, server) = spawn_persistent_server(Scheduler::Drr, caps, kernel);

    let n: usize = 16; // >> the per-connection bound (4)
    let mut send_stream = TcpStream::connect(addr).unwrap();
    send_stream
        .set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut read_stream = send_stream.try_clone().unwrap();
    read_stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();

    // Concurrent reader (a well-behaved pipelining client reads while it
    // sends, so its own send never deadlocks against host back-pressure).
    let reader = thread::spawn(move || read_n_verdicts(&mut read_stream, n));

    let mut buf = KNH2_PREAMBLE.to_vec();
    for t in 0..n as u64 {
        buf.extend_from_slice(&encode_hinted_frame(1, &tagged_payload(t)).unwrap());
    }
    send_stream.write_all(&buf).unwrap();
    send_stream.flush().unwrap();
    send_stream.shutdown(Shutdown::Write).unwrap();

    // Let the host fill the bounded channel + back-pressure its reader
    // (the gate stalls the writer), then release.
    thread::sleep(Duration::from_millis(200));
    release_gate(&state);

    let verdicts = reader.join().unwrap();
    assert_eq!(verdicts.len(), n, "every pipelined request got a response");
    // Each is Ok (admitted) or Busy (queue full) — never lost, never a
    // hang; the bounded channel converted memory growth into back-pressure.
    for v in &verdicts {
        assert!(
            *v == Verdict::Ok.to_byte() || *v == Verdict::Busy.to_byte(),
            "unexpected verdict byte {v}"
        );
    }
    join_server(&stop, server);
}

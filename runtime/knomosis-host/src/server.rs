// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Top-level orchestrator wiring listeners + queue + worker.
//!
//! ## Architecture
//!
//! ```text
//!  ┌─────────────────────────────────────────────────────────────┐
//!  │  TCP / TLS / Unix listener threads (one per protocol)        │
//!  │  ─ accept() loop                                             │
//!  │  ─ spawn(handle_connection) on new connection                │
//!  └────────────────────┬────────────────────────────────────────┘
//!                       │ queue.try_submit(payload)
//!                       ▼
//!  ┌─────────────────────────────────────────────────────────────┐
//!  │  BoundedQueue (mpsc sync_channel, capacity = max_queue_depth)│
//!  │  ─ Enqueued(reply_rx) on success                             │
//!  │  ─ Busy on overflow                                          │
//!  └────────────────────┬────────────────────────────────────────┘
//!                       │ rx.recv_timeout()
//!                       ▼
//!  ┌─────────────────────────────────────────────────────────────┐
//!  │  Worker thread (one)                                         │
//!  │  ─ drain_one(rx, dispatch=kernel.submit)                     │
//!  │  ─ reply.try_send(response) → connection handler             │
//!  └─────────────────────────────────────────────────────────────┘
//! ```
//!
//! ## Why single-threaded worker
//!
//! The kernel may hold mutable state (e.g. the knomosis log file)
//! that requires sequential access.  A multi-threaded worker
//! pool would need to either:
//!   * Hold a mutex around every kernel call (no parallelism
//!     gain), or
//!   * Run multiple log files (breaks the canonical log
//!     invariant).
//!
//! A single worker thread serialises the calls naturally.  The
//! bounded queue ensures backpressure surfaces to the client via
//! the `Busy` verdict rather than unbounded memory growth.
//!
//! ## Shutdown semantics
//!
//! `Server::run` watches the supplied stop flag.  When the flag
//! flips:
//!   1. Listener accept-loops exit (no new connections accepted).
//!   2. Worker thread drains the queue (already-enqueued
//!      requests complete normally).
//!   3. In-flight connection handler threads complete their
//!      current request.
//!   4. `Server::run` returns.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::config::Scheduler;
use crate::fair::drr::{Caps, DrrStats};
use crate::kernel::{Kernel, KernelResponse};
use crate::listener::{tcp::TcpListener, HandlerConfig};
use crate::queue::{
    drain_one, try_drain_one, BoundedQueue, DrainOutcome, FairQueue, NextOutcome, QueueHandle,
    DEFAULT_MAX_QUEUE_DEPTH,
};

use crate::listener::tls::TlsListener;
#[cfg(unix)]
use crate::listener::unix::UnixListener;

/// Maximum time `Server::run` waits for in-flight connection
/// handler threads to drain after the listener accept loops exit.
/// The handler threads themselves are bounded by
/// `kernel_reply_timeout` + a small grace period; this is an
/// upper bound that prevents a wedged handler from blocking
/// shutdown indefinitely.
const SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_secs(75);

/// How often the fair worker emits an aggregate fairness summary while
/// running (FQ.6).  One `info` line at most per interval, and only when
/// there has been activity since the last summary — never per-request
/// spam, and silent on a fully-idle host.
const FAIR_SUMMARY_INTERVAL: Duration = Duration::from_secs(30);

/// Server configuration.  Constructed by `crate::config::Config`'s
/// validation path; downstream code uses `Server::builder` to
/// construct from this.
///
/// Not `Debug` because the `Box<dyn Kernel>` field cannot derive
/// `Debug` automatically (would require widening the trait, which
/// is overly restrictive for kernel implementations).
pub struct ServerConfig {
    /// Maximum in-flight requests (the FIFO queue depth / the DRR
    /// `global` cap).
    pub max_queue_depth: usize,
    /// Which worker scheduler to run (FQ Rung 0).  `Fifo` (the default)
    /// builds the historical [`BoundedQueue`] + `worker_loop`; `Drr`
    /// builds a [`FairQueue`] + `fair_worker_loop`.
    pub scheduler: Scheduler,
    /// The DRR capacity caps (used only when `scheduler == Drr`).
    pub fair_caps: Caps,
    /// Handler-level config (frame size, timeouts).
    pub handler: HandlerConfig,
    /// Optional TCP listener.
    pub tcp_listener: Option<TcpListener>,
    /// Optional TLS-on-TCP listener.
    pub tls_listener: Option<TlsListener>,
    /// Optional Unix-socket listener.
    #[cfg(unix)]
    pub unix_listener: Option<UnixListener>,
    /// The kernel implementation to dispatch to.
    pub kernel: Box<dyn Kernel>,
}

/// The orchestrator handle.  After [`Server::run`] returns, the
/// server has fully shut down.
pub struct Server {
    config: ServerConfig,
}

impl Server {
    /// Construct a Server from a ServerConfig.
    #[must_use]
    pub fn new(config: ServerConfig) -> Self {
        Self { config }
    }

    /// Run the orchestrator until `stop` flips to `true`.
    ///
    /// Spawns:
    ///   1. The single worker thread — `worker_loop` (FIFO) or
    ///      `fair_worker_loop` (DRR), chosen by `config.scheduler`.
    ///   2. One thread per configured listener (TCP / TLS / Unix),
    ///      each submitting through a scheduler-agnostic
    ///      [`QueueHandle`] and assigning each connection a monotonic
    ///      [`crate::queue::ConnId`] from a shared counter (FQ.3).
    ///
    /// Blocks the calling thread until `stop` is set; then waits
    /// for all spawned threads to join before returning.
    ///
    /// ## Shutdown ordering
    ///
    /// When `stop` flips to `true`, shutdown proceeds in strict
    /// phases to honour the "queued requests complete on
    /// shutdown" promise:
    ///
    ///   1. **Listener accept loops exit.**  No new connections
    ///      accepted.
    ///   2. **Wait for in-flight connection handler threads** to
    ///      drain (bounded by `SHUTDOWN_DRAIN_TIMEOUT`).  Each
    ///      handler completes its current request → response
    ///      cycle, including waiting for the kernel's reply.  The
    ///      kernel keeps draining the queue during this phase.
    ///   3. **Release the producer handle.**  The listener-facing
    ///      [`QueueHandle`] is dropped.  On the FIFO path, with the
    ///      listener clones already gone, this drops the last channel
    ///      sender, so the worker's `drain_one` returns `Disconnected`.
    ///      On the DRR path the worker instead exits on the `stop`
    ///      flag; a [`FairQueue::wake_all`] broadcast wakes a parked
    ///      worker promptly.
    ///   4. **Worker exits cleanly** after draining the remainder, on
    ///      whichever signal its loop watches (FIFO: `Disconnected`;
    ///      DRR: `stop`).
    pub fn run(self, stop: Arc<AtomicBool>) {
        let handler_config = self.config.handler.clone();
        let kernel = self.config.kernel;
        let kernel_identifier = kernel.identifier().to_string();
        let kernel_ok_stage = kernel.ok_admission_stage();
        let connection_counter = Arc::new(AtomicUsize::new(0));
        // FQ.3: a process-wide monotonic connection-id source shared by
        // every listener.  Ignored on the FIFO path; the DRR routing key
        // on the fair path.
        let conn_seq = Arc::new(AtomicU64::new(0));
        let scheduler = self.config.scheduler;

        tracing::info!(
            kernel = %kernel_identifier,
            ok_stage = kernel_ok_stage.name(),
            scheduler = scheduler.name(),
            queue_depth = self.config.max_queue_depth,
            max_frame_size = self.config.handler.max_frame_size,
            max_concurrent_connections = self.config.handler.max_concurrent_connections,
            "knomosis-host starting"
        );

        // 1. Build the queue + spawn the worker (scheduler-specific).
        //    `handle` is the scheduler-agnostic producer the listeners
        //    submit through.  `fair_queue` is retained on the DRR path
        //    only — for the prompt shutdown wake (§2.8).  The FIFO arm is
        //    byte-for-byte the historical path.
        let (handle, worker, fair_queue): (QueueHandle, JoinHandle<()>, Option<FairQueue>) =
            match scheduler {
                Scheduler::Fifo => {
                    let (queue, receiver) = BoundedQueue::new(self.config.max_queue_depth);
                    let worker_stop = Arc::clone(&stop);
                    let worker = thread::Builder::new()
                        .name("knomosis-host-worker".into())
                        .spawn(move || worker_loop(receiver, kernel, worker_stop))
                        .expect("spawn worker thread");
                    (QueueHandle::Fifo(queue), worker, None)
                }
                Scheduler::Drr => {
                    let queue = FairQueue::new(self.config.fair_caps);
                    let worker_queue = queue.clone();
                    let worker_stop = Arc::clone(&stop);
                    let worker = thread::Builder::new()
                        .name("knomosis-host-worker".into())
                        .spawn(move || fair_worker_loop(worker_queue, kernel, worker_stop))
                        .expect("spawn fair worker thread");
                    (QueueHandle::Fair(queue.clone()), worker, Some(queue))
                }
            };

        // 2. Spawn listener threads (common to both schedulers; they
        //    submit through the `QueueHandle` and take a `conn_seq`
        //    clone for FQ.3 id assignment).
        let mut listener_handles: Vec<JoinHandle<()>> = Vec::new();
        if let Some(tcp) = self.config.tcp_listener {
            let h = handle.clone();
            let cfg = handler_config.clone();
            let s = Arc::clone(&stop);
            let counter = Arc::clone(&connection_counter);
            let seq = Arc::clone(&conn_seq);
            let local = tcp.local_addr().ok();
            tracing::info!(addr = ?local, "tcp listener up");
            let lh = thread::Builder::new()
                .name("knomosis-host-tcp".into())
                .spawn(move || tcp.accept_loop(h, cfg, s, counter, seq))
                .expect("spawn tcp listener thread");
            listener_handles.push(lh);
        }
        if let Some(tls) = self.config.tls_listener {
            let h = handle.clone();
            let cfg = handler_config.clone();
            let s = Arc::clone(&stop);
            let counter = Arc::clone(&connection_counter);
            let seq = Arc::clone(&conn_seq);
            let local = tls.local_addr().ok();
            tracing::info!(addr = ?local, "tls listener up");
            let lh = thread::Builder::new()
                .name("knomosis-host-tls".into())
                .spawn(move || tls.accept_loop(h, cfg, s, counter, seq))
                .expect("spawn tls listener thread");
            listener_handles.push(lh);
        }
        #[cfg(unix)]
        if let Some(unix) = self.config.unix_listener {
            let h = handle.clone();
            let cfg = handler_config.clone();
            let s = Arc::clone(&stop);
            let counter = Arc::clone(&connection_counter);
            let seq = Arc::clone(&conn_seq);
            let path = unix.path().to_path_buf();
            tracing::info!(path = ?path, "unix listener up");
            let lh = thread::Builder::new()
                .name("knomosis-host-unix".into())
                .spawn(move || unix.accept_loop(h, cfg, s, counter, seq))
                .expect("spawn unix listener thread");
            listener_handles.push(lh);
        }

        // 3. Wait for listeners (they exit when `stop` flips).
        for lh in listener_handles {
            if let Err(e) = lh.join() {
                tracing::warn!(error = ?e, "listener thread panicked");
            }
        }

        // 4. Wait for in-flight connection handler threads to
        //    drain.  Bounded by SHUTDOWN_DRAIN_TIMEOUT.  Each
        //    handler's kernel_reply_timeout bounds its own wait,
        //    so the drain converges naturally.
        wait_for_handlers_drain(&connection_counter, SHUTDOWN_DRAIN_TIMEOUT);

        // 5. Release the listener-facing producer handle.  On the FIFO
        //    path, with the listener clones already gone, this drops the
        //    last producer so the worker's `drain_one` returns
        //    Disconnected and exits.  On the DRR path the worker exits on
        //    `stop` (already set); the broadcast wake makes a parked
        //    worker notice it immediately rather than after the next
        //    poll timeout (§2.8).
        drop(handle);
        if let Some(fq) = fair_queue {
            fq.wake_all();
        }

        // 6. Wait for the worker to finish.
        if let Err(e) = worker.join() {
            tracing::warn!(error = ?e, "worker thread panicked");
        }

        tracing::info!("knomosis-host stopped");
    }
}

/// Poll the connection counter every 50 ms until it reaches 0 or
/// the deadline elapses.  Used during shutdown to drain in-flight
/// handler threads.
fn wait_for_handlers_drain(counter: &Arc<AtomicUsize>, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    loop {
        let active = counter.load(Ordering::Acquire);
        if active == 0 {
            return;
        }
        if Instant::now() >= deadline {
            tracing::warn!(
                active,
                "shutdown drain deadline elapsed; {} connection handler threads still active",
                active
            );
            return;
        }
        thread::sleep(Duration::from_millis(50));
    }
}

/// The worker loop.  Owns the kernel; reads requests from the
/// queue's receiver until shutdown.
///
/// ## Panic isolation
///
/// In release builds the workspace uses `panic = "abort"`, so a
/// `kernel.submit` panic terminates the entire process immediately.
/// In debug builds (the test profile) `panic = "unwind"` applies,
/// and a panic in `kernel.submit` would otherwise unwind out of the
/// worker thread, killing it.  Subsequent submissions would then
/// receive `Busy` (the disconnected-queue graceful path) — correct
/// but operator-visible as a permanent stall.
///
/// To make the worker survive transient kernel panics in debug, we
/// wrap each `submit` call in `std::panic::catch_unwind`.  On a
/// caught panic we synthesise a `NotAdmissible` response with a
/// `"kernel panicked"` reason, dispatch it back to the connection
/// handler, log the panic via `tracing::error`, and continue
/// draining.  This gives operators an accurate verdict (panic, not
/// timeout) and lets debug-build CI runs surface kernel bugs
/// without the host appearing to wedge.
fn worker_loop(
    receiver: std::sync::mpsc::Receiver<crate::queue::QueuedRequest>,
    kernel: Box<dyn Kernel>,
    stop: Arc<AtomicBool>,
) {
    let kernel_id = kernel.identifier().to_string();
    tracing::info!(kernel = %kernel_id, "worker thread up");
    let poll_timeout = Duration::from_millis(100);
    loop {
        if stop.load(Ordering::Relaxed) {
            // Drain remaining requests cooperatively before
            // exiting.  Uses non-blocking polling so we don't
            // wait for new arrivals.
            while let DrainOutcome::Dispatched =
                try_drain_one(&receiver, |bytes| catch_unwinding_submit(&*kernel, bytes))
            {
                // counted; loop until queue empty or disconnected
            }
            break;
        }
        match drain_one(&receiver, poll_timeout, |bytes| {
            catch_unwinding_submit(&*kernel, bytes)
        }) {
            DrainOutcome::Dispatched | DrainOutcome::Timeout => continue,
            DrainOutcome::Disconnected => break,
        }
    }
    tracing::info!(kernel = %kernel_id, "worker thread exited");
}

/// The fair-scheduler worker loop (FQ.4b).  Mirrors [`worker_loop`]
/// exactly (§2.8) but pulls from a [`FairQueue`] via
/// [`FairQueue::next`] / [`FairQueue::try_next`] instead of the FIFO
/// channel's `drain_one` / `try_drain_one`.
///
/// The dispatch + reply body is identical to the FIFO loop — the same
/// `catch_unwinding_submit` panic firewall followed by
/// `reply.try_send` — so both paths share one panic-isolation and
/// reply discipline.  Shutdown is owned entirely by the worker via the
/// `stop` flag: when it flips, the worker drains the remaining requests
/// non-blocking and exits.  The [`FairQueue`] holds no reference to the
/// stop flag; the server's [`FairQueue::wake_all`] only sharpens
/// shutdown latency.
fn fair_worker_loop(queue: FairQueue, kernel: Box<dyn Kernel>, stop: Arc<AtomicBool>) {
    let kernel_id = kernel.identifier().to_string();
    tracing::info!(kernel = %kernel_id, "fair worker thread up");
    let poll_timeout = Duration::from_millis(100);
    let mut last_summary = Instant::now();
    // Cumulative-activity watermark (dispatched + all rejections) at the
    // last emitted summary, so the periodic line is skipped when nothing
    // has happened — no idle-host log noise.
    let mut last_activity: u64 = 0;
    loop {
        if stop.load(Ordering::Relaxed) {
            // Stop accepting new work FIRST, so a request a handler
            // submits from here on gets a prompt `Busy` instead of
            // stranding with no worker to dispatch it (the FairQueue
            // counterpart of the FIFO path's disconnected-channel
            // rejection)...
            queue.close();
            // ...then drain everything already enqueued.  Non-blocking so
            // we never wait for new arrivals.
            while let Some(req) = queue.try_next() {
                let response = catch_unwinding_submit(&*kernel, &req.payload);
                let _ = req.reply.try_send(response);
            }
            break;
        }
        // FQ.6: periodic aggregate fairness summary (activity-gated).
        if last_summary.elapsed() >= FAIR_SUMMARY_INTERVAL {
            let stats = queue.stats();
            let activity = fair_activity(&stats);
            if activity != last_activity {
                log_fair_summary(&kernel_id, &stats, "periodic");
                last_activity = activity;
            }
            last_summary = Instant::now();
        }
        match queue.next(poll_timeout) {
            NextOutcome::Dispatch(req) => {
                let response = catch_unwinding_submit(&*kernel, &req.payload);
                let _ = req.reply.try_send(response);
            }
            NextOutcome::Idle => continue,
        }
    }
    // FQ.6: final aggregate summary on shutdown (always emitted so the
    // operator gets the lifetime tally).
    log_fair_summary(&kernel_id, &queue.stats(), "shutdown");
    tracing::info!(kernel = %kernel_id, "fair worker thread exited");
}

/// Cumulative-activity watermark for the fair scheduler: total
/// dispatches plus all cap rejections.  Used to skip the periodic
/// summary when nothing has changed.
fn fair_activity(stats: &DrrStats) -> u64 {
    stats
        .dispatched
        .saturating_add(stats.rejected_per_flow)
        .saturating_add(stats.rejected_max_flows)
        .saturating_add(stats.rejected_max_signers)
        .saturating_add(stats.rejected_global)
}

/// Emit one aggregate fair-scheduler summary line (FQ.6).  `reason`
/// distinguishes the `"periodic"` and `"shutdown"` call sites.
fn log_fair_summary(kernel_id: &str, stats: &DrrStats, reason: &'static str) {
    tracing::info!(
        kernel = %kernel_id,
        reason,
        dispatched = stats.dispatched,
        active_flows = stats.active_flows,
        active_signers = stats.active_signers,
        queued = stats.total_depth,
        rejected_per_flow = stats.rejected_per_flow,
        rejected_max_flows = stats.rejected_max_flows,
        rejected_max_signers = stats.rejected_max_signers,
        rejected_global = stats.rejected_global,
        "fair scheduler summary"
    );
}

/// Invoke `kernel.submit(bytes)` with a panic firewall.
///
/// In release builds the workspace uses `panic = "abort"`, so the
/// `catch_unwind` is a no-op (a panic aborts the process before
/// the catch sees anything).  In debug builds (the test profile)
/// it transforms a panicked `submit` call into a `NotAdmissible`
/// response with a `"kernel panicked"` reason — keeping the
/// worker alive for subsequent submissions.
///
/// `AssertUnwindSafe` is correct here: the kernel's only mutable
/// state is behind a `Mutex` (MockKernel, CommandKernel both lock
/// for every call), and our `lock().unwrap_or_else(|p|
/// p.into_inner())` poison-recovery pattern tolerates a panicked
/// lock-holder.  A panic mid-submit may leave the mutex poisoned,
/// but the next call recovers.
fn catch_unwinding_submit(kernel: &dyn Kernel, bytes: &[u8]) -> KernelResponse {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| kernel.submit(bytes))) {
        Ok(response) => response,
        Err(panic) => {
            let detail = panic_message(&panic);
            tracing::error!(
                panic = %detail,
                "kernel.submit panicked; reporting NotAdmissible"
            );
            KernelResponse::with_reason(
                crate::verdict::Verdict::NotAdmissible,
                format!("kernel panicked: {detail}"),
            )
        }
    }
}

/// Best-effort extraction of a panic payload's text content.
///
/// `Box<dyn Any + Send>` from `catch_unwind` contains either a
/// `&'static str`, a `String`, or some other arbitrary type.  We
/// downcast to the two common cases; everything else surfaces as
/// the opaque type name.
fn panic_message(panic: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = panic.downcast_ref::<&'static str>() {
        (*s).to_string()
    } else if let Some(s) = panic.downcast_ref::<String>() {
        s.clone()
    } else {
        "<non-string panic payload>".to_string()
    }
}

/// Builder for `ServerConfig`.  Validation-friendly: every
/// listener is added separately; the worker queue depth and
/// handler config are settable.
#[derive(Debug, Default)]
pub struct ServerConfigBuilder {
    max_queue_depth: Option<usize>,
    scheduler: Option<Scheduler>,
    fair_caps: Option<Caps>,
    handler: Option<HandlerConfig>,
    tcp_listener: Option<TcpListener>,
    tls_listener: Option<TlsListener>,
    #[cfg(unix)]
    unix_listener: Option<UnixListener>,
}

impl ServerConfigBuilder {
    /// Construct a default builder.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the maximum queue depth.  Default is
    /// `DEFAULT_MAX_QUEUE_DEPTH`.
    #[must_use]
    pub fn max_queue_depth(mut self, depth: usize) -> Self {
        self.max_queue_depth = Some(depth);
        self
    }

    /// Select the worker scheduler (FQ Rung 0).  Default
    /// [`Scheduler::Fifo`].
    #[must_use]
    pub fn scheduler(mut self, scheduler: Scheduler) -> Self {
        self.scheduler = Some(scheduler);
        self
    }

    /// Set the DRR capacity caps (used only under [`Scheduler::Drr`]).
    /// When unset, defaults to the documented per-flow / max-flows
    /// values with the global cap taken from `max_queue_depth`.
    #[must_use]
    pub fn fair_caps(mut self, caps: Caps) -> Self {
        self.fair_caps = Some(caps);
        self
    }

    /// Set the connection-handler config.
    #[must_use]
    pub fn handler(mut self, handler: HandlerConfig) -> Self {
        self.handler = Some(handler);
        self
    }

    /// Add a TCP listener.
    #[must_use]
    pub fn tcp(mut self, listener: TcpListener) -> Self {
        self.tcp_listener = Some(listener);
        self
    }

    /// Add a TLS-on-TCP listener.
    #[must_use]
    pub fn tls(mut self, listener: TlsListener) -> Self {
        self.tls_listener = Some(listener);
        self
    }

    /// Add a Unix-socket listener.
    #[cfg(unix)]
    #[must_use]
    pub fn unix(mut self, listener: UnixListener) -> Self {
        self.unix_listener = Some(listener);
        self
    }

    /// Build the final `ServerConfig`.  Consumes the builder.
    ///
    /// # Errors
    ///
    /// Returns `ServerBuildError::NoListeners` if no listener was
    /// configured (the server would have nothing to do).
    pub fn build(self, kernel: Box<dyn Kernel>) -> Result<ServerConfig, ServerBuildError> {
        #[cfg(unix)]
        let any_listener = self.tcp_listener.is_some()
            || self.tls_listener.is_some()
            || self.unix_listener.is_some();
        #[cfg(not(unix))]
        let any_listener = self.tcp_listener.is_some() || self.tls_listener.is_some();
        if !any_listener {
            return Err(ServerBuildError::NoListeners);
        }
        let max_queue_depth = self.max_queue_depth.unwrap_or(DEFAULT_MAX_QUEUE_DEPTH);
        // Default the DRR caps from the documented per-flow / max-flows
        // values with the global cap taken from the queue depth.
        let fair_caps = self.fair_caps.unwrap_or_else(|| {
            Caps::new(
                crate::fair::drr::DEFAULT_PER_FLOW_CAP,
                crate::fair::drr::DEFAULT_MAX_FLOWS,
                max_queue_depth,
            )
        });
        Ok(ServerConfig {
            max_queue_depth,
            scheduler: self.scheduler.unwrap_or(Scheduler::Fifo),
            fair_caps,
            handler: self.handler.unwrap_or_default(),
            tcp_listener: self.tcp_listener,
            tls_listener: self.tls_listener,
            #[cfg(unix)]
            unix_listener: self.unix_listener,
            kernel,
        })
    }
}

/// Errors during `ServerConfig` construction.
#[derive(Debug, thiserror::Error)]
pub enum ServerBuildError {
    /// No listener was configured.  The server would have nothing
    /// to do; refuse rather than silently exit.
    #[error("no listener configured; specify --listen, --tls-listen, or --unix-socket")]
    NoListeners,
}

#[cfg(test)]
mod tests {
    use super::{Server, ServerBuildError, ServerConfigBuilder};
    use crate::frame::encode_frame;
    use crate::kernel::mock::MockKernel;
    use crate::kernel::KernelResponse;
    use crate::listener::tcp::TcpListener;
    use crate::listener::HandlerConfig;
    use crate::verdict::Verdict;
    use std::io::{Read, Write};
    use std::net::TcpStream;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    /// `ServerConfigBuilder` with no listener returns
    /// `NoListeners`.
    #[test]
    fn builder_no_listeners_returns_error() {
        let kernel = Box::new(MockKernel::new());
        let result = ServerConfigBuilder::new().build(kernel);
        match result {
            Err(ServerBuildError::NoListeners) => {}
            Ok(_) => panic!("expected NoListeners, got Ok(_)"),
        }
    }

    /// `ServerConfigBuilder` with a TCP listener builds OK.
    #[test]
    fn builder_with_tcp_listener_succeeds() {
        let kernel = Box::new(MockKernel::new());
        let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let cfg = ServerConfigBuilder::new()
            .tcp(listener)
            .build(kernel)
            .unwrap();
        assert!(cfg.tcp_listener.is_some());
    }

    /// `ServerConfigBuilder::max_queue_depth` is plumbed through.
    #[test]
    fn builder_queue_depth_plumbed() {
        let kernel = Box::new(MockKernel::new());
        let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let cfg = ServerConfigBuilder::new()
            .max_queue_depth(8)
            .tcp(listener)
            .build(kernel)
            .unwrap();
        assert_eq!(cfg.max_queue_depth, 8);
    }

    /// End-to-end: spawn server on a random TCP port, submit one
    /// request, get an `Ok` verdict back.
    #[test]
    fn end_to_end_tcp_request_response() {
        // Server config.
        let kernel = Box::new(MockKernel::new());
        let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let local_addr = listener.local_addr().unwrap();
        let cfg = ServerConfigBuilder::new()
            .tcp(listener)
            .max_queue_depth(4)
            .build(kernel)
            .unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let server_stop = Arc::clone(&stop);
        let server = Server::new(cfg);
        let server_handle = std::thread::spawn(move || server.run(server_stop));

        // Give the listener a moment to be up.
        std::thread::sleep(Duration::from_millis(100));

        // Submit a request.
        let mut stream = TcpStream::connect(local_addr).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let payload = b"hello".to_vec();
        let frame = encode_frame(&payload).unwrap();
        stream.write_all(&frame).unwrap();
        stream.flush().unwrap();

        // Read the response.  Format: 1-byte verdict + 4-byte BE
        // reason length + M reason bytes.
        let mut response = Vec::new();
        stream.read_to_end(&mut response).unwrap();
        assert!(response.len() >= 5, "response too short: {response:?}");
        assert_eq!(response[0], Verdict::Ok.to_byte());
        let reason_len = u32::from_be_bytes([response[1], response[2], response[3], response[4]]);
        assert_eq!(reason_len, 0); // empty reason for default Ok

        // Shutdown.
        stop.store(true, Ordering::Relaxed);
        // Give the server time to wind down.
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if server_handle.is_finished() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        server_handle.join().expect("server join");
    }

    /// End-to-end: submit a request, MockKernel returns
    /// `NotAdmissible` with a reason; verify the reason round-trips
    /// to the client.
    #[test]
    fn end_to_end_not_admissible_with_reason() {
        let kernel = MockKernel::new();
        kernel.set_responses(vec![KernelResponse::with_reason(
            Verdict::NotAdmissible,
            "nonce mismatch",
        )]);
        let kernel = Box::new(kernel);
        let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let local_addr = listener.local_addr().unwrap();
        let cfg = ServerConfigBuilder::new()
            .tcp(listener)
            .build(kernel)
            .unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let server_stop = Arc::clone(&stop);
        let server_handle = std::thread::spawn(move || Server::new(cfg).run(server_stop));
        std::thread::sleep(Duration::from_millis(100));

        let mut stream = TcpStream::connect(local_addr).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let frame = encode_frame(b"payload").unwrap();
        stream.write_all(&frame).unwrap();
        stream.flush().unwrap();

        let mut response = Vec::new();
        stream.read_to_end(&mut response).unwrap();
        assert_eq!(response[0], Verdict::NotAdmissible.to_byte());
        let reason_len = u32::from_be_bytes([response[1], response[2], response[3], response[4]]);
        let reason = String::from_utf8_lossy(&response[5..5 + reason_len as usize]);
        assert_eq!(reason, "nonce mismatch");

        stop.store(true, Ordering::Relaxed);
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if server_handle.is_finished() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        server_handle.join().unwrap();
    }

    /// Oversize frame produces a `ParseError` response.
    #[test]
    fn end_to_end_oversize_frame_returns_parse_error() {
        let kernel = Box::new(MockKernel::new());
        let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let local_addr = listener.local_addr().unwrap();
        let handler = HandlerConfig {
            max_frame_size: 64,
            ..HandlerConfig::default()
        };
        let cfg = ServerConfigBuilder::new()
            .tcp(listener)
            .handler(handler)
            .build(kernel)
            .unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let server_stop = Arc::clone(&stop);
        let server_handle = std::thread::spawn(move || Server::new(cfg).run(server_stop));
        std::thread::sleep(Duration::from_millis(100));

        let mut stream = TcpStream::connect(local_addr).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        // Send a length-prefix claiming 200 bytes (over the 64 limit).
        stream.write_all(&200u32.to_be_bytes()).unwrap();
        // Don't send any payload — the server should reject on
        // the length check.
        stream.flush().unwrap();

        let mut response = Vec::new();
        stream.read_to_end(&mut response).unwrap();
        assert_eq!(response[0], Verdict::ParseError.to_byte());

        stop.store(true, Ordering::Relaxed);
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if server_handle.is_finished() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        server_handle.join().unwrap();
    }

    /// Multiple sequential requests on separate connections all
    /// succeed.
    #[test]
    fn multiple_sequential_requests() {
        let kernel = Box::new(MockKernel::new());
        let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let local_addr = listener.local_addr().unwrap();
        let cfg = ServerConfigBuilder::new()
            .tcp(listener)
            .max_queue_depth(8)
            .build(kernel)
            .unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let server_stop = Arc::clone(&stop);
        let server_handle = std::thread::spawn(move || Server::new(cfg).run(server_stop));
        std::thread::sleep(Duration::from_millis(100));

        for i in 0..5u8 {
            let mut stream = TcpStream::connect(local_addr).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let payload = vec![i; 10];
            let frame = encode_frame(&payload).unwrap();
            stream.write_all(&frame).unwrap();
            stream.flush().unwrap();
            let mut response = Vec::new();
            stream.read_to_end(&mut response).unwrap();
            assert_eq!(response[0], Verdict::Ok.to_byte(), "request {i} failed");
        }

        stop.store(true, Ordering::Relaxed);
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if server_handle.is_finished() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        server_handle.join().unwrap();
    }

    /// `ServerConfigBuilder::handler` plumbed through.
    #[test]
    fn builder_handler_plumbed() {
        let kernel = Box::new(MockKernel::new());
        let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let handler = HandlerConfig {
            max_frame_size: 2048,
            ..HandlerConfig::default()
        };
        let cfg = ServerConfigBuilder::new()
            .tcp(listener)
            .handler(handler)
            .build(kernel)
            .unwrap();
        assert_eq!(cfg.handler.max_frame_size, 2048);
    }
}

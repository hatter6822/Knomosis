// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G2.1b bounded persistent host-connection pool.
//!
//! A small set of persistent TCP connections to the binary host, each
//! carrying one request in-flight at a time.  A submit reuses an idle
//! connection (or opens a new one), frames the payload (G2.1a), writes
//! it, and reads the verdict.  Concurrency is capped at
//! `host_max_inflight` (an over-cap submit is rejected immediately as
//! `Saturated` → `503`); idle connections are reused up to
//! `host_pool_size`.
//!
//! **No double-submit (correctness).**  A submit is **not** idempotent —
//! re-sending an action whose write already reached the host could have
//! it processed twice (the kernel nonce blocks the *replay*, but the
//! client would then see the *second* verdict, not the first).  So the
//! pool retries on a fresh connection **only** when the **write** failed
//! (a stale idle connection the host had closed — the action never
//! reached it).  A failure **after** a successful write is surfaced
//! as-is; it is never retried.
//!
//! **Reconnect-on-drop.**  A connection is returned to the idle set only
//! after a successful round-trip; any errored connection is dropped (its
//! fd closed), so the next checkout reconnects — no fd leak under churn.

use std::io::Write;
use std::net::{SocketAddr, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use knomosis_host::verdict::VerdictResponse;

use super::client::{encode_request_frame, read_verdict_response, ResponseError};

/// Errors submitting an action to the host.  Each maps to an HTTP status
/// at the `POST /v1/actions` boundary (G2.2 / G2.3).
#[derive(Debug, thiserror::Error)]
pub enum SubmitError {
    /// The framed payload exceeds the host's hard frame cap (→ `413`).
    #[error("submit payload too large: {0}")]
    PayloadTooLarge(String),
    /// Concurrent in-flight submits hit `host_max_inflight` (→ `503`).
    #[error("host connection pool saturated")]
    Saturated,
    /// A new host connection could not be established (→ `502`).
    #[error("host connect failed: {0}")]
    Connect(String),
    /// A connect / write / read operation exceeded the deadline (→ `504`).
    #[error("host round-trip timed out")]
    Timeout,
    /// An I/O error during the request/response round-trip (→ `502`).
    #[error("host I/O failed: {0}")]
    Io(String),
    /// The host's response could not be parsed (→ `502`).
    #[error("host response invalid: {0}")]
    Response(#[from] ResponseError),
}

/// A bounded pool of persistent connections to the binary host.
#[derive(Debug)]
pub struct HostPool {
    /// The host upstream address.
    addr: SocketAddr,
    /// Maximum idle connections retained for reuse.
    pool_size: usize,
    /// Maximum concurrent in-flight submits (≤ `pool_size`).
    max_inflight: usize,
    /// Per-operation connect / read / write timeout.
    deadline: Duration,
    /// Idle connections available for reuse.
    idle: Mutex<Vec<TcpStream>>,
    /// Current in-flight submit count (the admission gate).
    in_flight: AtomicUsize,
}

impl HostPool {
    /// Build a pool for `addr` with `pool_size` persistent connections,
    /// an `max_inflight` concurrency cap, and a per-operation `deadline`.
    #[must_use]
    pub fn new(
        addr: SocketAddr,
        pool_size: usize,
        max_inflight: usize,
        deadline: Duration,
    ) -> Self {
        Self {
            addr,
            pool_size,
            max_inflight: max_inflight.min(pool_size).max(1),
            deadline,
            idle: Mutex::new(Vec::new()),
            in_flight: AtomicUsize::new(0),
        }
    }

    /// Submit a client-signed `SignedAction` payload (opaque CBE bytes)
    /// and return the host's verdict.
    ///
    /// # Errors
    ///
    /// See [`SubmitError`]: an over-cap submit is `Saturated`; framing /
    /// connect / I/O / response failures map to their variants.  A stale
    /// idle connection (write failed → the action never reached the host)
    /// is retried **once** on a fresh connection; a failure after a
    /// successful write is never retried (no double-submit).
    pub fn submit(&self, payload: &[u8]) -> Result<VerdictResponse, SubmitError> {
        let frame = encode_request_frame(payload).map_err(|e| match e {
            super::client::RequestError::TooLarge { reason } => {
                SubmitError::PayloadTooLarge(reason)
            }
        })?;
        let _permit = self.acquire_permit().ok_or(SubmitError::Saturated)?;

        // First, try an idle connection.  A WRITE-phase failure there is
        // a stale connection (the action never reached the host) → safe
        // to fall through to a fresh connection.
        if let Some(conn) = self.pop_idle() {
            match self.round_trip(conn, &frame) {
                Attempt::Done(verdict) => return Ok(verdict),
                Attempt::Retryable => {} // stale idle conn — reconnect below
                Attempt::Failed(err) => return Err(err),
            }
        }

        // A fresh connection.  Here a write failure is just an I/O error
        // (nothing to retry — a fresh connect that cannot write is down).
        let conn = self.connect()?;
        match self.round_trip(conn, &frame) {
            Attempt::Done(verdict) => Ok(verdict),
            Attempt::Retryable => Err(SubmitError::Io(
                "write to a freshly-opened host connection failed".to_string(),
            )),
            Attempt::Failed(err) => Err(err),
        }
    }

    /// Current in-flight count (for tests / metrics).
    #[must_use]
    pub fn in_flight(&self) -> usize {
        self.in_flight.load(Ordering::Relaxed)
    }

    /// Number of idle connections currently retained (for tests).
    #[must_use]
    pub fn idle_count(&self) -> usize {
        self.idle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .len()
    }

    /// One round-trip over `conn`: write the frame, then read the verdict.
    fn round_trip(&self, mut conn: TcpStream, frame: &[u8]) -> Attempt {
        // Write phase.  A *connection* failure (reset / broken pipe) means
        // the action did NOT reach the host → drop the connection and
        // retry on a fresh one.  A write *timeout*, by contrast, is
        // **ambiguous delivery** (the host may have received part of the
        // frame), so it is NOT retried — it surfaces as a 504.
        if let Err(e) = conn.write_all(frame).and_then(|()| conn.flush()) {
            if is_timeout(&e) {
                return Attempt::Failed(SubmitError::Timeout);
            }
            return Attempt::Retryable;
        }
        // Read phase.  The action HAS reached the host; a failure here is
        // NOT retryable (it may have been processed).  A read deadline is
        // a 504; any other failure is a 502.  The connection is dropped on
        // any error.
        match read_verdict_response(&mut conn) {
            Ok(verdict) => {
                self.return_conn(conn);
                Attempt::Done(verdict)
            }
            Err(ResponseError::ReadTimeout) => Attempt::Failed(SubmitError::Timeout),
            Err(err) => Attempt::Failed(SubmitError::Response(err)),
        }
    }

    /// Open a fresh connection with the configured deadlines.  A connect
    /// *timeout* is a `504`; any other connect failure is a `502`.
    fn connect(&self) -> Result<TcpStream, SubmitError> {
        let stream = TcpStream::connect_timeout(&self.addr, self.deadline).map_err(|e| {
            if is_timeout(&e) {
                SubmitError::Timeout
            } else {
                SubmitError::Connect(e.to_string())
            }
        })?;
        stream.set_read_timeout(Some(self.deadline)).ok();
        stream.set_write_timeout(Some(self.deadline)).ok();
        // Request/response is latency-sensitive and small; disable Nagle.
        stream.set_nodelay(true).ok();
        Ok(stream)
    }

    /// Pop an idle connection for reuse, if any.
    fn pop_idle(&self) -> Option<TcpStream> {
        self.idle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .pop()
    }

    /// Return a healthy connection to the idle set (dropped if the set is
    /// already at capacity — which cannot happen while in-flight ≤
    /// pool_size, but is handled defensively).
    fn return_conn(&self, stream: TcpStream) {
        let mut idle = self
            .idle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if idle.len() < self.pool_size {
            idle.push(stream);
        }
    }

    /// Acquire an in-flight permit, or `None` when the pool is saturated.
    /// Lock-free: optimistically increment, then roll back if over cap, so
    /// at most `max_inflight` permits are ever held concurrently.
    fn acquire_permit(&self) -> Option<Permit<'_>> {
        let prev = self.in_flight.fetch_add(1, Ordering::AcqRel);
        if prev >= self.max_inflight {
            self.in_flight.fetch_sub(1, Ordering::AcqRel);
            None
        } else {
            Some(Permit { pool: self })
        }
    }
}

/// Whether an I/O error represents a deadline being exceeded (a
/// `connect_timeout` / `set_read_timeout` / `set_write_timeout` firing).
fn is_timeout(e: &std::io::Error) -> bool {
    matches!(
        e.kind(),
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
    )
}

/// The outcome of one round-trip attempt (internal).
enum Attempt {
    /// A verdict was read (the connection was returned to the pool).
    Done(VerdictResponse),
    /// The write failed before the host saw the action — safe to retry
    /// once on a fresh connection.
    Retryable,
    /// A non-retryable failure (the action may have reached the host, or
    /// the response was malformed).
    Failed(SubmitError),
}

/// An in-flight permit; releases the slot on drop.
struct Permit<'a> {
    pool: &'a HostPool,
}

impl Drop for Permit<'_> {
    fn drop(&mut self) {
        self.pool.in_flight.fetch_sub(1, Ordering::AcqRel);
    }
}

#[cfg(test)]
mod tests {
    use super::{HostPool, SubmitError};
    use knomosis_host::frame::{read_frame, DEFAULT_MAX_FRAME_SIZE};
    use knomosis_host::verdict::{Verdict, VerdictResponse};
    use std::io::Write;
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    /// A mock host: accepts connections, and on each connection serves
    /// (persistently) every request frame with a fixed verdict response.
    /// Optionally sleeps before responding (to hold connections in-flight
    /// for the saturation test) and counts the connections it accepts.
    struct MockHost {
        addr: SocketAddr,
        accepted: Arc<AtomicUsize>,
        stop: Arc<AtomicBool>,
        handle: Option<thread::JoinHandle<()>>,
    }

    impl MockHost {
        fn start(verdict: Verdict, reason: &'static str, delay: Duration) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let addr = listener.local_addr().unwrap();
            let accepted = Arc::new(AtomicUsize::new(0));
            let stop = Arc::new(AtomicBool::new(false));
            let tally = Arc::clone(&accepted);
            let halt = Arc::clone(&stop);
            let handle = thread::spawn(move || {
                let mut conns = Vec::new();
                while !halt.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            tally.fetch_add(1, Ordering::Relaxed);
                            stream.set_nonblocking(false).unwrap();
                            let conn_halt = Arc::clone(&halt);
                            conns.push(thread::spawn(move || {
                                serve_conn(stream, verdict, reason, delay, &conn_halt);
                            }));
                        }
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(5));
                        }
                        Err(_) => break,
                    }
                }
                for c in conns {
                    let _ = c.join();
                }
            });
            Self {
                addr,
                accepted,
                stop,
                handle: Some(handle),
            }
        }
    }

    /// Serve one connection: read frames and reply with the verdict until
    /// the peer closes or the host stops.
    fn serve_conn(
        mut stream: TcpStream,
        verdict: Verdict,
        reason: &'static str,
        delay: Duration,
        stop: &AtomicBool,
    ) {
        stream
            .set_read_timeout(Some(Duration::from_millis(200)))
            .ok();
        loop {
            if stop.load(Ordering::Relaxed) {
                return;
            }
            match read_frame(&mut stream, DEFAULT_MAX_FRAME_SIZE) {
                Ok(_payload) => {
                    if !delay.is_zero() {
                        thread::sleep(delay);
                    }
                    let resp = VerdictResponse::with_reason(verdict, reason).encode();
                    if stream
                        .write_all(&resp)
                        .and_then(|()| stream.flush())
                        .is_err()
                    {
                        return;
                    }
                }
                // Timeout (no frame yet) → loop; any other error → the
                // peer closed, so end this connection.
                Err(_) => return,
            }
        }
    }

    impl Drop for MockHost {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(h) = self.handle.take() {
                let _ = h.join();
            }
        }
    }

    fn pool_for(host: &MockHost, pool_size: usize, max_inflight: usize) -> HostPool {
        HostPool::new(host.addr, pool_size, max_inflight, Duration::from_secs(2))
    }

    #[test]
    fn round_trips_and_reuses_one_connection() {
        let host = MockHost::start(Verdict::Ok, "", Duration::ZERO);
        let pool = pool_for(&host, 4, 4);
        // Several sequential submits reuse the single idle connection.
        for _ in 0..5 {
            let v = pool.submit(b"action").expect("verdict");
            assert_eq!(v.verdict, Verdict::Ok);
        }
        assert_eq!(pool.in_flight(), 0);
        assert_eq!(pool.idle_count(), 1, "one connection reused");
        // The host accepted exactly one connection (true reuse).
        assert_eq!(host.accepted.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn reason_round_trips() {
        let host = MockHost::start(Verdict::NotAdmissible, "InsufficientBudget", Duration::ZERO);
        let pool = pool_for(&host, 2, 2);
        let v = pool.submit(b"a").expect("verdict");
        assert_eq!(v.verdict, Verdict::NotAdmissible);
        assert_eq!(v.reason, "InsufficientBudget");
    }

    #[test]
    fn read_deadline_maps_to_timeout() {
        // The host accepts + reads the frame but delays its response past
        // the pool's read deadline → a 504-class `Timeout` (not retried,
        // not a 502).
        let host = MockHost::start(Verdict::Ok, "", Duration::from_millis(400));
        let pool = HostPool::new(host.addr, 2, 2, Duration::from_millis(100));
        let r = pool.submit(b"action");
        assert!(matches!(r, Err(SubmitError::Timeout)), "got {r:?}");
        assert_eq!(pool.in_flight(), 0, "the permit is released on timeout");
    }

    #[test]
    fn connect_failure_is_mapped() {
        // Bind then drop a listener to get an address nothing listens on.
        let probe = TcpListener::bind("127.0.0.1:0").unwrap();
        let dead: SocketAddr = probe.local_addr().unwrap();
        drop(probe);
        let pool = HostPool::new(dead, 2, 2, Duration::from_millis(200));
        assert!(matches!(
            pool.submit(b"a"),
            Err(SubmitError::Connect(_) | SubmitError::Io(_))
        ));
        assert_eq!(pool.in_flight(), 0, "the permit is released on failure");
    }

    #[test]
    fn saturation_returns_saturated() {
        // A slow host holds each connection in-flight; with max_inflight=1
        // a concurrent second submit is rejected.
        let host = MockHost::start(Verdict::Ok, "", Duration::from_millis(300));
        let pool = Arc::new(pool_for(&host, 2, 1));
        let p2 = Arc::clone(&pool);
        // Thread A occupies the single in-flight slot.
        let a = thread::spawn(move || p2.submit(b"slow"));
        // Give A time to acquire the permit and block in the host delay.
        thread::sleep(Duration::from_millis(80));
        // Thread B is rejected as saturated.
        let b = pool.submit(b"fast");
        assert!(matches!(b, Err(SubmitError::Saturated)), "got {b:?}");
        assert!(a.join().unwrap().is_ok());
        assert_eq!(pool.in_flight(), 0);
    }

    #[test]
    fn reconnects_after_host_drops_idle_connection() {
        // First submit opens + pools a connection.
        let host = MockHost::start(Verdict::Ok, "", Duration::ZERO);
        let pool = pool_for(&host, 2, 2);
        assert!(pool.submit(b"a").is_ok());
        assert_eq!(pool.idle_count(), 1);
        // Restart the host on the SAME port is not portable; instead,
        // simulate a stale idle connection by shutting it down directly.
        {
            let idle = pool.pop_idle().expect("one idle");
            idle.shutdown(std::net::Shutdown::Both).ok();
            pool.return_conn(idle); // put the now-dead connection back
        }
        // The next submit finds the stale connection's write fails, then
        // transparently reconnects and succeeds (no double-submit: the
        // stale write never reached the host).
        let v = pool.submit(b"b").expect("verdict after reconnect");
        assert_eq!(v.verdict, Verdict::Ok);
        // Two connections accepted total (the original + the reconnect).
        assert_eq!(host.accepted.load(Ordering::Relaxed), 2);
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Listener implementations for `knomosis-host`.
//!
//! Three listener variants share a common request/response cycle:
//!
//!   * [`tcp::TcpListener`] — plain TCP, suitable for local /
//!     trusted-network deployments.
//!   * [`tls::TlsListener`] — TCP + `rustls` termination.  Layer
//!     on top of TCP; requires a `TlsConfig` (`docs/abi.md` §10
//!     recommends TLS 1.3+).
//!   * [`unix::UnixListener`] — Unix domain socket, suitable for
//!     localhost-only deployments (the L1 ingestor co-located on
//!     the same host, for example).  Permission-protected at the
//!     filesystem layer (mode 0600).
//!
//! ## Connection lifecycle
//!
//! Each accepted connection runs in its own `std::thread`:
//!
//!   1. Read one wire frame via [`crate::frame::read_frame`].
//!   2. Try to submit to the [`crate::queue::BoundedQueue`].
//!   3. If queue is full: respond `Busy` immediately, close.
//!   4. Otherwise: block on the reply channel (capacity 1).
//!   5. Write the response via [`crate::verdict::VerdictResponse::encode`].
//!   6. Close the connection.
//!
//! Single-shot per connection.  HTTP-style — simpler than
//! persistent-connection multiplexing, and matches the plan's
//! §RH-C.3 "HTTP-style one-shot is also acceptable, simpler".

use std::io::{Read, Write};
use std::time::Duration;

use crate::frame::{read_frame, FrameError};
use crate::queue::{ConnId, QueueHandle, SubmitOutcome};
use crate::verdict::{Verdict, VerdictResponse};

/// Default read / write timeout per connection.  10 seconds is
/// generous — a slow client sending one byte every 9.9 seconds
/// stays under the timeout, but a malicious "slow-loris" client
/// is bounded.
pub const DEFAULT_CONNECTION_TIMEOUT: Duration = Duration::from_secs(10);

/// Maximum time the connection handler will block waiting for the
/// kernel's reply.  Bounded so a wedged kernel doesn't hold
/// connection threads indefinitely.
pub const DEFAULT_KERNEL_REPLY_TIMEOUT: Duration = Duration::from_secs(60);

/// Default cap on the number of simultaneously-active connection
/// handler threads (across all listeners).  Defends against the
/// spawn-storm DoS where an attacker opens N TCP connections in
/// parallel to exhaust the host's thread / FD budget.  When the
/// limit is hit, the listener writes a `Busy` verdict to the
/// new connection and closes immediately rather than spawning
/// another thread.
///
/// Default sized to 4× the default queue depth (`256`) so a
/// healthy worker can keep up under load.  Operators tune via
/// `--max-concurrent-connections`.
pub const DEFAULT_MAX_CONCURRENT_CONNECTIONS: usize = 1024;

/// Hard ceiling on operator-configurable concurrent connections.
/// Above this the operator is doing something unusual — at 1 MiB
/// frame size, 65 536 simultaneous handlers could hold up to
/// 64 GiB of resident buffers.
pub const HARD_MAX_CONCURRENT_CONNECTIONS: usize = 65_536;

/// Shared connection-handler parameters.  Each connection thread
/// reads frames according to these limits and dispatches via the
/// shared `BoundedQueue`.
#[derive(Clone, Debug)]
pub struct HandlerConfig {
    /// Maximum frame size accepted from the client.  Forwarded to
    /// [`crate::frame::read_frame`].
    pub max_frame_size: usize,
    /// Read / write timeout for the underlying socket.
    pub connection_timeout: Duration,
    /// Maximum time to wait for the kernel's reply before
    /// responding `NotAdmissible` with a "timeout" reason.
    pub kernel_reply_timeout: Duration,
    /// Maximum simultaneously-active connection handler threads.
    /// New connections beyond this limit receive `Busy` and the
    /// socket is closed immediately.
    pub max_concurrent_connections: usize,
}

impl Default for HandlerConfig {
    fn default() -> Self {
        Self {
            max_frame_size: crate::frame::DEFAULT_MAX_FRAME_SIZE,
            connection_timeout: DEFAULT_CONNECTION_TIMEOUT,
            kernel_reply_timeout: DEFAULT_KERNEL_REPLY_TIMEOUT,
            max_concurrent_connections: DEFAULT_MAX_CONCURRENT_CONNECTIONS,
        }
    }
}

/// A counted slot in the connection limiter.  Increments the
/// shared atomic counter on construction; decrements on drop.
/// Used as a RAII guard around the per-connection handler
/// thread so a panic anywhere in the handler still releases the
/// slot.
pub struct ConnectionSlot {
    counter: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

impl ConnectionSlot {
    /// Try to acquire a slot.  Returns `Some(slot)` on success or
    /// `None` if the active count already hit the cap.  This is
    /// the load-bearing DoS defence: when full, the listener
    /// responds `Busy` immediately without spawning a thread.
    ///
    /// `cap` is internally clamped to [`HARD_MAX_CONCURRENT_CONNECTIONS`]
    /// (defence-in-depth against library consumers constructing a
    /// `HandlerConfig` with `max_concurrent_connections = usize::MAX`,
    /// which would disable the protection entirely).  CLI-supplied
    /// values reach this function pre-clamped via `Config::validate`.
    ///
    /// Uses an atomic CAS so concurrent attempts on multiple
    /// listener threads stay coherent.
    pub fn try_acquire(
        counter: &std::sync::Arc<std::sync::atomic::AtomicUsize>,
        cap: usize,
    ) -> Option<Self> {
        use std::sync::atomic::Ordering;
        // Defence-in-depth clamp.  Parallel to `frame::read_frame`'s
        // `HARD_MAX_FRAME_SIZE` clamp.  Library consumers that
        // construct `HandlerConfig` directly cannot bypass.
        let cap = cap.min(HARD_MAX_CONCURRENT_CONNECTIONS);
        let mut current = counter.load(Ordering::Relaxed);
        loop {
            if current >= cap {
                return None;
            }
            match counter.compare_exchange_weak(
                current,
                current + 1,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Ok(_) => {
                    return Some(Self {
                        counter: std::sync::Arc::clone(counter),
                    })
                }
                Err(observed) => current = observed,
            }
        }
    }

    /// Active count snapshot.  Diagnostic only.
    pub fn active_count(counter: &std::sync::Arc<std::sync::atomic::AtomicUsize>) -> usize {
        counter.load(std::sync::atomic::Ordering::Relaxed)
    }
}

impl Drop for ConnectionSlot {
    fn drop(&mut self) {
        // Release the slot.  Use `Release` ordering so the slot's
        // associated state (the connection handler's work) is
        // ordered-before the decrement, matching the `Acquire` at
        // try_acquire.
        self.counter
            .fetch_sub(1, std::sync::atomic::Ordering::Release);
    }
}

/// Exponential backoff for persistent accept errors (e.g. EMFILE
/// / file-descriptor exhaustion).  Defends against the
/// busy-spin DoS where a listener thread retries `accept` at
/// 10× per second on a permanent error.
///
/// Sleep durations: 100 ms × 2^min(errors, 5), capped at 3.2 s.
/// Returns once the sleep completes; the caller's next iteration
/// will re-check the stop flag.
fn backoff_on_accept_error(consecutive_errors: u32) {
    let exp = consecutive_errors.saturating_sub(1).min(5);
    let ms = 100u64 << exp;
    std::thread::sleep(Duration::from_millis(ms));
}

/// Outcome of one [`handle_connection`] invocation.
///
/// Distinguishes between the operator-observable cases so the
/// per-listener wrappers can log accurately.  The wire-format
/// `Verdict` enum is bound to the response byte (`0..=3`); this
/// enum is broader because there are connection-level outcomes
/// that don't correspond to any single verdict byte (e.g. the
/// client closing cleanly before sending a frame).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HandleOutcome {
    /// A request was processed and the supplied verdict written
    /// to the client.
    Responded(Verdict),
    /// The client closed the connection cleanly before sending
    /// a request frame.  No response was owed.  This is the
    /// normal "client went away" case; not an error.
    ClientClosedBeforeRequest,
}

impl HandleOutcome {
    /// Human-readable name for log spans.  Stable; do not change
    /// without a `tracing` consumer update.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Responded(v) => v.name(),
            Self::ClientClosedBeforeRequest => "client_closed_before_request",
        }
    }
}

/// Run a single request/response cycle on an established
/// readable+writable stream.
///
/// Returns the outcome (verdict written, or client closed cleanly)
/// so the caller can log accurately.  The function closes the
/// response cycle on its own; the caller is responsible for
/// closing the stream after this function returns.
///
/// Used by all three listener variants (TCP, TLS, Unix) — the
/// stream abstraction is `impl Read + Write` so each variant can
/// pass its native socket type.
///
/// `conn_id` is the connection's monotonic [`ConnId`] (FQ.3).  It is
/// forwarded to [`QueueHandle::submit`] as the DRR routing key; the
/// FIFO arm ignores it, so the FIFO path is byte-for-byte unchanged.
/// The id is a *classification* hint only and never affects
/// admissibility (`GP.8` §2.6 invariant 1).
pub fn handle_connection<S: Read + Write>(
    stream: &mut S,
    handle: &QueueHandle,
    config: &HandlerConfig,
    conn_id: ConnId,
) -> HandleOutcome {
    // 1. Read the request frame.
    let payload = match read_frame(stream, config.max_frame_size) {
        Ok(p) => p,
        Err(FrameError::EofBeforeHeader) => {
            // Clean close before a frame arrived.  No response
            // owed; just bail.
            tracing::debug!("client closed before sending frame");
            return HandleOutcome::ClientClosedBeforeRequest;
        }
        Err(e) => {
            // Any other frame error → respond `ParseError` if we
            // can.  Failure to write the response is logged at
            // debug; the connection will close anyway.
            tracing::debug!(error = ?e, "frame read failure");
            let response =
                VerdictResponse::with_reason(Verdict::ParseError, format!("frame read: {e}"));
            let _ = stream.write_all(&response.encode());
            let _ = stream.flush();
            return HandleOutcome::Responded(Verdict::ParseError);
        }
    };

    // 2. Try to submit through the scheduler-agnostic queue handle.
    //    The connection id is the DRR routing key (ignored by FIFO).
    let reply_rx = match handle.submit(conn_id, payload) {
        SubmitOutcome::Enqueued(rx) => rx,
        SubmitOutcome::Busy => {
            // Queue full → respond Busy.
            tracing::debug!("queue full; responding busy");
            let response = VerdictResponse::from_verdict(Verdict::Busy);
            let _ = stream.write_all(&response.encode());
            let _ = stream.flush();
            return HandleOutcome::Responded(Verdict::Busy);
        }
    };

    // 3. Block on the kernel reply (bounded by
    //    `kernel_reply_timeout`).
    let response = match reply_rx.recv_timeout(config.kernel_reply_timeout) {
        Ok(r) => r,
        Err(_) => {
            // Timeout or disconnected.  Either way: tell the
            // client the kernel didn't respond.  We use
            // NotAdmissible rather than a new "kernel timeout"
            // verdict because the wire-format is fixed at
            // RH-C.1; adding a new verdict requires a protocol
            // bump.
            tracing::warn!("kernel did not reply within deadline");
            VerdictResponse::with_reason(Verdict::NotAdmissible, "kernel timeout")
        }
    };

    // 4. Write the response.  Errors are logged but otherwise
    //    swallowed — the client may have disconnected.
    let verdict = response.verdict;
    let bytes = response.encode();
    if let Err(e) = stream.write_all(&bytes) {
        tracing::debug!(error = ?e, "failed to write response");
        return HandleOutcome::Responded(verdict);
    }
    if let Err(e) = stream.flush() {
        tracing::debug!(error = ?e, "failed to flush response");
    }
    HandleOutcome::Responded(verdict)
}

/// Plain TCP listener.
pub mod tcp {
    use std::io::Write;
    use std::net::{TcpListener as StdTcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;

    use crate::queue::{ConnId, QueueHandle};
    use crate::verdict::{Verdict, VerdictResponse};

    use super::{backoff_on_accept_error, handle_connection, ConnectionSlot, HandlerConfig};

    /// A plain TCP listener.
    ///
    /// `accept_loop` blocks until `stop` flips to true, accepting
    /// connections and spawning a handler thread per connection
    /// up to the configured `max_concurrent_connections`.
    #[derive(Debug)]
    pub struct TcpListener {
        inner: StdTcpListener,
    }

    impl TcpListener {
        /// Bind to `addr` and prepare to accept connections.
        ///
        /// # Errors
        ///
        /// Surfaces `std::io::Error` from the OS bind.
        pub fn bind(addr: std::net::SocketAddr) -> std::io::Result<Self> {
            let inner = StdTcpListener::bind(addr)?;
            inner.set_nonblocking(true)?;
            Ok(Self { inner })
        }

        /// The local address the listener is bound to.  After
        /// binding to `:0`, this reflects the OS-assigned port.
        pub fn local_addr(&self) -> std::io::Result<std::net::SocketAddr> {
            self.inner.local_addr()
        }

        /// Run the accept loop.  Blocks the calling thread until
        /// `stop` is set.  Each accepted connection runs
        /// [`super::handle_connection`] on its own thread, gated by
        /// the shared `connection_counter` against
        /// `config.max_concurrent_connections`.
        ///
        /// `conn_seq` is the process-wide monotonic [`ConnId`] source
        /// (FQ.3): each accepted connection takes the next id and
        /// threads it to the submit call (the DRR routing key).
        pub fn accept_loop(
            &self,
            handle: QueueHandle,
            config: HandlerConfig,
            stop: Arc<AtomicBool>,
            connection_counter: Arc<AtomicUsize>,
            conn_seq: Arc<AtomicU64>,
        ) {
            let mut consecutive_errors = 0u32;
            while !stop.load(Ordering::Relaxed) {
                match self.inner.accept() {
                    Ok((stream, peer)) => {
                        consecutive_errors = 0;
                        // Try to acquire a connection slot.  If the
                        // limit is hit, respond Busy and close
                        // immediately rather than spawning.
                        match ConnectionSlot::try_acquire(
                            &connection_counter,
                            config.max_concurrent_connections,
                        ) {
                            Some(slot) => {
                                let conn_id = crate::queue::assign_conn_id(&conn_seq);
                                let handle = handle.clone();
                                let config = config.clone();
                                thread::spawn(move || {
                                    handle_single_connection(
                                        stream, peer, handle, config, slot, conn_id,
                                    );
                                });
                            }
                            None => {
                                // Spawn a tiny inline writer so we
                                // don't block the accept loop on
                                // the slow client.  Acceptable: the
                                // write is a fixed 5-byte response.
                                tracing::warn!(
                                    peer = %peer,
                                    "max_concurrent_connections reached; responding Busy"
                                );
                                let mut stream = stream;
                                let _ = stream.set_write_timeout(Some(config.connection_timeout));
                                let bytes = VerdictResponse::from_verdict(Verdict::Busy).encode();
                                let _ = stream.write_all(&bytes);
                                let _ = stream.flush();
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        consecutive_errors = 0;
                        // No connection ready; sleep briefly and re-check stop.
                        thread::sleep(std::time::Duration::from_millis(50));
                    }
                    Err(e) => {
                        consecutive_errors = consecutive_errors.saturating_add(1);
                        tracing::warn!(
                            error = ?e,
                            consecutive_errors,
                            "TCP accept failed"
                        );
                        backoff_on_accept_error(consecutive_errors);
                    }
                }
            }
        }
    }

    fn handle_single_connection(
        mut stream: TcpStream,
        peer: std::net::SocketAddr,
        handle: QueueHandle,
        config: HandlerConfig,
        _slot: ConnectionSlot,
        conn_id: ConnId,
    ) {
        // _slot is held for the lifetime of this function; the
        // RAII Drop releases the connection-counter slot when
        // the handler exits, regardless of panic / early return.
        let _ = stream.set_read_timeout(Some(config.connection_timeout));
        let _ = stream.set_write_timeout(Some(config.connection_timeout));
        let span = tracing::info_span!("conn", proto = "tcp", peer = %peer, conn = conn_id);
        let _enter = span.enter();
        let outcome = handle_connection(&mut stream, &handle, &config, conn_id);
        tracing::info!(outcome = outcome.name(), "request handled");
    }
}

/// TLS-on-TCP listener.  Layered on top of [`tcp::TcpListener`]
/// with `rustls` termination.
pub mod tls {
    use std::net::{TcpListener as StdTcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;

    use rustls::{ServerConfig, ServerConnection, StreamOwned};

    use crate::queue::{ConnId, QueueHandle};

    use super::{backoff_on_accept_error, handle_connection, ConnectionSlot, HandlerConfig};

    /// A TLS-on-TCP listener.
    #[derive(Debug)]
    pub struct TlsListener {
        inner: StdTcpListener,
        tls_config: Arc<ServerConfig>,
    }

    impl TlsListener {
        /// Bind to `addr` with the supplied TLS server config.
        ///
        /// # Errors
        ///
        /// Surfaces `std::io::Error` from the OS bind.
        pub fn bind(
            addr: std::net::SocketAddr,
            tls_config: Arc<ServerConfig>,
        ) -> std::io::Result<Self> {
            let inner = StdTcpListener::bind(addr)?;
            inner.set_nonblocking(true)?;
            Ok(Self { inner, tls_config })
        }

        /// The local address the listener is bound to.
        pub fn local_addr(&self) -> std::io::Result<std::net::SocketAddr> {
            self.inner.local_addr()
        }

        /// Run the accept loop.  Blocks the calling thread until
        /// `stop` is set.
        ///
        /// `conn_seq` is the process-wide monotonic [`ConnId`] source
        /// (FQ.3), shared across all listeners.
        pub fn accept_loop(
            &self,
            handle: QueueHandle,
            config: HandlerConfig,
            stop: Arc<AtomicBool>,
            connection_counter: Arc<AtomicUsize>,
            conn_seq: Arc<AtomicU64>,
        ) {
            let mut consecutive_errors = 0u32;
            while !stop.load(Ordering::Relaxed) {
                match self.inner.accept() {
                    Ok((stream, peer)) => {
                        consecutive_errors = 0;
                        match ConnectionSlot::try_acquire(
                            &connection_counter,
                            config.max_concurrent_connections,
                        ) {
                            Some(slot) => {
                                let conn_id = crate::queue::assign_conn_id(&conn_seq);
                                let handle = handle.clone();
                                let config = config.clone();
                                let tls_config = Arc::clone(&self.tls_config);
                                thread::spawn(move || {
                                    handle_tls_connection(
                                        stream, peer, handle, config, tls_config, slot, conn_id,
                                    );
                                });
                            }
                            None => {
                                tracing::warn!(
                                    peer = %peer,
                                    "TLS: max_concurrent_connections reached; closing without TLS \
                                     handshake"
                                );
                                // Writing the plaintext Busy
                                // verdict to a TLS-expecting client
                                // is not meaningful (they'd parse
                                // it as TLS bytes); close the
                                // connection without writing
                                // anything.  Clients see this as
                                // an immediate close + retry-with-
                                // backoff at the TLS layer.
                                let _ = stream.shutdown(std::net::Shutdown::Both);
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        consecutive_errors = 0;
                        thread::sleep(std::time::Duration::from_millis(50));
                    }
                    Err(e) => {
                        consecutive_errors = consecutive_errors.saturating_add(1);
                        tracing::warn!(error = ?e, consecutive_errors, "TLS accept failed");
                        backoff_on_accept_error(consecutive_errors);
                    }
                }
            }
        }
    }

    fn handle_tls_connection(
        stream: TcpStream,
        peer: std::net::SocketAddr,
        handle: QueueHandle,
        config: HandlerConfig,
        tls_config: Arc<ServerConfig>,
        _slot: ConnectionSlot,
        conn_id: ConnId,
    ) {
        // _slot RAII releases the connection-counter slot.
        let _ = stream.set_read_timeout(Some(config.connection_timeout));
        let _ = stream.set_write_timeout(Some(config.connection_timeout));
        // Required to switch the socket back to blocking mode for
        // the synchronous `rustls::StreamOwned` adapter.
        let _ = stream.set_nonblocking(false);
        let span = tracing::info_span!("conn", proto = "tls", peer = %peer, conn = conn_id);
        let _enter = span.enter();
        // Build the TLS connection.  ServerConnection::new only
        // fails on `rustls` mis-configuration (impossible if the
        // ServerConfig was built via TlsConfigBuilder).
        let connection = match ServerConnection::new(tls_config) {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!(error = ?e, "TLS connection setup failed");
                return;
            }
        };
        let mut tls_stream = StreamOwned::new(connection, stream);
        let outcome = handle_connection(&mut tls_stream, &handle, &config, conn_id);
        tracing::info!(outcome = outcome.name(), "request handled");
    }
}

/// Unix-socket listener.  Conditionally compiled for Unix; Windows
/// support is out of scope for RH-C (the L1 ingestor and other
/// Knomosis binaries also assume Unix).
#[cfg(unix)]
pub mod unix {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener as StdUnixListener, UnixStream};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;

    use crate::queue::{ConnId, QueueHandle};
    use crate::verdict::{Verdict, VerdictResponse};

    use super::{backoff_on_accept_error, handle_connection, ConnectionSlot, HandlerConfig};

    /// A Unix-socket listener.
    ///
    /// Socket file is created with mode `0600` (owner read/write
    /// only) so a non-root local user cannot access the daemon's
    /// IPC channel.
    ///
    /// ## TOCTOU race window
    ///
    /// `std::os::unix::net::UnixListener::bind` creates the socket
    /// file with the calling process's umask applied (typically
    /// `0666 & ~umask`, i.e. `0644` for the default umask `0022`).
    /// We tighten to `0600` via `set_permissions` immediately after
    /// `bind` returns, but a microsecond-wide race window exists in
    /// which a fast local attacker could connect to the
    /// world-writable socket.  The kernel's accept queue would hold
    /// the attacker's connection until our `accept_loop` dequeued
    /// it.
    ///
    /// **Operator mitigation.**  Two complementary defences:
    ///
    ///   1. **Restrict the parent directory.**  Place the socket
    ///      inside a directory with mode `0700` (owner-only).  Even
    ///      if the socket file itself is briefly world-writable, a
    ///      non-root attacker cannot traverse the parent directory
    ///      to reach it.  Example:
    ///      ```text
    ///      install -d -m 0700 -o knomosis /var/run/knomosis
    ///      knomosis-host --unix-socket /var/run/knomosis/host.sock
    ///      ```
    ///
    ///   2. **Set the process umask.**  Invoke `knomosis-host` with
    ///      `umask 0177` so the kernel-created socket inherits
    ///      `0600` directly, eliminating the race window:
    ///      ```text
    ///      umask 0177
    ///      knomosis-host --unix-socket /var/run/knomosis.sock
    ///      ```
    ///
    /// A future improvement would call `libc::umask` around the
    /// `bind` to set the umask programmatically, but that requires
    /// `unsafe` which the workspace forbids.  See the comment on
    /// `bind` for the rationale.
    #[derive(Debug)]
    pub struct UnixListener {
        inner: StdUnixListener,
        path: PathBuf,
    }

    impl UnixListener {
        /// Bind to a filesystem path and prepare to accept
        /// connections.
        ///
        /// If `path` exists already (a leftover socket from a
        /// previous run), it is removed before binding.  This
        /// matches the canonical Unix-daemon discipline.
        ///
        /// ## Race-window note
        ///
        /// See the [`UnixListener`] struct-level docstring for the
        /// TOCTOU race between `bind` and `set_permissions`.
        /// Operators MUST mitigate via a restricted parent
        /// directory (preferred) or a process-level umask of `0177`.
        ///
        /// # Errors
        ///
        /// Surfaces `std::io::Error` from the OS unlink (if any)
        /// + bind.
        pub fn bind(path: impl AsRef<Path>) -> std::io::Result<Self> {
            let path = path.as_ref().to_path_buf();
            // Remove any stale socket file.  If the file doesn't
            // exist that's fine; surfaces a real error if it's a
            // non-socket file (avoiding accidental deletion of an
            // operator's data).
            match std::fs::metadata(&path) {
                Ok(meta) => {
                    // Refuse to unlink a regular file at the socket
                    // path — could be an operator's data file by
                    // accident.  Only remove if the existing entry
                    // is a Unix-domain socket.
                    use std::os::unix::fs::FileTypeExt;
                    if !meta.file_type().is_socket() {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::AlreadyExists,
                            format!("path {path:?} exists and is not a Unix socket"),
                        ));
                    }
                    std::fs::remove_file(&path)?;
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
            let inner = StdUnixListener::bind(&path)?;
            // Tighten permissions FIRST (best-effort against the
            // race documented on the struct).  Even though the
            // kernel-created socket might briefly be 0644, narrowing
            // before set_nonblocking + accept_loop start dequeueing
            // connections gives the smallest possible exposure.
            let perms = std::fs::Permissions::from_mode(0o600);
            std::fs::set_permissions(&path, perms)?;
            // Now switch to non-blocking mode so the accept_loop
            // can poll cooperatively.
            inner.set_nonblocking(true)?;
            Ok(Self { inner, path })
        }

        /// The filesystem path the socket is bound to.
        pub fn path(&self) -> &Path {
            &self.path
        }

        /// Run the accept loop.  Blocks the calling thread until
        /// `stop` is set.
        ///
        /// `conn_seq` is the process-wide monotonic [`ConnId`] source
        /// (FQ.3), shared across all listeners.
        pub fn accept_loop(
            &self,
            handle: QueueHandle,
            config: HandlerConfig,
            stop: Arc<AtomicBool>,
            connection_counter: Arc<AtomicUsize>,
            conn_seq: Arc<AtomicU64>,
        ) {
            let mut consecutive_errors = 0u32;
            while !stop.load(Ordering::Relaxed) {
                match self.inner.accept() {
                    Ok((stream, _peer)) => {
                        consecutive_errors = 0;
                        match ConnectionSlot::try_acquire(
                            &connection_counter,
                            config.max_concurrent_connections,
                        ) {
                            Some(slot) => {
                                let conn_id = crate::queue::assign_conn_id(&conn_seq);
                                let handle = handle.clone();
                                let config = config.clone();
                                thread::spawn(move || {
                                    handle_single_unix_connection(
                                        stream, handle, config, slot, conn_id,
                                    );
                                });
                            }
                            None => {
                                tracing::warn!(
                                    "Unix: max_concurrent_connections reached; responding Busy"
                                );
                                let mut stream = stream;
                                let _ = stream.set_write_timeout(Some(config.connection_timeout));
                                let bytes = VerdictResponse::from_verdict(Verdict::Busy).encode();
                                let _ = stream.write_all(&bytes);
                                let _ = stream.flush();
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        consecutive_errors = 0;
                        thread::sleep(std::time::Duration::from_millis(50));
                    }
                    Err(e) => {
                        consecutive_errors = consecutive_errors.saturating_add(1);
                        tracing::warn!(error = ?e, consecutive_errors, "Unix accept failed");
                        backoff_on_accept_error(consecutive_errors);
                    }
                }
            }
        }
    }

    impl Drop for UnixListener {
        fn drop(&mut self) {
            // Best-effort cleanup; failure is logged at debug.
            // Operators relying on socket-file persistence across
            // restarts should arrange for it externally.
            if let Err(e) = std::fs::remove_file(&self.path) {
                if e.kind() != std::io::ErrorKind::NotFound {
                    tracing::debug!(path = ?self.path, error = ?e, "could not remove socket");
                }
            }
        }
    }

    fn handle_single_unix_connection(
        mut stream: UnixStream,
        handle: QueueHandle,
        config: HandlerConfig,
        _slot: ConnectionSlot,
        conn_id: ConnId,
    ) {
        // _slot RAII releases the connection-counter slot.
        let _ = stream.set_read_timeout(Some(config.connection_timeout));
        let _ = stream.set_write_timeout(Some(config.connection_timeout));
        let span = tracing::info_span!("conn", proto = "unix", conn = conn_id);
        let _enter = span.enter();
        let outcome = handle_connection(&mut stream, &handle, &config, conn_id);
        tracing::info!(outcome = outcome.name(), "request handled");
    }
}

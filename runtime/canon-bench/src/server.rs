// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! In-process `knomosis-host` helper for `--standalone` benchmark mode.
//!
//! ## What this provides
//!
//! [`StandaloneServer`] bundles a knomosis-host instance and its stop
//! flag.  Construction:
//!
//!   1. Bind a listener (Unix-socket OR TCP) on an
//!      operator-supplied address / path.
//!   2. Build a [`canon_host::server::Server`] with a
//!      [`canon_host::kernel::mock::MockKernel`].
//!   3. Spawn the server on a background thread.
//!
//! ## Shutdown discipline
//!
//! Two lifecycle paths:
//!
//!   * [`StandaloneServer::stop`] — explicit, bounded.  Flips the
//!     stop flag, polls `JoinHandle::is_finished()` every 50 ms
//!     until either the thread exits or the caller-supplied
//!     `timeout` elapses.  Returns `Err(JoinTimedOut)` on timeout.
//!     Recommended for tests and production benchmark code that
//!     wants a deterministic shutdown.
//!   * `Drop` — best-effort, non-blocking.  Sets the stop flag and
//!     returns immediately.  Does **not** join the background
//!     thread (joining from `Drop` risks deadlock if the dropping
//!     thread also owns the handle).  Suitable for the benchmark
//!     binary's exit path (the OS reclaims the thread on process
//!     termination).
//!
//! Callers wanting a deterministic shutdown MUST call
//! [`StandaloneServer::stop`] explicitly before dropping.
//!
//! ## Why MockKernel
//!
//! Per the plan §RH-F, the benchmark target is `knomosis-host`'s
//! end-to-end throughput.  MockKernel returns `Ok` for every
//! submission in O(µs); this isolates the host's framing / queue /
//! worker overhead from the kernel's per-action work.  Benchmarks
//! against a real Lean kernel are a follow-up (the harness's
//! `--connect <ADDR>` mode supports it directly).
//!
//! ## Concurrency model
//!
//! The standalone server uses knomosis-host's stock orchestration: one
//! listener thread + one worker thread.  Queue depth is supplied to
//! [`StandaloneServer::spawn_unix`] / [`StandaloneServer::spawn_tcp`]
//! at construction; there is no post-construction setter.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use canon_host::kernel::mock::MockKernel;
use canon_host::listener::HandlerConfig;
use canon_host::server::{Server, ServerConfigBuilder};

#[cfg(unix)]
use canon_host::listener::unix::UnixListener;

use canon_host::listener::tcp::TcpListener;

/// Errors surfaced by standalone server construction.
#[derive(Debug, thiserror::Error)]
pub enum StandaloneServerError {
    /// The Unix-socket bind failed.
    #[cfg(unix)]
    #[error("unix-socket bind failed at {path:?}: {source}")]
    UnixBind {
        /// The path the bind targeted.
        path: PathBuf,
        /// The underlying I/O error.
        #[source]
        source: std::io::Error,
    },
    /// The TCP bind failed.
    #[error("tcp bind failed at {addr}: {source}")]
    TcpBind {
        /// The address the bind targeted.
        addr: std::net::SocketAddr,
        /// The underlying I/O error.
        #[source]
        source: std::io::Error,
    },
    /// The server's `ServerConfigBuilder.build()` failed.
    #[error("server config build failed: {0}")]
    Build(String),
    /// Background-thread spawn failed (typically `EAGAIN` /
    /// `ENOMEM` under sustained load).  Matches the knomosis-host
    /// audit-pass-2 C-NEW-3 fix.
    #[error("server thread spawn failed: {0}")]
    SpawnFailed(#[source] std::io::Error),
}

/// A self-contained `knomosis-host` instance plus the lifecycle handle
/// to stop it.
///
/// Dropping a `StandaloneServer` does NOT block on the worker
/// thread (Rust's `Drop` would deadlock if the calling thread also
/// owned the join handle).  Callers wanting a clean shutdown should
/// invoke [`StandaloneServer::stop`] explicitly before dropping.
/// Without an explicit stop, the spawned thread continues running
/// until the process exits; for a benchmark binary that's
/// terminating anyway, this is the right default.
pub struct StandaloneServer {
    /// Stop flag — flipped to terminate the server thread.
    stop: Arc<AtomicBool>,
    /// Server thread join handle.  `Option` so [`stop`] can take
    /// ownership of the handle from `&mut self`.
    handle: Option<JoinHandle<()>>,
    /// The local Unix-socket path (if Unix mode).  None for TCP.
    unix_socket_path: Option<PathBuf>,
    /// The local TCP address (if TCP mode).  None for Unix.
    tcp_local_addr: Option<std::net::SocketAddr>,
}

impl StandaloneServer {
    /// Spawn a server backed by a Unix-socket listener.
    ///
    /// # Errors
    ///
    /// Returns `StandaloneServerError::UnixBind` if the listener
    /// cannot bind at `path`, or `StandaloneServerError::SpawnFailed`
    /// if the background thread cannot be spawned.
    #[cfg(unix)]
    pub fn spawn_unix(
        path: PathBuf,
        queue_depth: usize,
        handler: HandlerConfig,
    ) -> Result<Self, StandaloneServerError> {
        let listener =
            UnixListener::bind(&path).map_err(|source| StandaloneServerError::UnixBind {
                path: path.clone(),
                source,
            })?;
        let kernel = Box::new(MockKernel::new());
        let cfg = ServerConfigBuilder::new()
            .unix(listener)
            .max_queue_depth(queue_depth)
            .handler(handler)
            .build(kernel)
            .map_err(|e| StandaloneServerError::Build(format!("{e}")))?;
        let stop = Arc::new(AtomicBool::new(false));
        let server_stop = Arc::clone(&stop);
        let handle = std::thread::Builder::new()
            .name("knomosis-bench-server".into())
            .spawn(move || Server::new(cfg).run(server_stop))
            .map_err(StandaloneServerError::SpawnFailed)?;
        // Give the server a brief beat to bind + start accepting.
        // The plan recommends 100ms (matches the knomosis-host
        // integration tests).
        std::thread::sleep(Duration::from_millis(100));
        Ok(Self {
            stop,
            handle: Some(handle),
            unix_socket_path: Some(path),
            tcp_local_addr: None,
        })
    }

    /// Spawn a server backed by a TCP listener bound on the given
    /// address (use `127.0.0.1:0` for a kernel-assigned port).
    ///
    /// # Errors
    ///
    /// Returns `StandaloneServerError::TcpBind` if the listener
    /// cannot bind at `addr`, or `StandaloneServerError::SpawnFailed`
    /// if the background thread cannot be spawned.
    pub fn spawn_tcp(
        addr: std::net::SocketAddr,
        queue_depth: usize,
        handler: HandlerConfig,
    ) -> Result<Self, StandaloneServerError> {
        let listener = TcpListener::bind(addr)
            .map_err(|source| StandaloneServerError::TcpBind { addr, source })?;
        let local_addr = listener
            .local_addr()
            .map_err(|source| StandaloneServerError::TcpBind { addr, source })?;
        let kernel = Box::new(MockKernel::new());
        let cfg = ServerConfigBuilder::new()
            .tcp(listener)
            .max_queue_depth(queue_depth)
            .handler(handler)
            .build(kernel)
            .map_err(|e| StandaloneServerError::Build(format!("{e}")))?;
        let stop = Arc::new(AtomicBool::new(false));
        let server_stop = Arc::clone(&stop);
        let handle = std::thread::Builder::new()
            .name("knomosis-bench-server".into())
            .spawn(move || Server::new(cfg).run(server_stop))
            .map_err(StandaloneServerError::SpawnFailed)?;
        std::thread::sleep(Duration::from_millis(100));
        Ok(Self {
            stop,
            handle: Some(handle),
            unix_socket_path: None,
            tcp_local_addr: Some(local_addr),
        })
    }

    /// Return the bound Unix-socket path, if this server is in
    /// Unix mode.
    #[must_use]
    pub fn unix_socket_path(&self) -> Option<&std::path::Path> {
        self.unix_socket_path.as_deref()
    }

    /// Return the bound TCP local address, if this server is in
    /// TCP mode.
    #[must_use]
    pub fn tcp_local_addr(&self) -> Option<std::net::SocketAddr> {
        self.tcp_local_addr
    }

    /// Flip the stop flag and join the server thread.
    ///
    /// Bounded by `timeout`: if the server doesn't exit in time,
    /// the join is abandoned and the function returns
    /// `Err(JoinTimedOut)`.  This protects benchmark callers from
    /// hangs on shutdown.
    pub fn stop(&mut self, timeout: Duration) -> Result<(), JoinTimedOut> {
        self.stop.store(true, Ordering::Release);
        let Some(handle) = self.handle.take() else {
            return Ok(());
        };
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if handle.is_finished() {
                let _ = handle.join();
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        // The thread is still running; we deliberately leak it
        // (the JoinHandle goes out of scope without join'ing) so
        // the process can continue to exit.  The OS reclaims the
        // thread on process termination.
        drop(handle);
        Err(JoinTimedOut)
    }
}

impl Drop for StandaloneServer {
    fn drop(&mut self) {
        if self.handle.is_some() {
            // Best-effort: set the stop flag.  If the caller
            // wanted a deterministic shutdown they should have
            // called `.stop()`.
            self.stop.store(true, Ordering::Release);
        }
    }
}

/// The server didn't join in the configured timeout window.
#[derive(Debug, thiserror::Error)]
#[error("standalone server failed to join within timeout")]
pub struct JoinTimedOut;

#[cfg(test)]
mod tests {
    use super::StandaloneServer;
    use canon_host::listener::HandlerConfig;
    use std::time::Duration;

    /// Bind + connect + tear down a Unix-socket server.
    #[cfg(unix)]
    #[test]
    fn unix_spawn_and_stop() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("bench.sock");
        let mut server =
            StandaloneServer::spawn_unix(path.clone(), 16, HandlerConfig::default()).unwrap();
        // The path should exist.
        assert!(server.unix_socket_path().unwrap().exists());
        // TCP accessors are None.
        assert!(server.tcp_local_addr().is_none());
        // Clean shutdown.
        server.stop(Duration::from_secs(5)).unwrap();
    }

    /// Bind + connect + tear down a TCP server.
    #[test]
    fn tcp_spawn_and_stop() {
        let mut server = StandaloneServer::spawn_tcp(
            "127.0.0.1:0".parse().unwrap(),
            16,
            HandlerConfig::default(),
        )
        .unwrap();
        let local = server.tcp_local_addr().unwrap();
        // Port assigned.
        assert!(local.port() > 0);
        // Unix accessors are None.
        assert!(server.unix_socket_path().is_none());
        // Clean shutdown.
        server.stop(Duration::from_secs(5)).unwrap();
    }

    /// Stopping twice is idempotent.
    #[test]
    fn stop_idempotent() {
        let mut server = StandaloneServer::spawn_tcp(
            "127.0.0.1:0".parse().unwrap(),
            16,
            HandlerConfig::default(),
        )
        .unwrap();
        server.stop(Duration::from_secs(5)).unwrap();
        // Second stop on a server with no handle is a no-op.
        server.stop(Duration::from_secs(5)).unwrap();
    }
}

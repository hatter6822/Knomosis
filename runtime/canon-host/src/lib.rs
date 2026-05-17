// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `canon-host` — RH-C.
//!
//! Long-running TCP / Unix-socket service that accepts CBE-framed
//! `SignedAction` requests, forwards them to a `Kernel`
//! implementation (the Lean `canon` binary in production, a
//! `MockKernel` for tests), and returns the resulting `Verdict`.
//!
//! ## What this crate provides
//!
//!   * [`verdict`] — the `Verdict` enum mirroring the wire-format
//!     byte discriminator (`0 = OK`, `1 = NotAdmissible`,
//!     `2 = ParseError`, `3 = Busy` — the latter introduced by
//!     RH-C.4 / RH-C.5).
//!   * [`frame`] — wire-frame parser.  4-byte big-endian length
//!     prefix + `length`-byte payload.  Bounded against
//!     unbounded-payload DoS by `MAX_FRAME_SIZE` (default 1 MiB).
//!   * [`kernel`] — `Kernel` trait + two implementations:
//!     - `mock::MockKernel` for tests and dev (configurable
//!       per-request verdict; records every submission).
//!     - `command::CommandKernel` for production-ish use; spawns
//!       the `canon` binary per request, treating exit code 0 as
//!       `Ok` and anything else as `NotAdmissible`.  Heavy but
//!       correct.  See the [`kernel::command`] module's docstring
//!       for the architectural notes on the future
//!       long-running-subprocess optimization.
//!   * [`admission`] — typed `AdmissionStage` ladder (`Received`
//!     < `LocallyAdmitted` < `Sequenced` < `Finalized`) and
//!     `AdmissionReceipt` struct.  Lets the kernel API carry
//!     stage information internally without changing the wire-
//!     format byte for `Verdict::Ok`; forward-compatible with
//!     decentralized sequencing.
//!   * [`queue`] — `BoundedQueue` wrapping a `sync_channel` with a
//!     non-blocking `try_submit` API.  Returns the `Busy` verdict
//!     when full rather than blocking the listener.
//!   * [`tls`] — TLS configuration loader.  Parses PEM certificate
//!     and private-key files into a `rustls::ServerConfig`.
//!   * [`listener`] — per-protocol acceptors (TCP, Unix socket,
//!     TLS) sharing a unified `Connection` interface.
//!   * [`server`] — top-level orchestrator wiring listeners +
//!     queue + worker thread + kernel.
//!   * [`config`] — CLI flag parsing.
//!
//! ## Wire-format contract
//!
//! Mirrors `docs/abi.md` §10:
//!
//!   * **Request**: 4-byte BE u32 length + N CBE-encoded
//!     `SignedAction` bytes.  `1 ≤ N ≤ MAX_FRAME_SIZE`; the host
//!     does not parse the CBE payload itself.
//!   * **Response**: 1-byte verdict + 4-byte BE u32 reason length
//!     + M UTF-8 reason bytes.  M may be 0 (empty reason).
//!
//! Verdict byte table:
//!
//! | Byte | Meaning                                              |
//! |------|------------------------------------------------------|
//! | 0    | Ok — kernel admitted the action; L2 state advanced. |
//! | 1    | NotAdmissible — kernel rejected the action.         |
//! | 2    | ParseError — host or kernel could not parse the CBE.|
//! | 3    | Busy — host's worker queue full; retry with backoff.|
//!
//! ## Security properties
//!
//!   1. **The host does not interpret CBE bytes.**  All
//!      admissibility decisions happen in the Kernel implementation
//!      (Lean side for production).  A bug in the host's framing or
//!      queueing layer can drop or reorder requests but cannot
//!      violate any §8.2 admissibility witness.
//!   2. **Bounded payload size.**  Every length prefix is checked
//!      against `MAX_FRAME_SIZE` (default 1 MiB) before allocating
//!      or reading.  Rejects oversize frames with a `ParseError`
//!      verdict before processing.
//!   3. **Bounded queue.**  The mpsc channel is `sync_channel`
//!      bounded; under saturation the listener thread immediately
//!      returns `Busy` rather than blocking and growing memory
//!      usage.
//!   4. **No `unsafe`.**  `unsafe_code = "forbid"` workspace lint.
//!      The host is a pure-Rust orchestrator; FFI is delegated to
//!      the `Kernel` implementation (which is itself in safe Rust
//!      for the per-request `CommandKernel`).
//!   5. **No `panic`.**  The host handles every error path
//!      explicitly.  A connection-level error is logged and the
//!      connection closed; a worker-level error halts the worker
//!      with an operator alert.  `panic = "abort"` in the release
//!      profile (workspace default) makes any accidental panic
//!      fail-fast rather than unwinding into a half-broken state.
//!   6. **TLS termination.**  When `--tls-cert` and `--tls-key`
//!      are supplied, `rustls` (with the audited `ring` backend)
//!      terminates TLS at the TCP boundary.  Minimum TLS version
//!      is configurable; default 1.3.
//!   7. **Filesystem-permission-protected Unix socket.**  The
//!      Unix-socket listener sets mode `0600` (owner read/write
//!      only) so a non-root local user cannot trivially access
//!      the daemon's IPC channel.  There is a microsecond-wide
//!      race window between `bind` and `set_permissions`; see
//!      `listener::unix::UnixListener`'s docstring for the
//!      operator mitigations (restricted parent directory or
//!      process-level `umask 0177`).
//!
//! ## Threading model
//!
//! The server is a synchronous (non-async) `std::thread`-based
//! architecture chosen to keep the dependency tree minimal and
//! the audit surface narrow:
//!
//!   * One thread per listener (TCP, Unix, TLS-on-TCP) doing
//!     `accept()` in a loop.
//!   * One thread per accepted connection doing the
//!     request/response cycle.
//!   * One dedicated worker thread draining the bounded queue and
//!     calling `kernel.submit()`.  Serial — the Kernel may hold
//!     mutable state (e.g. the canon log file) that requires
//!     sequential access.
//!
//! This trades some peak throughput vs an async runtime for a
//! significantly smaller dependency tree (`tokio` would add 80+
//! transitive crates).  For Canon's expected workload (a single
//! sequencer + a small set of API consumers) this is the right
//! tradeoff.  See the engineering plan §RH-C for the original
//! tokio-based architecture sketch.
//!
//! ## What this crate does NOT provide
//!
//!   * **A long-running canon subprocess** (`canon serve` mode).
//!     The current `CommandKernel` spawns `canon process` per
//!     request, which re-loads the log file every time.  This is
//!     O(log size) per request and only suitable for low-throughput
//!     deployments.  The canonical optimization is a future
//!     `canon serve` Lean-side subcommand that reads CBE frames
//!     from stdin and writes verdicts to stdout, eliminating the
//!     per-request bootstrap cost.  Documented in
//!     `docs/planning/rust_host_runtime_plan.md` §RH-C closeout.
//!   * **An HTTP/1.1 compatibility shim.**  The canonical wire
//!     format is the raw TCP length-prefixed protocol per the
//!     plan §RH-C.1.  The existing
//!     `canon-l1-ingest/src/submitter.rs::http::HttpSubmitter`
//!     uses HTTP/1.1 against a placeholder endpoint; migrating
//!     the submitter to the canonical raw-TCP protocol is a
//!     future RH-B-adjacent PR.  Both protocols can coexist.

#![doc(html_root_url = "https://docs.rs/canon-host/0.1.0")]

pub mod admission;
pub mod config;
pub mod frame;
pub mod kernel;
pub mod listener;
pub mod queue;
pub mod server;
pub mod tls;
pub mod verdict;

/// Crate name, mirrored from `Cargo.toml`.
pub const CRATE_NAME: &str = "canon-host";

/// The implementation identifier this host publishes through its
/// startup diagnostics.  Mirrors the wire-protocol version so
/// operators can confirm at startup which network ABI is linked.
pub const HOST_IDENTIFIER: &str = "canon-host/v1";

/// The network ABI's protocol version.  Bumped if the wire-format
/// contract documented in `docs/abi.md` §10 changes.  Mirrors
/// `canon-l1-ingest`'s `PROTOCOL_VERSION` and is part of the
/// cross-stack version surface.
pub const PROTOCOL_VERSION: u32 = 1;

#[cfg(test)]
mod tests {
    use super::{CRATE_NAME, HOST_IDENTIFIER, PROTOCOL_VERSION};

    /// Crate-name constant doesn't drift silently.
    #[test]
    fn crate_name_constant() {
        assert_eq!(CRATE_NAME, "canon-host");
    }

    /// Identifier constant is the documented v1 string.
    #[test]
    fn identifier_constant() {
        assert_eq!(HOST_IDENTIFIER, "canon-host/v1");
    }

    /// Protocol version starts at 1 and is bumped by amendment.
    #[test]
    fn protocol_version_constant() {
        assert_eq!(PROTOCOL_VERSION, 1);
    }
}

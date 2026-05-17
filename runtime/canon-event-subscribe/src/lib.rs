// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `canon-event-subscribe` — RH-D.
//!
//! Long-running TCP service that tails Canon's transition log,
//! extracts deployment-facing events from each log entry via the
//! Lean `canon` subprocess (the wire-format authority), and
//! streams those events to subscribers in strict order with
//! bounded-lag eviction.
//!
//! ## What this crate provides
//!
//!   * [`frame`] — wire-frame parser/encoder for both directions
//!     of the protocol.  Outbound frames carry `(seq, event_bytes)`
//!     pairs; inbound frames carry the client's
//!     `subscribe { resume_from: Option<u64> }` handshake plus
//!     control bytes (`ack` heartbeats).  Bounded against the
//!     classic length-driven OOM by `MAX_FRAME_SIZE` (default
//!     1 MiB).
//!   * [`tail`] — log-tail reader.  Opens the persistent log file
//!     via `std::fs::File`, decodes complete frames at the tail,
//!     and yields `LogFrame` records (`(seq, payload_bytes)`
//!     pairs).  On EOF the reader sleeps and retries (no `inotify`
//!     dependency — keeps the dependency tree minimal).
//!   * [`extract`] — event extraction via the Lean `canon`
//!     subprocess.  Delegates the byte-level work to the
//!     wire-format authority rather than re-implementing
//!     `Events.extractEvents` in Rust.  Caches extracted events
//!     keyed by sequence number for backfill.
//!   * [`event_cache`] — sequenced event cache supporting the
//!     backfill protocol.  Bounded by `--keep-history <n>`; older
//!     events report `truncated` rather than silently delivering
//!     a partial range.
//!   * [`subscription`] — per-subscriber state machine.
//!     `BoundedSendQueue` + lag-counter + eviction policy.  A
//!     subscriber whose lag exceeds `--max-subscriber-lag` is sent
//!     a final `lag_exceeded` frame and disconnected.
//!   * [`server`] — top-level orchestrator wiring the tail
//!     reader, extractor, cache, and subscriber set.  Spawns
//!     one acceptor thread (TCP) plus one extractor thread;
//!     each subscriber gets a dedicated dispatch thread
//!     draining the bounded send queue.
//!   * [`config`] — CLI flag parsing and validation.  Mirrors
//!     `canon-host`'s hand-rolled parser; no `clap` dependency.
//!
//! ## Wire-format contract
//!
//! See `docs/abi.md` §11.  The protocol is **synchronous,
//! length-prefixed, and self-delimiting**:
//!
//! ### Client → server (handshake)
//!
//! ```text
//! offset  size  field
//! ------  ----  -------------------------------------------------
//!     0    1    frame kind tag (0 = SUBSCRIBE; see §11.2)
//!     1    8    resume_from sequence (big-endian u64; 0 = no resume)
//! ```
//!
//! After SUBSCRIBE the server starts streaming event frames.  The
//! client may close the connection at any time; there is no
//! explicit UNSUBSCRIBE.
//!
//! ### Server → client (event frame)
//!
//! ```text
//! offset  size  field
//! ------  ----  -------------------------------------------------
//!     0    1    frame kind tag (1 = EVENT)
//!     1    8    sequence number (big-endian u64)
//!     9    4    event payload length N (big-endian u32; 0 ≤ N ≤ max_frame_size)
//!    13    N    CBE-encoded `Event` bytes (cross-reference `Events/Types.lean`)
//! ```
//!
//! ### Server → client (control / termination frames)
//!
//! ```text
//! offset  size  field
//! ------  ----  -------------------------------------------------
//!     0    1    frame kind tag (2 = LAG_EXCEEDED, 3 = TRUNCATED,
//!                                4 = SERVER_SHUTDOWN, 5 = INVALID_REQUEST)
//!     1    8    diagnostic sequence (BE u64; semantically meaningful per kind)
//! ```
//!
//! Termination frames are followed by an immediate connection
//! close from the server side.  See `docs/abi.md` §11 for the
//! per-kind semantics.
//!
//! ## Security properties
//!
//!   1. **No `unsafe`.**  `unsafe_code = "forbid"` workspace lint.
//!      The subscriber is a pure-Rust orchestrator; FFI is
//!      delegated to the `canon` subprocess (which is itself
//!      Lean-side code with its own audit posture).
//!   2. **Bounded payload size.**  Every length prefix is checked
//!      against `MAX_FRAME_SIZE` (default 1 MiB) before
//!      allocating or reading.  Rejects oversize frames with a
//!      typed error before any allocation.  Mirrors `canon-host`'s
//!      `read_frame` discipline byte-for-byte.
//!   3. **Bounded subscriber lag.**  Each subscriber holds a
//!      bounded send queue (default 64 events deep).  If the
//!      queue is full when a new event arrives, the server
//!      increments a per-subscriber lag counter.  If the
//!      counter exceeds `--max-subscriber-lag` (default 256), the
//!      server sends a final `lag_exceeded` frame and disconnects.
//!      A slow subscriber **cannot** consume unbounded server
//!      memory.
//!   4. **No silent data loss.**  Truncation (resume-from-before-
//!      keep-history) and lag-eviction both surface as explicit
//!      control frames before the connection closes; the client
//!      can distinguish "I'm too slow" from "the server crashed."
//!   5. **Read-only against the log.**  The log file is opened
//!      read-only (`std::fs::OpenOptions::new().read(true)`); a
//!      bug in the subscriber cannot corrupt the canonical log.
//!      The host (`canon-host`) is the only writer.
//!   6. **Subprocess isolation.**  Event extraction runs in a
//!      separate `canon` subprocess that exits non-zero on any
//!      Lean-level error.  If the subprocess crashes the server
//!      restarts it (with bounded backoff) rather than hanging.
//!   7. **No panics on attacker input.**  Every frame-parse error
//!      path returns a typed `FrameError`; every subprocess
//!      error path returns a typed `ExtractError`; every queue-
//!      overflow path increments the lag counter and may close
//!      the connection.
//!
//! ## Threading model
//!
//! Synchronous `std::thread`-based architecture chosen to keep
//! the dependency tree minimal and the audit surface narrow:
//!
//!   * **One TCP acceptor thread** doing `accept()` in a loop.
//!     On a new connection, parses the handshake then spawns a
//!     dedicated dispatch thread.
//!   * **One extractor thread** driving the `canon` subprocess.
//!     Reads `LogFrame`s from the tail reader, sends them to
//!     `canon` for extraction, then publishes each extracted
//!     `(seq, Event)` to the broadcast queue.
//!   * **One dispatch thread per subscriber** draining the
//!     subscriber's bounded send queue and writing event frames
//!     to the TCP socket.
//!   * **One tail thread** following the log file and emitting
//!     `LogFrame` records as new frames complete on disk.
//!
//! The tail → extractor → broadcast → dispatch pipeline keeps
//! per-subscriber latency proportional to the slowest subscriber's
//! socket (NOT to the slowest subscriber's processing — slow
//! subscribers are disconnected rather than backpressuring the
//! pipeline).
//!
//! ## What this crate does NOT provide
//!
//!   * **Push notifications via Unix socket / IPC.**  RH-D's
//!     scope is TCP-only (matching the plan §RH-D.1's
//!     `--listen <addr>` flag).  Unix-socket support is a future
//!     extension; the listener layer is identical to
//!     `canon-host`'s and can be ported when needed.
//!   * **Filtering at the server.**  Every subscriber receives
//!     every event from `resume_from` onward.  Filtering by
//!     resource / actor / tag is a client-side concern; pushing
//!     it to the server would explode the protocol surface for
//!     marginal bandwidth savings on small deployments.
//!   * **Authentication.**  The server is intended for trust-
//!     bounded deployments (typically same-host as canon-host,
//!     or behind an operator-supplied TLS terminator).  Adding
//!     TLS is straightforward (the `rustls` config from
//!     `canon-host::tls` is reusable); deferred to a future PR.

#![doc(html_root_url = "https://docs.rs/canon-event-subscribe/0.1.0")]

pub mod config;
pub mod event_cache;
pub mod extract;
pub mod frame;
pub mod server;
pub mod subscription;
pub mod tail;

/// Crate name, mirrored from `Cargo.toml`.
pub const CRATE_NAME: &str = "canon-event-subscribe";

/// The implementation identifier this subscriber publishes through
/// startup diagnostics.  Mirrors `canon-host`'s `HOST_IDENTIFIER`
/// pattern and is part of the cross-stack version surface.
pub const SUBSCRIBE_IDENTIFIER: &str = "canon-event-subscribe/v1";

/// The event-subscribe protocol version.  Bumped if the wire-format
/// contract documented in `docs/abi.md` §11 changes.  Mirrors
/// `canon-host::PROTOCOL_VERSION`'s 1-up versioning.
pub const PROTOCOL_VERSION: u32 = 1;

#[cfg(test)]
mod tests {
    use super::{CRATE_NAME, PROTOCOL_VERSION, SUBSCRIBE_IDENTIFIER};

    /// Crate-name constant doesn't drift silently.
    #[test]
    fn crate_name_constant() {
        assert_eq!(CRATE_NAME, "canon-event-subscribe");
    }

    /// Identifier constant is the documented v1 string.
    #[test]
    fn identifier_constant() {
        assert_eq!(SUBSCRIBE_IDENTIFIER, "canon-event-subscribe/v1");
    }

    /// Protocol version starts at 1 and is bumped by amendment.
    #[test]
    fn protocol_version_constant() {
        assert_eq!(PROTOCOL_VERSION, 1);
    }
}

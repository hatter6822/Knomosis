// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `knomosis-host` — RH-C.
//!
//! Long-running TCP / Unix-socket service that accepts CBE-framed
//! `SignedAction` requests, forwards them to a `Kernel`
//! implementation (the Lean `knomosis` binary in production, a
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
//!       the `knomosis` binary per request, treating exit code 0 as
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
//!   * [`budget`] — the per-actor budget admission gate (GP.6.2): a
//!     byte-equivalent Rust mirror of the Lean kernel's
//!     `ActorBudget` / `EpochBudgetState` / `BudgetPolicy` plus the
//!     budget-ledger portion of the GP.3.2 admission gate.  Drives
//!     the `MockKernel`'s optional budget check (surfacing
//!     `InsufficientBudget` under `Verdict::NotAdmissible`) and the
//!     `CommandKernel`'s budget-policy flag pass-through to the Lean
//!     `knomosis` binary.
//!   * [`queue`] — the worker queue(s).  `BoundedQueue` wraps a
//!     `sync_channel` with a non-blocking `try_submit` API (the FIFO
//!     default), returning the `Busy` verdict when full rather than
//!     blocking the listener.  `FairQueue` is the optional
//!     Deficit-Round-Robin fair queue (FQ Rung 0), and `QueueHandle`
//!     unifies the two behind one scheduler-agnostic `submit` call.
//!   * [`fair`] — the optional per-connection fair scheduler
//!     (Workstream GP.8, Track A / FQ — Rung 0).  [`fair::drr`] is the
//!     pure, I/O-free Deficit-Round-Robin core; the concurrency wrapper
//!     ([`queue::FairQueue`]) and the server wiring build on it.  Ships
//!     behind the default-OFF `--scheduler drr` flag; FIFO stays the
//!     baseline.
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
//!     `accept()` in a loop.  Each accepted connection is assigned a
//!     monotonic, transport-authenticated `ConnId` from a shared
//!     counter (FQ.3).
//!   * One thread per accepted connection doing the
//!     request/response cycle.
//!   * One dedicated worker thread draining the queue and calling
//!     `kernel.submit()`.  Serial — the Kernel may hold mutable state
//!     (e.g. the knomosis log file) that requires sequential access.
//!     **This single serial worker is the contended resource the fair
//!     scheduler bounds.**
//!
//! This trades some peak throughput vs an async runtime for a
//! significantly smaller dependency tree (`tokio` would add 80+
//! transitive crates).  For Knomosis's expected workload (a single
//! sequencer + a small set of API consumers) this is the right
//! tradeoff.  See the engineering plan §RH-C for the original
//! tokio-based architecture sketch.
//!
//! ## Optional fair scheduling (FQ Rung 0)
//!
//! By default the worker drains a FIFO `BoundedQueue`.  Under
//! `--scheduler drr` it instead drains a [`queue::FairQueue`] — a
//! work-conserving Deficit-Round-Robin scheduler keyed by the
//! connection's `ConnId` — so that, **under contention for the serial
//! worker**, no one connection can monopolise it: a flooding connection
//! delays only itself (HOL blocking is removed at the dequeue end, and
//! a per-flow buffer cap removes it at the enqueue end), while a
//! productive burst on an idle host is throttled by nothing.  The
//! design (`docs/planning/GP.8_SEQUENCER_INTEGRATION_PLAN.md`
//! §2.3–§2.8) is governed by these load-bearing invariants:
//!
//!   * **Classification-only routing (§2.6 invariant 1).**  The routing
//!     key (`ConnId`) influences *order and drop* only, never
//!     admissibility.  A scheduling bug can reorder or drop, never admit
//!     an inadmissible action nor reject an admissible one — exactly the
//!     latitude security property #1 already grants the FIFO path.  The
//!     host still parses no CBE bytes.
//!   * **The scheduler is bounded (§2.6 invariant 4).**  Distinct flows
//!     (`--max-flows`), a per-flow backlog (`--per-flow-cap`), and the
//!     total buffered count (`--max-queue-depth`, reused as the global
//!     cap) are all capped, with empty flows evicted immediately, so the
//!     flow map cannot grow without bound.
//!   * **Deterministic, I/O-free decision (§2.7).**  The DRR `pick` reads
//!     no clock and performs no I/O, so it is reproducible — the seam a
//!     future accountable-fairness layer would replay against.
//!   * **Lock-free dispatch (§2.8).**  The worker pops a request under
//!     the scheduler lock and dispatches it *after* releasing the lock,
//!     so a slow `kernel.submit` never serializes producers.
//!
//! Rung 0 requires **no wire-format change** (host-internal only);
//! `PROTOCOL_VERSION` stays `1`.  The Rung-1 signer-hint extension
//! (a superset, `PROTOCOL_VERSION` 2) is future work.
//!
//! ## What this crate does NOT provide
//!
//!   * **A long-running knomosis subprocess** (`knomosis serve` mode).
//!     The current `CommandKernel` spawns `knomosis process` per
//!     request, which re-loads the log file every time.  This is
//!     O(log size) per request and only suitable for low-throughput
//!     deployments.  The canonical optimization is a future
//!     `knomosis serve` Lean-side subcommand that reads CBE frames
//!     from stdin and writes verdicts to stdout, eliminating the
//!     per-request bootstrap cost.  Documented in
//!     `docs/planning/rust_host_runtime_plan.md` §RH-C closeout.
//!   * **An HTTP/1.1 compatibility shim.**  The canonical wire
//!     format is the raw TCP length-prefixed protocol per the
//!     plan §RH-C.1.  The existing
//!     `knomosis-l1-ingest/src/submitter.rs::http::HttpSubmitter`
//!     uses HTTP/1.1 against a placeholder endpoint; migrating
//!     the submitter to the canonical raw-TCP protocol is a
//!     future RH-B-adjacent PR.  Both protocols can coexist.

#![doc(html_root_url = "https://docs.rs/knomosis-host/0.1.0")]

pub mod admission;
pub mod budget;
pub mod config;
pub mod fair;
pub mod frame;
pub mod kernel;
pub mod listener;
pub mod queue;
pub mod server;
pub mod tls;
pub mod verdict;

/// Crate name, mirrored from `Cargo.toml`.
pub const CRATE_NAME: &str = "knomosis-host";

/// The implementation identifier this host publishes through its
/// startup diagnostics.  Mirrors the wire-protocol version so
/// operators can confirm at startup which network ABI is linked.
pub const HOST_IDENTIFIER: &str = "knomosis-host/v1";

/// The network ABI's protocol version.  Bumped if the wire-format
/// contract documented in `docs/abi.md` §10 changes.  Mirrors
/// `knomosis-l1-ingest`'s `PROTOCOL_VERSION` and is part of the
/// cross-stack version surface.
pub const PROTOCOL_VERSION: u32 = 1;

#[cfg(test)]
mod tests {
    use super::{CRATE_NAME, HOST_IDENTIFIER, PROTOCOL_VERSION};

    /// Crate-name constant doesn't drift silently.
    #[test]
    fn crate_name_constant() {
        assert_eq!(CRATE_NAME, "knomosis-host");
    }

    /// Identifier constant is the documented v1 string.
    #[test]
    fn identifier_constant() {
        assert_eq!(HOST_IDENTIFIER, "knomosis-host/v1");
    }

    /// Protocol version starts at 1 and is bumped by amendment.
    #[test]
    fn protocol_version_constant() {
        assert_eq!(PROTOCOL_VERSION, 1);
    }
}

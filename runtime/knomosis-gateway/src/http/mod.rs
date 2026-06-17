// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The gateway's synchronous HTTP layer.
//!
//! Split into a **pure routing core** ([`router`]) — transport-agnostic, so it
//! is unit-testable in isolation; a **transport-agnostic request core**
//! ([`handler`]) shared by every front-end (so they cannot diverge in security
//! behaviour); the **transport-neutral connection handler** ([`conn`]) — the
//! gateway's own strict HTTP/1.1 reader + writer + keep-alive loop, generic
//! over any `Read + Write` stream; the two listeners that feed it — plaintext
//! ([`plain`], on `--listen`) and native HTTPS ([`tls`], on `--tls-listen`,
//! `rustls 0.23`); and the orchestration shell ([`server`]) that builds the
//! shared state and runs both listeners under one graceful shutdown.  The
//! gateway owns its whole HTTP stack (no `tiny_http`), so a connection is one
//! thread + a socket-owned read/write deadline on **both** transports.

pub mod conn;
pub mod handler;
mod plain;
mod router;
mod server;
pub mod tls;

pub use plain::spawn_plain_listener;
pub use router::{apply_conditional, route, Route, RouteOutcome};
pub use server::{serve, ServeError};

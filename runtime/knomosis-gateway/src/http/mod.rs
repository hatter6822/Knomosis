// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The gateway's synchronous HTTP layer.
//!
//! Split into a **pure routing core** ([`router`]) — transport- and
//! `tiny_http`-agnostic, so it is unit-testable in isolation — a
//! **transport-agnostic request core** ([`handler`]) shared by the HTTP and
//! HTTPS front-ends (so they cannot diverge in security behaviour), the
//! and the thin **IO shell** ([`server`]) that owns the `tiny_http` accept
//! loop and the request→response glue.

pub mod handler;
mod router;
mod server;

pub use router::{apply_conditional, route, Route, RouteOutcome};
pub use server::{handle_request, serve, spawn_handler_pool, ServeError};

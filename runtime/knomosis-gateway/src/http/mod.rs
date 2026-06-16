// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The gateway's synchronous HTTP layer.
//!
//! Split into a **pure routing core** ([`router`]) — transport- and
//! `tiny_http`-agnostic, so it is unit-testable in isolation — and a
//! thin **IO shell** ([`server`]) that owns the `tiny_http` accept
//! loop and the request→response glue.  This "testable core + thin IO
//! shell" split is the pattern every later HTTP unit (G1.2) extends.

mod router;
mod server;

pub use router::{route, RouteOutcome};
pub use server::{handle_request, serve, ServeError};

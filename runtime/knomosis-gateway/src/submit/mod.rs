// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The submit path (Workstream G2): the gateway forwards a client-signed
//! `SignedAction` to the binary host (§10) and maps the host's verdict to
//! the JSON contract.
//!
//! **Key custody (§8.2).**  The gateway frames the client's pre-signed
//! CBE bytes **opaquely** — it never holds or applies a signing key, so
//! the kernel's opaque-`Verify` / EUF-CMA trust model is preserved.
//!
//! G2.1a ships the wire codec ([`client`]); the bounded persistent
//! connection pool (G2.1b) and the `POST /v1/actions` intake + verdict
//! mapping (G2.2) build on it.

pub mod client;

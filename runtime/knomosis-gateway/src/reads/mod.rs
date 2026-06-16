// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Read endpoints: the balance / budget / pool views, rendered from the
//! read-only indexer storage handle ([`crate::state::ReadState`]) to
//! the OpenAPI JSON contract (`docs/api/gateway.openapi.yaml`).
//!
//! G1.6b ships the balances ([`balances`]); the budget and pool views
//! land in G1.7.  Every read carries `X-Knomosis-Seq` (the indexer
//! cursor the value reflects) so consumers can reconcile against the
//! eventually-consistent indexer view (§2 principle 4, §3.6).

pub mod balances;

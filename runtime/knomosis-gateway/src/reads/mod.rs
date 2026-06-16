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
//! G1.6b ships the balances ([`balances`]); G1.7 adds the budget
//! ([`budget`]) and pool ([`pools`]) views.  Every read carries
//! `X-Knomosis-Seq` (the indexer cursor the value reflects) so consumers
//! can reconcile against the eventually-consistent indexer view (§2
//! principle 4, §3.6).

pub mod balances;
pub mod budget;
pub mod pools;

/// Decode an 8-byte BE `u64` control cell (a cursor or a current-epoch
/// counter): absent → `Some(0)` (a fresh database); exactly 8 bytes →
/// `Some(v)`; any other length → `None` (corruption — the caller fails
/// closed with a `500`).
pub(crate) fn decode_control_u64(cell: Option<&[u8]>) -> Option<u64> {
    match cell {
        None => Some(0),
        Some(bytes) => {
            let arr: [u8; 8] = bytes.try_into().ok()?;
            Some(u64::from_be_bytes(arr))
        }
    }
}

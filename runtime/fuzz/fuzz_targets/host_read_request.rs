// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Fuzz the `knomosis-host` wire-frame request reader — the untrusted
//! network boundary (`docs/audits/20-…` §4.3).
//!
//! `read_request` is the exact entry point `handle_connection` calls on
//! every accepted socket: the one-time Rung-1 magic peek + the v1 /
//! v2-hinted branch (`[8-byte signer hint][4-byte length][payload]`).
//! A hostile peer controls every byte, so the reader must return
//! `Ok`/`Err` on ANY input and never panic / over-allocate — an
//! unchecked length prefix or slice would be a DoS on the sequencer.
//!
//! The companion `host.dict` dictionary seeds the 4-byte `KNH2`
//! preamble so the coverage-guided engine reaches the v2 hinted path
//! (which raw mutation almost never hits).  Mirrors the stable
//! `read_request_*` proptests in `knomosis-host/tests/property.rs`.

#![no_main]

use knomosis_host::frame::{read_request, DEFAULT_MAX_FRAME_SIZE};
use libfuzzer_sys::fuzz_target;
use std::io::Cursor;

fuzz_target!(|data: &[u8]| {
    let mut cursor = Cursor::new(data);
    // The result is intentionally discarded: the property under test is
    // termination-without-panic, not a specific decode outcome (the
    // harness fails on any panic / abort / OOM).
    let _ = read_request(&mut cursor, DEFAULT_MAX_FRAME_SIZE);
});

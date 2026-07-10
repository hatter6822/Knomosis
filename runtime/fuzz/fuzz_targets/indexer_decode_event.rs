// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Fuzz the `knomosis-indexer` event decoder — the untrusted
//! event-stream boundary (`docs/audits/20-…` §4.3).
//!
//! `decode_event` reconstructs a typed `Event` from the CBE-encoded
//! bytes the indexer reads off the subscription stream (which
//! ultimately originates from the kernel's event log, but the indexer
//! treats it as untrusted input and must be robust to a corrupt /
//! truncated / hostile frame).  It must return `Ok`/`Err` on ANY input
//! and never panic — the read model must not be a crash oracle.
//!
//! The committed `indexer.dict` dictionary seeds the CBE tag bytes so
//! the coverage-guided engine reaches the constructor-tag dispatch
//! deeper than random bytes would.  Mirrors the `decoder_fuzz_*`
//! proptests in `knomosis-indexer/tests/property.rs`.

#![no_main]

use knomosis_indexer::decoder::decode_event;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // Discarded: the property is termination-without-panic on arbitrary
    // bytes, not a specific decode outcome.
    let _ = decode_event(data);
});

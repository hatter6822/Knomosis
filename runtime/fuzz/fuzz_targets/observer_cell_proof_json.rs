// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Fuzz the fault-proof observer's `CellProof` JSON intake — the
//! boundary at which a variable-length SMT opening enters the process.
//!
//! `CellProof` is deserialised from the output of a `knomosis
//! export-cell-proofs` subprocess, and its `proof_data` field is the
//! only unbounded-length field on the struct: an opening is a 32-byte
//! bitmask followed by up to `SMT_DEPTH = 256` siblings.  The custom
//! deserialiser caps the hex length BEFORE `hex::decode` allocates and
//! then re-checks the decoded shape, so neither a multi-megabyte hex
//! string nor a misaligned tail can turn into an allocation spike or a
//! slice panic downstream.
//!
//! The property is the same one every target in this crate asserts:
//! `Ok`/`Err` on ANY input, never a panic — the observer must not be a
//! crash oracle for whoever can write to its input pipe.  What is
//! specific here is the length dimension: a size-cap check that reads
//! the decoded length instead of the encoded one still allocates first,
//! and only a length-varying corpus finds that.

#![no_main]

use knomosis_faultproof_observer::submitter::CellProof;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // Path 1: the raw bytes as a JSON document.  Reaches the field
    // dispatch and every deserialiser on the struct.
    if let Ok(text) = std::str::from_utf8(data) {
        let _ = serde_json::from_str::<CellProof>(text);

        // Path 2: the same bytes as the `proof_data` VALUE inside an
        // otherwise well-formed proof.  Path 1 almost never produces a
        // parseable envelope, so without this the opening's own
        // length/alignment checks are never reached with an
        // interesting length.  The value is escaped by serialisation,
        // so an embedded quote cannot break out of the envelope and
        // silently reduce this to path 1 again.
        let escaped = serde_json::to_string(text).unwrap_or_else(|_| "\"\"".to_string());
        let envelope = format!(
            concat!(
                r#"{{"cell_kind":0,"key_a":"0000000000000007","#,
                r#""key_b":"0000000000000001","cell_value":"","#,
                r#""witness_commit":"{}","proof_data":{}}}"#
            ),
            "00".repeat(32),
            escaped,
        );
        let _ = serde_json::from_str::<CellProof>(&envelope);
    }
});

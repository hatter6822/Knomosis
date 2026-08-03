// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Fuzz the fault-proof observer's `TerminateBundle` JSON intake — the
//! boundary at which a MULTIPROOF wire enters the process.
//!
//! `parse_terminate_bundle_json` reads the output of a `knomosis
//! export-terminate-bundle` subprocess and hands the result straight to
//! the ABI encoder, so it is the last place a malformed bundle can be
//! stopped before it becomes calldata.  Three of its fields are
//! unbounded on the wire and each is a distinct length dimension:
//!
//!   * `opened_cells` — the frontier, an array whose element count the
//!     parser caps at the contract's `MAX_CELL_OPENINGS`;
//!   * `gap_mask_hex` — `ceil(G/8)` bytes for a gap count the KEY SET
//!     determines, so its length is not a free parameter downstream but
//!     IS whatever the subprocess wrote;
//!   * `siblings_hex` — 32 bytes per set mask bit, checked here for
//!     whole-sibling alignment and capped by length.
//!
//! The `CellProof` target next door fuzzes a single fixed-shape opening.
//! What is specific here is the RELATIONSHIP between three
//! independently-varying lengths: an array count, a bitmask, and a
//! packed region whose size the bitmask implies.  A cap that reads the
//! decoded length instead of the encoded one, or an alignment check
//! that runs after a slice, is only found by varying them together.
//!
//! The property is the one every target in this crate asserts:
//! `Ok`/`Err` on ANY input, never a panic — the observer must not be a
//! crash oracle for whoever can write to its input pipe.

#![no_main]

use knomosis_faultproof_observer::strategy::parse_terminate_bundle_json;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };

    // Path 1: the raw bytes as a JSON document.  Reaches the field
    // dispatch and every deserialiser on the struct.
    let _ = parse_terminate_bundle_json(0, text);

    // Path 2: the same bytes as the wire's two hex VALUES inside an
    // otherwise well-formed bundle.  Path 1 almost never produces a
    // parseable envelope, so without this the length and alignment
    // checks are never reached with an interesting length.  Both
    // regions take the SAME input so a mask and a sibling list of
    // inconsistent sizes are generated together, which is the shape the
    // whole-sibling check exists for.  The values are escaped by
    // serialisation, so an embedded quote cannot break out and silently
    // reduce this to path 1 again.
    let escaped = serde_json::to_string(text).unwrap_or_else(|_| "\"\"".to_string());
    let envelope = format!(
        concat!(
            r#"{{"fixture_id":"log[0]","action_kind":0,"#,
            r#""action_fields_hex":"","signer":0,"#,
            r#""expected_post_commit_hex":"{}","#,
            r#""opened_cells":[{{"cell_kind":14,"key_a":"0000000000000000","#,
            r#""key_b":"0000000000000000","pre_value":""}}],"#,
            r#""gap_mask_hex":{},"siblings_hex":{}}}"#
        ),
        "00".repeat(32),
        escaped,
        escaped,
    );
    let _ = parse_terminate_bundle_json(0, &envelope);

    // Path 3: the bytes as the FRONTIER — a repeated cell whose count
    // scales with the input, so the element cap is reached with a
    // document the parser can actually decode.  The wire is left
    // well-formed, isolating the array-length dimension from the two
    // byte-region ones.
    let cells = usize::from(data.first().copied().unwrap_or(0)).min(64);
    let mut frontier = String::new();
    for i in 0..cells {
        if i > 0 {
            frontier.push(',');
        }
        frontier.push_str(
            r#"{"cell_kind":0,"key_a":"0000000000000001","key_b":"0000000000000002","pre_value":""}"#,
        );
    }
    let wide = format!(
        concat!(
            r#"{{"fixture_id":"log[0]","action_kind":0,"#,
            r#""action_fields_hex":"","signer":0,"#,
            r#""expected_post_commit_hex":"{}","#,
            r#""opened_cells":[{}],"#,
            r#""gap_mask_hex":"","siblings_hex":""}}"#
        ),
        "00".repeat(32),
        frontier,
    );
    let _ = parse_terminate_bundle_json(0, &wide);
});

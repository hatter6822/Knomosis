// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! WU GP.6.3 — Lean → indexer cross-stack round-trip for the `Event`
//! CBE wire format.
//!
//! The indexer's `decoder::decode_event` is the field-level consumer
//! of the bytes the event-subscription server streams.  This test
//! proves that consumer agrees with the Lean `Event.encode` authority
//! BYTE-FOR-BYTE: for every fixture entry (real Lean
//! `Event.encode` hex) whose tag is in the indexer's known range
//! `0..=15`, `decode_event` succeeds, the decoded tag matches, AND
//! `encode_event` reproduces the exact Lean bytes (a full
//! Lean→decode→re-encode round-trip).  Entries at the
//! Workstream-GP gas-pool tags `16..=19` (which the indexer's `Event`
//! mirror does not yet model — that is GP.6.4) must decode to the
//! typed `UnknownTag` error, never a bogus event.
//!
//! Gated on the Lean-generated fixture's presence (written by
//! `lake test`); skips locally when absent, fails under CI.

use std::path::PathBuf;

use knomosis_indexer::decoder::{decode_event, encode_event, DecodeError};
use serde::Deserialize;

/// The highest event tag the indexer's `Event` mirror models today.
/// Tags above this are the GP gas-pool family (GP.6.4 extends the
/// mirror to cover them).
const INDEXER_MAX_KNOWN_TAG: u64 = 15;

/// Pinned generator identifier (a Lean-side version bump forces an
/// explicit update here).
const EXPECTED_FIXTURE_IDENTIFIER: &str = "knomosis-event-subscribe/event-cbe/v1";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Header {
    identifier: String,
    count: usize,
    #[allow(dead_code)]
    known_tag_count: u64,
    #[allow(dead_code)]
    note: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Entry {
    kind: String,
    tag: u64,
    category: String,
    expected_cbe: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fixture {
    header: Header,
    entries: Vec<Entry>,
}

/// `<repo>/solidity/test/CrossCheck/fixtures/event_subscribe_cbe.json`.
fn locate_fixture() -> Option<PathBuf> {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // <repo>/runtime/knomosis-indexer -> <repo>
    let repo = manifest.parent()?.parent()?;
    let fixture = repo
        .join("solidity")
        .join("test")
        .join("CrossCheck")
        .join("fixtures")
        .join("event_subscribe_cbe.json");
    if fixture.exists() {
        Some(fixture)
    } else {
        None
    }
}

fn load_fixture() -> Option<Fixture> {
    let Some(path) = locate_fixture() else {
        assert!(
            std::env::var_os("CI").is_none(),
            "event_subscribe_cbe.json is absent under CI — regenerate via \
             `KNOMOSIS_FIXTURES_OVERWRITE=1 lake test`."
        );
        eprintln!("[SKIP] event_subscribe_cbe.json not found; run `lake test`.");
        return None;
    };
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("cannot read {path:?}: {e}"));
    Some(serde_json::from_slice(&bytes).unwrap_or_else(|e| panic!("malformed fixture: {e}")))
}

fn decode_hex(s: &str) -> Vec<u8> {
    let stripped = s
        .strip_prefix("0x")
        .unwrap_or_else(|| panic!("expectedCbe not 0x-prefixed: {s}"));
    hex::decode(stripped).unwrap_or_else(|e| panic!("bad hex ({s}): {e}"))
}

/// Header sanity: identifier pinned, count matches.
#[test]
fn lean_event_fixture_header_ok() {
    let Some(fx) = load_fixture() else { return };
    assert_eq!(fx.header.identifier, EXPECTED_FIXTURE_IDENTIFIER);
    assert_eq!(fx.header.count, fx.entries.len());
}

/// The load-bearing proof: tags 0..=15 decode + re-encode to the
/// EXACT Lean bytes; tags 16..=19 decode to `UnknownTag`.
#[test]
fn lean_event_bytes_round_trip_through_indexer() {
    let Some(fx) = load_fixture() else { return };
    let mut known_seen = 0usize;
    let mut gp_seen = 0usize;
    for e in &fx.entries {
        let bytes = decode_hex(&e.expected_cbe);
        if e.tag <= INDEXER_MAX_KNOWN_TAG {
            let decoded = decode_event(&bytes).unwrap_or_else(|err| {
                panic!(
                    "indexer failed to decode real Lean bytes for {} ({}): {err:?}",
                    e.kind, e.category
                )
            });
            assert_eq!(
                u64::from(decoded.tag()),
                e.tag,
                "decoded tag mismatch for {} ({})",
                e.kind,
                e.category
            );
            // Full Lean → decode → re-encode round-trip: the indexer's
            // encoder reproduces the Lean bytes byte-for-byte.
            let reencoded = encode_event(&decoded);
            assert_eq!(
                reencoded, bytes,
                "indexer re-encode != Lean bytes for {} ({}) — cross-stack wire-format drift",
                e.kind, e.category
            );
            known_seen += 1;
        } else {
            // GP gas-pool family (16..=19): the indexer's mirror does
            // not model these yet; it must reject with UnknownTag, not
            // mis-decode.
            match decode_event(&bytes) {
                Err(DecodeError::UnknownTag { tag }) => assert_eq!(tag, e.tag),
                other => panic!(
                    "expected UnknownTag for GP-family {} ({}), got {other:?}",
                    e.kind, e.category
                ),
            }
            gp_seen += 1;
        }
    }
    // Sanity: the corpus exercised both arms.
    assert!(
        known_seen >= 13,
        "expected the canonical 0..=15 tags, saw {known_seen}"
    );
    assert!(
        gp_seen >= 4,
        "expected the GP-family 16..=19 tags, saw {gp_seen}"
    );
}

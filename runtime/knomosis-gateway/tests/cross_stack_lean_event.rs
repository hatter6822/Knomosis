// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Gateway ↔ Lean cross-stack pin for the §6.2 event envelope.
//!
//! The gateway's `events::decode::render_event` is the **browser-facing**
//! consumer of the CBE event bytes the event-subscribe server streams: it
//! classifies the tag (`knomosis_event_subscribe::event_type::EventClass`),
//! decodes the fields (`knomosis_indexer::decoder::decode_event`), and renders
//! the §6.2 JSON envelope.  The byte authority is the Lean
//! `Encoding.Event.encode` instance, captured by the Lean-generated fixture
//! `solidity/test/CrossCheck/fixtures/event_subscribe_cbe.json` (the same
//! fixture the `knomosis-indexer` byte-round-trip pin and the
//! `knomosis-event-subscribe` tag-head pin consume).
//!
//! This pin proves the gateway agrees with that authority **end to end**: for
//! every frozen constructor (tags `0..=22`), the gateway
//!
//!   * renders the real Lean bytes to a well-formed §6.2 envelope (never a
//!     `Corrupt` / `Unparseable` error), and
//!   * names the event by its canonical type — **never** `"unknown"` for a
//!     frozen tag (the gateway recognises every event the Lean kernel emits).
//!
//! A new Lean constructor that the gateway's classifier/decoder did not learn
//! about would surface here as a `"unknown"`-typed envelope, failing the pin —
//! exactly the cross-stack drift signal the indexer/event-subscribe pins give
//! at the byte/tag layers, lifted to the gateway's JSON contract.
//!
//! Gated on the Lean-generated fixture's presence (written by `lake test`);
//! skips locally when absent, fails under CI.

use std::path::PathBuf;

use knomosis_gateway::events::decode::render_event;
use serde::Deserialize;

/// The highest event tag the frozen Lean `Event` set defines (GP.11.10:
/// `AmmReservesReclaimed` at tag 22).  A fixture tag above this means the Lean
/// corpus grew ahead of this pin — update both in lockstep.
const MAX_KNOWN_TAG: u64 = 22;

/// Pinned generator identifier (a Lean-side version bump forces an explicit
/// update here, so the fixture can never silently change shape).
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
    /// The Lean constructor name — the canonical §11A.5 event-type name the
    /// gateway must render (e.g. `"balanceChanged"`, `"ammReservesReclaimed"`).
    kind: String,
    /// The frozen constructor tag (`0..=22`).
    tag: u64,
    /// `"canonical"` (one per tag) or an edge-case label.
    category: String,
    /// The real Lean `Encoding.Event.encode` bytes, `0x`-hex.
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
    // <repo>/runtime/knomosis-gateway -> <repo>
    let repo = manifest.parent()?.parent()?;
    let fixture = repo
        .join("solidity")
        .join("test")
        .join("CrossCheck")
        .join("fixtures")
        .join("event_subscribe_cbe.json");
    fixture.exists().then_some(fixture)
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

/// Decode a `0x`-prefixed lowercase hex string to bytes (a tiny inline decoder
/// so the pin pulls in no extra dev-dependency).
fn decode_hex(s: &str) -> Vec<u8> {
    let stripped = s
        .strip_prefix("0x")
        .unwrap_or_else(|| panic!("expectedCbe not 0x-prefixed: {s}"));
    assert!(stripped.len() % 2 == 0, "odd-length hex: {s}");
    (0..stripped.len())
        .step_by(2)
        .map(|i| {
            u8::from_str_radix(&stripped[i..i + 2], 16)
                .unwrap_or_else(|e| panic!("bad hex ({s}): {e}"))
        })
        .collect()
}

/// Header sanity: the generator identifier is pinned and the count matches.
#[test]
fn lean_event_fixture_header_ok() {
    let Some(fx) = load_fixture() else { return };
    assert_eq!(fx.header.identifier, EXPECTED_FIXTURE_IDENTIFIER);
    assert_eq!(fx.header.count, fx.entries.len());
}

/// The load-bearing pin: the gateway renders **every** frozen Lean event type
/// from its real CBE bytes to a well-formed §6.2 envelope, naming it by its
/// canonical type — never `"unknown"`, never a decode error.
#[test]
fn gateway_renders_every_frozen_lean_event_type() {
    let Some(fx) = load_fixture() else { return };
    let mut tags_seen = std::collections::BTreeSet::new();
    for (i, e) in fx.entries.iter().enumerate() {
        assert!(
            e.tag <= MAX_KNOWN_TAG,
            "fixture entry {} ({}) has tag {} > {MAX_KNOWN_TAG}; the Lean corpus \
             drifted ahead of the gateway pin",
            e.kind,
            e.category,
            e.tag,
        );
        let bytes = decode_hex(&e.expected_cbe);
        // A distinct (seq, index) per entry so the envelope's identity fields
        // are exercised, not just the body.
        let seq = 1_000 + u64::try_from(i).expect("entry index fits u64");
        let index = u32::try_from(i % 4).expect("0..4 fits u32");
        let rendered = render_event(&bytes, seq, index).unwrap_or_else(|err| {
            panic!(
                "gateway failed to render real Lean bytes for {} ({}): {err}",
                e.kind, e.category
            )
        });
        // The gateway names the event by its canonical Lean constructor — a
        // frozen tag must NEVER fall through to `"unknown"`.
        assert_eq!(
            rendered.event_type, e.kind,
            "gateway rendered tag {} ({}) as type {:?}, expected the Lean name {:?}",
            e.tag, e.category, rendered.event_type, e.kind,
        );
        assert_ne!(
            rendered.event_type, "unknown",
            "a frozen tag {} ({}) must not render as unknown",
            e.tag, e.category,
        );
        // The §6.2 identity fields round-trip the inputs.
        assert_eq!(rendered.seq, seq.to_string());
        assert_eq!(rendered.index, index);
        // The envelope serialises to the §6.2 object shape.
        let value = serde_json::to_value(&rendered).expect("envelope serialises");
        let obj = value.as_object().expect("envelope is a JSON object");
        assert_eq!(
            obj.get("type").and_then(|v| v.as_str()),
            Some(e.kind.as_str())
        );
        assert!(obj.contains_key("seq"));
        assert!(obj.contains_key("index"));
        assert!(obj.contains_key("payload"));
        tags_seen.insert(e.tag);
    }
    // Every frozen tag 0..=22 is exercised (the corpus is complete).
    let expected: std::collections::BTreeSet<u64> = (0..=MAX_KNOWN_TAG).collect();
    assert_eq!(
        tags_seen,
        expected,
        "the fixture must cover every frozen tag 0..={MAX_KNOWN_TAG}; missing {:?}",
        expected.difference(&tags_seen).collect::<Vec<_>>(),
    );
}

/// The §6.2 value rules over real Lean bytes: big integers (amounts, ids,
/// nonces) render as **decimal strings**, and the subject `actor` / `resource`
/// are denormalised for filtering.  Pinned on `balanceChanged` (tag 0), whose
/// canonical fixture entry is `resource 7, actor 42, old 100, new 250`.
#[test]
fn gateway_event_envelope_value_rules() {
    let Some(fx) = load_fixture() else { return };
    let bc = fx
        .entries
        .iter()
        .find(|e| e.tag == 0 && e.category == "canonical")
        .expect("a canonical balanceChanged entry");
    let rendered = render_event(&decode_hex(&bc.expected_cbe), 42, 0).expect("renders");
    assert_eq!(rendered.event_type, "balanceChanged");
    // The subject actor + resource are denormalised as decimal strings.
    assert_eq!(rendered.actor.as_deref(), Some("42"));
    assert_eq!(rendered.resource.as_deref(), Some("7"));
    // The typed payload renders amounts as decimal strings (§6.2), not numbers.
    let payload = &rendered.payload;
    assert_eq!(payload["actor"], "42");
    assert_eq!(payload["resource"], "7");
    assert_eq!(payload["oldValue"], "100");
    assert_eq!(payload["newValue"], "250");
    assert!(
        payload["newValue"].is_string(),
        "a big integer must serialise as a decimal STRING, not a JSON number"
    );
}

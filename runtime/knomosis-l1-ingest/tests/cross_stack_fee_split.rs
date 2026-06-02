// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Cross-stack consistency tests for Workstream GP.6.1.
//!
//! ## What these tests verify
//!
//! Walks the `runtime/tests/cross-stack/l1_ingest_fee_split.cxsf`
//! corpus and, for every record, asserts:
//!
//!   1. The fixture's `input` bytes decode to a valid
//!      `FeeSplitInput`.
//!   2. The Rust-side `FeeSplitInput::split` produces a
//!      `(user_amount, pool_amount, budget_grant)` triple that
//!      satisfies the conservation, pool-cap, and budget-cap
//!      invariants (matching the Lean reference theorems
//!      `feeSplit_conserves`, `feeSplit_pool_le`,
//!      `feeSplit_budget_le_max`).
//!   3. The Rust-side `encode_action(Action::DepositWithFee
//!      { ... })` produces bytes byte-equal to the corpus's
//!      `expected` field — the load-bearing CBE byte-equivalence
//!      contract with the Lean reference encoder.
//!
//! ## Cross-stack equivalence with Lean
//!
//! Like the existing `l1_ingest.cxsf` (RH-B closeout), this
//! corpus's `expected` bytes are produced by the Rust encoder
//! itself.  The byte-equivalence with the Lean reference is
//! established mechanically by the hand-pinned known-vector tests
//! in `encoding::tests` (e.g.
//! `encode_deposit_with_fee_known_vector`,
//! `encode_top_up_action_budget_known_vector`,
//! `encode_top_up_action_budget_for_known_vector`), which
//! byte-compare the Rust encoder's output against bytes
//! independently derived from the Lean side's
//! `LegalKernel.Encoding.Action.encode` recipe.  Once those
//! pin the encoder's per-variant byte layout, the cross-stack
//! corpus pins the encoder's behaviour across the full operator
//! parameter space (240 sweep entries + 8 boundary cases = 248
//! total).
//!
//! ## What this is NOT
//!
//! This corpus does NOT exercise the L1 `KnomosisBridge`
//! contract's `depositETHWithFee` / `depositBoldWithFee` paths
//! directly — that's the GP.5.1 / GP.5.4 Solidity cross-stack
//! corpus (`solidity/test/CrossCheck/DepositFeeSplit.t.sol` and
//! `DepositFeeSplitBold.t.sol`).  This corpus is the Rust-side
//! mirror: the Rust ingestor crate's CBE encoder produces bytes
//! byte-equivalent to the Lean side's `Action.depositWithFee`
//! CBE bytes, for the same fee-split arithmetic the L1 contract
//! uses.  Together, the three corpora cover the Solidity → Rust
//! → Lean trifecta.

use std::collections::HashMap;

use knomosis_cross_stack::{FixtureFile, FixtureKind};
use knomosis_l1_ingest::encoding::encode_action;
use knomosis_l1_ingest::fixture::{decode_fee_split_input, MAX_BUDGET_PER_DEPOSIT};

/// Key for the ETH/BOLD pairing map: the six fee-split inputs
/// that determine the encoded Action bytes (excluding
/// `resource_id`, which is the field we're pairing across).
type PairingKey = (u128, u16, u64, u64, u64, u64);

/// Value stored per pairing key: the ETH-side and BOLD-side
/// expected bytes from the corpus, populated as we iterate.
type PairingSlot = (Option<Vec<u8>>, Option<Vec<u8>>);

/// A derived fee-split triple `(user_amount, pool_amount,
/// budget_grant)`.  Used by the ETH/BOLD split-parity test.
type SplitTriple = (u128, u128, u64);

/// Path to the GP.6.1 fee-split corpus.  Relative to the crate's
/// `CARGO_MANIFEST_DIR`.
fn corpus_path() -> String {
    format!(
        "{}/../tests/cross-stack/l1_ingest_fee_split.cxsf",
        env!("CARGO_MANIFEST_DIR")
    )
}

/// Headline cross-stack contract: every corpus record's
/// `(input, expected)` pair satisfies the encoder's byte-equivalence
/// with the Lean reference.
#[test]
fn fee_split_corpus_round_trip() {
    let fixture = FixtureFile::load(corpus_path()).expect("load fee-split fixture");
    assert!(
        matches!(fixture.kind(), FixtureKind::L1IngestFeeSplit),
        "fixture kind must be L1IngestFeeSplit, got {:?}",
        fixture.kind()
    );
    assert!(
        !fixture.records().is_empty(),
        "fixture must contain at least one record"
    );

    for (i, record) in fixture.records().iter().enumerate() {
        // 1. Input decode.
        let input = decode_fee_split_input(&record.input)
            .unwrap_or_else(|e| panic!("record {i}: decode input failed: {e:?}"));
        // 2. Split arithmetic produces a valid action constructor.
        let action = input.to_action().unwrap_or_else(|| {
            panic!(
                "record {i}: split exceeds encoder bound: msg_value={}, \
                 chosen_fee_bps={}, wei_per_budget_unit={}",
                input.msg_value, input.chosen_fee_bps, input.wei_per_budget_unit
            )
        });
        // 3. CBE encode and byte-compare.
        let actual_bytes = encode_action(&action)
            .unwrap_or_else(|e| panic!("record {i}: encode action failed: {e:?}"));
        assert_eq!(
            actual_bytes, record.expected,
            "record {i}: encoded action bytes differ from expected"
        );
    }
}

/// Coverage smoke check: the corpus has ≥ 50 records (the WU
/// GP.6.1 minimum).  Both ETH and BOLD entries must be present.
#[test]
fn fee_split_corpus_coverage_threshold() {
    let fixture = FixtureFile::load(corpus_path()).expect("load fee-split fixture");
    assert!(
        fixture.records().len() >= 50,
        "WU GP.6.1 requires ≥ 50 entries; got {}",
        fixture.records().len()
    );
    // Verify the corpus covers both resource ids.
    let mut saw_eth = false;
    let mut saw_bold = false;
    for record in fixture.records() {
        let input = decode_fee_split_input(&record.input).expect("decode input");
        if input.resource_id == 0 {
            saw_eth = true;
        }
        if input.resource_id == 1 {
            saw_bold = true;
        }
    }
    assert!(saw_eth, "corpus must include ETH (resource_id = 0) entries");
    assert!(
        saw_bold,
        "corpus must include BOLD (resource_id = 1) entries"
    );
}

/// Mathematical contract: every record's split satisfies
/// conservation `user + pool = msg_value`, pool cap `pool <= value`,
/// and budget cap `budget <= MAX_BUDGET_PER_DEPOSIT`.  Mirrors the
/// Lean reference theorems.
#[test]
fn fee_split_corpus_mathematical_soundness() {
    let fixture = FixtureFile::load(corpus_path()).expect("load fee-split fixture");
    for (i, record) in fixture.records().iter().enumerate() {
        let input = decode_fee_split_input(&record.input)
            .unwrap_or_else(|e| panic!("record {i}: decode input failed: {e:?}"));
        let (user, pool, budget) = input.split();

        // Conservation: user + pool = msg_value.
        assert_eq!(
            user.checked_add(pool)
                .expect("split sums never overflow u128"),
            input.msg_value,
            "record {i}: conservation broken (user + pool != msg_value)"
        );
        // Pool cap.
        assert!(
            pool <= input.msg_value,
            "record {i}: pool > msg_value (chosen_fee_bps may be > 10000)"
        );
        // Budget cap.
        assert!(
            budget <= MAX_BUDGET_PER_DEPOSIT,
            "record {i}: budget grant {budget} exceeds MAX_BUDGET_PER_DEPOSIT {MAX_BUDGET_PER_DEPOSIT}"
        );
        // chosen_fee_bps within the L1-contract admissibility range.
        assert!(
            input.chosen_fee_bps <= 10000,
            "record {i}: chosen_fee_bps > 10000 violates bps semantics"
        );
    }
}

/// ETH/BOLD resource-parametric byte-equivalence: for any pair of
/// records with identical `(msg_value, chosen_fee_bps,
/// wei_per_budget_unit, recipient, pool_actor, deposit_id)` and
/// differing only in `resource_id`, the encoded Action bytes
/// differ ONLY in the byte that encodes `r`.
#[test]
fn fee_split_corpus_resource_parametric_equivalence() {
    let fixture = FixtureFile::load(corpus_path()).expect("load fee-split fixture");

    let mut paired: HashMap<PairingKey, PairingSlot> = HashMap::new();
    for record in fixture.records() {
        let input = decode_fee_split_input(&record.input).expect("decode input");
        let key = (
            input.msg_value,
            input.chosen_fee_bps,
            input.wei_per_budget_unit,
            input.recipient,
            input.pool_actor,
            input.deposit_id,
        );
        let slot = paired.entry(key).or_default();
        match input.resource_id {
            0 => slot.0 = Some(record.expected.clone()),
            1 => slot.1 = Some(record.expected.clone()),
            // Other resource ids (none in this corpus) are
            // ignored for the parametric check.
            _ => {}
        }
    }

    let mut paired_count = 0usize;
    for (key, (eth, bold)) in &paired {
        if let (Some(eth_bytes), Some(bold_bytes)) = (eth, bold) {
            paired_count += 1;
            // Equal lengths (both `Action::DepositWithFee` = 72 bytes).
            assert_eq!(
                eth_bytes.len(),
                bold_bytes.len(),
                "ETH/BOLD pair has divergent byte lengths at key {key:?}"
            );
            // The `r` field is at bytes 9..18 (after the 9-byte tag head).
            // Low byte (index 10) differs: ETH = 0x00, BOLD = 0x01.
            assert_eq!(eth_bytes[10], 0x00);
            assert_eq!(bold_bytes[10], 0x01);
            // Every other byte is identical.
            for (i, (eb, bb)) in eth_bytes.iter().zip(bold_bytes.iter()).enumerate() {
                if i == 10 {
                    continue;
                }
                assert_eq!(
                    eb, bb,
                    "ETH/BOLD bytes differ outside the `r` field at byte {i} (key {key:?})"
                );
            }
        }
    }
    // At least the sweep grid (5 × 6 × 4 = 120) entries are paired.
    assert!(
        paired_count >= 100,
        "expected ≥ 100 ETH/BOLD paired entries, got {paired_count}"
    );
}

/// Calibration parity at the split-arithmetic level: for every
/// `(msg_value, chosen_fee_bps, wei_per_budget_unit)` triple that
/// appears for BOTH the ETH and BOLD legs (identical `recipient` /
/// `pool_actor` / `deposit_id`), the derived
/// `(user_amount, pool_amount, budget_grant)` triples are IDENTICAL.
/// This is the concrete statement of the calibration-parity property
/// the WU spec names: the fee-split economics are resource-agnostic
/// — only the resource tag differs on the wire.  Complements the
/// byte-level `..._resource_parametric_equivalence` test by pinning
/// the property at the arithmetic source rather than the encoded
/// output.
#[test]
fn fee_split_corpus_eth_bold_split_parity() {
    let fixture = FixtureFile::load(corpus_path()).expect("load fee-split fixture");

    // Key on the non-resource fields; collect each leg's derived split.
    let mut paired: HashMap<PairingKey, (Option<SplitTriple>, Option<SplitTriple>)> =
        HashMap::new();
    for record in fixture.records() {
        let input = decode_fee_split_input(&record.input).expect("decode input");
        let key = (
            input.msg_value,
            input.chosen_fee_bps,
            input.wei_per_budget_unit,
            input.recipient,
            input.pool_actor,
            input.deposit_id,
        );
        let slot = paired.entry(key).or_default();
        let split = input.split();
        match input.resource_id {
            0 => slot.0 = Some(split),
            1 => slot.1 = Some(split),
            _ => {}
        }
    }

    let mut checked = 0usize;
    for (key, (eth, bold)) in &paired {
        if let (Some(eth_split), Some(bold_split)) = (eth, bold) {
            checked += 1;
            assert_eq!(
                eth_split, bold_split,
                "ETH/BOLD split parity violated at {key:?}: ETH {eth_split:?} != BOLD {bold_split:?}"
            );
        }
    }
    assert!(
        checked >= 100,
        "expected >= 100 ETH/BOLD split-parity pairs, got {checked}"
    );
}

/// Re-encode determinism: decoding then re-encoding each record's
/// input yields byte-identical bytes (the input format is
/// deterministic).
#[test]
fn fee_split_corpus_input_round_trips() {
    use knomosis_l1_ingest::fixture::encode_fee_split_input;
    let fixture = FixtureFile::load(corpus_path()).expect("load fee-split fixture");
    for (i, record) in fixture.records().iter().enumerate() {
        let input = decode_fee_split_input(&record.input)
            .unwrap_or_else(|e| panic!("record {i}: decode input failed: {e:?}"));
        let re_encoded = encode_fee_split_input(&input);
        assert_eq!(
            re_encoded, record.input,
            "record {i}: input does not round-trip"
        );
    }
}

/// Encoder cross-product determinism: encoding the same Action
/// constructor twice produces identical bytes.  Spot-check using
/// every corpus record.
#[test]
fn fee_split_corpus_encoder_deterministic() {
    let fixture = FixtureFile::load(corpus_path()).expect("load fee-split fixture");
    for (i, record) in fixture.records().iter().enumerate() {
        let input = decode_fee_split_input(&record.input).expect("decode input");
        let action = input.to_action().expect("in-bounds split");
        let e1 = encode_action(&action).expect("encode 1");
        let e2 = encode_action(&action).expect("encode 2");
        assert_eq!(e1, e2, "record {i}: encoder non-deterministic");
    }
}

/// Sanity: every record's expected bytes encode the
/// `DepositWithFee` constructor (tag 19).  This pins the
/// corpus's wire-format identity at the per-record level.
#[test]
fn fee_split_corpus_all_records_are_deposit_with_fee() {
    let fixture = FixtureFile::load(corpus_path()).expect("load fee-split fixture");
    for (i, record) in fixture.records().iter().enumerate() {
        // Expected layout: 9-byte CBE uint head with tag 19 (0x13).
        assert!(
            record.expected.len() >= 9,
            "record {i}: expected bytes too short to contain a CBE uint head"
        );
        assert_eq!(
            record.expected[0], 0x00,
            "record {i}: expected byte 0 != CBE_TAG_UINT"
        );
        // The next 8 bytes are LE u64 = 19.
        let mut tag_bytes = [0u8; 8];
        tag_bytes.copy_from_slice(&record.expected[1..9]);
        assert_eq!(
            u64::from_le_bytes(tag_bytes),
            19,
            "record {i}: constructor tag != 19 (DepositWithFee)"
        );
        // Total length is exactly 72 bytes (8 × 9-byte CBE uint heads).
        assert_eq!(
            record.expected.len(),
            72,
            "record {i}: expected bytes != 72 (DepositWithFee CBE length)"
        );
    }
}

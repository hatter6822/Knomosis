// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Cross-stack consistency tests for Workstream GP.6.5 (BOLD-leg
//! tri-stack budget-mutation corpus).
//!
//! ## What these tests verify
//!
//! Walks the Lean-authored `runtime/tests/cross-stack/l1_ingest_bold.cxsf`
//! corpus (`FixtureKind::L1IngestBold`, on-disk tag 7) and, for every
//! record, asserts that the Lean-authored `expected` bytes equal an
//! INDEPENDENT Rust recompute.  Each record's `expected` field is the
//! 90-byte concatenation
//!
//! ```text
//!   expected[0..72]   = encode_action(Action::DepositWithFee { .. })  (72 bytes)
//!   expected[72..90]  = recipient post-deposit ActorBudget CBE         (18 bytes)
//! ```
//!
//! where the 18-byte budget tail is two 9-byte CBE uint heads —
//! `lastSeenEpoch` (always `0` for a deposit credited from the
//! genesis-empty `EpochBudgetState` at `currentEpoch = 0`,
//! `freeTier = 0`) followed by `budgetBalance` (the `budget_grant`
//! the fee-split arithmetic produces).  This mirrors the Lean
//! admission gate's `EpochBudgetState.topUp recipient 0 0 budgetGrant`
//! applied to an absent cell: `normalise {0,0} 0 0 = {0,0}`, then
//! `topUp` yields `{lastSeenEpoch = 0, budgetBalance = budgetGrant}`.
//!
//! ## Cross-stack equivalence with Lean
//!
//! Unlike the GP.6.1 `l1_ingest_fee_split.cxsf` corpus (whose
//! `expected` bytes the Rust encoder itself produced), THIS corpus's
//! `expected` bytes were authored by the LEAN side (`LegalKernel/Test/
//! Bridge/CrossCheck/BoldDeposit.lean`), using Lean's
//! `Encoding.Action.encode` for the action half and
//! `ActorBudget.encode` for the budget half.  The consumer below does
//! NOT trust those bytes — it recomputes both halves from the decoded
//! 58-byte `FeeSplitInput` via the Rust ingestor's `encode_action`
//! (action half) and `encode_u64` (budget half) and asserts
//! byte-equality.  That independent recompute IS the genuine Lean →
//! Rust differential, now extended to cover the budget-mutation
//! dimension the GP.6.5 spec adds.
//!
//! ## What this is NOT
//!
//! This corpus does NOT exercise the L1 `KnomosisBridge` contract's
//! `depositBoldWithFee` / `depositETHWithFee` paths directly — that is
//! the GP.5.4 Solidity cross-stack corpus
//! (`solidity/test/CrossCheck/BoldDepositFixtures.t.sol`, consuming the
//! sibling `bold_deposit.json`).  Together the Lean generator, this
//! Rust consumer, and the Solidity consumer cover the Lean → Rust →
//! Solidity trifecta over one shared entry list.

use std::collections::HashMap;

use knomosis_cross_stack::{FixtureFile, FixtureKind};
use knomosis_l1_ingest::encoding::{encode_action, encode_u64};
use knomosis_l1_ingest::fixture::{
    decode_fee_split_input, encode_fee_split_input, MAX_BUDGET_PER_DEPOSIT,
};

/// The byte length of every corpus record's `expected` field: the
/// 72-byte `DepositWithFee` action CBE plus the 18-byte recipient
/// `ActorBudget` CBE.
const EXPECTED_RECORD_BYTES: usize = 90;

/// The byte length of the `DepositWithFee` action half: 8 × 9-byte
/// CBE uint heads.
const ACTION_HALF_BYTES: usize = 72;

/// Key for the ETH/BOLD pairing map: the six fee-split inputs that
/// determine the encoded Action bytes (excluding `resource_id`,
/// which is the field we pair across).
type PairingKey = (u128, u16, u64, u64, u64, u64);

/// Value stored per pairing key in the resource-parametric test: the
/// ETH-side and BOLD-side expected bytes from the corpus, populated as
/// the records are iterated.
type PairingSlot = (Option<Vec<u8>>, Option<Vec<u8>>);

/// A derived fee-split triple `(user_amount, pool_amount,
/// budget_grant)`.  Used by the ETH/BOLD split-parity test.
type SplitTriple = (u128, u128, u64);

/// One leg of a USD-calibration pair: the deposit inputs that vary
/// across the pair (`msg_value`, `wei_per_budget_unit`) plus the
/// derived split.  Used by `bold_corpus_usd_calibration_parity` to
/// assert that two cross-amount legs at calibrated rates yield equal
/// budget grants.
struct FeeSplitView {
    msg_value: u128,
    wei_per_budget_unit: u64,
    #[allow(dead_code)]
    user: u128,
    #[allow(dead_code)]
    pool: u128,
    budget: u64,
}

/// Path to the GP.6.5 BOLD corpus.  Relative to the crate's
/// `CARGO_MANIFEST_DIR`.
fn corpus_path() -> String {
    format!(
        "{}/../tests/cross-stack/l1_ingest_bold.cxsf",
        env!("CARGO_MANIFEST_DIR")
    )
}

/// Recompute the canonical 18-byte recipient post-deposit
/// `ActorBudget` CBE tail for a given `budget_grant`: two 9-byte CBE
/// uint heads — `lastSeenEpoch = 0` then `budgetBalance =
/// budget_grant`.
fn recompute_budget_tail(budget_grant: u64) -> Vec<u8> {
    let mut tail = encode_u64(0);
    tail.extend_from_slice(&encode_u64(budget_grant));
    tail
}

/// Headline cross-stack contract: every corpus record's
/// `(input, expected)` pair satisfies the FULL byte-equivalence with
/// an independent Rust recompute — the action half via `encode_action`
/// and the budget half via `encode_u64`.
#[test]
fn bold_corpus_round_trip() {
    let fixture = FixtureFile::load(corpus_path()).expect("load BOLD fixture");
    assert!(
        matches!(fixture.kind(), FixtureKind::L1IngestBold),
        "fixture kind must be L1IngestBold, got {:?}",
        fixture.kind()
    );
    assert!(
        !fixture.records().is_empty(),
        "fixture must contain at least one record"
    );

    for (i, record) in fixture.records().iter().enumerate() {
        // The record's `expected` is exactly 90 bytes: 72-byte action
        // CBE + 18-byte budget CBE.  A wrong length means the Lean
        // fixture layout drifted — fail loudly with the diagnostic.
        assert_eq!(
            record.expected.len(),
            EXPECTED_RECORD_BYTES,
            "record {i}: expected length {} != {EXPECTED_RECORD_BYTES} \
             (action 72 + budget 18); fixture layout drift?",
            record.expected.len()
        );

        // 1. Input decode (strict 58-byte form).
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

        // 3. Action half: CBE encode and byte-compare against
        //    expected[..72].
        let actual_action = encode_action(&action)
            .unwrap_or_else(|e| panic!("record {i}: encode action failed: {e:?}"));
        let expected_action = &record.expected[..ACTION_HALF_BYTES];
        assert_eq!(
            actual_action.as_slice(),
            expected_action,
            "record {i}: action half differs from expected\n  expected: {}\n  actual:   {}\n  \
             decoded input: msg_value={} fee_bps={} wpbu={} resource_id={} recipient={} \
             pool_actor={} deposit_id={}",
            hex(expected_action),
            hex(&actual_action),
            input.msg_value,
            input.chosen_fee_bps,
            input.wei_per_budget_unit,
            input.resource_id,
            input.recipient,
            input.pool_actor,
            input.deposit_id,
        );

        // 4. Budget half: recompute from the split's budget_grant and
        //    byte-compare against expected[72..].
        let (_, _, budget_grant) = input.split();
        let actual_budget = recompute_budget_tail(budget_grant);
        let expected_budget = &record.expected[ACTION_HALF_BYTES..];
        assert_eq!(
            actual_budget.as_slice(),
            expected_budget,
            "record {i}: budget half differs from expected\n  expected: {}\n  actual:   {}\n  \
             budget_grant={budget_grant}",
            hex(expected_budget),
            hex(&actual_budget),
        );
    }
}

/// Coverage smoke check: the corpus has ≥ 50 records (the WU GP.6.5
/// minimum).  Both ETH and BOLD entries must be present.
#[test]
fn bold_corpus_coverage_threshold() {
    let fixture = FixtureFile::load(corpus_path()).expect("load BOLD fixture");
    assert!(
        fixture.records().len() >= 50,
        "WU GP.6.5 requires ≥ 50 entries; got {}",
        fixture.records().len()
    );
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
/// budget cap `budget <= MAX_BUDGET_PER_DEPOSIT`, and the bps
/// semantics bound `chosen_fee_bps <= 10000`.  Mirrors the Lean
/// reference theorems `feeSplit_conserves` / `feeSplit_pool_le` /
/// `feeSplit_budget_le_max`.
#[test]
fn bold_corpus_mathematical_soundness() {
    let fixture = FixtureFile::load(corpus_path()).expect("load BOLD fixture");
    for (i, record) in fixture.records().iter().enumerate() {
        let input = decode_fee_split_input(&record.input)
            .unwrap_or_else(|e| panic!("record {i}: decode input failed: {e:?}"));
        let (user, pool, budget) = input.split();

        assert_eq!(
            user.checked_add(pool)
                .expect("split sums never overflow u128"),
            input.msg_value,
            "record {i}: conservation broken (user + pool != msg_value)"
        );
        assert!(
            pool <= input.msg_value,
            "record {i}: pool > msg_value (chosen_fee_bps may be > 10000)"
        );
        assert!(
            budget <= MAX_BUDGET_PER_DEPOSIT,
            "record {i}: budget grant {budget} exceeds MAX_BUDGET_PER_DEPOSIT {MAX_BUDGET_PER_DEPOSIT}"
        );
        assert!(
            input.chosen_fee_bps <= 10000,
            "record {i}: chosen_fee_bps > 10000 violates bps semantics"
        );
    }
}

/// The headline NEW GP.6.5 dimension: the recipient post-deposit
/// `ActorBudget` carried in `expected[72..]` decodes to
/// `(lastSeenEpoch = 0, budgetBalance = budget_grant)`.  Recompute
/// the canonical 18-byte tail (`encode_u64(0) ++
/// encode_u64(budget_grant)`) and assert byte-equality with the
/// Lean-authored bytes.  This focuses the failure message on the
/// budget half (the round-trip test above also checks it, but a
/// dedicated test pinpoints budget-mutation drift).
#[test]
fn bold_corpus_budget_mutation_matches() {
    let fixture = FixtureFile::load(corpus_path()).expect("load BOLD fixture");
    for (i, record) in fixture.records().iter().enumerate() {
        assert_eq!(
            record.expected.len(),
            EXPECTED_RECORD_BYTES,
            "record {i}: expected length {} != {EXPECTED_RECORD_BYTES}; \
             cannot locate budget half",
            record.expected.len()
        );
        let input = decode_fee_split_input(&record.input)
            .unwrap_or_else(|e| panic!("record {i}: decode input failed: {e:?}"));
        let (_, _, budget_grant) = input.split();

        let expected_budget = &record.expected[ACTION_HALF_BYTES..];

        // Structural check: 18 bytes = two CBE uint heads.  The first
        // head MUST be lastSeenEpoch = 0 (CBE uint with value 0); the
        // second MUST be budgetBalance = budget_grant.
        assert_eq!(
            expected_budget.len(),
            18,
            "record {i}: budget half is {} bytes, not 18",
            expected_budget.len()
        );
        // First 9 bytes: CBE uint head for lastSeenEpoch = 0.
        assert_eq!(
            expected_budget[0], 0x00,
            "record {i}: budget half byte 0 != CBE_TAG_UINT"
        );
        let mut epoch_le = [0u8; 8];
        epoch_le.copy_from_slice(&expected_budget[1..9]);
        assert_eq!(
            u64::from_le_bytes(epoch_le),
            0,
            "record {i}: lastSeenEpoch != 0 (deposit from genesis-empty \
             budget at epoch 0 must have lastSeenEpoch = 0)"
        );
        // Next 9 bytes: CBE uint head for budgetBalance = budget_grant.
        assert_eq!(
            expected_budget[9], 0x00,
            "record {i}: budget half byte 9 != CBE_TAG_UINT"
        );
        let mut balance_le = [0u8; 8];
        balance_le.copy_from_slice(&expected_budget[10..18]);
        assert_eq!(
            u64::from_le_bytes(balance_le),
            budget_grant,
            "record {i}: encoded budgetBalance != recomputed budget_grant"
        );

        // Full-tail byte-equality against the canonical recompute.
        let actual_budget = recompute_budget_tail(budget_grant);
        assert_eq!(
            actual_budget.as_slice(),
            expected_budget,
            "record {i}: budget tail differs from canonical recompute\n  expected: {}\n  \
             actual:   {}\n  budget_grant={budget_grant}",
            hex(expected_budget),
            hex(&actual_budget),
        );
    }
}

/// ETH/BOLD resource-parametric byte-equivalence: for any pair of
/// records with identical `(msg_value, chosen_fee_bps,
/// wei_per_budget_unit, recipient, pool_actor, deposit_id)` and
/// differing only in `resource_id`, the ACTION halves (`expected[..72]`)
/// differ ONLY at byte index 10 (ETH = 0x00, BOLD = 0x01), and the
/// BUDGET halves (`expected[72..]`) are byte-identical (the budget
/// grant is resource-agnostic).
#[test]
fn bold_corpus_resource_parametric_equivalence() {
    let fixture = FixtureFile::load(corpus_path()).expect("load BOLD fixture");

    // Per pairing key: (ETH-side expected, BOLD-side expected).
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
            _ => {}
        }
    }

    let mut paired_count = 0usize;
    for (key, (eth, bold)) in &paired {
        if let (Some(eth_bytes), Some(bold_bytes)) = (eth, bold) {
            paired_count += 1;
            assert_eq!(
                eth_bytes.len(),
                bold_bytes.len(),
                "ETH/BOLD pair has divergent byte lengths at key {key:?}"
            );
            assert_eq!(
                eth_bytes.len(),
                EXPECTED_RECORD_BYTES,
                "ETH/BOLD pair length != {EXPECTED_RECORD_BYTES} at key {key:?}"
            );

            // Action halves: differ only at the resource-field low byte
            // (index 10 = first payload byte of the `r` CBE uint head).
            let eth_action = &eth_bytes[..ACTION_HALF_BYTES];
            let bold_action = &bold_bytes[..ACTION_HALF_BYTES];
            assert_eq!(eth_action[10], 0x00, "ETH action byte 10 != 0x00");
            assert_eq!(bold_action[10], 0x01, "BOLD action byte 10 != 0x01");
            for (i, (eb, bb)) in eth_action.iter().zip(bold_action.iter()).enumerate() {
                if i == 10 {
                    continue;
                }
                assert_eq!(
                    eb, bb,
                    "ETH/BOLD action bytes differ outside the `r` field at byte {i} (key {key:?})"
                );
            }

            // Budget halves: byte-identical (budget grant is the same
            // for the same fee-split inputs regardless of resource).
            assert_eq!(
                &eth_bytes[ACTION_HALF_BYTES..],
                &bold_bytes[ACTION_HALF_BYTES..],
                "ETH/BOLD budget halves differ at key {key:?}"
            );
        }
    }
    // Pinned EXACTLY at the 80 grid twin pairs (4 amounts × 5 fees ×
    // 4 rates).  Only the grid entries share an identical
    // (msg_value, fee, rate, recipient, pool_actor, deposit_id) key
    // across the two legs; the boundary entries use distinct deposit
    // ids and the USD-calibration pairs use distinct amounts, so
    // neither contributes here (the calibration pairs are checked,
    // with their cross-amount property, by
    // `bold_corpus_usd_calibration_parity`).  An exact pin means a
    // corpus regression that silently drops twin coverage cannot hide
    // behind a loose `>= 10` floor.
    assert_eq!(
        paired_count, 80,
        "expected exactly 80 ETH/BOLD grid twin pairs, got {paired_count}"
    );
}

/// Grid resource-agnosticism at the split-arithmetic level: for every
/// `(msg_value, chosen_fee_bps, wei_per_budget_unit)` triple that
/// appears for BOTH legs (identical `recipient` / `pool_actor` /
/// `deposit_id`), the derived `(user_amount, pool_amount,
/// budget_grant)` triples are IDENTICAL.  The fee-split economics are
/// resource-agnostic: same inputs ⇒ same outputs regardless of the
/// resource tag.
///
/// NOTE: this is the SAME-amount property (the grid twins).  The
/// spec's "calibration parity" deliverable — DIFFERENT amounts on the
/// two legs, calibrated to the same USD value, yielding equal budget
/// grants — is the distinct, stronger property checked by
/// `bold_corpus_usd_calibration_parity` below.
#[test]
fn bold_corpus_grid_resource_agnosticism() {
    let fixture = FixtureFile::load(corpus_path()).expect("load BOLD fixture");

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
    // Exactly the 80 grid twin pairs (4 amounts × 5 fees × 4 rates).
    assert_eq!(
        checked, 80,
        "expected exactly 80 ETH/BOLD grid twin pairs, got {checked}"
    );
}

/// USD-calibration parity — the spec's headline calibration deliverable.
///
/// Unlike the grid twins (identical amounts, differing only in the
/// resource tag), these pairs carry DIFFERENT amounts on the two legs,
/// deposited at DIFFERENT per-leg exchange rates, yet — because they
/// are calibrated to the same USD value at the same
/// USD-per-budget-unit rate — must yield EQUAL budget grants.
///
/// The Lean generator emits each calibrated pair sharing a unique
/// `deposit_id` (`2000 +`), so the two legs are paired by `deposit_id`
/// alone here (NOT by amount, which differs by construction).  The
/// calibration is exact (`amount_eth / rate_eth = amount_bold /
/// rate_bold`), so the grants match byte-for-byte — the spec's
/// floor-division-residue tolerance is a conservative bound this
/// corpus beats.  This is the genuine cross-amount property; the
/// same-amount `bold_corpus_grid_resource_agnosticism` test does NOT
/// exercise it.
#[test]
fn bold_corpus_usd_calibration_parity() {
    // The calibration constants must mirror the Lean generator
    // (`calibRateEth` / `calibRateBold` / `calibRatio`).
    const CALIB_RATE_ETH: u128 = 1_000_000_000_000; // 10^12
    const CALIB_RATE_BOLD: u128 = 3_000_000_000_000_000; // 3 · 10^15
    const CALIB_RATIO: u128 = 3000;

    let fixture = FixtureFile::load(corpus_path()).expect("load BOLD fixture");

    // Pair the calibration legs by their shared unique deposit_id.
    // deposit_id >= 2000 is the calibration block (grid = 42,
    // boundary = 1000..=1005).
    let mut by_id: HashMap<u64, (Option<FeeSplitView>, Option<FeeSplitView>)> = HashMap::new();
    for record in fixture.records() {
        let input = decode_fee_split_input(&record.input).expect("decode input");
        if input.deposit_id < 2000 {
            continue;
        }
        let (user, pool, budget) = input.split();
        let view = FeeSplitView {
            msg_value: input.msg_value,
            wei_per_budget_unit: input.wei_per_budget_unit,
            user,
            pool,
            budget,
        };
        let slot = by_id.entry(input.deposit_id).or_default();
        match input.resource_id {
            0 => slot.0 = Some(view),
            1 => slot.1 = Some(view),
            _ => {}
        }
    }

    let mut pairs = 0usize;
    for (did, (eth, bold)) in &by_id {
        let (eth, bold) = match (eth, bold) {
            (Some(e), Some(b)) => (e, b),
            _ => panic!("calibration deposit_id {did} is missing one leg"),
        };
        pairs += 1;

        // The legs MUST carry different amounts (cross-amount), at the
        // two calibrated rates.
        assert_ne!(
            eth.msg_value, bold.msg_value,
            "calibration pair {did} has identical amounts; expected cross-amount legs"
        );
        assert_eq!(
            u128::from(eth.wei_per_budget_unit),
            CALIB_RATE_ETH,
            "calibration pair {did} ETH leg rate != 10^12"
        );
        assert_eq!(
            u128::from(bold.wei_per_budget_unit),
            CALIB_RATE_BOLD,
            "calibration pair {did} BOLD leg rate != 3·10^15"
        );
        // USD alignment: amount_bold == 3000 · amount_eth, equivalently
        // amount_eth · rate_bold == amount_bold · rate_eth.
        assert_eq!(
            bold.msg_value,
            CALIB_RATIO * eth.msg_value,
            "calibration pair {did} amounts not in the 3000:1 ratio"
        );
        assert_eq!(
            eth.msg_value * CALIB_RATE_BOLD,
            bold.msg_value * CALIB_RATE_ETH,
            "calibration pair {did} not USD-aligned (rate cross-product)"
        );

        // The headline property: equal budget grants despite different
        // amounts and rates.
        assert_eq!(
            eth.budget, bold.budget,
            "USD-calibration parity broken at {did}: budget_eth {} != budget_bold {}",
            eth.budget, bold.budget
        );
        // Non-vacuous: each calibrated pair grants a positive budget.
        assert!(
            eth.budget > 0,
            "calibration pair {did} has a zero budget grant (vacuous)"
        );
    }
    assert_eq!(
        pairs, 12,
        "expected exactly 12 USD-calibration pairs, got {pairs}"
    );
}

/// Budget-clamp coverage: the corpus must contain ≥ 5 entries whose
/// fee-split budget grant saturates at `MAX_BUDGET_PER_DEPOSIT` (the
/// clamp boundary the Lean `feeSplit_budget_le_max` theorem and the
/// Solidity `MAX_BUDGET_PER_DEPOSIT` cap enforce).
#[test]
fn bold_corpus_clamp_coverage() {
    let fixture = FixtureFile::load(corpus_path()).expect("load BOLD fixture");
    let mut clamp_count = 0usize;
    for record in fixture.records() {
        let input = decode_fee_split_input(&record.input).expect("decode input");
        let (_, _, budget) = input.split();
        if budget == MAX_BUDGET_PER_DEPOSIT {
            clamp_count += 1;
        }
    }
    assert!(
        clamp_count >= 5,
        "expected ≥ 5 budget-clamp entries (budget == MAX_BUDGET_PER_DEPOSIT), got {clamp_count}"
    );
}

/// Sanity: every record's expected bytes lead with the
/// `DepositWithFee` constructor (tag 19) and are exactly 90 bytes
/// (72-byte action + 18-byte budget).  Pins the corpus's wire-format
/// identity at the per-record level.
#[test]
fn bold_corpus_all_records_are_deposit_with_fee() {
    let fixture = FixtureFile::load(corpus_path()).expect("load BOLD fixture");
    for (i, record) in fixture.records().iter().enumerate() {
        assert_eq!(
            record.expected.len(),
            EXPECTED_RECORD_BYTES,
            "record {i}: expected bytes != {EXPECTED_RECORD_BYTES} \
             (DepositWithFee 72 + ActorBudget 18)"
        );
        // Leading CBE uint head: tag = 19.
        assert_eq!(
            record.expected[0], 0x00,
            "record {i}: expected byte 0 != CBE_TAG_UINT"
        );
        let mut tag_bytes = [0u8; 8];
        tag_bytes.copy_from_slice(&record.expected[1..9]);
        assert_eq!(
            u64::from_le_bytes(tag_bytes),
            19,
            "record {i}: constructor tag != 19 (DepositWithFee)"
        );
    }
}

/// Re-encode determinism: decoding then re-encoding each record's
/// input yields byte-identical bytes (the 58-byte input format is
/// deterministic and round-trips).
#[test]
fn bold_corpus_input_round_trips() {
    let fixture = FixtureFile::load(corpus_path()).expect("load BOLD fixture");
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

/// Lowercase hex helper for diagnostic panic messages (no `0x`
/// prefix).  Kept local to the test crate so the production crate's
/// public surface stays minimal.
fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(nibble(b >> 4));
        s.push(nibble(b & 0x0f));
    }
    s
}

/// Map a 0..=15 nibble to its lowercase-hex character.
fn nibble(n: u8) -> char {
    match n {
        0..=9 => (b'0' + n) as char,
        10..=15 => (b'a' + (n - 10)) as char,
        // Unreachable: `n` is constructed via `b >> 4` or `b & 0x0f`.
        _ => '?',
    }
}

/// Whole-file canonical serialization — the WU GP.6.5 "fixture
/// determinism" structural invariant, consumer side.  The committed
/// `.cxsf` (authored by Lean's `buildCxsf`) re-serializes to itself
/// byte-for-byte through the Rust cross-stack loader's `to_bytes`.
/// This pins TWO things nothing else does: (1) the on-disk corpus
/// carries no extraneous padding or non-canonical framing, and (2)
/// Lean's `.cxsf` container framing (magic / version / kind tag /
/// record count / per-record length prefixes) is byte-identical to
/// the Rust `FixtureFile` serializer — cross-stack agreement on the
/// container format itself, distinct from `bold_corpus_round_trip`
/// (which pins each record's payload derivation).
#[test]
fn bold_corpus_file_is_canonical() {
    let raw = std::fs::read(corpus_path()).expect("read BOLD corpus file");
    let fixture = FixtureFile::load(corpus_path()).expect("load BOLD fixture");
    let reserialized = fixture.to_bytes();
    assert_eq!(
        reserialized, raw,
        "corpus .cxsf is not canonical: Rust re-serialization differs from \
         the committed (Lean-authored) bytes"
    );
}

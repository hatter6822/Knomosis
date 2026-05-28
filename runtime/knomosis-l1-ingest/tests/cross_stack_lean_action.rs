// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! True Lean → Rust CBE-encoder differential for the Workstream-GP
//! `Action` constructors (WU GP.6.1).
//!
//! ## What this is
//!
//! The companion `cross_stack_fee_split.rs` test walks the
//! `l1_ingest_fee_split.cxsf` corpus, whose `expected` bytes are
//! produced by the *Rust* encoder itself — it pins determinism and
//! format stability but is self-referential.  THIS test closes that
//! loop: it loads `deposit_with_fee_action.json`, a fixture whose
//! `expectedCbe` field is computed by running LEAN's
//! `LegalKernel.Encoding.Action.encode` (see
//! `LegalKernel/Test/Bridge/CrossCheck/DepositWithFeeAction.lean`),
//! reconstructs each `Action` from the numeric fields, runs the Rust
//! `encoding::encode_action`, and asserts the two byte streams are
//! identical.
//!
//! This is the genuine cross-stack byte-equivalence pin the WU
//! GP.6.1 "pinned via the Lean reference generator" deliverable
//! calls for: a Rust encoder regression OR a Lean encoder change
//! surfaces here as a byte mismatch.
//!
//! ## Hash independence
//!
//! The `Action` CBE encoding involves no hashing, so the fixture is
//! byte-identical regardless of the kernel's hash binding (FNV vs
//! keccak256).  The cross-check runs unconditionally — there is no
//! `isKeccak256Linked` gate.
//!
//! ## Skip discipline
//!
//! If the fixture file is absent (e.g. a Rust-only CI run that did
//! not run `lake test` first), the test SKIPS with a clear message
//! rather than failing.  Run `lake test` (with
//! `KNOMOSIS_FIXTURES_OVERWRITE=1` if the Lean generator changed) to
//! (re)materialise the fixture.  A present-but-malformed file PANICS
//! (a schema drift must never silently disable the differential).

use std::path::PathBuf;

use knomosis_l1_ingest::action::Action;
use knomosis_l1_ingest::encoding::encode_action;
use knomosis_l1_ingest::fixture::MAX_BUDGET_PER_DEPOSIT;
use serde::Deserialize;

/// The Lean fixture-generator identifier the Rust consumer expects
/// to find in the JSON header.  Bumping the Lean side without
/// updating this value is a deliberate schema-version change; the
/// `lean_action_corpus_identifier_matches` test fails fast so the
/// drift is impossible to miss.
const EXPECTED_FIXTURE_IDENTIFIER: &str = "knomosis-l1-ingest/deposit-with-fee-action/v1";

/// Fixture header — mirrors the Lean generator's `header` object.
///
/// `deny_unknown_fields` is the load-bearing schema-drift defence:
/// if the Lean generator adds a new header key (e.g. a version bump
/// or a new constitutional constant), deserialisation FAILS rather
/// than silently dropping the field.  Every Lean-side key MUST
/// appear here.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Header {
    /// Lean-side generator identifier; pinned by
    /// `lean_action_corpus_identifier_matches`.
    identifier: String,
    /// Total entry count (== `entries.length`).
    count: usize,
    /// Sub-count: depositWithFee entries.
    count_deposit_with_fee: usize,
    /// Sub-count: topUpActionBudget entries.
    count_top_up_budget: usize,
    /// Sub-count: topUpActionBudgetFor entries.
    count_top_up_budget_for: usize,
    /// Per-deposit budget-grant ceiling (the constitutional
    /// constant); cross-checked against the Rust
    /// `MAX_BUDGET_PER_DEPOSIT` by
    /// `lean_action_corpus_max_budget_constant_agrees`.
    max_budget_per_deposit: u64,
    /// Human-readable explanation of the `expectedCbe` field's
    /// semantics.  Deserialised so `deny_unknown_fields` accepts
    /// the Lean JSON; the value is not asserted (informational).
    #[allow(dead_code)]
    note: String,
}

/// One reference vector.  Each variant's fields are `Option` because
/// the three `kind`s share a flat JSON shape; the per-kind
/// reconstruction asserts the fields it needs are present.
///
/// `deny_unknown_fields` ensures a Lean generator that adds a
/// new per-entry key (e.g. a hypothetical `expectedRust`
/// cross-validation field) breaks deserialisation rather than
/// silently dropping it.  Every Lean-side per-entry key MUST
/// appear here.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Entry {
    /// Constructor discriminant: "depositWithFee" /
    /// "topUpActionBudget" / "topUpActionBudgetFor".
    kind: String,
    /// Human-readable category tag (for diagnostic messages).
    category: String,
    // ── depositWithFee fields (None for the topUp* variants) ──
    r: Option<u64>,
    recipient: Option<u64>,
    pool_actor: Option<u64>,
    user_amount: Option<u64>,
    pool_amount: Option<u64>,
    budget_grant: Option<u64>,
    deposit_id: Option<u64>,
    // ── topUpActionBudget(For) fields (None for depositWithFee) ──
    gas_resource: Option<u64>,
    gas_amount: Option<u64>,
    budget_increment: Option<u64>,
    /// The Lean-computed expected CBE bytes, 0x-prefixed lowercase
    /// hex.  The headline cross-stack value the Rust encoder must
    /// reproduce.
    expected_cbe: String,
}

/// Top-level fixture.  `deny_unknown_fields` rejects any top-level
/// key besides `header` and `entries`.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fixture {
    header: Header,
    entries: Vec<Entry>,
}

/// Resolve the fixture path:
/// `<repo>/solidity/test/CrossCheck/fixtures/deposit_with_fee_action.json`.
fn locate_fixture() -> Option<PathBuf> {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // <repo>/runtime/knomosis-l1-ingest -> <repo>
    let repo = manifest.parent()?.parent()?;
    let fixture = repo
        .join("solidity")
        .join("test")
        .join("CrossCheck")
        .join("fixtures")
        .join("deposit_with_fee_action.json");
    if fixture.exists() {
        Some(fixture)
    } else {
        None
    }
}

/// Load the fixture.  Three outcomes:
///
///   * present + well-formed → `Some(fixture)` (test runs);
///   * present + unreadable / malformed → panic with diagnostic
///     (a schema drift can never silently disable the differential);
///   * absent → panic UNDER CI, `None` (skip) locally.
///
/// The CI-fail-on-absence branch is the load-bearing half of the
/// PR #99 review fix: the committed fixture must be present in CI,
/// so a PR that DELETES or MOVES it (or a regeneration that drops it)
/// fails the Rust differential instead of silently skipping.  The
/// local skip is retained so a fresh checkout that has not yet run
/// `lake test` does not spuriously fail.  GitHub Actions sets
/// `CI=true` for every job, so `CI` present ⇒ running under CI.
fn load_fixture() -> Option<Fixture> {
    let Some(path) = locate_fixture() else {
        assert!(
            std::env::var_os("CI").is_none(),
            "deposit_with_fee_action.json is absent under CI — the committed \
             cross-stack fixture MUST be present.  If a PR deleted or moved it, \
             restore it; otherwise regenerate via \
             `KNOMOSIS_FIXTURES_OVERWRITE=1 lake test`."
        );
        return None;
    };
    let bytes = std::fs::read(&path)
        .unwrap_or_else(|e| panic!("fixture exists at {path:?} but cannot be read: {e}"));
    let fixture: Fixture = serde_json::from_slice(&bytes).unwrap_or_else(|e| {
        panic!(
            "fixture at {path:?} is malformed JSON or schema-drifted: {e}.  \
             Rebuild via `KNOMOSIS_FIXTURES_OVERWRITE=1 lake test`."
        )
    });
    Some(fixture)
}

/// Decode a `0x`-prefixed lowercase hex string to bytes.
fn decode_hex(s: &str) -> Vec<u8> {
    let stripped = s.strip_prefix("0x").unwrap_or_else(|| {
        panic!("expectedCbe is not 0x-prefixed: {s}");
    });
    hex::decode(stripped).unwrap_or_else(|e| panic!("expectedCbe is not valid hex ({s}): {e}"))
}

/// Reconstruct the `Action` an entry describes.  Panics with a clear
/// message if a field required by the `kind` is absent — that would
/// indicate a generator/consumer schema disagreement, which must
/// fail loudly.
///
/// Per-kind discipline is enforced TWO ways:
///   * `req` panics on a missing required field for the entry's
///     `kind` (e.g. a `depositWithFee` entry without `r`).
///   * `forbid` panics on a PRESENT field that should NOT exist
///     for the entry's `kind` (e.g. a `depositWithFee` entry with
///     `gasResource`).  Defends against cross-contamination —
///     `Option<_>` flat-shape decoding accepts spurious fields
///     silently, and the byte-equivalence test would still pass
///     because `entry_to_action` doesn't read them — so without
///     this guard, the Lean generator could quietly accumulate
///     wrong-variant fields under each kind and go unnoticed.
fn entry_to_action(e: &Entry) -> Action {
    let req = |o: Option<u64>, name: &str| {
        o.unwrap_or_else(|| {
            panic!(
                "entry {} (kind {}): missing required field {name}",
                e.category, e.kind
            )
        })
    };
    let forbid = |o: Option<u64>, name: &str| {
        assert!(
            o.is_none(),
            "entry {} (kind {}): forbidden field {name} present \
             — wrong-variant cross-contamination",
            e.category,
            e.kind
        );
    };
    match e.kind.as_str() {
        "depositWithFee" => {
            // Forbid any topUp-only field.
            forbid(e.gas_resource, "gasResource");
            forbid(e.gas_amount, "gasAmount");
            forbid(e.budget_increment, "budgetIncrement");
            Action::DepositWithFee {
                r: req(e.r, "r"),
                recipient: req(e.recipient, "recipient"),
                pool_actor: req(e.pool_actor, "poolActor"),
                user_amount: u128::from(req(e.user_amount, "userAmount")),
                pool_amount: u128::from(req(e.pool_amount, "poolAmount")),
                budget_grant: req(e.budget_grant, "budgetGrant"),
                deposit_id: req(e.deposit_id, "depositId"),
            }
        }
        "topUpActionBudget" => {
            // Forbid every depositWithFee-only field AND the
            // delegated-topUp's `recipient`.
            forbid(e.r, "r");
            forbid(e.recipient, "recipient");
            forbid(e.user_amount, "userAmount");
            forbid(e.pool_amount, "poolAmount");
            forbid(e.budget_grant, "budgetGrant");
            forbid(e.deposit_id, "depositId");
            Action::TopUpActionBudget {
                gas_resource: req(e.gas_resource, "gasResource"),
                gas_amount: u128::from(req(e.gas_amount, "gasAmount")),
                budget_increment: req(e.budget_increment, "budgetIncrement"),
                pool_actor: req(e.pool_actor, "poolActor"),
            }
        }
        "topUpActionBudgetFor" => {
            // Forbid every depositWithFee-only field.  (Both topUp
            // variants share gas + pool_actor; topUpActionBudgetFor
            // additionally has `recipient`.)
            forbid(e.r, "r");
            forbid(e.user_amount, "userAmount");
            forbid(e.pool_amount, "poolAmount");
            forbid(e.budget_grant, "budgetGrant");
            forbid(e.deposit_id, "depositId");
            Action::TopUpActionBudgetFor {
                recipient: req(e.recipient, "recipient"),
                gas_resource: req(e.gas_resource, "gasResource"),
                gas_amount: u128::from(req(e.gas_amount, "gasAmount")),
                budget_increment: req(e.budget_increment, "budgetIncrement"),
                pool_actor: req(e.pool_actor, "poolActor"),
            }
        }
        other => panic!("entry {}: unknown kind {other}", e.category),
    }
}

/// Headline differential: every Lean-computed `expectedCbe` equals
/// the Rust `encode_action` output, byte-for-byte.
#[test]
fn lean_action_corpus_byte_equivalence() {
    let Some(fixture) = load_fixture() else {
        eprintln!(
            "[SKIP] deposit_with_fee_action.json not found.  Run `lake test` \
             (with KNOMOSIS_FIXTURES_OVERWRITE=1 if the Lean generator changed) \
             to materialise the cross-stack fixture."
        );
        return;
    };

    assert_eq!(
        fixture.header.count,
        fixture.entries.len(),
        "header count disagrees with entries length"
    );

    for (i, e) in fixture.entries.iter().enumerate() {
        let action = entry_to_action(e);
        let actual = encode_action(&action).unwrap_or_else(|err| {
            panic!("entry {i} ({}): encode_action failed: {err:?}", e.category)
        });
        let expected = decode_hex(&e.expected_cbe);
        assert_eq!(
            actual, expected,
            "entry {i} ({}): Rust encode_action bytes differ from Lean Action.encode",
            e.category
        );
    }
}

/// Coverage: the fixture exercises all three GP-family constructors,
/// and the per-kind counts match the header's declared partition.
#[test]
fn lean_action_corpus_coverage() {
    let Some(fixture) = load_fixture() else {
        eprintln!("[SKIP] deposit_with_fee_action.json not found.");
        return;
    };

    let mut n_dwf = 0usize;
    let mut n_tub = 0usize;
    let mut n_tubf = 0usize;
    for e in &fixture.entries {
        match e.kind.as_str() {
            "depositWithFee" => n_dwf += 1,
            "topUpActionBudget" => n_tub += 1,
            "topUpActionBudgetFor" => n_tubf += 1,
            other => panic!("unexpected kind {other}"),
        }
    }
    assert_eq!(
        n_dwf, fixture.header.count_deposit_with_fee,
        "depositWithFee count disagrees with header"
    );
    assert_eq!(
        n_tub, fixture.header.count_top_up_budget,
        "topUpActionBudget count disagrees with header"
    );
    assert_eq!(
        n_tubf, fixture.header.count_top_up_budget_for,
        "topUpActionBudgetFor count disagrees with header"
    );
    assert!(
        n_dwf > 0 && n_tub > 0 && n_tubf > 0,
        "every kind must be present"
    );
}

/// Schema-version pin: the Lean fixture's header `identifier`
/// matches the constant the Rust consumer expects.  Combined with
/// `deny_unknown_fields` on the `Header`, `Entry`, and `Fixture`
/// structs, this catches any cross-stack schema drift: a
/// gnerator-side version bump, a new header / per-entry key, a
/// renamed key, or a removed key all surface as a typed test
/// failure rather than silently passing.
#[test]
fn lean_action_corpus_identifier_matches() {
    let Some(fixture) = load_fixture() else {
        eprintln!("[SKIP] deposit_with_fee_action.json not found.");
        return;
    };
    assert_eq!(
        fixture.header.identifier, EXPECTED_FIXTURE_IDENTIFIER,
        "fixture identifier disagrees with the Rust consumer's expected version"
    );
}

/// Constitutional-constant cross-stack pin: the fixture header's
/// `maxBudgetPerDeposit` (sourced from the Lean generator) equals the
/// Rust `MAX_BUDGET_PER_DEPOSIT`.  Since the Lean generator's value
/// is itself pinned (by `DepositWithFeeAction.lean`'s
/// `maxBudgetPerDeposit is the constitutional 10^12` test) to the
/// Solidity / `DepositFeeSplit.lean` value, this closes the
/// Lean ↔ Rust leg of the three-way constant agreement.
#[test]
fn lean_action_corpus_max_budget_constant_agrees() {
    let Some(fixture) = load_fixture() else {
        eprintln!("[SKIP] deposit_with_fee_action.json not found.");
        return;
    };
    assert_eq!(
        fixture.header.max_budget_per_deposit, MAX_BUDGET_PER_DEPOSIT,
        "Lean fixture's maxBudgetPerDeposit disagrees with Rust MAX_BUDGET_PER_DEPOSIT"
    );
    assert_eq!(MAX_BUDGET_PER_DEPOSIT, 1_000_000_000_000);
}

/// Per-kind leading-tag pin: every entry's Lean-computed bytes start
/// with the constructor's frozen CBE tag (19 / 20 / 21), independent
/// of the Rust encoder.  Catches a Lean-side frozen-index drift even
/// if (hypothetically) the Rust encoder drifted in lockstep.
#[test]
fn lean_action_corpus_leading_tag_per_kind() {
    let Some(fixture) = load_fixture() else {
        eprintln!("[SKIP] deposit_with_fee_action.json not found.");
        return;
    };
    for e in &fixture.entries {
        let bytes = decode_hex(&e.expected_cbe);
        assert!(bytes.len() >= 9, "entry {}: stream too short", e.category);
        // CBE uint head: byte 0 is the type tag 0x00; bytes 1..9 are
        // the LE u64 constructor tag.
        assert_eq!(
            bytes[0], 0x00,
            "entry {}: byte 0 != CBE_TAG_UINT",
            e.category
        );
        let mut tag = [0u8; 8];
        tag.copy_from_slice(&bytes[1..9]);
        let tag = u64::from_le_bytes(tag);
        let expected_tag = match e.kind.as_str() {
            "depositWithFee" => 19,
            "topUpActionBudget" => 20,
            "topUpActionBudgetFor" => 21,
            other => panic!("unknown kind {other}"),
        };
        assert_eq!(
            tag, expected_tag,
            "entry {} (kind {}): leading tag {tag} != frozen index {expected_tag}",
            e.category, e.kind
        );
    }
}

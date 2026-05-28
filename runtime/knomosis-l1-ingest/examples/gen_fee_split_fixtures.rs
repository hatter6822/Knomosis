// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Cross-stack fee-split fixture generator for WU GP.6.1.
//!
//! Produces `runtime/tests/cross-stack/l1_ingest_fee_split.cxsf`,
//! a `FixtureKind::L1IngestFeeSplit` corpus of `(L1 fee-split
//! inputs, expected CBE-encoded Action::DepositWithFee bytes)`
//! pairs.  Each entry pins:
//!
//!   1. **Fee-split arithmetic** — the Rust-side `FeeSplitInput::
//!      split` produces `(user_amount, pool_amount, budget_grant)`
//!      identical to the Lean side's `feeSplit` and to the L1
//!      contract's `KnomosisBridge.depositETHWithFee` /
//!      `depositBoldWithFee` recipe.
//!   2. **CBE encoder byte-equivalence** — the Rust-side
//!      `encode_action(Action::DepositWithFee { ... })` produces
//!      bytes identical to the Lean side's
//!      `LegalKernel.Encoding.Action.encode (.depositWithFee ...)`.
//!
//! Together, these two contracts certify that an `Action::
//! DepositWithFee` constructed off the L1 inputs (whether through
//! the ingestor, the bridge admission path, or any future
//! sequencer materialisation) carries the same bytes from L1
//! through Rust to the L2 kernel's signature-verification
//! boundary.
//!
//! Run via:
//!
//! ```bash
//! cd runtime
//! cargo run --example gen_fee_split_fixtures -- \
//!     tests/cross-stack/l1_ingest_fee_split.cxsf
//! ```
//!
//! ## Coverage matrix
//!
//! Per the WU GP.6.1 spec (sample across the operator-relevant
//! ranges):
//!
//!   * `chosen_fee_bps ∈ {0, 1, 100, 1000, 2500, 5000}` (6 values).
//!   * `msg_value ∈ {1, 10^9, 10^12, 10^15, 10^18}` (5 values, all
//!     well below `2^64 ≈ 1.84 × 10^19`).
//!   * `wei_per_budget_unit ∈ {1, 10^6, 10^12, 10^15}` (4 values).
//!
//! Cross-product: 6 × 5 × 4 = 120 entries; ALL are included so
//! the corpus is deterministic and exhaustive over the sampled
//! grid (well above the WU's "50+" requirement).
//!
//! For each `(msg_value, chosen_fee_bps, wei_per_budget_unit)`
//! triple, BOTH the ETH (`resource_id = 0`) and BOLD
//! (`resource_id = 1`) entries are emitted, doubling the corpus
//! to 240 entries.  Pairs with the same `(msg_value, bps, rate)`
//! differ only in the `r` field of the encoded Action — a
//! resource-parametric byte-equality the consumer test
//! cross-checks.
//!
//! Additionally, 8 boundary entries:
//!
//!   * `msg_value = u64::MAX` (the encoder's bound; `pool` at
//!     5000 bps ≈ 9.2 × 10^18; both still fit).
//!   * `msg_value = 1, chosen_fee_bps = 0` (rounding edge).
//!   * `msg_value = 10000, chosen_fee_bps = 5000, wei_per_budget_unit = 1`
//!     (exact-half split; budget = 5000).
//!   * `msg_value = 10^18, chosen_fee_bps = 5000, wei_per_budget_unit = 1`
//!     (budget clamp active at 10^12).
//!   * `msg_value = 12345, chosen_fee_bps = 333` (rounding-favours-user).
//!   * Three additional "calibration-parity" pairs covering the
//!     ETH-and-BOLD legs with identical USD-calibrated economics.
//!
//! Total corpus size: 240 + 8 = 248 entries (well above 50).

use std::env;
use std::path::PathBuf;

use knomosis_cross_stack::{FixtureFile, FixtureKind, FixtureRecord};
use knomosis_l1_ingest::encoding::encode_action;
use knomosis_l1_ingest::fixture::{encode_fee_split_input, FeeSplitInput};

/// Resource ids matched to the L1 contract.  ETH = 0; BOLD = 1.
const RESOURCE_ID_ETH: u64 = 0;
const RESOURCE_ID_BOLD: u64 = 1;

/// Deterministic L2 placement constants used across every entry.
/// `recipient` and `pool_actor` are L2 identifiers assigned by the
/// kernel-layer admission path; the fixture sweeps over fee-split
/// parameters with these held fixed so the only varying byte
/// regions are the fee-derived fields.
const FIXED_RECIPIENT: u64 = 7;
const FIXED_POOL_ACTOR: u64 = 2;
const FIXED_DEPOSIT_ID: u64 = 42;

fn main() {
    let args: Vec<String> = env::args().collect();
    let out_path = match args.get(1) {
        Some(p) => PathBuf::from(p),
        None => {
            eprintln!(
                "Usage: gen_fee_split_fixtures <output-path>\n\
                 (typically `runtime/tests/cross-stack/l1_ingest_fee_split.cxsf`)"
            );
            std::process::exit(2);
        }
    };

    let mut fixture = FixtureFile::new(FixtureKind::L1IngestFeeSplit);

    // ===================================================================
    // Sweep matrix: 6 × 5 × 4 × 2 = 240 entries
    // ===================================================================
    // Outer order is deliberately deterministic so the corpus file
    // is byte-identical across runs.
    let fee_bps_grid: [u16; 6] = [0, 1, 100, 1000, 2500, 5000];
    let msg_value_grid: [u128; 5] = [
        1,
        1_000_000_000,             // 10^9 wei (1 gwei)
        1_000_000_000_000,         // 10^12 wei (0.000001 ETH)
        1_000_000_000_000_000,     // 10^15 wei (0.001 ETH)
        1_000_000_000_000_000_000, // 10^18 wei (1 ETH)
    ];
    let wei_per_unit_grid: [u64; 4] = [
        1,
        1_000_000,             // 10^6
        1_000_000_000_000,     // 10^12
        1_000_000_000_000_000, // 10^15
    ];
    let resource_grid: [u64; 2] = [RESOURCE_ID_ETH, RESOURCE_ID_BOLD];

    for &resource_id in &resource_grid {
        for &msg_value in &msg_value_grid {
            for &chosen_fee_bps in &fee_bps_grid {
                for &wei_per_budget_unit in &wei_per_unit_grid {
                    let input = FeeSplitInput {
                        msg_value,
                        chosen_fee_bps,
                        wei_per_budget_unit,
                        resource_id,
                        recipient: FIXED_RECIPIENT,
                        pool_actor: FIXED_POOL_ACTOR,
                        deposit_id: FIXED_DEPOSIT_ID,
                    };
                    push_entry(&mut fixture, input);
                }
            }
        }
    }

    // ===================================================================
    // Boundary entries (8 additional)
    // ===================================================================
    // 1. msg_value just under 2^64 (encoder bound).
    push_entry(
        &mut fixture,
        FeeSplitInput {
            msg_value: u128::from(u64::MAX),
            chosen_fee_bps: 0, // pool = 0, user = u64::MAX -- exact
            wei_per_budget_unit: 1,
            resource_id: RESOURCE_ID_ETH,
            recipient: FIXED_RECIPIENT,
            pool_actor: FIXED_POOL_ACTOR,
            deposit_id: 1,
        },
    );
    // 2. 1 wei, zero fee — the rounding edge case.
    push_entry(
        &mut fixture,
        FeeSplitInput {
            msg_value: 1,
            chosen_fee_bps: 0,
            wei_per_budget_unit: 1,
            resource_id: RESOURCE_ID_ETH,
            recipient: FIXED_RECIPIENT,
            pool_actor: FIXED_POOL_ACTOR,
            deposit_id: 2,
        },
    );
    // 3. Exact-half split at exact-budget-equals-pool rate.
    push_entry(
        &mut fixture,
        FeeSplitInput {
            msg_value: 10_000,
            chosen_fee_bps: 5000,
            wei_per_budget_unit: 1,
            resource_id: RESOURCE_ID_ETH,
            recipient: FIXED_RECIPIENT,
            pool_actor: FIXED_POOL_ACTOR,
            deposit_id: 3,
        },
    );
    // 4. Budget clamp active.
    push_entry(
        &mut fixture,
        FeeSplitInput {
            msg_value: 10u128.pow(18),
            chosen_fee_bps: 5000,
            wei_per_budget_unit: 1,
            resource_id: RESOURCE_ID_ETH,
            recipient: FIXED_RECIPIENT,
            pool_actor: FIXED_POOL_ACTOR,
            deposit_id: 4,
        },
    );
    // 5. Residue-favours-user (12345 × 333 / 10000 = 411 with remainder).
    push_entry(
        &mut fixture,
        FeeSplitInput {
            msg_value: 12_345,
            chosen_fee_bps: 333,
            wei_per_budget_unit: 1,
            resource_id: RESOURCE_ID_ETH,
            recipient: FIXED_RECIPIENT,
            pool_actor: FIXED_POOL_ACTOR,
            deposit_id: 5,
        },
    );
    // 6-7-8. Calibration parity: ETH and BOLD at the same
    // budget-unit count.  The calibration-parity invariant (Lean
    // side: floor-division residue identical up to 1 unit) is
    // checked downstream.  We pick amounts well below 2^64 so the
    // encoder bound holds.
    //
    // BOLD calibration: 30 BOLD-wei × 10^15 = 3 × 10^16 wei,
    //   10% fee = 3 × 10^15 pool, rate 10^12 → budget = 3000.
    push_entry(
        &mut fixture,
        FeeSplitInput {
            msg_value: 30u128 * 10u128.pow(15), // 3 × 10^16 BOLD-wei
            chosen_fee_bps: 1000,
            wei_per_budget_unit: 10u64.pow(12),
            resource_id: RESOURCE_ID_BOLD,
            recipient: FIXED_RECIPIENT,
            pool_actor: FIXED_POOL_ACTOR,
            deposit_id: 6,
        },
    );
    // ETH calibration: 0.01 ETH = 10^16 wei, 10% fee = 10^15 pool,
    //   rate 10^12 → budget = 1000.
    push_entry(
        &mut fixture,
        FeeSplitInput {
            msg_value: 10u128.pow(16),
            chosen_fee_bps: 1000,
            wei_per_budget_unit: 10u64.pow(12),
            resource_id: RESOURCE_ID_ETH,
            recipient: FIXED_RECIPIENT,
            pool_actor: FIXED_POOL_ACTOR,
            deposit_id: 7,
        },
    );
    // ETH-BOLD calibration parity at low TVL: identical inputs
    // with only the resource flipped — produces identical
    // (user, pool, budget) triples.
    push_entry(
        &mut fixture,
        FeeSplitInput {
            msg_value: 10u128.pow(15),
            chosen_fee_bps: 500,
            wei_per_budget_unit: 10u64.pow(9),
            resource_id: RESOURCE_ID_BOLD,
            recipient: FIXED_RECIPIENT,
            pool_actor: FIXED_POOL_ACTOR,
            deposit_id: 8,
        },
    );

    // Write the fixture file.
    if let Some(parent) = out_path.parent() {
        std::fs::create_dir_all(parent).unwrap_or_else(|e| {
            eprintln!("create parent dir: {e}");
            std::process::exit(1);
        });
    }
    fixture.write_to(&out_path).unwrap_or_else(|e| {
        eprintln!("write fixture: {e}");
        std::process::exit(1);
    });
    println!(
        "wrote {} records to {}",
        fixture.records().len(),
        out_path.display()
    );
}

/// Build a fixture record from a `FeeSplitInput`:
///
///   * Input bytes: the 58-byte `encode_fee_split_input` form.
///   * Expected bytes: the CBE-encoded `Action::DepositWithFee`
///     bytes for the derived split.
///
/// Skips entries whose split exceeds the encoder's `u64` field
/// bound (printing a diagnostic).  The sweep matrix is designed
/// so every grid entry is in-bounds; out-of-bounds inputs would
/// only arise from the boundary entries, where we have already
/// verified the bounds hold.
fn push_entry(fixture: &mut FixtureFile, input: FeeSplitInput) {
    let action = match input.to_action() {
        Some(a) => a,
        None => {
            eprintln!(
                "warning: skipping fixture entry with out-of-bounds split: \
                 msg_value={}, chosen_fee_bps={}, wei_per_budget_unit={}",
                input.msg_value, input.chosen_fee_bps, input.wei_per_budget_unit
            );
            return;
        }
    };
    let expected_bytes = encode_action(&action).expect("encode in-bounds action");
    let input_bytes = encode_fee_split_input(&input);
    fixture.push(FixtureRecord::new(input_bytes, expected_bytes));
}

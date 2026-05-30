// SPDX-License-Identifier: GPL-3.0-or-later
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
//! Additionally, 9 boundary entries:
//!
//!   * `msg_value = u64::MAX, chosen_fee_bps = 0` (the encoder's
//!     bound; `user = u64::MAX`, `pool = 0`).
//!   * `msg_value = u64::MAX, chosen_fee_bps = 5000` (BOTH legs near
//!     the bound: `user ≈ pool ≈ 9.2 × 10^18`, budget clamped).
//!   * `msg_value = 1, chosen_fee_bps = 0` (rounding edge).
//!   * `msg_value = 10000, chosen_fee_bps = 5000, wei_per_budget_unit = 1`
//!     (exact-half split; budget = 5000).
//!   * `msg_value = 10^18, chosen_fee_bps = 5000, wei_per_budget_unit = 1`
//!     (budget clamp active at 10^12).
//!   * `msg_value = 12345, chosen_fee_bps = 333` (rounding-favours-user).
//!   * Three representative ETH / BOLD economic-scale entries at
//!     realistic fees and rates.  (Per-`(msg, fee, rate)`
//!     resource-parametric byte-equality is already exhaustively
//!     pinned by the 2-resource grid above, where every triple
//!     appears for both ETH and BOLD with identical
//!     `recipient` / `pool_actor` / `deposit_id`; these three add
//!     economic-scale variety, not new parity coverage.)
//!
//! Total corpus size: 240 + 9 = 249 entries (well above 50).
//!
//! ## Encoder-bound note (WU spec deviation)
//!
//! The WU GP.6.1 spec lists `msg.value ∈ {1, 10⁹, 10¹⁵, 10¹⁸, 10²¹}`.
//! The `10²¹` sample is dropped: the L2 `Action.depositWithFee`
//! encoding bounds `userAmount` and `poolAmount` to `< 2⁶⁴`
//! (`Action.fieldsBounded`), and `2⁶⁴ ≈ 1.84 × 10¹⁹` wei (~18.4 ETH)
//! is the hard ceiling on a single deposit's representable amount.
//! A `10²¹`-wei deposit is therefore unencodable as an L2 Action and
//! would be rejected by the L1 TVL cap long before it reached this
//! path.  The two `msg_value = u64::MAX` boundary entries cover the
//! real ceiling (one with the whole amount on the user leg, one
//! with both legs near the bound).
//!
//! ## Re-generation and CI drift check
//!
//! Two modes:
//!
//!   * `gen_fee_split_fixtures <path>` — (re)write the corpus.
//!   * `gen_fee_split_fixtures --check <path>` — regenerate
//!     in-memory and assert byte-equality with the committed file;
//!     exit non-zero on drift.  This is the CI guard that the
//!     committed `.cxsf` has not diverged from the generator (a
//!     hand-edit, or a generator change without re-running it).

use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

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

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    // Two invocation forms:
    //   gen_fee_split_fixtures <path>            → write the corpus
    //   gen_fee_split_fixtures --check <path>    → verify no drift
    let (check_mode, out_path) = match (args.get(1).map(String::as_str), args.get(2)) {
        (Some("--check"), Some(p)) => (true, PathBuf::from(p)),
        (Some("--check"), None) => {
            eprintln!("Usage: gen_fee_split_fixtures --check <path>");
            return ExitCode::from(2);
        }
        (Some(p), _) => (false, PathBuf::from(p)),
        (None, _) => {
            eprintln!(
                "Usage:\n  \
                 gen_fee_split_fixtures <output-path>            (write)\n  \
                 gen_fee_split_fixtures --check <output-path>    (verify no drift)\n\
                 (typically `runtime/tests/cross-stack/l1_ingest_fee_split.cxsf`)"
            );
            return ExitCode::from(2);
        }
    };

    let fixture = build_fixture();

    if check_mode {
        let on_disk = match std::fs::read(&out_path) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("--check: cannot read {}: {e}", out_path.display());
                return ExitCode::from(1);
            }
        };
        let regenerated = fixture.to_bytes();
        if on_disk == regenerated {
            println!(
                "--check: {} is up to date ({} records)",
                out_path.display(),
                fixture.records().len()
            );
            return ExitCode::SUCCESS;
        }
        eprintln!(
            "--check: DRIFT — {} ({} bytes on disk) differs from the generator's \
             output ({} bytes).  Re-run `cargo run --example gen_fee_split_fixtures -- {}` \
             and commit the result.",
            out_path.display(),
            on_disk.len(),
            regenerated.len(),
            out_path.display()
        );
        return ExitCode::from(1);
    }

    // Write the fixture file.
    if let Some(parent) = out_path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            eprintln!("create parent dir: {e}");
            return ExitCode::from(1);
        }
    }
    if let Err(e) = fixture.write_to(&out_path) {
        eprintln!("write fixture: {e}");
        return ExitCode::from(1);
    }
    println!(
        "wrote {} records to {}",
        fixture.records().len(),
        out_path.display()
    );
    ExitCode::SUCCESS
}

/// Build the full fee-split fixture (240 grid + 9 boundary = 249
/// records).  Deterministic: the same generator always produces
/// byte-identical output, so `--check` is a meaningful drift gate.
fn build_fixture() -> FixtureFile {
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
    // Boundary entries (9 additional)
    // ===================================================================
    // 1. msg_value just under 2^64 (encoder bound), whole amount on
    //    the user leg.
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
    // 1b. msg_value just under 2^64 with a 50% fee: BOTH legs land
    //    near 9.2 × 10^18 (each < 2^64, so both encode), and the
    //    budget clamps.  This is the only entry exercising two
    //    large-but-distinct amount legs simultaneously — the
    //    densest test of the 8-byte LE head on adjacent fields.
    push_entry(
        &mut fixture,
        FeeSplitInput {
            msg_value: u128::from(u64::MAX),
            chosen_fee_bps: 5000,
            wei_per_budget_unit: 1,
            resource_id: RESOURCE_ID_BOLD,
            recipient: FIXED_RECIPIENT,
            pool_actor: FIXED_POOL_ACTOR,
            deposit_id: 9,
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
    // 6-7-8. Representative ETH / BOLD economic-scale entries.
    // These add amount/rate variety at realistic scales; they do
    // NOT carry the resource-parametric parity claim (that is
    // pinned exhaustively by the grid, where every (msg, fee, rate)
    // triple appears for both resources with identical
    // recipient/pool_actor/deposit_id).  Amounts are well below
    // 2^64 so the encoder bound holds.
    //
    // BOLD scale: 30 BOLD-wei × 10^15 = 3 × 10^16 wei,
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
    // ETH scale: 0.01 ETH = 10^16 wei, 10% fee = 10^15 pool,
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
    // Low-TVL BOLD entry at a distinct (fee, rate) scale.
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

    fixture
}

/// Build a fixture record from a `FeeSplitInput`:
///
///   * Input bytes: the 58-byte `encode_fee_split_input` form.
///   * Expected bytes: the CBE-encoded `Action::DepositWithFee`
///     bytes for the derived split.
///
/// PANICS if the split exceeds the encoder's `u64` field bound
/// (i.e. `userAmount` or `poolAmount` >= 2^64) or if encoding
/// otherwise fails.  Every grid + boundary entry is constructed to
/// be in-bounds, so a panic here means the corpus definition itself
/// is wrong — the generator MUST fail loudly rather than silently
/// emit a short corpus (a silent skip could shrink the committed
/// fixture and weaken the cross-stack guarantee undetected).
fn push_entry(fixture: &mut FixtureFile, input: FeeSplitInput) {
    let action = input.to_action().unwrap_or_else(|| {
        panic!(
            "fee-split entry exceeds the u64 encoder bound (corpus definition bug): \
             msg_value={}, chosen_fee_bps={}, wei_per_budget_unit={}",
            input.msg_value, input.chosen_fee_bps, input.wei_per_budget_unit
        )
    });
    let expected_bytes = encode_action(&action).unwrap_or_else(|e| {
        panic!(
            "encode_action failed for an in-bounds entry (corpus definition bug): {e:?} \
             (msg_value={}, chosen_fee_bps={})",
            input.msg_value, input.chosen_fee_bps
        )
    });
    let input_bytes = encode_fee_split_input(&input);
    fixture.push(FixtureRecord::new(input_bytes, expected_bytes));
}

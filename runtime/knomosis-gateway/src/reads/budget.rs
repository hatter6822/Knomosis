// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `GET /v1/actors/{actor}/budget` — the epoch budget view (G1.7),
//! rendered to the OpenAPI `BudgetView` schema.
//!
//! Reads the current epoch, the per-epoch grants + consumed counters,
//! and the cursor under ONE `BEGIN DEFERRED` combined-read transaction
//! (the G1.6a read path), so the whole view is torn-read-free under a
//! concurrent indexer writer (§3.6).
//!
//! `remaining = freeTier + grants − consumed` is a **conservative lower
//! bound** on the kernel's authoritative budget (exact only when
//! `freeTier = 0` or carryover ≤ `freeTier`, §11A.4); the contract's
//! `BudgetView.remaining` description states this, and the exact value
//! awaits the G6 authoritative-read path.  `freeTier` / `actionCost` are
//! the gateway's configured echo of the deployment budget policy.

use knomosis_indexer::budget_view::CURRENT_EPOCH_KEY;
use knomosis_indexer::cursor::CURSOR_KEY;
use serde::Serialize;

use crate::http::RouteOutcome;
use crate::problem::Problem;
use crate::state::ReadState;

/// The OpenAPI `BudgetView` schema.  Numeric fields are decimal
/// strings; `gasBalance` is nullable (the indexer view does not carry
/// the exact gas balance — that is the G6 authoritative read's job).
#[derive(Serialize)]
struct BudgetViewDto {
    #[serde(rename = "actorId")]
    actor_id: String,
    epoch: String,
    #[serde(rename = "freeTier")]
    free_tier: String,
    remaining: String,
    #[serde(rename = "actionCost")]
    action_cost: String,
    #[serde(rename = "gasBalance")]
    gas_balance: Option<String>,
    seq: String,
}

/// `GET /v1/actors/{actor}/budget`.
#[must_use]
pub fn actor_budget(
    reads: &ReadState,
    actor: u64,
    free_tier: u128,
    action_cost: u128,
) -> RouteOutcome {
    // Read epoch + grants + consumed + cursor under ONE DEFERRED
    // combined-read transaction so the whole view is consistent (the
    // budget cells live in SQL tables and the epoch/cursor in the kv
    // table, so a kv-only `StorageSnapshot` cannot span them — the
    // combined-read transaction can).
    let tx = match reads.storage.combined_read_transaction() {
        Ok(t) => t,
        Err(e) => return read_failed("budget read transaction failed", &e.to_string()),
    };
    let epoch_cell = match tx.kv_get(CURRENT_EPOCH_KEY) {
        Ok(c) => c,
        Err(e) => return read_failed("epoch read failed", &e.to_string()),
    };
    let grants = match tx.get_actor_budget_current_epoch_grants(actor) {
        Ok(g) => g,
        Err(e) => return read_failed("grants read failed", &e.to_string()),
    };
    let consumed = match tx.get_actor_budget_current_epoch_consumed(actor) {
        Ok(c) => c,
        Err(e) => return read_failed("consumed read failed", &e.to_string()),
    };
    let cursor_cell = match tx.kv_get(CURSOR_KEY) {
        Ok(c) => c,
        Err(e) => return read_failed("cursor read failed", &e.to_string()),
    };
    if let Err(e) = tx.rollback() {
        return read_failed("budget read rollback failed", &e.to_string());
    }

    let Some(epoch) = crate::reads::decode_control_u64(epoch_cell.as_deref()) else {
        return read_failed("corrupt current_epoch cell", "value is not 8 bytes");
    };
    let Some(seq) = crate::reads::decode_control_u64(cursor_cell.as_deref()) else {
        return read_failed("corrupt cursor cell", "value is not 8 bytes");
    };
    // remaining = free_tier + grants − consumed (saturating); the
    // indexer's `BudgetReadView::remaining_this_epoch` formula.
    let remaining = free_tier.saturating_add(grants).saturating_sub(consumed);

    let dto = BudgetViewDto {
        actor_id: actor.to_string(),
        epoch: epoch.to_string(),
        free_tier: free_tier.to_string(),
        remaining: remaining.to_string(),
        action_cost: action_cost.to_string(),
        gas_balance: None,
        seq: seq.to_string(),
    };
    let body = serde_json::to_string(&dto).unwrap_or_else(|_| "{}".to_string());
    RouteOutcome::json(200, body).with_header("X-Knomosis-Seq", seq.to_string())
}

/// A `500` problem for an unexpected read-backend failure.
fn read_failed(title: &str, detail: &str) -> RouteOutcome {
    Problem::new("read-failed", title, 500)
        .with_detail(detail.to_string())
        .into_outcome()
}

#[cfg(test)]
mod tests {
    use super::actor_budget;
    use crate::state::ReadState;
    use knomosis_indexer::budget_view::CURRENT_EPOCH_KEY;
    use knomosis_indexer::cursor::CURSOR_KEY;
    use knomosis_storage::sqlite::{ReadOnlyOpenOptions, SqliteStorage};
    use knomosis_storage::storage::Storage;

    /// Seed actor 7 with epoch grants 100 / consumed 30, epoch 3, cursor
    /// 42; return the tempdir, the LIVE writer, and a read-only `ReadState`.
    fn seeded() -> (tempfile::TempDir, SqliteStorage, ReadState) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.db");
        let writer = SqliteStorage::open(&path).unwrap();
        let mut tx = writer.combined_transaction().unwrap();
        tx.credit_actor_budget_current_epoch_grants(7, 100).unwrap();
        tx.credit_actor_budget_current_epoch_consumed(7, 30)
            .unwrap();
        tx.commit().unwrap();
        writer.put(CURRENT_EPOCH_KEY, &3u64.to_be_bytes()).unwrap();
        writer.put(CURSOR_KEY, &42u64.to_be_bytes()).unwrap();
        let storage = SqliteStorage::open_read_only(&path, &ReadOnlyOpenOptions::new()).unwrap();
        (dir, writer, ReadState { storage })
    }

    #[test]
    fn budget_view_renders_contract_shape() {
        let (_dir, writer, reads) = seeded();
        // free_tier 50, action_cost 5: remaining = 50 + 100 − 30 = 120.
        let o = actor_budget(&reads, 7, 50, 5);
        assert_eq!(o.status, 200);
        assert_eq!(o.content_type, "application/json");
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["actorId"], "7");
        assert_eq!(v["epoch"], "3");
        assert_eq!(v["freeTier"], "50");
        assert_eq!(v["remaining"], "120");
        assert_eq!(v["actionCost"], "5");
        assert!(v["gasBalance"].is_null());
        assert_eq!(v["seq"], "42");
        assert!(o
            .headers
            .iter()
            .any(|(n, val)| *n == "X-Knomosis-Seq" && val == "42"));
        drop(writer);
    }

    #[test]
    fn unknown_actor_is_free_tier_only() {
        let (_dir, writer, reads) = seeded();
        // Actor 999 has no grants/consumed: remaining = free_tier (50).
        let o = actor_budget(&reads, 999, 50, 0);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["remaining"], "50");
        assert_eq!(v["epoch"], "3");
        drop(writer);
    }

    #[test]
    fn consumed_exceeding_budget_saturates_to_zero() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.db");
        let writer = SqliteStorage::open(&path).unwrap();
        let mut tx = writer.combined_transaction().unwrap();
        tx.credit_actor_budget_current_epoch_grants(7, 10).unwrap();
        tx.credit_actor_budget_current_epoch_consumed(7, 999)
            .unwrap();
        tx.commit().unwrap();
        writer.put(CURSOR_KEY, &1u64.to_be_bytes()).unwrap();
        let storage = SqliteStorage::open_read_only(&path, &ReadOnlyOpenOptions::new()).unwrap();
        let reads = ReadState { storage };
        // free_tier 0 + grants 10 − consumed 999 saturates at 0.
        let o = actor_budget(&reads, 7, 0, 0);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["remaining"], "0");
        drop(writer);
    }
}

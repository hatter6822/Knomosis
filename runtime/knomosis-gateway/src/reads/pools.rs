// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `GET /v1/pools/{pool}?resource={0|1}` — the gas-pool resource view
//! (G1.7), rendered to the OpenAPI `PoolView` schema.
//!
//! Reads the per-(pool-actor, resource) ledger cell and the cursor under
//! ONE `BEGIN DEFERRED` combined-read transaction (the G1.6a read path),
//! so the balance and the `seq` it advertises are torn-read-free under a
//! concurrent indexer writer (§3.6) — the same discipline as the budget
//! view.
//!
//! **`net` semantics.**  The indexer applies pool drains (tag 18
//! `GasPoolClaim`) ONLY to its configured `--gas-pool-actor`; every other
//! pool actor's cell holds gross inflows (tags 16/17/19).  The gateway
//! cannot introspect the indexer's choice (it is not persisted in the
//! database), so the caller passes `net` computed from the gateway's own
//! `--gas-pool-actor` echo: `net = (configured gas-pool-actor == pool)`.
//! A configuration mismatch between the gateway and the indexer is an
//! operator obligation (§9.2), identical to the budget-policy echo.
//!
//! **`resource` domain.**  Pools carry exactly resource `0` (ETH) and
//! `1` (BOLD); any other selector is a `400` (the router has already
//! parsed it as a `u64`, so the domain check lands here, next to the
//! `get_pool_eth` / `get_pool_bold` getters it guards).

use knomosis_indexer::cursor::CURSOR_KEY;
use serde::Serialize;

use crate::http::RouteOutcome;
use crate::problem::Problem;
use crate::state::ReadState;

/// The OpenAPI `PoolView` schema.  `poolId` / `resource` / `balance` /
/// `seq` are decimal strings; `net` is a boolean (true iff the balance
/// is net of drains — i.e. this pool is the configured gas-pool actor).
#[derive(Serialize)]
struct PoolViewDto {
    #[serde(rename = "poolId")]
    pool_id: String,
    resource: String,
    balance: String,
    net: bool,
    seq: String,
}

/// `GET /v1/pools/{pool}?resource={0|1}`.
///
/// `resource` selects the ledger: `0` → `get_pool_eth`, `1` →
/// `get_pool_bold`; any other value is rejected as a `400` before any
/// database work.  `net` is supplied by the dispatcher from the
/// `--gas-pool-actor` echo.  An absent cell reads as `"0"`.
#[must_use]
pub fn pool_view(reads: &ReadState, pool: u64, resource: u64, net: bool) -> RouteOutcome {
    // Reject an unsupported resource selector up front (no DB work for a
    // request that cannot be served).
    if resource > 1 {
        return Problem::new("bad-request", "Bad Request", 400)
            .with_detail(format!(
                "unsupported pool resource {resource} (expected 0 = ETH or 1 = BOLD)"
            ))
            .into_outcome();
    }

    // Read the pool cell + cursor under ONE DEFERRED combined-read
    // transaction so the balance and the seq it advertises are
    // consistent under a concurrent indexer writer.
    let tx = match reads.storage.combined_read_transaction() {
        Ok(t) => t,
        Err(e) => return read_failed("pool read transaction failed", &e.to_string()),
    };
    let balance = if resource == 0 {
        tx.get_pool_eth(pool)
    } else {
        // resource == 1 (the `> 1` case returned above).
        tx.get_pool_bold(pool)
    };
    let balance = match balance {
        Ok(b) => b,
        Err(e) => return read_failed("pool balance read failed", &e.to_string()),
    };
    let cursor_cell = match tx.kv_get(CURSOR_KEY) {
        Ok(c) => c,
        Err(e) => return read_failed("cursor read failed", &e.to_string()),
    };
    if let Err(e) = tx.rollback() {
        return read_failed("pool read rollback failed", &e.to_string());
    }

    let Some(seq) = crate::reads::decode_control_u64(cursor_cell.as_deref()) else {
        return read_failed("corrupt cursor cell", "value is not 8 bytes");
    };

    let dto = PoolViewDto {
        pool_id: pool.to_string(),
        resource: resource.to_string(),
        balance: balance.to_string(),
        net,
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
    use super::pool_view;
    use crate::state::ReadState;
    use knomosis_indexer::cursor::CURSOR_KEY;
    use knomosis_storage::sqlite::{ReadOnlyOpenOptions, SqliteStorage};
    use knomosis_storage::storage::Storage;

    /// Seed pool actor 161 with ETH 1000 / BOLD 200 and cursor 42;
    /// return the tempdir, the LIVE writer, and a read-only `ReadState`.
    fn seeded() -> (tempfile::TempDir, SqliteStorage, ReadState) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.db");
        let writer = SqliteStorage::open(&path).unwrap();
        let mut tx = writer.combined_transaction().unwrap();
        tx.credit_pool_eth(161, 1000).unwrap();
        tx.credit_pool_bold(161, 200).unwrap();
        tx.commit().unwrap();
        writer.put(CURSOR_KEY, &42u64.to_be_bytes()).unwrap();
        let storage = SqliteStorage::open_read_only(&path, &ReadOnlyOpenOptions::new()).unwrap();
        (dir, writer, ReadState { storage })
    }

    #[test]
    fn eth_pool_renders_contract_shape_with_net() {
        let (_dir, writer, reads) = seeded();
        // resource 0 (ETH), net = true (this is the configured pool).
        let o = pool_view(&reads, 161, 0, true);
        assert_eq!(o.status, 200);
        assert_eq!(o.content_type, "application/json");
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["poolId"], "161");
        assert_eq!(v["resource"], "0");
        assert_eq!(v["balance"], "1000");
        assert_eq!(v["net"], true); // JSON boolean, not a string
        assert_eq!(v["seq"], "42");
        assert!(o
            .headers
            .iter()
            .any(|(n, val)| *n == "X-Knomosis-Seq" && val == "42"));
        drop(writer);
    }

    #[test]
    fn bold_pool_selects_bold_ledger_gross() {
        let (_dir, writer, reads) = seeded();
        // resource 1 (BOLD), net = false (a non-configured pool).
        let o = pool_view(&reads, 161, 1, false);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["resource"], "1");
        assert_eq!(v["balance"], "200");
        assert_eq!(v["net"], false);
        drop(writer);
    }

    #[test]
    fn absent_pool_is_zero() {
        let (_dir, writer, reads) = seeded();
        // A pool actor with no inflows reads as balance "0".
        let o = pool_view(&reads, 999, 0, false);
        assert_eq!(o.status, 200);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["poolId"], "999");
        assert_eq!(v["balance"], "0");
        drop(writer);
    }

    #[test]
    fn unsupported_resource_is_bad_request() {
        let (_dir, writer, reads) = seeded();
        // resource 2 is outside the {0, 1} pool domain → 400.
        let o = pool_view(&reads, 161, 2, false);
        assert_eq!(o.status, 400);
        assert_eq!(o.content_type, "application/problem+json");
        assert!(o.body.contains("unsupported pool resource 2"));
        drop(writer);
    }
}

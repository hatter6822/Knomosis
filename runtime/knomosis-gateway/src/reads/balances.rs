// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `GET /v1/actors/{actor}/balances[/{resource}]` — the balance reads
//! (G1.6b), rendered to the OpenAPI `Balance` / `BalanceList` schemas.
//!
//! All numeric fields are decimal strings (§2 bigint-as-string).  Every
//! response carries an `X-Knomosis-Seq` header equal to the indexer
//! cursor the values reflect.

use knomosis_indexer::balance::{parse_balance_key, BalanceView, BALANCE_KEY_PREFIX};
use knomosis_indexer::cursor::{read_cursor, CURSOR_KEY};
use knomosis_storage::storage::Storage;
use serde::Serialize;

use crate::http::RouteOutcome;
use crate::problem::Problem;
use crate::state::ReadState;

/// The OpenAPI `Balance` schema: `{resource, amount, seq}` — all
/// decimal strings.
#[derive(Serialize)]
struct BalanceDto {
    resource: String,
    amount: String,
    seq: String,
}

/// The OpenAPI `BalanceList` schema: `{actorId, balances, seq}`.
#[derive(Serialize)]
struct BalanceListDto {
    #[serde(rename = "actorId")]
    actor_id: String,
    balances: Vec<BalanceDto>,
    seq: String,
}

/// `GET /v1/actors/{actor}/balances/{resource}` — one balance.
///
/// One `BalanceView::get` plus a cursor read.  A single cell tolerates
/// the documented eventual-consistency window (§3.6), so it does not
/// take a snapshot.  An absent cell reads as `"0"`.
#[must_use]
pub fn actor_balance(reads: &ReadState, actor: u64, resource: u64) -> RouteOutcome {
    let view = BalanceView::new(&reads.storage);
    let amount = match view.get(actor, resource) {
        Ok(a) => a,
        Err(e) => return read_failed("balance lookup failed", &e.to_string()),
    };
    let seq = match read_cursor(&reads.storage) {
        Ok(s) => s,
        Err(e) => return read_failed("cursor read failed", &e.to_string()),
    };
    let dto = BalanceDto {
        resource: resource.to_string(),
        amount: amount.to_string(),
        seq: seq.to_string(),
    };
    json_with_seq(&dto, seq).with_header("ETag", balance_etag(actor, Some(resource), seq))
}

/// `GET /v1/actors/{actor}/balances` — all balances for an actor,
/// **snapshot-consistent**: the balance scan and the cursor are read
/// under one `BEGIN DEFERRED` snapshot, so the list and the `seq` it
/// advertises are torn-read-free under a concurrent indexer writer
/// (§3.6).
#[must_use]
pub fn actor_balances(reads: &ReadState, actor: u64) -> RouteOutcome {
    let snap = match reads.storage.snapshot() {
        Ok(s) => s,
        Err(e) => return read_failed("snapshot failed", &e.to_string()),
    };
    let rows = match snap.scan(BALANCE_KEY_PREFIX) {
        Ok(r) => r,
        Err(e) => return read_failed("balance scan failed", &e.to_string()),
    };
    let cursor_cell = match snap.get(CURSOR_KEY) {
        Ok(c) => c,
        Err(e) => return read_failed("cursor read failed", &e.to_string()),
    };
    drop(snap); // release the read lock promptly

    let Some(seq) = crate::reads::decode_control_u64(cursor_cell.as_deref()) else {
        return read_failed("corrupt cursor cell", "cursor value is not 8 bytes");
    };
    let seq_str = seq.to_string();

    let mut balances = Vec::new();
    for (key, value) in &rows {
        // Skip `b/`-prefixed keys that are not canonical balance cells
        // (forward-compat for any future `b/` subkey).
        let Some((row_actor, resource)) = parse_balance_key(key) else {
            continue;
        };
        if row_actor != actor {
            continue;
        }
        let Some(amount) = decode_amount(value) else {
            return read_failed(
                "corrupt balance cell",
                &format!("actor {row_actor} resource {resource}: value is not 16 bytes"),
            );
        };
        balances.push(BalanceDto {
            resource: resource.to_string(),
            amount: amount.to_string(),
            seq: seq_str.clone(),
        });
    }

    let dto = BalanceListDto {
        actor_id: actor.to_string(),
        balances,
        seq: seq_str,
    };
    json_with_seq(&dto, seq).with_header("ETag", balance_etag(actor, None, seq))
}

/// A **weak** ETag validating an actor's balance view at a cursor, keyed
/// on `(actor[, resource], seq)`.  Weak (`W/`) because the cursor
/// advances on *any* indexer update, so the validator may conservatively
/// report "changed" even when this actor's balance did not — acceptable
/// for the contract's revalidation semantics (a missed `304`, never a
/// stale `304`).
fn balance_etag(actor: u64, resource: Option<u64>, seq: u64) -> String {
    match resource {
        Some(r) => format!("W/\"{actor}-{r}-{seq}\""),
        None => format!("W/\"{actor}-{seq}\""),
    }
}

/// Serialize `dto` to JSON and attach the `X-Knomosis-Seq` header.
/// Serialization of these fixed string-field shapes is infallible; the
/// `unwrap_or_else` keeps the path panic-free on the impossible error.
fn json_with_seq<T: Serialize>(dto: &T, seq: u64) -> RouteOutcome {
    let body = serde_json::to_string(dto).unwrap_or_else(|_| "{}".to_string());
    RouteOutcome::json(200, body).with_header("X-Knomosis-Seq", seq.to_string())
}

/// A `500` problem for an unexpected read-backend failure (corruption,
/// I/O).  The detail is operator-facing diagnostics, never client data.
fn read_failed(title: &str, detail: &str) -> RouteOutcome {
    Problem::new("read-failed", title, 500)
        .with_detail(detail.to_string())
        .into_outcome()
}

/// Decode a 16-byte BE `u128` balance value; `None` on the wrong length
/// (corruption).
fn decode_amount(value: &[u8]) -> Option<u128> {
    let bytes: [u8; 16] = value.try_into().ok()?;
    Some(u128::from_be_bytes(bytes))
}

#[cfg(test)]
mod tests {
    use super::{actor_balance, actor_balances};
    use crate::state::ReadState;
    use knomosis_indexer::balance::balance_key;
    use knomosis_indexer::cursor::CURSOR_KEY;
    use knomosis_storage::sqlite::{ReadOnlyOpenOptions, SqliteStorage};
    use knomosis_storage::storage::Storage;

    /// Seed a schema-v2 on-disk DB with balance cells for actors 7 and
    /// 9 and a cursor; return the tempdir, the LIVE writer (kept open so
    /// the read-only reader can map the WAL sidecars), and a `ReadState`
    /// over the same path.
    fn seeded() -> (tempfile::TempDir, SqliteStorage, ReadState) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.db");
        let writer = SqliteStorage::open(&path).unwrap();
        writer
            .put(&balance_key(7, 0), &1_000u128.to_be_bytes())
            .unwrap();
        writer
            .put(&balance_key(7, 1), &250u128.to_be_bytes())
            .unwrap();
        // A different actor's balance — must be excluded from actor 7's list.
        writer
            .put(&balance_key(9, 0), &5u128.to_be_bytes())
            .unwrap();
        writer.put(CURSOR_KEY, &42u64.to_be_bytes()).unwrap();
        let storage = SqliteStorage::open_read_only(&path, &ReadOnlyOpenOptions::new()).unwrap();
        (dir, writer, ReadState { storage })
    }

    #[test]
    fn single_balance_renders_contract_shape() {
        let (_dir, writer, reads) = seeded();
        let o = actor_balance(&reads, 7, 0);
        assert_eq!(o.status, 200);
        assert_eq!(o.content_type, "application/json");
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["resource"], "0");
        assert_eq!(v["amount"], "1000");
        assert_eq!(v["seq"], "42");
        assert!(o
            .headers
            .iter()
            .any(|(n, val)| *n == "X-Knomosis-Seq" && val == "42"));
        drop(writer);
    }

    #[test]
    fn absent_balance_is_zero() {
        let (_dir, writer, reads) = seeded();
        let o = actor_balance(&reads, 7, 99);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["amount"], "0");
        assert_eq!(v["resource"], "99");
        drop(writer);
    }

    #[test]
    fn balance_list_filters_to_actor_and_carries_snapshot_seq() {
        let (_dir, writer, reads) = seeded();
        let o = actor_balances(&reads, 7);
        assert_eq!(o.status, 200);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["actorId"], "7");
        assert_eq!(v["seq"], "42");
        let balances = v["balances"].as_array().unwrap();
        // Actor 7 has resources 0 and 1; actor 9 is excluded.
        assert_eq!(balances.len(), 2);
        for b in balances {
            assert_eq!(b["seq"], "42"); // each entry carries the snapshot seq
        }
        let amounts: Vec<&str> = balances
            .iter()
            .map(|b| b["amount"].as_str().unwrap())
            .collect();
        assert!(amounts.contains(&"1000"));
        assert!(amounts.contains(&"250"));
        assert!(!amounts.contains(&"5")); // actor 9's balance excluded
        assert!(o
            .headers
            .iter()
            .any(|(n, val)| *n == "X-Knomosis-Seq" && val == "42"));
        drop(writer);
    }

    #[test]
    fn empty_actor_list_is_well_formed() {
        let (_dir, writer, reads) = seeded();
        let o = actor_balances(&reads, 12345);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["actorId"], "12345");
        assert_eq!(v["balances"].as_array().unwrap().len(), 0);
        assert_eq!(v["seq"], "42");
        drop(writer);
    }

    #[test]
    fn balance_responses_carry_weak_etag() {
        let (_dir, writer, reads) = seeded();
        // Single balance: weak ETag keyed on (actor, resource, seq).
        let single = actor_balance(&reads, 7, 0);
        assert!(single
            .headers
            .iter()
            .any(|(n, v)| *n == "ETag" && v == "W/\"7-0-42\""));
        // List: weak ETag keyed on (actor, seq).
        let list = actor_balances(&reads, 7);
        assert!(list
            .headers
            .iter()
            .any(|(n, v)| *n == "ETag" && v == "W/\"7-42\""));
        drop(writer);
    }
}

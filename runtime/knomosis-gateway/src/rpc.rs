// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `POST /rpc` — a **minimal, read-only** Ethereum JSON-RPC shim so a
//! browser wallet (MetaMask, Rabby, …) can "Add Network" and target the
//! Knomosis **L2** chain id (`8357` mainnet / `83572` test).
//!
//! Knomosis is **not** an EVM chain: there is no `eth_sendTransaction`, no
//! EVM execution, and no account/state surface here.  An L2 action is
//! submitted through `POST /v1/actions` as a client-signed EIP-712
//! `SignedAction` (the wallet signs the `KnomosisAction` typed-data domain,
//! whose `chainId` is the L2 chain id — see `LegalKernel.Bridge.Eip712`).
//! This endpoint therefore answers **only** the handful of read-only methods
//! a wallet calls when adding + probing a network, which is exactly what
//! makes the wallet accept and display the Knomosis L2 chain id:
//!
//!   * `eth_chainId`        → the L2 chain id as a `0x`-hex quantity
//!   * `net_version`        → the L2 chain id as a decimal string
//!   * `eth_blockNumber`    → the indexer cursor (event `seq`) as a `0x`-hex
//!     height — a monotone "how far the L2 has advanced" counter (there are
//!     no EVM blocks; the cursor is the closest honest analogue), `0x0` when
//!     no indexer is configured
//!   * `web3_clientVersion` → the gateway build string
//!
//! Every other method returns JSON-RPC error `-32601` (method not found):
//! there is deliberately no transaction / account / log surface to expose.
//!
//! **Auth-exempt (like `/healthz`).**  A wallet adding a network cannot
//! present the gateway's bearer service credential, and every value here is
//! public (the chain id, the build string, a monotone counter).  So
//! `/rpc` is in [`crate::auth::is_exempt_path`]; it is `POST`-only and its
//! response is decorated by the same browser-CORS policy as every other
//! route (a browser-direct dApp needs `--cors-origin` set, exactly as for
//! the read endpoints).

use knomosis_indexer::cursor::read_cursor;
use serde_json::{Map, Value};

use crate::dispatch::RequestPayload;
use crate::http::RouteOutcome;
use crate::state::AppState;

/// JSON-RPC 2.0 error code: invalid JSON was received (parse error).
const PARSE_ERROR: i64 = -32_700;
/// JSON-RPC 2.0 error code: the payload was not a valid Request object.
const INVALID_REQUEST: i64 = -32_600;
/// JSON-RPC 2.0 error code: the method does not exist / is not supported.
const METHOD_NOT_FOUND: i64 = -32_601;

/// Maximum request objects in a single JSON-RPC batch.  `/rpc` is auth- and
/// rate-limit-exempt (a wallet cannot present the bearer credential), so an
/// unbounded batch would fan one request out into an unbounded number of
/// response objects — a cheap memory/CPU amplification.  A wallet's
/// Add-Network probe sends single requests or tiny batches, so a small cap
/// removes the amplification with no practical impact (the request body is
/// additionally bounded by `--max-frame-size`).
const MAX_BATCH: usize = 100;

/// Dispatch a `POST /rpc` request.  Reads the request body (the JSON-RPC
/// envelope) and — only for `eth_blockNumber` — the indexer cursor from
/// [`AppState`].  A request is answered HTTP `200` with the JSON-RPC response
/// envelope; a well-formed **Notification** (a request carrying no `id`, and
/// an all-notification batch) is answered `204 No Content` with no body
/// (JSON-RPC 2.0 §4.1: a Notification is not replied to).  Protocol-level
/// failures are carried in the JSON-RPC `error` member, never as a non-2xx
/// status.
#[must_use]
pub fn handle(state: &AppState, payload: &RequestPayload) -> RouteOutcome {
    let l2_chain_id = state.config.l2_chain_id;

    let parsed: Value = match serde_json::from_slice(payload.body) {
        Ok(v) => v,
        Err(_) => {
            return json_response(&error_response(
                Value::Null,
                PARSE_ERROR,
                "invalid JSON in request body",
            ))
        }
    };

    let response: Option<Value> = match parsed {
        // A batch: answer each non-notification member in order (JSON-RPC 2.0
        // §6).  An empty or over-cap batch is itself an invalid request.
        Value::Array(requests) => {
            if requests.is_empty() {
                Some(error_response(Value::Null, INVALID_REQUEST, "empty batch"))
            } else if requests.len() > MAX_BATCH {
                Some(error_response(
                    Value::Null,
                    INVALID_REQUEST,
                    &format!("batch too large (max {MAX_BATCH} requests)"),
                ))
            } else {
                let responses: Vec<Value> = requests
                    .iter()
                    .filter_map(|req| handle_one(req, l2_chain_id, state))
                    .collect();
                // A batch consisting solely of notifications gets no reply.
                if responses.is_empty() {
                    None
                } else {
                    Some(Value::Array(responses))
                }
            }
        }
        obj @ Value::Object(_) => handle_one(&obj, l2_chain_id, state),
        _ => Some(error_response(
            Value::Null,
            INVALID_REQUEST,
            "request must be a JSON object or a batch array",
        )),
    };

    match response {
        Some(v) => json_response(&v),
        // A Notification (or an all-notification batch): 204, no body.
        None => RouteOutcome::no_content(),
    }
}

/// Answer a single JSON-RPC request object.  Returns `None` for a well-formed
/// **Notification** (a request that carries a valid `method` but no `id`),
/// which JSON-RPC 2.0 §4.1 says must not be replied to; otherwise
/// `Some(response)`.  A malformed request (no / non-string `method`) is always
/// answered (with the echoed or `null` id) — it is not a valid Notification.
fn handle_one(req: &Value, l2_chain_id: u64, state: &AppState) -> Option<Value> {
    let id_field = req.get("id");
    let Some(method) = req.get("method").and_then(Value::as_str) else {
        // Invalid request: always answered, id echoed (or null).
        return Some(error_response(
            id_field.cloned().unwrap_or(Value::Null),
            INVALID_REQUEST,
            "missing or non-string \"method\"",
        ));
    };
    // A well-formed request with no `id` is a Notification — not replied to.
    let id = id_field?.clone();
    Some(match method {
        // The `0x`-hex quantity encoding (no leading zeros) MetaMask expects
        // for eth_chainId; e.g. 8357 -> "0x20a5", 83572 -> "0x14674".
        "eth_chainId" => result_response(id, Value::String(format!("0x{l2_chain_id:x}"))),
        // The legacy decimal-string network id.
        "net_version" => result_response(id, Value::String(l2_chain_id.to_string())),
        // The L2 advance counter as a `0x`-hex quantity.  The indexer cursor is
        // read lazily here — only this method needs it, so the other methods
        // (and malformed requests) never touch SQLite.
        "eth_blockNumber" => {
            result_response(id, Value::String(format!("0x{:x}", current_block(state))))
        }
        "web3_clientVersion" => result_response(
            id,
            Value::String(format!("knomosis-gateway/{}", crate::VERSION)),
        ),
        other => error_response(
            id,
            METHOD_NOT_FOUND,
            &format!(
                "method {other:?} is not supported: the Knomosis L2 is not an EVM chain, so \
                 this endpoint answers only eth_chainId, net_version, eth_blockNumber, and \
                 web3_clientVersion (submit L2 actions via POST /v1/actions)"
            ),
        ),
    })
}

/// The current L2 advance height: the indexer cursor (event `seq`) when an
/// indexer is configured + readable, else `0`.  A cursor read failure
/// degrades to `0` rather than surfacing an error — the RPC shim is a
/// best-effort network-probe surface, not an authority on state.
fn current_block(state: &AppState) -> u64 {
    state
        .reads
        .as_ref()
        .and_then(|reads| read_cursor(&reads.storage).ok())
        .unwrap_or(0)
}

/// A JSON-RPC 2.0 success response object.  `id` and `result` are moved into
/// the response map (built explicitly rather than via `json!` so the owned
/// values are consumed in place).
fn result_response(id: Value, result: Value) -> Value {
    let mut obj = Map::new();
    obj.insert("jsonrpc".to_string(), Value::from("2.0"));
    obj.insert("id".to_string(), id);
    obj.insert("result".to_string(), result);
    Value::Object(obj)
}

/// A JSON-RPC 2.0 error response object.  `id` is moved into the response map.
fn error_response(id: Value, code: i64, message: &str) -> Value {
    let mut err = Map::new();
    err.insert("code".to_string(), Value::from(code));
    err.insert("message".to_string(), Value::from(message));
    let mut obj = Map::new();
    obj.insert("jsonrpc".to_string(), Value::from("2.0"));
    obj.insert("id".to_string(), id);
    obj.insert("error".to_string(), Value::Object(err));
    Value::Object(obj)
}

/// Serialise a JSON-RPC response value into a `200 application/json`
/// outcome (a serialisation failure — impossible for these shapes — degrades
/// to an empty object rather than panicking).
fn json_response(value: &Value) -> RouteOutcome {
    RouteOutcome::json(
        200,
        serde_json::to_string(value).unwrap_or_else(|_| "{}".to_string()),
    )
}

#[cfg(test)]
mod tests {
    use super::handle;
    use crate::config::Config;
    use crate::dispatch::RequestPayload;
    use crate::http::RouteOutcome;
    use crate::state::AppState;

    /// A minimal state with the given L2 chain id and no indexer.
    fn state_with_chain_id(l2_chain_id: u64) -> AppState {
        let mut cfg = Config::test_default();
        cfg.l2_chain_id = l2_chain_id;
        AppState::new(cfg).expect("open state")
    }

    /// Dispatch a `POST /rpc` body and return the raw [`RouteOutcome`].
    fn raw_call(state: &AppState, body: &str) -> RouteOutcome {
        let payload = RequestPayload {
            content_type: Some("application/json"),
            body: body.as_bytes(),
            idempotency_key: None,
        };
        handle(state, &payload)
    }

    /// Dispatch a `POST /rpc` body, asserting a `200 application/json`
    /// envelope, and return the parsed JSON.
    fn call(state: &AppState, body: &str) -> serde_json::Value {
        let o = raw_call(state, body);
        assert_eq!(o.status, 200);
        assert_eq!(o.content_type, "application/json");
        serde_json::from_str(&o.body).expect("json body")
    }

    #[test]
    fn eth_chain_id_is_hex_of_configured_l2_chain_id() {
        // 8357 = 0x20a5.
        let v = call(
            &state_with_chain_id(8357),
            r#"{"jsonrpc":"2.0","id":1,"method":"eth_chainId"}"#,
        );
        assert_eq!(v["jsonrpc"], "2.0");
        assert_eq!(v["id"], 1);
        assert_eq!(v["result"], "0x20a5");
    }

    #[test]
    fn eth_chain_id_testnet_hex() {
        // 83572 = 0x14674.
        let v = call(
            &state_with_chain_id(83572),
            r#"{"jsonrpc":"2.0","id":"abc","method":"eth_chainId"}"#,
        );
        assert_eq!(v["id"], "abc"); // string ids echo verbatim
        assert_eq!(v["result"], "0x14674");
    }

    #[test]
    fn net_version_is_decimal_string() {
        let v = call(
            &state_with_chain_id(8357),
            r#"{"jsonrpc":"2.0","id":2,"method":"net_version"}"#,
        );
        assert_eq!(v["result"], "8357");
    }

    #[test]
    fn eth_block_number_is_zero_without_indexer() {
        let v = call(
            &state_with_chain_id(8357),
            r#"{"jsonrpc":"2.0","id":3,"method":"eth_blockNumber"}"#,
        );
        assert_eq!(v["result"], "0x0");
    }

    #[test]
    fn web3_client_version_names_the_gateway() {
        let v = call(
            &state_with_chain_id(8357),
            r#"{"jsonrpc":"2.0","id":4,"method":"web3_clientVersion"}"#,
        );
        let s = v["result"].as_str().expect("string result");
        assert!(s.starts_with("knomosis-gateway/"), "got {s:?}");
    }

    #[test]
    fn unknown_method_is_method_not_found() {
        let v = call(
            &state_with_chain_id(8357),
            r#"{"jsonrpc":"2.0","id":5,"method":"eth_sendTransaction","params":[]}"#,
        );
        assert_eq!(v["error"]["code"], -32601);
        assert!(v.get("result").is_none());
        assert_eq!(v["id"], 5);
    }

    #[test]
    fn parse_error_on_invalid_json() {
        let v = call(&state_with_chain_id(8357), "not json at all");
        assert_eq!(v["error"]["code"], -32700);
        assert!(v["id"].is_null());
    }

    #[test]
    fn missing_method_is_invalid_request() {
        let v = call(&state_with_chain_id(8357), r#"{"jsonrpc":"2.0","id":6}"#);
        assert_eq!(v["error"]["code"], -32600);
        assert_eq!(v["id"], 6);
    }

    #[test]
    fn batch_answers_each_member_in_order() {
        let v = call(
            &state_with_chain_id(8357),
            r#"[{"jsonrpc":"2.0","id":1,"method":"eth_chainId"},
                {"jsonrpc":"2.0","id":2,"method":"net_version"}]"#,
        );
        let arr = v.as_array().expect("array response");
        assert_eq!(arr.len(), 2);
        assert_eq!(arr[0]["result"], "0x20a5");
        assert_eq!(arr[1]["result"], "8357");
    }

    #[test]
    fn empty_batch_is_invalid_request() {
        let v = call(&state_with_chain_id(8357), "[]");
        assert_eq!(v["error"]["code"], -32600);
    }

    #[test]
    fn oversized_batch_is_rejected_without_per_element_work() {
        // A batch above MAX_BATCH is a single invalid-request error — the
        // endpoint is auth- and rate-limit-exempt, so an unbounded batch must
        // not fan out into an unbounded response (memory-amplification DoS).
        let body = format!(
            "[{}]",
            vec![r#"{"jsonrpc":"2.0","id":1,"method":"eth_chainId"}"#; super::MAX_BATCH + 1]
                .join(",")
        );
        let v = call(&state_with_chain_id(8357), &body);
        assert_eq!(v["error"]["code"], -32600);
        // A single error object, not an array of MAX_BATCH+1 responses.
        assert!(v.is_object());
    }

    #[test]
    fn notification_gets_no_reply() {
        // A well-formed request with no `id` is a Notification (JSON-RPC 2.0
        // §4.1): answered 204 with no body, not an id:null response.
        let o = raw_call(
            &state_with_chain_id(8357),
            r#"{"jsonrpc":"2.0","method":"eth_chainId"}"#,
        );
        assert_eq!(o.status, 204);
        assert!(o.body.is_empty());
    }

    #[test]
    fn all_notification_batch_gets_no_reply() {
        // A batch of only notifications yields no reply (204), not an array.
        let o = raw_call(
            &state_with_chain_id(8357),
            r#"[{"jsonrpc":"2.0","method":"eth_chainId"},
                {"jsonrpc":"2.0","method":"net_version"}]"#,
        );
        assert_eq!(o.status, 204);
        assert!(o.body.is_empty());
    }

    #[test]
    fn mixed_batch_replies_only_to_non_notifications() {
        // One request (id) + one notification (no id) → a one-element array.
        let v = call(
            &state_with_chain_id(8357),
            r#"[{"jsonrpc":"2.0","id":1,"method":"eth_chainId"},
                {"jsonrpc":"2.0","method":"net_version"}]"#,
        );
        let arr = v.as_array().expect("array response");
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["id"], 1);
        assert_eq!(arr[0]["result"], "0x20a5");
    }

    #[test]
    fn null_id_request_still_gets_a_reply() {
        // `id: null` is present (a request, not a notification) → answered.
        let v = call(
            &state_with_chain_id(8357),
            r#"{"jsonrpc":"2.0","id":null,"method":"eth_chainId"}"#,
        );
        assert_eq!(v["result"], "0x20a5");
        assert!(v["id"].is_null());
    }
}

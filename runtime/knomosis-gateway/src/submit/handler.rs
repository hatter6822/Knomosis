// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G2.2 `POST /v1/actions` intake: content-negotiate the request body into
//! opaque CBE `SignedAction` bytes, forward them to the host pool (G2.1b),
//! and map the verdict (§5).
//!
//! Two body forms (abi.md §10 / the OpenAPI):
//!   * `application/octet-stream` — the **canonical, zero-dependency**
//!     path: the body *is* the raw CBE bytes.
//!   * `application/json` — an `ActionSubmission` whose `signedAction` is
//!     the same bytes, Base64-encoded.
//!
//! Any other `Content-Type` is a `415`.  The bytes are **forwarded
//! verbatim** — the gateway never inspects, re-encodes, or re-signs them
//! (§8.2, no key custody).

use serde::Deserialize;

use crate::http::RouteOutcome;
use crate::problem::Problem;
use crate::state::AppState;

use super::{base64, verdict_map};

/// The `application/json` submit body (the OpenAPI `ActionSubmission`).
#[derive(Deserialize)]
struct ActionSubmission {
    #[serde(rename = "signedAction")]
    signed_action: String,
    /// Encoding of the decoded bytes; only `cbe` is defined.  Accepted
    /// and validated, but otherwise inert — the bytes are forwarded
    /// opaquely.
    #[serde(default)]
    encoding: Option<String>,
}

/// Handle `POST /v1/actions`.
#[must_use]
pub fn handle(state: &AppState, content_type: Option<&str>, body: &[u8]) -> RouteOutcome {
    // The submit path is available only when a host upstream is configured.
    let Some(pool) = &state.host_pool else {
        return Problem::new("submit-unavailable", "Submit Unavailable", 503)
            .with_detail("the submit path is disabled: the gateway was started without --host-addr")
            .into_outcome();
    };
    let payload = match decode_body(content_type, body) {
        Ok(payload) => payload,
        Err(problem) => return problem,
    };
    if payload.is_empty() {
        return Problem::new("parse-error", "Empty action", 400)
            .with_detail("the submitted SignedAction is empty")
            .into_outcome();
    }
    let result = pool.submit(&payload);
    verdict_map::map_submit_result(result, state.config.ok_admission_stage.as_str())
}

/// Content-negotiate the request body into opaque CBE bytes, or an error
/// outcome (`400` malformed / `415` unsupported media type).
fn decode_body(content_type: Option<&str>, body: &[u8]) -> Result<Vec<u8>, RouteOutcome> {
    // Match the media type prefix, ignoring any parameters (e.g.
    // `; charset=utf-8`) and case (RFC 9110 §8.3.1).
    let media = content_type
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("")
        .trim();

    if media.eq_ignore_ascii_case("application/octet-stream") {
        // Canonical path: the body is the raw CBE bytes.
        Ok(body.to_vec())
    } else if media.eq_ignore_ascii_case("application/json") {
        let submission: ActionSubmission = serde_json::from_slice(body).map_err(|e| {
            Problem::new("parse-error", "Malformed JSON", 400)
                .with_detail(format!("invalid ActionSubmission JSON: {e}"))
                .into_outcome()
        })?;
        if let Some(encoding) = &submission.encoding {
            if !encoding.eq_ignore_ascii_case("cbe") {
                return Err(Problem::new("parse-error", "Unsupported encoding", 400)
                    .with_detail(format!(
                        "unsupported encoding {encoding:?}; only \"cbe\" is defined"
                    ))
                    .into_outcome());
            }
        }
        base64::decode(&submission.signed_action).ok_or_else(|| {
            Problem::new("parse-error", "Malformed base64", 400)
                .with_detail("signedAction is not valid standard Base64")
                .into_outcome()
        })
    } else {
        Err(Problem::new("unsupported-media-type", "Unsupported Media Type", 415)
            .with_detail(format!(
                "unsupported Content-Type {media:?}; use application/octet-stream or application/json"
            ))
            .into_outcome())
    }
}

#[cfg(test)]
mod tests {
    use super::decode_body;

    #[test]
    fn octet_stream_is_the_raw_body() {
        let bytes = b"\x01\x02opaque-cbe";
        assert_eq!(
            decode_body(Some("application/octet-stream"), bytes).unwrap(),
            bytes
        );
        // Content-Type parameters + case are tolerated.
        assert_eq!(
            decode_body(Some("Application/Octet-Stream; charset=binary"), bytes).unwrap(),
            bytes
        );
    }

    #[test]
    fn json_body_base64_decodes_signed_action() {
        // "Zm9vYmFy" is base64("foobar").
        let body = br#"{"signedAction":"Zm9vYmFy","encoding":"cbe"}"#;
        assert_eq!(
            decode_body(Some("application/json"), body).unwrap(),
            b"foobar"
        );
        // `encoding` is optional.
        let body = br#"{"signedAction":"Zm9v"}"#;
        assert_eq!(decode_body(Some("application/json"), body).unwrap(), b"foo");
    }

    #[test]
    fn malformed_json_or_base64_is_400() {
        // Not JSON.
        let err = decode_body(Some("application/json"), b"not json").unwrap_err();
        assert_eq!(err.status, 400);
        // Valid JSON, invalid base64.
        let body = br#"{"signedAction":"!!!!"}"#;
        assert_eq!(
            decode_body(Some("application/json"), body)
                .unwrap_err()
                .status,
            400
        );
        // Valid JSON, unsupported encoding.
        let body = br#"{"signedAction":"Zm9v","encoding":"json"}"#;
        assert_eq!(
            decode_body(Some("application/json"), body)
                .unwrap_err()
                .status,
            400
        );
    }

    #[test]
    fn unsupported_or_absent_content_type_is_415() {
        assert_eq!(
            decode_body(Some("text/plain"), b"x").unwrap_err().status,
            415
        );
        assert_eq!(decode_body(None, b"x").unwrap_err().status, 415);
    }
}

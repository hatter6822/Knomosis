// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! RFC 9457 (Problem Details for HTTP APIs) responder + error taxonomy.
//!
//! Every gateway error path emits an `application/problem+json` body
//! built from [`Problem`], with a stable `type` URI under
//! [`ERROR_TYPE_BASE`] so consumers branch on the machine-readable id
//! rather than the human `title`.  Per §7 of the plan, verdict reasons
//! ride in the `knomosisReason` extension and backpressure / truncation
//! ride in `retryAfterMs` / `oldestSeq`.
//!
//! **Surface (G1.2b / G1.5).**  The `not-found` and `method-not-allowed`
//! problems the router needs, plus the generic [`Problem::new`] builder.
//! The rest of the taxonomy (parse-error, busy, upstream, decode-error,
//! …) is added alongside the endpoints that raise it (G2 / G3), each a
//! `Problem::new` with its own `type` suffix and extension members.

use serde::Serialize;

use crate::http::RouteOutcome;

/// The stable base URI for gateway problem `type` identifiers.  A
/// problem's `type` is `ERROR_TYPE_BASE + <suffix>`, e.g.
/// `https://knomosis/errors/not-found`.
pub const ERROR_TYPE_BASE: &str = "https://knomosis/errors/";

/// An RFC 9457 problem-details object, serialized to
/// `application/problem+json`.
///
/// The extension members (`knomosisReason`, `oldestSeq`,
/// `retryAfterMs`) are omitted from the wire body when absent, so a
/// minimal problem serializes to just `{type, title, status}`.  Big
/// integers (`oldestSeq`) are decimal strings per the §2 bigint-as-
/// string rule; `retryAfterMs` is a bounded small duration and stays a
/// number.
#[derive(Clone, Debug, Serialize, Eq, PartialEq)]
pub struct Problem {
    /// A stable URI identifying the problem type (machine-branchable).
    #[serde(rename = "type")]
    pub type_uri: String,
    /// A short, human-readable summary of the problem type.
    pub title: String,
    /// The HTTP status code, duplicated in the body per RFC 9457.
    pub status: u16,
    /// A human-readable explanation specific to this occurrence.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// An id for this specific occurrence — the per-request id, threaded
    /// from the server's observability layer (G4.3).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instance: Option<String>,
    /// Extension: the kernel verdict reason (the `BudgetGate*` family,
    /// `InsufficientBudget`, …) passed through verbatim (§5).
    #[serde(rename = "knomosisReason", skip_serializing_if = "Option::is_none")]
    pub knomosis_reason: Option<String>,
    /// Extension: the oldest retained seq for a `truncated` problem
    /// (§6), a decimal string per the bigint-as-string rule.
    #[serde(rename = "oldestSeq", skip_serializing_if = "Option::is_none")]
    pub oldest_seq: Option<String>,
    /// Extension: the backpressure retry hint, in milliseconds (§7).
    #[serde(rename = "retryAfterMs", skip_serializing_if = "Option::is_none")]
    pub retry_after_ms: Option<u64>,
}

impl Problem {
    /// Construct a problem with the given `type` suffix (appended to
    /// [`ERROR_TYPE_BASE`]), `title`, and `status`; no detail and no
    /// extension members.
    #[must_use]
    pub fn new(type_suffix: &str, title: &str, status: u16) -> Self {
        Self {
            type_uri: format!("{ERROR_TYPE_BASE}{type_suffix}"),
            title: title.to_string(),
            status,
            detail: None,
            instance: None,
            knomosis_reason: None,
            oldest_seq: None,
            retry_after_ms: None,
        }
    }

    /// Attach a human-readable `detail` for this occurrence.
    #[must_use]
    pub fn with_detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = Some(detail.into());
        self
    }

    /// Attach the per-request `instance` id (the observability layer's
    /// request id; G4.3).
    #[must_use]
    pub fn with_instance(mut self, instance: impl Into<String>) -> Self {
        self.instance = Some(instance.into());
        self
    }

    /// Attach the `retryAfterMs` extension (the suggested wait before
    /// retrying) — emitted on `429` / `503` backpressure responses
    /// alongside the HTTP `Retry-After` header.
    #[must_use]
    pub fn with_retry_after_ms(mut self, retry_after_ms: u64) -> Self {
        self.retry_after_ms = Some(retry_after_ms);
        self
    }

    /// Attach the `oldestSeq` extension (the oldest still-resumable
    /// sequence number) — emitted on the `409` truncated-cursor response
    /// (§6) so a behind-window backfill client knows where to re-resume.
    /// A decimal string per the bigint-as-string rule.
    #[must_use]
    pub fn with_oldest_seq(mut self, oldest_seq: u64) -> Self {
        self.oldest_seq = Some(oldest_seq.to_string());
        self
    }

    /// `404 Not Found` for an unrouted path.
    #[must_use]
    pub fn not_found(path: &str) -> Self {
        Self::new("not-found", "Not Found", 404).with_detail(format!("no route for {path}"))
    }

    /// `405 Method Not Allowed`.  The caller adds the `Allow` header
    /// (it knows which methods the matched path permits).
    #[must_use]
    pub fn method_not_allowed() -> Self {
        Self::new("method-not-allowed", "Method Not Allowed", 405)
    }

    /// Render this problem as a [`RouteOutcome`]
    /// (`application/problem+json` body, the problem's status).
    ///
    /// Serialization of this fixed `String`/`u16`/`Option` shape is
    /// infallible; on the impossible `serde_json` error we fall back to
    /// a minimal hand-written body so the path stays **panic-free**
    /// (the §3.2 `panic = "abort"` constraint).
    #[must_use]
    pub fn into_outcome(self) -> RouteOutcome {
        let status = self.status;
        let body = serde_json::to_string(&self).unwrap_or_else(|_| {
            format!(
                "{{\"type\":\"{ERROR_TYPE_BASE}internal\",\
                 \"title\":\"Internal Error\",\"status\":{status}}}"
            )
        });
        RouteOutcome::problem(status, body)
    }
}

#[cfg(test)]
mod tests {
    use super::{Problem, ERROR_TYPE_BASE};

    #[test]
    fn not_found_shape() {
        let outcome = Problem::not_found("/v1/nope").into_outcome();
        assert_eq!(outcome.status, 404);
        assert_eq!(outcome.content_type, "application/problem+json");
        let v: serde_json::Value = serde_json::from_str(&outcome.body).unwrap();
        assert_eq!(v["type"], format!("{ERROR_TYPE_BASE}not-found"));
        assert_eq!(v["title"], "Not Found");
        assert_eq!(v["status"], 404);
        assert!(v["detail"].as_str().unwrap().contains("/v1/nope"));
        // Absent extension members are omitted from the wire body.
        assert!(v.get("knomosisReason").is_none());
        assert!(v.get("instance").is_none());
    }

    #[test]
    fn method_not_allowed_shape() {
        let p = Problem::method_not_allowed();
        assert_eq!(p.status, 405);
        let outcome = p.into_outcome();
        let v: serde_json::Value = serde_json::from_str(&outcome.body).unwrap();
        assert_eq!(v["type"], format!("{ERROR_TYPE_BASE}method-not-allowed"));
        assert_eq!(v["status"], 405);
    }

    #[test]
    fn extension_members_serialize_with_camel_case_keys() {
        let mut p = Problem::new("busy", "Service Busy", 503);
        p.knomosis_reason = Some("Busy".to_string());
        p.oldest_seq = Some("42".to_string());
        p.retry_after_ms = Some(250);
        p.instance = Some("req-123".to_string());
        let body = serde_json::to_string(&p).unwrap();
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["knomosisReason"], "Busy");
        // The seq is a decimal STRING (bigint-as-string rule).
        assert_eq!(v["oldestSeq"], "42");
        // retryAfterMs is a number.
        assert_eq!(v["retryAfterMs"], 250);
        assert_eq!(v["instance"], "req-123");
    }
}

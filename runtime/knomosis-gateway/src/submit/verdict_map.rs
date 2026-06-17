// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G2.2 verdict → HTTP mapping (the authoritative §5 table).
//!
//! Rule: *processing-succeeded-but-kernel-declined* is **200**, not 4xx —
//! a budget/policy rejection is a normal, displayable outcome, so it
//! returns the `VerdictResponse` body with `accepted: false`, not an
//! error status.
//!
//! | verdict / condition          | HTTP                    |
//! |------------------------------|-------------------------|
//! | `Ok`                         | `200` `{accepted:true}` |
//! | `NotAdmissible`              | `200` `{accepted:false}`|
//! | `ParseError`                 | `400` problem+json      |
//! | `Busy`                       | `503` + `Retry-After`   |
//! | pool saturated               | `503` + `Retry-After`   |
//! | payload too large            | `413` problem+json      |
//! | connect / I/O / bad response | `502` problem+json      |

use serde::Serialize;

use knomosis_host::verdict::{Verdict, VerdictResponse};

use crate::http::RouteOutcome;
use crate::problem::Problem;
use crate::submit::pool::SubmitError;

/// The OpenAPI `VerdictResponse` body for an `Ok` / `NotAdmissible`
/// outcome.  `reason` / `admissionStage` / `seq` are present-and-nullable
/// (the §5 schema's `[string, "null"]`).
#[derive(Serialize)]
struct VerdictDto {
    accepted: bool,
    verdict: &'static str,
    reason: Option<String>,
    #[serde(rename = "admissionStage")]
    admission_stage: Option<String>,
    seq: Option<String>,
}

/// Map a host submit result to its HTTP response (§5).  `admission_stage`
/// is the gateway's configured `okAdmissionStage`, echoed on an `Ok`.
#[must_use]
pub fn map_submit_result(
    result: Result<VerdictResponse, SubmitError>,
    admission_stage: &str,
) -> RouteOutcome {
    match result {
        Ok(response) => map_verdict(&response, admission_stage),
        Err(err) => map_error(&err),
    }
}

/// Map a successfully-read verdict to its response.
fn map_verdict(response: &VerdictResponse, admission_stage: &str) -> RouteOutcome {
    match response.verdict {
        Verdict::Ok => verdict_body(&VerdictDto {
            accepted: true,
            verdict: "Ok",
            reason: None,
            admission_stage: Some(admission_stage.to_string()),
            // The host verdict frame carries no seq today (OQ-GW-6).
            seq: None,
        }),
        Verdict::NotAdmissible => verdict_body(&VerdictDto {
            accepted: false,
            verdict: "NotAdmissible",
            // An empty reason serialises as null.
            reason: (!response.reason.is_empty()).then(|| response.reason.clone()),
            admission_stage: None,
            seq: None,
        }),
        // The client's bytes failed to decode at the host — a client error.
        Verdict::ParseError => Problem::new("parse-error", "Malformed action bytes", 400)
            .with_detail("the host could not decode the submitted SignedAction")
            .into_outcome(),
        // The host's worker queue is full — backpressure.
        Verdict::Busy => Problem::new("busy", "Host busy", 503)
            .with_detail("the host worker queue is full; retry with backoff")
            .with_retry_after_ms(1000)
            .into_outcome()
            .with_header("Retry-After", "1"),
    }
}

/// Map a submit-pipeline error to its response.
fn map_error(err: &SubmitError) -> RouteOutcome {
    match err {
        SubmitError::PayloadTooLarge(detail) => {
            Problem::new("payload-too-large", "Payload Too Large", 413)
                .with_detail(detail.clone())
                .into_outcome()
        }
        SubmitError::Saturated => Problem::new("busy", "Host busy", 503)
            .with_detail("the host connection pool is saturated; retry with backoff")
            .with_retry_after_ms(1000)
            .into_outcome()
            .with_header("Retry-After", "1"),
        SubmitError::Connect(detail) => {
            upstream_unavailable(&format!("host connect failed: {detail}"))
        }
        SubmitError::Timeout => Problem::new("upstream-timeout", "Gateway Timeout", 504)
            .with_detail("the host did not complete the round-trip within the deadline")
            .into_outcome(),
        SubmitError::Io(detail) => upstream_unavailable(&format!("host I/O failed: {detail}")),
        SubmitError::Response(detail) => {
            upstream_unavailable(&format!("invalid host response: {detail}"))
        }
    }
}

/// A `502` for an unreachable / misbehaving host upstream.
fn upstream_unavailable(detail: &str) -> RouteOutcome {
    Problem::new("upstream-unavailable", "Bad Gateway", 502)
        .with_detail(detail.to_string())
        .into_outcome()
}

/// Serialise a `VerdictDto` to a `200` JSON outcome (the shape is
/// serde-infallible; the fallback keeps the path panic-free).
fn verdict_body(dto: &VerdictDto) -> RouteOutcome {
    let body = serde_json::to_string(dto).unwrap_or_else(|_| "{}".to_string());
    RouteOutcome::json(200, body)
}

#[cfg(test)]
mod tests {
    use super::map_submit_result;
    use crate::submit::pool::SubmitError;
    use knomosis_host::verdict::{Verdict, VerdictResponse};

    fn ok(
        result: Result<VerdictResponse, SubmitError>,
    ) -> (u16, serde_json::Value, Vec<(String, String)>) {
        let o = map_submit_result(result, "Finalized");
        let v = serde_json::from_str(&o.body).unwrap_or(serde_json::Value::Null);
        let headers = o
            .headers
            .iter()
            .map(|(n, val)| ((*n).to_string(), val.clone()))
            .collect();
        (o.status, v, headers)
    }

    #[test]
    fn ok_verdict_is_200_accepted_with_stage() {
        let (status, v, _) = ok(Ok(VerdictResponse::from_verdict(Verdict::Ok)));
        assert_eq!(status, 200);
        assert_eq!(v["accepted"], true);
        assert_eq!(v["verdict"], "Ok");
        assert_eq!(v["admissionStage"], "Finalized");
        assert!(v["reason"].is_null());
        assert!(v["seq"].is_null());
    }

    #[test]
    fn not_admissible_is_200_declined_with_reason() {
        let (status, v, _) = ok(Ok(VerdictResponse::with_reason(
            Verdict::NotAdmissible,
            "InsufficientBudget",
        )));
        assert_eq!(status, 200);
        assert_eq!(v["accepted"], false);
        assert_eq!(v["verdict"], "NotAdmissible");
        assert_eq!(v["reason"], "InsufficientBudget");
        assert!(v["admissionStage"].is_null());
    }

    #[test]
    fn not_admissible_empty_reason_is_null() {
        let (_, v, _) = ok(Ok(VerdictResponse::from_verdict(Verdict::NotAdmissible)));
        assert_eq!(v["accepted"], false);
        assert!(v["reason"].is_null());
    }

    #[test]
    fn parse_error_is_400() {
        let o = super::map_submit_result(
            Ok(VerdictResponse::from_verdict(Verdict::ParseError)),
            "Finalized",
        );
        assert_eq!(o.status, 400);
        assert_eq!(o.content_type, "application/problem+json");
    }

    #[test]
    fn busy_and_saturated_are_503_with_retry_after() {
        let (status, _, headers) = ok(Ok(VerdictResponse::from_verdict(Verdict::Busy)));
        assert_eq!(status, 503);
        assert!(headers
            .iter()
            .any(|(n, _)| n.eq_ignore_ascii_case("Retry-After")));
        let (status, _, headers) = ok(Err(SubmitError::Saturated));
        assert_eq!(status, 503);
        assert!(headers
            .iter()
            .any(|(n, _)| n.eq_ignore_ascii_case("Retry-After")));
    }

    #[test]
    fn payload_too_large_is_413() {
        let (status, _, _) = ok(Err(SubmitError::PayloadTooLarge("too big".to_string())));
        assert_eq!(status, 413);
    }

    #[test]
    fn connect_and_io_failures_are_502() {
        for e in [
            SubmitError::Connect("refused".to_string()),
            SubmitError::Io("reset".to_string()),
        ] {
            let (status, _, _) = ok(Err(e));
            assert_eq!(status, 502);
        }
    }

    #[test]
    fn timeout_is_504() {
        let o = super::map_submit_result(Err(SubmitError::Timeout), "Finalized");
        assert_eq!(o.status, 504);
        assert_eq!(o.content_type, "application/problem+json");
    }
}

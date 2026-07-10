// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G4.3 observability: per-request correlation ids + the structured
//! request log line.
//!
//! Every request is tagged with a process-unique [`next_request_id`], which
//! is propagated to the `X-Request-Id` response header, the RFC 9457
//! `problem.instance` member (so a client error carries the correlation
//! token), and a single structured log line (`request_id`, `method`,
//! `path`, `status`, `latency_us`) emitted at request completion.  That log
//! line is the **log-based metrics** surface (the OQ-GW-10 default — a
//! `/metrics` endpoint is the deferred alternative): an aggregator derives
//! per-endpoint status / latency from it.
//!
//! **Secret discipline (§8.1 / §9.2).**  The request log records only the
//! method, path, status, latency, and id — **never** the `Authorization`
//! header / bearer token, an `Idempotency-Key`, or a request / response
//! body.  The token set's own `Debug` is redacting; this module adds no new
//! sink that could leak one.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

/// The `X-Request-Id` response header name (every response carries it).
pub const REQUEST_ID_HEADER: &str = "X-Request-Id";

/// Monotonic per-request sequence within this process run.
static REQUEST_COUNTER: AtomicU64 = AtomicU64::new(0);

/// A process-start nonce distinguishing request ids across restarts in
/// aggregated logs (derived from the wall clock — no external dependency,
/// and only correlation-grade uniqueness is required, not unpredictability).
fn process_nonce() -> u32 {
    static NONCE: OnceLock<u32> = OnceLock::new();
    *NONCE.get_or_init(|| {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos())
    })
}

/// A per-request correlation id (`req-<nonce>-<seq>`): process-unique and
/// monotonically increasing within a run, distinguishable across restarts.
#[must_use]
pub fn next_request_id() -> String {
    let n = REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("req-{:06x}-{n:x}", process_nonce() & 0x00ff_ffff)
}

#[cfg(test)]
mod tests {
    use super::next_request_id;

    #[test]
    fn request_ids_are_unique_and_well_formed() {
        let a = next_request_id();
        let b = next_request_id();
        assert_ne!(a, b, "ids are monotonic");
        for id in [&a, &b] {
            assert!(id.starts_with("req-"), "id {id} has the req- prefix");
            // `req-<6 hex nonce>-<hex seq>`.
            let rest = id.strip_prefix("req-").unwrap();
            let (nonce, seq) = rest.split_once('-').expect("nonce-seq shape");
            assert_eq!(nonce.len(), 6);
            assert!(nonce.chars().all(|c| c.is_ascii_hexdigit()));
            assert!(!seq.is_empty() && seq.chars().all(|c| c.is_ascii_hexdigit()));
        }
    }

    #[test]
    fn ids_share_a_stable_process_nonce() {
        // The nonce component is process-stable, so two ids share it.
        let a = next_request_id();
        let b = next_request_id();
        let nonce = |id: &str| {
            id.strip_prefix("req-")
                .unwrap()
                .split_once('-')
                .unwrap()
                .0
                .to_string()
        };
        assert_eq!(nonce(&a), nonce(&b));
    }
}

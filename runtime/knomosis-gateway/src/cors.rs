// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Browser CORS support (`--cors-origin`, §8.4).
//!
//! Normally the gateway fronts a server-side BFF and needs no CORS at all.
//! When `--cors-origin` is configured (the deployment exposes the gateway
//! browser-direct), this module supplies the two halves of CORS:
//!
//!   * the **`OPTIONS` preflight** answer ([`preflight`]) — a `204` carrying
//!     `Access-Control-Allow-{Origin,Methods,Headers}` + `-Max-Age`, served
//!     **before** the auth gate (a preflight carries no credentials, per the
//!     Fetch standard);
//!   * the **actual-response decoration** ([`response_headers`]) —
//!     `Access-Control-Allow-Origin` (+ `Vary: Origin`, +
//!     `Access-Control-Allow-Credentials` for an explicit allowlist) added to
//!     every real response so the browser will surface it.
//!
//! The policy is parsed **once** at startup ([`CorsPolicy::parse`], from the
//! already-validated [`crate::config::Config::cors_origin`]) and held in
//! [`crate::state::AppState`].  An origin is echoed back verbatim only when it
//! is on the allowlist (or the policy is `*`), so a non-allowlisted origin
//! receives **no** `Access-Control-Allow-Origin` and the browser blocks it.

use crate::http::RouteOutcome;

/// The methods advertised in a CORS preflight (`Access-Control-Allow-Methods`).
/// The gateway's whole surface is `GET` (reads / info / events) + `POST`
/// (submit) + `OPTIONS` (preflight itself).
const ALLOW_METHODS: &str = "GET, POST, OPTIONS";

/// The request headers advertised in a CORS preflight
/// (`Access-Control-Allow-Headers`): exactly the ones the gateway reads off a
/// browser request.
const ALLOW_HEADERS: &str =
    "Authorization, Content-Type, Idempotency-Key, Last-Event-ID, If-None-Match";

/// How long a browser may cache the preflight (`Access-Control-Max-Age`, 10
/// minutes) — bounded so a policy change is picked up promptly.
const MAX_AGE_SECS: &str = "600";

/// A parsed browser-CORS allow policy (from `--cors-origin`).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CorsPolicy {
    /// `--cors-origin '*'`: allow any origin.  Per the Fetch standard a
    /// wildcard is incompatible with credentialed requests, so the gateway
    /// echoes a literal `*` and never sets `Access-Control-Allow-Credentials`.
    Any,
    /// An explicit origin allowlist.  A request whose `Origin` is in the list
    /// is answered with **that exact origin** echoed back (so credentialed
    /// CORS works); any other origin receives no CORS headers.
    List(Vec<String>),
}

impl CorsPolicy {
    /// Parse the **already-validated** [`crate::config::Config::cors_origin`]
    /// string: `*` → [`CorsPolicy::Any`]; otherwise a comma-separated allowlist
    /// (each entry already a well-formed, trimmed origin) → [`CorsPolicy::List`].
    #[must_use]
    pub fn parse(configured: &str) -> Self {
        if configured == "*" {
            CorsPolicy::Any
        } else {
            CorsPolicy::List(
                configured
                    .split(',')
                    .map(|s| s.trim().to_string())
                    .collect(),
            )
        }
    }

    /// Build the policy from a config, or `None` when CORS is disabled.
    #[must_use]
    pub fn from_config(config: &crate::config::Config) -> Option<Self> {
        config.cors_origin.as_deref().map(CorsPolicy::parse)
    }

    /// The value to echo in `Access-Control-Allow-Origin` for a request from
    /// `origin`, or `None` when the origin is not allowed.
    fn allow_origin_value(&self, origin: &str) -> Option<String> {
        match self {
            CorsPolicy::Any => Some("*".to_string()),
            CorsPolicy::List(list) => list
                .iter()
                .any(|allowed| allowed == origin)
                .then(|| origin.to_string()),
        }
    }

    /// Whether credentialed CORS is offered (only for an explicit allowlist —
    /// never with the wildcard, which the Fetch standard forbids combining with
    /// `Access-Control-Allow-Credentials`).
    fn allows_credentials(&self) -> bool {
        matches!(self, CorsPolicy::List(_))
    }
}

/// The CORS headers to add to a **real** response given the request `origin`
/// (if any): `Access-Control-Allow-Origin` (the echoed origin or `*`), a `Vary:
/// Origin` so a shared cache keys on it, and — for an explicit allowlist —
/// `Access-Control-Allow-Credentials: true`.  Empty when the origin is absent
/// or not allowed (the browser then blocks the cross-origin read).
#[must_use]
pub fn response_headers(policy: &CorsPolicy, origin: Option<&str>) -> Vec<(&'static str, String)> {
    let Some(origin) = origin else {
        return Vec::new();
    };
    let Some(allow) = policy.allow_origin_value(origin) else {
        return Vec::new();
    };
    let mut headers = vec![
        ("Access-Control-Allow-Origin", allow),
        ("Vary", "Origin".to_string()),
    ];
    if policy.allows_credentials() {
        headers.push(("Access-Control-Allow-Credentials", "true".to_string()));
    }
    headers
}

/// [`response_headers`] over an **optional** policy: empty when CORS is
/// disabled.  Used by the SSE-stream path, which stamps these on the hijacked
/// response head.
#[must_use]
pub fn response_headers_opt(
    policy: Option<&CorsPolicy>,
    origin: Option<&str>,
) -> Vec<(&'static str, String)> {
    policy.map_or_else(Vec::new, |policy| response_headers(policy, origin))
}

/// Decorate `outcome` with the CORS response headers for `origin` under the
/// optional `policy` (a no-op when CORS is disabled, or the origin is absent /
/// not allowed).
#[must_use]
pub fn decorate(
    outcome: RouteOutcome,
    policy: Option<&CorsPolicy>,
    origin: Option<&str>,
) -> RouteOutcome {
    let Some(policy) = policy else {
        return outcome;
    };
    response_headers(policy, origin)
        .into_iter()
        .fold(outcome, |o, (name, value)| o.with_header(name, value))
}

/// Build the `OPTIONS` preflight response: a `204` carrying the actual-response
/// CORS headers plus the preflight-only allow-methods / allow-headers / max-age
/// advertisements.  When `origin` is not allowed the `204` carries **no**
/// `Access-Control-*` headers, so the browser blocks the pending request.
#[must_use]
pub fn preflight(policy: &CorsPolicy, origin: &str) -> RouteOutcome {
    let mut outcome = RouteOutcome::no_content();
    let allowed = policy.allow_origin_value(origin).is_some();
    for (name, value) in response_headers(policy, Some(origin)) {
        outcome = outcome.with_header(name, value);
    }
    if allowed {
        outcome = outcome
            .with_header("Access-Control-Allow-Methods", ALLOW_METHODS)
            .with_header("Access-Control-Allow-Headers", ALLOW_HEADERS)
            .with_header("Access-Control-Max-Age", MAX_AGE_SECS);
    }
    outcome
}

#[cfg(test)]
mod tests {
    use super::{decorate, preflight, response_headers, CorsPolicy};

    fn has<'a>(headers: &'a [(&'static str, String)], name: &str) -> Option<&'a str> {
        headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    #[test]
    fn parse_wildcard_and_list() {
        assert_eq!(CorsPolicy::parse("*"), CorsPolicy::Any);
        assert_eq!(
            CorsPolicy::parse("https://a.example.com,https://b.example.com"),
            CorsPolicy::List(vec![
                "https://a.example.com".to_string(),
                "https://b.example.com".to_string(),
            ])
        );
    }

    #[test]
    fn wildcard_echoes_star_no_credentials() {
        let policy = CorsPolicy::Any;
        let h = response_headers(&policy, Some("https://anything.example.com"));
        assert_eq!(has(&h, "Access-Control-Allow-Origin"), Some("*"));
        assert_eq!(has(&h, "Vary"), Some("Origin"));
        // The wildcard never advertises credentials (Fetch-standard rule).
        assert!(has(&h, "Access-Control-Allow-Credentials").is_none());
    }

    #[test]
    fn allowlist_echoes_matching_origin_with_credentials() {
        let policy = CorsPolicy::parse("https://app.example.com");
        let h = response_headers(&policy, Some("https://app.example.com"));
        assert_eq!(
            has(&h, "Access-Control-Allow-Origin"),
            Some("https://app.example.com")
        );
        assert_eq!(has(&h, "Access-Control-Allow-Credentials"), Some("true"));
        // A non-allowlisted origin gets nothing (the browser blocks it).
        assert!(response_headers(&policy, Some("https://evil.example.com")).is_empty());
        // No Origin header at all → no CORS headers.
        assert!(response_headers(&policy, None).is_empty());
    }

    #[test]
    fn decorate_is_noop_without_policy_or_origin() {
        let base = crate::http::RouteOutcome::json(200, "{}".to_string());
        // No policy → unchanged.
        assert!(decorate(base.clone(), None, Some("https://x"))
            .headers
            .is_empty());
        // Policy but no origin → unchanged.
        let policy = CorsPolicy::Any;
        assert!(decorate(base, Some(&policy), None).headers.is_empty());
    }

    #[test]
    fn preflight_allowed_carries_method_and_header_advertisements() {
        let policy = CorsPolicy::parse("https://app.example.com");
        let o = preflight(&policy, "https://app.example.com");
        assert_eq!(o.status, 204);
        assert_eq!(
            has(&o.headers, "Access-Control-Allow-Origin"),
            Some("https://app.example.com")
        );
        assert!(has(&o.headers, "Access-Control-Allow-Methods").is_some());
        assert!(has(&o.headers, "Access-Control-Allow-Headers").is_some());
        assert!(has(&o.headers, "Access-Control-Max-Age").is_some());
    }

    #[test]
    fn preflight_disallowed_origin_has_no_cors_headers() {
        let policy = CorsPolicy::parse("https://app.example.com");
        let o = preflight(&policy, "https://evil.example.com");
        assert_eq!(o.status, 204);
        assert!(has(&o.headers, "Access-Control-Allow-Origin").is_none());
        assert!(has(&o.headers, "Access-Control-Allow-Methods").is_none());
    }
}

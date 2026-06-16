// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G1.4 service-to-service authentication: a **fail-closed** bearer-token
//! gate.
//!
//! The gateway sits behind the BFF on a private network; this token is a
//! *service* credential (BFF ↔ gateway), **not** an end-user credential
//! (end-user auth stays at the BFF edge, §8.1).  The token is compared in
//! **constant time** ([`subtle::ConstantTimeEq`]) so a timing side channel
//! cannot recover it byte-by-byte, and it is **never logged**.
//!
//! **Fail-closed posture (§8 / §220).**  When no token file is configured
//! the token set is empty and *every* non-exempt request is denied — the
//! gateway never serves protected data without a credential.  Only the
//! liveness / readiness probes (`/healthz`, `/readyz`, the contract's
//! `security: []` operations) are exempt.
//!
//! **Status mapping** (the G1.4 acceptance): a request with **no** bearer
//! credential → `401` (+ `WWW-Authenticate: Bearer`); a **well-formed but
//! non-matching** bearer token → `403`.

use std::path::Path;

use subtle::{Choice, ConstantTimeEq};

use crate::http::RouteOutcome;
use crate::problem::Problem;

/// Errors loading the bearer-token file.
#[derive(Debug, thiserror::Error)]
pub enum AuthLoadError {
    /// The token file could not be read.
    #[error("failed to read auth token file {path}: {reason}")]
    Read {
        /// The configured token-file path.
        path: String,
        /// The I/O diagnostic.
        reason: String,
    },
}

/// The loaded set of accepted bearer tokens (the gateway's service
/// credentials).  An **empty** set denies every non-exempt request
/// (fail-closed).  Token bytes are held for the process lifetime and
/// never logged.
pub struct Auth {
    tokens: Vec<Vec<u8>>,
}

impl std::fmt::Debug for Auth {
    /// Redacts the token *values* — only the count is ever printed, so a
    /// `Debug`-formatted [`Auth`] (e.g. via `AppState`) cannot leak a
    /// credential into a log line.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Auth")
            .field("token_count", &self.tokens.len())
            .finish()
    }
}

/// The result of authorizing one request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AuthOutcome {
    /// A valid bearer token was presented.
    Authorized,
    /// No bearer credential was presented (maps to `401`).
    MissingCredential,
    /// A bearer credential was presented but matched no configured token
    /// (maps to `403`).
    InvalidCredential,
}

impl Auth {
    /// An empty token set (no `--auth-token-file`): **fail-closed** — every
    /// non-exempt request is denied.
    #[must_use]
    pub fn empty() -> Self {
        Self { tokens: Vec::new() }
    }

    /// Load accepted tokens from `path`: one token per line; blank lines
    /// and `#`-prefixed comment lines are ignored; each token is trimmed
    /// of surrounding whitespace.
    ///
    /// An empty file (no usable tokens) is accepted and is equivalent to
    /// [`Auth::empty`] — still fail-closed.
    ///
    /// # Errors
    ///
    /// [`AuthLoadError::Read`] if the file cannot be read.
    pub fn load(path: &Path) -> Result<Self, AuthLoadError> {
        let contents = std::fs::read_to_string(path).map_err(|e| AuthLoadError::Read {
            path: path.display().to_string(),
            reason: e.to_string(),
        })?;
        let tokens = contents
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .map(|line| line.as_bytes().to_vec())
            .collect();
        Ok(Self { tokens })
    }

    /// The number of configured tokens (for the startup log / tests; the
    /// token *values* are never exposed).
    #[must_use]
    pub fn token_count(&self) -> usize {
        self.tokens.len()
    }

    /// Authorize a request from its raw `Authorization` header value.
    ///
    /// `None` (absent header) or a non-`Bearer` scheme →
    /// [`AuthOutcome::MissingCredential`]; a `Bearer` token that matches
    /// no configured token → [`AuthOutcome::InvalidCredential`]; a match →
    /// [`AuthOutcome::Authorized`].  The token comparison is constant-time
    /// and checks **every** configured token without an early return.
    #[must_use]
    pub fn authorize(&self, header: Option<&str>) -> AuthOutcome {
        let Some(raw) = header else {
            return AuthOutcome::MissingCredential;
        };
        // Split "Bearer <token>" on the first space; the scheme is
        // case-insensitive (RFC 7235 §2.1).
        let Some((scheme, token)) = raw.split_once(' ') else {
            return AuthOutcome::MissingCredential;
        };
        if !scheme.eq_ignore_ascii_case("bearer") {
            return AuthOutcome::MissingCredential;
        }
        let presented = token.trim().as_bytes();
        // OR the per-token constant-time equality bits; no early return on
        // the first match, so neither the matching token's identity nor
        // its position leaks through timing.
        let mut matched = Choice::from(0u8);
        for configured in &self.tokens {
            matched |= presented.ct_eq(configured.as_slice());
        }
        if bool::from(matched) {
            AuthOutcome::Authorized
        } else {
            AuthOutcome::InvalidCredential
        }
    }
}

/// Whether `path` is exempt from authentication (the liveness / readiness
/// probes, the contract's `security: []` operations).  Exemption is
/// **path-based**, so a wrong-method request to an exempt path still
/// skips auth (and is answered `405` by the router) rather than `401`.
#[must_use]
pub fn is_exempt_path(path: &str) -> bool {
    matches!(path, "/healthz" | "/readyz")
}

/// The auth gate applied before routing: `None` when the request is
/// allowed to proceed (an exempt path, or a valid credential), else
/// `Some(problem)` — the `401` / `403` outcome to return immediately.
///
/// Checking auth **before** routing means an unknown path is answered
/// `401` (not `404`) for an unauthenticated caller, so path existence is
/// not enumerable without a credential.
#[must_use]
pub fn gate(auth: &Auth, path: &str, header: Option<&str>) -> Option<RouteOutcome> {
    if is_exempt_path(path) {
        return None;
    }
    match auth.authorize(header) {
        AuthOutcome::Authorized => None,
        AuthOutcome::MissingCredential => Some(
            Problem::new("unauthorized", "Unauthorized", 401)
                .with_detail("a bearer service credential is required")
                .into_outcome()
                .with_header("WWW-Authenticate", "Bearer"),
        ),
        AuthOutcome::InvalidCredential => Some(
            Problem::new("forbidden", "Forbidden", 403)
                .with_detail("the presented credential is not accepted")
                .into_outcome(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::{gate, Auth, AuthOutcome};

    fn auth_with(tokens: &[&str]) -> Auth {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tokens");
        std::fs::write(&path, tokens.join("\n")).unwrap();
        Auth::load(&path).unwrap()
    }

    #[test]
    fn load_parses_lines_skipping_blanks_and_comments() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tokens");
        std::fs::write(&path, "  tok-a  \n\n# a comment\ntok-b\n").unwrap();
        let auth = Auth::load(&path).unwrap();
        assert_eq!(auth.token_count(), 2);
        assert_eq!(
            auth.authorize(Some("Bearer tok-a")),
            AuthOutcome::Authorized
        );
        assert_eq!(
            auth.authorize(Some("Bearer tok-b")),
            AuthOutcome::Authorized
        );
    }

    #[test]
    fn empty_token_set_is_fail_closed() {
        let auth = Auth::empty();
        // No credential → 401-class; a presented token → 403-class. Either
        // way, nothing is authorized.
        assert_eq!(auth.authorize(None), AuthOutcome::MissingCredential);
        assert_eq!(
            auth.authorize(Some("Bearer anything")),
            AuthOutcome::InvalidCredential
        );
    }

    #[test]
    fn missing_or_non_bearer_credential_is_missing() {
        let auth = auth_with(&["secret"]);
        assert_eq!(auth.authorize(None), AuthOutcome::MissingCredential);
        // A non-Bearer scheme is not a usable credential.
        assert_eq!(
            auth.authorize(Some("Basic dXNlcjpwYXNz")),
            AuthOutcome::MissingCredential
        );
        // A bare value with no scheme separator.
        assert_eq!(
            auth.authorize(Some("secret")),
            AuthOutcome::MissingCredential
        );
    }

    #[test]
    fn correct_token_authorizes_wrong_token_is_invalid() {
        let auth = auth_with(&["correct-horse"]);
        assert_eq!(
            auth.authorize(Some("Bearer correct-horse")),
            AuthOutcome::Authorized
        );
        assert_eq!(
            auth.authorize(Some("Bearer wrong-token")),
            AuthOutcome::InvalidCredential
        );
        // A token that is a prefix of the configured one must NOT match.
        assert_eq!(
            auth.authorize(Some("Bearer correct")),
            AuthOutcome::InvalidCredential
        );
    }

    #[test]
    fn bearer_scheme_is_case_insensitive() {
        let auth = auth_with(&["t0ken"]);
        assert_eq!(
            auth.authorize(Some("bearer t0ken")),
            AuthOutcome::Authorized
        );
        assert_eq!(
            auth.authorize(Some("BEARER t0ken")),
            AuthOutcome::Authorized
        );
    }

    #[test]
    fn any_configured_token_authorizes() {
        let auth = auth_with(&["alpha", "bravo", "charlie"]);
        for t in ["alpha", "bravo", "charlie"] {
            assert_eq!(
                auth.authorize(Some(&format!("Bearer {t}"))),
                AuthOutcome::Authorized
            );
        }
        assert_eq!(
            auth.authorize(Some("Bearer delta")),
            AuthOutcome::InvalidCredential
        );
    }

    #[test]
    fn gate_exempts_health_and_ready_only() {
        let auth = Auth::empty(); // fail-closed: nothing authorizes
                                  // Exempt paths pass with no credential.
        assert!(gate(&auth, "/healthz", None).is_none());
        assert!(gate(&auth, "/readyz", None).is_none());
        // Everything else is gated — even an unknown path (no enumeration)
        // and /v1/info — and answers 401 with no credential.
        let denied = gate(&auth, "/v1/info", None).expect("gated");
        assert_eq!(denied.status, 401);
        assert!(denied
            .headers
            .iter()
            .any(|(n, v)| *n == "WWW-Authenticate" && v == "Bearer"));
        let denied = gate(&auth, "/v1/does-not-exist", None).expect("gated");
        assert_eq!(denied.status, 401);
    }

    #[test]
    fn gate_maps_wrong_token_to_403() {
        let auth = auth_with(&["right"]);
        // Valid token → allowed (None).
        assert!(gate(&auth, "/v1/info", Some("Bearer right")).is_none());
        // Wrong token → 403.
        let denied = gate(&auth, "/v1/info", Some("Bearer wrong")).expect("gated");
        assert_eq!(denied.status, 403);
        assert_eq!(denied.content_type, "application/problem+json");
    }
}

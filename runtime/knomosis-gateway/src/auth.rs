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
use crate::rate_limit::RateLimiter;

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
    /// On Unix, the token file is accessible by "other" (it must not be
    /// world-readable / -writable — a secret-hygiene requirement, §8.1).
    #[error(
        "auth token file {path} is world-accessible (mode {mode:o}); \
         it must not be readable or writable by 'other' (use e.g. chmod 600)"
    )]
    InsecurePermissions {
        /// The configured token-file path.
        path: String,
        /// The offending file mode (low 9 permission bits).
        mode: u32,
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
        // Secret hygiene: refuse a world-accessible token file before
        // reading it (a no-op on non-Unix targets).
        check_token_file_permissions(path)?;
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
        let Some(token) = bearer_token(header) else {
            return AuthOutcome::MissingCredential;
        };
        let presented = token.as_bytes();
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

/// Extract the bearer token from an `Authorization` header value
/// (`Bearer <token>`; the scheme is case-insensitive per RFC 7235 §2.1),
/// trimmed of surrounding whitespace.  `None` when the header is absent
/// or is not a bearer credential.
#[must_use]
pub fn bearer_token(header: Option<&str>) -> Option<&str> {
    let (scheme, token) = header?.split_once(' ')?;
    scheme.eq_ignore_ascii_case("bearer").then(|| token.trim())
}

/// A stable in-process key identifying a credential, for per-credential
/// rate limiting.  Hashing the token keeps token *values* out of the
/// limiter's bucket map; equal tokens map to equal keys.
#[must_use]
pub fn credential_key(token: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    token.hash(&mut hasher);
    hasher.finish()
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

/// The per-credential rate-limit gate, applied **after** [`gate`] admits
/// a request: `None` when the request may proceed, or `Some(429)` (with a
/// `Retry-After` header + `retryAfterMs` extension) when the credential's
/// token bucket is exhausted.  Exempt paths (`/healthz`, `/readyz`) and a
/// disabled limiter are never throttled.
#[must_use]
pub fn rate_limit_check(
    limiter: &RateLimiter,
    path: &str,
    header: Option<&str>,
) -> Option<RouteOutcome> {
    if is_exempt_path(path) || limiter.is_disabled() {
        return None;
    }
    // The token is present on the authorized path (`gate` ran first).
    let token = bearer_token(header)?;
    match limiter.check(credential_key(token)) {
        Ok(()) => None,
        Err(retry_after) => Some(rate_limited(retry_after)),
    }
}

/// Build a `429 Too Many Requests` outcome with a `Retry-After` header
/// (whole seconds, RFC 9110 §10.2.3) and the `retryAfterMs` problem
/// extension (millisecond precision).
fn rate_limited(retry_after: std::time::Duration) -> RouteOutcome {
    let retry_ms = u64::try_from(retry_after.as_millis()).unwrap_or(u64::MAX);
    // `Retry-After` is whole seconds; round a sub-second hint up to 1.
    let retry_secs = retry_after.as_secs().max(1);
    Problem::new("rate-limited", "Too Many Requests", 429)
        .with_detail("per-credential request rate exceeded")
        .with_retry_after_ms(retry_ms)
        .into_outcome()
        .with_header("Retry-After", retry_secs.to_string())
}

/// Refuse a token file accessible by "other" (any of the low three mode
/// bits set) — a world-readable secret is a misconfiguration.  Group
/// access is left to the operator (service-group deployments).
#[cfg(unix)]
fn check_token_file_permissions(path: &Path) -> Result<(), AuthLoadError> {
    use std::os::unix::fs::PermissionsExt;
    let meta = std::fs::metadata(path).map_err(|e| AuthLoadError::Read {
        path: path.display().to_string(),
        reason: e.to_string(),
    })?;
    let mode = meta.permissions().mode();
    if mode & 0o007 != 0 {
        return Err(AuthLoadError::InsecurePermissions {
            path: path.display().to_string(),
            mode: mode & 0o777,
        });
    }
    Ok(())
}

/// Non-Unix targets have no POSIX permission model — nothing to check.
#[cfg(not(unix))]
fn check_token_file_permissions(_path: &Path) -> Result<(), AuthLoadError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{gate, rate_limit_check, Auth, AuthLoadError, AuthOutcome};
    use crate::rate_limit::RateLimiter;
    use std::path::{Path, PathBuf};

    /// Write a token file with secret-safe (owner-only) permissions, so
    /// the load-time permission check accepts it.
    fn write_secure(dir: &Path, content: &str) -> PathBuf {
        let path = dir.join("tokens");
        std::fs::write(&path, content).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        path
    }

    fn auth_with(tokens: &[&str]) -> Auth {
        let dir = tempfile::tempdir().unwrap();
        let path = write_secure(dir.path(), &tokens.join("\n"));
        Auth::load(&path).unwrap()
    }

    #[test]
    fn load_parses_lines_skipping_blanks_and_comments() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_secure(dir.path(), "  tok-a  \n\n# a comment\ntok-b\n");
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

    /// On Unix, a world-readable token file is refused at load.
    #[cfg(unix)]
    #[test]
    fn world_readable_token_file_is_rejected() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tokens");
        std::fs::write(&path, "secret").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(matches!(
            Auth::load(&path),
            Err(AuthLoadError::InsecurePermissions { .. })
        ));
        // The owner-only file loads fine.
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(Auth::load(&path).is_ok());
    }

    #[test]
    fn rate_limit_check_throttles_per_credential() {
        // The rate-limit gate runs after auth, so it consults only the
        // limiter + the (already-validated) credential, not `Auth`.
        let limiter = RateLimiter::new(1); // 1 rps, 1-token burst
        let cred = Some("Bearer tok");
        // First authed request admitted; the second (same credential,
        // same instant) is throttled with a 429.
        assert!(rate_limit_check(&limiter, "/v1/info", cred).is_none());
        let throttled = rate_limit_check(&limiter, "/v1/info", cred).expect("429");
        assert_eq!(throttled.status, 429);
        assert!(throttled
            .headers
            .iter()
            .any(|(n, _)| n.eq_ignore_ascii_case("Retry-After")));
        // Exempt paths are never throttled.
        assert!(rate_limit_check(&limiter, "/healthz", None).is_none());
        // A disabled limiter never throttles.
        let off = RateLimiter::new(0);
        for _ in 0..100 {
            assert!(rate_limit_check(&off, "/v1/info", cred).is_none());
        }
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

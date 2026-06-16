// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The `tiny_http` IO shell: bind, accept loop, and request→response
//! glue around the pure [`super::router`].
//!
//! **Scaffold (G1.1):** a single-threaded blocking accept loop.  The
//! bounded handler pool, `--max-connections` cap, per-connection
//! read/idle timeouts, and request-body limits land in G1.2d; the
//! graceful-drain shutdown lands in G4.4.

use crate::config::Config;
use crate::http::router::{route, RouteOutcome};

/// Errors from running the gateway HTTP server.
#[derive(Debug, thiserror::Error)]
pub enum ServeError {
    /// Binding the listen socket failed (address in use, permission
    /// denied, …).
    #[error("failed to bind HTTP listener on {addr}: {reason}")]
    Bind {
        /// The address that could not be bound.
        addr: String,
        /// The backend's diagnostic.
        reason: String,
    },
}

/// Run the gateway HTTP server, blocking the calling thread.
///
/// The accept loop runs until the process is terminated; it only
/// *returns* on a bind failure (the loop itself is infinite under
/// normal operation).  Graceful shutdown is G4.4.
///
/// # Errors
///
/// Returns [`ServeError::Bind`] if the listen socket cannot be bound.
pub fn serve(config: &Config) -> Result<(), ServeError> {
    let server = tiny_http::Server::http(config.listen).map_err(|e| ServeError::Bind {
        addr: config.listen.to_string(),
        reason: e.to_string(),
    })?;
    tracing::info!(
        identifier = crate::GATEWAY_IDENTIFIER,
        version = crate::VERSION,
        listen = %config.listen,
        "knomosis-gateway listening"
    );
    for request in server.incoming_requests() {
        handle_request(request);
    }
    Ok(())
}

/// Apply the routing table to one request and write the response.
///
/// **Panic-free by construction** (the §3.2 `panic = "abort"`
/// constraint): the method/path extraction uses only checked
/// operations, and a write failure — the client hung up before the
/// response was flushed — is logged at `debug` and dropped, since
/// there is nothing else to do.
pub fn handle_request(request: tiny_http::Request) {
    let method = method_token(request.method());
    // Strip any query string; `split` always yields at least one item,
    // but `unwrap_or` keeps this provably panic-free regardless.
    let path = request.url().split('?').next().unwrap_or("");
    let outcome = route(method, path);
    respond(request, &outcome);
}

/// Convert a [`RouteOutcome`] into a `tiny_http` response and write
/// it.  Consumes the request (which owns the connection).
fn respond(request: tiny_http::Request, outcome: &RouteOutcome) {
    let mut response =
        tiny_http::Response::from_string(outcome.body.clone()).with_status_code(outcome.status);
    // `Header::from_bytes` only fails on a malformed name/value; our
    // content types are compile-time constants, so this never fails —
    // but we handle the `Err` without panicking regardless.
    if let Ok(header) =
        tiny_http::Header::from_bytes(b"Content-Type", outcome.content_type.as_bytes())
    {
        response = response.with_header(header);
    }
    // Response-specific headers (e.g. `Allow` on 405, `Retry-After` on
    // 429/503, `X-Knomosis-Seq` / `ETag` on reads).  A malformed
    // name/value is skipped rather than panicking; our names/values are
    // controlled, so this never drops a header in practice.
    for (name, value) in &outcome.headers {
        if let Ok(header) = tiny_http::Header::from_bytes(name.as_bytes(), value.as_bytes()) {
            response = response.with_header(header);
        }
    }
    if let Err(e) = request.respond(response) {
        tracing::debug!(error = %e, "client closed connection before the response was written");
    }
}

/// Map a `tiny_http::Method` to the canonical uppercase token the
/// router matches on.  Unknown / non-standard methods map to
/// `"OTHER"` (they route to 404 in the scaffold table; G1.2b adds
/// 405 + `Allow`).
fn method_token(method: &tiny_http::Method) -> &'static str {
    match method {
        tiny_http::Method::Get => "GET",
        tiny_http::Method::Head => "HEAD",
        tiny_http::Method::Post => "POST",
        tiny_http::Method::Put => "PUT",
        tiny_http::Method::Delete => "DELETE",
        tiny_http::Method::Options => "OPTIONS",
        tiny_http::Method::Patch => "PATCH",
        _ => "OTHER",
    }
}

#[cfg(test)]
mod tests {
    use super::method_token;

    #[test]
    fn method_token_maps_common_verbs() {
        assert_eq!(method_token(&tiny_http::Method::Get), "GET");
        assert_eq!(method_token(&tiny_http::Method::Post), "POST");
        assert_eq!(method_token(&tiny_http::Method::Delete), "DELETE");
        // A method outside the explicit arms maps to the catch-all
        // token (G1.2b promotes these to 405 + `Allow`).
        assert_eq!(method_token(&tiny_http::Method::Trace), "OTHER");
        assert_eq!(method_token(&tiny_http::Method::Connect), "OTHER");
    }
}

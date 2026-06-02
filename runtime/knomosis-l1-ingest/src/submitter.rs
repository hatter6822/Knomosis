// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Submitter: forwards signed actions to the downstream consumer.
//!
//! ## Why a trait
//!
//! Decoupling the submission path behind a `Submitter` trait keeps
//! RH-B independently testable and lets the daemon pick the transport
//! at runtime (a `Box<dyn Submitter>`) without touching the watcher
//! loop.
//!
//! ## What this module provides
//!
//!   * [`Submitter`] — the trait.  One method: `submit(&self,
//!     SignedAction) -> Result<Verdict>`.  Object-safe, with a
//!     delegating `impl Submitter for Box<dyn Submitter>` so the
//!     daemon can choose a concrete transport at runtime.
//!   * [`Verdict`] — the response from the downstream consumer.
//!     Mirrors the wire-format `0 = ok, 1 = notAdmissible,
//!     2 = parseError, 3 = busy`.
//!   * [`buffering::BufferingSubmitter`] — an in-memory submitter
//!     that records every action.  Test double / dry-run fallback.
//!   * [`raw_tcp::RawTcpSubmitter`] — the **canonical** submitter
//!     (FQ.13a): speaks `knomosis-host`'s actual length-prefixed
//!     wire format (`docs/abi.md` §10), so it is the first real
//!     RH-B → RH-C forwarder.  With `--emit-signer-hints` it opens
//!     each connection with the Rung-1 `KNH2` preamble and prepends
//!     each frame's 8-byte signer hint (default OFF ⇒ byte-identical
//!     legacy v1 frames).
//!   * [`http::HttpSubmitter`] — a length-prefixed-binary-over-HTTP
//!     submitter.  A **placeholder** transport (it POSTs to an HTTP
//!     endpoint, NOT `knomosis-host`'s raw-TCP wire format); kept for
//!     compatibility with HTTP-fronted deployments.
//!
//! ## Wire format (raw-TCP / canonical)
//!
//! [`raw_tcp::RawTcpSubmitter`] speaks the RH-C wire format
//! (`docs/abi.md` §10.1):
//!
//!   * Request: a legacy `[4-byte BE length][CBE SignedAction]` frame,
//!     or — under `--emit-signer-hints` — the Rung-1 form `KNH2 ++
//!     [8-byte BE signer hint][4-byte BE length][CBE SignedAction]`.
//!   * Response: a 1-byte [`Verdict`] + 4-byte BE reason length +
//!     reason payload.
//!
//! Both sides are independently length-bounded by 16 MiB
//! (`MAX_SUBMISSION_BYTES`).  The raw-TCP framing is hand-rolled but
//! pinned byte-for-byte against the canonical `knomosis_host::frame`
//! encoders by `tests/raw_tcp_submitter.rs` (single source of truth,
//! no runtime dependency on `knomosis-host`).

use std::time::Duration;

use crate::action::{ActorId, Nonce};
use crate::encoding::{encode_signed_action, EncodeError};
use crate::translation::UnsignedAction;

/// Maximum bytes accepted in a request or response.  Hard cap
/// against unbounded-payload DoS.
pub const MAX_SUBMISSION_BYTES: usize = 16 * 1024 * 1024;

/// Default submitter request timeout.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

/// Verdict returned by the downstream consumer.  Mirrors the
/// planned wire-format byte discriminator.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
#[repr(u8)]
pub enum Verdict {
    /// Action was admitted; the L2 state advanced.
    Ok = 0,
    /// Action was rejected as not admissible (e.g. nonce
    /// mismatch, policy denied, precondition false).  Halts
    /// the ingestor with an operator alert per the plan §RH-B.5.
    NotAdmissible = 1,
    /// Action could not be parsed.  Halts the ingestor — a parse
    /// error means the encoder is broken or the wire format
    /// drifted.
    ParseError = 2,
    /// Downstream consumer is busy.  The ingestor backs off and
    /// retries.
    Busy = 3,
}

impl Verdict {
    /// Decode from the wire-format byte.  Returns `None` for
    /// unrecognised values.
    #[must_use]
    pub const fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(Self::Ok),
            1 => Some(Self::NotAdmissible),
            2 => Some(Self::ParseError),
            3 => Some(Self::Busy),
            _ => None,
        }
    }

    /// Encode to the wire-format byte.
    #[must_use]
    pub const fn to_byte(self) -> u8 {
        self as u8
    }
}

/// Errors surfaced by the [`Submitter`] trait.
#[derive(Debug, thiserror::Error)]
pub enum SubmitError {
    /// The action could not be encoded.
    #[error("encode failure: {0}")]
    Encode(#[from] EncodeError),
    /// The downstream consumer returned an unrecognised verdict
    /// byte.
    #[error("unrecognised verdict byte {0}")]
    UnknownVerdict(u8),
    /// The downstream consumer returned `NotAdmissible` — a hard
    /// failure that requires operator intervention.
    #[error("downstream consumer rejected as not admissible")]
    NotAdmissible,
    /// The downstream consumer returned `ParseError` — the
    /// encoder must be broken.
    #[error("downstream consumer returned parse error")]
    ParseError,
    /// Underlying transport error.
    #[error("submitter transport error: {0}")]
    Transport(String),
}

/// Trait the watcher loop consumes.  Each `submit` call may
/// block; the watcher is single-threaded, so blocking the
/// submitter blocks the entire loop (which is desirable for
/// backpressure).
pub trait Submitter {
    /// Submit a signed action.  Returns the downstream
    /// consumer's verdict.
    ///
    /// # Errors
    ///
    /// See [`SubmitError`].
    fn submit(&self, signed: &SignedActionForSubmit) -> Result<Verdict, SubmitError>;
}

/// Delegating impl so the daemon can pick a concrete submitter
/// (`HttpSubmitter` or [`raw_tcp::RawTcpSubmitter`]) at runtime and pass
/// it to the generic [`crate::watcher::WatcherLoop`] as a single
/// `Box<dyn Submitter>` — without monomorphising the whole watcher per
/// transport.  `Submitter` is object-safe (`&self`, no generics, no
/// `Self` in the signature), so the trait object is well-formed.
impl Submitter for Box<dyn Submitter> {
    fn submit(&self, signed: &SignedActionForSubmit) -> Result<Verdict, SubmitError> {
        (**self).submit(signed)
    }
}

/// A fully-signed action ready for submission.  Materialises the
/// product of the watcher's sign step.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SignedActionForSubmit {
    /// The action to be submitted.
    pub unsigned: UnsignedAction,
    /// The 64-byte `(r || s)` low-s ECDSA signature.
    pub signature: [u8; 64],
}

impl SignedActionForSubmit {
    /// Encode this signed action via the CBE encoder.  Mirrors
    /// Lean's `Encoding.SignedAction.encode`.
    ///
    /// # Errors
    ///
    /// Propagates `EncodeError` from the inner action encoding.
    pub fn encode(&self) -> Result<Vec<u8>, EncodeError> {
        encode_signed_action(
            &self.unsigned.action,
            self.unsigned.signer,
            self.unsigned.nonce,
            &self.signature,
        )
    }

    /// Accessor for the signer's `ActorId`.
    #[must_use]
    pub fn signer(&self) -> ActorId {
        self.unsigned.signer
    }

    /// Accessor for the signer's nonce.
    #[must_use]
    pub fn nonce(&self) -> Nonce {
        self.unsigned.nonce
    }
}

/// In-memory buffering submitter.  Records every submission;
/// returns `Verdict::Ok` for each one.  Useful as a fallback when
/// no downstream consumer is configured (e.g. dry-run mode) and
/// as a test double.
pub mod buffering {
    use std::sync::Mutex;

    use super::{SignedActionForSubmit, SubmitError, Submitter, Verdict};

    /// An in-memory submitter that records every action it sees.
    /// Each `submit` call returns the verdict from the
    /// configured response sequence (cycling) — defaults to
    /// `Verdict::Ok` for every call.
    #[derive(Debug, Default)]
    pub struct BufferingSubmitter {
        inner: Mutex<BufferingInner>,
    }

    #[derive(Debug, Default)]
    struct BufferingInner {
        recorded: Vec<SignedActionForSubmit>,
        response_sequence: Vec<Verdict>,
        next_response: usize,
    }

    impl BufferingSubmitter {
        /// Construct an empty buffering submitter that returns
        /// `Verdict::Ok` for every submission.
        #[must_use]
        pub fn new() -> Self {
            Self::default()
        }

        /// Set the response sequence.  Each `submit` returns the
        /// next element of this list (cycling).  If the list is
        /// empty, defaults to `Verdict::Ok` for every call.
        pub fn set_responses(&self, responses: Vec<Verdict>) {
            let mut inner = self
                .inner
                .lock()
                .expect("buffering submitter lock poisoned");
            inner.response_sequence = responses;
            inner.next_response = 0;
        }

        /// Return a clone of the recorded submissions.
        #[must_use]
        pub fn recorded(&self) -> Vec<SignedActionForSubmit> {
            let inner = self
                .inner
                .lock()
                .expect("buffering submitter lock poisoned");
            inner.recorded.clone()
        }

        /// Number of recorded submissions.
        #[must_use]
        pub fn len(&self) -> usize {
            self.recorded().len()
        }

        /// `true` iff nothing was submitted.
        #[must_use]
        pub fn is_empty(&self) -> bool {
            self.recorded().is_empty()
        }
    }

    impl Submitter for BufferingSubmitter {
        fn submit(&self, signed: &SignedActionForSubmit) -> Result<Verdict, SubmitError> {
            let mut inner = self
                .inner
                .lock()
                .expect("buffering submitter lock poisoned");
            inner.recorded.push(signed.clone());
            let verdict = if inner.response_sequence.is_empty() {
                Verdict::Ok
            } else {
                let v =
                    inner.response_sequence[inner.next_response % inner.response_sequence.len()];
                inner.next_response = inner.next_response.wrapping_add(1);
                v
            };
            match verdict {
                Verdict::NotAdmissible => Err(SubmitError::NotAdmissible),
                Verdict::ParseError => Err(SubmitError::ParseError),
                v => Ok(v),
            }
        }
    }
}

/// Length-prefixed-binary-over-HTTP submitter.
pub mod http {
    use std::io::{Read, Write};
    use std::net::{TcpStream, ToSocketAddrs};
    use std::time::Duration;

    use super::{SignedActionForSubmit, SubmitError, Submitter, Verdict, DEFAULT_TIMEOUT};

    /// HTTP-based submitter.  Posts the CBE bytes to an
    /// `http://host:port[/path]` endpoint and reads the verdict
    /// byte from the response body.
    ///
    /// Mostly mirrors `source::json_rpc::JsonRpcL1Source`'s
    /// HTTP transport (no async runtime, hand-rolled HTTP/1.1).
    ///
    /// `Send + Sync` because every field is itself thread-safe.
    /// The watcher loop is single-threaded; the trait bounds are
    /// for ergonomic sharing in test harnesses.
    #[derive(Debug)]
    pub struct HttpSubmitter {
        url: String,
        host: String,
        port: u16,
        path: String,
        timeout: Duration,
    }

    impl HttpSubmitter {
        /// Construct from `http://host:port[/path]`.  Returns
        /// `Err` for malformed URLs.
        ///
        /// # Errors
        ///
        /// Returns `SubmitError::Transport` on URL parse failure.
        pub fn new(url: impl Into<String>) -> Result<Self, SubmitError> {
            let url_str = url.into();
            let parsed = super::parse_http_url(&url_str)
                .map_err(|e| SubmitError::Transport(format!("URL parse: {e}")))?;
            Ok(Self {
                url: url_str,
                host: parsed.host,
                port: parsed.port,
                path: parsed.path,
                timeout: DEFAULT_TIMEOUT,
            })
        }

        /// Override the default request timeout.
        #[must_use]
        pub fn with_timeout(mut self, timeout: Duration) -> Self {
            self.timeout = timeout;
            self
        }

        /// The endpoint URL.  Diagnostic only.
        #[must_use]
        pub fn url(&self) -> &str {
            &self.url
        }
    }

    impl Submitter for HttpSubmitter {
        fn submit(&self, signed: &SignedActionForSubmit) -> Result<Verdict, SubmitError> {
            let body = signed.encode()?;
            // Open TCP connection.
            let addr = format!("{}:{}", self.host, self.port);
            let socket_addr = addr
                .to_socket_addrs()
                .map_err(|e| SubmitError::Transport(format!("resolve {addr}: {e}")))?
                .next()
                .ok_or_else(|| SubmitError::Transport(format!("no addresses for {addr}")))?;
            let mut stream = TcpStream::connect_timeout(&socket_addr, self.timeout)
                .map_err(|e| SubmitError::Transport(format!("connect: {e}")))?;
            stream
                .set_read_timeout(Some(self.timeout))
                .map_err(|e| SubmitError::Transport(format!("set_read_timeout: {e}")))?;
            stream
                .set_write_timeout(Some(self.timeout))
                .map_err(|e| SubmitError::Transport(format!("set_write_timeout: {e}")))?;
            // Write request: HTTP headers + length prefix + body.
            let req_head = format!(
                "POST {} HTTP/1.1\r\n\
                 Host: {}\r\n\
                 Content-Type: application/octet-stream\r\n\
                 Content-Length: {}\r\n\
                 Connection: close\r\n\
                 \r\n",
                self.path,
                self.host,
                body.len()
            );
            stream
                .write_all(req_head.as_bytes())
                .map_err(|e| SubmitError::Transport(format!("write head: {e}")))?;
            stream
                .write_all(&body)
                .map_err(|e| SubmitError::Transport(format!("write body: {e}")))?;
            stream
                .flush()
                .map_err(|e| SubmitError::Transport(format!("flush: {e}")))?;
            // Read response.
            let mut response = Vec::with_capacity(1024);
            let mut buf = [0u8; 1024];
            loop {
                let n = stream
                    .read(&mut buf)
                    .map_err(|e| SubmitError::Transport(format!("read: {e}")))?;
                if n == 0 {
                    break;
                }
                if response.len() + n > super::MAX_SUBMISSION_BYTES {
                    return Err(SubmitError::Transport(format!(
                        "response exceeds {} bytes",
                        super::MAX_SUBMISSION_BYTES
                    )));
                }
                response.extend_from_slice(&buf[..n]);
            }
            // Split headers / body.
            let body_start = super::find_double_crlf(&response).ok_or_else(|| {
                SubmitError::Transport("response missing header/body separator".into())
            })?;
            let header_str = std::str::from_utf8(&response[..body_start])
                .map_err(|_| SubmitError::Transport("response header is not valid UTF-8".into()))?;
            let status = super::parse_http_status(header_str).ok_or_else(|| {
                SubmitError::Transport("response is not a valid HTTP/1.1 status line".into())
            })?;
            if !(200..300).contains(&status) {
                return Err(SubmitError::Transport(format!("HTTP {status}")));
            }
            let resp_body = &response[body_start + 4..];
            // The verdict byte is the first byte of the response
            // body; reason payload (if any) follows.
            let verdict_byte = *resp_body
                .first()
                .ok_or_else(|| SubmitError::Transport("empty response body".into()))?;
            let verdict = Verdict::from_byte(verdict_byte)
                .ok_or(SubmitError::UnknownVerdict(verdict_byte))?;
            match verdict {
                Verdict::NotAdmissible => Err(SubmitError::NotAdmissible),
                Verdict::ParseError => Err(SubmitError::ParseError),
                v => Ok(v),
            }
        }
    }
}

/// Raw-TCP submitter speaking the canonical `knomosis-host` wire format
/// (RH-C / `docs/abi.md` §10), with opt-in Rung-1 signer-hint emission
/// (Workstream GP.8, Track A / FQ — FQ.13a).
///
/// Unlike [`http::HttpSubmitter`] (an HTTP/1.1 placeholder that cannot
/// talk to a real `knomosis-host`), this submitter speaks the host's
/// actual length-prefixed framing, so it is the first real
/// `knomosis-l1-ingest` → `knomosis-host` forwarder.  With
/// `--emit-signer-hints` it opens each (one-shot) connection with the
/// `KNH2` preamble and prepends each frame's 8-byte signer hint (the
/// `ActorId` the ingestor already holds), exercising the host's two-tier
/// DRR inner tier; default OFF it emits byte-identical legacy v1 frames.
pub mod raw_tcp {
    use std::io::{Read, Write};
    use std::net::{Shutdown, TcpStream, ToSocketAddrs};
    use std::time::Duration;

    use super::{SignedActionForSubmit, SubmitError, Submitter, Verdict, DEFAULT_TIMEOUT};

    /// The Rung-1 v2 preamble.  MUST stay byte-identical to
    /// `knomosis_host::frame::KNH2_PREAMBLE`; the
    /// `frames_match_canonical_encoders` test (`tests/raw_tcp_submitter.rs`)
    /// pins it against the published encoder so a drift fails the build —
    /// the single-source-of-truth discipline FQ.13 establishes, enforced
    /// here mechanically rather than by a runtime dependency.
    const KNH2_PREAMBLE: [u8; 4] = *b"KNH2";

    /// Raw-TCP submitter to a `knomosis-host` listener.
    ///
    /// `Send + Sync` (every field is); the watcher loop is
    /// single-threaded, but the bounds keep it ergonomic to share.
    #[derive(Clone, Debug)]
    pub struct RawTcpSubmitter {
        /// The `host:port` endpoint, resolved per request (so a DNS
        /// change is picked up), mirroring [`super::http::HttpSubmitter`].
        addr: String,
        /// Whether to emit the Rung-1 `KNH2` preamble + per-frame signer
        /// hint (default `false` ⇒ byte-identical legacy v1 frames).
        emit_hints: bool,
        /// Per-request connect / read / write timeout.
        timeout: Duration,
    }

    impl RawTcpSubmitter {
        /// Construct from a `host:port` endpoint (e.g. `127.0.0.1:7654`).
        ///
        /// The endpoint is validated for resolvability up front so a
        /// typo fails at startup, not on the first L1 event; it is then
        /// re-resolved per request.
        ///
        /// # Errors
        ///
        /// Returns `SubmitError::Transport` if `addr` does not resolve.
        pub fn new(addr: impl Into<String>) -> Result<Self, SubmitError> {
            let addr = addr.into();
            // Validate resolvability now (fail fast on a misconfiguration).
            addr.to_socket_addrs()
                .map_err(|e| SubmitError::Transport(format!("resolve {addr}: {e}")))?
                .next()
                .ok_or_else(|| SubmitError::Transport(format!("no addresses for {addr}")))?;
            Ok(Self {
                addr,
                emit_hints: false,
                timeout: DEFAULT_TIMEOUT,
            })
        }

        /// Enable or disable Rung-1 signer-hint emission (default off).
        #[must_use]
        pub fn with_emit_hints(mut self, emit_hints: bool) -> Self {
            self.emit_hints = emit_hints;
            self
        }

        /// Override the default request timeout.
        #[must_use]
        pub fn with_timeout(mut self, timeout: Duration) -> Self {
            self.timeout = timeout;
            self
        }

        /// Whether this submitter emits Rung-1 signer hints.  Diagnostic.
        #[must_use]
        pub fn emits_hints(&self) -> bool {
            self.emit_hints
        }

        /// The endpoint.  Diagnostic only.
        #[must_use]
        pub fn addr(&self) -> &str {
            &self.addr
        }

        /// Build the exact request bytes for `signed`: a legacy v1 frame
        /// `[4-byte BE len][CBE body]`, or — when `emit_hints` — the
        /// Rung-1 form `KNH2 ++ [8-byte BE signer hint][4-byte BE
        /// len][CBE body]`.  Factored out so the framing is unit-tested
        /// without a socket (and byte-pinned against the canonical
        /// `knomosis_host::frame` encoders).
        ///
        /// # Errors
        ///
        /// `SubmitError::Encode` if the action cannot be CBE-encoded;
        /// `SubmitError::Transport` if the body exceeds `u32::MAX`
        /// (the wire length field; impossible for any real action).
        pub fn build_request(
            &self,
            signed: &SignedActionForSubmit,
        ) -> Result<Vec<u8>, SubmitError> {
            let body = signed.encode()?;
            let len = u32::try_from(body.len()).map_err(|_| {
                SubmitError::Transport(format!("payload {} exceeds u32 wire length", body.len()))
            })?;
            let mut out = Vec::with_capacity(KNH2_PREAMBLE.len() + 8 + 4 + body.len());
            if self.emit_hints {
                // v2: preamble once per (one-shot) connection, then the
                // 8-byte big-endian signer hint.
                out.extend_from_slice(&KNH2_PREAMBLE);
                out.extend_from_slice(&signed.signer().to_be_bytes());
            }
            out.extend_from_slice(&len.to_be_bytes());
            out.extend_from_slice(&body);
            Ok(out)
        }
    }

    impl Submitter for RawTcpSubmitter {
        fn submit(&self, signed: &SignedActionForSubmit) -> Result<Verdict, SubmitError> {
            let request = self.build_request(signed)?;
            let socket_addr = self
                .addr
                .to_socket_addrs()
                .map_err(|e| SubmitError::Transport(format!("resolve {}: {e}", self.addr)))?
                .next()
                .ok_or_else(|| SubmitError::Transport(format!("no addresses for {}", self.addr)))?;
            let mut stream = TcpStream::connect_timeout(&socket_addr, self.timeout)
                .map_err(|e| SubmitError::Transport(format!("connect: {e}")))?;
            stream
                .set_read_timeout(Some(self.timeout))
                .map_err(|e| SubmitError::Transport(format!("set_read_timeout: {e}")))?;
            stream
                .set_write_timeout(Some(self.timeout))
                .map_err(|e| SubmitError::Transport(format!("set_write_timeout: {e}")))?;
            stream
                .write_all(&request)
                .map_err(|e| SubmitError::Transport(format!("write request: {e}")))?;
            stream
                .flush()
                .map_err(|e| SubmitError::Transport(format!("flush: {e}")))?;
            // Half-close the write side: the host reads exactly one
            // length-bounded frame (it never needs EOF to dispatch), but
            // this signals "no more requests" cleanly for the one-shot
            // lifecycle and lets the response read terminate on the
            // host's post-response close.
            let _ = stream.shutdown(Shutdown::Write);
            // Response framing (`docs/abi.md` §10.1): 1-byte verdict +
            // 4-byte BE reason length + M UTF-8 reason bytes.  Read the
            // fixed 5-byte header precisely (no dependence on the host
            // closing), then drain the bounded reason.
            let mut header = [0u8; 5];
            stream
                .read_exact(&mut header)
                .map_err(|e| SubmitError::Transport(format!("read response header: {e}")))?;
            let verdict_byte = header[0];
            let reason_len =
                u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
            if reason_len > super::MAX_SUBMISSION_BYTES {
                return Err(SubmitError::Transport(format!(
                    "response reason length {reason_len} exceeds {} bytes",
                    super::MAX_SUBMISSION_BYTES
                )));
            }
            if reason_len > 0 {
                let mut reason = vec![0u8; reason_len];
                stream
                    .read_exact(&mut reason)
                    .map_err(|e| SubmitError::Transport(format!("read response reason: {e}")))?;
            }
            let verdict = Verdict::from_byte(verdict_byte)
                .ok_or(SubmitError::UnknownVerdict(verdict_byte))?;
            match verdict {
                Verdict::NotAdmissible => Err(SubmitError::NotAdmissible),
                Verdict::ParseError => Err(SubmitError::ParseError),
                v => Ok(v),
            }
        }
    }
}

/// HTTP URL parts: `host`, `port`, `path`.  Lifted from
/// `source.rs` for use by `http::HttpSubmitter`.
pub(crate) struct HttpUrl {
    pub(crate) host: String,
    pub(crate) port: u16,
    pub(crate) path: String,
}

/// Parse `http://host:port[/path]` into its parts.  Lifted from
/// `source.rs`'s identical helper; `pub(crate)` so the submitter
/// module can share it.
pub(crate) fn parse_http_url(url: &str) -> Result<HttpUrl, String> {
    let after_scheme = url
        .strip_prefix("http://")
        .ok_or_else(|| format!("expected 'http://' prefix, got '{url}'"))?;
    let (authority, path) = match after_scheme.find('/') {
        Some(idx) => (&after_scheme[..idx], &after_scheme[idx..]),
        None => (after_scheme, "/"),
    };
    let (host, port) = match authority.rfind(':') {
        Some(idx) => {
            let host = &authority[..idx];
            let port_str = &authority[idx + 1..];
            let port: u16 = port_str
                .parse()
                .map_err(|e| format!("port '{port_str}' invalid: {e}"))?;
            (host.to_string(), port)
        }
        None => (authority.to_string(), 80),
    };
    if host.is_empty() {
        return Err("empty host in URL".to_string());
    }
    Ok(HttpUrl {
        host,
        port,
        path: path.to_string(),
    })
}

/// Locate the index of the `\r\n\r\n` separator between HTTP
/// headers and body.
pub(crate) fn find_double_crlf(data: &[u8]) -> Option<usize> {
    for i in 0..data.len().saturating_sub(3) {
        if &data[i..i + 4] == b"\r\n\r\n" {
            return Some(i);
        }
    }
    None
}

/// Parse the HTTP/1.1 status code from a response header.
pub(crate) fn parse_http_status(header: &str) -> Option<u16> {
    let first_line = header.lines().next()?;
    let mut parts = first_line.split_whitespace();
    let _version = parts.next()?;
    let code = parts.next()?;
    code.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::buffering::BufferingSubmitter;
    use super::raw_tcp::RawTcpSubmitter;
    use super::{
        find_double_crlf, parse_http_status, parse_http_url, SignedActionForSubmit, SubmitError,
        Submitter, Verdict,
    };
    use crate::action::{Action, ActorId, PublicKey};
    use crate::address_book::BRIDGE_ACTOR_ID;
    use crate::translation::UnsignedAction;

    fn sample_signed_action() -> SignedActionForSubmit {
        SignedActionForSubmit {
            unsigned: UnsignedAction {
                action: Action::RegisterIdentity {
                    actor: 1,
                    pk: PublicKey::from_bytes(&[0xab, 0xcd]),
                },
                signer: BRIDGE_ACTOR_ID,
                nonce: 7,
            },
            signature: [0xff; 64],
        }
    }

    /// `Verdict::from_byte` round-trips through `to_byte`.
    #[test]
    fn verdict_round_trip() {
        for v in [
            Verdict::Ok,
            Verdict::NotAdmissible,
            Verdict::ParseError,
            Verdict::Busy,
        ] {
            assert_eq!(Verdict::from_byte(v.to_byte()), Some(v));
        }
    }

    /// `Verdict::from_byte` returns `None` for unknown bytes.
    #[test]
    fn verdict_unknown_returns_none() {
        for b in 4u8..=10 {
            assert_eq!(Verdict::from_byte(b), None);
        }
    }

    /// `Verdict::to_byte` matches the wire-format table.
    #[test]
    fn verdict_byte_table() {
        assert_eq!(Verdict::Ok.to_byte(), 0);
        assert_eq!(Verdict::NotAdmissible.to_byte(), 1);
        assert_eq!(Verdict::ParseError.to_byte(), 2);
        assert_eq!(Verdict::Busy.to_byte(), 3);
    }

    // ===== FQ.13a — RawTcpSubmitter framing =========================

    /// Build a signed action whose `SignedAction.signer` is `signer`
    /// (the value the Rung-1 hint must mirror).  The `actor` field is a
    /// fixed distinct value, so the test proves the hint comes from
    /// `signer()`, not from the action's payload.
    fn signed_with_signer(signer: ActorId) -> SignedActionForSubmit {
        SignedActionForSubmit {
            unsigned: UnsignedAction {
                action: Action::RegisterIdentity {
                    actor: 1,
                    pk: PublicKey::from_bytes(&[0xab, 0xcd]),
                },
                signer,
                nonce: 3,
            },
            signature: [0x11; 64],
        }
    }

    /// Default (no hints): the request is a legacy v1 frame
    /// `[4-byte BE len][CBE body]` — byte-identical to the pre-Rung-1
    /// framing (FQ.13a "default OFF is byte-identical").
    #[test]
    fn raw_tcp_legacy_frame_layout() {
        let s = RawTcpSubmitter::new("127.0.0.1:7654").unwrap();
        assert!(!s.emits_hints());
        let action = signed_with_signer(5);
        let body = action.encode().unwrap();
        let frame = s.build_request(&action).unwrap();
        assert_eq!(frame.len(), 4 + body.len());
        assert_eq!(
            &frame[..4],
            &u32::try_from(body.len()).unwrap().to_be_bytes()
        );
        assert_eq!(&frame[4..], &body[..]);
    }

    /// With hints: `KNH2 ++ [8-byte BE signer hint][4-byte BE len][body]`;
    /// the hint is EXACTLY the signer `ActorId` (big-endian).
    #[test]
    fn raw_tcp_hinted_frame_layout() {
        let signer = 0x0102_0304_0506_0708u64;
        let s = RawTcpSubmitter::new("127.0.0.1:7654")
            .unwrap()
            .with_emit_hints(true);
        assert!(s.emits_hints());
        let action = signed_with_signer(signer);
        let body = action.encode().unwrap();
        let frame = s.build_request(&action).unwrap();
        assert_eq!(&frame[..4], b"KNH2");
        assert_eq!(
            &frame[4..12],
            &signer.to_be_bytes(),
            "hint must equal signer"
        );
        assert_eq!(
            &frame[12..16],
            &u32::try_from(body.len()).unwrap().to_be_bytes()
        );
        assert_eq!(&frame[16..], &body[..]);
        assert_eq!(frame.len(), 4 + 8 + 4 + body.len());
    }

    /// The hinted frame is exactly the legacy frame with a 12-byte
    /// (preamble + hint) prefix — the `[len][body]` tail is identical, so
    /// the body the host decodes is byte-for-byte the same either way.
    #[test]
    fn raw_tcp_hinted_is_legacy_plus_prefix() {
        let action = signed_with_signer(9);
        let legacy = RawTcpSubmitter::new("127.0.0.1:1")
            .unwrap()
            .build_request(&action)
            .unwrap();
        let hinted = RawTcpSubmitter::new("127.0.0.1:1")
            .unwrap()
            .with_emit_hints(true)
            .build_request(&action)
            .unwrap();
        assert_eq!(
            &hinted[12..],
            &legacy[..],
            "the [len][body] tail must match"
        );
    }

    /// An unresolvable endpoint fails fast at construction.
    #[test]
    fn raw_tcp_rejects_unresolvable_addr() {
        assert!(matches!(
            RawTcpSubmitter::new("definitely not a socket address"),
            Err(SubmitError::Transport(_))
        ));
    }

    /// FQ.13a — the `Box<dyn Submitter>` delegating impl (the daemon's
    /// runtime transport-selection seam) forwards `submit` to the boxed
    /// submitter and returns its verdict.
    #[test]
    fn box_dyn_submitter_delegates() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;

        /// A test submitter that counts calls and echoes a fixed verdict.
        struct CountingSubmitter {
            calls: Arc<AtomicUsize>,
            verdict: Verdict,
        }
        impl Submitter for CountingSubmitter {
            fn submit(&self, _: &SignedActionForSubmit) -> Result<Verdict, SubmitError> {
                self.calls.fetch_add(1, Ordering::Relaxed);
                Ok(self.verdict)
            }
        }

        let calls = Arc::new(AtomicUsize::new(0));
        let boxed: Box<dyn Submitter> = Box::new(CountingSubmitter {
            calls: Arc::clone(&calls),
            verdict: Verdict::Busy,
        });
        let action = signed_with_signer(7);
        // The verdict + the call BOTH come from the boxed inner impl.
        assert_eq!(boxed.submit(&action).unwrap(), Verdict::Busy);
        assert_eq!(boxed.submit(&action).unwrap(), Verdict::Busy);
        assert_eq!(
            calls.load(Ordering::Relaxed),
            2,
            "Box<dyn Submitter> must delegate every submit to the boxed impl"
        );
    }

    /// `BufferingSubmitter` records and replies Ok by default.
    #[test]
    fn buffering_submitter_default() {
        let s = BufferingSubmitter::new();
        let sa = sample_signed_action();
        assert_eq!(s.submit(&sa).unwrap(), Verdict::Ok);
        let recorded = s.recorded();
        assert_eq!(recorded.len(), 1);
        assert_eq!(recorded[0], sa);
    }

    /// `BufferingSubmitter` cycles through a custom response
    /// sequence.
    #[test]
    fn buffering_submitter_cycles_responses() {
        let s = BufferingSubmitter::new();
        s.set_responses(vec![Verdict::Busy, Verdict::Ok]);
        let sa = sample_signed_action();
        assert_eq!(s.submit(&sa).unwrap(), Verdict::Busy);
        assert_eq!(s.submit(&sa).unwrap(), Verdict::Ok);
        assert_eq!(s.submit(&sa).unwrap(), Verdict::Busy);
    }

    /// `BufferingSubmitter` returns `NotAdmissible` as an error.
    #[test]
    fn buffering_submitter_not_admissible() {
        let s = BufferingSubmitter::new();
        s.set_responses(vec![Verdict::NotAdmissible]);
        let sa = sample_signed_action();
        match s.submit(&sa) {
            Err(SubmitError::NotAdmissible) => {}
            other => panic!("expected NotAdmissible, got {other:?}"),
        }
    }

    /// `BufferingSubmitter` returns `ParseError` as an error.
    #[test]
    fn buffering_submitter_parse_error() {
        let s = BufferingSubmitter::new();
        s.set_responses(vec![Verdict::ParseError]);
        let sa = sample_signed_action();
        match s.submit(&sa) {
            Err(SubmitError::ParseError) => {}
            other => panic!("expected ParseError, got {other:?}"),
        }
    }

    /// `SignedActionForSubmit::encode` produces non-empty CBE
    /// bytes.
    #[test]
    fn signed_action_encode_non_empty() {
        let sa = sample_signed_action();
        let encoded = sa.encode().unwrap();
        assert!(!encoded.is_empty());
    }

    /// Accessors return the right fields.
    #[test]
    fn signed_action_accessors() {
        let sa = sample_signed_action();
        assert_eq!(sa.signer(), BRIDGE_ACTOR_ID);
        assert_eq!(sa.nonce(), 7);
    }

    /// `parse_http_url` accepts a valid HTTP URL.
    #[test]
    fn parse_http_url_ok() {
        let p = parse_http_url("http://localhost:8080/submit").unwrap();
        assert_eq!(p.host, "localhost");
        assert_eq!(p.port, 8080);
        assert_eq!(p.path, "/submit");
    }

    /// `parse_http_url` rejects non-http schemes.
    #[test]
    fn parse_http_url_rejects_non_http() {
        assert!(parse_http_url("https://localhost:8080").is_err());
        assert!(parse_http_url("tcp://localhost:8080").is_err());
    }

    /// `find_double_crlf` finds the header/body separator.
    #[test]
    fn find_double_crlf_basic() {
        let data = b"HTTP/1.1 200 OK\r\nFoo: bar\r\n\r\nBody";
        let idx = find_double_crlf(data).unwrap();
        assert_eq!(&data[idx..idx + 4], b"\r\n\r\n");
    }

    /// `parse_http_status` extracts the code.
    #[test]
    fn parse_http_status_ok() {
        assert_eq!(parse_http_status("HTTP/1.1 200 OK\r\n..."), Some(200));
        assert_eq!(parse_http_status("HTTP/1.1 503 Server Error"), Some(503));
        assert_eq!(parse_http_status(""), None);
    }
}

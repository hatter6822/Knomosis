// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Submitter: forwards signed actions to the downstream consumer.
//!
//! ## Why a trait
//!
//! The downstream consumer (`knomosis-host`, RH-C) has not yet
//! landed.  Decoupling the submission path behind a `Submitter`
//! trait keeps RH-B independently testable and lets us swap in
//! the production HTTP / Unix-socket impl when RH-C lands without
//! touching the watcher loop.
//!
//! ## What this module provides
//!
//!   * [`Submitter`] — the trait.  One method: `submit(&self,
//!     SignedAction) -> Result<Verdict>`.
//!   * [`Verdict`] — the response from the downstream consumer.
//!     Mirrors the planned wire-format `0 = ok, 1 = notAdmissible,
//!     2 = parseError, 3 = busy`.
//!   * [`buffering::BufferingSubmitter`] — an in-memory submitter
//!     that records every action.  Default impl when no
//!     downstream consumer is configured; production deployments
//!     swap in [`http::HttpSubmitter`] (or a future Unix-socket
//!     variant).
//!   * [`http::HttpSubmitter`] — a length-prefixed-binary-over-
//!     HTTP submitter.  Issues a POST with the CBE bytes of the
//!     SignedAction and parses the verdict-byte response.
//!
//! ## Wire format (HTTP variant)
//!
//! The HTTP submitter speaks the planned RH-C wire format:
//!
//!   * Request body: length-prefixed CBE-encoded SignedAction.
//!     8-byte BE u64 length + the action bytes.
//!   * Response body: a single byte (the [`Verdict`]) followed by
//!     an optional 8-byte BE u64 length + reason-string payload.
//!
//! Both sides are independently length-bounded by 16 MiB
//! (`MAX_SUBMISSION_BYTES`).

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
    use super::{
        find_double_crlf, parse_http_status, parse_http_url, SignedActionForSubmit, SubmitError,
        Submitter, Verdict,
    };
    use crate::action::{Action, PublicKey};
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

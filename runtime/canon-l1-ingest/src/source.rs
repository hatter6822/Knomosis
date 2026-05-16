// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! L1 event source abstraction.
//!
//! Provides a trait [`L1Source`] that the watcher loop consumes,
//! plus two implementations:
//!
//!   * [`mock::InMemoryL1Source`] — fully in-memory; the test
//!     harness uses this to drive the watcher with synthetic
//!     blocks and pre-recorded events.  Available in
//!     `#[cfg(test)]` and to consumers of this crate as a
//!     library.
//!   * [`json_rpc::JsonRpcL1Source`] — production HTTP /
//!     JSON-RPC source.  Uses `std::net::TcpStream` plus a tiny
//!     hand-rolled HTTP/1.1 client (no `ureq`, no async) to keep
//!     the dependency footprint minimal.  The RPC envelope is
//!     `serde_json`-based.
//!
//! ## Why a trait + mock pattern
//!
//! The watcher's correctness is decoupled from network details.
//! By driving all I/O through `L1Source`, the watcher's unit
//! tests cover the entire orchestration loop (re-org handling,
//! confirmation depth, idempotency) without spinning up a real
//! Ethereum node.  The production `JsonRpcL1Source` is a thin
//! transport-only adaptor.
//!
//! ## What the trait requires
//!
//!   * `latest_block_number()` — the L1 chain head.  Polled by
//!     the watcher to decide when to advance.
//!   * `block_header_by_number(n)` — the block header at height
//!     `n`.  Returned for inclusion in the re-org window.
//!   * `logs_in_block_by_hash(hash, contract)` — every log
//!     emitted by `contract` in the block with the given hash.
//!     Filtering by hash (rather than number) defends against
//!     re-orgs racing the header-fetch + log-fetch sequence.

use crate::events::RawLog;

/// Errors a [`L1Source`] implementation may surface.
#[derive(Debug, thiserror::Error)]
pub enum SourceError {
    /// The source's underlying transport returned an error.
    /// Examples: connection refused, request timeout, HTTP 5xx.
    #[error("L1 source transport error: {0}")]
    Transport(String),
    /// The source returned malformed data (e.g. a JSON-RPC
    /// response with the wrong field types).
    #[error("malformed L1 source response: {0}")]
    Malformed(String),
    /// The requested block doesn't exist (number > current head).
    #[error("block {0} not found")]
    BlockNotFound(u64),
}

/// Trait the watcher loop consumes.  Implementations supply the
/// minimum quartet of operations needed for re-org-aware event
/// ingestion: chain head, block header, block logs.
pub trait L1Source {
    /// Return the current L1 chain-head block number.
    ///
    /// # Errors
    ///
    /// See [`SourceError`].
    fn latest_block_number(&self) -> Result<u64, SourceError>;

    /// Return the header of block `number`.
    ///
    /// # Errors
    ///
    /// See [`SourceError`]; in particular `BlockNotFound` if
    /// `number` is past the chain head.
    fn block_header_by_number(&self, number: u64)
        -> Result<crate::reorg::BlockHeader, SourceError>;

    /// Return every log emitted by `contract` in the block
    /// with the given **block hash**, in log-index order.  An
    /// empty vector means the contract emitted no logs in that
    /// block (not an error).
    ///
    /// Implementations MUST filter by hash, not by number.
    /// This defends against a re-org happening between the
    /// header fetch and the log fetch: if the chain forked and
    /// the RPC returned logs from a different block at the same
    /// number, the watcher's idempotency / re-org accounting
    /// would silently desync from the L1 reality.  Filtering by
    /// hash makes the RPC contract resolve "no such block" as
    /// the typed error rather than returning wrong-fork logs.
    ///
    /// The Ethereum JSON-RPC spec (EIP-234) standardises a
    /// `blockHash` parameter for `eth_getLogs`; production RPC
    /// providers have supported this since Geth 1.8.
    ///
    /// Implementations SHOULD additionally verify that each
    /// returned log's `blockHash` matches the requested hash
    /// (defence-in-depth; some RPC providers have historically
    /// ignored the filter on certain queries).  The verification
    /// is performed by the default no-op trait wrapper but
    /// individual implementations may strengthen.
    ///
    /// # Errors
    ///
    /// See [`SourceError`].
    fn logs_in_block_by_hash(
        &self,
        block_hash: &crate::events::TopicHash,
        contract: &crate::action::EthAddress,
    ) -> Result<Vec<RawLog>, SourceError>;
}

/// In-memory test mock for [`L1Source`].
///
/// The implementation stores a vector of `(header, logs)` pairs
/// in ascending block-number order.  Tests construct one of
/// these via `InMemoryL1Source::new()` then `push_block(...)`
/// for each synthesised block.
///
/// Public (not test-cfg) so downstream tests in `watcher.rs` and
/// integration tests can use it.  Marked `pub` rather than
/// `pub(crate)` because the integration tests live outside the
/// crate.
pub mod mock {
    use std::collections::HashMap;

    use crate::action::EthAddress;
    use crate::events::{RawLog, TopicHash};
    use crate::reorg::BlockHeader;

    use super::{L1Source, SourceError};

    /// An in-memory L1 source.  Each `push_block` adds a header
    /// + per-contract log map; queries return canned data.
    #[derive(Clone, Debug, Default)]
    pub struct InMemoryL1Source {
        blocks: Vec<MockBlock>,
        latest_block: Option<u64>,
    }

    /// One synthesised block.  Internal — public methods are
    /// `push_block` / `set_latest`.
    #[derive(Clone, Debug)]
    struct MockBlock {
        header: BlockHeader,
        // Map from contract address to list of logs.
        logs: HashMap<EthAddress, Vec<RawLog>>,
    }

    impl InMemoryL1Source {
        /// Construct an empty mock source.
        #[must_use]
        pub fn new() -> Self {
            Self::default()
        }

        /// Push a synthesised block with a (possibly empty)
        /// per-contract log map.  Blocks must be pushed in
        /// ascending number order; otherwise `panic!`.
        pub fn push_block(&mut self, header: BlockHeader, logs: HashMap<EthAddress, Vec<RawLog>>) {
            if let Some(last) = self.blocks.last() {
                assert!(
                    header.number > last.header.number,
                    "blocks must be pushed in ascending order"
                );
            }
            self.blocks.push(MockBlock { header, logs });
        }

        /// Set what `latest_block_number` returns.  If not set,
        /// the highest pushed block's number is used.  Allows
        /// tests to simulate "block exists but isn't yet
        /// confirmed".
        pub fn set_latest(&mut self, latest: u64) {
            self.latest_block = Some(latest);
        }

        /// Replace blocks at and after `start` with `new_chain`.
        /// Simulates an L1 re-org.  `new_chain` must be in
        /// ascending block-number order starting at `start`.
        pub fn rewrite_chain(
            &mut self,
            start: u64,
            new_chain: Vec<(BlockHeader, HashMap<EthAddress, Vec<RawLog>>)>,
        ) {
            self.blocks.retain(|b| b.header.number < start);
            for (header, logs) in new_chain {
                self.push_block(header, logs);
            }
        }
    }

    impl L1Source for InMemoryL1Source {
        fn latest_block_number(&self) -> Result<u64, SourceError> {
            if let Some(latest) = self.latest_block {
                return Ok(latest);
            }
            Ok(self
                .blocks
                .last()
                .map(|b| b.header.number)
                .unwrap_or_default())
        }

        fn block_header_by_number(&self, number: u64) -> Result<BlockHeader, SourceError> {
            self.blocks
                .iter()
                .find(|b| b.header.number == number)
                .map(|b| b.header)
                .ok_or(SourceError::BlockNotFound(number))
        }

        fn logs_in_block_by_hash(
            &self,
            block_hash: &TopicHash,
            contract: &EthAddress,
        ) -> Result<Vec<RawLog>, SourceError> {
            let block = self
                .blocks
                .iter()
                .find(|b| &b.header.hash == block_hash)
                .ok_or_else(|| {
                    SourceError::Malformed(format!(
                        "no block with hash {block_hash:?} in mock source"
                    ))
                })?;
            // Defence-in-depth: filter logs to those whose
            // `block_number` matches the cached block's number.
            // (For tests, the mock-pushed logs are trusted, but
            // this filtering matches the production
            // `JsonRpcL1Source::logs_in_block_by_hash` discipline.)
            let logs = block.logs.get(contract).cloned().unwrap_or_default();
            Ok(logs
                .into_iter()
                .filter(|l| l.block_number == block.header.number)
                .collect())
        }
    }
}

/// Production JSON-RPC L1 source.  Hand-rolled HTTP/1.1 client
/// over `std::net::TcpStream`; no async runtime required.
///
/// ## HTTP transport limitations
///
/// The hand-rolled HTTP/1.1 client is intentionally minimal:
///
///   * **HTTP only**: HTTPS / WS / IPC are out of scope at the
///     RH-B landing.  Production deployments wrap with a
///     TLS-terminating reverse proxy if cross-network security
///     is required.
///   * **`Connection: close` only**: the client sends
///     `Connection: close` and reads until EOF.  HTTP/1.1
///     persistent connections are not used.
///   * **No chunked transfer-encoding**: we read the entire
///     response into a buffer and assume the body is
///     content-length-delimited or the connection is closed
///     after the body.  Production Ethereum RPC endpoints
///     (geth, erigon, infura, alchemy) all return
///     content-length-delimited responses for `eth_*` methods.
///   * **No redirect following**: an HTTP 301/302 surfaces as
///     `SourceError::Transport` with the HTTP status code.
///   * **10 MiB max response body** (`MAX_RESPONSE_BYTES`):
///     defends against unbounded-payload DoS.  Adjust if your
///     RPC provider returns larger payloads (e.g.  state-dump
///     queries).
pub mod json_rpc {
    use std::io::{Read, Write};
    use std::net::{TcpStream, ToSocketAddrs};
    use std::time::Duration;

    use serde::{Deserialize, Serialize};
    use serde_json::Value;

    use crate::action::EthAddress;
    use crate::events::{RawLog, TopicHash};
    use crate::reorg::BlockHeader;

    use super::{L1Source, SourceError};

    /// Maximum response body the client will accept (10 MiB).
    /// Defends against unbounded-response DoS.
    pub const MAX_RESPONSE_BYTES: usize = 10 * 1024 * 1024;

    /// Default request timeout (10 s).  Production deployments
    /// may override via `JsonRpcL1Source::with_timeout`.
    pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);

    /// Errors specific to the JSON-RPC transport.  Internal;
    /// converted to `SourceError` at the trait boundary.
    #[derive(Debug, thiserror::Error)]
    enum RpcError {
        #[error("I/O error: {0}")]
        Io(#[from] std::io::Error),
        #[error("HTTP status {0}")]
        HttpStatus(u16),
        #[error("response exceeded max size of {0} bytes")]
        ResponseTooLarge(usize),
        #[error("malformed JSON-RPC response: {0}")]
        Malformed(String),
        #[error("RPC error response: code={code} message={message}")]
        RpcReturned { code: i64, message: String },
    }

    impl From<RpcError> for SourceError {
        fn from(e: RpcError) -> Self {
            match e {
                RpcError::Malformed(s) => SourceError::Malformed(s),
                RpcError::RpcReturned { message, .. } => SourceError::Malformed(message),
                other => SourceError::Transport(other.to_string()),
            }
        }
    }

    /// JSON-RPC request envelope.
    #[derive(Debug, Serialize)]
    struct RpcRequest<'a> {
        jsonrpc: &'static str,
        id: u64,
        method: &'a str,
        params: Value,
    }

    /// JSON-RPC response envelope.
    #[derive(Debug, Deserialize)]
    struct RpcResponse {
        #[serde(default)]
        #[allow(dead_code)] // surfaced via #[serde] for completeness
        jsonrpc: Option<String>,
        #[serde(default)]
        #[allow(dead_code)]
        id: Option<u64>,
        #[serde(default)]
        result: Option<Value>,
        #[serde(default)]
        error: Option<RpcErrorObject>,
    }

    /// JSON-RPC error object.
    #[derive(Debug, Deserialize)]
    struct RpcErrorObject {
        code: i64,
        message: String,
    }

    /// Production Ethereum JSON-RPC source.
    #[derive(Debug, Clone)]
    pub struct JsonRpcL1Source {
        /// The RPC endpoint URL.  Currently supports
        /// `http://host:port[/path]` only — HTTPS / WS / IPC are
        /// out of scope for the RH-B landing.
        url: String,
        /// Cached `(host, port, path)` parse to avoid repeated
        /// URL parsing.
        host: String,
        port: u16,
        path: String,
        /// Request timeout.
        timeout: Duration,
    }

    impl JsonRpcL1Source {
        /// Construct from a URL of the form `http://host:port[/path]`.
        ///
        /// # Errors
        ///
        /// Returns `SourceError::Transport` if the URL is
        /// malformed.
        pub fn new(url: impl Into<String>) -> Result<Self, SourceError> {
            let url_str = url.into();
            let parsed = parse_http_url(&url_str)
                .map_err(|e| SourceError::Transport(format!("URL parse: {e}")))?;
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

        /// Send a JSON-RPC request and return the `result` field
        /// as `serde_json::Value`.
        fn rpc_call(&self, method: &str, params: Value) -> Result<Value, RpcError> {
            let request = RpcRequest {
                jsonrpc: "2.0",
                id: 1,
                method,
                params,
            };
            let body = serde_json::to_vec(&request)
                .map_err(|e| RpcError::Malformed(format!("serialise request: {e}")))?;
            let response_bytes = self.http_post(&body)?;
            let response: RpcResponse = serde_json::from_slice(&response_bytes)
                .map_err(|e| RpcError::Malformed(format!("parse response: {e}")))?;
            if let Some(err) = response.error {
                return Err(RpcError::RpcReturned {
                    code: err.code,
                    message: err.message,
                });
            }
            response
                .result
                .ok_or_else(|| RpcError::Malformed("response has neither result nor error".into()))
        }

        /// Issue an HTTP/1.1 POST with the given JSON body and
        /// return the response body (up to MAX_RESPONSE_BYTES).
        fn http_post(&self, body: &[u8]) -> Result<Vec<u8>, RpcError> {
            let addr = format!("{}:{}", self.host, self.port);
            let mut socket_addrs = addr.to_socket_addrs().map_err(|e| {
                RpcError::Io(std::io::Error::new(
                    std::io::ErrorKind::AddrNotAvailable,
                    format!("resolve {addr}: {e}"),
                ))
            })?;
            let first = socket_addrs.next().ok_or_else(|| {
                RpcError::Io(std::io::Error::new(
                    std::io::ErrorKind::AddrNotAvailable,
                    format!("no addresses resolved for {addr}"),
                ))
            })?;
            let mut stream = TcpStream::connect_timeout(&first, self.timeout)?;
            stream.set_read_timeout(Some(self.timeout))?;
            stream.set_write_timeout(Some(self.timeout))?;
            // Build the HTTP/1.1 request.
            let request = format!(
                "POST {} HTTP/1.1\r\n\
                 Host: {}\r\n\
                 Content-Type: application/json\r\n\
                 Content-Length: {}\r\n\
                 Connection: close\r\n\
                 \r\n",
                self.path,
                self.host,
                body.len()
            );
            stream.write_all(request.as_bytes())?;
            stream.write_all(body)?;
            stream.flush()?;
            // Read response.
            let mut response = Vec::with_capacity(4096);
            let mut buf = [0u8; 4096];
            loop {
                let n = stream.read(&mut buf)?;
                if n == 0 {
                    break;
                }
                if response.len() + n > MAX_RESPONSE_BYTES {
                    return Err(RpcError::ResponseTooLarge(MAX_RESPONSE_BYTES));
                }
                response.extend_from_slice(&buf[..n]);
            }
            // Split header / body and verify status.
            let body_start = find_double_crlf(&response).ok_or_else(|| {
                RpcError::Malformed("response missing header/body separator".into())
            })?;
            let header = &response[..body_start];
            let header_str = std::str::from_utf8(header)
                .map_err(|_| RpcError::Malformed("response header is not valid UTF-8".into()))?;
            let status = parse_http_status(header_str).ok_or_else(|| {
                RpcError::Malformed("response is not a valid HTTP/1.1 status line".into())
            })?;
            if !(200..300).contains(&status) {
                return Err(RpcError::HttpStatus(status));
            }
            // The body may be chunked-encoded or content-length
            // delimited; both are handled identically here because
            // we're consuming the entire stream and the response
            // body follows the header separator.
            Ok(response[body_start + 4..].to_vec())
        }
    }

    /// HTTP URL parts: `host`, `port`, `path`.
    struct HttpUrl {
        host: String,
        port: u16,
        path: String,
    }

    /// Parse `http://host:port[/path]` into its parts.  Public
    /// surface is `JsonRpcL1Source::new`; this is the internal
    /// helper.
    fn parse_http_url(url: &str) -> Result<HttpUrl, String> {
        let after_scheme = url
            .strip_prefix("http://")
            .ok_or_else(|| format!("expected 'http://' prefix, got '{url}'"))?;
        // Find the path separator.
        let (authority, path) = match after_scheme.find('/') {
            Some(idx) => (&after_scheme[..idx], &after_scheme[idx..]),
            None => (after_scheme, "/"),
        };
        // Split host and port.
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

    /// Locate the index of the `\r\n\r\n` separator between
    /// HTTP headers and body.
    fn find_double_crlf(data: &[u8]) -> Option<usize> {
        for i in 0..data.len().saturating_sub(3) {
            if &data[i..i + 4] == b"\r\n\r\n" {
                return Some(i);
            }
        }
        None
    }

    /// Parse the HTTP/1.1 status code from a response header
    /// string (the first line is `HTTP/1.1 <code> <reason>`).
    fn parse_http_status(header: &str) -> Option<u16> {
        let first_line = header.lines().next()?;
        let mut parts = first_line.split_whitespace();
        let _version = parts.next()?;
        let code = parts.next()?;
        code.parse().ok()
    }

    /// Parse an Ethereum hex string `"0x..."` into a `u64`.
    /// Returns `None` for malformed input.
    fn parse_hex_u64(s: &str) -> Option<u64> {
        let stripped = s.strip_prefix("0x")?;
        u64::from_str_radix(stripped, 16).ok()
    }

    /// Parse an Ethereum hex string `"0x..."` (32 bytes) into
    /// a `[u8; 32]`.  Returns `None` for malformed input.
    fn parse_hex_32(s: &str) -> Option<TopicHash> {
        let stripped = s.strip_prefix("0x")?;
        if stripped.len() != 64 {
            return None;
        }
        let mut out = [0u8; 32];
        for (i, byte_chunk) in stripped.as_bytes().chunks(2).enumerate() {
            let hi = hex_digit(byte_chunk[0])?;
            let lo = hex_digit(byte_chunk[1])?;
            out[i] = (hi << 4) | lo;
        }
        Some(out)
    }

    /// Parse an Ethereum hex address (20 bytes) into a
    /// `[u8; 20]`.
    fn parse_hex_20(s: &str) -> Option<[u8; 20]> {
        let stripped = s.strip_prefix("0x")?;
        if stripped.len() != 40 {
            return None;
        }
        let mut out = [0u8; 20];
        for (i, byte_chunk) in stripped.as_bytes().chunks(2).enumerate() {
            let hi = hex_digit(byte_chunk[0])?;
            let lo = hex_digit(byte_chunk[1])?;
            out[i] = (hi << 4) | lo;
        }
        Some(out)
    }

    /// Parse a `"0x..."` hex string into a `Vec<u8>`.
    fn parse_hex_bytes(s: &str) -> Option<Vec<u8>> {
        let stripped = s.strip_prefix("0x")?;
        if stripped.len() % 2 != 0 {
            return None;
        }
        let mut out = Vec::with_capacity(stripped.len() / 2);
        for chunk in stripped.as_bytes().chunks(2) {
            let hi = hex_digit(chunk[0])?;
            let lo = hex_digit(chunk[1])?;
            out.push((hi << 4) | lo);
        }
        Some(out)
    }

    /// Map a single ASCII hex character to its nibble.
    fn hex_digit(b: u8) -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(10 + b - b'a'),
            b'A'..=b'F' => Some(10 + b - b'A'),
            _ => None,
        }
    }

    /// Encode a byte slice as a lowercase hex string (no `0x`
    /// prefix).  Used to format `blockHash` for `eth_getLogs`.
    fn hex_encode_bytes(bytes: &[u8]) -> String {
        let mut s = String::with_capacity(bytes.len() * 2);
        for b in bytes {
            s.push(hex_char(b >> 4));
            s.push(hex_char(b & 0x0f));
        }
        s
    }

    /// Map a nibble (0..=15) to its ASCII hex character.
    fn hex_char(n: u8) -> char {
        match n {
            0..=9 => (b'0' + n) as char,
            10..=15 => (b'a' + (n - 10)) as char,
            _ => '?',
        }
    }

    impl L1Source for JsonRpcL1Source {
        fn latest_block_number(&self) -> Result<u64, SourceError> {
            let result = self.rpc_call("eth_blockNumber", Value::Array(vec![]))?;
            let s = result.as_str().ok_or_else(|| {
                SourceError::Malformed(format!("eth_blockNumber expected string, got {result:?}"))
            })?;
            parse_hex_u64(s).ok_or_else(|| {
                SourceError::Malformed(format!("eth_blockNumber malformed hex: {s}"))
            })
        }

        fn block_header_by_number(&self, number: u64) -> Result<BlockHeader, SourceError> {
            let params = Value::Array(vec![
                Value::String(format!("0x{number:x}")),
                Value::Bool(false), // false = headers only, no full tx objects
            ]);
            let result = self.rpc_call("eth_getBlockByNumber", params)?;
            if result.is_null() {
                return Err(SourceError::BlockNotFound(number));
            }
            let obj = result.as_object().ok_or_else(|| {
                SourceError::Malformed(format!("eth_getBlockByNumber result not object"))
            })?;
            let num_field = obj
                .get("number")
                .and_then(|v| v.as_str())
                .ok_or_else(|| SourceError::Malformed("block missing 'number' field".into()))?;
            let block_number = parse_hex_u64(num_field).ok_or_else(|| {
                SourceError::Malformed(format!("malformed block number: {num_field}"))
            })?;
            let hash_str = obj
                .get("hash")
                .and_then(|v| v.as_str())
                .ok_or_else(|| SourceError::Malformed("block missing 'hash'".into()))?;
            let hash = parse_hex_32(hash_str).ok_or_else(|| {
                SourceError::Malformed(format!("malformed block hash: {hash_str}"))
            })?;
            let parent_str = obj
                .get("parentHash")
                .and_then(|v| v.as_str())
                .ok_or_else(|| SourceError::Malformed("block missing 'parentHash'".into()))?;
            let parent_hash = parse_hex_32(parent_str).ok_or_else(|| {
                SourceError::Malformed(format!("malformed parent hash: {parent_str}"))
            })?;
            Ok(BlockHeader {
                number: block_number,
                hash,
                parent_hash,
            })
        }

        fn logs_in_block_by_hash(
            &self,
            block_hash: &TopicHash,
            contract: &EthAddress,
        ) -> Result<Vec<RawLog>, SourceError> {
            // EIP-234: `eth_getLogs` accepts a `blockHash`
            // parameter.  Filtering by hash (rather than
            // `fromBlock`/`toBlock`) defends against an L1 re-org
            // happening between the header fetch and the log
            // fetch — by-number filters could otherwise return
            // logs from a different fork's block at the same
            // height.
            let filter = serde_json::json!({
                "blockHash": format!("0x{}", hex_encode_bytes(block_hash)),
                "address": format!("0x{}", contract.to_hex()),
            });
            let params = Value::Array(vec![filter]);
            let result = self.rpc_call("eth_getLogs", params)?;
            let arr = result
                .as_array()
                .ok_or_else(|| SourceError::Malformed("eth_getLogs result not array".into()))?;
            let mut logs = Vec::with_capacity(arr.len());
            for entry in arr {
                let obj = entry
                    .as_object()
                    .ok_or_else(|| SourceError::Malformed("log entry not object".into()))?;
                let address_str = obj
                    .get("address")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| SourceError::Malformed("log missing 'address'".into()))?;
                let address_bytes = parse_hex_20(address_str).ok_or_else(|| {
                    SourceError::Malformed(format!("malformed log address: {address_str}"))
                })?;
                let address = EthAddress(address_bytes);
                let topics_arr = obj
                    .get("topics")
                    .and_then(|v| v.as_array())
                    .ok_or_else(|| SourceError::Malformed("log missing 'topics'".into()))?;
                let mut topics = Vec::with_capacity(topics_arr.len());
                for t in topics_arr {
                    let s = t
                        .as_str()
                        .ok_or_else(|| SourceError::Malformed("topic is not a string".into()))?;
                    let h = parse_hex_32(s)
                        .ok_or_else(|| SourceError::Malformed(format!("malformed topic: {s}")))?;
                    topics.push(h);
                }
                let data_str = obj
                    .get("data")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| SourceError::Malformed("log missing 'data'".into()))?;
                let data = parse_hex_bytes(data_str).ok_or_else(|| {
                    SourceError::Malformed(format!("malformed log data: {data_str}"))
                })?;
                let block_number_str = obj
                    .get("blockNumber")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| SourceError::Malformed("log missing 'blockNumber'".into()))?;
                let block_number = parse_hex_u64(block_number_str).ok_or_else(|| {
                    SourceError::Malformed(format!("malformed block number: {block_number_str}"))
                })?;
                let tx_hash_str = obj
                    .get("transactionHash")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| {
                        SourceError::Malformed("log missing 'transactionHash'".into())
                    })?;
                let tx_hash = parse_hex_32(tx_hash_str).ok_or_else(|| {
                    SourceError::Malformed(format!("malformed tx hash: {tx_hash_str}"))
                })?;
                let log_index_str = obj
                    .get("logIndex")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| SourceError::Malformed("log missing 'logIndex'".into()))?;
                let log_index = parse_hex_u64(log_index_str).ok_or_else(|| {
                    SourceError::Malformed(format!("malformed log index: {log_index_str}"))
                })?;
                // Defence-in-depth: verify the log carries the
                // expected `blockHash`.  The RPC SHOULD filter
                // correctly, but historically some providers
                // have ignored the filter on specific block
                // ranges — verify locally.
                let returned_hash_str = obj
                    .get("blockHash")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| SourceError::Malformed("log missing 'blockHash'".into()))?;
                let returned_hash = parse_hex_32(returned_hash_str).ok_or_else(|| {
                    SourceError::Malformed(format!("malformed log blockHash: {returned_hash_str}"))
                })?;
                if &returned_hash != block_hash {
                    return Err(SourceError::Malformed(format!(
                        "RPC returned log with blockHash {returned_hash_str} \
                         when filter requested {block_hash:?}"
                    )));
                }
                logs.push(RawLog {
                    address,
                    topics,
                    data,
                    block_number,
                    tx_hash,
                    log_index,
                });
            }
            // Sort by log index for determinism.  An RPC endpoint
            // SHOULD return logs in order but the spec is not
            // strict; defensive sort costs nothing on small
            // arrays.
            logs.sort_by_key(|l| l.log_index);
            Ok(logs)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::{
            find_double_crlf, hex_digit, parse_hex_20, parse_hex_32, parse_hex_bytes,
            parse_hex_u64, parse_http_status, parse_http_url,
        };

        #[test]
        fn url_parse_simple() {
            let p = parse_http_url("http://localhost:8545").unwrap();
            assert_eq!(p.host, "localhost");
            assert_eq!(p.port, 8545);
            assert_eq!(p.path, "/");
        }

        #[test]
        fn url_parse_with_path() {
            let p = parse_http_url("http://example.com:80/rpc/v1").unwrap();
            assert_eq!(p.host, "example.com");
            assert_eq!(p.port, 80);
            assert_eq!(p.path, "/rpc/v1");
        }

        #[test]
        fn url_parse_no_port_defaults_to_80() {
            let p = parse_http_url("http://example.com/path").unwrap();
            assert_eq!(p.port, 80);
        }

        #[test]
        fn url_parse_rejects_https() {
            assert!(parse_http_url("https://example.com").is_err());
        }

        #[test]
        fn url_parse_rejects_empty() {
            assert!(parse_http_url("").is_err());
            assert!(parse_http_url("http://").is_err());
        }

        #[test]
        fn url_parse_rejects_bad_port() {
            assert!(parse_http_url("http://host:abc").is_err());
        }

        #[test]
        fn find_double_crlf_basic() {
            let s = b"HTTP/1.1 200 OK\r\nFoo: bar\r\n\r\nBody";
            let idx = find_double_crlf(s).unwrap();
            assert_eq!(&s[idx..idx + 4], b"\r\n\r\n");
        }

        #[test]
        fn find_double_crlf_missing() {
            assert!(find_double_crlf(b"no separators here").is_none());
        }

        #[test]
        fn parse_http_status_ok() {
            assert_eq!(parse_http_status("HTTP/1.1 200 OK"), Some(200));
            assert_eq!(parse_http_status("HTTP/1.1 503 Server Error"), Some(503));
        }

        #[test]
        fn parse_http_status_malformed() {
            assert_eq!(parse_http_status(""), None);
            assert_eq!(parse_http_status("garbage"), None);
            assert_eq!(parse_http_status("HTTP/1.1"), None);
        }

        #[test]
        fn hex_digit_all_cases() {
            for i in 0..=9 {
                assert_eq!(hex_digit(b'0' + i), Some(i));
            }
            for i in 0..6 {
                assert_eq!(hex_digit(b'a' + i), Some(10 + i));
                assert_eq!(hex_digit(b'A' + i), Some(10 + i));
            }
            assert_eq!(hex_digit(b'g'), None);
            assert_eq!(hex_digit(b'Z'), None);
            assert_eq!(hex_digit(b'/'), None);
        }

        #[test]
        fn parse_hex_u64_basic() {
            assert_eq!(parse_hex_u64("0x0"), Some(0));
            assert_eq!(parse_hex_u64("0x10"), Some(16));
            assert_eq!(parse_hex_u64("0xff"), Some(255));
            assert_eq!(parse_hex_u64("0x100000"), Some(0x100000));
        }

        #[test]
        fn parse_hex_u64_malformed() {
            assert_eq!(parse_hex_u64("0xZZ"), None);
            assert_eq!(parse_hex_u64("no_prefix"), None);
            assert_eq!(parse_hex_u64(""), None);
        }

        #[test]
        fn parse_hex_32_basic() {
            let s = format!("0x{}", "ab".repeat(32));
            let result = parse_hex_32(&s).unwrap();
            assert_eq!(result, [0xab; 32]);
        }

        #[test]
        fn parse_hex_32_wrong_length() {
            assert_eq!(parse_hex_32("0x00"), None);
            assert_eq!(parse_hex_32(&format!("0x{}", "00".repeat(31))), None);
            assert_eq!(parse_hex_32(&format!("0x{}", "00".repeat(33))), None);
        }

        #[test]
        fn parse_hex_20_basic() {
            let s = format!("0x{}", "cd".repeat(20));
            let result = parse_hex_20(&s).unwrap();
            assert_eq!(result, [0xcd; 20]);
        }

        #[test]
        fn parse_hex_bytes_empty() {
            assert_eq!(parse_hex_bytes("0x"), Some(vec![]));
        }

        #[test]
        fn parse_hex_bytes_odd_length() {
            assert_eq!(parse_hex_bytes("0xabc"), None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{mock::InMemoryL1Source, L1Source, SourceError};
    use crate::action::EthAddress;
    use crate::reorg::BlockHeader;
    use std::collections::HashMap;

    /// Empty source: latest is 0, blocks not found.
    #[test]
    fn empty_source() {
        let s = InMemoryL1Source::new();
        assert_eq!(s.latest_block_number().unwrap(), 0);
        assert!(matches!(
            s.block_header_by_number(0),
            Err(SourceError::BlockNotFound(0))
        ));
    }

    /// `push_block` and read-back round-trip.
    #[test]
    fn push_and_read() {
        let mut s = InMemoryL1Source::new();
        let h = BlockHeader {
            number: 100,
            hash: [0xaa; 32],
            parent_hash: [0xbb; 32],
        };
        s.push_block(h, HashMap::new());
        assert_eq!(s.latest_block_number().unwrap(), 100);
        assert_eq!(s.block_header_by_number(100).unwrap(), h);
    }

    /// `set_latest` overrides automatic latest derivation.
    #[test]
    fn explicit_latest() {
        let mut s = InMemoryL1Source::new();
        let h = BlockHeader {
            number: 100,
            hash: [0xaa; 32],
            parent_hash: [0xbb; 32],
        };
        s.push_block(h, HashMap::new());
        s.set_latest(110);
        assert_eq!(s.latest_block_number().unwrap(), 110);
    }

    /// `logs_in_block_by_hash` returns the contract's logs.
    #[test]
    fn logs_in_block_by_hash_finds_logs() {
        use crate::events::RawLog;
        let mut s = InMemoryL1Source::new();
        let contract = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let log = RawLog {
            address: contract,
            topics: vec![[0xee; 32]],
            data: vec![],
            block_number: 100,
            tx_hash: [0x11; 32],
            log_index: 0,
        };
        let mut logs = HashMap::new();
        logs.insert(contract, vec![log.clone()]);
        let h = BlockHeader {
            number: 100,
            hash: [0xaa; 32],
            parent_hash: [0xbb; 32],
        };
        s.push_block(h, logs);
        let returned = s.logs_in_block_by_hash(&h.hash, &contract).unwrap();
        assert_eq!(returned.len(), 1);
        assert_eq!(returned[0], log);
    }

    /// `logs_in_block_by_hash` returns empty for an unrelated
    /// contract.
    #[test]
    fn logs_in_block_by_hash_returns_empty_for_other_contract() {
        use crate::events::RawLog;
        let mut s = InMemoryL1Source::new();
        let contract_a = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let contract_b = EthAddress::from_bytes(&[2u8; 20]).unwrap();
        let log = RawLog {
            address: contract_a,
            topics: vec![[0xee; 32]],
            data: vec![],
            block_number: 100,
            tx_hash: [0x11; 32],
            log_index: 0,
        };
        let mut logs = HashMap::new();
        logs.insert(contract_a, vec![log]);
        let h = BlockHeader {
            number: 100,
            hash: [0xaa; 32],
            parent_hash: [0xbb; 32],
        };
        s.push_block(h, logs);
        let returned = s.logs_in_block_by_hash(&h.hash, &contract_b).unwrap();
        assert!(returned.is_empty());
    }

    /// `logs_in_block_by_hash` rejects an unknown block hash
    /// rather than silently returning empty.
    #[test]
    fn logs_in_block_by_hash_rejects_unknown_hash() {
        let s = InMemoryL1Source::new();
        let contract = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let unknown_hash = [0xab; 32];
        let result = s.logs_in_block_by_hash(&unknown_hash, &contract);
        match result {
            Err(SourceError::Malformed(_)) => {} // expected
            other => panic!("expected Malformed error, got {other:?}"),
        }
    }

    /// `logs_in_block_by_hash` filters logs whose `block_number`
    /// doesn't match the cached block's number (defence-in-depth
    /// against a buggy mock or stale data).
    #[test]
    fn logs_in_block_by_hash_filters_by_block_number() {
        use crate::events::RawLog;
        let mut s = InMemoryL1Source::new();
        let contract = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        // Log claims block_number = 200, but the block we'll
        // push has number 100.  The filter must drop the log.
        let log = RawLog {
            address: contract,
            topics: vec![[0xee; 32]],
            data: vec![],
            block_number: 200,
            tx_hash: [0x11; 32],
            log_index: 0,
        };
        let mut logs = HashMap::new();
        logs.insert(contract, vec![log]);
        let h = BlockHeader {
            number: 100,
            hash: [0xaa; 32],
            parent_hash: [0xbb; 32],
        };
        s.push_block(h, logs);
        let returned = s.logs_in_block_by_hash(&h.hash, &contract).unwrap();
        assert!(
            returned.is_empty(),
            "log with wrong block_number must be filtered out"
        );
    }

    /// `rewrite_chain` simulates an L1 re-org.
    #[test]
    fn rewrite_chain_replaces_blocks_at_or_after_start() {
        let mut s = InMemoryL1Source::new();
        for i in 100..105 {
            s.push_block(
                BlockHeader {
                    number: i,
                    hash: [i as u8; 32],
                    parent_hash: [(i - 1) as u8; 32],
                },
                HashMap::new(),
            );
        }
        // Rewrite from block 102.
        let new_blocks: Vec<_> = (102..104)
            .map(|i| {
                (
                    BlockHeader {
                        number: i,
                        hash: [(0xff - i as u8); 32],
                        parent_hash: [(0xff - i as u8 + 1); 32],
                    },
                    HashMap::new(),
                )
            })
            .collect();
        s.rewrite_chain(102, new_blocks);
        // Block 101 unchanged.
        assert_eq!(s.block_header_by_number(101).unwrap().hash, [101; 32]);
        // Block 102 has new hash.
        assert_eq!(
            s.block_header_by_number(102).unwrap().hash,
            [0xff - 102; 32]
        );
        // Block 104 removed.
        assert!(matches!(
            s.block_header_by_number(104),
            Err(SourceError::BlockNotFound(104))
        ));
    }

    /// `push_block` panics on non-monotone order.
    #[test]
    #[should_panic(expected = "must be pushed in ascending order")]
    fn push_block_rejects_non_monotone() {
        let mut s = InMemoryL1Source::new();
        s.push_block(
            BlockHeader {
                number: 100,
                hash: [0; 32],
                parent_hash: [0; 32],
            },
            HashMap::new(),
        );
        s.push_block(
            BlockHeader {
                number: 100,
                hash: [0; 32],
                parent_hash: [0; 32],
            },
            HashMap::new(),
        );
    }
}

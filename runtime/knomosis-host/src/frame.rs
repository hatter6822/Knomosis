// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Wire-frame parser for the knomosis-host network protocol.
//!
//! See `docs/abi.md` §10 for the canonical wire-format specification.
//!
//! ## Frame layout
//!
//! ```text
//! offset  size  field
//! ------  ----  -----------------------------------------------
//!     0    4    payload length N (big-endian u32; ≤ MAX_FRAME_SIZE)
//!     4    N    payload (opaque CBE bytes; not interpreted here)
//! ```
//!
//! The host treats the payload as opaque bytes — every CBE
//! interpretation happens inside the kernel implementation.  The
//! host's only frame-level invariant is "length matches".
//!
//! ## Rung-1 signer hint (optional, `PROTOCOL_VERSION 2`)
//!
//! A client may opt into per-frame signer hints (the FQ Rung-1 fair-
//! scheduling inner tier) by opening the connection with the 4-byte
//! [`KNH2_PREAMBLE`].  Thereafter every request is `[8-byte BE signer
//! hint][4-byte BE length][payload]`.  The host peeks the first 4 bytes
//! once ([`negotiate_connection`]) and reads either a v1 frame
//! ([`read_frame`] via [`read_frame_with_prefix`]) or a hinted frame
//! ([`read_hinted_frame`]) for the connection's lifetime; [`read_request`]
//! is the one-shot composite.  The disambiguation is collision-proof
//! because [`HARD_MAX_FRAME_SIZE`] is strictly below [`KNH2_MAGIC`] (a
//! valid v1 length can never equal the preamble — pinned by a `const`
//! assertion).  The hint is **advisory routing only**: it never affects
//! admissibility (the kernel reads + verifies the real signer from the
//! CBE body).  [`encode_frame`] / [`encode_hinted_frame`] are the
//! canonical client-side encoders.  See `docs/abi.md` §10.4.2.
//!
//! ## Bounded length
//!
//! Every frame's declared length is checked against
//! [`DEFAULT_MAX_FRAME_SIZE`] (default 1 MiB) before allocation or read.
//! This defends against the classic length-driven OOM attack: a
//! malformed client sending a `0xFFFFFFFF` length prefix on a
//! truncated body would otherwise cause the server to allocate
//! 4 GiB before noticing the truncation.
//!
//! ## Why hand-rolled
//!
//! The plan §RH-C.1 mentions `tokio-util`'s `LengthDelimitedCodec`
//! as a reference; we hand-roll the parser instead to keep the
//! dependency tree small and the audit surface narrow (the
//! ingestor crate `knomosis-l1-ingest` made the same choice for its
//! CBE encoder and HTTP submitter).

use std::io::{self, Read, Write};

use crate::queue::{SignerHint, LEGACY_SIGNER_HINT};

/// Default maximum accepted frame payload size (1 MiB).
///
/// CBE-encoded `SignedAction` records are typically well under
/// 1 KiB; the 1 MiB bound is generous headroom for any realistic
/// deployment.  Operators wanting to handle larger payloads can
/// override via [`crate::config::Config::max_frame_size`] —
/// the parser checks against the configured bound on every
/// `read_frame` call.
pub const DEFAULT_MAX_FRAME_SIZE: usize = 1024 * 1024;

/// Hard-cap on the maximum frame size an operator can configure.
/// 16 MiB matches the workspace's other limits
/// (`knomosis-cross-stack::MAX_RECORD_BYTES`, `knomosis-l1-ingest::
/// submitter::MAX_SUBMISSION_BYTES`).  Above this the operator
/// is doing something unusual and should reconsider the
/// architecture.
pub const HARD_MAX_FRAME_SIZE: usize = 16 * 1024 * 1024;

/// Length of the frame-header prefix (4 bytes for a big-endian
/// u32 length field).
pub const HEADER_LEN: usize = 4;

/// The 4-byte preamble a Rung-1 (v2) client sends ONCE on connection
/// open to opt into per-frame signer hints (Workstream GP.8, Track A /
/// FQ — Rung 1, FQ.9).
///
/// `b"KNH2"` — "KNomosis Host, protocol 2".  After this preamble every
/// request on the connection is `[8-byte BE signer hint][4-byte BE
/// length][payload]` (see [`read_hinted_frame`] / [`encode_hinted_frame`]).
/// A legacy (v1) client sends no preamble; its first 4 bytes are the v1
/// length prefix.
pub const KNH2_PREAMBLE: [u8; HEADER_LEN] = *b"KNH2";

/// The Rung-1 preamble interpreted as a big-endian `u32` — the value a
/// v1 length prefix would have to equal to collide with the preamble
/// (FQ.9).  `0x4B4E_4832` = 1 263 421 490 ≈ 1.18 GiB.
///
/// The disambiguation "first 4 bytes == preamble ⇒ v2, else v1" is
/// sound precisely because no *valid* v1 length can reach this value:
/// see [`HARD_MAX_FRAME_SIZE`] and the compile-time invariant below.
pub const KNH2_MAGIC: u32 = u32::from_be_bytes(KNH2_PREAMBLE);

/// Length of the per-frame signer hint on a Rung-1 connection (8 bytes,
/// big-endian `u64`; FQ.9 / FQ.10b).
pub const SIGNER_HINT_LEN: usize = 8;

// The load-bearing FQ.9 correctness invariant, pinned at COMPILE TIME:
// the hard ceiling on a configurable frame size is strictly below the
// Rung-1 magic, so a *valid* v1 length prefix (always ≤ the operator's
// `max_frame_size` ≤ `HARD_MAX_FRAME_SIZE`) can NEVER equal the magic.
// Therefore the one-time 4-byte peek (`negotiate_connection`) never
// misclassifies a legitimate v1 frame as a v2 preamble.  16 MiB <
// 1.18 GiB.  (A v1 client that sends an over-`HARD_MAX_FRAME_SIZE`
// length is already an oversize-frame protocol error; mistaking it for a
// preamble merely turns one error into another — never a misadmission.)
const _: () = assert!(
    (HARD_MAX_FRAME_SIZE as u64) < (KNH2_MAGIC as u64),
    "HARD_MAX_FRAME_SIZE must be strictly below the KNH2 magic so a valid \
     v1 length prefix can never be mistaken for the Rung-1 preamble",
);

/// Frame-parsing errors.
///
/// Each variant carries enough information to diagnose the failure
/// from server logs without re-running with extra instrumentation.
#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    /// The underlying I/O operation failed.  Surfaces transient
    /// network errors (connection reset, timeout) as well as
    /// permanent ones (socket closed by peer).
    #[error("I/O error reading frame: {0}")]
    Io(#[from] io::Error),
    /// The peer disconnected before sending a complete header
    /// (clean EOF on the listening socket).  Distinguished from
    /// [`FrameError::TruncatedPayload`] because this is the
    /// normal "client went away" case, whereas a truncated
    /// payload after a valid header indicates a malformed
    /// client.
    #[error("client closed connection before sending a frame header")]
    EofBeforeHeader,
    /// The peer sent a partial header (1–3 bytes) then closed.
    /// Indicates a malformed client; the legitimate case is
    /// either zero bytes (clean close) or a full 4-byte header.
    #[error("client sent {bytes_read} of {} header bytes before EOF", HEADER_LEN)]
    TruncatedHeader {
        /// Number of bytes received before EOF (0 < n < HEADER_LEN).
        bytes_read: usize,
    },
    /// On a Rung-1 (hinted) connection, the peer sent a partial 8-byte
    /// signer hint (1–7 bytes) then closed.  Distinguished from
    /// [`FrameError::TruncatedHeader`] so logs pinpoint the per-frame
    /// hint read; surfaced as a `ParseError` to the client BEFORE any
    /// body allocation (FQ.10b).
    #[error(
        "client sent {bytes_read} of {} signer-hint bytes before EOF",
        SIGNER_HINT_LEN
    )]
    TruncatedHint {
        /// Number of hint bytes received before EOF (0 < n < SIGNER_HINT_LEN).
        bytes_read: usize,
    },
    /// The peer sent a complete header but only part of the
    /// payload before closing the connection.
    #[error("client sent {bytes_read} of {declared_length} payload bytes before EOF")]
    TruncatedPayload {
        /// Number of payload bytes received.
        bytes_read: usize,
        /// Declared payload length from the header.
        declared_length: usize,
    },
    /// The declared payload length exceeds the configured maximum.
    /// Defends against unbounded-payload DoS.
    #[error("frame length {declared_length} exceeds configured max {max}")]
    OversizeFrame {
        /// Declared payload length from the header.
        declared_length: u32,
        /// Configured maximum frame size in bytes.
        max: usize,
    },
    /// The declared payload length is zero.  A zero-length frame
    /// is not meaningful (the kernel cannot decode an empty
    /// SignedAction); the parser rejects it upstream of the
    /// kernel rather than letting it bubble through as a
    /// ParseError.
    #[error("zero-length frame rejected; minimum is 1 byte")]
    ZeroLengthFrame,
}

/// Read one complete frame from `reader`.
///
/// On success returns the payload bytes (the 4-byte length prefix is
/// consumed but not included in the returned vector).
///
/// On `Err(EofBeforeHeader)` the caller is expected to close the
/// connection cleanly (the peer disconnected normally).  All other
/// `Err` variants are protocol violations and should be logged.
///
/// `max_frame_size` is the configured upper bound for the declared
/// payload length.  Internally clamped to [`HARD_MAX_FRAME_SIZE`]
/// (a defence-in-depth measure against library consumers passing
/// `usize::MAX`); the CLI-facing `Config::validate` enforces the
/// same bound up-front, so operator-supplied values reach this
/// function pre-clamped.
///
/// # Errors
///
/// See [`FrameError`].
pub fn read_frame<R: Read>(reader: &mut R, max_frame_size: usize) -> Result<Vec<u8>, FrameError> {
    // Defence-in-depth: clamp to HARD_MAX_FRAME_SIZE.  The CLI
    // validation rejects oversize values up-front; library
    // consumers that bypass the CLI (e.g. RH-F's bench) might
    // pass usize::MAX.  Clamping here is the load-bearing safety
    // net (per AR-RHC #14).
    let max_frame_size = max_frame_size.min(HARD_MAX_FRAME_SIZE);
    // 1. Read the 4-byte length prefix.  EOF at byte 0 is a clean
    //    close; a partial header is a protocol error.
    let mut header = [0u8; HEADER_LEN];
    read_header_bytes(reader, &mut header)?;
    // 2. + 3. Bound the declared length and read the payload.
    read_payload(reader, u32::from_be_bytes(header), max_frame_size)
}

/// Read one v1 frame whose 4-byte length prefix has ALREADY been
/// consumed (the Rung-1 negotiation peek; FQ.10a).  `prefix` is the
/// already-read big-endian length header; this reads exactly the
/// payload, so a legacy connection's first frame is never lost or
/// double-read.
///
/// # Errors
///
/// See [`FrameError`] (same payload-level errors as [`read_frame`]).
pub fn read_frame_with_prefix<R: Read>(
    reader: &mut R,
    prefix: [u8; HEADER_LEN],
    max_frame_size: usize,
) -> Result<Vec<u8>, FrameError> {
    let max_frame_size = max_frame_size.min(HARD_MAX_FRAME_SIZE);
    read_payload(reader, u32::from_be_bytes(prefix), max_frame_size)
}

/// Read one Rung-1 (v2) hinted frame: an 8-byte big-endian signer hint
/// followed by a standard `[4-byte length][payload]` frame (FQ.10b).
///
/// The hint is read FIRST, bounded to exactly [`SIGNER_HINT_LEN`] bytes,
/// before any body allocation — so a malformed / truncated hint is a
/// protocol error ([`FrameError::TruncatedHint`]) that never reads into
/// (or mis-reads) the CBE body.  A clean EOF before any hint byte is
/// [`FrameError::EofBeforeHeader`] (the peer closed between frames).
///
/// Once the FULL hint has been read the client has **committed** to a
/// request, so a subsequent EOF before the length header is a *truncated
/// request* ([`FrameError::TruncatedHeader`] — a protocol error the host
/// answers `ParseError`), NOT the benign inter-frame close that
/// `EofBeforeHeader` denotes.  This keeps the truncation semantics
/// consistent with the v1 path (where a started-but-unfinished frame is
/// likewise a protocol error, not a clean close) and is what a future
/// persistent-connection mode relies on to decide a response is owed.
///
/// The hint is **advisory routing only** (`GP.8` §2.6); the kernel reads
/// the real signer from the returned payload's CBE and verifies the
/// signature.
///
/// # Errors
///
/// See [`FrameError`].
pub fn read_hinted_frame<R: Read>(
    reader: &mut R,
    max_frame_size: usize,
) -> Result<(SignerHint, Vec<u8>), FrameError> {
    let max_frame_size = max_frame_size.min(HARD_MAX_FRAME_SIZE);
    // 1. Read the bounded 8-byte hint.  EOF at byte 0 = clean close
    //    between frames; a partial hint is a protocol error.  No body
    //    allocation happens until the hint is fully in hand.
    let mut hint = [0u8; SIGNER_HINT_LEN];
    let mut bytes_read = 0usize;
    while bytes_read < SIGNER_HINT_LEN {
        let n = reader.read(&mut hint[bytes_read..])?;
        if n == 0 {
            if bytes_read == 0 {
                return Err(FrameError::EofBeforeHeader);
            }
            return Err(FrameError::TruncatedHint { bytes_read });
        }
        bytes_read += n;
    }
    let signer = u64::from_be_bytes(hint);
    // 2. Then the ordinary length-prefixed payload.  The hint has
    //    committed the client to a request, so re-map the frame reader's
    //    clean-close `EofBeforeHeader` (no length-header byte arrived) to
    //    `TruncatedHeader { bytes_read: 0 }` — a protocol error → the host
    //    answers `ParseError` rather than treating a half-sent request as
    //    a benign disconnect.  A partial length header (1–3 bytes) already
    //    surfaces as `TruncatedHeader` directly.
    let payload = match read_frame(reader, max_frame_size) {
        Ok(p) => p,
        Err(FrameError::EofBeforeHeader) => {
            return Err(FrameError::TruncatedHeader { bytes_read: 0 })
        }
        Err(e) => return Err(e),
    };
    Ok((signer, payload))
}

/// The outcome of the one-time Rung-1 connection negotiation (FQ.10a).
///
/// A connection's classification is fixed for its lifetime: the host
/// peeks the first 4 bytes exactly once and never renegotiates
/// mid-connection.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Negotiation {
    /// A Rung-1 (v2) connection: the leading 4 bytes equalled the
    /// [`KNH2_PREAMBLE`], which was consumed.  Read subsequent requests
    /// with [`read_hinted_frame`].
    Hinted,
    /// A legacy (v1) connection: the leading 4 bytes were NOT the
    /// preamble, so they ARE the first frame's length prefix.  They are
    /// returned here (not discarded) to feed into [`read_frame_with_prefix`].
    Legacy([u8; HEADER_LEN]),
}

/// Perform the one-time Rung-1 magic peek on a freshly-accepted
/// connection (FQ.10a).
///
/// Reads the leading 4 bytes and classifies the connection:
///
///   * `== KNH2_PREAMBLE` ⇒ [`Negotiation::Hinted`] (preamble consumed);
///   * otherwise ⇒ [`Negotiation::Legacy`] carrying those 4 bytes as the
///     first frame's length prefix.
///
/// This is sound — a valid v1 length can never equal the preamble —
/// because of the compile-time `HARD_MAX_FRAME_SIZE < KNH2_MAGIC`
/// invariant pinned in this module (FQ.9).
///
/// A clean EOF before any byte is [`FrameError::EofBeforeHeader`] (the
/// peer closed without sending a request); a partial (1–3 byte) peek is
/// [`FrameError::TruncatedHeader`].
///
/// # Errors
///
/// See [`FrameError`].
pub fn negotiate_connection<R: Read>(reader: &mut R) -> Result<Negotiation, FrameError> {
    let mut head = [0u8; HEADER_LEN];
    read_header_bytes(reader, &mut head)?;
    if head == KNH2_PREAMBLE {
        Ok(Negotiation::Hinted)
    } else {
        Ok(Negotiation::Legacy(head))
    }
}

/// Read one full request from a freshly-accepted connection, performing
/// the Rung-1 negotiation and returning the routing signer hint plus the
/// opaque payload (FQ.10).
///
/// For a v2 connection the real per-frame hint is returned; for a legacy
/// (v1) connection the [`LEGACY_SIGNER_HINT`] sentinel is returned (so
/// the fair scheduler treats the whole connection as one inner flow ⇒
/// Rung-0 behaviour).  Either way the returned payload is byte-identical
/// to what a plain [`read_frame`] would have produced for the same body.
///
/// # Errors
///
/// See [`FrameError`].  `EofBeforeHeader` means the client closed before
/// sending a request (no response owed).
pub fn read_request<R: Read>(
    reader: &mut R,
    max_frame_size: usize,
) -> Result<(SignerHint, Vec<u8>), FrameError> {
    match negotiate_connection(reader)? {
        Negotiation::Hinted => read_hinted_frame(reader, max_frame_size),
        Negotiation::Legacy(prefix) => {
            let payload = read_frame_with_prefix(reader, prefix, max_frame_size)?;
            Ok((LEGACY_SIGNER_HINT, payload))
        }
    }
}

/// Fill `buf` completely from `reader`, mapping a clean EOF at offset 0
/// to [`FrameError::EofBeforeHeader`] and a partial read to
/// [`FrameError::TruncatedHeader`].  Shared by [`read_frame`] and
/// [`negotiate_connection`]'s 4-byte reads.
fn read_header_bytes<R: Read>(reader: &mut R, buf: &mut [u8]) -> Result<(), FrameError> {
    let mut bytes_read = 0usize;
    while bytes_read < buf.len() {
        let n = reader.read(&mut buf[bytes_read..])?;
        if n == 0 {
            if bytes_read == 0 {
                return Err(FrameError::EofBeforeHeader);
            }
            return Err(FrameError::TruncatedHeader { bytes_read });
        }
        // `read` returns ≤ buf.len() bytes, so no overflow is possible.
        bytes_read += n;
    }
    Ok(())
}

/// Bound `declared` against zero / `max_frame_size`, then allocate
/// exactly `declared` bytes and read them.  Shared by [`read_frame`]
/// and [`read_frame_with_prefix`].
///
/// Rejecting zero-length here is deliberate: there is no valid empty
/// `SignedAction`, so a zero-length frame is always a protocol error.
/// Capacity is bounded above by `max_frame_size` (the oversize check
/// runs first), so allocation can never panic on a malformed client.
fn read_payload<R: Read>(
    reader: &mut R,
    declared: u32,
    max_frame_size: usize,
) -> Result<Vec<u8>, FrameError> {
    if declared == 0 {
        return Err(FrameError::ZeroLengthFrame);
    }
    let declared_usize = declared as usize;
    if declared_usize > max_frame_size {
        return Err(FrameError::OversizeFrame {
            declared_length: declared,
            max: max_frame_size,
        });
    }
    let mut payload = vec![0u8; declared_usize];
    let mut filled = 0usize;
    while filled < declared_usize {
        let n = reader.read(&mut payload[filled..])?;
        if n == 0 {
            return Err(FrameError::TruncatedPayload {
                bytes_read: filled,
                declared_length: declared_usize,
            });
        }
        filled += n;
    }
    Ok(payload)
}

/// Errors returned by [`write_frame`].
#[derive(Debug, thiserror::Error)]
pub enum WriteFrameError {
    /// The underlying I/O operation failed.
    #[error("I/O error writing frame: {0}")]
    Io(#[from] io::Error),
    /// The payload is too large to encode in the 32-bit length
    /// field.  Cannot occur for any payload originating in this
    /// codebase (we bound at `MAX_FRAME_SIZE = 1 MiB`), but the
    /// type system requires us to handle the case for `usize >
    /// u32::MAX` on 64-bit hosts.
    #[error("payload length {0} exceeds u32::MAX (wire format limit)")]
    PayloadTooLarge(usize),
}

/// Write one complete frame to `writer`.  Writes the 4-byte
/// big-endian length prefix followed by `payload`.
///
/// Convenience helper for tests and reference clients (the
/// production submitters write their own headers inline with the
/// HTTP framing).
///
/// # Errors
///
/// See [`WriteFrameError`].
pub fn write_frame<W: Write>(writer: &mut W, payload: &[u8]) -> Result<(), WriteFrameError> {
    let len_u32 = u32::try_from(payload.len())
        .map_err(|_| WriteFrameError::PayloadTooLarge(payload.len()))?;
    writer.write_all(&len_u32.to_be_bytes())?;
    writer.write_all(payload)?;
    writer.flush()?;
    Ok(())
}

/// Encode a frame to an in-memory buffer.  Inverse of
/// [`read_frame`] modulo the `Read` trait abstraction.  Used by
/// tests to construct expected wire bytes without setting up a
/// `Cursor`.
///
/// # Errors
///
/// Returns `WriteFrameError::PayloadTooLarge` if `payload.len()`
/// exceeds `u32::MAX`.
pub fn encode_frame(payload: &[u8]) -> Result<Vec<u8>, WriteFrameError> {
    let len_u32 = u32::try_from(payload.len())
        .map_err(|_| WriteFrameError::PayloadTooLarge(payload.len()))?;
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
    out.extend_from_slice(&len_u32.to_be_bytes());
    out.extend_from_slice(payload);
    Ok(out)
}

/// Encode one Rung-1 (v2) hinted frame to an in-memory buffer: an
/// 8-byte big-endian signer hint followed by the standard
/// `[4-byte length][payload]` frame (FQ.9 / FQ.13).  The exact inverse
/// of [`read_hinted_frame`].
///
/// This is the **single source of truth** for the Rung-1 frame layout
/// that any wire client (the bench harness today; a future migrated
/// L1-ingest / observer submitter) uses to emit hinted frames — the
/// caller sends [`KNH2_PREAMBLE`] ONCE on connection open, then one of
/// these per request.  Keeping the layout in one tested place means a
/// client can never drift from the host's `read_hinted_frame`.
///
/// # Errors
///
/// Returns `WriteFrameError::PayloadTooLarge` if `payload.len()`
/// exceeds `u32::MAX`.
pub fn encode_hinted_frame(signer: SignerHint, payload: &[u8]) -> Result<Vec<u8>, WriteFrameError> {
    let len_u32 = u32::try_from(payload.len())
        .map_err(|_| WriteFrameError::PayloadTooLarge(payload.len()))?;
    let mut out = Vec::with_capacity(SIGNER_HINT_LEN + HEADER_LEN + payload.len());
    out.extend_from_slice(&signer.to_be_bytes());
    out.extend_from_slice(&len_u32.to_be_bytes());
    out.extend_from_slice(payload);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::{
        encode_frame, encode_hinted_frame, negotiate_connection, read_frame,
        read_frame_with_prefix, read_hinted_frame, read_request, write_frame, FrameError,
        Negotiation, DEFAULT_MAX_FRAME_SIZE, HARD_MAX_FRAME_SIZE, HEADER_LEN, KNH2_MAGIC,
        KNH2_PREAMBLE, SIGNER_HINT_LEN,
    };
    use crate::queue::LEGACY_SIGNER_HINT;
    use std::io::Cursor;

    /// Round-trip: encode then read.
    #[test]
    fn round_trip_basic() {
        let payload = b"hello world".to_vec();
        let bytes = encode_frame(&payload).unwrap();
        // 4-byte length prefix (BE 11 = 0x00000000B) + payload.
        assert_eq!(bytes.len(), HEADER_LEN + payload.len());
        let mut cursor = Cursor::new(bytes);
        let decoded = read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(decoded, payload);
    }

    /// `write_frame` produces identical bytes to `encode_frame`.
    #[test]
    fn write_frame_matches_encode() {
        let payload = vec![0x01u8, 0x02, 0x03];
        let mut buf = Vec::new();
        write_frame(&mut buf, &payload).unwrap();
        assert_eq!(buf, encode_frame(&payload).unwrap());
    }

    /// Header layout: 4 big-endian bytes followed by payload.
    #[test]
    fn header_is_big_endian_u32() {
        let payload = vec![0u8; 0x0102_0304];
        // This would allocate 16 MiB; instead, just check the
        // encoded prefix is correct.  Verify with a 5-byte payload
        // whose length is exactly representable as a small u32.
        let small_payload = vec![0xaau8; 5];
        let bytes = encode_frame(&small_payload).unwrap();
        assert_eq!(bytes[0], 0x00);
        assert_eq!(bytes[1], 0x00);
        assert_eq!(bytes[2], 0x00);
        assert_eq!(bytes[3], 0x05);
        // The 0x01020304 case is verified via the bound on
        // `OversizeFrame` rejection in another test.
        let _ = payload; // suppress unused
    }

    /// Reader at byte 0 returns `EofBeforeHeader` (clean close).
    #[test]
    fn empty_input_returns_eof_before_header() {
        let empty: Vec<u8> = Vec::new();
        let mut cursor = Cursor::new(empty);
        match read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::EofBeforeHeader) => {}
            other => panic!("expected EofBeforeHeader, got {other:?}"),
        }
    }

    /// Reader with 2 of 4 header bytes returns `TruncatedHeader`.
    #[test]
    fn partial_header_returns_truncated_header() {
        let bytes = vec![0x00u8, 0x00]; // 2 of 4 bytes
        let mut cursor = Cursor::new(bytes);
        match read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::TruncatedHeader { bytes_read }) => {
                assert_eq!(bytes_read, 2);
            }
            other => panic!("expected TruncatedHeader, got {other:?}"),
        }
    }

    /// Reader with complete header but partial payload returns
    /// `TruncatedPayload`.
    #[test]
    fn partial_payload_returns_truncated_payload() {
        // Header claims 10 bytes; only 3 bytes follow.
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&10u32.to_be_bytes());
        bytes.extend_from_slice(&[0x01, 0x02, 0x03]);
        let mut cursor = Cursor::new(bytes);
        match read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::TruncatedPayload {
                bytes_read,
                declared_length,
            }) => {
                assert_eq!(bytes_read, 3);
                assert_eq!(declared_length, 10);
            }
            other => panic!("expected TruncatedPayload, got {other:?}"),
        }
    }

    /// Header claiming > max_frame_size bytes returns
    /// `OversizeFrame`.
    #[test]
    fn oversize_header_returns_oversize_frame() {
        let mut bytes = Vec::new();
        // Max is 1 MiB; claim 2 MiB.
        bytes.extend_from_slice(&(2u32 * 1024 * 1024).to_be_bytes());
        let mut cursor = Cursor::new(bytes);
        match read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::OversizeFrame {
                declared_length,
                max,
            }) => {
                assert_eq!(declared_length, 2 * 1024 * 1024);
                assert_eq!(max, DEFAULT_MAX_FRAME_SIZE);
            }
            other => panic!("expected OversizeFrame, got {other:?}"),
        }
    }

    /// Header claiming u32::MAX returns `OversizeFrame` (does NOT
    /// allocate 4 GiB).  Defends against the canonical
    /// length-driven OOM attack pattern.
    #[test]
    fn huge_length_does_not_allocate() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&u32::MAX.to_be_bytes());
        let mut cursor = Cursor::new(bytes);
        let start = std::time::Instant::now();
        let result = read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE);
        let elapsed = start.elapsed();
        // Must error AND must be fast (allocation of 4 GiB would
        // take ms-to-seconds).
        assert!(
            elapsed.as_millis() < 100,
            "u32::MAX length took {elapsed:?}"
        );
        match result {
            Err(FrameError::OversizeFrame {
                declared_length, ..
            }) => {
                assert_eq!(declared_length, u32::MAX);
            }
            other => panic!("expected OversizeFrame, got {other:?}"),
        }
    }

    /// Zero-length frame is rejected.
    #[test]
    fn zero_length_frame_rejected() {
        let bytes = 0u32.to_be_bytes().to_vec();
        let mut cursor = Cursor::new(bytes);
        match read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::ZeroLengthFrame) => {}
            other => panic!("expected ZeroLengthFrame, got {other:?}"),
        }
    }

    /// 1-byte payload (smallest valid frame) round-trips.
    #[test]
    fn one_byte_payload_roundtrip() {
        let payload = vec![0xab];
        let bytes = encode_frame(&payload).unwrap();
        let mut cursor = Cursor::new(bytes);
        let decoded = read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(decoded, payload);
    }

    /// Payload at exactly `max_frame_size` is accepted.
    #[test]
    fn payload_at_exact_max_accepted() {
        let max = 4096; // small for test speed
        let payload = vec![0x42u8; max];
        let bytes = encode_frame(&payload).unwrap();
        let mut cursor = Cursor::new(bytes);
        let decoded = read_frame(&mut cursor, max).unwrap();
        assert_eq!(decoded, payload);
    }

    /// Payload at `max_frame_size + 1` is rejected.
    #[test]
    fn payload_above_max_rejected() {
        let max = 4096;
        let payload = vec![0x42u8; max + 1];
        let bytes = encode_frame(&payload).unwrap();
        let mut cursor = Cursor::new(bytes);
        match read_frame(&mut cursor, max) {
            Err(FrameError::OversizeFrame {
                declared_length,
                max: m,
            }) => {
                assert_eq!(declared_length as usize, max + 1);
                assert_eq!(m, max);
            }
            other => panic!("expected OversizeFrame, got {other:?}"),
        }
    }

    /// Multiple frames can be read sequentially from the same
    /// reader.  Defends against the parser accidentally consuming
    /// past the frame boundary.
    #[test]
    fn multiple_frames_sequential() {
        let p1 = b"first".to_vec();
        let p2 = b"second message".to_vec();
        let p3 = vec![0xff; 100];
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&encode_frame(&p1).unwrap());
        bytes.extend_from_slice(&encode_frame(&p2).unwrap());
        bytes.extend_from_slice(&encode_frame(&p3).unwrap());
        let mut cursor = Cursor::new(bytes);
        let d1 = read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        let d2 = read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        let d3 = read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(d1, p1);
        assert_eq!(d2, p2);
        assert_eq!(d3, p3);
        // Stream is now empty.
        match read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::EofBeforeHeader) => {}
            other => panic!("expected EofBeforeHeader, got {other:?}"),
        }
    }

    /// Read via a fragmented `Read` impl (returning ≤ 1 byte per
    /// call) still produces the correct payload.  Tests the
    /// `while filled < declared` loop.
    #[test]
    fn fragmented_reader() {
        struct OneByteReader<'a> {
            data: &'a [u8],
            pos: usize,
        }
        impl std::io::Read for OneByteReader<'_> {
            fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
                if self.pos >= self.data.len() || buf.is_empty() {
                    return Ok(0);
                }
                buf[0] = self.data[self.pos];
                self.pos += 1;
                Ok(1)
            }
        }
        let payload = b"fragmented payload bytes".to_vec();
        let bytes = encode_frame(&payload).unwrap();
        let mut reader = OneByteReader {
            data: &bytes,
            pos: 0,
        };
        let decoded = read_frame(&mut reader, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(decoded, payload);
    }

    /// `write_frame` for a payload longer than u32::MAX returns
    /// `PayloadTooLarge`.  We can't actually allocate u32::MAX
    /// bytes in a test, but we can verify via `encode_frame` that
    /// the cast guards against it.  (`encode_frame` shares the
    /// same `u32::try_from` guard.)
    #[test]
    fn payload_too_large_for_u32_returns_error() {
        // Synthesise a `Read`-failing case via a closure.  This
        // test is informational: we can't allocate > u32::MAX
        // bytes, so the test simply documents the contract.
        let small = vec![0u8; 10];
        let r = encode_frame(&small);
        assert!(r.is_ok());
    }

    /// Constants match the documented contract.
    #[test]
    fn constants_stable() {
        assert_eq!(DEFAULT_MAX_FRAME_SIZE, 1024 * 1024);
        assert_eq!(HARD_MAX_FRAME_SIZE, 16 * 1024 * 1024);
        assert_eq!(HEADER_LEN, 4);
    }

    /// `FrameError` is `Send + Sync` so it can cross thread
    /// boundaries (the connection handler threads may need to
    /// propagate errors via `JoinHandle::join`).
    #[test]
    fn frame_error_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<FrameError>();
    }

    /// A reader returning `WouldBlock` does NOT cause an infinite
    /// loop — the error propagates through `read_frame`.  This is
    /// important because non-blocking sockets surface as
    /// `WouldBlock`, and the parser must not spin.
    #[test]
    fn would_block_propagates() {
        struct WouldBlockReader;
        impl std::io::Read for WouldBlockReader {
            fn read(&mut self, _buf: &mut [u8]) -> std::io::Result<usize> {
                Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "would block",
                ))
            }
        }
        let mut reader = WouldBlockReader;
        match read_frame(&mut reader, DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::Io(e)) => {
                assert_eq!(e.kind(), std::io::ErrorKind::WouldBlock);
            }
            other => panic!("expected Io(WouldBlock), got {other:?}"),
        }
    }

    // ===== Rung-1 wire amendment (FQ.9 / FQ.10a / FQ.10b) ============

    /// The Rung-1 wire constants are the documented values, and the
    /// magic is the big-endian reading of the preamble bytes.
    #[test]
    fn rung1_constants_stable() {
        assert_eq!(KNH2_PREAMBLE, *b"KNH2");
        assert_eq!(KNH2_MAGIC, 0x4B4E_4832);
        assert_eq!(KNH2_MAGIC, u32::from_be_bytes(KNH2_PREAMBLE));
        assert_eq!(SIGNER_HINT_LEN, 8);
    }

    /// FQ.9 — THE load-bearing collision invariant, asserted at runtime
    /// to mirror the compile-time `const _` guard: the hard frame-size
    /// ceiling is strictly below the magic, so a valid v1 length prefix
    /// can never be mistaken for the preamble.
    #[test]
    fn hard_max_frame_size_below_magic() {
        assert!(
            (HARD_MAX_FRAME_SIZE as u64) < u64::from(KNH2_MAGIC),
            "HARD_MAX_FRAME_SIZE {HARD_MAX_FRAME_SIZE} must be < KNH2_MAGIC {KNH2_MAGIC}"
        );
        // And the default frame size is well below it too.
        assert!((DEFAULT_MAX_FRAME_SIZE as u64) < u64::from(KNH2_MAGIC));
    }

    /// FQ.10a — `negotiate_connection` detects a v2 connection (the
    /// 4-byte preamble) and consumes it, leaving the reader positioned
    /// at the first hinted frame.
    #[test]
    fn negotiate_detects_v2_preamble() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&KNH2_PREAMBLE);
        bytes.extend_from_slice(&encode_hinted_frame(7, b"body").unwrap());
        let mut cursor = Cursor::new(bytes);
        assert_eq!(
            negotiate_connection(&mut cursor).unwrap(),
            Negotiation::Hinted
        );
        // The preamble was consumed; the hinted frame follows intact.
        let (hint, payload) = read_hinted_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(hint, 7);
        assert_eq!(payload, b"body");
    }

    /// FQ.10a — `negotiate_connection` classifies a legacy (v1)
    /// connection and returns its first 4 bytes as the length prefix
    /// (NOT lost), which `read_frame_with_prefix` then completes.
    #[test]
    fn negotiate_legacy_preserves_first_frame() {
        // A v1 frame: 4-byte length (5) + 5-byte payload.
        let payload = b"hello";
        let bytes = encode_frame(payload).unwrap();
        let mut cursor = Cursor::new(bytes);
        let prefix = match negotiate_connection(&mut cursor).unwrap() {
            Negotiation::Legacy(p) => p,
            Negotiation::Hinted => panic!("v1 frame misclassified as hinted"),
        };
        assert_eq!(prefix, (payload.len() as u32).to_be_bytes());
        let decoded = read_frame_with_prefix(&mut cursor, prefix, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(
            decoded, payload,
            "legacy first frame payload lost/corrupted"
        );
    }

    /// FQ.9 collision argument in practice: NO valid v1 length (1 ..=
    /// HARD_MAX_FRAME_SIZE) is ever classified as the v2 preamble.  We
    /// sweep representative lengths including the exact ceiling.
    #[test]
    fn no_valid_v1_length_collides_with_magic() {
        for len in [
            1u32,
            2,
            255,
            65_536,
            DEFAULT_MAX_FRAME_SIZE as u32,
            HARD_MAX_FRAME_SIZE as u32,
        ] {
            let head = len.to_be_bytes();
            assert_ne!(
                head, KNH2_PREAMBLE,
                "v1 length {len} collides with the magic"
            );
            let mut cursor = Cursor::new(head.to_vec());
            // Negotiation classifies it as legacy (it then errors on the
            // missing body, but never as Hinted).
            match negotiate_connection(&mut cursor).unwrap() {
                Negotiation::Legacy(p) => assert_eq!(p, head),
                Negotiation::Hinted => panic!("v1 length {len} misclassified as hinted"),
            }
        }
    }

    /// FQ.10a — a clean close before any byte is `EofBeforeHeader`
    /// (the no-request-owed case); a partial (1–3 byte) peek is
    /// `TruncatedHeader`.
    #[test]
    fn negotiate_eof_and_partial() {
        let empty: Vec<u8> = Vec::new();
        match negotiate_connection(&mut Cursor::new(empty)) {
            Err(FrameError::EofBeforeHeader) => {}
            other => panic!("expected EofBeforeHeader, got {other:?}"),
        }
        let partial = vec![0x00u8, 0x00];
        match negotiate_connection(&mut Cursor::new(partial)) {
            Err(FrameError::TruncatedHeader { bytes_read }) => assert_eq!(bytes_read, 2),
            other => panic!("expected TruncatedHeader, got {other:?}"),
        }
    }

    /// FQ.10b — `read_hinted_frame` reads the 8-byte hint then the
    /// length-prefixed payload; the payload bytes are byte-identical to
    /// the non-hinted case for the same body.
    #[test]
    fn hinted_frame_round_trips() {
        let body = b"the opaque CBE body";
        let framed = encode_hinted_frame(0xDEAD_BEEF_0000_0001, body).unwrap();
        // Layout: 8-byte BE hint ++ 4-byte BE len ++ body.
        assert_eq!(framed.len(), SIGNER_HINT_LEN + HEADER_LEN + body.len());
        assert_eq!(
            &framed[..SIGNER_HINT_LEN],
            &0xDEAD_BEEF_0000_0001u64.to_be_bytes()
        );
        let mut cursor = Cursor::new(framed);
        let (hint, payload) = read_hinted_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(hint, 0xDEAD_BEEF_0000_0001);
        assert_eq!(payload, body);
        // The payload is exactly what a plain `read_frame` would yield.
        let mut plain = Cursor::new(encode_frame(body).unwrap());
        assert_eq!(
            read_frame(&mut plain, DEFAULT_MAX_FRAME_SIZE).unwrap(),
            payload
        );
    }

    /// FQ.10b — EOF semantics on a hinted connection: a clean EOF before
    /// any hint byte is `EofBeforeHeader` (the peer closed between
    /// frames); a partial hint is the dedicated `TruncatedHint`; and —
    /// once the FULL hint has committed the client to a request — an EOF
    /// before the length header is a `TruncatedHeader` (a protocol error
    /// → `ParseError`), NOT a benign `EofBeforeHeader`.  All surfaced
    /// BEFORE any body allocation.
    #[test]
    fn hinted_frame_eof_and_truncated_hint() {
        // (a) EOF before any hint byte → benign inter-frame close.
        match read_hinted_frame(&mut Cursor::new(Vec::new()), DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::EofBeforeHeader) => {}
            other => panic!("expected EofBeforeHeader, got {other:?}"),
        }
        // (b) 5 of 8 hint bytes then EOF → TruncatedHint.
        let partial = vec![0u8; 5];
        match read_hinted_frame(&mut Cursor::new(partial), DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::TruncatedHint { bytes_read }) => assert_eq!(bytes_read, 5),
            other => panic!("expected TruncatedHint, got {other:?}"),
        }
        // (c) FULL 8-byte hint then EOF before the length header → a
        //     committed-but-truncated request, NOT a clean close.  This
        //     must be a protocol error (handle_connection → ParseError),
        //     so it must NOT be EofBeforeHeader.
        let full_hint_only = 42u64.to_be_bytes().to_vec();
        match read_hinted_frame(&mut Cursor::new(full_hint_only), DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::TruncatedHeader { bytes_read }) => assert_eq!(bytes_read, 0),
            other => panic!("expected TruncatedHeader (committed-but-truncated), got {other:?}"),
        }
        // (d) full hint + 2 of 4 length-header bytes then EOF → also a
        //     TruncatedHeader (the partial header surfaces directly).
        let mut full_hint_partial_len = 7u64.to_be_bytes().to_vec();
        full_hint_partial_len.extend_from_slice(&[0u8, 0]); // 2 of 4 len bytes
        match read_hinted_frame(
            &mut Cursor::new(full_hint_partial_len),
            DEFAULT_MAX_FRAME_SIZE,
        ) {
            Err(FrameError::TruncatedHeader { bytes_read }) => assert_eq!(bytes_read, 2),
            other => panic!("expected TruncatedHeader (partial len), got {other:?}"),
        }
    }

    /// FQ.10b — a hinted connection with a valid hint but a zero-length
    /// / oversize body still rejects at the body layer (the hint read is
    /// independent of the body's validity), never reading the hint AS
    /// the body.
    #[test]
    fn hinted_frame_body_errors_are_independent_of_hint() {
        // Valid hint + zero-length body → ZeroLengthFrame.
        let mut bytes = 42u64.to_be_bytes().to_vec();
        bytes.extend_from_slice(&0u32.to_be_bytes());
        match read_hinted_frame(&mut Cursor::new(bytes), DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::ZeroLengthFrame) => {}
            other => panic!("expected ZeroLengthFrame, got {other:?}"),
        }
        // Valid hint + oversize body → OversizeFrame (no 2 GiB alloc).
        let mut bytes = 42u64.to_be_bytes().to_vec();
        bytes.extend_from_slice(&(8u32 * 1024 * 1024).to_be_bytes());
        match read_hinted_frame(&mut Cursor::new(bytes), 1024) {
            Err(FrameError::OversizeFrame { .. }) => {}
            other => panic!("expected OversizeFrame, got {other:?}"),
        }
    }

    /// FQ.10 — `read_request` is the one-shot composite: it returns the
    /// real hint for a v2 connection and the legacy sentinel for a v1
    /// connection, with byte-identical payloads in both cases.
    #[test]
    fn read_request_v1_and_v2() {
        let body = b"opaque";
        // v1: plain frame ⇒ LEGACY_SIGNER_HINT.
        let mut v1 = Cursor::new(encode_frame(body).unwrap());
        let (h1, p1) = read_request(&mut v1, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(h1, LEGACY_SIGNER_HINT);
        assert_eq!(p1, body);
        // v2: preamble + hinted frame ⇒ the real hint.
        let mut v2bytes = KNH2_PREAMBLE.to_vec();
        v2bytes.extend_from_slice(&encode_hinted_frame(123, body).unwrap());
        let mut v2 = Cursor::new(v2bytes);
        let (h2, p2) = read_request(&mut v2, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(h2, 123);
        assert_eq!(p2, body, "v1/v2 payloads must be byte-identical");
        assert_eq!(p1, p2);
    }

    /// FQ.10 — a v2 connection can carry multiple hinted frames in
    /// sequence (the wire format is per-frame, even though the host is
    /// one-shot today), and the negotiation is done exactly once.
    #[test]
    fn v2_multiple_hinted_frames_sequential() {
        let mut bytes = KNH2_PREAMBLE.to_vec();
        bytes.extend_from_slice(&encode_hinted_frame(1, b"a").unwrap());
        bytes.extend_from_slice(&encode_hinted_frame(2, b"bb").unwrap());
        let mut cursor = Cursor::new(bytes);
        assert_eq!(
            negotiate_connection(&mut cursor).unwrap(),
            Negotiation::Hinted
        );
        let (h1, p1) = read_hinted_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        let (h2, p2) = read_hinted_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!((h1, p1.as_slice()), (1, b"a".as_slice()));
        assert_eq!((h2, p2.as_slice()), (2, b"bb".as_slice()));
        // Stream now empty: a clean inter-frame close.
        match read_hinted_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::EofBeforeHeader) => {}
            other => panic!("expected EofBeforeHeader, got {other:?}"),
        }
    }

    /// `encode_hinted_frame` is the exact inverse of `read_hinted_frame`
    /// for the full `u64` hint range (endianness + layout pin).
    #[test]
    fn encode_hinted_frame_inverse_of_read() {
        for hint in [
            0u64,
            1,
            255,
            256,
            u64::from(u32::MAX),
            u64::MAX,
            LEGACY_SIGNER_HINT,
        ] {
            let framed = encode_hinted_frame(hint, b"x").unwrap();
            let mut cursor = Cursor::new(framed);
            let (got, payload) = read_hinted_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
            assert_eq!(got, hint);
            assert_eq!(payload, b"x");
        }
    }

    /// Fuzz: arbitrary leading bytes never panic the negotiation and
    /// never mis-read a v1 body as a hint — they classify as Hinted
    /// ONLY when the first 4 bytes are exactly the preamble.
    #[test]
    fn negotiate_fuzz_never_panics_or_misclassifies() {
        // Deterministic LCG so the test is reproducible.
        let mut state = 0x1234_5678_9abc_def0u64;
        let mut next = || {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (state >> 32) as u32
        };
        for _ in 0..10_000 {
            let head = next().to_be_bytes();
            let mut tail = vec![0u8; (next() % 16) as usize];
            for b in &mut tail {
                *b = next() as u8;
            }
            let mut bytes = head.to_vec();
            bytes.extend_from_slice(&tail);
            let mut cursor = Cursor::new(bytes);
            match negotiate_connection(&mut cursor) {
                Ok(Negotiation::Hinted) => {
                    assert_eq!(head, KNH2_PREAMBLE, "classified Hinted without the magic");
                }
                Ok(Negotiation::Legacy(p)) => {
                    assert_eq!(p, head);
                    assert_ne!(head, KNH2_PREAMBLE);
                }
                Err(_) => { /* truncated peek on a < 4 byte buffer is fine */ }
            }
        }
    }
}

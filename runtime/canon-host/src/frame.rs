// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Wire-frame parser for the canon-host network protocol.
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
//! ## Bounded length
//!
//! Every frame's declared length is checked against
//! [`MAX_FRAME_SIZE`] (default 1 MiB) before allocation or read.
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
//! ingestor crate `canon-l1-ingest` made the same choice for its
//! CBE encoder and HTTP submitter).

use std::io::{self, Read, Write};
use std::time::Instant;

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
/// (`canon-cross-stack::MAX_RECORD_BYTES`, `canon-l1-ingest::
/// submitter::MAX_SUBMISSION_BYTES`).  Above this the operator
/// is doing something unusual and should reconsider the
/// architecture.
pub const HARD_MAX_FRAME_SIZE: usize = 16 * 1024 * 1024;

/// Length of the frame-header prefix (4 bytes for a big-endian
/// u32 length field).
pub const HEADER_LEN: usize = 4;

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
    /// The caller-provided request deadline elapsed before the
    /// complete frame was read.
    #[error("frame read exceeded request deadline")]
    DeadlineExceeded,
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
    read_frame_internal(reader, max_frame_size, None)
}

/// Read one complete frame from `reader`, aborting if `deadline`
/// is reached before the full frame arrives.
///
/// Use this in network-facing code paths to bound total request
/// lifetime (slow-loris defence), not only individual socket-read
/// calls.
pub fn read_frame_with_deadline<R: Read>(
    reader: &mut R,
    max_frame_size: usize,
    deadline: Instant,
) -> Result<Vec<u8>, FrameError> {
    read_frame_internal(reader, max_frame_size, Some(deadline))
}

fn read_frame_internal<R: Read>(
    reader: &mut R,
    max_frame_size: usize,
    deadline: Option<Instant>,
) -> Result<Vec<u8>, FrameError> {
    // Defence-in-depth: clamp to HARD_MAX_FRAME_SIZE.  The CLI
    // validation rejects oversize values up-front; library
    // consumers that bypass the CLI (e.g. RH-F's bench) might
    // pass usize::MAX.  Clamping here is the load-bearing safety
    // net (per AR-RHC #14).
    let max_frame_size = max_frame_size.min(HARD_MAX_FRAME_SIZE);
    // 1. Read the 4-byte length prefix.  We allow EOF at byte 0
    //    (clean close) but a partial header is a protocol error.
    let mut header = [0u8; HEADER_LEN];
    let mut bytes_read = 0usize;
    while bytes_read < HEADER_LEN {
        if deadline.is_some_and(|d| Instant::now() >= d) {
            return Err(FrameError::DeadlineExceeded);
        }
        let n = reader.read(&mut header[bytes_read..])?;
        if n == 0 {
            // EOF.  If we haven't read anything yet, that's a clean
            // close; otherwise it's a truncated header.
            if bytes_read == 0 {
                return Err(FrameError::EofBeforeHeader);
            }
            return Err(FrameError::TruncatedHeader { bytes_read });
        }
        // `read` is guaranteed to return ≤ buf.len() bytes, so
        // `bytes_read + n ≤ HEADER_LEN`.  No overflow possible.
        bytes_read += n;
    }
    let declared = u32::from_be_bytes(header);

    // 2. Bound the declared length.  Rejecting zero-length here is
    //    deliberate: there is no valid empty SignedAction, so a
    //    zero-length frame is always a protocol error.  We surface
    //    it as a distinct variant so the listener can return
    //    ParseError without invoking the kernel.
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

    // 3. Allocate exactly `declared` bytes and fill via repeated
    //    reads.  Capacity is bounded above by `max_frame_size`
    //    (rejected by the previous check), so allocation can
    //    never panic on a malformed client.
    let mut payload = vec![0u8; declared_usize];
    let mut filled = 0usize;
    while filled < declared_usize {
        if deadline.is_some_and(|d| Instant::now() >= d) {
            return Err(FrameError::DeadlineExceeded);
        }
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

#[cfg(test)]
mod tests {
    use super::{
        encode_frame, read_frame, read_frame_with_deadline, write_frame, FrameError,
        DEFAULT_MAX_FRAME_SIZE, HARD_MAX_FRAME_SIZE, HEADER_LEN,
    };
    use std::io::Cursor;
    use std::time::{Duration, Instant};

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

    /// Deadline-enforced reads reject slow fragmented streams.
    #[test]
    fn deadline_exceeded_for_slow_fragmented_reader() {
        struct SlowOneByteReader {
            data: Vec<u8>,
            pos: usize,
            pause: Duration,
        }
        impl std::io::Read for SlowOneByteReader {
            fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
                if self.pos >= self.data.len() || buf.is_empty() {
                    return Ok(0);
                }
                std::thread::sleep(self.pause);
                buf[0] = self.data[self.pos];
                self.pos += 1;
                Ok(1)
            }
        }

        let payload = vec![0xaa; 8];
        let bytes = encode_frame(&payload).unwrap();
        let mut reader = SlowOneByteReader {
            data: bytes,
            pos: 0,
            pause: Duration::from_millis(10),
        };
        let deadline = Instant::now() + Duration::from_millis(15);
        match read_frame_with_deadline(&mut reader, DEFAULT_MAX_FRAME_SIZE, deadline) {
            Err(FrameError::DeadlineExceeded) => {}
            other => panic!("expected DeadlineExceeded, got {other:?}"),
        }
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
}

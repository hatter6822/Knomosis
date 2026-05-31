// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Wire-frame parser/encoder for the knomosis-event-subscribe protocol.
//!
//! See `docs/abi.md` §11 for the canonical wire-format specification.
//!
//! ## Two frame flows
//!
//! The protocol is bidirectional but asymmetric:
//!
//!   * **Client → server (inbound).**  A single `SUBSCRIBE` frame
//!     carrying an optional `resume_from` sequence number.  After
//!     SUBSCRIBE the client never sends another frame; the
//!     connection is effectively one-way (server → client) from
//!     that point onward.
//!   * **Server → client (outbound).**  A stream of frames; each
//!     either an `EVENT` frame (sequenced event payload) or a
//!     terminal control frame (`LAG_EXCEEDED`, `TRUNCATED`,
//!     `SERVER_SHUTDOWN`, `INVALID_REQUEST`).
//!
//! ## Frame layout discipline
//!
//! Every frame starts with a 1-byte kind tag.  Variable-length
//! payloads carry a 4-byte big-endian length prefix.  Fixed-width
//! fields (sequence numbers) are 8-byte big-endian u64.  Big-endian
//! matches `knomosis-host`'s wire format.
//!
//! ## Bounded length
//!
//! Every event-payload length prefix is checked against
//! [`MAX_FRAME_SIZE`] (default 1 MiB) before allocation or read.
//! Mirrors `knomosis-host::frame::read_frame`'s discipline byte-for-byte.
//!
//! ## Why hand-rolled
//!
//! Matches `knomosis-host`'s frame parser philosophy.  A generic
//! framing library would multiply the audit surface for a small
//! protocol; the explicit `read_be_u8` / `read_be_u32` / `read_be_u64`
//! / `read_bytes` helpers make every byte intentional.

use std::io::{self, Read, Write};

/// Default maximum accepted event-payload size (1 MiB).  Matches
/// `knomosis-host::frame::DEFAULT_MAX_FRAME_SIZE` so an event whose
/// CBE-encoded representation fits in knomosis-host's submission
/// envelope can fit in a subscriber's notification.  Operators may
/// override via `--max-frame-size <bytes>`.
pub const DEFAULT_MAX_FRAME_SIZE: usize = 1024 * 1024;

/// Hard ceiling on operator-configurable frame size.  16 MiB
/// matches the workspace's other limits.
pub const HARD_MAX_FRAME_SIZE: usize = 16 * 1024 * 1024;

/// 1-byte kind tag indicating an inbound `SUBSCRIBE` frame.
/// Followed by an 8-byte BE u64 `resume_from` (0 means "no resume,
/// start from the live tail").
pub const KIND_SUBSCRIBE: u8 = 0;

/// 1-byte kind tag indicating an outbound `EVENT` frame.
/// Followed by an 8-byte BE u64 sequence number, a 4-byte BE u32
/// payload length, and the CBE-encoded `Event` payload bytes.
pub const KIND_EVENT: u8 = 1;

/// 1-byte kind tag indicating the subscriber's lag exceeded the
/// configured maximum and the connection is being closed.
/// Followed by an 8-byte BE u64 reporting the **last delivered**
/// sequence number so the client can compute the gap if they
/// reconnect later (with `resume_from = last_delivered_seq`).
pub const KIND_LAG_EXCEEDED: u8 = 2;

/// 1-byte kind tag indicating the client's requested
/// `resume_from` is older than the server's `keep-history`
/// window — events that old are no longer available for backfill.
/// Followed by an 8-byte BE u64 reporting the **oldest available**
/// sequence number so the client knows where they could
/// successfully resume.
pub const KIND_TRUNCATED: u8 = 3;

/// 1-byte kind tag indicating the server is shutting down (operator
/// stop, or an unrecoverable extractor error).  Followed by an
/// 8-byte BE u64 reporting the last sequence number the server
/// emitted to this subscriber.
pub const KIND_SERVER_SHUTDOWN: u8 = 4;

/// 1-byte kind tag indicating the client's first frame was not a
/// valid SUBSCRIBE (unknown kind, malformed length, etc).  Followed
/// by an 8-byte BE u64 set to 0 (reserved; semantics are "no
/// per-frame diagnostic available beyond the tag itself").  The
/// server closes the connection immediately after sending.
pub const KIND_INVALID_REQUEST: u8 = 5;

/// Frame-parsing errors for inbound frames.
#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    /// The underlying I/O operation failed.
    #[error("I/O error reading frame: {0}")]
    Io(#[from] io::Error),
    /// The peer disconnected before sending any bytes.
    #[error("client closed connection before sending handshake")]
    EofBeforeHeader,
    /// The peer sent a partial frame and then closed the
    /// connection.  Indicates a malformed client.  `bytes_read`
    /// is the count of bytes successfully consumed before EOF.
    #[error("client sent {bytes_read} of {expected} frame bytes before EOF")]
    Truncated {
        /// Bytes received before EOF.
        bytes_read: usize,
        /// Bytes expected for the (partially-parsed) frame.
        expected: usize,
    },
    /// The kind tag did not match a known frame type.
    #[error("unknown frame kind: 0x{kind:02x}")]
    UnknownKind {
        /// The raw tag byte read.
        kind: u8,
    },
    /// The declared payload length exceeds the configured max.
    #[error("frame length {declared_length} exceeds configured max {max}")]
    OversizeFrame {
        /// Declared payload length from the header.
        declared_length: u32,
        /// Configured maximum frame size in bytes.
        max: usize,
    },
}

/// An inbound frame from the client.  Currently only one shape
/// (SUBSCRIBE) but kept as an enum for forward-extensibility.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InboundFrame {
    /// Subscription handshake.  `resume_from = 0` means "no
    /// resume; start from the live tail."  Any non-zero value
    /// means "send me every event whose sequence is **strictly
    /// greater** than `resume_from`" (i.e., `resume_from` is the
    /// last sequence the client successfully received).
    Subscribe {
        /// Last successfully-received sequence on the client side,
        /// or `0` to request "no resume, start from live tail."
        resume_from: u64,
    },
}

/// An outbound frame from the server.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OutboundFrame {
    /// A sequenced event payload.  `payload` is the CBE-encoded
    /// `Event` bytes from `Events.extractEvents`.
    Event {
        /// Sequence number (monotonically increasing, starting
        /// from `1` for the first event ever extracted).
        seq: u64,
        /// Event payload bytes (CBE-encoded).
        payload: Vec<u8>,
    },
    /// The subscriber was disconnected for exceeding the
    /// `--max-subscriber-lag` configuration.  The carried
    /// sequence is the last successfully-delivered event.
    LagExceeded {
        /// Last seq delivered before lag-eviction.
        last_delivered_seq: u64,
    },
    /// The client's requested `resume_from` is too old; the
    /// server has discarded events that old per its
    /// `--keep-history` setting.  The carried sequence is the
    /// **oldest available** seq the client could successfully
    /// resume from on a retry.
    Truncated {
        /// Oldest seq the server still has cached.
        oldest_available_seq: u64,
    },
    /// The server is shutting down (operator stop, or an
    /// unrecoverable extractor error).  Carries the last seq
    /// the subscriber received.
    ServerShutdown {
        /// Last seq delivered before shutdown.
        last_delivered_seq: u64,
    },
    /// The client's handshake was malformed (unknown kind,
    /// oversize, etc).  Reserved for handshake-time rejection
    /// only; subsequent server activity uses the other variants.
    InvalidRequest,
}

/// Read one [`InboundFrame`] from `reader`.
///
/// Currently only SUBSCRIBE is a valid inbound frame; future
/// extensions (e.g. `PING`, `UNSUBSCRIBE`) would add variants.
///
/// # Errors
///
/// Returns [`FrameError::EofBeforeHeader`] for a clean client
/// disconnect at byte 0.  All other variants surface protocol
/// violations.
pub fn read_inbound<R: Read>(reader: &mut R) -> Result<InboundFrame, FrameError> {
    // The SUBSCRIBE frame is exactly 9 bytes: 1 tag + 8 seq.
    // We read it in two phases so the EofBeforeHeader case is
    // distinguishable from a partial frame after some bytes.
    let mut header = [0u8; 1];
    let mut filled = 0usize;
    while filled < 1 {
        let n = reader.read(&mut header[filled..])?;
        if n == 0 {
            return Err(FrameError::EofBeforeHeader);
        }
        filled += n;
    }
    let kind = header[0];
    match kind {
        KIND_SUBSCRIBE => {
            let mut buf = [0u8; 8];
            read_exact_or_truncated(reader, &mut buf, 1, 9)?;
            let resume_from = u64::from_be_bytes(buf);
            Ok(InboundFrame::Subscribe { resume_from })
        }
        _ => Err(FrameError::UnknownKind { kind }),
    }
}

/// Read `buf.len()` bytes from `reader` into `buf`, returning
/// [`FrameError::Truncated`] on EOF before completion.
///
/// `bytes_already_read` and `expected_total` are diagnostic values
/// folded into the error.
fn read_exact_or_truncated<R: Read>(
    reader: &mut R,
    buf: &mut [u8],
    bytes_already_read: usize,
    expected_total: usize,
) -> Result<(), FrameError> {
    let mut filled = 0usize;
    while filled < buf.len() {
        let n = reader.read(&mut buf[filled..])?;
        if n == 0 {
            return Err(FrameError::Truncated {
                bytes_read: bytes_already_read + filled,
                expected: expected_total,
            });
        }
        filled += n;
    }
    Ok(())
}

/// Errors returned by [`write_outbound`].
#[derive(Debug, thiserror::Error)]
pub enum WriteFrameError {
    /// The underlying I/O operation failed.
    #[error("I/O error writing frame: {0}")]
    Io(#[from] io::Error),
    /// The event payload exceeds the configured max size and
    /// would have to be silently truncated.  Surfaces as a hard
    /// error so the caller can log + skip rather than corrupt
    /// the stream.
    #[error("event payload length {0} exceeds configured max {1}")]
    PayloadOversize(usize, usize),
    /// The event payload length exceeds the wire-format's u32
    /// length-prefix capacity.  Unreachable from any in-codebase
    /// payload (we bound at `MAX_FRAME_SIZE = 1 MiB`); included
    /// for type-system completeness.
    #[error("event payload length {0} exceeds u32::MAX (wire format limit)")]
    PayloadTooLarge(usize),
}

/// Encode an [`OutboundFrame`] to a byte vector.  Convenience
/// helper for tests and the server's tracing log.
///
/// # Errors
///
/// See [`WriteFrameError`].
pub fn encode_outbound(
    frame: &OutboundFrame,
    max_payload: usize,
) -> Result<Vec<u8>, WriteFrameError> {
    // Defence-in-depth: clamp to HARD_MAX_FRAME_SIZE.  Mirrors
    // `knomosis-host::frame::read_frame`'s clamping discipline.
    let max_payload = max_payload.min(HARD_MAX_FRAME_SIZE);
    match frame {
        OutboundFrame::Event { seq, payload } => {
            if payload.len() > max_payload {
                return Err(WriteFrameError::PayloadOversize(payload.len(), max_payload));
            }
            let len_u32 = u32::try_from(payload.len())
                .map_err(|_| WriteFrameError::PayloadTooLarge(payload.len()))?;
            let mut out = Vec::with_capacity(1 + 8 + 4 + payload.len());
            out.push(KIND_EVENT);
            out.extend_from_slice(&seq.to_be_bytes());
            out.extend_from_slice(&len_u32.to_be_bytes());
            out.extend_from_slice(payload);
            Ok(out)
        }
        OutboundFrame::LagExceeded { last_delivered_seq } => {
            let mut out = Vec::with_capacity(9);
            out.push(KIND_LAG_EXCEEDED);
            out.extend_from_slice(&last_delivered_seq.to_be_bytes());
            Ok(out)
        }
        OutboundFrame::Truncated {
            oldest_available_seq,
        } => {
            let mut out = Vec::with_capacity(9);
            out.push(KIND_TRUNCATED);
            out.extend_from_slice(&oldest_available_seq.to_be_bytes());
            Ok(out)
        }
        OutboundFrame::ServerShutdown { last_delivered_seq } => {
            let mut out = Vec::with_capacity(9);
            out.push(KIND_SERVER_SHUTDOWN);
            out.extend_from_slice(&last_delivered_seq.to_be_bytes());
            Ok(out)
        }
        OutboundFrame::InvalidRequest => {
            let mut out = Vec::with_capacity(9);
            out.push(KIND_INVALID_REQUEST);
            out.extend_from_slice(&0u64.to_be_bytes());
            Ok(out)
        }
    }
}

/// Write an [`OutboundFrame`] to `writer`, calling `flush` after
/// the payload completes.  Used by the per-subscriber dispatch
/// thread.
///
/// # Errors
///
/// See [`WriteFrameError`].
pub fn write_outbound<W: Write>(
    writer: &mut W,
    frame: &OutboundFrame,
    max_payload: usize,
) -> Result<(), WriteFrameError> {
    let bytes = encode_outbound(frame, max_payload)?;
    writer.write_all(&bytes)?;
    writer.flush()?;
    Ok(())
}

/// Read one [`OutboundFrame`] from `reader`.  Used by clients
/// (mostly tests; production clients are deployment-specific).
///
/// `max_payload` is the upper bound on accepted event-payload
/// length.  Internally clamped to [`HARD_MAX_FRAME_SIZE`] as a
/// defence-in-depth measure against library consumers passing
/// `usize::MAX`.
///
/// # Errors
///
/// See [`FrameError`].
pub fn read_outbound<R: Read>(
    reader: &mut R,
    max_payload: usize,
) -> Result<OutboundFrame, FrameError> {
    let max_payload = max_payload.min(HARD_MAX_FRAME_SIZE);
    // 1. Read the 1-byte kind tag.
    let mut header = [0u8; 1];
    let mut filled = 0usize;
    while filled < 1 {
        let n = reader.read(&mut header[filled..])?;
        if n == 0 {
            return Err(FrameError::EofBeforeHeader);
        }
        filled += n;
    }
    let kind = header[0];
    match kind {
        KIND_EVENT => {
            // 8-byte BE seq + 4-byte BE length + N payload bytes.
            let mut seq_buf = [0u8; 8];
            read_exact_or_truncated(reader, &mut seq_buf, 1, 13)?;
            let seq = u64::from_be_bytes(seq_buf);
            let mut len_buf = [0u8; 4];
            read_exact_or_truncated(reader, &mut len_buf, 9, 13)?;
            let declared = u32::from_be_bytes(len_buf);
            let declared_usize = declared as usize;
            if declared_usize > max_payload {
                return Err(FrameError::OversizeFrame {
                    declared_length: declared,
                    max: max_payload,
                });
            }
            let mut payload = vec![0u8; declared_usize];
            read_exact_or_truncated(reader, &mut payload, 13, 13 + declared_usize)?;
            Ok(OutboundFrame::Event { seq, payload })
        }
        KIND_LAG_EXCEEDED => {
            let mut buf = [0u8; 8];
            read_exact_or_truncated(reader, &mut buf, 1, 9)?;
            let seq = u64::from_be_bytes(buf);
            Ok(OutboundFrame::LagExceeded {
                last_delivered_seq: seq,
            })
        }
        KIND_TRUNCATED => {
            let mut buf = [0u8; 8];
            read_exact_or_truncated(reader, &mut buf, 1, 9)?;
            let seq = u64::from_be_bytes(buf);
            Ok(OutboundFrame::Truncated {
                oldest_available_seq: seq,
            })
        }
        KIND_SERVER_SHUTDOWN => {
            let mut buf = [0u8; 8];
            read_exact_or_truncated(reader, &mut buf, 1, 9)?;
            let seq = u64::from_be_bytes(buf);
            Ok(OutboundFrame::ServerShutdown {
                last_delivered_seq: seq,
            })
        }
        KIND_INVALID_REQUEST => {
            let mut buf = [0u8; 8];
            read_exact_or_truncated(reader, &mut buf, 1, 9)?;
            // The 8 bytes are reserved; we silently consume them.
            let _ = u64::from_be_bytes(buf);
            Ok(OutboundFrame::InvalidRequest)
        }
        _ => Err(FrameError::UnknownKind { kind }),
    }
}

/// Encode an [`InboundFrame`] to a byte vector.  Used by test
/// clients.
#[must_use]
pub fn encode_inbound(frame: &InboundFrame) -> Vec<u8> {
    match frame {
        InboundFrame::Subscribe { resume_from } => {
            let mut out = Vec::with_capacity(9);
            out.push(KIND_SUBSCRIBE);
            out.extend_from_slice(&resume_from.to_be_bytes());
            out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        encode_inbound, encode_outbound, read_inbound, read_outbound, write_outbound, FrameError,
        InboundFrame, OutboundFrame, DEFAULT_MAX_FRAME_SIZE, HARD_MAX_FRAME_SIZE, KIND_EVENT,
        KIND_INVALID_REQUEST, KIND_LAG_EXCEEDED, KIND_SERVER_SHUTDOWN, KIND_SUBSCRIBE,
        KIND_TRUNCATED,
    };
    use std::io::Cursor;

    /// Frame-kind constants match the documented values.
    #[test]
    fn kind_constants_stable() {
        assert_eq!(KIND_SUBSCRIBE, 0);
        assert_eq!(KIND_EVENT, 1);
        assert_eq!(KIND_LAG_EXCEEDED, 2);
        assert_eq!(KIND_TRUNCATED, 3);
        assert_eq!(KIND_SERVER_SHUTDOWN, 4);
        assert_eq!(KIND_INVALID_REQUEST, 5);
    }

    /// Default + hard-max bounds are documented values.
    #[test]
    fn bounds_constants_stable() {
        assert_eq!(DEFAULT_MAX_FRAME_SIZE, 1024 * 1024);
        assert_eq!(HARD_MAX_FRAME_SIZE, 16 * 1024 * 1024);
    }

    /// SUBSCRIBE round-trip: encode then read.
    #[test]
    fn subscribe_round_trip() {
        let frame = InboundFrame::Subscribe { resume_from: 42 };
        let bytes = encode_inbound(&frame);
        assert_eq!(bytes.len(), 9);
        assert_eq!(bytes[0], KIND_SUBSCRIBE);
        let mut cursor = Cursor::new(bytes);
        let decoded = read_inbound(&mut cursor).unwrap();
        assert_eq!(decoded, frame);
    }

    /// SUBSCRIBE with `resume_from = 0` (live-tail).
    #[test]
    fn subscribe_no_resume() {
        let frame = InboundFrame::Subscribe { resume_from: 0 };
        let bytes = encode_inbound(&frame);
        let mut cursor = Cursor::new(bytes);
        let decoded = read_inbound(&mut cursor).unwrap();
        assert_eq!(decoded, frame);
    }

    /// SUBSCRIBE with the max u64 round-trips.
    #[test]
    fn subscribe_max_u64() {
        let frame = InboundFrame::Subscribe {
            resume_from: u64::MAX,
        };
        let bytes = encode_inbound(&frame);
        let mut cursor = Cursor::new(bytes);
        let decoded = read_inbound(&mut cursor).unwrap();
        assert_eq!(decoded, frame);
    }

    /// SUBSCRIBE is serialised in big-endian order.
    #[test]
    fn subscribe_is_big_endian() {
        let frame = InboundFrame::Subscribe {
            resume_from: 0x01_02_03_04_05_06_07_08,
        };
        let bytes = encode_inbound(&frame);
        // tag + BE u64
        assert_eq!(
            bytes,
            vec![
                KIND_SUBSCRIBE,
                0x01,
                0x02,
                0x03,
                0x04,
                0x05,
                0x06,
                0x07,
                0x08
            ]
        );
    }

    /// Empty input → `EofBeforeHeader` (clean close).
    #[test]
    fn empty_input_returns_eof_before_header() {
        let mut cursor = Cursor::new(Vec::<u8>::new());
        match read_inbound(&mut cursor) {
            Err(FrameError::EofBeforeHeader) => {}
            other => panic!("expected EofBeforeHeader, got {other:?}"),
        }
    }

    /// Partial SUBSCRIBE (1 of 9 bytes) → `Truncated`.
    #[test]
    fn partial_subscribe_returns_truncated() {
        let mut cursor = Cursor::new(vec![KIND_SUBSCRIBE]);
        match read_inbound(&mut cursor) {
            Err(FrameError::Truncated {
                bytes_read,
                expected,
            }) => {
                assert_eq!(bytes_read, 1);
                assert_eq!(expected, 9);
            }
            other => panic!("expected Truncated, got {other:?}"),
        }
    }

    /// Partial SUBSCRIBE (4 of 9 bytes) → `Truncated`.
    #[test]
    fn partial_subscribe_4_bytes() {
        let mut cursor = Cursor::new(vec![KIND_SUBSCRIBE, 0, 0, 0]);
        match read_inbound(&mut cursor) {
            Err(FrameError::Truncated {
                bytes_read,
                expected,
            }) => {
                assert_eq!(bytes_read, 4);
                assert_eq!(expected, 9);
            }
            other => panic!("expected Truncated, got {other:?}"),
        }
    }

    /// Unknown kind tag → `UnknownKind`.
    #[test]
    fn unknown_kind_returns_error() {
        let mut cursor = Cursor::new(vec![0xff]);
        match read_inbound(&mut cursor) {
            Err(FrameError::UnknownKind { kind }) => assert_eq!(kind, 0xff),
            other => panic!("expected UnknownKind, got {other:?}"),
        }
    }

    /// EVENT round-trip.
    #[test]
    fn event_round_trip() {
        let frame = OutboundFrame::Event {
            seq: 100,
            payload: b"hello".to_vec(),
        };
        let bytes = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        // tag(1) + seq(8) + len(4) + payload(5)
        assert_eq!(bytes.len(), 18);
        assert_eq!(bytes[0], KIND_EVENT);
        let mut cursor = Cursor::new(bytes);
        let decoded = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(decoded, frame);
    }

    /// EVENT with empty payload round-trips (length-zero payload
    /// is legal — some kernel actions emit no events).
    #[test]
    fn event_empty_payload() {
        let frame = OutboundFrame::Event {
            seq: 1,
            payload: Vec::new(),
        };
        let bytes = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(bytes.len(), 13);
        let mut cursor = Cursor::new(bytes);
        let decoded = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(decoded, frame);
    }

    /// EVENT with payload exactly at max accepted.
    #[test]
    fn event_at_exact_max_size() {
        let max = 1024;
        let frame = OutboundFrame::Event {
            seq: 1,
            payload: vec![0x42; max],
        };
        let bytes = encode_outbound(&frame, max).unwrap();
        let mut cursor = Cursor::new(bytes);
        let decoded = read_outbound(&mut cursor, max).unwrap();
        assert_eq!(decoded, frame);
    }

    /// EVENT payload above max is rejected at encode time.
    #[test]
    fn event_oversize_payload_rejected_at_encode() {
        let max = 1024;
        let frame = OutboundFrame::Event {
            seq: 1,
            payload: vec![0x42; max + 1],
        };
        match encode_outbound(&frame, max) {
            Err(super::WriteFrameError::PayloadOversize(n, m)) => {
                assert_eq!(n, max + 1);
                assert_eq!(m, max);
            }
            other => panic!("expected PayloadOversize, got {other:?}"),
        }
    }

    /// EVENT payload above max is rejected at decode time.
    /// Synthesise an EVENT frame manually with a long length
    /// prefix; verify the parser rejects with `OversizeFrame`.
    #[test]
    fn event_oversize_payload_rejected_at_decode() {
        let max = 1024;
        let mut bytes = Vec::new();
        bytes.push(KIND_EVENT);
        bytes.extend_from_slice(&1u64.to_be_bytes()); // seq
        bytes.extend_from_slice(&2048u32.to_be_bytes()); // declared length > max
        let mut cursor = Cursor::new(bytes);
        match read_outbound(&mut cursor, max) {
            Err(FrameError::OversizeFrame {
                declared_length,
                max: m,
            }) => {
                assert_eq!(declared_length, 2048);
                assert_eq!(m, max);
            }
            other => panic!("expected OversizeFrame, got {other:?}"),
        }
    }

    /// EVENT with u32::MAX declared length → OversizeFrame (no
    /// 4 GiB allocation).
    #[test]
    fn event_huge_length_does_not_allocate() {
        let mut bytes = Vec::new();
        bytes.push(KIND_EVENT);
        bytes.extend_from_slice(&1u64.to_be_bytes());
        bytes.extend_from_slice(&u32::MAX.to_be_bytes());
        let mut cursor = Cursor::new(bytes);
        let start = std::time::Instant::now();
        let result = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE);
        let elapsed = start.elapsed();
        assert!(
            elapsed.as_millis() < 100,
            "u32::MAX length took {elapsed:?}"
        );
        match result {
            Err(FrameError::OversizeFrame {
                declared_length, ..
            }) => assert_eq!(declared_length, u32::MAX),
            other => panic!("expected OversizeFrame, got {other:?}"),
        }
    }

    /// LAG_EXCEEDED round-trip.
    #[test]
    fn lag_exceeded_round_trip() {
        let frame = OutboundFrame::LagExceeded {
            last_delivered_seq: 12345,
        };
        let bytes = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(bytes.len(), 9);
        assert_eq!(bytes[0], KIND_LAG_EXCEEDED);
        let mut cursor = Cursor::new(bytes);
        let decoded = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(decoded, frame);
    }

    /// TRUNCATED round-trip.
    #[test]
    fn truncated_round_trip() {
        let frame = OutboundFrame::Truncated {
            oldest_available_seq: 200,
        };
        let bytes = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(bytes.len(), 9);
        let mut cursor = Cursor::new(bytes);
        let decoded = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(decoded, frame);
    }

    /// SERVER_SHUTDOWN round-trip.
    #[test]
    fn server_shutdown_round_trip() {
        let frame = OutboundFrame::ServerShutdown {
            last_delivered_seq: 999,
        };
        let bytes = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(bytes.len(), 9);
        let mut cursor = Cursor::new(bytes);
        let decoded = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(decoded, frame);
    }

    /// INVALID_REQUEST round-trip.
    #[test]
    fn invalid_request_round_trip() {
        let frame = OutboundFrame::InvalidRequest;
        let bytes = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(bytes.len(), 9);
        assert_eq!(bytes[0], KIND_INVALID_REQUEST);
        let mut cursor = Cursor::new(bytes);
        let decoded = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(decoded, frame);
    }

    /// `write_outbound` produces identical bytes to `encode_outbound`.
    #[test]
    fn write_outbound_matches_encode() {
        let frame = OutboundFrame::Event {
            seq: 50,
            payload: b"abc".to_vec(),
        };
        let mut buf = Vec::new();
        write_outbound(&mut buf, &frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        let encoded = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(buf, encoded);
    }

    /// EVENT length prefix is big-endian.
    #[test]
    fn event_length_is_big_endian() {
        let frame = OutboundFrame::Event {
            seq: 1,
            payload: vec![0xff; 0x102],
        };
        let bytes = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        // tag + seq(8) = offset 9; length is at [9..13]
        assert_eq!(bytes[9], 0x00);
        assert_eq!(bytes[10], 0x00);
        assert_eq!(bytes[11], 0x01);
        assert_eq!(bytes[12], 0x02);
    }

    /// Multiple outbound frames can be read sequentially.
    #[test]
    fn multiple_outbound_frames_sequential() {
        let f1 = OutboundFrame::Event {
            seq: 1,
            payload: b"a".to_vec(),
        };
        let f2 = OutboundFrame::Event {
            seq: 2,
            payload: b"bc".to_vec(),
        };
        let f3 = OutboundFrame::LagExceeded {
            last_delivered_seq: 2,
        };
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&encode_outbound(&f1, DEFAULT_MAX_FRAME_SIZE).unwrap());
        bytes.extend_from_slice(&encode_outbound(&f2, DEFAULT_MAX_FRAME_SIZE).unwrap());
        bytes.extend_from_slice(&encode_outbound(&f3, DEFAULT_MAX_FRAME_SIZE).unwrap());
        let mut cursor = Cursor::new(bytes);
        assert_eq!(
            read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap(),
            f1
        );
        assert_eq!(
            read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap(),
            f2
        );
        assert_eq!(
            read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap(),
            f3
        );
        // Stream is now empty.
        match read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::EofBeforeHeader) => {}
            other => panic!("expected EofBeforeHeader, got {other:?}"),
        }
    }

    /// Fragmented reader (1 byte per `read` call) round-trips EVENT.
    /// Defends against the parser accidentally requiring a single
    /// large `read` call.
    #[test]
    fn fragmented_reader_event() {
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
        let frame = OutboundFrame::Event {
            seq: 7,
            payload: b"slow-byte-by-byte-event".to_vec(),
        };
        let bytes = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        let mut reader = OneByteReader {
            data: &bytes,
            pos: 0,
        };
        let decoded = read_outbound(&mut reader, DEFAULT_MAX_FRAME_SIZE).unwrap();
        assert_eq!(decoded, frame);
    }

    /// `FrameError` is `Send + Sync` so it can cross thread
    /// boundaries (the per-subscriber dispatch threads may
    /// propagate errors).
    #[test]
    fn frame_error_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<FrameError>();
        assert_send_sync::<super::WriteFrameError>();
    }

    /// A reader returning `WouldBlock` does NOT cause an infinite
    /// loop — the error propagates.
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
        match read_inbound(&mut reader) {
            Err(FrameError::Io(e)) => {
                assert_eq!(e.kind(), std::io::ErrorKind::WouldBlock);
            }
            other => panic!("expected Io(WouldBlock), got {other:?}"),
        }
    }

    /// Truncated EVENT (header but no payload) → `Truncated`.
    #[test]
    fn truncated_event_returns_error() {
        let mut bytes = Vec::new();
        bytes.push(KIND_EVENT);
        bytes.extend_from_slice(&1u64.to_be_bytes());
        bytes.extend_from_slice(&10u32.to_be_bytes()); // declared 10 bytes
        bytes.extend_from_slice(&[0x01, 0x02]); // only 2 bytes follow
        let mut cursor = Cursor::new(bytes);
        match read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE) {
            Err(FrameError::Truncated {
                bytes_read,
                expected,
            }) => {
                assert_eq!(bytes_read, 15); // tag(1)+seq(8)+len(4)+payload(2)
                assert_eq!(expected, 23); // tag(1)+seq(8)+len(4)+payload(10)
            }
            other => panic!("expected Truncated, got {other:?}"),
        }
    }
}

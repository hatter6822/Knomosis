// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G2.1a host wire codec: frame a submit request for the binary host, and
//! parse the host's verdict response.
//!
//! The wire format (abi.md §10, mirrored from `knomosis-host`):
//!   * **request** — a v1 frame (`knomosis_host::frame::encode_frame`): a
//!     4-byte big-endian length prefix + the client-signed `SignedAction`
//!     CBE payload (forwarded opaquely; no signer hint, no key custody).
//!   * **response** — `[1-byte verdict][4-byte BE reason length M][M reason
//!     bytes]` (the raw `VerdictResponse::encode` form; not itself
//!     length-framed — the verdict + length prefix *is* the framing).
//!
//! Every malformed response — a short buffer, an unrecognised verdict
//! byte (protocol drift / corruption), an over-long or non-UTF-8 reason —
//! **fails closed** with a typed [`ResponseError`] the submit endpoint
//! maps to `502` (G2.2).

use std::io::Read;

use knomosis_host::frame::encode_frame;
use knomosis_host::verdict::{Verdict, VerdictResponse};

/// The verdict-response header: a 1-byte verdict + a 4-byte BE reason
/// length.
const RESPONSE_HEADER_LEN: usize = 5;

/// Upper bound on a verdict reason, guarding against a misbehaving host
/// declaring a huge reason length before we allocate.  Verdict reasons
/// are short policy strings; 64 KiB is generous headroom.
const MAX_REASON_LEN: usize = 64 * 1024;

/// Errors framing a submit request for the host.
#[derive(Debug, thiserror::Error)]
pub enum RequestError {
    /// The signed-action payload exceeds the host's hard frame cap.
    #[error("submit payload too large to frame: {reason}")]
    TooLarge {
        /// The framing-layer diagnostic.
        reason: String,
    },
}

/// Errors parsing the host's verdict response — all **fail closed**
/// (the submit endpoint maps them to `502`).
#[derive(Debug, thiserror::Error)]
pub enum ResponseError {
    /// The response ended before a full header / reason was read.
    #[error("verdict response truncated: {reason}")]
    Truncated {
        /// What was expected vs. what arrived.
        reason: String,
    },
    /// The verdict byte is not a recognised [`Verdict`] (protocol drift
    /// or corruption).
    #[error("unrecognised verdict byte {byte:#04x}")]
    UnknownVerdict {
        /// The offending byte.
        byte: u8,
    },
    /// The declared reason length exceeds [`MAX_REASON_LEN`].
    #[error("verdict reason length {len} exceeds the {max}-byte cap")]
    ReasonTooLong {
        /// The declared length.
        len: usize,
        /// The enforced cap.
        max: usize,
    },
    /// The reason bytes are not valid UTF-8.
    #[error("verdict reason is not valid UTF-8")]
    InvalidReasonUtf8,
    /// The host did not send (the rest of) the response within the read
    /// deadline — distinct from a connection that closed early, so the
    /// pool can map it to `504` rather than `502`.
    #[error("verdict response read timed out")]
    ReadTimeout,
}

/// Frame a client-signed `SignedAction` payload (CBE bytes) into a host
/// request frame (v1, no signer hint).  The payload is forwarded
/// **opaquely** — the gateway never inspects or re-signs it.
///
/// # Errors
///
/// [`RequestError::TooLarge`] when the payload exceeds the host's hard
/// frame cap.
pub fn encode_request_frame(payload: &[u8]) -> Result<Vec<u8>, RequestError> {
    encode_frame(payload).map_err(|e| RequestError::TooLarge {
        reason: e.to_string(),
    })
}

/// Parse a **complete** verdict-response buffer into a [`VerdictResponse`].
///
/// # Errors
///
/// See [`ResponseError`]: a short buffer, an unknown verdict byte, or an
/// over-long / non-UTF-8 reason all fail closed.
pub fn parse_verdict_response(bytes: &[u8]) -> Result<VerdictResponse, ResponseError> {
    if bytes.len() < RESPONSE_HEADER_LEN {
        return Err(ResponseError::Truncated {
            reason: format!(
                "need {RESPONSE_HEADER_LEN} header bytes, got {}",
                bytes.len()
            ),
        });
    }
    let (header, body) = bytes.split_at(RESPONSE_HEADER_LEN);
    let verdict = decode_verdict(header[0])?;
    let reason_len = decode_reason_len(header)?;
    if body.len() < reason_len {
        return Err(ResponseError::Truncated {
            reason: format!("need {reason_len} reason bytes, got {}", body.len()),
        });
    }
    let reason = std::str::from_utf8(&body[..reason_len])
        .map_err(|_| ResponseError::InvalidReasonUtf8)?
        .to_string();
    Ok(VerdictResponse { verdict, reason })
}

/// Read a verdict response from a stream: read the 5-byte header, then
/// the declared reason, then parse.  Used by the connection pool
/// (G2.1b).
///
/// # Errors
///
/// See [`ResponseError`].
pub fn read_verdict_response<R: Read>(reader: &mut R) -> Result<VerdictResponse, ResponseError> {
    let mut header = [0u8; RESPONSE_HEADER_LEN];
    read_exact_or_truncated(reader, &mut header)?;
    let verdict = decode_verdict(header[0])?;
    let reason_len = decode_reason_len(&header)?;
    let mut reason_bytes = vec![0u8; reason_len];
    read_exact_or_truncated(reader, &mut reason_bytes)?;
    let reason = String::from_utf8(reason_bytes).map_err(|_| ResponseError::InvalidReasonUtf8)?;
    Ok(VerdictResponse { verdict, reason })
}

/// Decode the verdict byte, failing closed on an unrecognised value.
fn decode_verdict(byte: u8) -> Result<Verdict, ResponseError> {
    Verdict::from_byte(byte).ok_or(ResponseError::UnknownVerdict { byte })
}

/// Decode + bound the 4-byte BE reason length from a header (the caller
/// guarantees at least [`RESPONSE_HEADER_LEN`] bytes).
fn decode_reason_len(header: &[u8]) -> Result<usize, ResponseError> {
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    if len > MAX_REASON_LEN {
        return Err(ResponseError::ReasonTooLong {
            len,
            max: MAX_REASON_LEN,
        });
    }
    Ok(len)
}

/// `read_exact`, mapping a read deadline to [`ResponseError::ReadTimeout`]
/// and any other early EOF / I/O failure to [`ResponseError::Truncated`].
fn read_exact_or_truncated<R: Read>(reader: &mut R, buf: &mut [u8]) -> Result<(), ResponseError> {
    reader.read_exact(buf).map_err(|e| {
        if matches!(
            e.kind(),
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
        ) {
            ResponseError::ReadTimeout
        } else {
            ResponseError::Truncated {
                reason: e.to_string(),
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::{
        encode_request_frame, parse_verdict_response, read_verdict_response, ResponseError,
        MAX_REASON_LEN, RESPONSE_HEADER_LEN,
    };
    use knomosis_host::frame::{read_frame, DEFAULT_MAX_FRAME_SIZE};
    use knomosis_host::verdict::{Verdict, VerdictResponse};

    /// Every verdict + reason round-trips through `VerdictResponse::encode`
    /// → `parse_verdict_response` (golden bytes from the host's own
    /// encoder).
    #[test]
    fn parse_round_trips_every_verdict() {
        for verdict in [
            Verdict::Ok,
            Verdict::NotAdmissible,
            Verdict::ParseError,
            Verdict::Busy,
        ] {
            for reason in ["", "InsufficientBudget", "nonce mismatch — retry"] {
                let golden = VerdictResponse::with_reason(verdict, reason).encode();
                let parsed = parse_verdict_response(&golden).expect("parses");
                assert_eq!(parsed.verdict, verdict);
                assert_eq!(parsed.reason, reason);
            }
        }
    }

    /// The streaming reader yields the same result over a cursor, and
    /// consumes exactly the response bytes (a trailing byte is left).
    #[test]
    fn stream_reader_matches_buffer_parse() {
        let golden = VerdictResponse::with_reason(Verdict::NotAdmissible, "denied").encode();
        let mut framed = golden.clone();
        framed.push(0xAB); // a trailing byte the reader must not consume
        let mut cursor = std::io::Cursor::new(framed);
        let parsed = read_verdict_response(&mut cursor).expect("reads");
        assert_eq!(parsed.verdict, Verdict::NotAdmissible);
        assert_eq!(parsed.reason, "denied");
        // The trailing byte remains unread.
        let mut rest = Vec::new();
        std::io::Read::read_to_end(&mut cursor, &mut rest).unwrap();
        assert_eq!(rest, vec![0xAB]);
    }

    /// An unrecognised verdict byte fails closed (→ 502).
    #[test]
    fn unknown_verdict_byte_fails_closed() {
        let mut bytes = VerdictResponse::with_reason(Verdict::Ok, "x").encode();
        bytes[0] = 0xFE; // not a valid Verdict
        assert!(matches!(
            parse_verdict_response(&bytes),
            Err(ResponseError::UnknownVerdict { byte: 0xFE })
        ));
    }

    /// A short buffer (no full header, or a reason shorter than declared)
    /// is truncated.
    #[test]
    fn truncated_responses_are_rejected() {
        assert!(matches!(
            parse_verdict_response(&[0, 0, 0]),
            Err(ResponseError::Truncated { .. })
        ));
        // Header declares a 10-byte reason but only 3 follow.
        let mut bytes = vec![Verdict::Ok.to_byte()];
        bytes.extend_from_slice(&10u32.to_be_bytes());
        bytes.extend_from_slice(b"abc");
        assert!(matches!(
            parse_verdict_response(&bytes),
            Err(ResponseError::Truncated { .. })
        ));
    }

    /// A reason length over the cap is rejected before allocation.
    #[test]
    fn over_long_reason_is_rejected() {
        let mut header = [0u8; RESPONSE_HEADER_LEN];
        header[0] = Verdict::Ok.to_byte();
        #[allow(clippy::cast_possible_truncation)]
        let over = (MAX_REASON_LEN + 1) as u32;
        header[1..5].copy_from_slice(&over.to_be_bytes());
        assert!(matches!(
            parse_verdict_response(&header),
            Err(ResponseError::ReasonTooLong { .. })
        ));
    }

    /// A non-UTF-8 reason fails closed.
    #[test]
    fn non_utf8_reason_is_rejected() {
        let mut bytes = vec![Verdict::Ok.to_byte()];
        bytes.extend_from_slice(&2u32.to_be_bytes());
        bytes.extend_from_slice(&[0xFF, 0xFE]); // invalid UTF-8
        assert!(matches!(
            parse_verdict_response(&bytes),
            Err(ResponseError::InvalidReasonUtf8)
        ));
    }

    /// The request framing round-trips through the host's `read_frame`
    /// (the payload is forwarded byte-identical).
    #[test]
    fn request_frame_round_trips_through_host_decoder() {
        let payload = b"opaque-signed-action-cbe-bytes";
        let frame = encode_request_frame(payload).expect("frames");
        let mut cursor = std::io::Cursor::new(frame);
        let decoded = read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).expect("decodes");
        assert_eq!(decoded, payload);
    }
}

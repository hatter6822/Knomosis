// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! A small, dependency-free **standard** Base64 decoder (RFC 4648 §4,
//! the `+/` alphabet with `=` padding) for the `application/json` submit
//! intake's `signedAction` field.
//!
//! The gateway's *canonical* submit path is `application/octet-stream`
//! (raw CBE bytes, no Base64), so this decoder exists only for the JSON
//! convenience form — hence a hand-roll rather than a new dependency.  It
//! is strict: it rejects non-alphabet characters, bad padding, and a
//! wrong-length input, so a malformed `signedAction` fails closed (→
//! `400`) rather than silently decoding to the wrong bytes.

/// Decode standard Base64 (`+/`, `=` padding).  Internal whitespace is
/// **not** permitted (a JSON string field carries none).
///
/// Returns `None` on any malformed input (illegal character, misplaced
/// padding, or a length that is not a multiple of four).
#[must_use]
pub fn decode(input: &str) -> Option<Vec<u8>> {
    let bytes = input.as_bytes();
    if bytes.len() % 4 != 0 {
        return None;
    }
    if bytes.is_empty() {
        return Some(Vec::new());
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let last = bytes.len() / 4 - 1;
    for (i, chunk) in bytes.chunks_exact(4).enumerate() {
        // `=` is only ever legal in positions 2-3 of the final quad; in
        // positions 0-1 it is not an alphabet byte and `sextet` rejects
        // it below, so we only count padding in the trailing two.
        let pad = usize::from(chunk[2] == b'=') + usize::from(chunk[3] == b'=');
        if pad > 0 && i != last {
            return None; // padding before the final quad
        }
        let s0 = sextet(chunk[0])?;
        let s1 = sextet(chunk[1])?;
        // The first two sextets are always present; positions 3 and 4 may
        // be padding.
        out.push((s0 << 2) | (s1 >> 4));
        match (chunk[2], chunk[3]) {
            (b'=', b'=') => {
                if pad != 2 {
                    return None;
                }
                // One output byte from this quad; the low bits of s1 must
                // be zero (canonical encoding).
                if s1 & 0x0F != 0 {
                    return None;
                }
            }
            (c2, b'=') => {
                let s2 = sextet(c2)?;
                if s2 & 0x03 != 0 {
                    return None; // non-canonical trailing bits
                }
                out.push((s1 << 4) | (s2 >> 2));
            }
            (c2, c3) => {
                let s2 = sextet(c2)?;
                let s3 = sextet(c3)?;
                out.push((s1 << 4) | (s2 >> 2));
                out.push((s2 << 6) | s3);
            }
        }
    }
    Some(out)
}

/// Map one Base64 alphabet byte to its 6-bit value; `None` for any byte
/// outside `A-Za-z0-9+/`.
fn sextet(b: u8) -> Option<u8> {
    match b {
        b'A'..=b'Z' => Some(b - b'A'),
        b'a'..=b'z' => Some(b - b'a' + 26),
        b'0'..=b'9' => Some(b - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::decode;

    /// A tiny reference encoder so the tests assert against independent
    /// golden vectors (and round-trips).
    fn encode(input: &[u8]) -> String {
        const ALPHA: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for chunk in input.chunks(3) {
            let b0 = chunk[0];
            let b1 = chunk.get(1).copied().unwrap_or(0);
            let b2 = chunk.get(2).copied().unwrap_or(0);
            out.push(ALPHA[(b0 >> 2) as usize] as char);
            out.push(ALPHA[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
            if chunk.len() > 1 {
                out.push(ALPHA[(((b1 & 0x0F) << 2) | (b2 >> 6)) as usize] as char);
            } else {
                out.push('=');
            }
            if chunk.len() > 2 {
                out.push(ALPHA[(b2 & 0x3F) as usize] as char);
            } else {
                out.push('=');
            }
        }
        out
    }

    #[test]
    fn known_vectors() {
        // RFC 4648 §10 test vectors.
        assert_eq!(decode("").unwrap(), b"");
        assert_eq!(decode("Zg==").unwrap(), b"f");
        assert_eq!(decode("Zm8=").unwrap(), b"fo");
        assert_eq!(decode("Zm9v").unwrap(), b"foo");
        assert_eq!(decode("Zm9vYg==").unwrap(), b"foob");
        assert_eq!(decode("Zm9vYmE=").unwrap(), b"fooba");
        assert_eq!(decode("Zm9vYmFy").unwrap(), b"foobar");
    }

    #[test]
    fn round_trips_arbitrary_bytes() {
        for len in 0..=64usize {
            let bytes: Vec<u8> = (0..len)
                .map(|i| u8::try_from(i).unwrap().wrapping_mul(37))
                .collect();
            let encoded = encode(&bytes);
            assert_eq!(
                decode(&encoded).as_deref(),
                Some(bytes.as_slice()),
                "len {len}"
            );
        }
    }

    #[test]
    fn rejects_malformed_input() {
        assert!(decode("Zg=").is_none()); // length not a multiple of 4
        assert!(decode("Zm9vYg=").is_none()); // ditto
        assert!(decode("Zm9v====").is_none()); // too much padding
        assert!(decode("Z===").is_none()); // padding in position 2
        assert!(decode("Zg==Zg==").is_none()); // padding before the final quad
        assert!(decode("Zm@v").is_none()); // illegal character
        assert!(decode("Zm 9").is_none()); // embedded whitespace
                                           // Non-canonical trailing bits (the encoded byte sets bits that a
                                           // 1-byte group must leave zero).
        assert!(decode("Zh==").is_none());
    }
}

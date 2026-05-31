// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Verdict enum mirroring the wire-format byte discriminator.
//!
//! See `docs/abi.md` §10 for the canonical wire-format table.
//! Mirrors `knomosis-l1-ingest/src/submitter.rs::Verdict` byte-for-byte
//! so the two crates form a closed contract.
//!
//! ## `Verdict::Ok` and the admission-stage ladder
//!
//! In the single-sequencer model the host's MVP targets, `Ok`
//! unambiguously means "the kernel admitted the action and the L2
//! state has advanced."  In a future decentralized-sequencing
//! deployment the wire byte alone can no longer convey *which*
//! stage of the pipeline the action has reached — the canonical
//! ordering might be agreed by consensus seconds after the local
//! kernel's admission predicate fires, and L1 finalization
//! follows minutes after that.
//!
//! Rather than overloading the wire byte, knomosis-host expresses the
//! stage ladder via the typed [`crate::admission::AdmissionStage`]
//! enum and lets each kernel declare its
//! [`crate::kernel::Kernel::ok_admission_stage`]:
//!
//!   * **Centralized kernels** (`MockKernel`, `CommandKernel`)
//!     declare `Finalized` — `Verdict::Ok` means "no further
//!     state transitions can change this action's outcome under
//!     the deployment's trust model."
//!   * **Future consensus kernels** declare `Sequenced` or
//!     `LocallyAdmitted` — `Verdict::Ok` means "this kernel's
//!     view is consistent up through the declared stage, but
//!     finer stages may follow asynchronously."
//!
//! Clients that need finer-grained progress subscribe via the
//! future RH-D event-subscription protocol; clients that read a
//! single byte and disconnect (the MVP pattern) continue to see
//! the same wire format with no protocol-version change required.

/// Verdict returned by the host's kernel.  Mirrors the planned
/// wire-format byte discriminator:
///
/// | Byte | Variant         | Semantics                                                                    |
/// |------|-----------------|------------------------------------------------------------------------------|
/// | 0    | `Ok`            | Kernel admitted the action; state advanced through at least its declared stage. |
/// | 1    | `NotAdmissible` | Kernel rejected the action (precondition false, policy denied).             |
/// | 2    | `ParseError`    | The CBE bytes could not be decoded as a `SignedAction`.                     |
/// | 3    | `Busy`          | Host's worker queue full; retry with backoff.  RH-C.4 new.                  |
///
/// **Stage attribution for `Ok`.**  The wire byte does not encode
/// the stage; the kernel that produced it declares
/// [`crate::kernel::Kernel::ok_admission_stage`].  Centralized
/// kernels declare `Finalized` (the wire `Ok` means fully
/// canonical); future consensus kernels declare `Sequenced` or
/// `LocallyAdmitted`.  Operators read the stage in `tracing` logs;
/// future clients query it via RH-D's `getInfo` preamble.  This
/// keeps the wire byte stable across deployment models.
///
/// The numeric encoding is part of the wire-format contract;
/// changing it requires a `docs/abi.md` §10 amendment and a
/// coordinated bump of the [`crate::PROTOCOL_VERSION`] constant.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
#[repr(u8)]
pub enum Verdict {
    /// Action admitted by the kernel.  The kernel's
    /// [`crate::kernel::Kernel::ok_admission_stage`] declares the
    /// precise stage reached (`LocallyAdmitted`, `Sequenced`, or
    /// `Finalized`).  In the centralized MVP deployment this is
    /// always `Finalized`; in future decentralized deployments
    /// the stage is configurable.
    Ok = 0,
    /// Action rejected: precondition false, policy denied, nonce
    /// mismatch, or any other §8.2 admissibility-clause failure.
    /// Terminal (no further stage transitions possible) under
    /// the kernel's current view.
    NotAdmissible = 1,
    /// CBE bytes failed to decode as a `SignedAction`.  Indicates
    /// either a malformed client request or a protocol-version
    /// drift between the client and host.
    ParseError = 2,
    /// Host's worker queue is full.  The client should back off
    /// and retry; the verdict carries no admissibility information.
    /// RH-C.4 introduces this variant; clients prior to RH-C may
    /// not recognise the byte.
    Busy = 3,
}

impl Verdict {
    /// Decode from the wire-format byte.  Returns `None` for
    /// unrecognised values.
    ///
    /// Used by clients (e.g. `knomosis-l1-ingest`'s submitter) when
    /// reading the host's response byte; recognised values map to
    /// the corresponding variant.
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

    /// Human-readable name suitable for logs.  Stable; do not
    /// change without a `tracing` consumer update.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::NotAdmissible => "not_admissible",
            Self::ParseError => "parse_error",
            Self::Busy => "busy",
        }
    }
}

/// A full response payload: a verdict byte plus an optional
/// human-readable reason.  The wire format is:
///
/// ```text
/// | 1 byte: verdict | 4 bytes BE: reason length M | M bytes: UTF-8 reason |
/// ```
///
/// When `reason` is empty, the trailing length is `0` and no
/// payload bytes follow.  This is symmetric to the request frame
/// in [`crate::frame`], so both sides of the wire use identical
/// length-prefix discipline.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerdictResponse {
    /// The kernel's verdict.
    pub verdict: Verdict,
    /// Optional human-readable reason.  May be empty.  UTF-8.
    pub reason: String,
}

impl VerdictResponse {
    /// Construct from a verdict with an empty reason.  Convenience
    /// constructor for the common case.
    #[must_use]
    pub fn from_verdict(verdict: Verdict) -> Self {
        Self {
            verdict,
            reason: String::new(),
        }
    }

    /// Construct from a verdict + reason pair.
    #[must_use]
    pub fn with_reason(verdict: Verdict, reason: impl Into<String>) -> Self {
        Self {
            verdict,
            reason: reason.into(),
        }
    }

    /// Encode this response to the wire format.  Returns the
    /// `1 + 4 + reason.len()` byte buffer ready for writing to a
    /// `Write` impl.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let reason_bytes = self.reason.as_bytes();
        // Total = verdict byte + 4-byte length prefix + reason payload.
        let mut out = Vec::with_capacity(1 + 4 + reason_bytes.len());
        out.push(self.verdict.to_byte());
        // Wire-format length prefix is a u32, so reasons longer
        // than `u32::MAX` bytes can't fit.  Saturate the declared
        // length (rather than panicking) so a misbehaving kernel
        // emitting a multi-gigabyte reason degrades gracefully.
        let reason_len_u32 = u32::try_from(reason_bytes.len()).unwrap_or(u32::MAX);
        // Bound the actually-emitted payload to the declared length
        // so the wire stays self-consistent in the saturation case.
        // On a 64-bit host with `reason_bytes.len() > u32::MAX`:
        //   declared = u32::MAX,
        //   emit_len = u32::MAX as usize,
        //   emit_len.min(reason_bytes.len()) = u32::MAX,
        // so we emit exactly the first 4 GiB.  On any
        // realistic-length reason (≤ u32::MAX), emit_len ==
        // reason_bytes.len() and the `.min` is a no-op.
        let emit_len = reason_len_u32 as usize;
        out.extend_from_slice(&reason_len_u32.to_be_bytes());
        out.extend_from_slice(&reason_bytes[..emit_len.min(reason_bytes.len())]);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::{Verdict, VerdictResponse};

    /// `Verdict::from_byte` round-trips through `to_byte` for every
    /// named variant.
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
        for b in 4u8..=255 {
            assert_eq!(Verdict::from_byte(b), None);
        }
    }

    /// `Verdict::to_byte` matches the documented wire-format table.
    #[test]
    fn verdict_byte_table() {
        assert_eq!(Verdict::Ok.to_byte(), 0);
        assert_eq!(Verdict::NotAdmissible.to_byte(), 1);
        assert_eq!(Verdict::ParseError.to_byte(), 2);
        assert_eq!(Verdict::Busy.to_byte(), 3);
    }

    /// Names are stable / non-empty.
    #[test]
    fn verdict_names_stable() {
        assert_eq!(Verdict::Ok.name(), "ok");
        assert_eq!(Verdict::NotAdmissible.name(), "not_admissible");
        assert_eq!(Verdict::ParseError.name(), "parse_error");
        assert_eq!(Verdict::Busy.name(), "busy");
    }

    /// `VerdictResponse::from_verdict` produces an empty reason.
    #[test]
    fn response_from_verdict_empty_reason() {
        let r = VerdictResponse::from_verdict(Verdict::Ok);
        assert_eq!(r.verdict, Verdict::Ok);
        assert!(r.reason.is_empty());
    }

    /// `VerdictResponse::with_reason` carries the reason text.
    #[test]
    fn response_with_reason() {
        let r = VerdictResponse::with_reason(Verdict::NotAdmissible, "nonce mismatch");
        assert_eq!(r.verdict, Verdict::NotAdmissible);
        assert_eq!(r.reason, "nonce mismatch");
    }

    /// Empty-reason response encodes to 5 bytes (1 verdict + 4
    /// zero-length prefix).
    #[test]
    fn encode_empty_reason() {
        let r = VerdictResponse::from_verdict(Verdict::Ok);
        let bytes = r.encode();
        assert_eq!(bytes, vec![0u8, 0, 0, 0, 0]);
    }

    /// Non-empty-reason response encodes verdict + length + UTF-8.
    #[test]
    fn encode_non_empty_reason() {
        let r = VerdictResponse::with_reason(Verdict::NotAdmissible, "bad");
        let bytes = r.encode();
        // 1 byte verdict (0x01) + 4-byte length BE (0x00000003) +
        // 3 bytes "bad" ASCII.
        assert_eq!(bytes, vec![0x01, 0x00, 0x00, 0x00, 0x03, b'b', b'a', b'd']);
    }

    /// Wire self-consistency at the u32::MAX-byte boundary:
    /// the declared length field MUST equal the actual emitted
    /// payload length, regardless of reason size.  This is the
    /// load-bearing invariant a streaming client relies on:
    /// "consume `declared` bytes, then expect either another
    /// frame or EOF."  For a 5 GiB reason (the saturation case),
    /// we'd declare 4 GiB and emit 4 GiB.  For a reason ≤ u32::MAX,
    /// declared == reason.len() and we emit reason.len().
    ///
    /// We can't actually allocate 5 GiB in a test, so we drive
    /// the invariant for reasons up to a few hundred kilobytes,
    /// plus the boundary case where reason.len() is well within
    /// u32::MAX.  The 5-GiB saturation case is documented but
    /// untested (allocating 5 GiB on a CI host is prohibitive);
    /// the encode() function's `.min(reason_bytes.len())` clause
    /// is the load-bearing line that enforces the property by
    /// construction.
    #[test]
    fn encode_declared_length_equals_emitted_payload_for_realistic_sizes() {
        // Test reasons of varied sizes well below u32::MAX.
        for &n in &[0usize, 1, 10, 1024, 65_536, 1_048_576] {
            let reason = "x".repeat(n);
            let r = VerdictResponse::with_reason(Verdict::NotAdmissible, reason);
            let bytes = r.encode();
            assert!(bytes.len() >= 5, "response too short: len={}", bytes.len());
            let declared = u32::from_be_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize;
            let emitted = bytes.len() - 5;
            assert_eq!(
                declared, emitted,
                "wire desync at reason.len()={n}: declared={declared}, emitted={emitted}"
            );
        }
    }

    /// UTF-8 reasons round-trip in the payload.
    #[test]
    fn encode_utf8_reason() {
        let r = VerdictResponse::with_reason(Verdict::ParseError, "тест"); // Cyrillic
        let bytes = r.encode();
        // verdict (0x02) + 4-byte length BE + "тест" UTF-8 bytes.
        let payload = "тест".as_bytes();
        assert_eq!(bytes[0], 0x02);
        let len = u32::from_be_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize;
        assert_eq!(len, payload.len());
        assert_eq!(&bytes[5..], payload);
    }

    /// `Verdict` is `Send + Sync + Copy`.
    #[test]
    fn verdict_is_send_sync_copy() {
        fn assert_send_sync_copy<T: Send + Sync + Copy>() {}
        assert_send_sync_copy::<Verdict>();
    }

    /// `VerdictResponse` is `Send + Sync`.
    #[test]
    fn response_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<VerdictResponse>();
    }

    /// All variants are distinct numeric values.
    #[test]
    fn variants_distinct() {
        let bytes: Vec<u8> = [
            Verdict::Ok,
            Verdict::NotAdmissible,
            Verdict::ParseError,
            Verdict::Busy,
        ]
        .iter()
        .map(|v| v.to_byte())
        .collect();
        let mut sorted = bytes.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), bytes.len());
    }
}

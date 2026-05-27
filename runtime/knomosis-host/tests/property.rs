// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Property-based tests for `knomosis-host`.
//!
//! Uses `proptest` to fuzz the wire-frame parser, verdict
//! encoding, and queue invariants over randomly-generated inputs.

use knomosis_host::frame::{encode_frame, read_frame, FrameError, DEFAULT_MAX_FRAME_SIZE};
use knomosis_host::queue::{drain_one, BoundedQueue, DrainOutcome, SubmitOutcome};
use knomosis_host::verdict::{Verdict, VerdictResponse};
use proptest::prelude::*;
use std::io::Cursor;
use std::time::Duration;

proptest! {
    /// Any non-empty payload round-trips through encode/read.
    #[test]
    fn frame_roundtrip(payload in proptest::collection::vec(any::<u8>(), 1..=4096)) {
        let bytes = encode_frame(&payload).unwrap();
        let mut cursor = Cursor::new(bytes);
        let decoded = read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        prop_assert_eq!(decoded, payload);
    }

    /// `read_frame` never panics on arbitrary input, regardless of
    /// content.  The function must surface every error path as a
    /// typed `FrameError`.
    #[test]
    fn read_frame_never_panics_on_arbitrary_input(bytes in proptest::collection::vec(any::<u8>(), 0..=8192)) {
        let mut cursor = Cursor::new(bytes);
        // Result is irrelevant; we're testing absence of panic.
        let _ = read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE);
    }

    /// Truncating any single byte after a valid frame's encoding
    /// always yields an `Err`, never a successful but smaller
    /// payload.
    #[test]
    fn truncation_always_errors(
        payload in proptest::collection::vec(any::<u8>(), 1..=512),
    ) {
        let bytes = encode_frame(&payload).unwrap();
        for cut in 0..bytes.len() {
            let mut cursor = Cursor::new(&bytes[..cut]);
            let result = read_frame(&mut cursor, DEFAULT_MAX_FRAME_SIZE);
            prop_assert!(
                result.is_err(),
                "truncated to {} bytes was accepted",
                cut
            );
        }
    }

    /// A declared length > max_frame_size is always rejected
    /// with `OversizeFrame`, never read.
    #[test]
    fn oversize_always_rejected(
        max_frame_size in 1usize..=4096,
        oversize_factor in 2u32..=4,
    ) {
        let oversize_len = (max_frame_size as u32) * oversize_factor;
        let bytes = oversize_len.to_be_bytes();
        let mut cursor = Cursor::new(&bytes[..]);
        match read_frame(&mut cursor, max_frame_size) {
            Err(FrameError::OversizeFrame { declared_length, max }) => {
                prop_assert_eq!(declared_length, oversize_len);
                prop_assert_eq!(max, max_frame_size);
            }
            other => prop_assert!(false, "expected OversizeFrame, got {:?}", other),
        }
    }

    /// Verdict round-trip: from_byte ∘ to_byte = identity for
    /// every defined variant.
    #[test]
    fn verdict_round_trip(b in 0u8..=3) {
        let v = Verdict::from_byte(b).unwrap();
        prop_assert_eq!(v.to_byte(), b);
    }

    /// Verdict::from_byte returns None for any out-of-range byte.
    #[test]
    fn verdict_out_of_range_returns_none(b in 4u8..=255) {
        prop_assert!(Verdict::from_byte(b).is_none());
    }

    /// VerdictResponse encoding is deterministic: two encodes
    /// produce identical bytes.
    #[test]
    fn verdict_response_encoding_deterministic(
        verdict_byte in 0u8..=3,
        reason in proptest::string::string_regex("[a-zA-Z0-9 ]{0,256}").unwrap(),
    ) {
        let verdict = Verdict::from_byte(verdict_byte).unwrap();
        let response = VerdictResponse::with_reason(verdict, &reason);
        let bytes1 = response.encode();
        let bytes2 = response.encode();
        prop_assert_eq!(bytes1, bytes2);
    }

    /// VerdictResponse encoding has the documented prefix layout.
    #[test]
    fn verdict_response_prefix_layout(
        verdict_byte in 0u8..=3,
        reason in proptest::string::string_regex("[a-zA-Z0-9 ]{0,256}").unwrap(),
    ) {
        let verdict = Verdict::from_byte(verdict_byte).unwrap();
        let response = VerdictResponse::with_reason(verdict, &reason);
        let bytes = response.encode();
        // First byte = verdict
        prop_assert_eq!(bytes[0], verdict_byte);
        // Next 4 bytes = BE length
        let len = u32::from_be_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize;
        prop_assert_eq!(len, reason.len());
        // Trailing bytes = reason
        prop_assert_eq!(&bytes[5..], reason.as_bytes());
    }

    /// Bounded queue with capacity N admits exactly N submissions
    /// before producing Busy (when no worker drains).
    #[test]
    fn queue_capacity_admits_exactly_n(capacity in 1usize..=32) {
        let (queue, _rx) = BoundedQueue::new(capacity);
        let mut enqueued = 0;
        for _ in 0..(capacity + 5) {
            match queue.try_submit(vec![0u8]) {
                SubmitOutcome::Enqueued(_) => enqueued += 1,
                SubmitOutcome::Busy => break,
            }
        }
        prop_assert_eq!(enqueued, capacity);
    }

    /// Drain after enqueue: every enqueued item is dispatched
    /// exactly once.
    #[test]
    fn drain_dispatches_every_enqueue(n in 1usize..=16) {
        let (queue, rx) = BoundedQueue::new(n + 4);
        let mut reply_rxs = Vec::with_capacity(n);
        for i in 0..n {
            if let SubmitOutcome::Enqueued(reply_rx) = queue.try_submit(vec![i as u8]) {
                reply_rxs.push(reply_rx);
            }
        }
        // Drain n requests.
        let mut dispatched = 0;
        for _ in 0..n {
            match drain_one(&rx, Duration::from_millis(10), |_| {
                knomosis_host::kernel::KernelResponse::from_verdict(Verdict::Ok)
            }) {
                DrainOutcome::Dispatched => dispatched += 1,
                _ => break,
            }
        }
        prop_assert_eq!(dispatched, n);
        // Every reply receiver gets exactly one response.
        for rx in reply_rxs {
            let r = rx.recv_timeout(Duration::from_millis(100));
            prop_assert!(r.is_ok());
        }
    }

    /// VerdictResponse with non-UTF-8-safe reason (lossy hex)
    /// still encodes to a valid byte sequence.  The length prefix
    /// always equals the actual emitted byte count.
    #[test]
    fn verdict_response_length_matches_payload(
        verdict_byte in 0u8..=3,
        reason_bytes in proptest::collection::vec(any::<u8>(), 0..=256),
    ) {
        // String::from_utf8_lossy preserves UTF-8 sequences and
        // replaces invalid ones with the replacement character.
        let reason = String::from_utf8_lossy(&reason_bytes).into_owned();
        let response = VerdictResponse::with_reason(
            Verdict::from_byte(verdict_byte).unwrap(),
            &reason,
        );
        let bytes = response.encode();
        let declared = u32::from_be_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize;
        prop_assert_eq!(declared, bytes.len() - 5);
        prop_assert_eq!(declared, reason.as_bytes().len());
    }
}

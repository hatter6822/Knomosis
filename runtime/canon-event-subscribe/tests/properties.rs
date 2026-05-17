// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Property tests for `canon-event-subscribe`.
//!
//! These tests use `proptest` to sweep arbitrary inputs through
//! the wire-frame parser and the event cache, verifying:
//!
//!   * The parser never panics on arbitrary bytes.
//!   * Frame round-trip: encode then decode is the identity on
//!     well-formed inputs.
//!   * Cache invariants: oldest_seq ≤ newest_seq; len ≤ capacity.
//!   * Range correctness: every `InWindow` outcome contains only
//!     events with seq > from_seq AND seq ≤ newest_seq.

use canon_event_subscribe::event_cache::{CachedEvent, EventCache, RangeOutcome};
use canon_event_subscribe::frame::{
    encode_inbound, encode_outbound, read_inbound, read_outbound, InboundFrame, OutboundFrame,
    DEFAULT_MAX_FRAME_SIZE,
};
use proptest::prelude::*;
use std::io::Cursor;

proptest! {
    /// Inbound parser never panics on arbitrary bytes.
    #[test]
    fn parser_inbound_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..64)) {
        let mut cursor = Cursor::new(bytes);
        let _ = read_inbound(&mut cursor);
    }

    /// Outbound parser never panics on arbitrary bytes.
    #[test]
    fn parser_outbound_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..64)) {
        let mut cursor = Cursor::new(bytes);
        let _ = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE);
    }

    /// SUBSCRIBE round-trip: encode_inbound followed by read_inbound
    /// returns the original frame.
    #[test]
    fn subscribe_round_trip(resume_from in any::<u64>()) {
        let frame = InboundFrame::Subscribe { resume_from };
        let bytes = encode_inbound(&frame);
        let mut cursor = Cursor::new(bytes);
        let decoded = read_inbound(&mut cursor).unwrap();
        prop_assert_eq!(decoded, frame);
    }

    /// EVENT round-trip on bounded payload.
    #[test]
    fn event_round_trip(
        seq in any::<u64>(),
        payload in proptest::collection::vec(any::<u8>(), 0..1024)
    ) {
        let frame = OutboundFrame::Event { seq, payload: payload.clone() };
        let bytes = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        let mut cursor = Cursor::new(bytes);
        let decoded = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        prop_assert_eq!(decoded, frame);
    }

    /// LAG_EXCEEDED / TRUNCATED / SERVER_SHUTDOWN / INVALID_REQUEST
    /// round-trip on arbitrary u64.
    #[test]
    fn control_frames_round_trip(seq in any::<u64>()) {
        for frame in [
            OutboundFrame::LagExceeded { last_delivered_seq: seq },
            OutboundFrame::Truncated { oldest_available_seq: seq },
            OutboundFrame::ServerShutdown { last_delivered_seq: seq },
        ] {
            let bytes = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
            let mut cursor = Cursor::new(bytes);
            let decoded = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
            prop_assert_eq!(decoded, frame);
        }
        // InvalidRequest carries no payload-state.
        let frame = OutboundFrame::InvalidRequest;
        let bytes = encode_outbound(&frame, DEFAULT_MAX_FRAME_SIZE).unwrap();
        let mut cursor = Cursor::new(bytes);
        let decoded = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE).unwrap();
        prop_assert_eq!(decoded, frame);
    }

    /// Cache invariants: oldest_seq ≤ newest_seq; len ≤ capacity.
    #[test]
    fn cache_invariants_hold_under_random_pushes(
        capacity in 1usize..32,
        seqs in proptest::collection::vec(1u64..1024, 0..50),
    ) {
        let mut cache = EventCache::new(capacity).unwrap();
        let mut last_pushed = 0u64;
        // Filter to strictly-monotonic sequence (the cache requires it).
        let monotonic: Vec<u64> = seqs.into_iter().filter(|s| {
            if *s > last_pushed {
                last_pushed = *s;
                true
            } else {
                false
            }
        }).collect();

        for s in &monotonic {
            cache.push(CachedEvent { seq: *s, payload: vec![] }).unwrap();
        }
        prop_assert!(cache.len() <= capacity);
        if !cache.is_empty() {
            let oldest = cache.oldest_seq().unwrap();
            let newest = cache.newest_seq().unwrap();
            prop_assert!(oldest <= newest);
        }
    }

    /// Range correctness: `InWindow { events }` ⇒ every event's
    /// seq > from_seq AND ≤ newest_seq.  Returned events are in
    /// strictly-increasing seq order.
    #[test]
    fn cache_range_returns_strictly_increasing_seqs_above_from(
        capacity in 5usize..20,
        n_events in 0usize..30,
        from_seq in 0u64..100,
    ) {
        let mut cache = EventCache::new(capacity).unwrap();
        for s in 1..=(n_events as u64) {
            cache.push(CachedEvent { seq: s, payload: vec![] }).unwrap();
        }
        match cache.range(from_seq) {
            RangeOutcome::InWindow { events } => {
                let mut prev = 0u64;
                for e in &events {
                    prop_assert!(e.seq > from_seq, "InWindow event seq must be > from_seq");
                    prop_assert!(e.seq > prev, "events must be strictly increasing");
                    prev = e.seq;
                }
                if let Some(newest) = cache.newest_seq() {
                    for e in &events {
                        prop_assert!(e.seq <= newest);
                    }
                }
            }
            RangeOutcome::OutOfWindow { oldest_available_seq } => {
                // For OutOfWindow: from_seq + 1 < oldest_available.
                prop_assert!(from_seq.saturating_add(1) < oldest_available_seq);
            }
            RangeOutcome::AtLiveTail => {
                // For AtLiveTail: either cache is empty OR
                // from_seq >= newest_seq OR from_seq == 0.
                let cond = cache.is_empty()
                    || from_seq == 0
                    || cache.newest_seq().is_some_and(|n| from_seq >= n);
                prop_assert!(cond);
            }
        }
    }

    /// Truncated EVENT frames don't allocate huge buffers.  The
    /// parser must reject payloads exceeding `max_payload` before
    /// allocating.
    #[test]
    fn parser_rejects_oversize_event_length(
        seq in any::<u64>(),
        oversize_length in (DEFAULT_MAX_FRAME_SIZE as u32 + 1)..u32::MAX,
    ) {
        let mut bytes = Vec::new();
        bytes.push(canon_event_subscribe::frame::KIND_EVENT);
        bytes.extend_from_slice(&seq.to_be_bytes());
        bytes.extend_from_slice(&oversize_length.to_be_bytes());
        let mut cursor = Cursor::new(bytes);
        let start = std::time::Instant::now();
        let result = read_outbound(&mut cursor, DEFAULT_MAX_FRAME_SIZE);
        let elapsed = start.elapsed();
        prop_assert!(elapsed.as_millis() < 100);
        let is_oversize = matches!(
            result,
            Err(canon_event_subscribe::frame::FrameError::OversizeFrame { .. })
        );
        prop_assert!(is_oversize);
    }
}

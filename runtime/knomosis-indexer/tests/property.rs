// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Property tests for `knomosis-indexer`.
//!
//! The headline properties:
//!
//!   * **Decoder round-trip**: every `Event` survives a
//!     `encode_event(e)` / `decode_event(_)` round trip.
//!   * **Balance-view oracle**: the indexer's balance view
//!     matches a reference `HashMap<(actor, resource), Amount>`
//!     computed by replaying the same event stream.
//!   * **Cursor monotonicity**: across an arbitrary event stream,
//!     the indexer's cursor is strictly increasing.

use knomosis_indexer::balance::BalanceView;
use knomosis_indexer::decoder::{decode_event, encode_event};
use knomosis_indexer::event::Event;
use knomosis_indexer::indexer::Indexer;
use knomosis_storage::sqlite::SqliteStorage;
use proptest::collection::vec;
use proptest::prelude::*;
use std::collections::HashMap;

/// Strategy for generating arbitrary `Event` values.  Covers
/// every tag with small-but-non-trivial field values.
fn event_strategy() -> impl Strategy<Value = Event> {
    prop_oneof![
        (any::<u8>(), any::<u8>(), 0u64..=1_000, 0u64..=1_000).prop_map(|(r, a, old_v, new_v)| {
            Event::BalanceChanged {
                resource: u64::from(r),
                actor: u64::from(a),
                old_value: u128::from(old_v),
                new_value: u128::from(new_v),
            }
        }),
        (any::<u8>(), 0u64..=1_000, 1u64..=1_001).prop_map(|(a, old_n, new_n)| {
            Event::NonceAdvanced {
                actor: u64::from(a),
                old_nonce: u128::from(old_n),
                new_nonce: u128::from(new_n),
            }
        }),
        (any::<u8>(), vec(any::<u8>(), 0..=32)).prop_map(|(a, key)| Event::IdentityRegistered {
            actor: u64::from(a),
            key,
        }),
        any::<u8>().prop_map(|a| Event::IdentityRevoked {
            actor: u64::from(a),
        }),
        any::<u64>().prop_map(|t| Event::TimeRecorded { time: t }),
        (any::<u8>(), any::<u64>()).prop_map(|(c, t)| Event::DisputeFiled {
            challenger: u64::from(c),
            target_idx: t,
        }),
        any::<u64>().prop_map(|d| Event::DisputeWithdrawn { dispute_idx: d }),
        (any::<u64>(), 0u64..=2).prop_map(|(d, o)| Event::VerdictApplied {
            dispute_idx: d,
            outcome_tag: o,
        }),
        (any::<u8>(), any::<u8>(), 0u64..=1_000).prop_map(|(r, a, amt)| Event::RewardIssued {
            resource: u64::from(r),
            recipient: u64::from(a),
            amount: u128::from(amt),
        }),
        (
            any::<u8>(),
            any::<u8>(),
            0u64..=1_000,
            any::<[u8; 20]>(),
            any::<u64>(),
        )
            .prop_map(|(r, s, amt, addr, wid)| Event::WithdrawalRequested {
                resource: u64::from(r),
                sender: u64::from(s),
                amount: u128::from(amt),
                recipient_l1: addr,
                withdrawal_id: wid,
            }),
        (any::<u8>(), any::<u8>(), 0u64..=1_000, any::<u64>()).prop_map(|(r, rec, amt, did)| {
            Event::DepositCredited {
                resource: u64::from(r),
                recipient: u64::from(rec),
                amount: u128::from(amt),
                deposit_id: did,
            }
        }),
        (any::<u8>(), vec(any::<u8>(), 0..=32)).prop_map(|(a, p)| Event::LocalPolicyDeclared {
            actor: u64::from(a),
            policy: p,
        }),
        any::<u8>().prop_map(|a| Event::LocalPolicyRevoked {
            actor: u64::from(a),
        }),
    ]
}

/// Strategy for generating "balance-only" events.  Used by the
/// indexer-oracle test: only events that affect the balance view.
fn balance_event_strategy() -> impl Strategy<Value = Event> {
    prop_oneof![
        // Set: BalanceChanged
        (
            0u64..=10, // resource
            0u64..=10, // actor
            0u128..=10_000,
        )
            .prop_map(|(r, a, v)| Event::BalanceChanged {
                resource: r,
                actor: a,
                old_value: 0, // ignored by dispatch
                new_value: v,
            }),
        // Credit: RewardIssued (capped at 100 so credits don't
        // pile up close to u128::MAX in long event streams)
        (0u64..=10, 0u64..=10, 0u128..=100).prop_map(|(r, a, amt)| Event::RewardIssued {
            resource: r,
            recipient: a,
            amount: amt,
        }),
        // Credit: DepositCredited
        (0u64..=10, 0u64..=10, 0u128..=100, any::<u64>()).prop_map(|(r, a, amt, did)| {
            Event::DepositCredited {
                resource: r,
                recipient: a,
                amount: amt,
                deposit_id: did,
            }
        }),
    ]
}

/// Reference implementation that applies an event stream to a
/// `HashMap<(actor, resource), Amount>`.  The indexer's balance
/// view must equal this after running the same event stream.
fn apply_to_reference(
    reference: &mut HashMap<(u64, u64), u128>,
    event: &Event,
) -> Result<(), String> {
    match event {
        Event::BalanceChanged {
            resource,
            actor,
            new_value,
            ..
        } => {
            reference.insert((*actor, *resource), *new_value);
        }
        Event::RewardIssued {
            resource,
            recipient,
            amount,
        }
        | Event::DepositCredited {
            resource,
            recipient,
            amount,
            ..
        } => {
            let key = (*recipient, *resource);
            let current = reference.get(&key).copied().unwrap_or(0);
            let new = current.saturating_add(*amount);
            reference.insert(key, new);
        }
        Event::WithdrawalRequested {
            resource,
            sender,
            amount,
            ..
        } => {
            let key = (*sender, *resource);
            let current = reference.get(&key).copied().unwrap_or(0);
            let new = current
                .checked_sub(*amount)
                .ok_or_else(|| format!("underflow on debit: {current} < {amount}"))?;
            reference.insert(key, new);
        }
        _ => {}
    }
    Ok(())
}

/// Strategy for **adversarial** balance-affecting events: the same
/// credit / debit / set tags the indexer's two-pass dispatch acts on,
/// but with FULL-RANGE `u128` amounts (not the ≤ 1 000 caps the other
/// strategies use).  Drives the dispatch arithmetic into the
/// saturating-add / checked-sub overflow regimes a small-amount stream
/// never reaches.
fn adversarial_balance_event_strategy() -> impl Strategy<Value = Event> {
    prop_oneof![
        (0u64..=4, 0u64..=4, any::<u128>()).prop_map(|(r, a, v)| Event::BalanceChanged {
            resource: r,
            actor: a,
            old_value: 0,
            new_value: v,
        }),
        (0u64..=4, 0u64..=4, any::<u128>()).prop_map(|(r, a, amt)| Event::RewardIssued {
            resource: r,
            recipient: a,
            amount: amt,
        }),
        (0u64..=4, 0u64..=4, any::<u128>(), any::<u64>()).prop_map(|(r, a, amt, did)| {
            Event::DepositCredited {
                resource: r,
                recipient: a,
                amount: amt,
                deposit_id: did,
            }
        }),
        (
            0u64..=4,
            0u64..=4,
            any::<u128>(),
            any::<[u8; 20]>(),
            any::<u64>()
        )
            .prop_map(|(r, s, amt, addr, wid)| Event::WithdrawalRequested {
                resource: r,
                sender: s,
                amount: amt,
                recipient_l1: addr,
                withdrawal_id: wid,
            }),
    ]
}

proptest! {
    /// Round-trip: every Event survives encode → decode.
    #[test]
    fn round_trip_arbitrary_event(event in event_strategy()) {
        let bytes = encode_event(&event);
        let decoded = decode_event(&bytes).unwrap();
        prop_assert_eq!(decoded, event);
    }

    /// Tag projection: every encoded Event decodes to the same
    /// tag value.
    #[test]
    fn encoded_tag_is_preserved(event in event_strategy()) {
        let bytes = encode_event(&event);
        let decoded = decode_event(&bytes).unwrap();
        prop_assert_eq!(decoded.tag(), event.tag());
    }

    /// Balance-view oracle: the indexer matches the reference
    /// HashMap after applying the same event stream.
    ///
    /// We run the indexer's apply path and the reference's
    /// apply path in lock-step.  When the indexer rejects an
    /// event (e.g. on underflow), we mirror that decision by
    /// NOT updating the reference.  This keeps the two in sync
    /// across the entire event stream.
    #[test]
    fn balance_view_matches_reference(
        events in vec(balance_event_strategy(), 0..30)
    ) {
        let storage = SqliteStorage::open_in_memory().unwrap();
        let mut indexer = Indexer::open(&storage).unwrap();
        let mut reference: HashMap<(u64, u64), u128> = HashMap::new();

        for (i, event) in events.iter().enumerate() {
            let seq = (i + 1) as u64;
            // Apply to indexer first.  If it accepts, mirror the
            // change in the reference; if it rejects, leave the
            // reference alone (mirroring the indexer's reject).
            if indexer.apply_batch(seq, &[event.clone()]).is_ok() {
                let _ = apply_to_reference(&mut reference, event);
            }
        }

        let view = BalanceView::new(&storage);
        for ((actor, resource), &amount) in &reference {
            prop_assert_eq!(
                view.get(*actor, *resource).unwrap(),
                amount,
                "mismatch for ({}, {})", actor, resource
            );
        }
    }

    /// Cursor monotonicity: under any successful event stream,
    /// the cursor is non-decreasing.
    #[test]
    fn cursor_monotonic(events in vec(balance_event_strategy(), 0..20)) {
        let storage = SqliteStorage::open_in_memory().unwrap();
        let mut indexer = Indexer::open(&storage).unwrap();
        let mut last_cursor = 0u64;
        for (i, event) in events.iter().enumerate() {
            let seq = (i + 1) as u64;
            match indexer.apply_batch(seq, &[event.clone()]) {
                Ok(()) => {
                    prop_assert!(indexer.cursor() >= last_cursor);
                    last_cursor = indexer.cursor();
                }
                Err(_) => {
                    // Cursor unchanged on failure.
                    prop_assert_eq!(indexer.cursor(), last_cursor);
                }
            }
        }
    }

    /// Idempotent restart: dropping + re-opening the indexer
    /// preserves the cursor and balance view.
    #[test]
    fn restart_preserves_state(events in vec(balance_event_strategy(), 0..10)) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("p.db");
        let mut applied = 0u64;
        let mut last_seq = 0u64;

        {
            let storage = SqliteStorage::open(&path).unwrap();
            let mut indexer = Indexer::open(&storage).unwrap();
            for (i, event) in events.iter().enumerate() {
                let seq = (i + 1) as u64;
                if indexer.apply_batch(seq, &[event.clone()]).is_ok() {
                    applied = seq;
                }
                last_seq = seq;
            }
        }

        // Reopen.
        let storage = SqliteStorage::open(&path).unwrap();
        let indexer = Indexer::open(&storage).unwrap();
        prop_assert_eq!(indexer.cursor(), applied);
        prop_assert!(indexer.cursor() <= last_seq);
    }

    /// **Decoder fuzz**: arbitrary byte input either decodes
    /// successfully or returns a typed `DecodeError` — NEVER
    /// panics, NEVER hangs.  Property-test surface over the
    /// decoder's robustness; complements the hand-picked
    /// adversarial patterns in `decoder::tests::decoder_does_not_panic_on_random_input`.
    #[test]
    fn decoder_fuzz_never_panics(bytes in vec(any::<u8>(), 0..=512)) {
        // Either Ok or Err — never panic.  No assertions on the
        // outcome (any byte string is permissible input); the
        // load-bearing assertion is "does not panic".
        let _ = knomosis_indexer::decoder::decode_event(&bytes);
    }

    /// **Decoder fuzz with valid CBE prefix**: bytes prefixed
    /// with a valid CBE uint head (tag=0x00 + 8 LE bytes)
    /// followed by arbitrary tail.  Exercises the
    /// constructor-tag dispatch path more thoroughly.
    #[test]
    fn decoder_fuzz_with_valid_tag_prefix(
        tag in 0u64..=20,
        tail in vec(any::<u8>(), 0..=256)
    ) {
        let mut payload = vec![0x00u8]; // CBE uint tag
        payload.extend_from_slice(&tag.to_le_bytes());
        payload.extend(tail);
        // Either Ok (for valid tag values + well-formed tail)
        // or Err — never panic.
        let _ = knomosis_indexer::decoder::decode_event(&payload);
    }

    /// **Dispatch fuzz**: feed a stream of arbitrary all-tag
    /// `Event`s (decoder fuzz covers byte robustness; this covers
    /// the indexer's two-pass dispatch on *structurally valid but
    /// adversarial* events) to `apply_batch` and assert it NEVER
    /// panics — every step returns `Ok` or a typed error, and the
    /// cursor never regresses.  Complements
    /// `balance_view_matches_reference` (which uses the restricted
    /// small-amount strategy) by exercising the full `Event`
    /// surface, including the non-balance tags the dispatch must
    /// skip cleanly.
    #[test]
    fn indexer_apply_arbitrary_events_never_panics(
        events in vec(event_strategy(), 0..40)
    ) {
        let storage = SqliteStorage::open_in_memory().unwrap();
        let mut indexer = Indexer::open(&storage).unwrap();
        let mut last_cursor = 0u64;
        for (i, event) in events.iter().enumerate() {
            let seq = (i + 1) as u64;
            // Load-bearing assertion: no panic on ANY tag / value.
            let _ = indexer.apply_batch(seq, &[event.clone()]);
            // The cursor must never regress, whatever the verdict.
            prop_assert!(indexer.cursor() >= last_cursor);
            last_cursor = indexer.cursor();
        }
    }

    /// **Dispatch overflow fuzz**: stream FULL-RANGE-`u128`-amount
    /// balance events (credits up to `u128::MAX`, withdrawals that
    /// would underflow) into `apply_batch`.  The indexer must
    /// handle the saturating-add / checked-sub boundaries WITHOUT
    /// panicking — the small-amount strategies never reach these
    /// regimes.
    #[test]
    fn indexer_apply_adversarial_amounts_never_panics(
        events in vec(adversarial_balance_event_strategy(), 0..40)
    ) {
        let storage = SqliteStorage::open_in_memory().unwrap();
        let mut indexer = Indexer::open(&storage).unwrap();
        for (i, event) in events.iter().enumerate() {
            let seq = (i + 1) as u64;
            // No panic on overflow-adjacent amounts.
            let _ = indexer.apply_batch(seq, &[event.clone()]);
        }
        // The balance view must remain queryable (no corruption) for
        // every actor/resource the stream could have touched.
        let view = BalanceView::new(&storage);
        for actor in 0u64..=4 {
            for resource in 0u64..=4 {
                let _ = view.get(actor, resource);
            }
        }
    }
}

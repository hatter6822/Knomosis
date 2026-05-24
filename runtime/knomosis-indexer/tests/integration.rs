// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Integration tests for `knomosis-indexer`.
//!
//! These tests exercise the full library API: event decoder
//! → indexer dispatch → balance view → query.  Each test runs
//! against a fresh in-memory SQLite database so the per-test
//! state is isolated.

use knomosis_indexer::balance::BalanceView;
use knomosis_indexer::decoder::{decode_event, encode_event};
use knomosis_indexer::event::Event;
use knomosis_indexer::indexer::Indexer;
use knomosis_storage::sqlite::SqliteStorage;

/// End-to-end: encode events on the wire side, decode + dispatch,
/// query the balance view.  Mirrors the production pipeline.
#[test]
fn end_to_end_pipeline() {
    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();

    let events = [
        Event::BalanceChanged {
            resource: 1,
            actor: 100,
            old_value: 0,
            new_value: 500,
        },
        Event::BalanceChanged {
            resource: 1,
            actor: 200,
            old_value: 0,
            new_value: 300,
        },
        Event::BalanceChanged {
            resource: 2,
            actor: 100,
            old_value: 0,
            new_value: 1000,
        },
    ];

    // Encode each event, round-trip through the decoder, then
    // dispatch.  Each event is its own seq (1, 2, 3).
    for (i, event) in events.iter().enumerate() {
        let bytes = encode_event(event);
        let decoded = decode_event(&bytes).unwrap();
        assert_eq!(&decoded, event);
        indexer.apply_batch(i as u64 + 1, &[decoded]).unwrap();
    }

    // Query the balance view.
    let view = BalanceView::new(&storage);
    assert_eq!(view.get(100, 1).unwrap(), 500);
    assert_eq!(view.get(200, 1).unwrap(), 300);
    assert_eq!(view.get(100, 2).unwrap(), 1000);
    assert_eq!(indexer.cursor(), 3);
}

/// Restart simulation: write some events, drop the indexer,
/// reopen, write more events.  The cursor must persist + advance
/// correctly.
#[test]
fn restart_resumes_at_cursor() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("restart.db");

    {
        let storage = SqliteStorage::open(&path).unwrap();
        let mut indexer = Indexer::open(&storage).unwrap();
        for i in 1..=5u64 {
            indexer
                .apply_batch(
                    i,
                    &[Event::BalanceChanged {
                        resource: 1,
                        actor: i,
                        old_value: 0,
                        new_value: u128::from(i) * 100,
                    }],
                )
                .unwrap();
        }
        assert_eq!(indexer.cursor(), 5);
    }

    // Reopen.
    {
        let storage = SqliteStorage::open(&path).unwrap();
        let indexer = Indexer::open(&storage).unwrap();
        assert_eq!(indexer.cursor(), 5);
        let view = BalanceView::new(&storage);
        for i in 1..=5u64 {
            assert_eq!(view.get(i, 1).unwrap(), u128::from(i) * 100);
        }
    }

    // Continue writing.
    {
        let storage = SqliteStorage::open(&path).unwrap();
        let mut indexer = Indexer::open(&storage).unwrap();
        for i in 6..=10u64 {
            indexer
                .apply_batch(
                    i,
                    &[Event::BalanceChanged {
                        resource: 1,
                        actor: i,
                        old_value: 0,
                        new_value: u128::from(i) * 100,
                    }],
                )
                .unwrap();
        }
        assert_eq!(indexer.cursor(), 10);
    }
}

/// Multi-event batch (multiple events sharing a seq) commits
/// atomically.  Mirrors the production wire-protocol semantics
/// from §11.4 (a single log frame can produce multiple events,
/// all sharing the same seq).
#[test]
fn multi_event_per_seq() {
    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();

    // A single transfer in the kernel produces TWO balanceChanged
    // events (sender + receiver), both with the same seq.
    let batch = vec![
        Event::BalanceChanged {
            resource: 1,
            actor: 100, // sender
            old_value: 500,
            new_value: 400,
        },
        Event::BalanceChanged {
            resource: 1,
            actor: 200, // receiver
            old_value: 0,
            new_value: 100,
        },
    ];
    indexer.apply_batch(1, &batch).unwrap();

    let view = BalanceView::new(&storage);
    assert_eq!(view.get(100, 1).unwrap(), 400);
    assert_eq!(view.get(200, 1).unwrap(), 100);
    assert_eq!(indexer.cursor(), 1);
}

/// Underflow rolls back the entire batch (including any earlier
/// events in the same batch).
#[test]
fn underflow_rolls_back_batch() {
    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();

    // Seed with 50.
    indexer
        .apply_batch(
            1,
            &[Event::BalanceChanged {
                resource: 1,
                actor: 100,
                old_value: 0,
                new_value: 50,
            }],
        )
        .unwrap();

    // Batch: first event sets actor 200's balance to 999, then
    // tries to withdraw 100 from actor 100 (which has only 50).
    // The batch should roll back entirely.
    let batch = vec![
        Event::BalanceChanged {
            resource: 1,
            actor: 200,
            old_value: 0,
            new_value: 999,
        },
        Event::WithdrawalRequested {
            resource: 1,
            sender: 100,
            amount: 100,
            recipient_l1: [0; 20],
            withdrawal_id: 1,
        },
    ];
    let result = indexer.apply_batch(2, &batch);
    assert!(result.is_err());

    let view = BalanceView::new(&storage);
    // Actor 200's balance should NOT be 999 — the batch rolled back.
    assert_eq!(view.get(200, 1).unwrap(), 0);
    // Actor 100's balance unchanged.
    assert_eq!(view.get(100, 1).unwrap(), 50);
    // Cursor unchanged.
    assert_eq!(indexer.cursor(), 1);
}

/// Deposit + reward + transfer scenario.
#[test]
fn realistic_scenario() {
    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();

    // 1. Bridge credits actor 1 with 1000 of resource 0.
    indexer
        .apply_batch(
            1,
            &[
                Event::DepositCredited {
                    resource: 0,
                    recipient: 1,
                    amount: 1000,
                    deposit_id: 1,
                },
                // Kernel emits BalanceChanged too — overrides.
                Event::BalanceChanged {
                    resource: 0,
                    actor: 1,
                    old_value: 0,
                    new_value: 1000,
                },
            ],
        )
        .unwrap();

    // 2. Reward issued: 100 to actor 1.
    indexer
        .apply_batch(
            2,
            &[
                Event::RewardIssued {
                    resource: 0,
                    recipient: 1,
                    amount: 100,
                },
                Event::BalanceChanged {
                    resource: 0,
                    actor: 1,
                    old_value: 1000,
                    new_value: 1100,
                },
            ],
        )
        .unwrap();

    // 3. Transfer: 300 from actor 1 to actor 2.
    indexer
        .apply_batch(
            3,
            &[
                Event::BalanceChanged {
                    resource: 0,
                    actor: 1,
                    old_value: 1100,
                    new_value: 800,
                },
                Event::BalanceChanged {
                    resource: 0,
                    actor: 2,
                    old_value: 0,
                    new_value: 300,
                },
            ],
        )
        .unwrap();

    let view = BalanceView::new(&storage);
    assert_eq!(view.get(1, 0).unwrap(), 800);
    assert_eq!(view.get(2, 0).unwrap(), 300);
    assert_eq!(indexer.cursor(), 3);
}

/// Decoder round-trip for every event variant.
#[test]
fn decoder_round_trip_every_variant() {
    let events = vec![
        Event::BalanceChanged {
            resource: 1,
            actor: 2,
            old_value: 3,
            new_value: 4,
        },
        Event::NonceAdvanced {
            actor: 5,
            old_nonce: 0,
            new_nonce: 1,
        },
        Event::IdentityRegistered {
            actor: 6,
            key: vec![1, 2, 3],
        },
        Event::IdentityRevoked { actor: 7 },
        Event::TimeRecorded { time: 100 },
        Event::DisputeFiled {
            challenger: 8,
            target_idx: 9,
        },
        Event::DisputeWithdrawn { dispute_idx: 10 },
        Event::VerdictApplied {
            dispute_idx: 11,
            outcome_tag: 0,
        },
        Event::RewardIssued {
            resource: 12,
            recipient: 13,
            amount: 14,
        },
        Event::WithdrawalRequested {
            resource: 15,
            sender: 16,
            amount: 17,
            recipient_l1: [0xAB; 20],
            withdrawal_id: 18,
        },
        Event::DepositCredited {
            resource: 19,
            recipient: 20,
            amount: 21,
            deposit_id: 22,
        },
        Event::LocalPolicyDeclared {
            actor: 23,
            policy: vec![0xCD; 16],
        },
        Event::LocalPolicyRevoked { actor: 24 },
        Event::FaultProofGameOpened {
            game_id: 25,
            challenger: 26,
            disputed_start_idx: 27,
            disputed_end_idx: 28,
            binding_hash: vec![0xEF; 32],
        },
        Event::FaultProofBisectionStep {
            game_id: 29,
            round: 30,
            party: 31,
            idx: 32,
            commit: vec![0x12; 32],
        },
        Event::FaultProofGameSettled {
            game_id: 33,
            winner: 34,
            loser: 35,
            payout: 36,
        },
    ];
    assert_eq!(events.len(), 16);
    for e in &events {
        let bytes = encode_event(e);
        let decoded = decode_event(&bytes).unwrap();
        assert_eq!(&decoded, e);
    }
}

/// Mass-event test: 1000 events distributed across 100 actors.
#[test]
fn many_actors_many_events() {
    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();
    let mut expected: std::collections::HashMap<(u64, u64), u128> =
        std::collections::HashMap::new();

    for seq in 1..=100u64 {
        let mut batch = Vec::new();
        for actor_off in 0..10u64 {
            let actor = (seq + actor_off) % 100; // pseudo-random
            let resource = actor_off % 3;
            let new_value = u128::from(seq * 1000 + actor_off);
            batch.push(Event::BalanceChanged {
                resource,
                actor,
                old_value: expected.get(&(actor, resource)).copied().unwrap_or(0),
                new_value,
            });
            expected.insert((actor, resource), new_value);
        }
        indexer.apply_batch(seq, &batch).unwrap();
    }

    let view = BalanceView::new(&storage);
    for ((actor, resource), &amount) in &expected {
        assert_eq!(view.get(*actor, *resource).unwrap(), amount);
    }
    assert_eq!(indexer.cursor(), 100);
}

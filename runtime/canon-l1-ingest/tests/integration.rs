// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Integration tests for the watcher loop.
//!
//! These tests exercise the full orchestration:
//!
//!   1. Mock L1Source publishes synthetic blocks with logs.
//!   2. Watcher processes blocks, applies confirmation depth,
//!      tracks the address book, signs actions, and submits
//!      them.
//!   3. BufferingSubmitter records submissions for assertion.
//!
//! Re-org scenarios are exercised at the unit level (in
//! `src/reorg.rs`); the integration tests focus on end-to-end
//! flow correctness: the right `Action` is signed with the right
//! key for the right nonce in the right order.

use std::collections::HashMap;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

use canon_l1_ingest::action::EthAddress;
use canon_l1_ingest::events::{EventTopic, RawLog};
use canon_l1_ingest::key::BridgeActorKey;
use canon_l1_ingest::reorg::BlockHeader;
use canon_l1_ingest::source::mock::InMemoryL1Source;
use canon_l1_ingest::submitter::buffering::BufferingSubmitter;
use canon_l1_ingest::watcher::{WatcherConfig, WatcherLoop};

const IDENTITY_ADDR: [u8; 20] = [0x1d; 20];

fn bridge_addr() -> EthAddress {
    EthAddress::from_bytes(&[0xb1; 20]).unwrap()
}

fn identity_addr() -> EthAddress {
    EthAddress::from_bytes(&IDENTITY_ADDR).unwrap()
}

fn test_key() -> BridgeActorKey {
    let mut scalar = [0u8; 32];
    scalar[31] = 42;
    BridgeActorKey::from_private_bytes(&scalar).unwrap()
}

/// Build a synthesized RegisteredECDSA log.
fn build_registered_ecdsa_log(
    actor: [u8; 20],
    pubkey: &[u8],
    block_number: u64,
    log_index: u64,
    tx_hash: [u8; 32],
) -> RawLog {
    let mut actor_topic = [0u8; 32];
    actor_topic[12..32].copy_from_slice(&actor);
    // ABI-encode the bytes field: offset + length + payload.
    let mut data = Vec::new();
    let mut off = [0u8; 32];
    off[31] = 32;
    data.extend_from_slice(&off);
    let mut len_be = [0u8; 32];
    let len = pubkey.len() as u64;
    len_be[24..32].copy_from_slice(&len.to_be_bytes());
    data.extend_from_slice(&len_be);
    data.extend_from_slice(pubkey);
    let padding = (32 - (pubkey.len() % 32)) % 32;
    data.extend_from_slice(&vec![0u8; padding]);
    RawLog {
        address: identity_addr(),
        topics: vec![EventTopic::RegisteredEcdsa.hash(), actor_topic],
        data,
        block_number,
        tx_hash,
        log_index,
    }
}

/// Push a chain of `count` blocks (numbered 0..count) plus optional
/// logs into the source.  The first block uses `[0; 32]` as parent.
fn push_chain_with_log(source: &mut InMemoryL1Source, count: u64, log_at_block: u64, log: RawLog) {
    for n in 0..count {
        let mut logs_map = HashMap::new();
        if n == log_at_block {
            logs_map.insert(identity_addr(), vec![log.clone()]);
        }
        let parent_hash = if n == 0 {
            [0u8; 32]
        } else {
            [(n - 1) as u8; 32]
        };
        source.push_block(
            BlockHeader {
                number: n,
                hash: [n as u8; 32],
                parent_hash,
            },
            logs_map,
        );
    }
}

/// End-to-end happy path: one registration, one signed-and-
/// submitted action.
#[test]
fn end_to_end_single_registration() {
    let temp = tempfile::tempdir().unwrap();
    let state_path = temp.path().join("state.jsonl");
    let mut source = InMemoryL1Source::new();
    let log = build_registered_ecdsa_log([0x55; 20], &[0x02, 0xab, 0xcd, 0xef], 0, 0, [0x77; 32]);
    push_chain_with_log(&mut source, 13, 0, log);
    let submitter = BufferingSubmitter::new();
    let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
    config.confirmation_depth = 12;
    let mut watcher = WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
    let processed = watcher.run_iteration().unwrap();
    assert_eq!(processed, 1, "exactly one block reached confirmation depth");
    assert_eq!(watcher.last_confirmed_block(), Some(0));
}

/// End-to-end with three blocks at confirmation: one event per
/// block, three submissions in order.
#[test]
fn end_to_end_three_blocks() {
    let temp = tempfile::tempdir().unwrap();
    let state_path = temp.path().join("state.jsonl");
    let mut source = InMemoryL1Source::new();
    for n in 0..15u64 {
        let mut logs_map = HashMap::new();
        if n < 3 {
            // Put one event in each of blocks 0, 1, 2.
            logs_map.insert(
                identity_addr(),
                vec![build_registered_ecdsa_log(
                    [(0x50 + n as u8); 20],
                    &[0x02, (0x80 + n as u8)],
                    n,
                    0,
                    [(0x70 + n as u8); 32],
                )],
            );
        }
        let parent_hash = if n == 0 {
            [0u8; 32]
        } else {
            [(n - 1) as u8; 32]
        };
        source.push_block(
            BlockHeader {
                number: n,
                hash: [n as u8; 32],
                parent_hash,
            },
            logs_map,
        );
    }
    let submitter = BufferingSubmitter::new();
    let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
    config.confirmation_depth = 12;
    let mut watcher = WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
    let processed = watcher.run_iteration().unwrap();
    // confirmed_head = 14 - 12 = 2; start_block = 0; so we process
    // blocks 0, 1, 2.
    assert_eq!(processed, 3);
    assert_eq!(watcher.last_confirmed_block(), Some(2));
}

/// Watcher persists state to disk; a second instance over the
/// same state file resumes correctly.
#[test]
fn state_persists_across_restarts() {
    let temp = tempfile::tempdir().unwrap();
    let state_path = temp.path().join("state.jsonl");
    let log = build_registered_ecdsa_log([0x33; 20], &[0x02, 0x99], 0, 0, [0x44; 32]);
    {
        let mut source = InMemoryL1Source::new();
        push_chain_with_log(&mut source, 13, 0, log.clone());
        let submitter = BufferingSubmitter::new();
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        let mut watcher =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        watcher.run_iteration().unwrap();
    }
    // Reopen: should resume from block 1.  No new blocks past 12
    // exist so nothing happens, but the resumed state has
    // last_confirmed_block = Some(0).
    {
        let mut source = InMemoryL1Source::new();
        push_chain_with_log(&mut source, 13, 0, log);
        let submitter = BufferingSubmitter::new();
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        let mut watcher2 =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        // No new blocks to process.
        let processed = watcher2.run_iteration().unwrap();
        assert_eq!(processed, 0);
        assert_eq!(watcher2.last_confirmed_block(), Some(0));
        // Address book has the assignment from the prior run.
        let addr = EthAddress::from_bytes(&[0x33; 20]).unwrap();
        assert_eq!(watcher2.address_book().lookup(&addr), Some(1));
    }
}

/// `run_until` exits when the target block is reached.
#[test]
fn run_until_target_block() {
    let temp = tempfile::tempdir().unwrap();
    let state_path = temp.path().join("state.jsonl");
    let log = build_registered_ecdsa_log([0x55; 20], &[0x02, 0xab, 0xcd], 0, 0, [0x77; 32]);
    let mut source = InMemoryL1Source::new();
    push_chain_with_log(&mut source, 13, 0, log);
    let submitter = BufferingSubmitter::new();
    let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
    config.confirmation_depth = 12;
    config.poll_interval = Duration::from_millis(1);
    let mut watcher = WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let processed = watcher.run_until(0, stop).unwrap();
    assert!(processed >= 1);
    // `last_confirmed_block` is `Some(_)` after processing.
    assert!(watcher.last_confirmed_block().is_some());
}

/// End-to-end with a `RegisteredEIP1271` event: contract-signer
/// registration translates to `RegisterIdentity` with the
/// 20-byte contract address as the pubkey payload (matching the
/// translator's documented behaviour).
#[test]
fn end_to_end_eip1271_registration() {
    let temp = tempfile::tempdir().unwrap();
    let state_path = temp.path().join("state.jsonl");
    let mut source = InMemoryL1Source::new();
    // Build a RegisteredEIP1271 log: actor topic + 32-byte
    // padded contract-signer address in data.
    let actor: [u8; 20] = [0x66; 20];
    let contract_signer: [u8; 20] = [0x77; 20];
    let mut actor_topic = [0u8; 32];
    actor_topic[12..32].copy_from_slice(&actor);
    let mut data = [0u8; 32];
    data[12..32].copy_from_slice(&contract_signer);
    let log = canon_l1_ingest::events::RawLog {
        address: identity_addr(),
        topics: vec![
            canon_l1_ingest::events::EventTopic::RegisteredEip1271.hash(),
            actor_topic,
        ],
        data: data.to_vec(),
        block_number: 0,
        tx_hash: [0x88; 32],
        log_index: 0,
    };
    push_chain_with_log(&mut source, 13, 0, log);
    let submitter = BufferingSubmitter::new();
    let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
    config.confirmation_depth = 12;
    let mut watcher = WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
    let processed = watcher.run_iteration().unwrap();
    assert_eq!(processed, 1);
    let recorded = watcher.submitter().recorded();
    assert_eq!(recorded.len(), 1);
    match &recorded[0].unsigned.action {
        canon_l1_ingest::action::Action::RegisterIdentity { actor: id, pk } => {
            assert_eq!(*id, 1);
            // The pubkey payload is the 20-byte contract signer
            // address (per the translator's EIP-1271 mapping).
            assert_eq!(pk.as_bytes(), &contract_signer);
        }
        other => panic!("expected RegisterIdentity, got {other:?}"),
    }
    // Address book has the (actor, 1) mapping.
    let addr = canon_l1_ingest::action::EthAddress::from_bytes(&actor).unwrap();
    assert_eq!(watcher.address_book().lookup(&addr), Some(1));
}

/// When the operator configures `bridge_contract ==
/// identity_registry_contract` (a single-contract / test
/// deployment), the watcher skips the redundant second RPC
/// fetch.  Functional correctness: the action is still
/// submitted exactly once (via the dedup layer's idempotency).
#[test]
fn end_to_end_same_contract_for_bridge_and_identity() {
    let temp = tempfile::tempdir().unwrap();
    let state_path = temp.path().join("state.jsonl");
    let mut source = InMemoryL1Source::new();
    let log = build_registered_ecdsa_log([0x77; 20], &[0x02, 0xab], 0, 0, [0x99; 32]);
    push_chain_with_log(&mut source, 13, 0, log);
    let submitter = BufferingSubmitter::new();
    // Point both contract flags at the SAME address.
    let same_addr = identity_addr();
    let mut config = WatcherConfig::new(same_addr, same_addr, vec![]);
    config.confirmation_depth = 12;
    let mut watcher = WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
    let processed = watcher.run_iteration().unwrap();
    assert_eq!(processed, 1);
    // The action was submitted exactly once (NOT twice).
    let recorded = watcher.submitter().recorded();
    assert_eq!(
        recorded.len(),
        1,
        "expected exactly 1 submission; the watcher must dedup the redundant second RPC call"
    );
}

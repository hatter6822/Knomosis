// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Fuzz the `knomosis-l1-ingest` L1-log ABI decoder — the untrusted
//! on-chain-feed boundary (`docs/audits/20-…` §4.3).
//!
//! `decode_event` turns a raw Ethereum log (topics + ABI-encoded data)
//! into a typed `IngestedEvent`; an L1 RPC / re-org feed can hand it
//! arbitrary bytes.  It must return `Ok`/`Err` on ANY input and never
//! panic (an unchecked fixed-word read or dynamic-`bytes` length prefix
//! on the deposit paths — the events that credit L2 balances — would be
//! a DoS on the ingestor, or worse a mis-credit).
//!
//! The structured input biases `topic0` toward a REAL event-signature
//! hash (a 32-byte magic the mutator cannot reach on its own), so the
//! deeper per-event decode arm — not just the "unknown topic0 → None"
//! early return — is actually driven.  Mirrors the
//! `decode_event_with_valid_topic0_*` proptest.

#![no_main]

use arbitrary::Arbitrary;
use knomosis_l1_ingest::action::EthAddress;
use knomosis_l1_ingest::events::{decode_event, EventTopic, RawLog};
use libfuzzer_sys::fuzz_target;

/// Structured fuzz input, decoded from the raw bytes by `arbitrary`.
#[derive(Arbitrary, Debug)]
struct FuzzLog {
    address: [u8; 20],
    /// Selects `topic0`: `0..6` picks the matching real event-signature
    /// hash so the deep decode arm is reachable; any other value leaves
    /// `topic0` to come from `extra_topics` (or none), exercising the
    /// unknown-topic and no-topics paths.
    topic0_selector: u8,
    /// Trailing topics (indexed params) — adversarial arity: a real
    /// event has a fixed indexed-param count, so too-few / too-many both
    /// exercise the decoder's topic-index reads.
    extra_topics: Vec<[u8; 32]>,
    /// Non-indexed ABI payload.
    data: Vec<u8>,
    block_number: u64,
    tx_hash: [u8; 32],
    log_index: u64,
}

/// Every canonical event `topic0`, indexed by `topic0_selector`.
const REAL_TOPICS: [EventTopic; 6] = [
    EventTopic::RegisteredEcdsa,
    EventTopic::RegisteredEip1271,
    EventTopic::Revoked,
    EventTopic::DepositInitiated,
    EventTopic::DepositWithFeeInitiated,
    EventTopic::AmmDisabled,
];

fuzz_target!(|input: FuzzLog| {
    let mut topics: Vec<[u8; 32]> = Vec::new();
    if let Some(ev) = REAL_TOPICS.get(input.topic0_selector as usize) {
        topics.push(ev.hash());
    }
    topics.extend(input.extra_topics);
    let log = RawLog {
        address: EthAddress(input.address),
        topics,
        data: input.data,
        block_number: input.block_number,
        tx_hash: input.tx_hash,
        log_index: input.log_index,
    };
    // Discarded: the property is termination-without-panic on the
    // matched-topic0 decode path, not a specific outcome.
    let _ = decode_event(&log);
});

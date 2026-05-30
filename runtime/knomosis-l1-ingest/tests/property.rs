// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Property-based tests for RH-B.
//!
//! Exercises the encoder, the address-book, the re-org window,
//! and the translation function across pseudo-random inputs to
//! catch edge cases the curated unit tests miss.

use knomosis_l1_ingest::action::{Action, EthAddress, PublicKey};
use knomosis_l1_ingest::address_book::AddressBook;
use knomosis_l1_ingest::encoding::{encode_action, encode_signed_action, signing_input};
use knomosis_l1_ingest::events::IngestedEvent;
use knomosis_l1_ingest::fixture::{FeeSplitInput, MAX_BUDGET_PER_DEPOSIT};
use knomosis_l1_ingest::reorg::{AdvanceOutcome, BlockHeader, ReorgWindow};
use knomosis_l1_ingest::translation::ingest;

use proptest::prelude::*;

// `encode_action` is deterministic across random inputs.
proptest! {
    #[test]
    fn encode_action_deterministic(
        actor in 0u64..=u64::from(u32::MAX),
        pubkey in proptest::collection::vec(any::<u8>(), 0..200),
    ) {
        let action = Action::RegisterIdentity {
            actor,
            pk: PublicKey::from_bytes(&pubkey),
        };
        let e1 = encode_action(&action).unwrap();
        let e2 = encode_action(&action).unwrap();
        prop_assert_eq!(e1, e2);
    }
}

// `encode_action` distinguishes distinct register-identity actions.
proptest! {
    #[test]
    fn encode_action_distinguishes_distinct_register_identities(
        a1 in 0u64..1_000_000u64,
        a2 in 1_000_001u64..2_000_000u64,
        pubkey in proptest::collection::vec(any::<u8>(), 0..32),
    ) {
        prop_assume!(a1 != a2);
        let action1 = Action::RegisterIdentity {
            actor: a1,
            pk: PublicKey::from_bytes(&pubkey),
        };
        let action2 = Action::RegisterIdentity {
            actor: a2,
            pk: PublicKey::from_bytes(&pubkey),
        };
        let e1 = encode_action(&action1).unwrap();
        let e2 = encode_action(&action2).unwrap();
        prop_assert_ne!(e1, e2);
    }
}

// `signing_input` is non-empty for any valid action.
proptest! {
    #[test]
    fn signing_input_non_empty(
        signer in 0u64..=u64::from(u32::MAX),
        nonce in 0u128..1u128 << 64,
        deployment in proptest::collection::vec(any::<u8>(), 0..100),
    ) {
        let action = Action::FreezeResource { r: 0 };
        let bytes = signing_input(&action, signer, nonce, &deployment).unwrap();
        prop_assert!(bytes.len() >= 36);
    }
}

// `signing_input` distinguishes deployments.
proptest! {
    #[test]
    fn signing_input_distinguishes_deployments(
        signer in 0u64..=u64::from(u32::MAX),
        nonce in 0u128..1u128 << 32,
        d1 in proptest::collection::vec(any::<u8>(), 1..32),
        d2 in proptest::collection::vec(any::<u8>(), 1..32),
    ) {
        prop_assume!(d1 != d2);
        let action = Action::FreezeResource { r: 0 };
        let s1 = signing_input(&action, signer, nonce, &d1).unwrap();
        let s2 = signing_input(&action, signer, nonce, &d2).unwrap();
        prop_assert_ne!(s1, s2);
    }
}

// `signing_input` distinguishes nonces.
proptest! {
    #[test]
    fn signing_input_distinguishes_nonces(
        signer in 0u64..=u64::from(u32::MAX),
        n1 in 0u128..1u128 << 32,
        n2 in 0u128..1u128 << 32,
        deployment in proptest::collection::vec(any::<u8>(), 0..32),
    ) {
        prop_assume!(n1 != n2);
        let action = Action::FreezeResource { r: 0 };
        let s1 = signing_input(&action, signer, n1, &deployment).unwrap();
        let s2 = signing_input(&action, signer, n2, &deployment).unwrap();
        prop_assert_ne!(s1, s2);
    }
}

// `encode_signed_action` is deterministic.
proptest! {
    #[test]
    fn encode_signed_action_deterministic(
        signer in 0u64..=u64::from(u32::MAX),
        nonce in 0u128..1u128 << 32,
        sig in proptest::collection::vec(any::<u8>(), 0..64),
    ) {
        let action = Action::FreezeResource { r: 1 };
        let e1 = encode_signed_action(&action, signer, nonce, &sig).unwrap();
        let e2 = encode_signed_action(&action, signer, nonce, &sig).unwrap();
        prop_assert_eq!(e1, e2);
    }
}

// `AddressBook::assign` produces monotonically-increasing ids.
proptest! {
    #[test]
    fn address_book_monotone(addrs in proptest::collection::vec(any::<u8>(), 0..256)) {
        let mut book = AddressBook::new();
        let mut last_id = 0u64;
        for byte in addrs {
            let addr = EthAddress::from_bytes(&[byte; 20]).unwrap();
            let (id, is_new) = book.assign(&addr);
            if is_new {
                prop_assert!(id > last_id);
                last_id = id;
            }
        }
    }
}

// `AddressBook::lookup` after `assign` returns the assigned id.
proptest! {
    #[test]
    fn address_book_lookup_after_assign(
        addr_bytes in proptest::collection::vec(any::<u8>(), 20..21),
    ) {
        let addr = EthAddress::from_bytes(&addr_bytes).unwrap();
        let mut book = AddressBook::new();
        let (assigned_id, _) = book.assign(&addr);
        prop_assert_eq!(book.lookup(&addr), Some(assigned_id));
    }
}

// Translate-then-lookup: after `ingest` on a first-time
// RegisteredECDSA, the address book has the assigned id.
proptest! {
    #[test]
    fn translate_first_time_registers_address(
        addr_byte in any::<u8>(),
        pubkey in proptest::collection::vec(any::<u8>(), 1..33),
        nonce in 0u128..1u128 << 32,
    ) {
        let addr = EthAddress::from_bytes(&[addr_byte; 20]).unwrap();
        let mut book = AddressBook::new();
        let event = IngestedEvent::RegisteredEcdsa {
            actor: addr,
            pubkey,
            block_number: 0,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let result = ingest(&mut book, &event, nonce);
        prop_assert!(result.is_some());
        prop_assert!(book.lookup(&addr).is_some());
    }
}

// Translate `Revoked` always returns None.
proptest! {
    #[test]
    fn translate_revoked_returns_none(
        addr_byte in any::<u8>(),
        nonce in 0u128..1u128 << 32,
    ) {
        let addr = EthAddress::from_bytes(&[addr_byte; 20]).unwrap();
        let mut book = AddressBook::new();
        let event = IngestedEvent::Revoked {
            actor: addr,
            block_number: 0,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let result = ingest(&mut book, &event, nonce);
        prop_assert!(result.is_none());
        prop_assert!(book.is_empty());
    }
}

// === Workstream GP.6.1: GP-family encoder properties ===

// `encode_action` is deterministic over random in-bounds
// `DepositWithFee` fields.  `u64`-typed amounts always satisfy the
// `< 2^64` encoder bound when widened to `u128`, so encoding never
// errors.
proptest! {
    #[test]
    fn encode_deposit_with_fee_deterministic(
        r in any::<u64>(),
        recipient in any::<u64>(),
        pool_actor in any::<u64>(),
        user_amount in any::<u64>(),
        pool_amount in any::<u64>(),
        budget_grant in any::<u64>(),
        deposit_id in any::<u64>(),
    ) {
        let action = Action::DepositWithFee {
            r,
            recipient,
            pool_actor,
            user_amount: u128::from(user_amount),
            pool_amount: u128::from(pool_amount),
            budget_grant,
            deposit_id,
        };
        let e1 = encode_action(&action).unwrap();
        let e2 = encode_action(&action).unwrap();
        prop_assert_eq!(&e1, &e2);
        // Layout invariant: 8 × 9-byte CBE uint heads.
        prop_assert_eq!(e1.len(), 72);
    }
}

// ETH (`r = 0`) and BOLD (`r = 1`) `DepositWithFee` encodings differ
// ONLY in the resource field's low byte (index 10) for any choice of
// the other fields.  This is the resource-parametric byte-equality
// the cross-stack corpus relies on, pinned over random inputs.
proptest! {
    #[test]
    fn encode_deposit_with_fee_resource_parametric(
        recipient in any::<u64>(),
        pool_actor in any::<u64>(),
        user_amount in any::<u64>(),
        pool_amount in any::<u64>(),
        budget_grant in any::<u64>(),
        deposit_id in any::<u64>(),
    ) {
        let mk = |r: u64| Action::DepositWithFee {
            r,
            recipient,
            pool_actor,
            user_amount: u128::from(user_amount),
            pool_amount: u128::from(pool_amount),
            budget_grant,
            deposit_id,
        };
        let eth = encode_action(&mk(0)).unwrap();
        let bold = encode_action(&mk(1)).unwrap();
        prop_assert_eq!(eth.len(), bold.len());
        for i in 0..eth.len() {
            if i == 10 {
                // The `r` field's low byte: 0 for ETH, 1 for BOLD.
                prop_assert_eq!(eth[10], 0u8);
                prop_assert_eq!(bold[10], 1u8);
            } else {
                prop_assert_eq!(eth[i], bold[i]);
            }
        }
    }
}

// `encode_action` is deterministic over random `TopUpActionBudget`
// fields, with the 5-head (45-byte) layout invariant.
proptest! {
    #[test]
    fn encode_top_up_action_budget_deterministic(
        gas_resource in any::<u64>(),
        gas_amount in any::<u64>(),
        budget_increment in any::<u64>(),
        pool_actor in any::<u64>(),
    ) {
        let action = Action::TopUpActionBudget {
            gas_resource,
            gas_amount: u128::from(gas_amount),
            budget_increment,
            pool_actor,
        };
        let e1 = encode_action(&action).unwrap();
        let e2 = encode_action(&action).unwrap();
        prop_assert_eq!(&e1, &e2);
        prop_assert_eq!(e1.len(), 45);
    }
}

// `encode_action` is deterministic over random
// `TopUpActionBudgetFor` fields, with the 6-head (54-byte) layout.
proptest! {
    #[test]
    fn encode_top_up_action_budget_for_deterministic(
        recipient in any::<u64>(),
        gas_resource in any::<u64>(),
        gas_amount in any::<u64>(),
        budget_increment in any::<u64>(),
        pool_actor in any::<u64>(),
    ) {
        let action = Action::TopUpActionBudgetFor {
            recipient,
            gas_resource,
            gas_amount: u128::from(gas_amount),
            budget_increment,
            pool_actor,
        };
        let e1 = encode_action(&action).unwrap();
        let e2 = encode_action(&action).unwrap();
        prop_assert_eq!(&e1, &e2);
        prop_assert_eq!(e1.len(), 54);
    }
}

// The self-funded (`topUpActionBudget`) and delegated
// (`topUpActionBudgetFor`) top-up variants encode to byte-distinct
// streams even on identical gas-transfer fields — the tag-separation
// design property, pinned over random inputs.
proptest! {
    #[test]
    fn top_up_variants_byte_distinct(
        gas_resource in any::<u64>(),
        gas_amount in any::<u64>(),
        budget_increment in any::<u64>(),
        pool_actor in any::<u64>(),
        recipient in any::<u64>(),
    ) {
        let self_funded = Action::TopUpActionBudget {
            gas_resource,
            gas_amount: u128::from(gas_amount),
            budget_increment,
            pool_actor,
        };
        let delegated = Action::TopUpActionBudgetFor {
            recipient,
            gas_resource,
            gas_amount: u128::from(gas_amount),
            budget_increment,
            pool_actor,
        };
        let a = encode_action(&self_funded).unwrap();
        let b = encode_action(&delegated).unwrap();
        // Distinct tag bytes (20 vs 21) ⇒ distinct streams.
        prop_assert_ne!(&a, &b);
        prop_assert_eq!(a[1], 20u8);
        prop_assert_eq!(b[1], 21u8);
    }
}

// `FeeSplitInput::split` satisfies the cross-stack arithmetic
// invariants for ANY input (mirrors Lean's `feeSplit_conserves`,
// `feeSplit_pool_le`, `feeSplit_budget_le_max`): conservation,
// pool-cap, and budget-cap.  `msg_value` ranges over a wide u128
// band; `bps` over `[0, 10000]` (the universal admissibility bound).
proptest! {
    #[test]
    fn fee_split_arithmetic_invariants(
        msg_value in 0u128..(1u128 << 96),
        chosen_fee_bps in 0u16..=10000u16,
        wei_per_budget_unit in 1u64..(1u64 << 50),
        resource_id in any::<u64>(),
    ) {
        let input = FeeSplitInput {
            msg_value,
            chosen_fee_bps,
            wei_per_budget_unit,
            resource_id,
            recipient: 7,
            pool_actor: 2,
            deposit_id: 1,
        };
        let (user, pool, budget) = input.split();
        // Conservation: user + pool = msg_value exactly.
        prop_assert_eq!(user.checked_add(pool).unwrap(), msg_value);
        // Pool cap: pool <= msg_value (bps <= 10000).
        prop_assert!(pool <= msg_value);
        // Budget cap.
        prop_assert!(budget <= MAX_BUDGET_PER_DEPOSIT);
    }
}

// Linear advance into ReorgWindow always returns `Advanced`.
proptest! {
    #[test]
    fn reorg_window_linear_advance(
        capacity in 1usize..16usize,
        count in 1usize..32usize,
    ) {
        let mut window = ReorgWindow::new(capacity);
        let mut last_hash = [0u8; 32];
        for i in 0..count {
            let mut hash = [0u8; 32];
            hash[0] = (i & 0xff) as u8;
            hash[31] = ((i >> 8) & 0xff) as u8;
            let header = BlockHeader {
                number: i as u64,
                hash,
                parent_hash: last_hash,
            };
            let outcome = window.advance(header).unwrap();
            prop_assert_eq!(outcome, AdvanceOutcome::Advanced);
            last_hash = hash;
        }
        prop_assert!(window.len() <= capacity);
        prop_assert!(window.len() <= count);
    }
}

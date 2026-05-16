// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Property-based tests for RH-B.
//!
//! Exercises the encoder, the address-book, the re-org window,
//! and the translation function across pseudo-random inputs to
//! catch edge cases the curated unit tests miss.

use canon_l1_ingest::action::{Action, EthAddress, PublicKey};
use canon_l1_ingest::address_book::AddressBook;
use canon_l1_ingest::encoding::{encode_action, encode_signed_action, signing_input};
use canon_l1_ingest::events::IngestedEvent;
use canon_l1_ingest::reorg::{AdvanceOutcome, BlockHeader, ReorgWindow};
use canon_l1_ingest::translation::ingest;

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

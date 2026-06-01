// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Cross-stack fixture generator for RH-B.
//!
//! Produces `runtime/tests/cross-stack/l1_ingest.cxsf` —
//! a sequence of `(IngestedEvent + AddressBook snapshot +
//! current_nonce, expected Action CBE bytes)` pairs.
//!
//! Run via:
//!
//! ```bash
//! cd runtime
//! cargo run --example gen_ingest_fixtures -- tests/cross-stack/l1_ingest.cxsf
//! ```
//!
//! The fixtures cover every translatable event variant + several
//! edge cases:
//!
//!   1. First-time `RegisteredECDSA` → `RegisterIdentity` (id 3,
//!      the genesis `next_actor_id` post-GP.7.1).
//!   2. Two distinct first-time registrations (ids 3 + 4).
//!   3. First-time + rotation (`RegisterIdentity` then
//!      `ReplaceKey` for the same address).
//!   4. `RegisteredEIP1271` first-time → `RegisterIdentity`
//!      with the contract-signer's address as the pubkey.
//!   5. `Revoked` → `None`.
//!   6. `DepositInitiated` → `None`.
//!   7. Edge: empty pubkey (RegisteredECDSA with `pubkey = []`).
//!   8. Edge: max-realistic pubkey (33-byte SEC1-compressed).
//!   9. Edge: large nonce (near `u64::MAX`).
//!   10. Edge: large address book (16 entries) prior to a fresh
//!       registration that bumps to id 19 (ids 3..18 pre-assigned).

use std::env;
use std::path::PathBuf;

use knomosis_cross_stack::{FixtureFile, FixtureKind, FixtureRecord};
use knomosis_l1_ingest::action::EthAddress;
use knomosis_l1_ingest::address_book::AddressBook;
use knomosis_l1_ingest::events::IngestedEvent;
use knomosis_l1_ingest::fixture::{encode_expected, encode_input, FixtureInput};
use knomosis_l1_ingest::translation::ingest;

fn main() {
    let args: Vec<String> = env::args().collect();
    let out_path = match args.get(1) {
        Some(p) => PathBuf::from(p),
        None => {
            eprintln!(
                "Usage: gen_ingest_fixtures <output-path>\n\
                 (typically `runtime/tests/cross-stack/l1_ingest.cxsf`)"
            );
            std::process::exit(2);
        }
    };

    let mut fixture = FixtureFile::new(FixtureKind::L1Ingest);

    // ---------------------------------------------------------------
    // Case 1: first-time RegisteredECDSA → RegisterIdentity
    // ---------------------------------------------------------------
    {
        let mut book = AddressBook::new();
        let event = IngestedEvent::RegisteredEcdsa {
            actor: EthAddress::from_bytes(&[0x01; 20]).unwrap(),
            pubkey: vec![0x02, 0xab, 0xcd],
            block_number: 100,
            tx_hash: [0x77; 32],
            log_index: 0,
        };
        let input = FixtureInput {
            event: event.clone(),
            address_book: snapshot(&book),
            current_nonce: 0,
        };
        let expected = ingest(&mut book, &event, 0);
        push_record(&mut fixture, &input, expected.as_ref());
    }

    // ---------------------------------------------------------------
    // Case 2: two distinct first-time registrations
    // ---------------------------------------------------------------
    {
        let mut book = AddressBook::new();
        let e1 = IngestedEvent::RegisteredEcdsa {
            actor: EthAddress::from_bytes(&[0x02; 20]).unwrap(),
            pubkey: vec![0x02, 0x11, 0x22],
            block_number: 200,
            tx_hash: [0x01; 32],
            log_index: 0,
        };
        let input1 = FixtureInput {
            event: e1.clone(),
            address_book: snapshot(&book),
            current_nonce: 0,
        };
        let expected1 = ingest(&mut book, &e1, 0);
        push_record(&mut fixture, &input1, expected1.as_ref());

        let e2 = IngestedEvent::RegisteredEcdsa {
            actor: EthAddress::from_bytes(&[0x03; 20]).unwrap(),
            pubkey: vec![0x02, 0x33, 0x44],
            block_number: 200,
            tx_hash: [0x02; 32],
            log_index: 1,
        };
        let input2 = FixtureInput {
            event: e2.clone(),
            address_book: snapshot(&book),
            current_nonce: 1,
        };
        let expected2 = ingest(&mut book, &e2, 1);
        push_record(&mut fixture, &input2, expected2.as_ref());
    }

    // ---------------------------------------------------------------
    // Case 3: rotation (RegisterIdentity then ReplaceKey)
    // ---------------------------------------------------------------
    {
        let mut book = AddressBook::new();
        let addr = EthAddress::from_bytes(&[0x05; 20]).unwrap();
        // First-time registration.
        let e1 = IngestedEvent::RegisteredEcdsa {
            actor: addr,
            pubkey: vec![0x02, 0x55, 0x66],
            block_number: 300,
            tx_hash: [0x03; 32],
            log_index: 0,
        };
        let input1 = FixtureInput {
            event: e1.clone(),
            address_book: snapshot(&book),
            current_nonce: 0,
        };
        let expected1 = ingest(&mut book, &e1, 0);
        push_record(&mut fixture, &input1, expected1.as_ref());

        // Rotation.
        let e2 = IngestedEvent::RegisteredEcdsa {
            actor: addr,
            pubkey: vec![0x02, 0x77, 0x88],
            block_number: 350,
            tx_hash: [0x04; 32],
            log_index: 0,
        };
        let input2 = FixtureInput {
            event: e2.clone(),
            address_book: snapshot(&book),
            current_nonce: 1,
        };
        let expected2 = ingest(&mut book, &e2, 1);
        push_record(&mut fixture, &input2, expected2.as_ref());
    }

    // ---------------------------------------------------------------
    // Case 4: RegisteredEIP1271 first-time
    // ---------------------------------------------------------------
    {
        let mut book = AddressBook::new();
        let event = IngestedEvent::RegisteredEip1271 {
            actor: EthAddress::from_bytes(&[0x06; 20]).unwrap(),
            contract_signer: EthAddress::from_bytes(&[0x07; 20]).unwrap(),
            block_number: 400,
            tx_hash: [0x05; 32],
            log_index: 0,
        };
        let input = FixtureInput {
            event: event.clone(),
            address_book: snapshot(&book),
            current_nonce: 0,
        };
        let expected = ingest(&mut book, &event, 0);
        push_record(&mut fixture, &input, expected.as_ref());
    }

    // ---------------------------------------------------------------
    // Case 5: Revoked → None
    // ---------------------------------------------------------------
    {
        let mut book = AddressBook::new();
        let event = IngestedEvent::Revoked {
            actor: EthAddress::from_bytes(&[0x08; 20]).unwrap(),
            block_number: 500,
            tx_hash: [0x06; 32],
            log_index: 0,
        };
        let input = FixtureInput {
            event: event.clone(),
            address_book: snapshot(&book),
            current_nonce: 0,
        };
        let expected = ingest(&mut book, &event, 0);
        push_record(&mut fixture, &input, expected.as_ref());
    }

    // ---------------------------------------------------------------
    // Case 6: DepositInitiated → None
    // ---------------------------------------------------------------
    {
        let mut book = AddressBook::new();
        let event = IngestedEvent::DepositInitiated {
            depositor: EthAddress::from_bytes(&[0x09; 20]).unwrap(),
            resource_id: 7,
            token: EthAddress::from_bytes(&[0x0a; 20]).unwrap(),
            amount: [0xff; 32],
            depositor_nonce: 42,
            receipt_hash: [0xbb; 32],
            block_number: 600,
            tx_hash: [0x07; 32],
            log_index: 0,
        };
        let input = FixtureInput {
            event: event.clone(),
            address_book: snapshot(&book),
            current_nonce: 0,
        };
        let expected = ingest(&mut book, &event, 0);
        push_record(&mut fixture, &input, expected.as_ref());
    }

    // ---------------------------------------------------------------
    // Case 7: empty pubkey
    // ---------------------------------------------------------------
    {
        let mut book = AddressBook::new();
        let event = IngestedEvent::RegisteredEcdsa {
            actor: EthAddress::from_bytes(&[0x0b; 20]).unwrap(),
            pubkey: vec![],
            block_number: 700,
            tx_hash: [0x08; 32],
            log_index: 0,
        };
        let input = FixtureInput {
            event: event.clone(),
            address_book: snapshot(&book),
            current_nonce: 0,
        };
        let expected = ingest(&mut book, &event, 0);
        push_record(&mut fixture, &input, expected.as_ref());
    }

    // ---------------------------------------------------------------
    // Case 8: 33-byte SEC1-compressed pubkey (the realistic size)
    // ---------------------------------------------------------------
    {
        let mut book = AddressBook::new();
        let mut pk = vec![0x02];
        for i in 0..32 {
            pk.push(i as u8);
        }
        let event = IngestedEvent::RegisteredEcdsa {
            actor: EthAddress::from_bytes(&[0x0c; 20]).unwrap(),
            pubkey: pk,
            block_number: 800,
            tx_hash: [0x09; 32],
            log_index: 0,
        };
        let input = FixtureInput {
            event: event.clone(),
            address_book: snapshot(&book),
            current_nonce: 0,
        };
        let expected = ingest(&mut book, &event, 0);
        push_record(&mut fixture, &input, expected.as_ref());
    }

    // ---------------------------------------------------------------
    // Case 9: large nonce near u64::MAX
    // ---------------------------------------------------------------
    {
        let mut book = AddressBook::new();
        let event = IngestedEvent::RegisteredEcdsa {
            actor: EthAddress::from_bytes(&[0x0d; 20]).unwrap(),
            pubkey: vec![0x02, 0xab],
            block_number: 900,
            tx_hash: [0x0a; 32],
            log_index: 0,
        };
        let large_nonce = u128::from(u64::MAX) - 1;
        let input = FixtureInput {
            event: event.clone(),
            address_book: snapshot(&book),
            current_nonce: large_nonce,
        };
        let expected = ingest(&mut book, &event, large_nonce);
        push_record(&mut fixture, &input, expected.as_ref());
    }

    // ---------------------------------------------------------------
    // Case 10: large address book (16 entries) + fresh registration
    // ---------------------------------------------------------------
    {
        let mut book = AddressBook::new();
        for i in 1..=16u8 {
            book.assign(&EthAddress::from_bytes(&[i; 20]).unwrap());
        }
        let event = IngestedEvent::RegisteredEcdsa {
            actor: EthAddress::from_bytes(&[0x11; 20]).unwrap(),
            pubkey: vec![0x02, 0xee, 0xff],
            block_number: 1000,
            tx_hash: [0x0b; 32],
            log_index: 0,
        };
        let input = FixtureInput {
            event: event.clone(),
            address_book: snapshot(&book),
            current_nonce: 16,
        };
        let expected = ingest(&mut book, &event, 16);
        push_record(&mut fixture, &input, expected.as_ref());
    }

    // Write the fixture file.
    if let Some(parent) = out_path.parent() {
        std::fs::create_dir_all(parent).unwrap_or_else(|e| {
            eprintln!("create parent dir: {e}");
            std::process::exit(1);
        });
    }
    fixture.write_to(&out_path).unwrap_or_else(|e| {
        eprintln!("write fixture: {e}");
        std::process::exit(1);
    });
    println!(
        "wrote {} records to {}",
        fixture.records().len(),
        out_path.display()
    );
}

fn snapshot(book: &AddressBook) -> Vec<(EthAddress, u64)> {
    // The book's `BTreeMap` iterates in deterministic (sorted)
    // address order — exactly what we want for stable fixtures.
    let mut out = Vec::new();
    // We use the helper exposed by `lookup` — iterate every byte
    // pattern would be slow.  Instead, we accept that the public
    // API is `lookup`-only; for the snapshot helper we re-derive
    // the contents by replaying the assigned addresses through
    // `lookup_reverse`.  The book never reuses ids; we walk from
    // 1 to `next_actor_id() - 1`.
    for id in 1..book.next_actor_id() {
        if let Some(addr) = book.lookup_reverse(id) {
            out.push((addr, id));
        }
    }
    out
}

fn push_record(
    fixture: &mut FixtureFile,
    input: &FixtureInput,
    expected: Option<&knomosis_l1_ingest::translation::UnsignedAction>,
) {
    let input_bytes = encode_input(input).expect("encode input");
    // `encode_expected` takes `&Option<T>`; we adapt the
    // `Option<&T>` parameter to the expected shape via `.cloned()`.
    let owned = expected.cloned();
    let expected_bytes = encode_expected(&owned).expect("encode expected");
    fixture.push(FixtureRecord::new(input_bytes, expected_bytes));
}

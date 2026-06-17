// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! CBE decoder for `Event` payloads.
//!
//! ## Wire format
//!
//! Each `Event` payload is encoded as:
//!
//! ```text
//!   tag-as-uint (9 bytes; CBE-encoded u64)
//!   field 1 ... field N (one CBE-encoded value each)
//! ```
//!
//! Field types use the same CBE primitives as
//! `knomosis-l1-ingest/src/encoding.rs`:
//!
//!   * `u64` / `Nat` field → 9 bytes (`0x00` tag + 8-byte LE u64).
//!   * `Amount` / `Nonce` field → 9 bytes (CBE uint; the encoder
//!     guarantees the value fits in u64 via
//!     `Action.fieldsBounded`).
//!   * Byte string → variable (`0x02` tag + 8-byte LE length +
//!     payload).
//!   * `EthAddress` → 29 bytes (encoded as a 20-byte byte string).
//!
//! ## Note on the Lean side
//!
//! As of this PR's landing the Lean side does NOT yet ship an
//! `Encodable Event` instance — the `knomosis extract-events`
//! subcommand is deferred (per CLAUDE.md "Workstream RH-D" entry
//! and the plan §RH-D.2 closeout).  This decoder uses the
//! established CBE convention so it remains compatible the
//! moment the Lean encoder lands.  Until then, the indexer's
//! integration tests use synthetic Event payloads produced by
//! [`encode_event`] (the reverse of [`decode_event`]) — same
//! byte format as the future Lean encoder.
//!
//! ## CBE constants
//!
//! These constants mirror `knomosis-l1-ingest/src/encoding.rs`:

use crate::event::{Amount, BudgetUnits, DepositId, EthAddress, Event, Nonce, WithdrawalId};

/// CBE tag byte for an unsigned integer.  Matches Lean's
/// `Encoding.CBOR.cbeTagUint`.
pub const CBE_TAG_UINT: u8 = 0x00;

/// CBE tag byte for a byte string.  Matches Lean's
/// `Encoding.CBOR.cbeTagBytes`.
pub const CBE_TAG_BYTES: u8 = 0x02;

/// Length of a CBE head (1-byte tag + 8-byte LE u64).
pub const HEAD_LEN: usize = 9;

/// 20-byte byte string is the standard EthAddress encoding (head
/// + 20 payload bytes = 29 bytes total).
pub const ETH_ADDRESS_BYTES: usize = 20;

/// Hard ceiling on decoded byte-string length.  Defends against a
/// malformed payload claiming a length larger than the buffer can
/// supply (the underlying decoder also bounds-checks, but a hard
/// cap surfaces unreasonable lengths as typed errors rather than
/// allocating gigabytes).
pub const HARD_MAX_BYTE_STRING_LEN: u64 = 1024 * 1024;

/// Decoder errors.
#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum DecodeError {
    /// The payload is shorter than the next field requires.
    /// `expected` and `available` give the caller enough detail
    /// to diagnose the malformation (e.g. "encoder produced a
    /// short buffer" vs "wire format truncated mid-field").
    #[error("truncated payload at offset {offset}: expected {expected} bytes, only {available} available")]
    Truncated {
        /// Byte offset at which the truncation was detected.
        offset: usize,
        /// Bytes the next field needs.
        expected: usize,
        /// Bytes actually available.
        available: usize,
    },
    /// A CBE head's tag byte did not match the expected tag.
    #[error(
        "invalid CBE head at offset {offset}: expected tag 0x{expected:02x}, got 0x{actual:02x}"
    )]
    BadHeadTag {
        /// Byte offset of the offending tag.
        offset: usize,
        /// Tag the decoder was expecting.
        expected: u8,
        /// Tag actually read.
        actual: u8,
    },
    /// A byte-string field declared a length exceeding
    /// `HARD_MAX_BYTE_STRING_LEN`.
    #[error("byte-string length {len} at offset {offset} exceeds hard cap {cap}")]
    ByteStringTooLong {
        /// Byte offset of the offending length prefix.
        offset: usize,
        /// Declared length.
        len: u64,
        /// Configured ceiling.
        cap: u64,
    },
    /// The payload's leading constructor tag did not match any
    /// known Event variant.
    #[error("unknown Event constructor tag: {tag}")]
    UnknownTag {
        /// The offending tag value.
        tag: u64,
    },
    /// After fully parsing an event, the buffer had unexpected
    /// trailing bytes.  Indicates an encoder bug or a corrupted
    /// payload.
    #[error("event payload has {trailing} trailing bytes after fully parsed event")]
    TrailingBytes {
        /// Number of unconsumed trailing bytes.
        trailing: usize,
    },
    /// A byte-string was expected to be exactly N bytes long
    /// (e.g. `EthAddress` is always 20 bytes); the declared
    /// length was different.
    #[error("expected exactly {expected}-byte byte string at offset {offset}, got {actual}")]
    BadByteStringLength {
        /// Byte offset of the offending byte-string head.
        offset: usize,
        /// Expected length.
        expected: usize,
        /// Actual declared length.
        actual: u64,
    },
}

/// A cursor that walks a byte buffer in a forward-only fashion,
/// surfacing typed errors on truncation / tag mismatch.
struct Cursor<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    /// Remaining bytes from the current offset onward.
    fn remaining(&self) -> usize {
        self.bytes.len().saturating_sub(self.offset)
    }

    /// Read `n` bytes and advance.
    ///
    /// **Overflow safety.**  We use `checked_add` for the end
    /// offset to defend against `self.offset + n` wrapping on
    /// pathological inputs (e.g., `self.offset == usize::MAX`).
    /// In practice `read_bytes` is only reached after a
    /// `remaining() >= n` check, so the wrap is unreachable, but
    /// defending at the slice-index boundary is cheap.
    fn read_bytes(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        let available = self.remaining();
        if available < n {
            return Err(DecodeError::Truncated {
                offset: self.offset,
                expected: n,
                available,
            });
        }
        let end = self.offset.checked_add(n).ok_or(DecodeError::Truncated {
            offset: self.offset,
            expected: n,
            available,
        })?;
        let out = &self.bytes[self.offset..end];
        self.offset = end;
        Ok(out)
    }

    /// Read one CBE head.  Returns the (tag, n) pair.
    fn read_head_raw(&mut self) -> Result<(u8, u64), DecodeError> {
        let buf = self.read_bytes(HEAD_LEN)?;
        let tag = buf[0];
        let mut n_buf = [0u8; 8];
        n_buf.copy_from_slice(&buf[1..9]);
        let n = u64::from_le_bytes(n_buf);
        Ok((tag, n))
    }

    /// Read a CBE uint head (tag 0x00).  Returns the embedded
    /// u64 value.
    fn read_uint(&mut self) -> Result<u64, DecodeError> {
        let head_offset = self.offset;
        let (tag, n) = self.read_head_raw()?;
        if tag != CBE_TAG_UINT {
            return Err(DecodeError::BadHeadTag {
                offset: head_offset,
                expected: CBE_TAG_UINT,
                actual: tag,
            });
        }
        Ok(n)
    }

    /// Read a CBE uint and re-cast to `u128` (per the trait
    /// `Amount` / `Nonce` typing).  Mirrors Lean's `Encodable Nat`
    /// roundtrip: the value is encoded as a u64 and decoded back
    /// to the wider Rust type for arithmetic.
    fn read_amount(&mut self) -> Result<u128, DecodeError> {
        Ok(u128::from(self.read_uint()?))
    }

    /// Read a CBE uint and re-cast to `BudgetUnits` (= `u128`).
    /// Semantically distinct from `read_amount` but uses the same
    /// wire encoding (CBE uint head + 8-byte LE u64) — the field
    /// is a `Nat` on the Lean side bounded `< 2^64` by the
    /// canonical encoding.  Named separately so the decoder's
    /// per-field discipline reads clearly.
    fn read_budget_units(&mut self) -> Result<BudgetUnits, DecodeError> {
        Ok(BudgetUnits::from(self.read_uint()?))
    }

    /// Read a CBE byte string (tag 0x02 + 8-byte LE length +
    /// payload).
    fn read_byte_string(&mut self) -> Result<Vec<u8>, DecodeError> {
        let head_offset = self.offset;
        let (tag, len) = self.read_head_raw()?;
        if tag != CBE_TAG_BYTES {
            return Err(DecodeError::BadHeadTag {
                offset: head_offset,
                expected: CBE_TAG_BYTES,
                actual: tag,
            });
        }
        if len > HARD_MAX_BYTE_STRING_LEN {
            return Err(DecodeError::ByteStringTooLong {
                offset: head_offset,
                len,
                cap: HARD_MAX_BYTE_STRING_LEN,
            });
        }
        let len_usize = usize::try_from(len).map_err(|_| DecodeError::ByteStringTooLong {
            offset: head_offset,
            len,
            cap: HARD_MAX_BYTE_STRING_LEN,
        })?;
        let payload = self.read_bytes(len_usize)?;
        Ok(payload.to_vec())
    }

    /// Read a CBE byte string whose declared length must be
    /// exactly `expected`.  Used for fixed-width fields like
    /// `EthAddress` (20 bytes).
    fn read_byte_string_exact(&mut self, expected: usize) -> Result<Vec<u8>, DecodeError> {
        let head_offset = self.offset;
        let (tag, len) = self.read_head_raw()?;
        if tag != CBE_TAG_BYTES {
            return Err(DecodeError::BadHeadTag {
                offset: head_offset,
                expected: CBE_TAG_BYTES,
                actual: tag,
            });
        }
        if len != expected as u64 {
            return Err(DecodeError::BadByteStringLength {
                offset: head_offset,
                expected,
                actual: len,
            });
        }
        let payload = self.read_bytes(expected)?;
        Ok(payload.to_vec())
    }

    /// Read an EthAddress (20-byte fixed-width byte string).
    fn read_eth_address(&mut self) -> Result<EthAddress, DecodeError> {
        let payload = self.read_byte_string_exact(ETH_ADDRESS_BYTES)?;
        let mut out = [0u8; 20];
        out.copy_from_slice(&payload);
        Ok(out)
    }
}

/// Decode an event from its CBE-encoded payload.
///
/// # Errors
///
/// Returns a typed [`DecodeError`] on truncation, bad tag,
/// out-of-range length, or trailing bytes.
pub fn decode_event(payload: &[u8]) -> Result<Event, DecodeError> {
    let mut cursor = Cursor::new(payload);
    let tag = cursor.read_uint()?;
    let event = match tag {
        0 => Event::BalanceChanged {
            resource: cursor.read_uint()?,
            actor: cursor.read_uint()?,
            old_value: cursor.read_amount()?,
            new_value: cursor.read_amount()?,
        },
        1 => Event::NonceAdvanced {
            actor: cursor.read_uint()?,
            old_nonce: cursor.read_amount()?,
            new_nonce: cursor.read_amount()?,
        },
        2 => Event::IdentityRegistered {
            actor: cursor.read_uint()?,
            key: cursor.read_byte_string()?,
        },
        3 => Event::IdentityRevoked {
            actor: cursor.read_uint()?,
        },
        4 => Event::TimeRecorded {
            time: cursor.read_uint()?,
        },
        5 => Event::DisputeFiled {
            challenger: cursor.read_uint()?,
            target_idx: cursor.read_uint()?,
        },
        6 => Event::DisputeWithdrawn {
            dispute_idx: cursor.read_uint()?,
        },
        7 => Event::VerdictApplied {
            dispute_idx: cursor.read_uint()?,
            outcome_tag: cursor.read_uint()?,
        },
        8 => Event::RewardIssued {
            resource: cursor.read_uint()?,
            recipient: cursor.read_uint()?,
            amount: cursor.read_amount()?,
        },
        9 => Event::WithdrawalRequested {
            resource: cursor.read_uint()?,
            sender: cursor.read_uint()?,
            amount: cursor.read_amount()?,
            recipient_l1: cursor.read_eth_address()?,
            withdrawal_id: cursor.read_uint()?,
        },
        10 => Event::DepositCredited {
            resource: cursor.read_uint()?,
            recipient: cursor.read_uint()?,
            amount: cursor.read_amount()?,
            deposit_id: cursor.read_uint()?,
        },
        11 => Event::LocalPolicyDeclared {
            actor: cursor.read_uint()?,
            policy: cursor.read_byte_string()?,
        },
        12 => Event::LocalPolicyRevoked {
            actor: cursor.read_uint()?,
        },
        13 => Event::FaultProofGameOpened {
            game_id: cursor.read_uint()?,
            challenger: cursor.read_uint()?,
            disputed_start_idx: cursor.read_uint()?,
            disputed_end_idx: cursor.read_uint()?,
            binding_hash: cursor.read_byte_string()?,
        },
        14 => Event::FaultProofBisectionStep {
            game_id: cursor.read_uint()?,
            round: cursor.read_uint()?,
            party: cursor.read_uint()?,
            idx: cursor.read_uint()?,
            commit: cursor.read_byte_string()?,
        },
        15 => Event::FaultProofGameSettled {
            game_id: cursor.read_uint()?,
            winner: cursor.read_uint()?,
            loser: cursor.read_uint()?,
            payout: cursor.read_amount()?,
        },
        16 => Event::DepositWithFeeCredited {
            resource: cursor.read_uint()?,
            recipient: cursor.read_uint()?,
            pool_actor: cursor.read_uint()?,
            user_amount: cursor.read_amount()?,
            pool_amount: cursor.read_amount()?,
            budget_grant: cursor.read_budget_units()?,
            deposit_id: cursor.read_uint()?,
        },
        17 => Event::ActionBudgetTopUp {
            signer: cursor.read_uint()?,
            gas_resource: cursor.read_uint()?,
            gas_amount: cursor.read_amount()?,
            budget_increment: cursor.read_budget_units()?,
            pool_actor: cursor.read_uint()?,
        },
        18 => Event::GasPoolClaim {
            resource: cursor.read_uint()?,
            sequencer: cursor.read_uint()?,
            amount: cursor.read_amount()?,
        },
        19 => Event::DelegatedActionBudgetTopUp {
            recipient: cursor.read_uint()?,
            signer: cursor.read_uint()?,
            gas_resource: cursor.read_uint()?,
            gas_amount: cursor.read_amount()?,
            budget_increment: cursor.read_budget_units()?,
            pool_actor: cursor.read_uint()?,
        },
        20 => Event::BudgetConsumed {
            actor: cursor.read_uint()?,
            amount: cursor.read_budget_units()?,
        },
        21 => Event::AmmSwapExecuted {
            from_resource: cursor.read_uint()?,
            to_resource: cursor.read_uint()?,
            amount_in: cursor.read_amount()?,
            amount_out: cursor.read_amount()?,
            amm_reserve_actor: cursor.read_uint()?,
        },
        22 => Event::AmmReservesReclaimed {
            resource: cursor.read_uint()?,
            amount: cursor.read_amount()?,
            reserve_actor: cursor.read_uint()?,
            pool_actor: cursor.read_uint()?,
        },
        other => return Err(DecodeError::UnknownTag { tag: other }),
    };
    // Reject trailing bytes — the encoder is supposed to produce a
    // self-delimiting frame.
    if cursor.remaining() != 0 {
        return Err(DecodeError::TrailingBytes {
            trailing: cursor.remaining(),
        });
    }
    Ok(event)
}

/// Encode a CBE uint head into `out`.  Internal helper for
/// `encode_event` and the integration tests.
fn write_uint(out: &mut Vec<u8>, n: u64) {
    out.push(CBE_TAG_UINT);
    out.extend_from_slice(&n.to_le_bytes());
}

/// Encode a CBE byte string into `out`.
fn write_byte_string(out: &mut Vec<u8>, payload: &[u8]) {
    out.push(CBE_TAG_BYTES);
    out.extend_from_slice(&(payload.len() as u64).to_le_bytes());
    out.extend_from_slice(payload);
}

/// Errors surfaced by [`encode_event_checked`].  Mirrors the
/// shape of `knomosis-l1-ingest/src/encoding.rs::EncodeError`.
#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum EncodeError {
    /// An `Amount` (or `Nonce`) field exceeded the CBE
    /// canonical-encoding bound (`< 2^64`).  The Lean encoder
    /// silently truncates such values; the Rust checked path
    /// rejects them so callers can surface the error to the
    /// operator.
    #[error("amount field {value} exceeds 2^64 CBE encoding bound")]
    AmountExceedsBound {
        /// The offending field's value.
        value: u128,
    },
}

/// Encode an Amount (u128 that fits in u64) into `out` — fallible.
/// Returns `EncodeError::AmountExceedsBound` if the value is
/// `>= 2^64`.  Mirrors `knomosis-l1-ingest::encoding::encode_u128_checked`.
fn write_amount_checked(out: &mut Vec<u8>, amount: Amount) -> Result<(), EncodeError> {
    if amount >= 1u128 << 64 {
        return Err(EncodeError::AmountExceedsBound { value: amount });
    }
    #[allow(clippy::cast_possible_truncation)] // bound-checked above
    let n = amount as u64;
    write_uint(out, n);
    Ok(())
}

/// Encode an Amount (u128 fitting in u64) into `out`.
///
/// **Silent truncation.**  The CBE convention restricts amounts
/// to `< 2^64`; this function silently truncates the high 64
/// bits of larger values, matching the Lean encoder's
/// documented behaviour for out-of-bounds `Nat`s.
///
/// Callers that want explicit rejection on overflow use
/// [`encode_event_checked`] (which calls [`write_amount_checked`]
/// instead).  This unchecked variant is reserved for the test
/// path where synthetic events are bounded by construction;
/// production code that handles arbitrary Amount values should
/// route through the checked variant.
fn write_amount(out: &mut Vec<u8>, amount: Amount) {
    let n = (amount & u128::from(u64::MAX)) as u64;
    write_uint(out, n);
}

/// Encode a `BudgetUnits` (u128 fitting in u64) into `out`.
/// Same wire encoding as [`write_amount`]; the alias keeps the
/// per-field discipline readable on the GP-family encoder arms.
fn write_budget_units(out: &mut Vec<u8>, units: BudgetUnits) {
    let n = (units & u128::from(u64::MAX)) as u64;
    write_uint(out, n);
}

/// Encode a `BudgetUnits` into `out`, rejecting values `>= 2^64`.
/// Sibling of [`write_amount_checked`] for the budget-unit fields.
fn write_budget_units_checked(out: &mut Vec<u8>, units: BudgetUnits) -> Result<(), EncodeError> {
    if units >= 1u128 << 64 {
        return Err(EncodeError::AmountExceedsBound { value: units });
    }
    #[allow(clippy::cast_possible_truncation)] // bound-checked above
    let n = units as u64;
    write_uint(out, n);
    Ok(())
}

/// Encode an EthAddress into `out` (as a 20-byte byte string).
fn write_eth_address(out: &mut Vec<u8>, addr: &EthAddress) {
    write_byte_string(out, addr);
}

/// Re-encode an event back to bytes.  Inverse of [`decode_event`]
/// up to the `Amount`-fits-in-u64 bound (per CBE).
///
/// **Public** because it is cross-checked **byte-for-byte** against the
/// Lean-side `Encoding.Event.encode` authority (the `instEncodableEvent`
/// instance in `LegalKernel/Encoding/Event.lean`): the
/// `tests/cross_stack_lean_event.rs` pin decodes every entry of the
/// Lean-generated `event_subscribe_cbe.json` fixture and asserts
/// `encode_event` reproduces the exact Lean bytes — the same mechanism by
/// which `knomosis-l1-ingest` cross-checks its `encode_action` against
/// `Encoding.Action.encode`.  (The gateway lifts this pin to its §6.2 JSON
/// envelope in `knomosis-gateway/tests/cross_stack_lean_event.rs`.)
#[must_use]
pub fn encode_event(event: &Event) -> Vec<u8> {
    let mut out = Vec::new();
    write_uint(&mut out, u64::from(event.tag()));
    match event {
        Event::BalanceChanged {
            resource,
            actor,
            old_value,
            new_value,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *actor);
            write_amount(&mut out, *old_value);
            write_amount(&mut out, *new_value);
        }
        Event::NonceAdvanced {
            actor,
            old_nonce,
            new_nonce,
        } => {
            write_uint(&mut out, *actor);
            write_amount(&mut out, *old_nonce);
            write_amount(&mut out, *new_nonce);
        }
        Event::IdentityRegistered { actor, key } => {
            write_uint(&mut out, *actor);
            write_byte_string(&mut out, key);
        }
        Event::IdentityRevoked { actor } | Event::LocalPolicyRevoked { actor } => {
            write_uint(&mut out, *actor);
        }
        Event::TimeRecorded { time } => {
            write_uint(&mut out, *time);
        }
        Event::DisputeFiled {
            challenger,
            target_idx,
        } => {
            write_uint(&mut out, *challenger);
            write_uint(&mut out, *target_idx);
        }
        Event::DisputeWithdrawn { dispute_idx } => {
            write_uint(&mut out, *dispute_idx);
        }
        Event::VerdictApplied {
            dispute_idx,
            outcome_tag,
        } => {
            write_uint(&mut out, *dispute_idx);
            write_uint(&mut out, *outcome_tag);
        }
        Event::RewardIssued {
            resource,
            recipient,
            amount,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *recipient);
            write_amount(&mut out, *amount);
        }
        Event::WithdrawalRequested {
            resource,
            sender,
            amount,
            recipient_l1,
            withdrawal_id,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *sender);
            write_amount(&mut out, *amount);
            write_eth_address(&mut out, recipient_l1);
            write_uint(&mut out, *withdrawal_id);
        }
        Event::DepositCredited {
            resource,
            recipient,
            amount,
            deposit_id,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *recipient);
            write_amount(&mut out, *amount);
            write_uint(&mut out, *deposit_id);
        }
        Event::LocalPolicyDeclared { actor, policy } => {
            write_uint(&mut out, *actor);
            write_byte_string(&mut out, policy);
        }
        Event::FaultProofGameOpened {
            game_id,
            challenger,
            disputed_start_idx,
            disputed_end_idx,
            binding_hash,
        } => {
            write_uint(&mut out, *game_id);
            write_uint(&mut out, *challenger);
            write_uint(&mut out, *disputed_start_idx);
            write_uint(&mut out, *disputed_end_idx);
            write_byte_string(&mut out, binding_hash);
        }
        Event::FaultProofBisectionStep {
            game_id,
            round,
            party,
            idx,
            commit,
        } => {
            write_uint(&mut out, *game_id);
            write_uint(&mut out, *round);
            write_uint(&mut out, *party);
            write_uint(&mut out, *idx);
            write_byte_string(&mut out, commit);
        }
        Event::FaultProofGameSettled {
            game_id,
            winner,
            loser,
            payout,
        } => {
            write_uint(&mut out, *game_id);
            write_uint(&mut out, *winner);
            write_uint(&mut out, *loser);
            write_amount(&mut out, *payout);
        }
        Event::DepositWithFeeCredited {
            resource,
            recipient,
            pool_actor,
            user_amount,
            pool_amount,
            budget_grant,
            deposit_id,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *recipient);
            write_uint(&mut out, *pool_actor);
            write_amount(&mut out, *user_amount);
            write_amount(&mut out, *pool_amount);
            write_budget_units(&mut out, *budget_grant);
            write_uint(&mut out, *deposit_id);
        }
        Event::ActionBudgetTopUp {
            signer,
            gas_resource,
            gas_amount,
            budget_increment,
            pool_actor,
        } => {
            write_uint(&mut out, *signer);
            write_uint(&mut out, *gas_resource);
            write_amount(&mut out, *gas_amount);
            write_budget_units(&mut out, *budget_increment);
            write_uint(&mut out, *pool_actor);
        }
        Event::GasPoolClaim {
            resource,
            sequencer,
            amount,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *sequencer);
            write_amount(&mut out, *amount);
        }
        Event::DelegatedActionBudgetTopUp {
            recipient,
            signer,
            gas_resource,
            gas_amount,
            budget_increment,
            pool_actor,
        } => {
            write_uint(&mut out, *recipient);
            write_uint(&mut out, *signer);
            write_uint(&mut out, *gas_resource);
            write_amount(&mut out, *gas_amount);
            write_budget_units(&mut out, *budget_increment);
            write_uint(&mut out, *pool_actor);
        }
        Event::BudgetConsumed { actor, amount } => {
            write_uint(&mut out, *actor);
            write_budget_units(&mut out, *amount);
        }
        Event::AmmSwapExecuted {
            from_resource,
            to_resource,
            amount_in,
            amount_out,
            amm_reserve_actor,
        } => {
            write_uint(&mut out, *from_resource);
            write_uint(&mut out, *to_resource);
            write_amount(&mut out, *amount_in);
            write_amount(&mut out, *amount_out);
            write_uint(&mut out, *amm_reserve_actor);
        }
        Event::AmmReservesReclaimed {
            resource,
            amount,
            reserve_actor,
            pool_actor,
        } => {
            write_uint(&mut out, *resource);
            write_amount(&mut out, *amount);
            write_uint(&mut out, *reserve_actor);
            write_uint(&mut out, *pool_actor);
        }
    }
    out
}

/// Re-encode an event back to bytes, rejecting amounts >= 2^64
/// with [`EncodeError::AmountExceedsBound`].
///
/// This is the **safe** variant of [`encode_event`].  Production
/// code that handles arbitrary Amount values (e.g., values sourced
/// from operator input or external systems) should route through
/// this function instead of `encode_event`.  The unchecked
/// `encode_event` silently truncates to match the Lean encoder's
/// documented behaviour for out-of-bounds Nats — appropriate for
/// the test path where Amounts are bounded by construction, but a
/// footgun for general use.
///
/// # Errors
///
/// Returns [`EncodeError::AmountExceedsBound`] if any of the
/// event's `Amount` / `Nonce` / `payout` fields is `>= 2^64`.
pub fn encode_event_checked(event: &Event) -> Result<Vec<u8>, EncodeError> {
    let mut out = Vec::new();
    write_uint(&mut out, u64::from(event.tag()));
    match event {
        Event::BalanceChanged {
            resource,
            actor,
            old_value,
            new_value,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *actor);
            write_amount_checked(&mut out, *old_value)?;
            write_amount_checked(&mut out, *new_value)?;
        }
        Event::NonceAdvanced {
            actor,
            old_nonce,
            new_nonce,
        } => {
            write_uint(&mut out, *actor);
            write_amount_checked(&mut out, *old_nonce)?;
            write_amount_checked(&mut out, *new_nonce)?;
        }
        Event::IdentityRegistered { actor, key } => {
            write_uint(&mut out, *actor);
            write_byte_string(&mut out, key);
        }
        Event::IdentityRevoked { actor } | Event::LocalPolicyRevoked { actor } => {
            write_uint(&mut out, *actor);
        }
        Event::TimeRecorded { time } => {
            write_uint(&mut out, *time);
        }
        Event::DisputeFiled {
            challenger,
            target_idx,
        } => {
            write_uint(&mut out, *challenger);
            write_uint(&mut out, *target_idx);
        }
        Event::DisputeWithdrawn { dispute_idx } => {
            write_uint(&mut out, *dispute_idx);
        }
        Event::VerdictApplied {
            dispute_idx,
            outcome_tag,
        } => {
            write_uint(&mut out, *dispute_idx);
            write_uint(&mut out, *outcome_tag);
        }
        Event::RewardIssued {
            resource,
            recipient,
            amount,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *recipient);
            write_amount_checked(&mut out, *amount)?;
        }
        Event::WithdrawalRequested {
            resource,
            sender,
            amount,
            recipient_l1,
            withdrawal_id,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *sender);
            write_amount_checked(&mut out, *amount)?;
            write_eth_address(&mut out, recipient_l1);
            write_uint(&mut out, *withdrawal_id);
        }
        Event::DepositCredited {
            resource,
            recipient,
            amount,
            deposit_id,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *recipient);
            write_amount_checked(&mut out, *amount)?;
            write_uint(&mut out, *deposit_id);
        }
        Event::LocalPolicyDeclared { actor, policy } => {
            write_uint(&mut out, *actor);
            write_byte_string(&mut out, policy);
        }
        Event::FaultProofGameOpened {
            game_id,
            challenger,
            disputed_start_idx,
            disputed_end_idx,
            binding_hash,
        } => {
            write_uint(&mut out, *game_id);
            write_uint(&mut out, *challenger);
            write_uint(&mut out, *disputed_start_idx);
            write_uint(&mut out, *disputed_end_idx);
            write_byte_string(&mut out, binding_hash);
        }
        Event::FaultProofBisectionStep {
            game_id,
            round,
            party,
            idx,
            commit,
        } => {
            write_uint(&mut out, *game_id);
            write_uint(&mut out, *round);
            write_uint(&mut out, *party);
            write_uint(&mut out, *idx);
            write_byte_string(&mut out, commit);
        }
        Event::FaultProofGameSettled {
            game_id,
            winner,
            loser,
            payout,
        } => {
            write_uint(&mut out, *game_id);
            write_uint(&mut out, *winner);
            write_uint(&mut out, *loser);
            write_amount_checked(&mut out, *payout)?;
        }
        Event::DepositWithFeeCredited {
            resource,
            recipient,
            pool_actor,
            user_amount,
            pool_amount,
            budget_grant,
            deposit_id,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *recipient);
            write_uint(&mut out, *pool_actor);
            write_amount_checked(&mut out, *user_amount)?;
            write_amount_checked(&mut out, *pool_amount)?;
            write_budget_units_checked(&mut out, *budget_grant)?;
            write_uint(&mut out, *deposit_id);
        }
        Event::ActionBudgetTopUp {
            signer,
            gas_resource,
            gas_amount,
            budget_increment,
            pool_actor,
        } => {
            write_uint(&mut out, *signer);
            write_uint(&mut out, *gas_resource);
            write_amount_checked(&mut out, *gas_amount)?;
            write_budget_units_checked(&mut out, *budget_increment)?;
            write_uint(&mut out, *pool_actor);
        }
        Event::GasPoolClaim {
            resource,
            sequencer,
            amount,
        } => {
            write_uint(&mut out, *resource);
            write_uint(&mut out, *sequencer);
            write_amount_checked(&mut out, *amount)?;
        }
        Event::DelegatedActionBudgetTopUp {
            recipient,
            signer,
            gas_resource,
            gas_amount,
            budget_increment,
            pool_actor,
        } => {
            write_uint(&mut out, *recipient);
            write_uint(&mut out, *signer);
            write_uint(&mut out, *gas_resource);
            write_amount_checked(&mut out, *gas_amount)?;
            write_budget_units_checked(&mut out, *budget_increment)?;
            write_uint(&mut out, *pool_actor);
        }
        Event::BudgetConsumed { actor, amount } => {
            write_uint(&mut out, *actor);
            write_budget_units_checked(&mut out, *amount)?;
        }
        Event::AmmSwapExecuted {
            from_resource,
            to_resource,
            amount_in,
            amount_out,
            amm_reserve_actor,
        } => {
            write_uint(&mut out, *from_resource);
            write_uint(&mut out, *to_resource);
            write_amount_checked(&mut out, *amount_in)?;
            write_amount_checked(&mut out, *amount_out)?;
            write_uint(&mut out, *amm_reserve_actor);
        }
        Event::AmmReservesReclaimed {
            resource,
            amount,
            reserve_actor,
            pool_actor,
        } => {
            write_uint(&mut out, *resource);
            write_amount_checked(&mut out, *amount)?;
            write_uint(&mut out, *reserve_actor);
            write_uint(&mut out, *pool_actor);
        }
    }
    Ok(out)
}

/// Convenience: an Amount value as a fixed-length 16-byte BE u128
/// byte string suitable for storage as a balance value.  Used by
/// the balance store and the indexer.  Not part of the CBE wire
/// format; this is a stable on-disk representation of an Amount
/// for storage purposes only.
#[must_use]
pub fn amount_to_be_bytes(amount: Amount) -> [u8; 16] {
    amount.to_be_bytes()
}

/// Reverse of [`amount_to_be_bytes`].  Decodes a 16-byte BE u128
/// back to an Amount.  Returns the value (any 16-byte input is a
/// valid u128, so no error path).
#[must_use]
pub fn amount_from_be_bytes(bytes: &[u8; 16]) -> Amount {
    Amount::from_be_bytes(*bytes)
}

/// Re-exports of the per-type aliases for downstream consumers
/// that just need the decoder.  Mirrors the same set in
/// `crate::event`.
pub use crate::event::{ActorId as DActorId, Amount as DAmount, ResourceId as DResourceId};

#[allow(dead_code)] // alias kept for naming consistency in tests
type _Aliases = (
    DActorId,
    DAmount,
    DResourceId,
    Nonce,
    DepositId,
    WithdrawalId,
);

#[cfg(test)]
mod tests {
    use super::{
        decode_event, encode_event, encode_event_checked, DecodeError, ETH_ADDRESS_BYTES,
        HARD_MAX_BYTE_STRING_LEN, HEAD_LEN,
    };
    use crate::event::Event;

    /// Constants pinned (no silent drift).
    #[test]
    fn constants() {
        assert_eq!(HEAD_LEN, 9);
        assert_eq!(ETH_ADDRESS_BYTES, 20);
        assert_eq!(HARD_MAX_BYTE_STRING_LEN, 1024 * 1024);
    }

    /// Round-trip: every tag.
    #[test]
    fn round_trip_balance_changed() {
        let e = Event::BalanceChanged {
            resource: 7,
            actor: 42,
            old_value: 100,
            new_value: 250,
        };
        let bytes = encode_event(&e);
        let decoded = decode_event(&bytes).unwrap();
        assert_eq!(decoded, e);
    }

    #[test]
    fn round_trip_nonce_advanced() {
        let e = Event::NonceAdvanced {
            actor: 9,
            old_nonce: 0,
            new_nonce: 1,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_identity_registered() {
        let e = Event::IdentityRegistered {
            actor: 1,
            key: vec![0xab, 0xcd, 0xef],
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_identity_revoked() {
        let e = Event::IdentityRevoked { actor: 12 };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_time_recorded() {
        let e = Event::TimeRecorded {
            time: 1_700_000_000,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_dispute_filed() {
        let e = Event::DisputeFiled {
            challenger: 3,
            target_idx: 100,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_dispute_withdrawn() {
        let e = Event::DisputeWithdrawn { dispute_idx: 99 };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_verdict_applied() {
        let e = Event::VerdictApplied {
            dispute_idx: 99,
            outcome_tag: 0,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_reward_issued() {
        let e = Event::RewardIssued {
            resource: 2,
            recipient: 5,
            amount: 1_000_000,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_withdrawal_requested() {
        let e = Event::WithdrawalRequested {
            resource: 4,
            sender: 7,
            amount: 50_000,
            recipient_l1: [0x11; 20],
            withdrawal_id: 42,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_deposit_credited() {
        let e = Event::DepositCredited {
            resource: 4,
            recipient: 7,
            amount: 100_000,
            deposit_id: 42,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_local_policy_declared() {
        let e = Event::LocalPolicyDeclared {
            actor: 9,
            policy: vec![1, 2, 3, 4, 5],
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_local_policy_revoked() {
        let e = Event::LocalPolicyRevoked { actor: 9 };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_fault_proof_game_opened() {
        let e = Event::FaultProofGameOpened {
            game_id: 1,
            challenger: 2,
            disputed_start_idx: 3,
            disputed_end_idx: 4,
            binding_hash: vec![0xAB, 0xCD],
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_fault_proof_bisection_step() {
        let e = Event::FaultProofBisectionStep {
            game_id: 1,
            round: 5,
            party: 7,
            idx: 100,
            commit: vec![0xCC; 32],
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    #[test]
    fn round_trip_fault_proof_game_settled() {
        let e = Event::FaultProofGameSettled {
            game_id: 1,
            winner: 2,
            loser: 3,
            payout: 1000,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    /// Round-trip: `DepositWithFeeCredited` (GP tag 16).
    #[test]
    fn round_trip_deposit_with_fee_credited() {
        let e = Event::DepositWithFeeCredited {
            resource: 0,
            recipient: 42,
            pool_actor: 1,
            user_amount: 900,
            pool_amount: 100,
            budget_grant: 50,
            deposit_id: 7,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    /// Round-trip: `ActionBudgetTopUp` (GP tag 17).
    #[test]
    fn round_trip_action_budget_top_up() {
        let e = Event::ActionBudgetTopUp {
            signer: 99,
            gas_resource: 0,
            gas_amount: 10,
            budget_increment: 100,
            pool_actor: 1,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    /// Round-trip: `GasPoolClaim` (GP tag 18).
    #[test]
    fn round_trip_gas_pool_claim() {
        let e = Event::GasPoolClaim {
            resource: 0,
            sequencer: 2,
            amount: 5000,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    /// Round-trip: `DelegatedActionBudgetTopUp` (GP tag 19).
    #[test]
    fn round_trip_delegated_action_budget_top_up() {
        let e = Event::DelegatedActionBudgetTopUp {
            recipient: 55,
            signer: 77,
            gas_resource: 0,
            gas_amount: 10,
            budget_increment: 100,
            pool_actor: 1,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    /// Round-trip: `BudgetConsumed` (GP tag 20, GP.6.4).
    #[test]
    fn round_trip_budget_consumed() {
        let e = Event::BudgetConsumed {
            actor: 42,
            amount: 1,
        };
        let bytes = encode_event(&e);
        assert_eq!(decode_event(&bytes).unwrap(), e);
    }

    /// GP tag-20 wire-layout: `BudgetConsumed` has 2 fields × 9
    /// bytes = 18 bytes + 9 tag-head = 27 bytes total.  Pin the
    /// byte layout against the Lean encoder.
    #[test]
    fn budget_consumed_byte_layout() {
        let e = Event::BudgetConsumed {
            actor: 42,
            amount: 1,
        };
        let bytes = encode_event(&e);
        assert_eq!(bytes.len(), 27);
        // Tag head: 0x00 + 8-byte LE 20.
        assert_eq!(bytes[0], 0x00);
        assert_eq!(&bytes[1..9], &20u64.to_le_bytes());
        // Field 1: actor = 42.
        assert_eq!(bytes[9], 0x00);
        assert_eq!(&bytes[10..18], &42u64.to_le_bytes());
        // Field 2: amount = 1.
        assert_eq!(bytes[18], 0x00);
        assert_eq!(&bytes[19..27], &1u64.to_le_bytes());
    }

    /// GP tag-16 wire-layout: `DepositWithFeeCredited` is the
    /// widest GP variant — pin the byte count + tag head.
    /// Layout: 1 tag-head + 7 fields × 9 bytes = 72 bytes.
    #[test]
    fn deposit_with_fee_credited_byte_layout() {
        let e = Event::DepositWithFeeCredited {
            resource: 1,
            recipient: 2,
            pool_actor: 3,
            user_amount: 4,
            pool_amount: 5,
            budget_grant: 6,
            deposit_id: 7,
        };
        let bytes = encode_event(&e);
        // tag(9) + resource(9) + recipient(9) + pool_actor(9)
        // + user_amount(9) + pool_amount(9) + budget_grant(9)
        // + deposit_id(9) = 72 bytes.
        assert_eq!(bytes.len(), 72);
        // Tag head: 0x00 + 8-byte LE 16.
        assert_eq!(bytes[0], 0x00);
        assert_eq!(&bytes[1..9], &16u64.to_le_bytes());
        // Resource head.
        assert_eq!(bytes[9], 0x00);
        assert_eq!(&bytes[10..18], &1u64.to_le_bytes());
        // Spot-check field-7 (deposit_id) head.
        assert_eq!(bytes[63], 0x00);
        assert_eq!(&bytes[64..72], &7u64.to_le_bytes());
    }

    /// GP tag-19 wire-layout: `DelegatedActionBudgetTopUp` has
    /// 6 fields × 9 bytes = 54 bytes + 9 tag-head = 63 bytes.
    #[test]
    fn delegated_action_budget_top_up_byte_layout() {
        let e = Event::DelegatedActionBudgetTopUp {
            recipient: 55,
            signer: 77,
            gas_resource: 0,
            gas_amount: 10,
            budget_increment: 100,
            pool_actor: 1,
        };
        let bytes = encode_event(&e);
        assert_eq!(bytes.len(), 63);
        // Tag head: 0x00 + 8-byte LE 19.
        assert_eq!(bytes[0], 0x00);
        assert_eq!(&bytes[1..9], &19u64.to_le_bytes());
        // First field: recipient = 55 (NOT signer — the load-bearing
        // ordering distinguishes this variant from tag 17).
        assert_eq!(bytes[9], 0x00);
        assert_eq!(&bytes[10..18], &55u64.to_le_bytes());
        // Second field: signer = 77.
        assert_eq!(bytes[18], 0x00);
        assert_eq!(&bytes[19..27], &77u64.to_le_bytes());
    }

    /// Tag 17 (`ActionBudgetTopUp`) and tag 19
    /// (`DelegatedActionBudgetTopUp`) MUST produce
    /// byte-distinguishable encodings even for "identical-shape"
    /// data — the leading tag separator + field-order swap on the
    /// first two fields makes them non-colliding.
    #[test]
    fn tag_17_and_19_byte_distinct() {
        // Field overlap: signer = 77, gas_resource = 0,
        // gas_amount = 10, budget_increment = 100, pool_actor = 1.
        let e17 = Event::ActionBudgetTopUp {
            signer: 77,
            gas_resource: 0,
            gas_amount: 10,
            budget_increment: 100,
            pool_actor: 1,
        };
        // Tag 19 has the same trailing 5 fields if recipient = 77,
        // but the recipient field comes BEFORE signer in tag 19.
        let e19 = Event::DelegatedActionBudgetTopUp {
            recipient: 77,
            signer: 77,
            gas_resource: 0,
            gas_amount: 10,
            budget_increment: 100,
            pool_actor: 1,
        };
        let b17 = encode_event(&e17);
        let b19 = encode_event(&e19);
        // Different lengths: tag 17 has 5 fields, tag 19 has 6.
        assert!(b17.len() < b19.len(), "tag 19 must be longer");
        // Leading tag bytes differ.
        assert_eq!(&b17[1..9], &17u64.to_le_bytes());
        assert_eq!(&b19[1..9], &19u64.to_le_bytes());
    }

    /// Checked encoder accepts bounded GP-family amounts.
    #[test]
    fn encode_event_checked_accepts_gp_family() {
        let events = vec![
            Event::DepositWithFeeCredited {
                resource: 0,
                recipient: 42,
                pool_actor: 1,
                user_amount: 900,
                pool_amount: 100,
                budget_grant: 50,
                deposit_id: 7,
            },
            Event::ActionBudgetTopUp {
                signer: 99,
                gas_resource: 0,
                gas_amount: 10,
                budget_increment: 100,
                pool_actor: 1,
            },
            Event::GasPoolClaim {
                resource: 0,
                sequencer: 2,
                amount: 5000,
            },
            Event::DelegatedActionBudgetTopUp {
                recipient: 55,
                signer: 77,
                gas_resource: 0,
                gas_amount: 10,
                budget_increment: 100,
                pool_actor: 1,
            },
        ];
        for e in &events {
            let checked = encode_event_checked(e).unwrap();
            let unchecked = encode_event(e);
            assert_eq!(checked, unchecked, "byte mismatch for {e:?}");
            let decoded = decode_event(&checked).unwrap();
            assert_eq!(decoded, *e);
        }
    }

    /// Checked encoder rejects out-of-range `budget_grant`.
    #[test]
    fn encode_event_checked_rejects_oversize_budget_grant() {
        let e = Event::DepositWithFeeCredited {
            resource: 0,
            recipient: 0,
            pool_actor: 0,
            user_amount: 0,
            pool_amount: 0,
            budget_grant: 1u128 << 64, // exactly 2^64 — out of range
            deposit_id: 0,
        };
        match encode_event_checked(&e) {
            Err(super::EncodeError::AmountExceedsBound { value }) => {
                assert_eq!(value, 1u128 << 64);
            }
            other => panic!("expected AmountExceedsBound, got {other:?}"),
        }
    }

    /// Checked encoder rejects out-of-range `budget_increment`
    /// on tag 17.
    #[test]
    fn encode_event_checked_rejects_oversize_budget_increment_tag17() {
        let e = Event::ActionBudgetTopUp {
            signer: 0,
            gas_resource: 0,
            gas_amount: 0,
            budget_increment: u128::MAX,
            pool_actor: 0,
        };
        assert!(matches!(
            encode_event_checked(&e),
            Err(super::EncodeError::AmountExceedsBound { .. })
        ));
    }

    /// Empty payload → Truncated at offset 0.
    #[test]
    fn empty_payload_truncated() {
        match decode_event(&[]) {
            Err(DecodeError::Truncated { offset, .. }) => assert_eq!(offset, 0),
            other => panic!("expected Truncated, got {other:?}"),
        }
    }

    /// Trailing bytes after a valid event → TrailingBytes.
    #[test]
    fn trailing_bytes_rejected() {
        let e = Event::IdentityRevoked { actor: 1 };
        let mut bytes = encode_event(&e);
        bytes.push(0xAA);
        bytes.push(0xBB);
        match decode_event(&bytes) {
            Err(DecodeError::TrailingBytes { trailing }) => assert_eq!(trailing, 2),
            other => panic!("expected TrailingBytes, got {other:?}"),
        }
    }

    /// Unknown tag.
    #[test]
    fn unknown_tag_rejected() {
        // Encode tag = 99 (unknown).
        let mut bytes = Vec::new();
        bytes.push(0x00); // CBE uint tag
        bytes.extend_from_slice(&99u64.to_le_bytes());
        match decode_event(&bytes) {
            Err(DecodeError::UnknownTag { tag }) => assert_eq!(tag, 99),
            other => panic!("expected UnknownTag, got {other:?}"),
        }
    }

    /// Bad head tag (using 0x03 instead of 0x00 for the
    /// constructor index head).
    #[test]
    fn bad_head_tag_rejected() {
        let mut bytes = Vec::new();
        bytes.push(0x03); // wrong tag (should be 0x00 for uint)
        bytes.extend_from_slice(&0u64.to_le_bytes());
        match decode_event(&bytes) {
            Err(DecodeError::BadHeadTag {
                offset,
                expected,
                actual,
            }) => {
                assert_eq!(offset, 0);
                assert_eq!(expected, 0x00);
                assert_eq!(actual, 0x03);
            }
            other => panic!("expected BadHeadTag, got {other:?}"),
        }
    }

    /// Mid-payload truncation.
    #[test]
    fn truncated_mid_payload() {
        let e = Event::BalanceChanged {
            resource: 1,
            actor: 2,
            old_value: 3,
            new_value: 4,
        };
        let bytes = encode_event(&e);
        // Truncate the last byte.
        let truncated = &bytes[..bytes.len() - 1];
        match decode_event(truncated) {
            Err(DecodeError::Truncated { .. }) => {}
            other => panic!("expected Truncated, got {other:?}"),
        }
    }

    /// Byte-string-too-long rejected.
    #[test]
    fn byte_string_too_long_rejected() {
        // Construct: tag=2 (IdentityRegistered), actor=0, key with
        // declared length exceeding the cap.
        let mut bytes = Vec::new();
        // Constructor tag = 2.
        bytes.push(0x00);
        bytes.extend_from_slice(&2u64.to_le_bytes());
        // actor = 0.
        bytes.push(0x00);
        bytes.extend_from_slice(&0u64.to_le_bytes());
        // key byte-string head: tag=0x02, length = HARD_MAX + 1.
        bytes.push(0x02);
        bytes.extend_from_slice(&(HARD_MAX_BYTE_STRING_LEN + 1).to_le_bytes());
        // (No payload — we never reach the read because the head's
        // length check fires first.)
        match decode_event(&bytes) {
            Err(DecodeError::ByteStringTooLong { .. }) => {}
            other => panic!("expected ByteStringTooLong, got {other:?}"),
        }
    }

    /// EthAddress with wrong length → BadByteStringLength.
    #[test]
    fn eth_address_wrong_length_rejected() {
        // Construct a WithdrawalRequested-shaped prefix with the
        // EthAddress field's length set to 21 instead of 20.
        let mut bytes = Vec::new();
        bytes.push(0x00); // tag-head start
        bytes.extend_from_slice(&9u64.to_le_bytes()); // tag=9
        for n in [1u64, 2, 3] {
            bytes.push(0x00);
            bytes.extend_from_slice(&n.to_le_bytes());
        }
        // recipient_l1: 21-byte byte string (one off).
        bytes.push(0x02);
        bytes.extend_from_slice(&21u64.to_le_bytes());
        bytes.extend_from_slice(&[0u8; 21]);
        // withdrawal_id (uint).
        bytes.push(0x00);
        bytes.extend_from_slice(&42u64.to_le_bytes());
        match decode_event(&bytes) {
            Err(DecodeError::BadByteStringLength {
                expected, actual, ..
            }) => {
                assert_eq!(expected, 20);
                assert_eq!(actual, 21);
            }
            other => panic!("expected BadByteStringLength, got {other:?}"),
        }
    }

    /// `encode_event` is deterministic (same event always
    /// produces the same bytes).
    #[test]
    fn encode_event_deterministic() {
        let e = Event::DepositCredited {
            resource: 7,
            recipient: 42,
            amount: 100,
            deposit_id: 1,
        };
        let a = encode_event(&e);
        let b = encode_event(&e);
        assert_eq!(a, b);
    }

    /// Encoding a `BalanceChanged` produces the expected layout
    /// byte-for-byte.  Pins the wire format.
    #[test]
    fn balance_changed_byte_layout() {
        let e = Event::BalanceChanged {
            resource: 1,
            actor: 2,
            old_value: 3,
            new_value: 4,
        };
        let bytes = encode_event(&e);
        // Tag head (5 fields × 9 bytes = 45 bytes total).
        assert_eq!(bytes.len(), 45);
        // tag = 0 at bytes 0..9.
        assert_eq!(bytes[0], 0x00);
        assert_eq!(&bytes[1..9], &0u64.to_le_bytes());
        // resource = 1 at bytes 9..18.
        assert_eq!(bytes[9], 0x00);
        assert_eq!(&bytes[10..18], &1u64.to_le_bytes());
        // actor = 2 at bytes 18..27.
        assert_eq!(bytes[18], 0x00);
        assert_eq!(&bytes[19..27], &2u64.to_le_bytes());
        // old_value = 3 at bytes 27..36.
        assert_eq!(bytes[27], 0x00);
        assert_eq!(&bytes[28..36], &3u64.to_le_bytes());
        // new_value = 4 at bytes 36..45.
        assert_eq!(bytes[36], 0x00);
        assert_eq!(&bytes[37..45], &4u64.to_le_bytes());
    }

    /// Decoder rejects every invalid input without panicking.
    /// Smoke test over a few adversarial byte patterns.
    #[test]
    fn decoder_does_not_panic_on_random_input() {
        let patterns: &[&[u8]] = &[
            &[],
            &[0x00],
            &[0xFF; 100],
            &[0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            &[0xFF; 1024],
        ];
        for p in patterns {
            // Either Ok or Err — never panic.
            let _ = decode_event(p);
        }
    }

    /// `encode_event_checked` accepts bounded amounts.
    #[test]
    fn encode_event_checked_accepts_bounded() {
        let e = Event::BalanceChanged {
            resource: 1,
            actor: 2,
            old_value: 100,
            new_value: 200,
        };
        let bytes = encode_event_checked(&e).unwrap();
        // Round-trip via the regular decoder.
        let decoded = decode_event(&bytes).unwrap();
        assert_eq!(decoded, e);
    }

    /// `encode_event_checked` rejects out-of-range amounts.
    #[test]
    fn encode_event_checked_rejects_overflow() {
        // u128::MAX exceeds 2^64.
        let e = Event::BalanceChanged {
            resource: 1,
            actor: 2,
            old_value: 0,
            new_value: u128::MAX,
        };
        let result = encode_event_checked(&e);
        match result {
            Err(super::EncodeError::AmountExceedsBound { value }) => {
                assert_eq!(value, u128::MAX);
            }
            other => panic!("expected AmountExceedsBound, got {other:?}"),
        }
    }

    /// `encode_event_checked` rejects exactly 2^64 (boundary).
    #[test]
    fn encode_event_checked_rejects_exact_boundary() {
        let e = Event::RewardIssued {
            resource: 0,
            recipient: 0,
            amount: 1u128 << 64, // exactly 2^64 — out of range
        };
        match encode_event_checked(&e) {
            Err(super::EncodeError::AmountExceedsBound { value }) => {
                assert_eq!(value, 1u128 << 64);
            }
            other => panic!("expected AmountExceedsBound, got {other:?}"),
        }
    }

    /// `encode_event_checked` accepts the largest in-range value
    /// (2^64 - 1).
    #[test]
    fn encode_event_checked_accepts_max_u64() {
        let e = Event::RewardIssued {
            resource: 0,
            recipient: 0,
            amount: u128::from(u64::MAX),
        };
        let bytes = encode_event_checked(&e).unwrap();
        let decoded = decode_event(&bytes).unwrap();
        assert_eq!(decoded, e);
    }

    /// `encode_event_checked` matches `encode_event` byte-for-byte
    /// for in-range amounts.
    #[test]
    fn encode_event_checked_matches_unchecked_in_range() {
        let events = vec![
            Event::BalanceChanged {
                resource: 1,
                actor: 2,
                old_value: 100,
                new_value: 200,
            },
            Event::NonceAdvanced {
                actor: 1,
                old_nonce: 0,
                new_nonce: 1,
            },
            Event::RewardIssued {
                resource: 0,
                recipient: 0,
                amount: u128::from(u64::MAX),
            },
            Event::FaultProofGameSettled {
                game_id: 1,
                winner: 2,
                loser: 3,
                payout: u128::from(u64::MAX),
            },
        ];
        for e in &events {
            let unchecked = encode_event(e);
            let checked = encode_event_checked(e).unwrap();
            assert_eq!(unchecked, checked, "byte mismatch for {e:?}");
        }
    }
}

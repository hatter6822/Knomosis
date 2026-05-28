// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! CBE (Canonical Binary Encoding) encoder/decoder matching the
//! Lean kernel's `LegalKernel.Encoding.*` modules.
//!
//! ## What CBE is
//!
//! CBE is the Knomosis project's wire encoding.  It uses canonical-
//! CBOR-style "major types" (uint / bytes / text / array / map),
//! but in a simplified fixed-width form:
//!
//!   * **Head:** 1-byte type tag + 8-byte little-endian Nat
//!     (length / count / value).  Single byte sequence per Nat
//!     in `[0, 2^64)`; no compactness variants.
//!   * **Uint:** head only.  Used for `Nat`, `Bool`, `ActorId`,
//!     `ResourceId`, etc.
//!   * **Byte string:** head (with `cbeTagBytes` = 0x02) +
//!     raw payload bytes.  Used for `ByteArray` /
//!     `PublicKey` / `EthAddress` (when encoded as bytes).
//!   * **Text string:** head (with `cbeTagText` = 0x03) + UTF-8
//!     payload.  Not used in `Action` directly — only in the
//!     signing-input domain prefix, which is encoded as a CBE
//!     **byte** string in this codebase (per
//!     `Authority/SignedAction.lean::signingInput`).
//!
//! ## Why hand-rolled
//!
//! Two factors:
//!
//!   1. **Byte-exact reproducibility.**  Every wire byte is
//!      intentional; a generic CBOR library would need extensive
//!      configuration (and might still drift on a minor version
//!      bump).  Hand-rolling makes the byte stream visible to
//!      audit.
//!   2. **Minimal dependency surface.**  The L1 ingestor pulls
//!      in `k256` and `sha3`; adding a CBOR crate would
//!      multiply the attack surface for negligible savings.
//!
//! ## Type-tag table
//!
//! Mirrors `LegalKernel/Encoding/CBOR.lean`:
//!
//! | Tag  | Major type       | Lean constant     |
//! |------|------------------|-------------------|
//! | 0x00 | unsigned int     | `cbeTagUint`      |
//! | 0x02 | byte string      | `cbeTagBytes`     |
//! | 0x03 | text string      | `cbeTagText`      |
//! | 0x04 | array            | `cbeTagArray`     |
//! | 0x05 | map              | `cbeTagMap`       |
//!
//! ## Encoding the `Action` inductive
//!
//! For each `Action` variant we emit:
//!
//!   1. The constructor tag (a CBE uint encoded as a 9-byte
//!      head — even though every tag is a small number, the head
//!      is fixed-width per `Encoding/Encodable.lean::
//!      instEncodableNat`).
//!   2. Each field in declaration order, encoded with its
//!      respective `Encodable` instance.
//!
//! See `action.rs` for the frozen tag table.

use crate::action::{Action, EthAddress};

/// CBE type tag for unsigned integers.  Matches Lean's
/// `Encoding.CBOR.cbeTagUint`.
pub const CBE_TAG_UINT: u8 = 0x00;

/// CBE type tag for byte strings.  Matches Lean's
/// `Encoding.CBOR.cbeTagBytes`.
pub const CBE_TAG_BYTES: u8 = 0x02;

/// The signing-input domain prefix.  Mirrors Lean's
/// `Authority.Crypto.signedActionDomain`.  Bytes here MUST equal
/// the Lean constant byte-for-byte (verified by the unit tests).
pub const SIGNED_ACTION_DOMAIN: &str = "legalkernel/v1/signedaction";

/// Length of a CBE head: 1 type tag byte + 8-byte LE Nat = 9 bytes.
pub const HEAD_LEN: usize = 9;

/// Encode `n` as an 8-byte little-endian `u64`.  Mirrors Lean's
/// `Encoding.CBOR.natToBytesLE n 8`.
///
/// **Bound contract.**  The Lean side documents that for `n ≥
/// 2^64` the high bits are silently truncated.  This Rust mirror
/// takes a `u64` argument, so the truncation is by type rather
/// than by runtime check — every caller has already proven the
/// `< 2^64` bound at the type system level.
fn write_u64_le(out: &mut Vec<u8>, n: u64) {
    // `n.to_le_bytes()` is `[u8; 8]` in little-endian byte order.
    // This is exactly the byte sequence Lean's `natToBytesLE n 8`
    // produces under the `n < 2^64` precondition.
    out.extend_from_slice(&n.to_le_bytes());
}

/// Encode a single CBE head: type-tag byte + 8-byte LE length /
/// value.  Mirrors Lean's `Encoding.CBOR.cborHeadEncode`.
fn write_head(out: &mut Vec<u8>, tag: u8, n: u64) {
    out.push(tag);
    write_u64_le(out, n);
}

/// Encode a `u64` as a CBE uint.  Mirrors Lean's
/// `Encoding.Encodable.encode (T := Nat)`.
pub fn encode_u64(value: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEAD_LEN);
    write_head(&mut out, CBE_TAG_UINT, value);
    out
}

/// Encode a `u128` as a CBE uint, asserting it fits in `u64`.
/// `Amount` and `Nonce` are typed as `u128` on the Rust side to
/// mirror Lean's unbounded `Nat`; the encoder requires `< 2^64`
/// by CBE contract.  Out-of-range values are *not* silently
/// truncated — the caller receives `None`.
///
/// This is the safer Rust mirror of Lean's
/// `Encoding.Encodable.encode (T := Nat)`: Lean documents that
/// out-of-range values are silently truncated; the Rust runtime
/// surface rejects them.  Callers are obligated to validate
/// fields against `Action.fieldsBounded` before encoding.
pub fn encode_u128_checked(value: u128) -> Option<Vec<u8>> {
    if value >= 1u128 << 64 {
        return None;
    }
    #[allow(clippy::cast_possible_truncation)] // bound checked above
    let n = value as u64;
    Some(encode_u64(n))
}

/// Encode raw bytes as a CBE byte string: head (`CBE_TAG_BYTES`,
/// length) followed by the payload.  Mirrors Lean's
/// `Encoding.Encodable.encode (T := ByteArray)`.
///
/// Returns `None` when `bytes.len()` would exceed the canonical
/// `< 2^64` bound.  On every supported 64-bit host, `usize`
/// already fits in `u64`; the bound check is a wire-format
/// invariant statement that future-proofs against wider
/// pointer-width hosts.
pub fn encode_bytes_checked(bytes: &[u8]) -> Option<Vec<u8>> {
    let len = bytes.len();
    // Use `u64::try_from` rather than a runtime `<` check; this
    // expresses "length must fit in u64" at the type level on
    // hypothetical wider-pointer hosts, and is a no-op on 64-bit
    // targets where `usize` already fits.
    let len_u64 = u64::try_from(len).ok()?;
    let mut out = Vec::with_capacity(HEAD_LEN + len);
    write_head(&mut out, CBE_TAG_BYTES, len_u64);
    out.extend_from_slice(bytes);
    Some(out)
}

/// Errors surfaced when encoding an `Action`.  Each variant
/// corresponds to a violation of the Lean-side
/// `Action.fieldsBounded` predicate.
#[derive(Debug, Eq, PartialEq, thiserror::Error)]
pub enum EncodeError {
    /// A numeric field exceeded the canonical-encoding bound
    /// (`< 2^64`).  Carries the offending value for diagnostics.
    #[error("field value {value} exceeds 2^64 canonical-encoding bound")]
    FieldExceedsBound {
        /// The offending field's value.
        value: u128,
    },
    /// A byte-string field's length exceeded the canonical-
    /// encoding bound (`< 2^64`).  Unreachable on any 64-bit
    /// host but the boundary check stays.
    #[error("byte-string length {len} exceeds 2^64 canonical-encoding bound")]
    LengthExceedsBound {
        /// The offending field's byte length.
        len: usize,
    },
}

/// Encode an `Action` as a CBE byte stream.  Returns
/// `EncodeError` if any field violates `Action.fieldsBounded`.
///
/// Byte-equivalence to Lean's `Encoding.Action.encode` is the
/// load-bearing cross-stack contract; verified by every
/// `FixtureKind::L1Ingest` corpus record.
///
/// # Errors
///
/// Returns `EncodeError::FieldExceedsBound` if any numeric field
/// is `>= 2^64`.  Returns `EncodeError::LengthExceedsBound` if a
/// byte-string field's length is `>= 2^64` (unreachable on 64-bit
/// hosts).
pub fn encode_action(action: &Action) -> Result<Vec<u8>, EncodeError> {
    let mut out = Vec::new();
    // First field: constructor tag.
    out.extend_from_slice(&encode_u64(action.tag()));
    match action {
        Action::Transfer {
            r,
            sender,
            receiver,
            amount,
        } => {
            out.extend_from_slice(&encode_u64(*r));
            out.extend_from_slice(&encode_u64(*sender));
            out.extend_from_slice(&encode_u64(*receiver));
            out.extend_from_slice(&encode_amount(*amount)?);
        }
        Action::Mint { r, to, amount } => {
            out.extend_from_slice(&encode_u64(*r));
            out.extend_from_slice(&encode_u64(*to));
            out.extend_from_slice(&encode_amount(*amount)?);
        }
        Action::Burn {
            r,
            from_actor,
            amount,
        } => {
            out.extend_from_slice(&encode_u64(*r));
            out.extend_from_slice(&encode_u64(*from_actor));
            out.extend_from_slice(&encode_amount(*amount)?);
        }
        Action::FreezeResource { r } => {
            out.extend_from_slice(&encode_u64(*r));
        }
        Action::ReplaceKey { actor, new_key } => {
            out.extend_from_slice(&encode_u64(*actor));
            out.extend_from_slice(&encode_byte_string(new_key.as_bytes())?);
        }
        Action::Reward { r, to, amount } => {
            out.extend_from_slice(&encode_u64(*r));
            out.extend_from_slice(&encode_u64(*to));
            out.extend_from_slice(&encode_amount(*amount)?);
        }
        Action::DistributeOthers {
            r,
            excluded,
            amount,
        } => {
            out.extend_from_slice(&encode_u64(*r));
            out.extend_from_slice(&encode_u64(*excluded));
            out.extend_from_slice(&encode_amount(*amount)?);
        }
        Action::ProportionalDilute {
            r,
            excluded,
            total_reward,
        } => {
            out.extend_from_slice(&encode_u64(*r));
            out.extend_from_slice(&encode_u64(*excluded));
            out.extend_from_slice(&encode_amount(*total_reward)?);
        }
        Action::DisputeWithdraw { idx } => {
            out.extend_from_slice(&encode_u64(*idx));
        }
        Action::Rollback { target_idx } => {
            out.extend_from_slice(&encode_u64(*target_idx));
        }
        Action::RegisterIdentity { actor, pk } => {
            out.extend_from_slice(&encode_u64(*actor));
            out.extend_from_slice(&encode_byte_string(pk.as_bytes())?);
        }
        Action::Deposit {
            r,
            recipient,
            amount,
            deposit_id,
        } => {
            out.extend_from_slice(&encode_u64(*r));
            out.extend_from_slice(&encode_u64(*recipient));
            out.extend_from_slice(&encode_amount(*amount)?);
            out.extend_from_slice(&encode_u64(*deposit_id));
        }
        Action::Withdraw {
            r,
            sender,
            amount,
            recipient_l1,
        } => {
            out.extend_from_slice(&encode_u64(*r));
            out.extend_from_slice(&encode_u64(*sender));
            out.extend_from_slice(&encode_amount(*amount)?);
            // The L1 recipient is encoded as a 20-byte byte
            // string (lossless), per Audit-2's amendment of
            // `Encoding/Action.lean`.
            out.extend_from_slice(&encode_byte_string(recipient_l1.as_bytes())?);
        }
        Action::RevokeLocalPolicy => {
            // No fields after the tag.
        }
        Action::FaultProofChallenge {
            binding_hash,
            disputed_start_idx,
            disputed_end_idx,
            challenger_commit,
        } => {
            out.extend_from_slice(&encode_byte_string(binding_hash)?);
            out.extend_from_slice(&encode_u64(*disputed_start_idx));
            out.extend_from_slice(&encode_u64(*disputed_end_idx));
            out.extend_from_slice(&encode_byte_string(challenger_commit)?);
        }
        Action::FaultProofResolution {
            binding_hash,
            game_id,
            winner,
            revert_from_idx,
        } => {
            out.extend_from_slice(&encode_byte_string(binding_hash)?);
            out.extend_from_slice(
                &encode_u128_checked(*game_id)
                    .ok_or(EncodeError::FieldExceedsBound { value: *game_id })?,
            );
            out.extend_from_slice(&encode_u64(*winner));
            out.extend_from_slice(&encode_u64(*revert_from_idx));
        }
    }
    Ok(out)
}

/// Encode an `Amount` (`u128` on the Rust side) as a CBE uint.
/// Wrapping helper that reports `EncodeError::FieldExceedsBound`
/// for out-of-range inputs.
fn encode_amount(amount: u128) -> Result<Vec<u8>, EncodeError> {
    encode_u128_checked(amount).ok_or(EncodeError::FieldExceedsBound { value: amount })
}

/// Encode a byte slice as a CBE byte string, reporting
/// `EncodeError::LengthExceedsBound` if the length exceeds
/// `2^64`.
fn encode_byte_string(bytes: &[u8]) -> Result<Vec<u8>, EncodeError> {
    encode_bytes_checked(bytes).ok_or(EncodeError::LengthExceedsBound { len: bytes.len() })
}

/// Compute the signing-input bytes for a `(action, signer, nonce,
/// deployment_id)` quadruple.  Mirrors Lean's
/// `Authority.SignedAction.signingInput`.
///
/// Layout (concatenation of CBE encodings, in order):
///
///   1. **Domain prefix** — `signedActionDomain` (the ASCII
///      string `"legalkernel/v1/signedaction"`, 27 bytes)
///      encoded as a CBE byte string (head + raw bytes).
///   2. `Encodable.encode (T := ByteArray) deploymentId`.
///   3. `Encodable.encode (T := Action) action`.
///   4. `Encodable.encode (T := Nat) signer.toNat`.
///   5. `Encodable.encode (T := Nat) nonce`.
///
/// The first prefix component is a length-prefixed CBE byte
/// string, so the concatenation is self-delimiting and injective
/// in `(action, signer, nonce, deploymentId)`.
///
/// # Errors
///
/// Returns `EncodeError::FieldExceedsBound` if `signer >= 2^64`
/// (unreachable for `u64`-typed signers) or `nonce >= 2^64`.
/// Propagates `EncodeError` from the inner `Action` encoding.
pub fn signing_input(
    action: &Action,
    signer: u64,
    nonce: u128,
    deployment_id: &[u8],
) -> Result<Vec<u8>, EncodeError> {
    let mut out = Vec::new();
    // Domain prefix: CBE byte string wrapping the ASCII bytes of
    // `signedActionDomain`.  The wrapping uses CBE_TAG_BYTES per
    // Lean's `Authority/SignedAction.lean::signingInput` (NOT
    // `cbeTagText` — the domain prefix is treated as a byte
    // string for self-delimiting framing).
    let domain_bytes = SIGNED_ACTION_DOMAIN.as_bytes();
    out.extend_from_slice(&encode_byte_string(domain_bytes)?);
    // Deployment id, action, signer, nonce — in that order.
    out.extend_from_slice(&encode_byte_string(deployment_id)?);
    out.extend_from_slice(&encode_action(action)?);
    out.extend_from_slice(&encode_u64(signer));
    out.extend_from_slice(&encode_amount(nonce)?);
    Ok(out)
}

/// Encode a `SignedAction` — `(action, signer, nonce, sig)`
/// quadruple — as a CBE byte stream.  Mirrors Lean's
/// `Encoding.SignedAction.encode`.
///
/// Layout (per `Encoding/SignedAction.lean`): four sequential
/// CBE-encoded fields in declaration order.  No constructor tag
/// (the `SignedAction` is a structure, not a tagged sum).
///
/// # Errors
///
/// Propagates `EncodeError` from the inner `Action` and signature
/// encoding.
pub fn encode_signed_action(
    action: &Action,
    signer: u64,
    nonce: u128,
    sig: &[u8],
) -> Result<Vec<u8>, EncodeError> {
    let mut out = Vec::new();
    out.extend_from_slice(&encode_action(action)?);
    out.extend_from_slice(&encode_u64(signer));
    out.extend_from_slice(&encode_amount(nonce)?);
    out.extend_from_slice(&encode_byte_string(sig)?);
    Ok(out)
}

/// Encode an `EthAddress` as a 20-byte CBE byte string.  Mirrors
/// Lean's `Bridge.EthAddress.toBytes` followed by
/// `Encodable.encode (T := ByteArray)`.
pub fn encode_eth_address(addr: &EthAddress) -> Vec<u8> {
    // 20-byte payload always fits comfortably under 2^64.
    encode_bytes_checked(addr.as_bytes()).expect("20-byte EthAddress always encodes")
}

#[cfg(test)]
mod tests {
    use super::{
        encode_action, encode_bytes_checked, encode_eth_address, encode_signed_action,
        encode_u128_checked, encode_u64, signing_input, write_u64_le, CBE_TAG_BYTES, CBE_TAG_UINT,
        HEAD_LEN, SIGNED_ACTION_DOMAIN,
    };
    use crate::action::{Action, EthAddress, PublicKey};

    /// `write_u64_le` produces 8 little-endian bytes.
    #[test]
    fn u64_le_zero() {
        let mut out = Vec::new();
        write_u64_le(&mut out, 0);
        assert_eq!(out, vec![0u8; 8]);
    }

    /// `write_u64_le` for 1.
    #[test]
    fn u64_le_one() {
        let mut out = Vec::new();
        write_u64_le(&mut out, 1);
        assert_eq!(out, vec![0x01, 0, 0, 0, 0, 0, 0, 0]);
    }

    /// `write_u64_le` for u64::MAX.
    #[test]
    fn u64_le_max() {
        let mut out = Vec::new();
        write_u64_le(&mut out, u64::MAX);
        assert_eq!(out, vec![0xff; 8]);
    }

    /// `write_u64_le` for a specific value with all positions set.
    #[test]
    fn u64_le_pattern() {
        let mut out = Vec::new();
        write_u64_le(&mut out, 0x0807_0605_0403_0201);
        // LE order: lowest byte first.
        assert_eq!(out, vec![0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
    }

    /// `encode_u64(n)` is `[CBE_TAG_UINT] ++ LE(n)`.
    #[test]
    fn encode_u64_layout() {
        let encoded = encode_u64(42);
        assert_eq!(encoded.len(), HEAD_LEN);
        assert_eq!(encoded[0], CBE_TAG_UINT);
        assert_eq!(&encoded[1..], &[42, 0, 0, 0, 0, 0, 0, 0]);
    }

    /// `encode_u128_checked` rejects values `>= 2^64`.
    #[test]
    fn encode_u128_rejects_overflow() {
        assert!(encode_u128_checked(1u128 << 64).is_none());
        assert!(encode_u128_checked(u128::MAX).is_none());
        assert!(encode_u128_checked((1u128 << 64) - 1).is_some());
    }

    /// `encode_bytes_checked` for empty payload: `[CBE_TAG_BYTES, 0, 0, ...]`.
    #[test]
    fn encode_bytes_empty() {
        let encoded = encode_bytes_checked(&[]).unwrap();
        assert_eq!(encoded.len(), HEAD_LEN);
        assert_eq!(encoded[0], CBE_TAG_BYTES);
        assert_eq!(&encoded[1..], &[0u8; 8]);
    }

    /// `encode_bytes_checked` for 3-byte payload.
    #[test]
    fn encode_bytes_short() {
        let encoded = encode_bytes_checked(&[0xaa, 0xbb, 0xcc]).unwrap();
        assert_eq!(encoded.len(), HEAD_LEN + 3);
        assert_eq!(encoded[0], CBE_TAG_BYTES);
        assert_eq!(&encoded[1..9], &[3, 0, 0, 0, 0, 0, 0, 0]); // LE length=3
        assert_eq!(&encoded[9..], &[0xaa, 0xbb, 0xcc]);
    }

    /// `encode_action` for the smallest possible Transfer.
    #[test]
    fn encode_transfer_layout() {
        let action = Action::Transfer {
            r: 0,
            sender: 1,
            receiver: 2,
            amount: 100,
        };
        let encoded = encode_action(&action).unwrap();
        // Layout: tag(0) ++ r(0) ++ sender(1) ++ receiver(2) ++ amount(100).
        // Each component is a 9-byte CBE uint head.
        assert_eq!(encoded.len(), HEAD_LEN * 5);
        // tag is at offset 0.
        assert_eq!(encoded[0], CBE_TAG_UINT);
        assert_eq!(&encoded[1..9], &0u64.to_le_bytes());
        // r is at offset 9.
        assert_eq!(encoded[9], CBE_TAG_UINT);
        assert_eq!(&encoded[10..18], &0u64.to_le_bytes());
        // sender is at offset 18.
        assert_eq!(encoded[18], CBE_TAG_UINT);
        assert_eq!(&encoded[19..27], &1u64.to_le_bytes());
        // receiver at offset 27.
        assert_eq!(encoded[27], CBE_TAG_UINT);
        assert_eq!(&encoded[28..36], &2u64.to_le_bytes());
        // amount at offset 36.
        assert_eq!(encoded[36], CBE_TAG_UINT);
        assert_eq!(&encoded[37..45], &100u64.to_le_bytes());
    }

    /// `encode_action` for `RegisterIdentity` — the primary
    /// ingestor emission path.
    #[test]
    fn encode_register_identity_layout() {
        let pk = PublicKey::from_bytes(&[0x02, 0xab, 0xcd, 0xef]);
        let action = Action::RegisterIdentity { actor: 7, pk };
        let encoded = encode_action(&action).unwrap();
        // tag(12) ++ actor(7) ++ pk(byte_string).
        // Lengths: 9 + 9 + (9 + 4) = 31.
        assert_eq!(encoded.len(), HEAD_LEN * 3 + 4);
        // tag is 12.
        assert_eq!(encoded[0], CBE_TAG_UINT);
        assert_eq!(&encoded[1..9], &12u64.to_le_bytes());
        // actor is 7.
        assert_eq!(encoded[9], CBE_TAG_UINT);
        assert_eq!(&encoded[10..18], &7u64.to_le_bytes());
        // pk is a byte string of length 4.
        assert_eq!(encoded[18], CBE_TAG_BYTES);
        assert_eq!(&encoded[19..27], &4u64.to_le_bytes());
        assert_eq!(&encoded[27..31], &[0x02, 0xab, 0xcd, 0xef]);
    }

    /// `encode_action` for `ReplaceKey`.
    #[test]
    fn encode_replace_key_layout() {
        let pk = PublicKey::from_bytes(&[0x03; 33]);
        let action = Action::ReplaceKey {
            actor: 42,
            new_key: pk,
        };
        let encoded = encode_action(&action).unwrap();
        // tag(4) ++ actor(42) ++ pk(33 bytes).
        assert_eq!(encoded.len(), HEAD_LEN + HEAD_LEN + HEAD_LEN + 33);
        assert_eq!(encoded[0], CBE_TAG_UINT);
        assert_eq!(&encoded[1..9], &4u64.to_le_bytes());
        assert_eq!(encoded[9], CBE_TAG_UINT);
        assert_eq!(&encoded[10..18], &42u64.to_le_bytes());
        assert_eq!(encoded[18], CBE_TAG_BYTES);
        assert_eq!(&encoded[19..27], &33u64.to_le_bytes());
        assert_eq!(&encoded[27..60], &[0x03; 33]);
    }

    /// `encode_action` for `Withdraw` (verifies the 20-byte
    /// EthAddress encoding per Audit-2).
    #[test]
    fn encode_withdraw_layout() {
        let recipient = EthAddress::from_bytes(&[0x12; 20]).unwrap();
        let action = Action::Withdraw {
            r: 5,
            sender: 9,
            amount: 1000,
            recipient_l1: recipient,
        };
        let encoded = encode_action(&action).unwrap();
        // tag(14) + r(5) + sender(9) + amount(1000) + recipient_l1(20 byte string).
        assert_eq!(encoded.len(), HEAD_LEN * 5 + 20);
        assert_eq!(encoded[0], CBE_TAG_UINT);
        assert_eq!(&encoded[1..9], &14u64.to_le_bytes());
    }

    /// `encode_action` for `RevokeLocalPolicy` — bare tag.
    #[test]
    fn encode_revoke_local_policy() {
        let action = Action::RevokeLocalPolicy;
        let encoded = encode_action(&action).unwrap();
        assert_eq!(encoded.len(), HEAD_LEN);
        assert_eq!(encoded[0], CBE_TAG_UINT);
        assert_eq!(&encoded[1..9], &16u64.to_le_bytes());
    }

    /// `encode_signed_action` layout: action ++ signer ++ nonce ++ sig.
    #[test]
    fn encode_signed_action_layout() {
        let action = Action::FreezeResource { r: 1 };
        let sig = vec![0xaa; 64];
        let encoded = encode_signed_action(&action, 42, 7, &sig).unwrap();
        // action: 9 (tag) + 9 (r) = 18
        // signer (42): 9
        // nonce (7): 9
        // sig: 9 + 64 = 73
        assert_eq!(encoded.len(), 18 + 9 + 9 + 73);
    }

    /// `signing_input` prefix is the CBE-byte-string-wrapped
    /// domain bytes.
    #[test]
    fn signing_input_starts_with_domain_prefix() {
        let action = Action::FreezeResource { r: 0 };
        let bytes = signing_input(&action, 0, 0, &[]).unwrap();
        // First 9 bytes: CBE byte string head with length=27 (the
        // ASCII length of "legalkernel/v1/signedaction").
        assert_eq!(bytes[0], CBE_TAG_BYTES);
        assert_eq!(&bytes[1..9], &27u64.to_le_bytes());
        // Next 27 bytes: the ASCII bytes of the domain string.
        assert_eq!(&bytes[9..36], SIGNED_ACTION_DOMAIN.as_bytes());
        assert_eq!(SIGNED_ACTION_DOMAIN.len(), 27);
    }

    /// `signing_input` minimum size matches the Lean theorem
    /// `signInput_nonempty`: ≥ 36 bytes (9-byte head + 27-byte
    /// domain).
    #[test]
    fn signing_input_min_size() {
        let action = Action::FreezeResource { r: 0 };
        let bytes = signing_input(&action, 0, 0, &[]).unwrap();
        assert!(
            bytes.len() >= 36,
            "expected ≥ 36 bytes, got {}",
            bytes.len()
        );
    }

    /// `signing_input` distinguishes deployments — the
    /// cross-deployment-replay-protection property.
    #[test]
    fn signing_input_distinguishes_deployments() {
        let action = Action::FreezeResource { r: 0 };
        let d1 = signing_input(&action, 1, 1, &[1, 2, 3]).unwrap();
        let d2 = signing_input(&action, 1, 1, &[4, 5, 6]).unwrap();
        assert_ne!(d1, d2);
    }

    /// `signing_input` distinguishes nonces.
    #[test]
    fn signing_input_distinguishes_nonces() {
        let action = Action::FreezeResource { r: 0 };
        let d1 = signing_input(&action, 1, 1, &[]).unwrap();
        let d2 = signing_input(&action, 1, 2, &[]).unwrap();
        assert_ne!(d1, d2);
    }

    /// `signing_input` distinguishes actions.
    #[test]
    fn signing_input_distinguishes_actions() {
        let a1 = Action::FreezeResource { r: 0 };
        let a2 = Action::FreezeResource { r: 1 };
        let s1 = signing_input(&a1, 1, 1, &[]).unwrap();
        let s2 = signing_input(&a2, 1, 1, &[]).unwrap();
        assert_ne!(s1, s2);
    }

    /// `encode_eth_address` is a CBE byte string of length 20.
    #[test]
    fn encode_eth_address_layout() {
        let addr = EthAddress::from_bytes(&[0xab; 20]).unwrap();
        let encoded = encode_eth_address(&addr);
        assert_eq!(encoded.len(), HEAD_LEN + 20);
        assert_eq!(encoded[0], CBE_TAG_BYTES);
        assert_eq!(&encoded[1..9], &20u64.to_le_bytes());
        assert_eq!(&encoded[9..29], &[0xab; 20]);
    }

    /// The `SIGNED_ACTION_DOMAIN` constant matches the Lean
    /// `Authority.Crypto.signedActionDomain` value byte-for-byte.
    #[test]
    fn signed_action_domain_matches_lean() {
        assert_eq!(SIGNED_ACTION_DOMAIN, "legalkernel/v1/signedaction");
        // The length is 27 — used in several other tests.
        assert_eq!(SIGNED_ACTION_DOMAIN.len(), 27);
    }

    /// Encoding identical inputs is deterministic (byte-equal).
    #[test]
    fn encode_action_deterministic() {
        let a = Action::RegisterIdentity {
            actor: 1,
            pk: PublicKey::from_bytes(&[0x02, 0xab]),
        };
        let e1 = encode_action(&a).unwrap();
        let e2 = encode_action(&a).unwrap();
        assert_eq!(e1, e2);
    }

    /// Known-vector test for `RegisterIdentity` —
    /// byte-equivalent to Lean's `Encoding.Action.encode
    /// (.registerIdentity 1 (PublicKey.mk #[0x02, 0xab]))`.
    ///
    /// Hand-calculated expected bytes:
    ///
    ///   * Tag 12 (uint): `[0x00, 0x0c, 0, 0, 0, 0, 0, 0, 0]`
    ///   * actor 1 (uint): `[0x00, 0x01, 0, 0, 0, 0, 0, 0, 0]`
    ///   * pk (byte string of length 2): `[0x02, 0x02, 0, 0, 0,
    ///     0, 0, 0, 0, 0x02, 0xab]`
    ///
    /// Total 29 bytes.
    #[test]
    fn encode_register_identity_known_vector() {
        let a = Action::RegisterIdentity {
            actor: 1,
            pk: PublicKey::from_bytes(&[0x02, 0xab]),
        };
        let actual = encode_action(&a).unwrap();
        let expected: Vec<u8> = vec![
            // Tag 12 (CBE uint head)
            0x00, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            // actor 1 (CBE uint head)
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            // pk byte-string head (CBE bytes, length=2)
            0x02, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // pk payload
            0x02, 0xab,
        ];
        assert_eq!(actual, expected);
    }

    /// Known-vector test for `signing_input` — verifies the
    /// load-bearing 36-byte domain prefix bytes.
    ///
    /// The Lean reference (`Authority/SignedAction.lean::
    /// signingInput`) produces a domain prefix of:
    ///
    ///   * CBE byte-string head with length=27.
    ///   * 27 UTF-8 bytes of "legalkernel/v1/signedaction".
    ///
    /// Total prefix size: 36 bytes.
    #[test]
    fn signing_input_domain_prefix_known_vector() {
        let a = Action::FreezeResource { r: 0 };
        let bytes = signing_input(&a, 0, 0, &[]).unwrap();
        let expected_prefix: Vec<u8> = {
            let mut v = vec![
                // CBE byte-string head (tag, length=27 LE)
                0x02, 0x1b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            ];
            v.extend_from_slice(b"legalkernel/v1/signedaction");
            v
        };
        assert!(bytes.len() >= expected_prefix.len());
        assert_eq!(&bytes[..expected_prefix.len()], expected_prefix.as_slice());
    }

    /// Known-vector test: empty CBE byte-string is `[0x02,
    /// 0, 0, 0, 0, 0, 0, 0, 0]` (head only, no payload).
    #[test]
    fn encode_bytes_checked_empty_known_vector() {
        let encoded = encode_bytes_checked(&[]).unwrap();
        assert_eq!(encoded, vec![0x02, 0, 0, 0, 0, 0, 0, 0, 0]);
    }

    /// Known-vector test: empty CBE uint is `[0x00,
    /// 0, 0, 0, 0, 0, 0, 0, 0]` (head only, value=0).
    #[test]
    fn encode_u64_zero_known_vector() {
        assert_eq!(encode_u64(0), vec![0x00, 0, 0, 0, 0, 0, 0, 0, 0]);
    }
}

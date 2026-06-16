// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Independent-observer receipt-fetch binding (Workstream GP.8.5 v2 /
//! **OQ-GP-8b** follow-on (b)).
//!
//! The Lean gate `LegalKernel.Bridge.receiptVerifiedClaimAdmissible` admits
//! a sequencer reimbursement only against a `SequencerReimbursementVerified`
//! witness, whose `l1_attestation` field is the deployment-supplied
//! `l1GasReceiptVerifier` opaque.  This module is the **production binding**
//! of that opaque: it lets a party who is **not the claim builder** fetch
//! the L1 batch-publication transaction receipt, **re-derive**
//! `(gasUsed, gasPrice)` from it, recompute the canonical receipt binding
//! hash, and confirm — independently — that a submitted [`SequencerClaim`]
//! is backed wei-for-wei (ETH leg) or BOLD-for-wei (BOLD leg, via an
//! attested [`EthBoldRate`]).
//!
//! ## Why "independent" matters
//!
//! [`crate::sequencer_claim`]'s [`SequencerClaim::build_receipt_backed`] is
//! the *builder* side: it clamps the claim to a [`GasReceipt`] the operator
//! supplies.  That alone does not stop a dishonest operator from supplying a
//! fabricated receipt.  The binding here closes that: the
//! [`ReceiptSource`]-fed verifier constructs the [`GasReceipt`] **itself**
//! from the on-chain receipt (never from the claim or the operator's
//! assertion), so the attestation reflects L1 reality.  Run by ≥1
//! independent watchtower it is the cross-checkable mitigation the Lean
//! module docstring promises.
//!
//! ## The canonical binding hash (the agreement point)
//!
//! Builder and verifier must agree on *which* 32-byte handle identifies a
//! receipt (it is the value `ConsumedReceipts` de-duplicates on).  That
//! handle is [`canonical_receipt_binding_hash`]:
//!
//! ```text
//! keccak256( DOMAIN ‖ tx_hash[32] ‖ batch_id_be[8]
//!            ‖ gas_used_be[16] ‖ gas_price_be[16] )
//! ```
//!
//! with `DOMAIN = "knomosis/v1/gas-receipt-binding"`.  It is a pure,
//! deterministic function of the on-chain receipt's identifying fields, so
//! the builder (from its observed receipt) and any independent observer
//! (from the fetched receipt) compute the same hash — and a fabricated
//! receipt cannot reuse a real receipt's hash.
//!
//! ## No-reuse on the observer path
//!
//! The canonical hash is what the consumed set de-duplicates on, so the
//! `_fresh` verifiers ([`verify_eth_claim_independently_fresh`] /
//! [`verify_bold_claim_independently_fresh`]) reject a [`ClaimBackingOutcome::Reused`]
//! receipt — the observer-side analogue of the Lean `consumeReceipt_blocks_reuse`.
//! **The no-reuse check uses the canonical hash re-derived from L1, never a
//! sequencer-asserted one** — otherwise a dishonest operator could present
//! distinct fabricated hashes for one real receipt to back N claims and drain
//! the pool by N× the real spend.  [`fetch_and_derive_gas_receipt`] is the
//! composable primitive that hands a caller the canonical-hash [`GasReceipt`]
//! to record in its consumed set.

use crate::sequencer_claim::{EthBoldRate, GasReceipt, SequencerClaim};

/// Domain separator for the canonical gas-receipt binding hash.
const RECEIPT_BINDING_DOMAIN: &[u8] = b"knomosis/v1/gas-receipt-binding";

/// The canonical 32-byte binding hash of an L1 batch-publication gas
/// receipt: `keccak256(DOMAIN ‖ tx_hash ‖ batch_id ‖ gas_used ‖ gas_price)`,
/// all integers big-endian.  This is the handle the deployment-side
/// verifier attests and that [`crate::sequencer_claim::GasReceipt`] carries;
/// computing it identically on both the builder and the independent-observer
/// sides is what makes the binding meaningful (and the no-reuse / consumed
/// set sound).
#[must_use]
pub fn canonical_receipt_binding_hash(
    tx_hash: &[u8; 32],
    batch_id: u64,
    gas_used: u128,
    gas_price: u128,
) -> [u8; 32] {
    use sha3::{Digest, Keccak256};
    let mut hasher = Keccak256::new();
    hasher.update(RECEIPT_BINDING_DOMAIN);
    hasher.update(tx_hash);
    hasher.update(batch_id.to_be_bytes());
    hasher.update(gas_used.to_be_bytes());
    hasher.update(gas_price.to_be_bytes());
    hasher.finalize().into()
}

/// A raw Ethereum transaction receipt, exactly the subset of
/// `eth_getTransactionReceipt` fields this binding consumes.  An independent
/// observer fetches one via a [`ReceiptSource`]; it is **never** taken from
/// the claim builder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EthTxReceipt {
    /// The 32-byte L1 transaction hash (`transactionHash`).
    pub transaction_hash: [u8; 32],
    /// Gas units consumed (`gasUsed`).
    pub gas_used: u128,
    /// The effective gas price in wei (`effectiveGasPrice`).
    pub effective_gas_price: u128,
    /// `true` iff the transaction succeeded (`status == 0x1`).  A reverted
    /// batch publication backs nothing.
    pub status_ok: bool,
}

/// Re-derive the canonical [`GasReceipt`] for a batch from an
/// independently-fetched L1 receipt.  Returns `None` iff the L1 transaction
/// reverted (`status_ok == false`) — a failed batch publication justifies
/// no reimbursement.  The binding hash is computed canonically
/// ([`canonical_receipt_binding_hash`]) from the **fetched** fields, so the
/// result reflects L1 reality, not the operator's assertion.
#[must_use]
pub fn derive_gas_receipt(receipt: &EthTxReceipt, batch_id: u64) -> Option<GasReceipt> {
    if !receipt.status_ok {
        return None;
    }
    Some(GasReceipt {
        batch_id,
        gas_used: receipt.gas_used,
        gas_price: receipt.effective_gas_price,
        receipt_binding_hash: canonical_receipt_binding_hash(
            &receipt.transaction_hash,
            batch_id,
            receipt.gas_used,
            receipt.effective_gas_price,
        ),
    })
}

/// Error fetching or parsing an L1 transaction receipt.
#[derive(Debug, thiserror::Error)]
pub enum ReceiptFetchError {
    /// The underlying transport / RPC failed.
    #[error("receipt source error: {0}")]
    Source(String),
    /// The receipt JSON was missing a required field or was malformed.
    #[error("malformed receipt: {0}")]
    Malformed(String),
}

/// A source of L1 transaction receipts — the "fetch" half of the binding.
///
/// Production deployments implement it over a JSON-RPC endpoint (see the
/// blanket impl for [`crate::source::json_rpc::JsonRpcL1Source`]); tests use
/// an in-memory mock.  Keeping it a trait decouples the *verification* logic
/// (below) from the transport, and lets the same independent verifier run
/// inside the off-chain observer or the l1-ingest daemon.
pub trait ReceiptSource {
    /// Fetch the receipt for `tx_hash`, or `Ok(None)` if the chain has no
    /// receipt for it yet (unmined / unknown).
    ///
    /// # Errors
    ///
    /// [`ReceiptFetchError::Source`] on a transport failure, or
    /// [`ReceiptFetchError::Malformed`] if the response cannot be parsed.
    fn fetch_receipt(&self, tx_hash: &[u8; 32]) -> Result<Option<EthTxReceipt>, ReceiptFetchError>;
}

/// The outcome of an independent backing check.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClaimBackingOutcome {
    /// The claim is a canonical reimbursement claim, its amount is within the
    /// independently-derived receipt cost, and (for the fresh check) the
    /// receipt has not been consumed before — backed.
    Backed,
    /// The claim's shape or amount is not justified by the on-chain receipt.
    NotBacked,
    /// The claim IS backed by the receipt, but that receipt's canonical
    /// binding hash has already been consumed by a prior admitted claim —
    /// admitting it would let one L1 receipt back two reimbursements, so the
    /// no-reuse rule rejects it (the observer-side analogue of the Lean
    /// `consumeReceipt_blocks_reuse`).  Only produced by the `_fresh` checks.
    Reused,
    /// No receipt exists on L1 for the given transaction hash.
    ReceiptNotFound,
    /// The L1 transaction reverted; it backs no reimbursement.
    TransactionFailed,
}

impl ClaimBackingOutcome {
    /// Is this the `Backed` outcome?
    #[must_use]
    pub fn is_backed(self) -> bool {
        matches!(self, ClaimBackingOutcome::Backed)
    }
}

/// Fetch the L1 receipt for `tx_hash` and re-derive the canonical
/// [`GasReceipt`] for `batch_id`.  `Ok(None)` if the chain has no receipt
/// for the hash OR the transaction reverted (both back nothing).
///
/// This is the composable primitive a watchtower uses: the returned
/// [`GasReceipt`] carries the **canonical** binding hash (re-derived from L1
/// by [`canonical_receipt_binding_hash`]), which the caller checks for
/// backing/freshness ([`SequencerClaim::is_receipt_backed_by`] /
/// [`SequencerClaim::is_receipt_fresh_and_backed`]) and records in its
/// consumed set.
///
/// **Security invariant.**  The consumed set MUST be keyed by THIS hash
/// (re-derived from L1), never by a sequencer-asserted one — otherwise a
/// dishonest operator could present distinct fabricated binding hashes for
/// one real L1 receipt to evade the no-reuse rule and drain the pool by
/// N× the real spend.
///
/// # Errors
///
/// Propagates [`ReceiptFetchError`] from the source.
pub fn fetch_and_derive_gas_receipt<S: ReceiptSource>(
    source: &S,
    tx_hash: &[u8; 32],
    batch_id: u64,
) -> Result<Option<GasReceipt>, ReceiptFetchError> {
    Ok(source
        .fetch_receipt(tx_hash)?
        .and_then(|raw| derive_gas_receipt(&raw, batch_id)))
}

/// **Independently verify an ETH-leg claim is backed** against the on-chain
/// receipt (backing only — no freshness).  Convenience wrapper over
/// [`verify_eth_claim_independently_fresh`] with an empty consumed set, so it
/// never returns [`ClaimBackingOutcome::Reused`].
///
/// # Errors
///
/// Propagates [`ReceiptFetchError`] from the source.
pub fn verify_eth_claim_independently<S: ReceiptSource>(
    source: &S,
    claim: &SequencerClaim,
    tx_hash: &[u8; 32],
    batch_id: u64,
) -> Result<ClaimBackingOutcome, ReceiptFetchError> {
    verify_eth_claim_independently_fresh(source, claim, tx_hash, batch_id, &[])
}

/// **Independently verify an ETH-leg claim is backed AND fresh.**
///
/// Fetches the receipt for `tx_hash` via `source`, re-derives the canonical
/// [`GasReceipt`] for `batch_id` (never trusting the claim), and reports
/// [`ClaimBackingOutcome`]: `ReceiptNotFound` (no L1 receipt),
/// `TransactionFailed` (the tx reverted), `NotBacked` (wrong shape or over
/// the cost), `Reused` (backed, but the receipt's canonical binding hash is
/// already in `consumed`), or `Backed` (canonically backed and fresh).  This
/// is the production binding of the Lean `l1GasReceiptVerifier` opaque plus
/// the `receiptEnforcedClaimAdmissible` freshness gate for the ETH leg — the
/// no-reuse check uses the **canonical re-derived** hash, never the claim's.
///
/// # Errors
///
/// Propagates [`ReceiptFetchError`] from the source.
pub fn verify_eth_claim_independently_fresh<S: ReceiptSource>(
    source: &S,
    claim: &SequencerClaim,
    tx_hash: &[u8; 32],
    batch_id: u64,
    consumed: &[[u8; 32]],
) -> Result<ClaimBackingOutcome, ReceiptFetchError> {
    let Some(raw) = source.fetch_receipt(tx_hash)? else {
        return Ok(ClaimBackingOutcome::ReceiptNotFound);
    };
    let Some(gas_receipt) = derive_gas_receipt(&raw, batch_id) else {
        return Ok(ClaimBackingOutcome::TransactionFailed);
    };
    if !claim.is_receipt_backed_by(&gas_receipt) {
        return Ok(ClaimBackingOutcome::NotBacked);
    }
    // Backed — the no-reuse check is against the CANONICAL (re-derived) hash.
    if consumed.contains(&gas_receipt.receipt_binding_hash) {
        return Ok(ClaimBackingOutcome::Reused);
    }
    Ok(ClaimBackingOutcome::Backed)
}

/// **Independently verify a BOLD-leg claim is backed** against the on-chain
/// receipt and an attested ETH→BOLD `rate` (backing only — no freshness).
/// Convenience wrapper over [`verify_bold_claim_independently_fresh`] with an
/// empty consumed set.
///
/// The `rate` is the observer's own attested price (the second OQ-GP-8b trust
/// assumption); a watchtower supplies it from its independent oracle — the
/// binding here covers the *gas* re-derivation, and the verdict is relative
/// to the observer's rate (cross-check across oracles, per GENESIS_PLAN
/// §15E.7).
///
/// # Errors
///
/// Propagates [`ReceiptFetchError`] from the source.
pub fn verify_bold_claim_independently<S: ReceiptSource>(
    source: &S,
    claim: &SequencerClaim,
    tx_hash: &[u8; 32],
    batch_id: u64,
    rate: &EthBoldRate,
) -> Result<ClaimBackingOutcome, ReceiptFetchError> {
    verify_bold_claim_independently_fresh(source, claim, tx_hash, batch_id, rate, &[])
}

/// **Independently verify a BOLD-leg claim is backed AND fresh.**  The BOLD
/// analogue of [`verify_eth_claim_independently_fresh`]: converts the
/// re-derived wei cost to BOLD at `rate` ([`SequencerClaim::is_bold_receipt_backed_by`])
/// and applies the same no-reuse check on the canonical hash (the consumed
/// set spans both legs).
///
/// # Errors
///
/// Propagates [`ReceiptFetchError`] from the source.
pub fn verify_bold_claim_independently_fresh<S: ReceiptSource>(
    source: &S,
    claim: &SequencerClaim,
    tx_hash: &[u8; 32],
    batch_id: u64,
    rate: &EthBoldRate,
    consumed: &[[u8; 32]],
) -> Result<ClaimBackingOutcome, ReceiptFetchError> {
    let Some(raw) = source.fetch_receipt(tx_hash)? else {
        return Ok(ClaimBackingOutcome::ReceiptNotFound);
    };
    let Some(gas_receipt) = derive_gas_receipt(&raw, batch_id) else {
        return Ok(ClaimBackingOutcome::TransactionFailed);
    };
    if !claim.is_bold_receipt_backed_by(&gas_receipt, rate) {
        return Ok(ClaimBackingOutcome::NotBacked);
    }
    if consumed.contains(&gas_receipt.receipt_binding_hash) {
        return Ok(ClaimBackingOutcome::Reused);
    }
    Ok(ClaimBackingOutcome::Backed)
}

/// Parse the subset of an `eth_getTransactionReceipt` JSON result this
/// binding needs.  `Ok(None)` for a JSON `null` (no such receipt).
///
/// # Errors
///
/// [`ReceiptFetchError::Malformed`] if a required field
/// (`transactionHash`, `gasUsed`, `effectiveGasPrice`, `status`) is absent
/// or not a parseable hex quantity.
pub fn parse_eth_receipt(
    value: &serde_json::Value,
) -> Result<Option<EthTxReceipt>, ReceiptFetchError> {
    if value.is_null() {
        return Ok(None);
    }
    let obj = value
        .as_object()
        .ok_or_else(|| ReceiptFetchError::Malformed("receipt is not a JSON object".into()))?;
    let transaction_hash = decode_hex32(get_str(obj, "transactionHash")?)
        .ok_or_else(|| ReceiptFetchError::Malformed("transactionHash not a 32-byte hex".into()))?;
    let gas_used = parse_hex_u128(get_str(obj, "gasUsed")?)?;
    let effective_gas_price = parse_hex_u128(get_str(obj, "effectiveGasPrice")?)?;
    // EIP-658: `status` is exactly "0x1" (success) or "0x0" (revert).  Match
    // `== 1` strictly (not `!= 0`) so a non-spec status backs nothing
    // (fail-closed) rather than being treated as success.
    let status_ok = parse_hex_u128(get_str(obj, "status")?)? == 1;
    Ok(Some(EthTxReceipt {
        transaction_hash,
        gas_used,
        effective_gas_price,
        status_ok,
    }))
}

fn get_str<'a>(
    obj: &'a serde_json::Map<String, serde_json::Value>,
    key: &str,
) -> Result<&'a str, ReceiptFetchError> {
    obj.get(key)
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| ReceiptFetchError::Malformed(format!("missing/invalid field `{key}`")))
}

fn parse_hex_u128(s: &str) -> Result<u128, ReceiptFetchError> {
    let stripped = s.strip_prefix("0x").unwrap_or(s);
    u128::from_str_radix(stripped, 16)
        .map_err(|e| ReceiptFetchError::Malformed(format!("invalid hex quantity `{s}`: {e}")))
}

fn decode_hex32(s: &str) -> Option<[u8; 32]> {
    let stripped = s.strip_prefix("0x").unwrap_or(s);
    if stripped.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(stripped.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(out)
}

/// Live [`ReceiptSource`] over a JSON-RPC endpoint: `fetch_receipt` issues
/// `eth_getTransactionReceipt` and parses the result.  This is the
/// production transport an independent observer uses.
impl ReceiptSource for crate::source::json_rpc::JsonRpcL1Source {
    fn fetch_receipt(&self, tx_hash: &[u8; 32]) -> Result<Option<EthTxReceipt>, ReceiptFetchError> {
        let mut hex = String::with_capacity(66);
        hex.push_str("0x");
        for b in tx_hash {
            use core::fmt::Write;
            // Infallible: writing to a String never errors.
            let _ = write!(hex, "{b:02x}");
        }
        let params = serde_json::Value::Array(vec![serde_json::Value::String(hex)]);
        let result = self
            .rpc("eth_getTransactionReceipt", params)
            .map_err(|e| ReceiptFetchError::Source(e.to_string()))?;
        parse_eth_receipt(&result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::action::Action;
    use crate::address_book::{GAS_POOL_ACTOR_ID, SEQUENCER_ACTOR_ID};
    use crate::key::SIGNATURE_LEN;
    use std::collections::HashMap;

    /// In-memory mock receipt source keyed by tx hash.
    #[derive(Default)]
    struct MockReceiptSource {
        receipts: HashMap<[u8; 32], EthTxReceipt>,
    }

    impl MockReceiptSource {
        fn with(mut self, receipt: EthTxReceipt) -> Self {
            self.receipts.insert(receipt.transaction_hash, receipt);
            self
        }
    }

    impl ReceiptSource for MockReceiptSource {
        fn fetch_receipt(
            &self,
            tx_hash: &[u8; 32],
        ) -> Result<Option<EthTxReceipt>, ReceiptFetchError> {
            Ok(self.receipts.get(tx_hash).cloned())
        }
    }

    fn ok_receipt(tx_hash: [u8; 32], gas_used: u128, gas_price: u128) -> EthTxReceipt {
        EthTxReceipt {
            transaction_hash: tx_hash,
            gas_used,
            effective_gas_price: gas_price,
            status_ok: true,
        }
    }

    fn mk_claim(action: Action) -> SequencerClaim {
        SequencerClaim {
            action,
            signer: GAS_POOL_ACTOR_ID,
            nonce: 0,
            sig: [0u8; SIGNATURE_LEN],
        }
    }

    fn eth_claim(amount: u128) -> SequencerClaim {
        mk_claim(Action::Transfer {
            r: 0,
            sender: GAS_POOL_ACTOR_ID,
            receiver: SEQUENCER_ACTOR_ID,
            amount,
        })
    }

    #[test]
    fn binding_hash_is_deterministic_and_field_sensitive() {
        let tx = [0x11u8; 32];
        let h = canonical_receipt_binding_hash(&tx, 7, 21_000, 50);
        // Deterministic.
        assert_eq!(h, canonical_receipt_binding_hash(&tx, 7, 21_000, 50));
        // Sensitive to every field — a fabricated receipt cannot collide
        // with a real one without finding a keccak preimage.
        assert_ne!(
            h,
            canonical_receipt_binding_hash(&[0x12; 32], 7, 21_000, 50)
        );
        assert_ne!(h, canonical_receipt_binding_hash(&tx, 8, 21_000, 50));
        assert_ne!(h, canonical_receipt_binding_hash(&tx, 7, 21_001, 50));
        assert_ne!(h, canonical_receipt_binding_hash(&tx, 7, 21_000, 51));
    }

    #[test]
    fn derive_gas_receipt_uses_canonical_hash_and_fetched_fields() {
        let tx = [0xAA; 32];
        let raw = ok_receipt(tx, 21_000, 50);
        let g = derive_gas_receipt(&raw, 7).expect("success ⇒ Some");
        assert_eq!(g.batch_id, 7);
        assert_eq!(g.gas_used, 21_000);
        assert_eq!(g.gas_price, 50);
        assert_eq!(g.reimbursement(), 1_050_000);
        assert_eq!(
            g.receipt_binding_hash,
            canonical_receipt_binding_hash(&tx, 7, 21_000, 50)
        );
    }

    #[test]
    fn derive_gas_receipt_rejects_reverted_tx() {
        let mut raw = ok_receipt([0xAA; 32], 21_000, 50);
        raw.status_ok = false;
        assert!(
            derive_gas_receipt(&raw, 7).is_none(),
            "reverted tx backs nothing"
        );
    }

    #[test]
    fn independent_eth_verify_backs_a_within_cost_claim() {
        let tx = [0xAA; 32];
        let source = MockReceiptSource::default().with(ok_receipt(tx, 21_000, 50));
        // reimbursement = 1_050_000; an under-cost claim is backed.
        let claim = eth_claim(1_000_000);
        assert_eq!(
            verify_eth_claim_independently(&source, &claim, &tx, 7).unwrap(),
            ClaimBackingOutcome::Backed
        );
        // Exactly at cost is backed (boundary).
        assert!(
            verify_eth_claim_independently(&source, &eth_claim(1_050_000), &tx, 7)
                .unwrap()
                .is_backed()
        );
    }

    #[test]
    fn independent_eth_verify_rejects_overspend_and_fabrication() {
        let tx = [0xAA; 32];
        let source = MockReceiptSource::default().with(ok_receipt(tx, 21_000, 50));
        // Over the real (independently-derived) cost → NotBacked.  The
        // verifier derives the cost from the L1 receipt, NOT from the claim
        // (which carries only an amount), so an operator cannot inflate the
        // bound by asserting a richer receipt.
        assert_eq!(
            verify_eth_claim_independently(&source, &eth_claim(2_000_000), &tx, 7).unwrap(),
            ClaimBackingOutcome::NotBacked
        );
        // A wrong-recipient claim is NotBacked regardless of amount.
        let wrong = mk_claim(Action::Transfer {
            r: 0,
            sender: GAS_POOL_ACTOR_ID,
            receiver: 9,
            amount: 1,
        });
        assert_eq!(
            verify_eth_claim_independently(&source, &wrong, &tx, 7).unwrap(),
            ClaimBackingOutcome::NotBacked
        );
    }

    #[test]
    fn independent_verify_reports_missing_and_failed() {
        let tx = [0xAA; 32];
        let other = [0xBB; 32];
        let mut reverted = ok_receipt(other, 21_000, 50);
        reverted.status_ok = false;
        let source = MockReceiptSource::default()
            .with(ok_receipt(tx, 21_000, 50))
            .with(reverted);
        // Unknown tx → ReceiptNotFound.
        assert_eq!(
            verify_eth_claim_independently(&source, &eth_claim(1), &[0xCC; 32], 7).unwrap(),
            ClaimBackingOutcome::ReceiptNotFound
        );
        // Reverted tx → TransactionFailed.
        assert_eq!(
            verify_eth_claim_independently(&source, &eth_claim(1), &other, 7).unwrap(),
            ClaimBackingOutcome::TransactionFailed
        );
    }

    #[test]
    fn independent_bold_verify_uses_the_rate() {
        let tx = [0xAA; 32];
        let source = MockReceiptSource::default().with(ok_receipt(tx, 21_000, 50));
        // wei cost 1_050_000 * rate 2 = 2_100_000 BOLD.
        let rate = EthBoldRate {
            rate_num: 2,
            rate_den: 1,
            rate_binding_hash: [0xCD; 32],
        };
        let bold_claim = |amount: u128| {
            mk_claim(Action::Transfer {
                r: 1,
                sender: GAS_POOL_ACTOR_ID,
                receiver: SEQUENCER_ACTOR_ID,
                amount,
            })
        };
        assert!(
            verify_bold_claim_independently(&source, &bold_claim(2_100_000), &tx, 7, &rate)
                .unwrap()
                .is_backed()
        );
        assert_eq!(
            verify_bold_claim_independently(&source, &bold_claim(2_100_001), &tx, 7, &rate)
                .unwrap(),
            ClaimBackingOutcome::NotBacked
        );
        // An ETH-leg claim is not BOLD-backed.
        assert_eq!(
            verify_bold_claim_independently(&source, &eth_claim(1), &tx, 7, &rate).unwrap(),
            ClaimBackingOutcome::NotBacked
        );
    }

    #[test]
    fn parse_eth_receipt_parses_and_rejects() {
        let v: serde_json::Value = serde_json::json!({
            "transactionHash": "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "gasUsed": "0x5208",            // 21000
            "effectiveGasPrice": "0x32",    // 50
            "status": "0x1"
        });
        let r = parse_eth_receipt(&v).unwrap().expect("non-null");
        assert_eq!(r.gas_used, 21_000);
        assert_eq!(r.effective_gas_price, 50);
        assert!(r.status_ok);
        assert_eq!(r.transaction_hash, [0xAA; 32]);
        // null → None.
        assert!(parse_eth_receipt(&serde_json::Value::Null)
            .unwrap()
            .is_none());
        // Reverted status parses with status_ok = false.
        let mut obj = v.as_object().unwrap().clone();
        obj.insert("status".into(), serde_json::Value::String("0x0".into()));
        assert!(
            !parse_eth_receipt(&serde_json::Value::Object(obj))
                .unwrap()
                .unwrap()
                .status_ok
        );
        // Strict EIP-658: a NON-SPEC status (not exactly 0x1) is NOT success
        // (fail-closed) — backs nothing.
        let mut obj2 = v.as_object().unwrap().clone();
        obj2.insert("status".into(), serde_json::Value::String("0x2".into()));
        assert!(
            !parse_eth_receipt(&serde_json::Value::Object(obj2))
                .unwrap()
                .unwrap()
                .status_ok,
            "a non-spec status (0x2) must not be treated as success"
        );
        // Missing field → Malformed.
        let bad = serde_json::json!({ "gasUsed": "0x1" });
        assert!(parse_eth_receipt(&bad).is_err());
    }

    #[test]
    fn fresh_verify_rejects_a_reused_receipt() {
        // OQ-GP-8b no-reuse on the observer path: a receipt that backed a
        // prior claim cannot back another — keyed on the CANONICAL hash.
        let tx = [0xAA; 32];
        let source = MockReceiptSource::default().with(ok_receipt(tx, 21_000, 50));
        let claim = eth_claim(1_000_000);
        let canon = canonical_receipt_binding_hash(&tx, 7, 21_000, 50);
        // Fresh (nothing consumed) → Backed.
        assert_eq!(
            verify_eth_claim_independently_fresh(&source, &claim, &tx, 7, &[]).unwrap(),
            ClaimBackingOutcome::Backed
        );
        // After the CANONICAL hash is consumed → Reused.
        assert_eq!(
            verify_eth_claim_independently_fresh(&source, &claim, &tx, 7, &[canon]).unwrap(),
            ClaimBackingOutcome::Reused
        );
        // A DIFFERENT consumed hash does NOT block: the observer keys on the
        // canonical re-derived hash, so a sequencer-fabricated hash is
        // irrelevant to the no-reuse decision (the security invariant).
        assert_eq!(
            verify_eth_claim_independently_fresh(&source, &claim, &tx, 7, &[[0xFF; 32]]).unwrap(),
            ClaimBackingOutcome::Backed
        );
        // An over-cost claim is NotBacked even when fresh (backing precedes
        // the freshness check).
        assert_eq!(
            verify_eth_claim_independently_fresh(&source, &eth_claim(2_000_000), &tx, 7, &[])
                .unwrap(),
            ClaimBackingOutcome::NotBacked
        );
        // The backing-only wrapper never reports Reused.
        assert_eq!(
            verify_eth_claim_independently(&source, &claim, &tx, 7).unwrap(),
            ClaimBackingOutcome::Backed
        );
    }

    #[test]
    fn fresh_bold_verify_rejects_a_reused_receipt() {
        let tx = [0xAA; 32];
        let source = MockReceiptSource::default().with(ok_receipt(tx, 21_000, 50));
        let rate = EthBoldRate {
            rate_num: 2,
            rate_den: 1,
            rate_binding_hash: [0xCD; 32],
        };
        let claim = mk_claim(Action::Transfer {
            r: 1,
            sender: GAS_POOL_ACTOR_ID,
            receiver: SEQUENCER_ACTOR_ID,
            amount: 2_000_000,
        });
        let canon = canonical_receipt_binding_hash(&tx, 7, 21_000, 50);
        assert_eq!(
            verify_bold_claim_independently_fresh(&source, &claim, &tx, 7, &rate, &[]).unwrap(),
            ClaimBackingOutcome::Backed
        );
        assert_eq!(
            verify_bold_claim_independently_fresh(&source, &claim, &tx, 7, &rate, &[canon])
                .unwrap(),
            ClaimBackingOutcome::Reused
        );
    }

    #[test]
    fn fetch_and_derive_exposes_the_canonical_receipt() {
        let tx = [0xAA; 32];
        let source = MockReceiptSource::default().with(ok_receipt(tx, 21_000, 50));
        let gr = fetch_and_derive_gas_receipt(&source, &tx, 7)
            .unwrap()
            .expect("present");
        assert_eq!(
            gr.receipt_binding_hash,
            canonical_receipt_binding_hash(&tx, 7, 21_000, 50)
        );
        assert_eq!(gr.reimbursement(), 1_050_000);
        // Missing tx → None.
        assert!(fetch_and_derive_gas_receipt(&source, &[0xCC; 32], 7)
            .unwrap()
            .is_none());
    }

    #[test]
    fn builder_and_observer_agree_on_the_canonical_hash() {
        // The agreement point: a builder deriving the canonical GasReceipt
        // from its own observed receipt, and an observer re-deriving from the
        // fetched receipt, compute the SAME binding hash — so a shared
        // consumed set de-dups one L1 receipt to one reimbursement.
        let tx = [0xAA; 32];
        let raw = ok_receipt(tx, 21_000, 50);
        let source = MockReceiptSource::default().with(raw.clone());
        let builder_gr = derive_gas_receipt(&raw, 7).unwrap(); // builder side
        let observer_gr = fetch_and_derive_gas_receipt(&source, &tx, 7)
            .unwrap()
            .unwrap(); // observer side
        assert_eq!(
            builder_gr.receipt_binding_hash, observer_gr.receipt_binding_hash,
            "builder and observer must agree on the canonical binding hash"
        );
        // A within-cost claim verifies Backed; consuming the canonical hash
        // then drives the no-reuse rejection.
        let claim = eth_claim(500);
        assert!(verify_eth_claim_independently(&source, &claim, &tx, 7)
            .unwrap()
            .is_backed());
        assert_eq!(
            verify_eth_claim_independently_fresh(
                &source,
                &claim,
                &tx,
                7,
                &[builder_gr.receipt_binding_hash]
            )
            .unwrap(),
            ClaimBackingOutcome::Reused
        );
    }
}

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
//! keccak256( DOMAIN ‖ tx_hash[32] )
//! ```
//!
//! with `DOMAIN = "knomosis/v1/gas-receipt-binding"`.  It is keyed on the
//! **immutable L1 transaction identity alone** — *not* on the
//! caller-supplied `batch_id`, nor on the (re-org-variable) gas values.
//! That is deliberate: the de-dup key must be invariant under anything a
//! caller can vary, so the **same publication tx maps to one and only one
//! handle**.  Keying it on `batch_id` would let a caller mint distinct
//! handles for one real receipt (varying `batch_id`) and back several
//! reimbursements; keying it on the gas would make a pre-finality re-org
//! that re-prices the tx produce a second handle.  The `batch_id` and gas
//! cost are still carried on the [`GasReceipt`] (the Lean-witness mirror)
//! and the gas is checked separately in the backing test — they are just
//! not part of the de-dup identity.
//!
//! ## Re-org safety (confirmation depth)
//!
//! `eth_getTransactionReceipt` returns a receipt as soon as the tx is mined
//! — possibly in a still-reorgable block.  Attesting then would let a
//! sequencer back (and consume) a claim against a tx that later disappears.
//! The verifiers therefore take a `confirmed_head` and attest `Backed` only
//! when the receipt's `block_number <= confirmed_head` (the same
//! `head − confirmation_depth` rule the watcher enforces,
//! `watcher.rs`); a shallower receipt yields [`ClaimBackingOutcome::Unconfirmed`].
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
//!
//! ## BOLD rate oracle (the second trust assumption)
//!
//! The Lean BOLD gate requires `l1EthBoldRateOracle rateBindingHash batchId
//! rateNum rateDen = true` — the rate must be oracle-attested **for the exact
//! batch**.  The observer binding mirrors that with the [`RateOracle`] trait:
//! [`verify_bold_claim_independently`] fetches the attested rate for `batch_id`
//! from the oracle and backs the claim against *that* rate, never a rate
//! passed in by the caller (which could be stale or inflated).

use crate::sequencer_claim::{EthBoldRate, GasReceipt, SequencerClaim};

/// Domain separator for the canonical gas-receipt binding hash.
const RECEIPT_BINDING_DOMAIN: &[u8] = b"knomosis/v1/gas-receipt-binding";

/// The canonical 32-byte binding hash of an L1 batch-publication gas
/// receipt: `keccak256(DOMAIN ‖ tx_hash)`.  It is keyed on the **immutable
/// L1 transaction hash alone** — the unique identity of the publication tx —
/// so the same tx always maps to the same handle regardless of any
/// caller-supplied value.  This is the handle the deployment-side verifier
/// attests and that [`crate::sequencer_claim::GasReceipt`] carries; computing
/// it identically on both the builder and the independent-observer sides is
/// what makes the binding meaningful (and the no-reuse / consumed set sound).
///
/// It deliberately does **not** fold in `batch_id` (caller-supplied and
/// unproven by the receipt — folding it in would let one real receipt mint
/// distinct handles under different batch ids and back several
/// reimbursements) nor the gas values (re-org-variable before finality).
#[must_use]
pub fn canonical_receipt_binding_hash(tx_hash: &[u8; 32]) -> [u8; 32] {
    use sha3::{Digest, Keccak256};
    let mut hasher = Keccak256::new();
    hasher.update(RECEIPT_BINDING_DOMAIN);
    hasher.update(tx_hash);
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
    /// The number of the block the receipt is in (`blockNumber`).  Used for
    /// the confirmation-depth (re-org safety) check — a receipt is attestable
    /// only once `block_number <= confirmed_head`.
    pub block_number: u64,
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
/// ([`canonical_receipt_binding_hash`]) from the **fetched** transaction hash,
/// so the result reflects L1 reality, not the operator's assertion.
///
/// This does NOT apply the confirmation-depth check (it has no chain head);
/// callers attest only after the [`verify`-family functions](verify_eth_claim_independently)
/// / [`fetch_and_derive_gas_receipt`] confirm `block_number <= confirmed_head`.
#[must_use]
pub fn derive_gas_receipt(receipt: &EthTxReceipt, batch_id: u64) -> Option<GasReceipt> {
    if !receipt.status_ok {
        return None;
    }
    Some(GasReceipt {
        batch_id,
        gas_used: receipt.gas_used,
        gas_price: receipt.effective_gas_price,
        receipt_binding_hash: canonical_receipt_binding_hash(&receipt.transaction_hash),
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

/// An oracle of ETH→BOLD exchange rates — the production binding of the Lean
/// `l1EthBoldRateOracle` opaque.  The BOLD verifiers consult it for the rate
/// attested **for the exact batch** being verified, rather than trusting a
/// rate passed in by the caller (which could be stale or inflated for a
/// different batch).  A watchtower implements it over its own price feed;
/// tests use an in-memory mock.
pub trait RateOracle {
    /// Return the oracle's attested ETH→BOLD rate for `batch_id`, or
    /// `Ok(None)` if no rate is attested for that batch (→ the claim cannot be
    /// BOLD-backed: [`ClaimBackingOutcome::RateUnavailable`]).
    ///
    /// # Errors
    ///
    /// [`ReceiptFetchError`] on a transport/oracle failure.
    fn attested_rate(&self, batch_id: u64) -> Result<Option<EthBoldRate>, ReceiptFetchError>;
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
    /// The receipt exists and succeeded, but its block is not yet
    /// `confirmation_depth` blocks deep (`block_number > confirmed_head`), so
    /// it is still reorgable and must NOT be attested (re-org safety).
    Unconfirmed,
    /// No oracle-attested ETH→BOLD rate is available for the batch, so a BOLD
    /// claim cannot be backed (only produced by the BOLD verifiers).
    RateUnavailable,
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
/// [`GasReceipt`] for `batch_id`, applying the confirmation-depth gate.
/// `Ok(None)` if the chain has no receipt for the hash, the transaction
/// reverted, OR the receipt's block is not yet `confirmed_head`-deep (still
/// reorgable) — all back nothing.
///
/// This is the composable primitive a watchtower uses: the returned
/// [`GasReceipt`] carries the **canonical** binding hash (re-derived from L1
/// by [`canonical_receipt_binding_hash`]), which the caller checks for
/// backing/freshness ([`SequencerClaim::is_receipt_backed_by`] /
/// [`SequencerClaim::is_receipt_fresh_and_backed`]) and records in its
/// consumed set.  `confirmed_head` is the deepest block the caller treats as
/// final (`head − confirmation_depth`, the watcher's rule).
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
    confirmed_head: u64,
) -> Result<Option<GasReceipt>, ReceiptFetchError> {
    let Some(raw) = source.fetch_receipt(tx_hash)? else {
        return Ok(None);
    };
    if raw.block_number > confirmed_head {
        // Not yet confirmation-depth deep — still reorgable; back nothing.
        return Ok(None);
    }
    Ok(derive_gas_receipt(&raw, batch_id))
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
    confirmed_head: u64,
) -> Result<ClaimBackingOutcome, ReceiptFetchError> {
    verify_eth_claim_independently_fresh(source, claim, tx_hash, batch_id, confirmed_head, &[])
}

/// **Independently verify an ETH-leg claim is backed AND fresh.**
///
/// Fetches the receipt for `tx_hash` via `source`, re-derives the canonical
/// [`GasReceipt`] for `batch_id` (never trusting the claim), and reports
/// [`ClaimBackingOutcome`]: `ReceiptNotFound` (no L1 receipt),
/// `TransactionFailed` (the tx reverted), `Unconfirmed` (the receipt's block
/// is not yet `confirmed_head`-deep — re-org safety), `NotBacked` (wrong
/// shape or over the cost), `Reused` (backed, but the receipt's canonical
/// binding hash is already in `consumed`), or `Backed` (canonically backed,
/// confirmed, and fresh).  This is the production binding of the Lean
/// `l1GasReceiptVerifier` opaque plus the `receiptEnforcedClaimAdmissible`
/// freshness gate for the ETH leg — the no-reuse check uses the **canonical
/// re-derived** hash, never the claim's.
///
/// # Errors
///
/// Propagates [`ReceiptFetchError`] from the source.
pub fn verify_eth_claim_independently_fresh<S: ReceiptSource>(
    source: &S,
    claim: &SequencerClaim,
    tx_hash: &[u8; 32],
    batch_id: u64,
    confirmed_head: u64,
    consumed: &[[u8; 32]],
) -> Result<ClaimBackingOutcome, ReceiptFetchError> {
    let Some(raw) = source.fetch_receipt(tx_hash)? else {
        return Ok(ClaimBackingOutcome::ReceiptNotFound);
    };
    // Re-org safety FIRST: a still-reorgable receipt yields no terminal
    // verdict — even a current `status == 0` failure can be replaced by a
    // re-org, so `TransactionFailed` is reported only once the receipt is
    // confirmation-depth deep.
    if raw.block_number > confirmed_head {
        return Ok(ClaimBackingOutcome::Unconfirmed);
    }
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
/// receipt and the `oracle`-attested ETH→BOLD rate for the batch (backing
/// only — no freshness).  Convenience wrapper over
/// [`verify_bold_claim_independently_fresh`] with an empty consumed set.
///
/// The rate is **fetched from `oracle` for `batch_id`** (the production
/// binding of the Lean `l1EthBoldRateOracle`, tying the rate to the exact
/// batch), never a rate passed in by the caller; a watchtower implements the
/// oracle over its own price feed and cross-checks across observers
/// (GENESIS_PLAN §15E.7).
///
/// # Errors
///
/// Propagates [`ReceiptFetchError`] from the source or oracle.
pub fn verify_bold_claim_independently<S: ReceiptSource, O: RateOracle>(
    source: &S,
    oracle: &O,
    claim: &SequencerClaim,
    tx_hash: &[u8; 32],
    batch_id: u64,
    confirmed_head: u64,
) -> Result<ClaimBackingOutcome, ReceiptFetchError> {
    verify_bold_claim_independently_fresh(
        source,
        oracle,
        claim,
        tx_hash,
        batch_id,
        confirmed_head,
        &[],
    )
}

/// **Independently verify a BOLD-leg claim is backed AND fresh.**  The BOLD
/// analogue of [`verify_eth_claim_independently_fresh`]: after the same
/// confirmation-depth gate, it fetches the `oracle`-attested rate for
/// `batch_id` (→ [`ClaimBackingOutcome::RateUnavailable`] if none), converts
/// the re-derived wei cost to BOLD at *that* rate
/// ([`SequencerClaim::is_bold_receipt_backed_by`]), and applies the same
/// no-reuse check on the canonical hash (the consumed set spans both legs).
///
/// # Errors
///
/// Propagates [`ReceiptFetchError`] from the source or oracle.
pub fn verify_bold_claim_independently_fresh<S: ReceiptSource, O: RateOracle>(
    source: &S,
    oracle: &O,
    claim: &SequencerClaim,
    tx_hash: &[u8; 32],
    batch_id: u64,
    confirmed_head: u64,
    consumed: &[[u8; 32]],
) -> Result<ClaimBackingOutcome, ReceiptFetchError> {
    let Some(raw) = source.fetch_receipt(tx_hash)? else {
        return Ok(ClaimBackingOutcome::ReceiptNotFound);
    };
    // Re-org safety FIRST (as on the ETH leg): no terminal verdict for a
    // still-reorgable receipt.
    if raw.block_number > confirmed_head {
        return Ok(ClaimBackingOutcome::Unconfirmed);
    }
    let Some(gas_receipt) = derive_gas_receipt(&raw, batch_id) else {
        return Ok(ClaimBackingOutcome::TransactionFailed);
    };
    // The rate must be oracle-attested for THIS batch (the Lean
    // l1EthBoldRateOracle binding), never a caller-supplied rate.
    let Some(rate) = oracle.attested_rate(batch_id)? else {
        return Ok(ClaimBackingOutcome::RateUnavailable);
    };
    if !claim.is_bold_receipt_backed_by(&gas_receipt, &rate) {
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
/// [`ReceiptFetchError::Malformed`] if a required field (`transactionHash`,
/// `blockNumber`, `gasUsed`, `effectiveGasPrice`, `status`) is absent, or is
/// not a `0x`-prefixed hex quantity / 32-byte hash.
pub fn parse_eth_receipt(
    value: &serde_json::Value,
) -> Result<Option<EthTxReceipt>, ReceiptFetchError> {
    if value.is_null() {
        return Ok(None);
    }
    let obj = value
        .as_object()
        .ok_or_else(|| ReceiptFetchError::Malformed("receipt is not a JSON object".into()))?;
    let transaction_hash = decode_hex32(get_str(obj, "transactionHash")?).ok_or_else(|| {
        ReceiptFetchError::Malformed("transactionHash not a 0x-prefixed 32-byte hex".into())
    })?;
    let block_number = parse_hex_u64(get_str(obj, "blockNumber")?)?;
    let gas_used = parse_hex_u128(get_str(obj, "gasUsed")?)?;
    let effective_gas_price = parse_hex_u128(get_str(obj, "effectiveGasPrice")?)?;
    // EIP-658: `status` is exactly "0x1" (success) or "0x0" (revert).  Match
    // `== 1` strictly (not `!= 0`) so a non-spec status backs nothing
    // (fail-closed) rather than being treated as success.
    let status_ok = parse_hex_u128(get_str(obj, "status")?)? == 1;
    Ok(Some(EthTxReceipt {
        transaction_hash,
        block_number,
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

/// Strip the **required** `0x` prefix from a JSON-RPC hex quantity.  A field
/// without it is rejected (fail-closed) rather than parsed as bare hex —
/// e.g. a proxy returning the decimal-looking `"21000"` must NOT be read as
/// `0x21000`, which would overstate the gas cost it bounds.
fn strip_hex_prefix(s: &str) -> Result<&str, ReceiptFetchError> {
    s.strip_prefix("0x").ok_or_else(|| {
        ReceiptFetchError::Malformed(format!("quantity `{s}` lacks the required 0x prefix"))
    })
}

fn parse_hex_u128(s: &str) -> Result<u128, ReceiptFetchError> {
    u128::from_str_radix(strip_hex_prefix(s)?, 16)
        .map_err(|e| ReceiptFetchError::Malformed(format!("invalid hex quantity `{s}`: {e}")))
}

fn parse_hex_u64(s: &str) -> Result<u64, ReceiptFetchError> {
    u64::from_str_radix(strip_hex_prefix(s)?, 16)
        .map_err(|e| ReceiptFetchError::Malformed(format!("invalid hex quantity `{s}`: {e}")))
}

fn decode_hex32(s: &str) -> Option<[u8; 32]> {
    // Require the 0x prefix (JSON-RPC hashes are always 0x-prefixed).
    let stripped = s.strip_prefix("0x")?;
    if stripped.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(stripped.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(out)
}

/// [`parse_eth_receipt`] **plus** the requested-tx check: a parsed receipt is
/// rejected unless its `transactionHash` equals `expected_tx_hash`.  Defends
/// against a JSON-RPC proxy/cache that returns a receipt for a *different*
/// transaction than requested — without this, an unrelated high-cost receipt
/// could be treated as backing the claim instead of failing closed.
fn parse_eth_receipt_for(
    value: &serde_json::Value,
    expected_tx_hash: &[u8; 32],
) -> Result<Option<EthTxReceipt>, ReceiptFetchError> {
    match parse_eth_receipt(value)? {
        Some(receipt) if &receipt.transaction_hash != expected_tx_hash => {
            Err(ReceiptFetchError::Malformed(
                "receipt is for a different transaction than requested".into(),
            ))
        }
        other => Ok(other),
    }
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
        // Reject a receipt for a different tx than requested (proxy/cache defence).
        parse_eth_receipt_for(&result, tx_hash)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::action::Action;
    use crate::address_book::{GAS_POOL_ACTOR_ID, SEQUENCER_ACTOR_ID};
    use crate::key::SIGNATURE_LEN;
    use std::collections::HashMap;

    /// The block every test receipt sits in; `CONFIRMED` is a head deep
    /// enough to treat it as final, `UNCONFIRMED_HEAD` is too shallow.
    const RECEIPT_BLOCK: u64 = 100;
    const CONFIRMED: u64 = 100;
    const UNCONFIRMED_HEAD: u64 = 99;

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

    /// In-memory rate oracle keyed by batch id (the production binding is a
    /// price feed); an unknown batch attests no rate.
    #[derive(Default)]
    struct MockRateOracle {
        rates: HashMap<u64, EthBoldRate>,
    }

    impl MockRateOracle {
        fn with(mut self, batch_id: u64, rate: EthBoldRate) -> Self {
            self.rates.insert(batch_id, rate);
            self
        }
    }

    impl RateOracle for MockRateOracle {
        fn attested_rate(&self, batch_id: u64) -> Result<Option<EthBoldRate>, ReceiptFetchError> {
            Ok(self.rates.get(&batch_id).cloned())
        }
    }

    fn rate(num: u128, den: u128) -> EthBoldRate {
        EthBoldRate {
            rate_num: num,
            rate_den: den,
            rate_binding_hash: [0xCD; 32],
        }
    }

    fn ok_receipt(tx_hash: [u8; 32], gas_used: u128, gas_price: u128) -> EthTxReceipt {
        EthTxReceipt {
            transaction_hash: tx_hash,
            block_number: RECEIPT_BLOCK,
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

    fn bold_claim(amount: u128) -> SequencerClaim {
        mk_claim(Action::Transfer {
            r: 1,
            sender: GAS_POOL_ACTOR_ID,
            receiver: SEQUENCER_ACTOR_ID,
            amount,
        })
    }

    #[test]
    fn binding_hash_is_deterministic_and_tx_keyed() {
        let tx = [0x11u8; 32];
        let h = canonical_receipt_binding_hash(&tx);
        // Deterministic.
        assert_eq!(h, canonical_receipt_binding_hash(&tx));
        // Sensitive to the tx identity.
        assert_ne!(h, canonical_receipt_binding_hash(&[0x12; 32]));
        // Domain-separated: not the bare tx hash.
        assert_ne!(h, tx);
    }

    #[test]
    fn binding_hash_is_independent_of_caller_supplied_batch_id() {
        // P1 fix (review): the de-dup hash must NOT depend on the
        // caller-supplied batch_id — otherwise one real receipt could mint
        // distinct handles under different batch ids and back several claims.
        let tx = [0xAA; 32];
        let raw = ok_receipt(tx, 21_000, 50);
        let g7 = derive_gas_receipt(&raw, 7).unwrap();
        let g8 = derive_gas_receipt(&raw, 8).unwrap();
        assert_eq!(
            g7.receipt_binding_hash, g8.receipt_binding_hash,
            "same tx ⇒ same binding hash regardless of batch_id"
        );
        assert_eq!(g7.receipt_binding_hash, canonical_receipt_binding_hash(&tx));
        // batch_id is still carried (informational, the Lean-witness mirror).
        assert_eq!(g7.batch_id, 7);
        assert_eq!(g8.batch_id, 8);
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
        assert_eq!(g.receipt_binding_hash, canonical_receipt_binding_hash(&tx));
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
        // reimbursement = 1_050_000; an under-cost, confirmed claim is backed.
        let claim = eth_claim(1_000_000);
        assert_eq!(
            verify_eth_claim_independently(&source, &claim, &tx, 7, CONFIRMED).unwrap(),
            ClaimBackingOutcome::Backed
        );
        // Exactly at cost is backed (boundary).
        assert!(
            verify_eth_claim_independently(&source, &eth_claim(1_050_000), &tx, 7, CONFIRMED)
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
            verify_eth_claim_independently(&source, &eth_claim(2_000_000), &tx, 7, CONFIRMED)
                .unwrap(),
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
            verify_eth_claim_independently(&source, &wrong, &tx, 7, CONFIRMED).unwrap(),
            ClaimBackingOutcome::NotBacked
        );
    }

    #[test]
    fn independent_verify_rejects_unconfirmed_receipt() {
        // P1 fix (review): a receipt whose block is not yet confirmation-depth
        // deep is still reorgable and must NOT be attested.
        let tx = [0xAA; 32];
        let source = MockReceiptSource::default().with(ok_receipt(tx, 21_000, 50)); // block 100
        let claim = eth_claim(1_000_000);
        // Head only 99 deep → block 100 unconfirmed.
        assert_eq!(
            verify_eth_claim_independently(&source, &claim, &tx, 7, UNCONFIRMED_HEAD).unwrap(),
            ClaimBackingOutcome::Unconfirmed
        );
        // Confirmed (head == block) and deeper → Backed.
        assert!(
            verify_eth_claim_independently(&source, &claim, &tx, 7, CONFIRMED)
                .unwrap()
                .is_backed()
        );
        assert!(verify_eth_claim_independently(&source, &claim, &tx, 7, 200)
            .unwrap()
            .is_backed());
        // The composable primitive also refuses an unconfirmed receipt.
        assert!(
            fetch_and_derive_gas_receipt(&source, &tx, 7, UNCONFIRMED_HEAD)
                .unwrap()
                .is_none()
        );
        assert!(fetch_and_derive_gas_receipt(&source, &tx, 7, CONFIRMED)
            .unwrap()
            .is_some());
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
            verify_eth_claim_independently(&source, &eth_claim(1), &[0xCC; 32], 7, CONFIRMED)
                .unwrap(),
            ClaimBackingOutcome::ReceiptNotFound
        );
        // Reverted tx → TransactionFailed.
        assert_eq!(
            verify_eth_claim_independently(&source, &eth_claim(1), &other, 7, CONFIRMED).unwrap(),
            ClaimBackingOutcome::TransactionFailed
        );
    }

    #[test]
    fn unconfirmed_failed_receipt_is_not_terminal() {
        // Review fix: a still-reorgable receipt must NOT yield a terminal
        // TransactionFailed — a re-org could replace the failure with a valid
        // tx, and a caller treating TransactionFailed as terminal would then
        // deny a later-valid reimbursement.  Confirmation is checked first.
        let tx = [0xAA; 32];
        let mut reverted = ok_receipt(tx, 21_000, 50); // block 100, status 0
        reverted.status_ok = false;
        let source = MockReceiptSource::default().with(reverted);
        let claim = eth_claim(1);
        // Unconfirmed head → Unconfirmed (not TransactionFailed): keep retrying.
        assert_eq!(
            verify_eth_claim_independently(&source, &claim, &tx, 7, UNCONFIRMED_HEAD).unwrap(),
            ClaimBackingOutcome::Unconfirmed
        );
        // Once confirmation-depth deep, the failure IS terminal.
        assert_eq!(
            verify_eth_claim_independently(&source, &claim, &tx, 7, CONFIRMED).unwrap(),
            ClaimBackingOutcome::TransactionFailed
        );
        // The BOLD leg has the same ordering.
        let oracle = MockRateOracle::default().with(7, rate(2, 1));
        assert_eq!(
            verify_bold_claim_independently(&source, &oracle, &claim, &tx, 7, UNCONFIRMED_HEAD)
                .unwrap(),
            ClaimBackingOutcome::Unconfirmed
        );
    }

    #[test]
    fn parse_eth_receipt_for_rejects_mismatched_tx() {
        // Review fix: a proxy/cache that returns a receipt for a DIFFERENT tx
        // than requested must fail closed, not back the claim with an
        // unrelated (possibly higher-cost) receipt.
        let v: serde_json::Value = serde_json::json!({
            "transactionHash": "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "blockNumber": "0x64",
            "gasUsed": "0x5208",
            "effectiveGasPrice": "0x32",
            "status": "0x1"
        });
        // Requested hash matches the receipt → Ok(Some).
        assert!(parse_eth_receipt_for(&v, &[0xAA; 32]).unwrap().is_some());
        // Requested a DIFFERENT tx → Malformed (the RPC returned the wrong one).
        assert!(
            parse_eth_receipt_for(&v, &[0xBB; 32]).is_err(),
            "a receipt for a different tx must be rejected"
        );
        // null → Ok(None) regardless of the requested hash.
        assert!(parse_eth_receipt_for(&serde_json::Value::Null, &[0xBB; 32])
            .unwrap()
            .is_none());
    }

    #[test]
    fn independent_bold_verify_uses_the_oracle_rate() {
        let tx = [0xAA; 32];
        let source = MockReceiptSource::default().with(ok_receipt(tx, 21_000, 50));
        // Oracle attests rate 2:1 for batch 7 — wei 1_050_000 * 2 = 2_100_000.
        let oracle = MockRateOracle::default().with(7, rate(2, 1));
        assert!(verify_bold_claim_independently(
            &source,
            &oracle,
            &bold_claim(2_100_000),
            &tx,
            7,
            CONFIRMED
        )
        .unwrap()
        .is_backed());
        assert_eq!(
            verify_bold_claim_independently(
                &source,
                &oracle,
                &bold_claim(2_100_001),
                &tx,
                7,
                CONFIRMED
            )
            .unwrap(),
            ClaimBackingOutcome::NotBacked
        );
        // An ETH-leg claim is not BOLD-backed.
        assert_eq!(
            verify_bold_claim_independently(&source, &oracle, &eth_claim(1), &tx, 7, CONFIRMED)
                .unwrap(),
            ClaimBackingOutcome::NotBacked
        );
    }

    #[test]
    fn independent_bold_verify_binds_the_rate_to_the_batch() {
        // P2 fix (review): the rate must be oracle-attested for THIS batch.
        // The oracle attests 2:1 for batch 7 and 1:1 for batch 8.
        let tx = [0xAA; 32];
        let source = MockReceiptSource::default().with(ok_receipt(tx, 21_000, 50));
        let oracle = MockRateOracle::default()
            .with(7, rate(2, 1))
            .with(8, rate(1, 1));
        let claim = bold_claim(2_100_000); // == 1_050_000 * 2
                                           // Batch 7 (rate 2) → backed.
        assert!(
            verify_bold_claim_independently(&source, &oracle, &claim, &tx, 7, CONFIRMED)
                .unwrap()
                .is_backed()
        );
        // The SAME claim against batch 8 (rate 1) exceeds the cost → NotBacked:
        // a higher-batch rate cannot be reused to back a lower-batch claim.
        assert_eq!(
            verify_bold_claim_independently(&source, &oracle, &claim, &tx, 8, CONFIRMED).unwrap(),
            ClaimBackingOutcome::NotBacked
        );
        // A batch with NO attested rate → RateUnavailable (cannot be backed),
        // even though the gas receipt itself is fine.
        assert_eq!(
            verify_bold_claim_independently(&source, &oracle, &claim, &tx, 9, CONFIRMED).unwrap(),
            ClaimBackingOutcome::RateUnavailable
        );
    }

    #[test]
    fn parse_eth_receipt_parses_and_rejects() {
        let v: serde_json::Value = serde_json::json!({
            "transactionHash": "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "blockNumber": "0x64",          // 100
            "gasUsed": "0x5208",            // 21000
            "effectiveGasPrice": "0x32",    // 50
            "status": "0x1"
        });
        let r = parse_eth_receipt(&v).unwrap().expect("non-null");
        assert_eq!(r.block_number, 100);
        assert_eq!(r.gas_used, 21_000);
        assert_eq!(r.effective_gas_price, 50);
        assert!(r.status_ok);
        assert_eq!(r.transaction_hash, [0xAA; 32]);
        // null → None.
        assert!(parse_eth_receipt(&serde_json::Value::Null)
            .unwrap()
            .is_none());
        // Reverted status parses with status_ok = false.
        let with_status = |s: &str| {
            let mut obj = v.as_object().unwrap().clone();
            obj.insert("status".into(), serde_json::Value::String(s.into()));
            parse_eth_receipt(&serde_json::Value::Object(obj))
                .unwrap()
                .unwrap()
                .status_ok
        };
        assert!(!with_status("0x0"));
        // Strict EIP-658: a NON-SPEC status (not exactly 0x1) is NOT success.
        assert!(!with_status("0x2"), "a non-spec status must not be success");
        assert!(with_status("0x1"));
        // P2 fix (review): a quantity WITHOUT the 0x prefix is rejected
        // (fail-closed), not silently parsed as hex — `"21000"` must NOT be
        // read as 0x21000 and overstate the gas cost.
        let mut no_prefix = v.as_object().unwrap().clone();
        no_prefix.insert("gasUsed".into(), serde_json::Value::String("21000".into()));
        assert!(
            parse_eth_receipt(&serde_json::Value::Object(no_prefix)).is_err(),
            "a non-0x-prefixed quantity must be Malformed, not parsed as hex"
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
        let canon = canonical_receipt_binding_hash(&tx);
        // Fresh (nothing consumed) → Backed.
        assert_eq!(
            verify_eth_claim_independently_fresh(&source, &claim, &tx, 7, CONFIRMED, &[]).unwrap(),
            ClaimBackingOutcome::Backed
        );
        // After the CANONICAL hash is consumed → Reused.
        assert_eq!(
            verify_eth_claim_independently_fresh(&source, &claim, &tx, 7, CONFIRMED, &[canon])
                .unwrap(),
            ClaimBackingOutcome::Reused
        );
        // A DIFFERENT consumed hash does NOT block: the observer keys on the
        // canonical re-derived hash, so a sequencer-fabricated hash is
        // irrelevant to the no-reuse decision (the security invariant).
        assert_eq!(
            verify_eth_claim_independently_fresh(&source, &claim, &tx, 7, CONFIRMED, &[[0xFF; 32]])
                .unwrap(),
            ClaimBackingOutcome::Backed
        );
        // An over-cost claim is NotBacked even when fresh (backing precedes
        // the freshness check).
        assert_eq!(
            verify_eth_claim_independently_fresh(
                &source,
                &eth_claim(2_000_000),
                &tx,
                7,
                CONFIRMED,
                &[]
            )
            .unwrap(),
            ClaimBackingOutcome::NotBacked
        );
        // The backing-only wrapper never reports Reused.
        assert_eq!(
            verify_eth_claim_independently(&source, &claim, &tx, 7, CONFIRMED).unwrap(),
            ClaimBackingOutcome::Backed
        );
    }

    #[test]
    fn fresh_bold_verify_rejects_a_reused_receipt() {
        let tx = [0xAA; 32];
        let source = MockReceiptSource::default().with(ok_receipt(tx, 21_000, 50));
        let oracle = MockRateOracle::default().with(7, rate(2, 1));
        let claim = bold_claim(2_000_000);
        let canon = canonical_receipt_binding_hash(&tx);
        assert_eq!(
            verify_bold_claim_independently_fresh(&source, &oracle, &claim, &tx, 7, CONFIRMED, &[])
                .unwrap(),
            ClaimBackingOutcome::Backed
        );
        assert_eq!(
            verify_bold_claim_independently_fresh(
                &source,
                &oracle,
                &claim,
                &tx,
                7,
                CONFIRMED,
                &[canon]
            )
            .unwrap(),
            ClaimBackingOutcome::Reused
        );
    }

    #[test]
    fn fetch_and_derive_exposes_the_canonical_receipt() {
        let tx = [0xAA; 32];
        let source = MockReceiptSource::default().with(ok_receipt(tx, 21_000, 50));
        let gr = fetch_and_derive_gas_receipt(&source, &tx, 7, CONFIRMED)
            .unwrap()
            .expect("present");
        assert_eq!(gr.receipt_binding_hash, canonical_receipt_binding_hash(&tx));
        assert_eq!(gr.reimbursement(), 1_050_000);
        // Missing tx → None.
        assert!(
            fetch_and_derive_gas_receipt(&source, &[0xCC; 32], 7, CONFIRMED)
                .unwrap()
                .is_none()
        );
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
        let observer_gr = fetch_and_derive_gas_receipt(&source, &tx, 7, CONFIRMED)
            .unwrap()
            .unwrap(); // observer side
        assert_eq!(
            builder_gr.receipt_binding_hash, observer_gr.receipt_binding_hash,
            "builder and observer must agree on the canonical binding hash"
        );
        // A within-cost claim verifies Backed; consuming the canonical hash
        // then drives the no-reuse rejection.
        let claim = eth_claim(500);
        assert!(
            verify_eth_claim_independently(&source, &claim, &tx, 7, CONFIRMED)
                .unwrap()
                .is_backed()
        );
        assert_eq!(
            verify_eth_claim_independently_fresh(
                &source,
                &claim,
                &tx,
                7,
                CONFIRMED,
                &[builder_gr.receipt_binding_hash]
            )
            .unwrap(),
            ClaimBackingOutcome::Reused
        );
    }
}

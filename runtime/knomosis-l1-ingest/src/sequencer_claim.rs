// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Sequencer reimbursement-claim constructor (Workstream GP.8 Track B):
//! the v1 honour-system claim ([`SequencerClaim::build`]) and the v2
//! receipt-verified claim ([`SequencerClaim::build_receipt_backed`],
//! GP.8.5).
//!
//! The sequencer pays real L1 ETH/BOLD to submit state roots (Workstream
//! H); it funds that from the gas pool, which accrues the deposit
//! fee-split skim + per-actor top-up revenue at [`GAS_POOL_ACTOR_ID`].
//! A reimbursement claim is a single kernel action:
//!
//! ```text
//! Action::Transfer { r, sender: GAS_POOL_ACTOR_ID,
//!                    receiver: SEQUENCER_ACTOR_ID, amount }
//! ```
//!
//! signed by the gas-pool actor's own registered key.  It is admitted
//! under the GP.7.4 genesis-ratified governance, whose **proven** Lean
//! properties (`gasPoolPolicy_denies_all_non_transfer`,
//! `…_requires_sequencer_recipient_{eth,bold}`, `…_caps_per_action`,
//! and the GP.7.3 per-trace bound `pool_drain_bounded_by_action_count`)
//! mean: the pool moves only its own funds, only to the sequencer, and
//! by at most `maxDrainPerAction` per action.
//!
//! ## Safety by construction
//!
//! This constructor builds **only** well-shaped claims:
//!
//!   * the recipient is hard-wired to [`SEQUENCER_ACTOR_ID`] — a
//!     wrong-recipient claim is *unconstructible* via this API;
//!   * the amount is clamped to the per-action cap (`maxDrainPerAction`
//!     for the leg) — an over-cap claim is *unconstructible*.
//!
//! So a claim produced here can never be one `gasPoolPolicy` rejects for
//! shape (the kernel rejects it anyway; this is defence in depth + a
//! fail-*early* ergonomic for the operator).
//!
//! ## Honour system (v1) and the receipt-verified path (v2)
//!
//! [`SequencerClaim::build`] is the **honour-system** (v1) claim:
//! `amount` is the operator's estimate of L1 gas spent, *not* a proven
//! receipt.  A fully-malicious operator can claim up to the cap
//! regardless of real spend — accepted because (i) the cap bounds the
//! loss per action and (via GP.7.3) per trace, (ii) the sequencer is
//! already trusted for liveness, and (iii) the dispute pipeline can
//! challenge sustained over-claims.
//!
//! [`SequencerClaim::build_receipt_backed`] is the **receipt-verified**
//! (v2, GP.8.5) claim: it binds `amount` to a concrete L1 batch-
//! publication [`GasReceipt`], clamping it to `min(cap, gasUsed *
//! gasPrice)` so the admitted amount can never exceed the wei the
//! sequencer actually paid on L1.  This is the Rust mirror of the Lean
//! gate `LegalKernel.Bridge.receiptVerifiedClaimAdmissible` and its
//! `gasReceiptReimbursement` bound; the kernel **action is identical**
//! to v1 (v2 adds an admissibility *gate*, not a new action — the v1
//! wire shape is forward-compatible), and [`SequencerClaim`] exposes
//! [`SequencerClaim::is_receipt_backed_by`] as the runtime mirror of
//! the Lean witness's `amount_backed` field.
//!
//! **Both legs (OQ-GP-8b).**  The gas receipt cost is wei
//! (`gasUsed * gasPrice`), so the **ETH leg** (resource `0`,
//! [`SequencerClaim::build_receipt_backed`]) is exact and oracle-free.
//! The **BOLD leg** (resource `1`, [`SequencerClaim::build_receipt_backed_bold`])
//! converts that wei cost to BOLD base units via an attested ETH→BOLD
//! [`EthBoldRate`] — a second trust assumption (the price oracle), mirroring
//! the Lean `l1EthBoldRateOracle` / `boldReceiptReimbursement`.  Both
//! builders double-clamp to `min(cap, receipt cost)` and expose a
//! shape-checked observer re-check ([`SequencerClaim::is_receipt_backed_by`] /
//! [`SequencerClaim::is_bold_receipt_backed_by`]).  The independent-observer
//! receipt-fetch binding (re-deriving the receipt from L1, not trusting the
//! builder) lives in [`crate::receipt_verifier`].
//!
//! ## Key handling
//!
//! The pool key is held behind [`BridgeActorKey`] (a `Zeroizing`
//! secp256k1 scalar).  This module never logs key material and never
//! exposes the private bytes.

use crate::action::{Action, Amount, ResourceId};
use crate::address_book::{GAS_POOL_ACTOR_ID, SEQUENCER_ACTOR_ID};
use crate::encoding::{encode_signed_action, signing_input, EncodeError};
use crate::key::{BridgeActorKey, KeyError, SIGNATURE_LEN};

/// Error constructing a sequencer reimbursement claim.
#[derive(Debug)]
pub enum ClaimError {
    /// CBE encoding of the signing input or the signed action failed.
    Encode(EncodeError),
    /// Signing the claim with the pool key failed.
    Key(KeyError),
}

impl core::fmt::Display for ClaimError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            ClaimError::Encode(e) => write!(f, "claim encoding failed: {e}"),
            ClaimError::Key(e) => write!(f, "claim signing failed: {e}"),
        }
    }
}

impl std::error::Error for ClaimError {}

impl From<EncodeError> for ClaimError {
    fn from(e: EncodeError) -> Self {
        ClaimError::Encode(e)
    }
}

impl From<KeyError> for ClaimError {
    fn from(e: KeyError) -> Self {
        ClaimError::Key(e)
    }
}

/// A signed sequencer reimbursement claim, ready to submit to the host.
///
/// Constructed by [`SequencerClaim::build`], which guarantees the
/// invariants documented on this module (recipient is the sequencer;
/// amount ≤ cap).
#[derive(Clone)]
pub struct SequencerClaim {
    /// The kernel action — always a `Transfer` from [`GAS_POOL_ACTOR_ID`]
    /// to [`SEQUENCER_ACTOR_ID`] with a capped amount.
    pub action: Action,
    /// The signer actor id — always [`GAS_POOL_ACTOR_ID`].
    pub signer: u64,
    /// The signer's expected nonce for this claim.
    pub nonce: u128,
    /// The 64-byte `(r || s)` low-s ECDSA signature over the
    /// domain-separated signing input.
    pub sig: [u8; SIGNATURE_LEN],
}

impl SequencerClaim {
    /// Build and sign a reimbursement claim of `requested_amount` of
    /// `resource`, **clamped** to `cap` (the leg's `maxDrainPerAction`).
    ///
    /// The recipient is always [`SEQUENCER_ACTOR_ID`] and the amount is
    /// `min(requested_amount, cap)`, so the result is always within the
    /// `gasPoolPolicy` bound.  `nonce` must equal the gas-pool actor's
    /// expected next nonce; `deployment_id` domain-separates the
    /// signature.
    ///
    /// # Errors
    ///
    /// Returns [`ClaimError::Encode`] if the signing input cannot be
    /// encoded, or [`ClaimError::Key`] if signing fails.
    pub fn build(
        key: &BridgeActorKey,
        resource: ResourceId,
        requested_amount: Amount,
        cap: Amount,
        nonce: u128,
        deployment_id: &[u8],
    ) -> Result<Self, ClaimError> {
        // Over-cap is unconstructible: clamp to the per-action cap.
        let amount = requested_amount.min(cap);
        // Wrong-recipient is unconstructible: hard-wire the sequencer.
        let action = Action::Transfer {
            r: resource,
            sender: GAS_POOL_ACTOR_ID,
            receiver: SEQUENCER_ACTOR_ID,
            amount,
        };
        let signer = GAS_POOL_ACTOR_ID;
        let input = signing_input(&action, signer, nonce, deployment_id)?;
        // `sign_keccak256` keccak256-hashes the signing input and signs
        // the digest, matching the verifier's expectation.
        let sig = key.sign_keccak256(&input)?;
        Ok(SequencerClaim {
            action,
            signer,
            nonce,
            sig,
        })
    }

    /// The amount actually claimed (post-clamp) at the claim's resource.
    #[must_use]
    pub fn amount(&self) -> Amount {
        match self.action {
            Action::Transfer { amount, .. } => amount,
            // Unreachable: `build` only ever produces a `Transfer`.
            _ => 0,
        }
    }

    /// Encode the claim as CBE `SignedAction` wire bytes for submission.
    ///
    /// # Errors
    ///
    /// Returns [`ClaimError::Encode`] if the signed action cannot be
    /// encoded.
    pub fn encode(&self) -> Result<Vec<u8>, ClaimError> {
        Ok(encode_signed_action(
            &self.action,
            self.signer,
            self.nonce,
            &self.sig,
        )?)
    }

    /// Build and sign a **receipt-verified** (v2, GP.8.5) reimbursement
    /// claim for the ETH leg (resource `0`), backed by a concrete L1
    /// batch-publication [`GasReceipt`].
    ///
    /// The amount is **double-clamped** to `min(requested_amount, cap,
    /// receipt.reimbursement())` — so it can never exceed EITHER the
    /// GP.7.2 per-action cap OR the wei the sequencer actually paid on
    /// L1 (`gasUsed * gasPrice`).  This is the constructive Rust mirror
    /// of the Lean gate `receiptVerifiedClaimAdmissible`: by
    /// construction the result satisfies both the cap bound and the
    /// receipt bound `amount ≤ gasReceiptReimbursement`, so an over-spend
    /// claim is *unconstructible* via this API just as it is
    /// untypeable in Lean.
    ///
    /// The kernel action is byte-identical to a v1 [`SequencerClaim::build`]
    /// claim of the same amount; the receipt is the off-chain witness an
    /// observer re-checks (via [`SequencerClaim::is_receipt_backed_by`]),
    /// not part of the signed wire payload.
    ///
    /// # Errors
    ///
    /// Returns [`ClaimError::Encode`] if the signing input cannot be
    /// encoded, or [`ClaimError::Key`] if signing fails.
    pub fn build_receipt_backed(
        key: &BridgeActorKey,
        receipt: &GasReceipt,
        requested_amount: Amount,
        cap: Amount,
        nonce: u128,
        deployment_id: &[u8],
    ) -> Result<Self, ClaimError> {
        // Double-clamp: within the per-action cap AND within the
        // L1-verified wei cost.  `min` of both is unconstructibly safe.
        let amount = requested_amount.min(cap).min(receipt.reimbursement());
        // ETH leg (resource 0) only — the leg whose receipt cost is wei.
        Self::build(key, 0, amount, amount, nonce, deployment_id)
    }

    /// Runtime mirror of the Lean gate `receiptVerifiedClaimAdmissible`:
    /// is this claim a *canonical ETH-leg* sequencer-reimbursement claim
    /// whose amount is within the wei cost the `receipt` justifies?
    ///
    /// The Lean gate admits ONLY `transfer 0 gasPoolActor sequencerActor
    /// amount` with `amount ≤ gasUsed * gasPrice`, so this check
    /// validates the full **action shape** (resource `0`, sender
    /// `GAS_POOL_ACTOR_ID`, receiver `SEQUENCER_ACTOR_ID`) BEFORE
    /// comparing the amount.  Without the shape check an observer
    /// re-verifying a submitted claim could misclassify a noncanonical
    /// claim — a BOLD-leg (resource 1) transfer, a wrong-recipient or
    /// wrong-sender transfer built through the v1 honour-system path, or
    /// a non-transfer action — as "receipt-verified" merely because its
    /// amount happened to fall under the receipt cost.  Returns `false`
    /// for every such noncanonical claim regardless of amount.
    #[must_use]
    pub fn is_receipt_backed_by(&self, receipt: &GasReceipt) -> bool {
        match self.action {
            Action::Transfer {
                r,
                sender,
                receiver,
                amount,
            } => {
                r == 0
                    && sender == GAS_POOL_ACTOR_ID
                    && receiver == SEQUENCER_ACTOR_ID
                    && amount <= receipt.reimbursement()
            }
            _ => false,
        }
    }

    /// The ENFORCED re-check (PR #126 review): is this claim BOTH
    /// canonically receipt-backed (shape + amount — [`is_receipt_backed_by`])
    /// AND backed by a FRESH receipt whose binding hash has not already
    /// been consumed by a prior claim?  Mirrors the Lean
    /// `SequencerReimbursementVerifiedFresh` / `receiptEnforcedClaimAdmissible`.
    ///
    /// An observer or host enforcing v2 threads the set of already-spent
    /// receipt binding hashes through `consumed`; a receipt that backed a
    /// prior claim is rejected here, so one L1 receipt backs AT MOST one
    /// reimbursement.  Without this freshness check the per-claim
    /// `min(cap, cost)` bound would NOT lift to a batch — a sequencer
    /// could present one receipt to back N claims and drain N× the spend.
    #[must_use]
    pub fn is_receipt_fresh_and_backed(&self, receipt: &GasReceipt, consumed: &[[u8; 32]]) -> bool {
        self.is_receipt_backed_by(receipt) && !consumed.contains(&receipt.receipt_binding_hash)
    }

    /// Build and sign a **receipt-verified BOLD-leg** (resource `1`,
    /// GP.8.5 v2 / OQ-GP-8b) reimbursement claim, backed by a concrete L1
    /// [`GasReceipt`] AND an attested ETH→BOLD [`EthBoldRate`].
    ///
    /// The wei receipt cost is converted to BOLD base units at the
    /// attested rate (`gasUsed * gasPrice * rate_num / rate_den`, floored),
    /// and the amount is **double-clamped** to `min(requested_amount, cap,
    /// receipt.bold_reimbursement(rate))` — so it can never exceed EITHER
    /// the GP.7.2 per-action BOLD cap OR the BOLD value of the wei the
    /// sequencer actually paid on L1.  The Rust mirror of the Lean gate
    /// `receiptVerifiedBoldClaimAdmissible` / `boldReceiptReimbursement`:
    /// by construction an over-claim is *unconstructible* via this API.
    ///
    /// # Errors
    ///
    /// Returns [`ClaimError::Encode`] if the signing input cannot be
    /// encoded, or [`ClaimError::Key`] if signing fails.
    pub fn build_receipt_backed_bold(
        key: &BridgeActorKey,
        receipt: &GasReceipt,
        rate: &EthBoldRate,
        requested_amount: Amount,
        cap: Amount,
        nonce: u128,
        deployment_id: &[u8],
    ) -> Result<Self, ClaimError> {
        // Triple-clamp: within the per-action BOLD cap AND within the
        // rate-converted L1 wei cost.
        let amount = requested_amount
            .min(cap)
            .min(receipt.bold_reimbursement(rate));
        // BOLD leg (resource 1).
        Self::build(key, 1, amount, amount, nonce, deployment_id)
    }

    /// Runtime mirror of the Lean gate `receiptVerifiedBoldClaimAdmissible`:
    /// is this claim a *canonical BOLD-leg* (resource `1`) sequencer-
    /// reimbursement claim whose amount is within the BOLD value the
    /// `receipt` justifies at `rate`?
    ///
    /// Validates the full **action shape** (resource `1`, sender
    /// `GAS_POOL_ACTOR_ID`, receiver `SEQUENCER_ACTOR_ID`) before comparing
    /// the amount against `receipt.bold_reimbursement(rate)`.  Returns
    /// `false` for every noncanonical claim regardless of amount — an
    /// ETH-leg (resource `0`) transfer, a wrong-recipient / wrong-sender
    /// transfer, or a non-transfer action — so an observer cannot
    /// misclassify a v1 honour-system or off-leg claim as BOLD-receipt-
    /// verified.
    #[must_use]
    pub fn is_bold_receipt_backed_by(&self, receipt: &GasReceipt, rate: &EthBoldRate) -> bool {
        match self.action {
            Action::Transfer {
                r,
                sender,
                receiver,
                amount,
            } => {
                r == 1
                    && sender == GAS_POOL_ACTOR_ID
                    && receiver == SEQUENCER_ACTOR_ID
                    && amount <= receipt.bold_reimbursement(rate)
            }
            _ => false,
        }
    }

    /// The ENFORCED BOLD re-check: is this claim BOTH canonically
    /// BOLD-receipt-backed ([`is_bold_receipt_backed_by`]) AND backed by a
    /// FRESH receipt (binding hash not already consumed)?  The BOLD
    /// analogue of [`is_receipt_fresh_and_backed`] — the consumed set is
    /// shared across legs, so one L1 batch receipt backs at most one
    /// reimbursement whether ETH or BOLD.
    #[must_use]
    pub fn is_bold_receipt_fresh_and_backed(
        &self,
        receipt: &GasReceipt,
        rate: &EthBoldRate,
        consumed: &[[u8; 32]],
    ) -> bool {
        self.is_bold_receipt_backed_by(receipt, rate)
            && !consumed.contains(&receipt.receipt_binding_hash)
    }
}

/// A concrete L1 batch-publication gas receipt: the off-chain witness
/// that backs a receipt-verified (v2) reimbursement claim.
///
/// Mirrors the fields of the Lean `SequencerReimbursementVerified`
/// witness (`batchId`, `gasUsed`, `gasPrice`, `receiptBindingHash`).
/// The L1 watcher (`knomosis-l1-ingest`) constructs one of these from a
/// confirmed batch-publication transaction receipt; the `reimbursement`
/// it justifies is exactly `gasUsed * gasPrice` wei (the Lean
/// `gasReceiptReimbursement`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GasReceipt {
    /// The L1 batch id this receipt settles.
    pub batch_id: u64,
    /// The gas units the L1 batch-publication transaction consumed.
    pub gas_used: u128,
    /// The effective gas price (wei per gas) of that transaction.
    pub gas_price: u128,
    /// The 32-byte binding hash (keccak-256) of the L1 receipt, the
    /// handle the deployment-side verifier attests.
    pub receipt_binding_hash: [u8; 32],
}

impl GasReceipt {
    /// The maximum reimbursement (wei) this receipt justifies:
    /// `gas_used * gas_price`, the exact EVM gas-cost identity — the
    /// Rust mirror of the Lean `gasReceiptReimbursement`.  Uses a
    /// **saturating** product so a pathological receipt can never wrap
    /// (it would merely cap the reimbursement at `Amount::MAX`, which
    /// the per-action `cap` then bounds further down).
    #[must_use]
    pub fn reimbursement(&self) -> Amount {
        self.gas_used.saturating_mul(self.gas_price)
    }

    /// The maximum BOLD reimbursement (BOLD base units) this receipt
    /// justifies at the attested `rate`: the wei cost converted via
    /// `rate.rate_num / rate.rate_den` BOLD-per-wei and rounded DOWN — the
    /// Rust mirror of the Lean `boldReceiptReimbursement`.  Fail-closed on
    /// a zero denominator (returns `0`).
    #[must_use]
    pub fn bold_reimbursement(&self, rate: &EthBoldRate) -> Amount {
        bold_receipt_reimbursement(self.gas_used, self.gas_price, rate.rate_num, rate.rate_den)
    }
}

/// An attested ETH→BOLD exchange rate (the OQ-GP-8b price oracle's output):
/// the rational `rate_num / rate_den` BOLD base units per ETH wei, bound to
/// its `rate_binding_hash`.  Mirrors the Lean `SequencerReimbursementVerifiedBold`
/// witness's `(rateNum, rateDen, rateBindingHash)` triple; the deployment-side
/// oracle attests it for a given batch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EthBoldRate {
    /// Rate numerator — BOLD base units.
    pub rate_num: u128,
    /// Rate denominator — ETH wei.
    pub rate_den: u128,
    /// The 32-byte binding hash of the rate quotation (the handle the
    /// deployment-side oracle attests).
    pub rate_binding_hash: [u8; 32],
}

/// The maximum BOLD reimbursement (BOLD base units) a verified wei
/// expenditure justifies at rate `rate_num / rate_den`:
/// `⌊gas_used * gas_price * rate_num / rate_den⌋` — the Rust mirror of the
/// Lean `boldReceiptReimbursement`.  Uses **saturating** products so a
/// pathological receipt/rate caps at `Amount::MAX` (which the per-action
/// `cap` then bounds further) rather than wrapping, and **floor** division
/// so the result never exceeds the real-valued conversion (never
/// over-reimburses).  A zero denominator returns `0` (fail-closed, mirroring
/// the Lean `_ / 0 = 0`).
#[must_use]
pub fn bold_receipt_reimbursement(
    gas_used: u128,
    gas_price: u128,
    rate_num: u128,
    rate_den: u128,
) -> Amount {
    if rate_den == 0 {
        return 0;
    }
    let wei = gas_used.saturating_mul(gas_price);
    wei.saturating_mul(rate_num) / rate_den
}

/// The maximum reimbursement (wei) a verified L1 gas expenditure
/// justifies: `gas_used * gas_price` (saturating).  Free-function form
/// of [`GasReceipt::reimbursement`], the Rust mirror of the Lean
/// `gasReceiptReimbursement`.
#[must_use]
pub fn gas_receipt_reimbursement(gas_used: u128, gas_price: u128) -> Amount {
    gas_used.saturating_mul(gas_price)
}

#[cfg(test)]
mod tests {
    use super::*;
    use k256::ecdsa::signature::hazmat::PrehashVerifier;
    use k256::ecdsa::{Signature as K256Sig, VerifyingKey};
    use sha3::{Digest, Keccak256};

    /// A fixed, valid secp256k1 scalar for the pool key under test.
    const TEST_SCALAR: [u8; 32] = [
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x20,
    ];

    fn test_key() -> BridgeActorKey {
        BridgeActorKey::from_private_bytes(&TEST_SCALAR).expect("valid scalar")
    }

    #[test]
    fn claim_is_capped_gas_pool_to_sequencer_transfer() {
        let key = test_key();
        let claim = SequencerClaim::build(&key, 0, 500, 1000, 7, b"dep").unwrap();
        match claim.action {
            Action::Transfer {
                r,
                sender,
                receiver,
                amount,
            } => {
                assert_eq!(r, 0);
                assert_eq!(sender, GAS_POOL_ACTOR_ID);
                assert_eq!(receiver, SEQUENCER_ACTOR_ID);
                assert_eq!(amount, 500, "under-cap request passes through");
            }
            _ => panic!("claim must be a Transfer"),
        }
        assert_eq!(claim.signer, GAS_POOL_ACTOR_ID);
    }

    #[test]
    fn over_cap_request_is_clamped_to_cap() {
        let key = test_key();
        let claim = SequencerClaim::build(&key, 1, 9_999, 1000, 0, b"dep").unwrap();
        assert_eq!(claim.amount(), 1000, "over-cap request clamps to the cap");
        // And the recipient is still the sequencer — wrong-recipient is
        // unconstructible regardless of the requested amount.
        match claim.action {
            Action::Transfer { receiver, .. } => assert_eq!(receiver, SEQUENCER_ACTOR_ID),
            _ => panic!("claim must be a Transfer"),
        }
    }

    #[test]
    fn signature_verifies_against_the_pool_public_key() {
        let key = test_key();
        let claim = SequencerClaim::build(&key, 0, 250, 1000, 3, b"deployment-xyz").unwrap();
        // Recompute the domain-separated signing input and verify the
        // claim's signature against the pool's public key.
        let input =
            signing_input(&claim.action, claim.signer, claim.nonce, b"deployment-xyz").unwrap();
        let prehash = Keccak256::digest(&input);
        let vk = VerifyingKey::from_sec1_bytes(&key.public_key_compressed()).unwrap();
        let sig = K256Sig::from_slice(&claim.sig).unwrap();
        assert!(
            vk.verify_prehash(&prehash, &sig).is_ok(),
            "claim signature must verify under the pool public key"
        );
    }

    #[test]
    fn build_is_deterministic_and_encodes() {
        // RFC6979 deterministic ECDSA: identical inputs ⇒ identical wire.
        let key = test_key();
        let a = SequencerClaim::build(&key, 1, 42, 1000, 11, b"dep").unwrap();
        let b = SequencerClaim::build(&key, 1, 42, 1000, 11, b"dep").unwrap();
        assert_eq!(a.encode().unwrap(), b.encode().unwrap());
        assert!(!a.encode().unwrap().is_empty());
    }

    // ===== GP.8.5 (v2): receipt-verified claim =====

    /// A receipt for a realistic batch: 21 000 gas @ 50 gwei.
    fn test_receipt(gas_used: u128, gas_price: u128) -> GasReceipt {
        GasReceipt {
            batch_id: 7,
            gas_used,
            gas_price,
            receipt_binding_hash: [0xAB; 32],
        }
    }

    #[test]
    fn reimbursement_is_gas_used_times_gas_price() {
        // Mirror of the Lean `gasReceiptReimbursement` value test.
        assert_eq!(gas_receipt_reimbursement(21_000, 50), 1_050_000);
        assert_eq!(test_receipt(21_000, 50).reimbursement(), 1_050_000);
        // Zero corners: no free claim.
        assert_eq!(gas_receipt_reimbursement(0, 999), 0);
        assert_eq!(gas_receipt_reimbursement(999, 0), 0);
    }

    #[test]
    fn reimbursement_saturates_instead_of_wrapping() {
        // A pathological receipt caps at Amount::MAX rather than wrapping.
        assert_eq!(gas_receipt_reimbursement(u128::MAX, 2), u128::MAX);
        assert_eq!(
            test_receipt(u128::MAX, u128::MAX).reimbursement(),
            u128::MAX
        );
    }

    #[test]
    fn receipt_backed_clamps_to_the_receipt_when_it_binds() {
        // reimbursement (1_050_000) < cap (10_000_000): the RECEIPT is the
        // binding constraint — this is the v2 teeth over v1's cap-only.
        let key = test_key();
        let receipt = test_receipt(21_000, 50);
        let claim =
            SequencerClaim::build_receipt_backed(&key, &receipt, 9_999_999, 10_000_000, 1, b"dep")
                .unwrap();
        assert_eq!(
            claim.amount(),
            1_050_000,
            "amount clamps to the receipt cost"
        );
        assert!(claim.is_receipt_backed_by(&receipt));
        // Shape: ETH-leg gas-pool → sequencer transfer.
        match claim.action {
            Action::Transfer {
                r,
                sender,
                receiver,
                amount,
            } => {
                assert_eq!(r, 0, "receipt-backed claims are ETH-leg only");
                assert_eq!(sender, GAS_POOL_ACTOR_ID);
                assert_eq!(receiver, SEQUENCER_ACTOR_ID);
                assert_eq!(amount, 1_050_000);
            }
            _ => panic!("claim must be a Transfer"),
        }
    }

    #[test]
    fn receipt_backed_still_respects_the_cap_when_cap_binds() {
        // cap (1000) < reimbursement (1_050_000): the GP.7.2 CAP still
        // binds — v2 is a strengthening, never a relaxation, of v1.
        let key = test_key();
        let receipt = test_receipt(21_000, 50);
        let claim =
            SequencerClaim::build_receipt_backed(&key, &receipt, 9_999_999, 1000, 2, b"dep")
                .unwrap();
        assert_eq!(claim.amount(), 1000, "amount clamps to the cap");
        assert!(claim.is_receipt_backed_by(&receipt));
    }

    #[test]
    fn receipt_backed_passes_through_under_both_bounds() {
        // requested (500) < cap and < reimbursement: passes through.
        let key = test_key();
        let receipt = test_receipt(21_000, 50);
        let claim = SequencerClaim::build_receipt_backed(&key, &receipt, 500, 1_000_000, 3, b"dep")
            .unwrap();
        assert_eq!(claim.amount(), 500);
        assert!(claim.is_receipt_backed_by(&receipt));
    }

    #[test]
    fn is_receipt_backed_by_rejects_an_overspend() {
        // A v1 claim whose amount exceeds the receipt cost is NOT
        // receipt-backed — the runtime mirror of the Lean negative.
        let key = test_key();
        let receipt = test_receipt(21_000, 50); // reimbursement = 1_050_000
        let overspend = SequencerClaim::build(&key, 0, 2_000_000, 10_000_000, 4, b"dep").unwrap();
        assert_eq!(overspend.amount(), 2_000_000);
        assert!(
            !overspend.is_receipt_backed_by(&receipt),
            "an over-receipt amount must NOT be receipt-backed"
        );
        // Exactly at the receipt cost is backed (boundary).
        let at_cost = SequencerClaim::build(&key, 0, 1_050_000, 10_000_000, 5, b"dep").unwrap();
        assert!(at_cost.is_receipt_backed_by(&receipt));
    }

    #[test]
    fn is_receipt_backed_by_rejects_noncanonical_claim_shapes() {
        // The Lean gate `receiptVerifiedClaimAdmissible` admits ONLY
        // `transfer 0 gasPoolActor sequencerActor amount`.  An observer
        // re-checking a submitted claim must NOT classify a noncanonical
        // claim as receipt-verified even when its amount is within the
        // receipt cost — otherwise a v1 honour-system / off-leg /
        // victim-drain claim could be mis-accepted.
        let receipt = test_receipt(21_000, 50); // reimbursement = 1_050_000
        let small = 500u128; // well within the receipt cost
        let mk = |action: Action| SequencerClaim {
            action,
            signer: GAS_POOL_ACTOR_ID,
            nonce: 0,
            sig: [0u8; SIGNATURE_LEN],
        };
        // BOLD leg (resource 1) — out of the wei-denominated v2 scope.
        assert!(
            !mk(Action::Transfer {
                r: 1,
                sender: GAS_POOL_ACTOR_ID,
                receiver: SEQUENCER_ACTOR_ID,
                amount: small,
            })
            .is_receipt_backed_by(&receipt),
            "BOLD-leg claim must NOT be receipt-backed"
        );
        // Wrong recipient (not the sequencer).
        assert!(
            !mk(Action::Transfer {
                r: 0,
                sender: GAS_POOL_ACTOR_ID,
                receiver: 9,
                amount: small,
            })
            .is_receipt_backed_by(&receipt),
            "wrong-recipient claim must NOT be receipt-backed"
        );
        // Wrong sender (the victim-drain shape — sender is not the pool).
        assert!(
            !mk(Action::Transfer {
                r: 0,
                sender: 9,
                receiver: SEQUENCER_ACTOR_ID,
                amount: small,
            })
            .is_receipt_backed_by(&receipt),
            "wrong-sender claim must NOT be receipt-backed"
        );
        // A non-transfer action.
        assert!(
            !mk(Action::Mint {
                r: 0,
                to: SEQUENCER_ACTOR_ID,
                amount: small,
            })
            .is_receipt_backed_by(&receipt),
            "non-transfer action must NOT be receipt-backed"
        );
        // Positive control: the canonical ETH-leg claim within cost IS backed.
        assert!(
            mk(Action::Transfer {
                r: 0,
                sender: GAS_POOL_ACTOR_ID,
                receiver: SEQUENCER_ACTOR_ID,
                amount: small,
            })
            .is_receipt_backed_by(&receipt),
            "canonical ETH-leg claim within cost MUST be receipt-backed"
        );
    }

    #[test]
    fn is_receipt_fresh_and_backed_rejects_consumed_receipts() {
        // PR #126 review c2: a receipt that backed a prior claim cannot
        // back a second — the runtime mirror of consumeReceipt_blocks_reuse.
        let key = test_key();
        let receipt = test_receipt(21_000, 50); // reimbursement = 1_050_000
        let claim = SequencerClaim::build_receipt_backed(&key, &receipt, 500, 1_000_000, 1, b"dep")
            .unwrap();
        // Fresh (nothing consumed) → backed.
        assert!(claim.is_receipt_fresh_and_backed(&receipt, &[]));
        // After this receipt's binding hash is consumed → NOT fresh → rejected.
        let consumed = [receipt.receipt_binding_hash];
        assert!(
            !claim.is_receipt_fresh_and_backed(&receipt, &consumed),
            "a consumed receipt must NOT back a second claim"
        );
        // A DIFFERENT consumed hash does not block a fresh receipt.
        let other = [[0x00u8; 32]];
        assert!(claim.is_receipt_fresh_and_backed(&receipt, &other));
        // An overspend is rejected even when the receipt is fresh
        // (shape/amount check still applies).
        let overspend = SequencerClaim::build(&key, 0, 2_000_000, 10_000_000, 2, b"dep").unwrap();
        assert!(!overspend.is_receipt_fresh_and_backed(&receipt, &[]));
    }

    #[test]
    fn receipt_backed_signature_verifies() {
        // The v2 builder reuses the v1 signing path; the signature must
        // still verify against the pool public key.
        let key = test_key();
        let receipt = test_receipt(21_000, 50);
        let claim =
            SequencerClaim::build_receipt_backed(&key, &receipt, 500, 1_000_000, 9, b"dep-xyz")
                .unwrap();
        let input = signing_input(&claim.action, claim.signer, claim.nonce, b"dep-xyz").unwrap();
        let prehash = Keccak256::digest(&input);
        let vk = VerifyingKey::from_sec1_bytes(&key.public_key_compressed()).unwrap();
        let sig = K256Sig::from_slice(&claim.sig).unwrap();
        assert!(
            vk.verify_prehash(&prehash, &sig).is_ok(),
            "receipt-backed claim signature must verify"
        );
    }

    // ===== GP.8.5 / OQ-GP-8b: BOLD leg + ETH→BOLD price oracle =====

    /// A rate of `num / den` BOLD base units per ETH wei.
    fn test_rate(num: u128, den: u128) -> EthBoldRate {
        EthBoldRate {
            rate_num: num,
            rate_den: den,
            rate_binding_hash: [0xCD; 32],
        }
    }

    #[test]
    fn bold_reimbursement_converts_wei_via_rate() {
        // 21000 gas @ 50 wei = 1.05e6 wei; at 3000 BOLD/wei (den 1) = 3.15e9.
        assert_eq!(
            bold_receipt_reimbursement(21_000, 50, 3000, 1),
            3_150_000_000
        );
        assert_eq!(
            test_receipt(21_000, 50).bold_reimbursement(&test_rate(3000, 1)),
            3_150_000_000
        );
    }

    #[test]
    fn bold_reimbursement_floors_and_fail_closes() {
        // Floor: 10 wei * 1 / 3 = 3 (not 4) — never over-reimburses.
        assert_eq!(bold_receipt_reimbursement(10, 1, 1, 3), 3);
        assert_eq!(bold_receipt_reimbursement(2, 1, 1, 3), 0);
        // Zero corners.
        assert_eq!(bold_receipt_reimbursement(0, 50, 3000, 1), 0);
        assert_eq!(bold_receipt_reimbursement(21_000, 0, 3000, 1), 0);
        assert_eq!(bold_receipt_reimbursement(21_000, 50, 0, 1), 0);
        // den = 0 is fail-closed (mirrors Lean `_ / 0 = 0`).
        assert_eq!(bold_receipt_reimbursement(21_000, 50, 3000, 0), 0);
        // Saturating product never wraps.
        assert_eq!(bold_receipt_reimbursement(u128::MAX, 2, 1, 1), u128::MAX);
    }

    #[test]
    fn bold_receipt_backed_clamps_to_the_converted_cost() {
        // converted cost (1_050_000 * 2 = 2_100_000) < cap: the RECEIPT
        // binds — the BOLD v2 teeth over v1's cap-only.
        let key = test_key();
        let receipt = test_receipt(21_000, 50);
        let rate = test_rate(2, 1); // 2 BOLD per wei
        let claim = SequencerClaim::build_receipt_backed_bold(
            &key,
            &receipt,
            &rate,
            9_999_999_999,
            10_000_000_000,
            1,
            b"dep",
        )
        .unwrap();
        assert_eq!(
            claim.amount(),
            2_100_000,
            "clamps to the converted BOLD cost"
        );
        assert!(claim.is_bold_receipt_backed_by(&receipt, &rate));
        // Shape: BOLD-leg (resource 1) gas-pool → sequencer transfer.
        match claim.action {
            Action::Transfer {
                r,
                sender,
                receiver,
                amount,
            } => {
                assert_eq!(r, 1, "receipt-backed-bold claims are BOLD-leg");
                assert_eq!(sender, GAS_POOL_ACTOR_ID);
                assert_eq!(receiver, SEQUENCER_ACTOR_ID);
                assert_eq!(amount, 2_100_000);
            }
            _ => panic!("claim must be a Transfer"),
        }
    }

    #[test]
    fn bold_receipt_backed_still_respects_the_cap() {
        // cap (1000) < converted cost: the GP.7.2 BOLD CAP still binds.
        let key = test_key();
        let receipt = test_receipt(21_000, 50);
        let rate = test_rate(2, 1);
        let claim = SequencerClaim::build_receipt_backed_bold(
            &key, &receipt, &rate, 9_999_999, 1000, 2, b"dep",
        )
        .unwrap();
        assert_eq!(claim.amount(), 1000, "amount clamps to the BOLD cap");
        assert!(claim.is_bold_receipt_backed_by(&receipt, &rate));
    }

    #[test]
    fn is_bold_receipt_backed_by_rejects_noncanonical_claim_shapes() {
        // The Lean gate `receiptVerifiedBoldClaimAdmissible` admits ONLY
        // `transfer 1 gasPoolActor sequencerActor amount`.  Leg
        // discrimination + recipient/sender checks must hold.
        let receipt = test_receipt(21_000, 50);
        let rate = test_rate(2, 1); // converted cost = 2_100_000
        let small = 500u128;
        let mk = |action: Action| SequencerClaim {
            action,
            signer: GAS_POOL_ACTOR_ID,
            nonce: 0,
            sig: [0u8; SIGNATURE_LEN],
        };
        // ETH leg (resource 0) — must NOT be BOLD-receipt-backed.
        assert!(
            !mk(Action::Transfer {
                r: 0,
                sender: GAS_POOL_ACTOR_ID,
                receiver: SEQUENCER_ACTOR_ID,
                amount: small,
            })
            .is_bold_receipt_backed_by(&receipt, &rate),
            "ETH-leg claim must NOT be BOLD-receipt-backed"
        );
        // Wrong recipient.
        assert!(
            !mk(Action::Transfer {
                r: 1,
                sender: GAS_POOL_ACTOR_ID,
                receiver: 9,
                amount: small,
            })
            .is_bold_receipt_backed_by(&receipt, &rate),
            "wrong-recipient claim must NOT be BOLD-receipt-backed"
        );
        // Over the converted cost.
        assert!(
            !mk(Action::Transfer {
                r: 1,
                sender: GAS_POOL_ACTOR_ID,
                receiver: SEQUENCER_ACTOR_ID,
                amount: 2_100_001,
            })
            .is_bold_receipt_backed_by(&receipt, &rate),
            "over-converted-cost claim must NOT be BOLD-receipt-backed"
        );
        // Positive control: canonical BOLD-leg claim within cost IS backed.
        assert!(
            mk(Action::Transfer {
                r: 1,
                sender: GAS_POOL_ACTOR_ID,
                receiver: SEQUENCER_ACTOR_ID,
                amount: small,
            })
            .is_bold_receipt_backed_by(&receipt, &rate),
            "canonical BOLD-leg claim within cost MUST be BOLD-receipt-backed"
        );
    }

    #[test]
    fn is_bold_receipt_fresh_and_backed_rejects_consumed_receipts() {
        // The consumed set is shared across legs: a receipt that backed a
        // prior (ETH or BOLD) claim cannot back a BOLD claim.
        let key = test_key();
        let receipt = test_receipt(21_000, 50);
        let rate = test_rate(2, 1);
        let claim = SequencerClaim::build_receipt_backed_bold(
            &key, &receipt, &rate, 500, 1_000_000, 1, b"dep",
        )
        .unwrap();
        assert!(claim.is_bold_receipt_fresh_and_backed(&receipt, &rate, &[]));
        let consumed = [receipt.receipt_binding_hash];
        assert!(
            !claim.is_bold_receipt_fresh_and_backed(&receipt, &rate, &consumed),
            "a consumed receipt must NOT back a second (BOLD) claim"
        );
    }
}

-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.ReceiptVerifiedClaim — Workstream GP.8.5
(Track B v2) test suite for the receipt-verified sequencer-
reimbursement gate (`LegalKernel/Bridge/ReceiptVerifiedClaim.lean`).

Like the fault-proof `FaultProof.Witness` suite, the witness's
`l1_attestation` field references the global `l1GasReceiptVerifier`
opaque, whose value is unspecified at the Lean level — so a witness
cannot be *value-constructed* from a real attestation in a test.
Coverage is therefore the established opaque-witness mix:

  * **Pure arithmetic** (`gasReceiptReimbursement`) value-level: the
    exact EVM gas-cost identity, the zero-gas / zero-price corners,
    and a monotonicity sample.
  * **Term-level proof-path exercises** (not mere signature checks):
    given a *hypothetical* attestation + bound, the full construction
    `of_receipt → gate → headline double bound` elaborates as a closed
    proof term; the narrowing `…_implies_gasPoolPolicy`; and the
    NEGATIVE direction (a non-transfer / wrong-shape action is
    provably inadmissible).
  * **Opaque presence** — `l1GasReceiptVerifier` evaluates to a `Bool`.
  * **API stability** for every public surface.
-/

import LegalKernel
import LegalKernel.Bridge.ReceiptVerifiedClaim
import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge
namespace ReceiptVerifiedClaimTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Test

/-! ## Test cases -/

/-- All GP.8.5 (Track B v2) test cases. -/
def tests : List TestCase :=
  [ -- ## Pure-arithmetic reimbursement bound (value-level)
    { name := "GP.8.5: gasReceiptReimbursement is gasUsed * gasPrice (EVM identity)"
    , body := do
        -- A realistic batch: 21 000 gas at 50 gwei = 1 050 000 gwei.
        assertEq (expected := 21000 * 50) (actual := gasReceiptReimbursement 21000 50)
          "reimbursement = gasUsed * gasPrice"
        assertEq (expected := 1_050_000) (actual := gasReceiptReimbursement 21000 50)
          "21000 gas @ 50 = 1.05e6"
    }
  , { name := "GP.8.5: gasReceiptReimbursement zero corners"
    , body := do
        -- Zero gas or zero price ⇒ zero reimbursable: no free claim.
        assertEq (expected := 0) (actual := gasReceiptReimbursement 0 999) "zero gas ⇒ 0"
        assertEq (expected := 0) (actual := gasReceiptReimbursement 999 0) "zero price ⇒ 0"
        assertEq (expected := 0) (actual := gasReceiptReimbursement 0 0) "both zero ⇒ 0"
    }
  , { name := "GP.8.5: gasReceiptReimbursement is monotone in each factor (sample)"
    , body := do
        -- More gas (or higher price) never backs LESS reimbursement.
        assert (decide (gasReceiptReimbursement 100 7 ≤ gasReceiptReimbursement 200 7))
          "monotone in gasUsed"
        assert (decide (gasReceiptReimbursement 100 7 ≤ gasReceiptReimbursement 100 9))
          "monotone in gasPrice"
    }
  , -- ## Opaque presence
    { name := "GP.8.5: l1GasReceiptVerifier opaque is present (evaluates to Bool)"
    , body := do
        -- The deployment-supplied opaque exists with the expected arity;
        -- its value is unspecified at the Lean level (fail-closed).
        let _b : Bool := l1GasReceiptVerifier ByteArray.empty 0 0 0
        pure ()
    }
  , -- ## Term-level proof-path: construction ⇒ admissible
    { name := "GP.8.5: a backed, capped receipt is receipt-verified-admissible (proof term)"
    , body := do
        -- GIVEN a hypothetical L1 attestation `ha` for (gu, gp) and that
        -- the wei cost is within the cap, the canonical ETH-leg claim of
        -- exactly `gu * gp` is admissible — the full `of_receipt → gate`
        -- construction elaborates as a closed term.
        let _proof :
            ∀ (cap : Amount) (rbh : ByteArray) (b gu gp : Nat),
              l1GasReceiptVerifier rbh b gu gp = true →
              gu * gp ≤ cap →
              receiptVerifiedClaimAdmissible cap
                (.transfer 0 gasPoolActor sequencerActor (gu * gp)) :=
          fun _cap rbh b gu gp ha hcap =>
            ⟨gu * gp, rfl, hcap,
              ⟨SequencerReimbursementVerified.of_receipt
                  (gu * gp) rbh b gu gp ha (Nat.le_refl _)⟩⟩
        pure ()
    }
  , -- ## Term-level proof-path: admissible ⇒ double bound (headline)
    { name := "GP.8.5: headline extracts BOTH the cap and the receipt bound (proof term)"
    , body := do
        let _proof :
            ∀ (cap : Amount) (action : Action),
              receiptVerifiedClaimAdmissible cap action →
              ∃ amount, action = .transfer 0 gasPoolActor sequencerActor amount ∧
                amount ≤ cap ∧
                ∃ rbh b gu gp, l1GasReceiptVerifier rbh b gu gp = true ∧
                  amount ≤ gasReceiptReimbursement gu gp :=
          fun cap _action h => receiptVerifiedClaim_capped_and_backed cap h
        pure ()
    }
  , -- ## Term-level proof-path: narrowing (v2 ⊆ v1)
    { name := "GP.8.5: every receipt-verified claim is gasPoolPolicy-permitted (proof term)"
    , body := do
        let _proof :
            ∀ (mEth mBold : Amount) (action : Action),
              receiptVerifiedClaimAdmissible mEth action →
              (gasPoolPolicy mEth mBold).permits gasPoolActor action :=
          fun mEth mBold _action h =>
            receiptVerifiedClaimAdmissible_implies_gasPoolPolicy mEth mBold h
        pure ()
    }
  , -- ## Term-level proof-path: NEGATIVE (non-transfer inadmissible)
    { name := "GP.8.5: a non-transfer action is provably NOT receipt-verified-admissible"
    , body := do
        -- The gate's existential pins the action to a `transfer`; a
        -- `mint` can never satisfy it (constructor disjointness).
        let _proof :
            ∀ (cap : Amount),
              ¬ receiptVerifiedClaimAdmissible cap (.mint 0 sequencerActor 5) :=
          fun _cap h => by obtain ⟨_a, ha, _, _⟩ := h; simp at ha
        pure ()
    }
  , { name := "GP.8.5: a wrong-recipient transfer is provably NOT admissible (proof term)"
    , body := do
        -- A transfer to someone OTHER than sequencerActor cannot match
        -- the gate's canonical shape regardless of the receipt.
        let _proof :
            ∀ (cap amount : Amount),
              ¬ receiptVerifiedClaimAdmissible cap
                  (.transfer 0 gasPoolActor bridgeActor amount) :=
          fun _cap _amount h => by
            obtain ⟨_a, ha, _, _⟩ := h
            rw [Action.transfer.injEq] at ha
            -- ha : 0 = 0 ∧ gasPoolActor = gasPoolActor ∧
            --      bridgeActor = sequencerActor ∧ _amount = _a
            exact absurd ha.2.2.1 (by decide)
        pure ()
    }
  , -- ## API stability for every public surface
    { name := "GP.8.5: gasReceiptReimbursement API stable"
    , body := do
        let _ := @gasReceiptReimbursement
        pure ()
    }
  , { name := "GP.8.5: SequencerReimbursementVerified.of_receipt API stable"
    , body := do
        let _ := @SequencerReimbursementVerified.of_receipt
        pure ()
    }
  , { name := "GP.8.5: sequencerReimbursementVerified_backed API stable"
    , body := do
        let _ := @sequencerReimbursementVerified_backed
        pure ()
    }
  , { name := "GP.8.5: receiptVerifiedClaimAdmissible API stable"
    , body := do
        let _ := @receiptVerifiedClaimAdmissible
        pure ()
    }
  , { name := "GP.8.5: receiptVerifiedClaim_capped_and_backed API stable"
    , body := do
        let _ := @receiptVerifiedClaim_capped_and_backed
        pure ()
    }
  , { name := "GP.8.5: receiptVerifiedClaimAdmissible_implies_gasPoolPolicy API stable"
    , body := do
        let _ := @receiptVerifiedClaimAdmissible_implies_gasPoolPolicy
        pure ()
    }
  , { name := "GP.8.5: receiptVerifiedClaim_requires_backing API stable"
    , body := do
        let _ := @receiptVerifiedClaim_requires_backing
        pure ()
    }
  , -- ## Receipt consumption — no reuse (PR #126 review c2)
    { name := "GP.8.5: consumeReceipt prepends the binding hash (length grows)"
    , body := do
        let rbh : ByteArray := ⟨#[0xAB, 0xCD]⟩
        assertEq (expected := 0) (actual := ([] : ConsumedReceipts).length)
          "empty before consume"
        assertEq (expected := 1) (actual := (consumeReceipt [] rbh).length)
          "one entry after consume"
        assertEq (expected := 2) (actual := (consumeReceipt (consumeReceipt [] rbh) rbh).length)
          "two entries after two consumes"
    }
  , { name := "GP.8.5: consumeReceipt_blocks_reuse — fresh witness ⇒ hash ≠ consumed (proof term)"
    , body := do
        -- A fresh witness against `consumeReceipt consumed rbh` cannot
        -- have binding hash `rbh` — the per-receipt no-reuse guarantee.
        let _proof :
            ∀ (consumed : ConsumedReceipts) (rbh : ByteArray) (amount : Amount)
              (w : SequencerReimbursementVerifiedFresh (consumeReceipt consumed rbh) amount),
              w.backing.receiptBindingHash ≠ rbh :=
          fun consumed rbh _amount w => consumeReceipt_blocks_reuse consumed rbh w
        pure ()
    }
  , { name := "GP.8.5: a fresh-backed claim builds an enforced-admissible witness (proof term)"
    , body := do
        -- GIVEN a hypothetical attestation + a fresh receipt, the
        -- enforced gate is satisfiable (the construction elaborates).
        let _proof :
            ∀ (consumed : ConsumedReceipts) (cap : Amount) (rbh : ByteArray)
              (b gu gp : Nat),
              l1GasReceiptVerifier rbh b gu gp = true →
              gu * gp ≤ cap →
              rbh ∉ consumed →
              receiptEnforcedClaimAdmissible consumed cap
                (.transfer 0 gasPoolActor sequencerActor (gu * gp)) :=
          fun _consumed _cap rbh b gu gp ha hcap hfresh =>
            ⟨gu * gp, rfl, hcap,
              ⟨{ backing := SequencerReimbursementVerified.of_receipt
                   (gu * gp) rbh b gu gp ha (Nat.le_refl _)
               , fresh := hfresh }⟩⟩
        pure ()
    }
  , -- ## Enforcement — strictly stronger than the base gate (c4)
    { name := "GP.8.5: enforced ⇒ base ⇒ gasPoolPolicy (proof term)"
    , body := do
        let _proof :
            ∀ (consumed : ConsumedReceipts) (mEth mBold : Amount) (action : Action),
              receiptEnforcedClaimAdmissible consumed mEth action →
              (gasPoolPolicy mEth mBold).permits gasPoolActor action :=
          fun consumed mEth mBold _action h =>
            receiptEnforcedClaimAdmissible_implies_gasPoolPolicy consumed mEth mBold h
        pure ()
    }
  , { name := "GP.8.5: enforced headline = capped ∧ backed ∧ fresh (proof term)"
    , body := do
        let _proof :
            ∀ (consumed : ConsumedReceipts) (mEth : Amount) (action : Action),
              receiptEnforcedClaimAdmissible consumed mEth action →
              ∃ amount rbh b gu gp,
                action = .transfer 0 gasPoolActor sequencerActor amount ∧
                amount ≤ mEth ∧
                l1GasReceiptVerifier rbh b gu gp = true ∧
                amount ≤ gasReceiptReimbursement gu gp ∧
                rbh ∉ consumed :=
          fun consumed mEth _action h =>
            receiptEnforcedClaim_capped_backed_and_fresh consumed mEth h
        pure ()
    }
  , { name := "GP.8.5: consumption + enforcement API stable"
    , body := do
        let _ := @consumeReceipt
        let _ := @SequencerReimbursementVerifiedFresh.backing
        let _ := @consumeReceipt_blocks_reuse
        let _ := @receiptEnforcedClaimAdmissible
        let _ := @receiptEnforcedClaimAdmissible_implies_base
        let _ := @receiptEnforcedClaimAdmissible_implies_gasPoolPolicy
        let _ := @receiptEnforcedClaim_capped_backed_and_fresh
        pure ()
    }
  , -- ## Admission path requiring the gate (c4) + no reuse across admissions (c2)
    { name := "GP.8.5: receiptGatedAdmissible REQUIRES the gate for a gas-pool claim (proof term)"
    , body := do
        -- Under receipt-gated admission, a gas-pool ETH-leg claim is
        -- admitted ONLY if the enforced gate holds — the formal closure
        -- of "the v2 gate is unenforced".
        let _proof :
            ∀ (base : Prop) (consumed : ConsumedReceipts) (mEth amount : Amount),
              receiptGatedAdmissible base consumed mEth
                  (.transfer 0 gasPoolActor sequencerActor amount) →
              receiptEnforcedClaimAdmissible consumed mEth
                  (.transfer 0 gasPoolActor sequencerActor amount) :=
          fun base consumed mEth amount h =>
            receiptGatedAdmissible_requires_gate_for_claim consumed mEth ⟨amount, rfl⟩ h
        pure ()
    }
  , { name := "GP.8.5: receiptGatedAdmissible defers to base off-claim (v1 unaffected, proof term)"
    , body := do
        -- A non-claim action's gated admission is EXACTLY the base, so
        -- enabling v2 restricts only gas-pool claims.
        let _proof :
            ∀ (base : Prop) (consumed : ConsumedReceipts) (mEth : Amount) (action : Action),
              ¬ isGasPoolEthClaim action →
              (receiptGatedAdmissible base consumed mEth action ↔ base) :=
          fun base consumed mEth action hnot =>
            receiptGatedAdmissible_eq_base_off_claim consumed mEth hnot
        pure ()
    }
  , { name := "GP.8.5: no receipt reuse across admissions — 2nd claim's receipt ≠ 1st (proof term)"
    , body := do
        let _proof :
            ∀ (consumed : ConsumedReceipts) (mEth : Amount) (rbh₁ : ByteArray) (action : Action),
              receiptEnforcedClaimAdmissible (consumeReceipt consumed rbh₁) mEth action →
              ∃ amount rbh₂ b gu gp,
                action = .transfer 0 gasPoolActor sequencerActor amount ∧
                l1GasReceiptVerifier rbh₂ b gu gp = true ∧
                amount ≤ gasReceiptReimbursement gu gp ∧
                rbh₂ ≠ rbh₁ :=
          fun consumed mEth rbh₁ _action h =>
            receiptEnforced_second_claim_distinct_receipt consumed mEth rbh₁ h
        pure ()
    }
  , { name := "GP.8.5: admission-composer + distinct-receipt API stable"
    , body := do
        let _ := @isGasPoolEthClaim
        let _ := @receiptGatedAdmissible
        let _ := @receiptGatedAdmissible_implies_base
        let _ := @receiptGatedAdmissible_requires_gate_for_claim
        let _ := @receiptGatedAdmissible_eq_base_off_claim
        let _ := @receiptEnforced_second_claim_distinct_receipt
        pure ()
    }
    -- ====================================================================
    -- ## OQ-GP-8b follow-on (a): the BOLD leg + ETH→BOLD price oracle
    -- ====================================================================
  , { name := "GP.8.5-bold: boldReceiptReimbursement converts wei via the rate (floored)"
    , body := do
        -- 21000 gas @ 50 wei = 1.05e6 wei; at 3000 BOLD-base-units/wei
        -- (den 1) that is 3.15e9 BOLD base units.
        assertEq (expected := 21000 * 50 * 3000)
          (actual := boldReceiptReimbursement 21000 50 3000 1)
          "bold reimbursement = wei cost * rate (den 1)"
        assertEq (expected := 3_150_000_000)
          (actual := boldReceiptReimbursement 21000 50 3000 1) "value check"
    }
  , { name := "GP.8.5-bold: boldReceiptReimbursement rounds DOWN (never over-reimburses)"
    , body := do
        -- 10 wei * 1 / 3 = 10/3 = 3 (floor), not 4 — the conversion can
        -- never back MORE BOLD than the wei cost justifies.
        assertEq (expected := 3) (actual := boldReceiptReimbursement 10 1 1 3)
          "floor division: 10/3 = 3"
        assertEq (expected := 0) (actual := boldReceiptReimbursement 2 1 1 3)
          "floor division: 2/3 = 0"
    }
  , { name := "GP.8.5-bold: boldReceiptReimbursement fail-closed corners (zero gas/price/rate/den)"
    , body := do
        assertEq (expected := 0) (actual := boldReceiptReimbursement 0 50 3000 1) "zero gas ⇒ 0"
        assertEq (expected := 0) (actual := boldReceiptReimbursement 21000 0 3000 1) "zero price ⇒ 0"
        assertEq (expected := 0) (actual := boldReceiptReimbursement 21000 50 0 1) "zero rate ⇒ 0"
        -- den = 0 is fail-closed (Lean `_ / 0 = 0`): a malformed rate backs nothing.
        assertEq (expected := 0) (actual := boldReceiptReimbursement 21000 50 3000 0)
          "zero denominator ⇒ 0 (fail-closed)"
    }
  , { name := "GP.8.5-bold: boldReceiptReimbursement monotone in the wei cost (sample)"
    , body := do
        assert (decide (boldReceiptReimbursement 100 7 5 2 ≤ boldReceiptReimbursement 200 7 5 2))
          "monotone in gasUsed"
        assert (decide (boldReceiptReimbursement 100 7 5 2 ≤ boldReceiptReimbursement 100 9 5 2))
          "monotone in gasPrice"
    }
  , { name := "GP.8.5-bold: l1EthBoldRateOracle opaque is present (evaluates to Bool)"
    , body := do
        let _b : Bool := l1EthBoldRateOracle ByteArray.empty 0 0 1
        pure ()
    }
  , { name := "GP.8.5-bold: a backed, capped BOLD receipt is admissible (proof term)"
    , body := do
        -- GIVEN gas + rate attestations and that the converted cost is
        -- within the BOLD cap, the canonical BOLD-leg claim of exactly the
        -- converted cost is admissible — the full of_receipt → gate path.
        let _proof :
            ∀ (cap : Amount) (rbh rateBh : ByteArray) (b gu gp num den : Nat),
              l1GasReceiptVerifier rbh b gu gp = true →
              l1EthBoldRateOracle rateBh b num den = true →
              boldReceiptReimbursement gu gp num den ≤ cap →
              receiptVerifiedBoldClaimAdmissible cap
                (.transfer 1 gasPoolActor sequencerActor
                  (boldReceiptReimbursement gu gp num den)) :=
          fun _cap rbh rateBh b gu gp num den hgas hrate hcap =>
            ⟨boldReceiptReimbursement gu gp num den, rfl, hcap,
              ⟨SequencerReimbursementVerifiedBold.of_receipt
                  (boldReceiptReimbursement gu gp num den)
                  rbh rateBh b gu gp num den hgas hrate (Nat.le_refl _)⟩⟩
        pure ()
    }
  , { name := "GP.8.5-bold: BOLD headline extracts cap + gas + rate + bound (proof term)"
    , body := do
        let _proof :
            ∀ (cap : Amount) (action : Action),
              receiptVerifiedBoldClaimAdmissible cap action →
              ∃ amount, action = .transfer 1 gasPoolActor sequencerActor amount ∧
                amount ≤ cap ∧
                ∃ rbh rateBh b gu gp num den,
                  l1GasReceiptVerifier rbh b gu gp = true ∧
                  l1EthBoldRateOracle rateBh b num den = true ∧
                  amount ≤ boldReceiptReimbursement gu gp num den :=
          fun cap _action h => receiptVerifiedBoldClaim_capped_and_backed cap h
        pure ()
    }
  , { name := "GP.8.5-bold: every BOLD receipt-verified claim is gasPoolPolicy-permitted (proof term)"
    , body := do
        let _proof :
            ∀ (mEth mBold : Amount) (action : Action),
              receiptVerifiedBoldClaimAdmissible mBold action →
              (gasPoolPolicy mEth mBold).permits gasPoolActor action :=
          fun mEth mBold _action h =>
            receiptVerifiedBoldClaimAdmissible_implies_gasPoolPolicy mEth mBold h
        pure ()
    }
  , { name := "GP.8.5-bold: an ETH-leg (resource 0) transfer is NOT BOLD-admissible (proof term)"
    , body := do
        -- Leg discrimination: the BOLD gate pins resource 1, so a
        -- resource-0 transfer can never satisfy it (regardless of receipt).
        let _proof :
            ∀ (cap amount : Amount),
              ¬ receiptVerifiedBoldClaimAdmissible cap
                  (.transfer 0 gasPoolActor sequencerActor amount) :=
          fun _cap _amount h => by
            obtain ⟨_a, ha, _, _⟩ := h
            rw [Action.transfer.injEq] at ha
            exact absurd ha.1 (by decide)
        pure ()
    }
  , { name := "GP.8.5-bold: a non-transfer action is NOT BOLD-admissible (proof term)"
    , body := do
        let _proof :
            ∀ (cap : Amount),
              ¬ receiptVerifiedBoldClaimAdmissible cap (.mint 1 sequencerActor 5) :=
          fun _cap h => by obtain ⟨_a, ha, _, _⟩ := h; simp at ha
        pure ()
    }
  , { name := "GP.8.5-bold: a wrong-recipient BOLD transfer is NOT admissible (proof term)"
    , body := do
        -- A resource-1 transfer to someone OTHER than sequencerActor cannot
        -- match the BOLD gate's canonical shape (recipient discrimination).
        let _proof :
            ∀ (cap amount : Amount),
              ¬ receiptVerifiedBoldClaimAdmissible cap
                  (.transfer 1 gasPoolActor bridgeActor amount) :=
          fun _cap _amount h => by
            obtain ⟨_a, ha, _, _⟩ := h
            rw [Action.transfer.injEq] at ha
            exact absurd ha.2.2.1 (by decide)
        pure ()
    }
  , { name := "GP.8.5-bold: consumeReceipt_blocks_reuse_bold — fresh ⇒ hash ≠ consumed (proof term)"
    , body := do
        let _proof :
            ∀ (consumed : ConsumedReceipts) (rbh : ByteArray) (amount : Amount)
              (w : SequencerReimbursementVerifiedBoldFresh (consumeReceipt consumed rbh) amount),
              w.backing.receiptBindingHash ≠ rbh :=
          fun consumed rbh _amount w => consumeReceipt_blocks_reuse_bold consumed rbh w
        pure ()
    }
  , { name := "GP.8.5-bold: enforced BOLD ⇒ base ⇒ gasPoolPolicy (proof term)"
    , body := do
        let _proof :
            ∀ (consumed : ConsumedReceipts) (mEth mBold : Amount) (action : Action),
              receiptEnforcedBoldClaimAdmissible consumed mBold action →
              (gasPoolPolicy mEth mBold).permits gasPoolActor action :=
          fun consumed mEth mBold _action h =>
            receiptEnforcedBoldClaimAdmissible_implies_gasPoolPolicy consumed mEth mBold h
        pure ()
    }
  , -- ## Unified composer — gate BOTH legs (the OQ-GP-8b closure)
    { name := "GP.8.5-bold: unified composer REQUIRES the BOLD gate for a BOLD claim (proof term)"
    , body := do
        -- The gap the ETH-only `receiptGatedAdmissible` left open: under
        -- the unified composer a BOLD gas-pool claim is admitted ONLY if
        -- the enforced BOLD gate holds.
        let _proof :
            ∀ (base : Prop) (consumed : ConsumedReceipts) (mEth mBold amount : Amount),
              receiptGatedAdmissibleUnified base consumed mEth mBold
                  (.transfer 1 gasPoolActor sequencerActor amount) →
              receiptEnforcedBoldClaimAdmissible consumed mBold
                  (.transfer 1 gasPoolActor sequencerActor amount) :=
          fun _base consumed mEth mBold amount h =>
            receiptGatedAdmissibleUnified_requires_bold_gate consumed mEth mBold ⟨amount, rfl⟩ h
        pure ()
    }
  , { name := "GP.8.5-bold: unified composer REQUIRES the ETH gate for an ETH claim (proof term)"
    , body := do
        let _proof :
            ∀ (base : Prop) (consumed : ConsumedReceipts) (mEth mBold amount : Amount),
              receiptGatedAdmissibleUnified base consumed mEth mBold
                  (.transfer 0 gasPoolActor sequencerActor amount) →
              receiptEnforcedClaimAdmissible consumed mEth
                  (.transfer 0 gasPoolActor sequencerActor amount) :=
          fun _base consumed mEth mBold amount h =>
            receiptGatedAdmissibleUnified_requires_eth_gate consumed mEth mBold ⟨amount, rfl⟩ h
        pure ()
    }
  , { name := "GP.8.5-bold: unified composer defers to base off-claim (v1 unaffected, proof term)"
    , body := do
        let _proof :
            ∀ (base : Prop) (consumed : ConsumedReceipts) (mEth mBold : Amount) (action : Action),
              ¬ isGasPoolClaim action →
              (receiptGatedAdmissibleUnified base consumed mEth mBold action ↔ base) :=
          fun _base consumed mEth mBold action hnot =>
            receiptGatedAdmissibleUnified_eq_base_off_claim consumed mEth mBold hnot
        pure ()
    }
  , { name := "GP.8.5-bold: BOLD-leg + unified-composer API stable"
    , body := do
        let _ := @l1EthBoldRateOracle
        let _ := @boldReceiptReimbursement
        let _ := @SequencerReimbursementVerifiedBold.of_receipt
        let _ := @sequencerReimbursementVerifiedBold_backed
        let _ := @receiptVerifiedBoldClaimAdmissible
        let _ := @receiptVerifiedBoldClaim_capped_and_backed
        let _ := @receiptVerifiedBoldClaimAdmissible_implies_gasPoolPolicy
        let _ := @SequencerReimbursementVerifiedBoldFresh.backing
        let _ := @consumeReceipt_blocks_reuse_bold
        let _ := @receiptEnforcedBoldClaimAdmissible
        let _ := @receiptEnforcedBoldClaimAdmissible_implies_base
        let _ := @receiptEnforcedBoldClaimAdmissible_implies_gasPoolPolicy
        let _ := @receiptEnforcedBoldClaim_capped_backed_and_fresh
        let _ := @isGasPoolBoldClaim
        let _ := @isGasPoolClaim
        let _ := @receiptGatedAdmissibleUnified
        let _ := @receiptGatedAdmissibleUnified_implies_base
        let _ := @receiptGatedAdmissibleUnified_requires_eth_gate
        let _ := @receiptGatedAdmissibleUnified_requires_bold_gate
        let _ := @receiptGatedAdmissibleUnified_eq_base_off_claim
        pure ()
    }
  ]

end ReceiptVerifiedClaimTests
end LegalKernel.Test.Bridge

-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.ReceiptVerifiedClaim — Workstream GP.8.5 (Track B
"v2": the receipt-verified sequencer-reimbursement gate).

The GP.8 Track B *v1* claim (`runtime/.../sequencer_claim.rs`) is an
**honour-system** reimbursement: the gas-pool actor signs a capped
`transfer` to `sequencerActor`, and the GP.7.2 `gasPoolPolicy` bounds
the per-action amount by `maxDrainPerActionEth`.  The amount is the
operator's *estimate* of L1 publishing gas — not a proven receipt.  A
fully-malicious operator can therefore claim up to the cap regardless
of real spend (accepted in v1 because the cap bounds the loss and the
sequencer is already trusted for liveness).

This module ships the **v2 strengthening** the v1 docstring promises:
"v2 adds an admissibility *gate*, not a new action."  The claim action
is unchanged (the same `transfer gasPoolActor → sequencerActor`); what
v2 adds is a *receipt witness* binding the claimed amount to a real,
L1-verified gas expenditure, so the admitted amount is bounded by
`min(cap, actual L1 wei cost)` rather than the cap alone.

**Trust-boundary characterization.**  Like `FaultProof.Witness`, this
module introduces ONE new `opaque` trust assumption — the
deployment-side `l1GasReceiptVerifier`, which observes an L1 batch-
publication transaction and attests its exact `(gasUsed, gasPrice)`.
Per the Workstream-A discipline, `opaque` declarations never appear in
`#print axioms` output; only `propext` / `Quot.sound` (and possibly
`Classical.choice`) remain in the audit trail.  Mitigation is the same
as the fault-proof verifier's: the attestation can be cross-checked
across multiple independent L1 watchers (`runtime/knomosis-l1-ingest`).

This module is **not** part of the kernel TCB.  A bug here can only
ever *narrow* what the gas pool may pay out (the gate is a conjunction
ON TOP of `gasPoolPolicy`); it cannot widen pool outflow or violate any
kernel invariant.  `receiptVerifiedClaimAdmissible_implies_gasPoolPolicy`
proves the narrowing direction formally: every v2-admissible claim is
already GP.7.2-admissible.

**Unit scope.**  The verifier attests the L1 *wei* cost
(`gasUsed * gasPrice`).  The exact, oracle-free reimbursement bound is
therefore the ETH leg (resource `0`, denominated in wei); this module
gates exactly that leg.  Reimbursing the BOLD leg (resource `1`) from a
wei-denominated receipt would require a deployment-configured ETH→BOLD
price oracle (a SECOND trust assumption); that is a deliberate,
documented boundary, left to v1 honour-system-within-cap until such an
oracle is ratified, and is not hidden behind this gate.
-/

import LegalKernel.Bridge.GasPoolPolicy

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-! ## L1 gas-receipt verifier (deployment-supplied opaque)

The single new trust assumption.  It mirrors
`FaultProof.l1FaultProofVerifier` exactly: a `Bool`-valued `opaque`
that the production deployment binds to the Rust L1 watcher, and that
test code substitutes with a deterministic mock *at the use-site* (by
passing a verifier function as an argument), never relying on the
global opaque's value. -/

/-- Deployment-supplied L1 gas-receipt verifier.  Given the binding
    hash of an L1 batch-publication transaction receipt, the batch id
    it settles, and the `(gasUsed, gasPrice)` that transaction
    consumed, the deployment-side L1 watcher confirms whether a
    matching receipt with exactly that gas expenditure exists on L1.
    Returns `true` iff yes.

    `opaque` (not `axiom`): identical discipline to
    `FaultProof.l1FaultProofVerifier`.  Opaque declarations do not
    appear in `#print axioms`, so the kernel's axiom footprint is
    unchanged.  Until a production deployment links the watcher, the
    Lean-level value is unspecified (the opaque has no defining
    equation), so NO witness is constructible without an explicit
    deployment-time attestation — exactly the fail-closed posture of
    the fault-proof verifier. -/
opaque l1GasReceiptVerifier
    (receiptBindingHash : ByteArray) (batchId : Nat)
    (gasUsed : Nat) (gasPrice : Nat) : Bool

/-! ## Reimbursement bound -/

/-- The maximum reimbursement (in wei) a verified L1 gas expenditure
    justifies: `gasUsed * gasPrice`, the exact EVM gas-cost identity —
    i.e. the L1 wei the sequencer actually paid to publish the batch.
    This is the *upper bound* a receipt backs; a deployment may
    reimburse less, never more. -/
def gasReceiptReimbursement (gasUsed gasPrice : Nat) : Amount :=
  gasUsed * gasPrice

/-! ## The receipt witness

`SequencerReimbursementVerified amount` is the v2 analogue of the
Phase-6 `VerdictPassedStage3` / fault-proof `FaultProofChallengerWon`
propositional witness: a callsite that can present it has discharged
the receipt-backing requirement at the type level.  Its two
load-bearing fields are an L1 *attestation* (the opaque returned
`true`) and an *amount bound* (`amount ≤ gasUsed * gasPrice`).
Together they certify: the claimed `amount` does not exceed an L1
expenditure that the deployment-side watcher confirmed actually
happened. -/

/-- A propositional witness that a sequencer reimbursement of `amount`
    wei is fully backed by an L1-verified gas expenditure.

    The witness exhibits a concrete L1 receipt — its binding hash,
    batch id, and `(gasUsed, gasPrice)` — together with:
      * `l1_attestation`: the deployment-side watcher confirmed a
        batch-publication receipt with exactly that gas expenditure;
      * `amount_backed`: the claimed `amount` is within the wei cost
        that receipt justifies (`gasUsed * gasPrice`).

    Without this witness the v2 gate (`receiptVerifiedClaimAdmissible`)
    cannot be entered, so an unbacked over-claim is *unconstructible*
    at the type level — the v2 analogue of "replay impossible". -/
structure SequencerReimbursementVerified (amount : Amount) where
  /-- The binding hash of the L1 batch-publication transaction receipt. -/
  receiptBindingHash : ByteArray
  /-- The L1 batch id this receipt settles. -/
  batchId : Nat
  /-- The gas units the L1 batch-publication transaction consumed. -/
  gasUsed : Nat
  /-- The effective gas price (wei per gas) of that transaction. -/
  gasPrice : Nat
  /-- The L1 attestation: the deployment-side watcher confirms a
      batch-publication receipt with exactly this `(gasUsed, gasPrice)`.
      Depends on the `l1GasReceiptVerifier` opaque. -/
  l1_attestation :
    l1GasReceiptVerifier receiptBindingHash batchId gasUsed gasPrice = true
  /-- The reimbursement bound: the claimed `amount` does not exceed the
      L1 wei cost the verified receipt justifies. -/
  amount_backed : amount ≤ gasReceiptReimbursement gasUsed gasPrice

/-- Construct a `SequencerReimbursementVerified` witness from a
    concrete L1 receipt and the two discharged obligations (the
    attestation and the amount bound).  Mirrors
    `FaultProofChallengerWon.of_log_entry`: a one-line aggregator that
    downstream callers use after externally discharging the
    attestation (from the L1 watcher) and the bound (a `Nat`
    comparison). -/
def SequencerReimbursementVerified.of_receipt
    (amount : Amount) (receiptBindingHash : ByteArray)
    (batchId gasUsed gasPrice : Nat)
    (h_attest :
      l1GasReceiptVerifier receiptBindingHash batchId gasUsed gasPrice = true)
    (h_backed : amount ≤ gasReceiptReimbursement gasUsed gasPrice) :
    SequencerReimbursementVerified amount where
  receiptBindingHash := receiptBindingHash
  batchId := batchId
  gasUsed := gasUsed
  gasPrice := gasPrice
  l1_attestation := h_attest
  amount_backed := h_backed

/-- **Backing projection.**  A receipt witness for `amount` exhibits an
    L1-attested gas expenditure whose wei cost is at least `amount`.
    This is the headline content of the witness, threaded out for
    downstream callers — the v2 analogue of
    `faultProof_challenger_won_carries_l1_attestation`. -/
theorem sequencerReimbursementVerified_backed
    {amount : Amount} (w : SequencerReimbursementVerified amount) :
    ∃ rbh batchId gasUsed gasPrice,
      l1GasReceiptVerifier rbh batchId gasUsed gasPrice = true ∧
      amount ≤ gasReceiptReimbursement gasUsed gasPrice :=
  ⟨w.receiptBindingHash, w.batchId, w.gasUsed, w.gasPrice,
   w.l1_attestation, w.amount_backed⟩

/-! ## The receipt-verified admission gate

`receiptVerifiedClaimAdmissible` is the v2 admission predicate.  It is
phrased as a single existential over the claimed `amount` (avoiding a
catch-all `match`, which keeps every downstream proof a one-step
`obtain`), and it conjoins THREE requirements onto the bare claim:

  1. the action is *exactly* the canonical ETH-leg claim
     (`transfer 0 gasPoolActor sequencerActor amount`);
  2. `amount ≤ maxDrainPerActionEth` — the GP.7.2 cap still applies; and
  3. a `SequencerReimbursementVerified amount` witness exists — the new
     receipt-backing requirement.

Because (2) and (3) are *both* required, an admitted claim is bounded
by `min(cap, verified wei cost)` — strictly tighter than v1's cap
alone. -/

/-- The v2 receipt-verified admission gate for an ETH-leg
    sequencer-reimbursement claim.  Holds iff the action is the
    canonical capped `gasPoolActor → sequencerActor` transfer AND a
    receipt witness backs the claimed amount.

    Stated as `∃ amount, action = … ∧ amount ≤ cap ∧ Nonempty (…)`:
    the `Nonempty` is the propositional "a receipt witness exists",
    eliminable into any `Prop` goal.  This predicate sits alongside —
    never replaces — `gasPoolPolicy`; a deployment that wants v2
    semantics admits a pool claim iff BOTH `gasPoolPolicy` permits it
    AND this gate holds (and `…_implies_gasPoolPolicy` shows the latter
    already implies the former on the ETH leg, so the gate is a pure
    strengthening). -/
def receiptVerifiedClaimAdmissible
    (maxDrainPerActionEth : Amount) (action : Action) : Prop :=
  ∃ amount,
    action = .transfer 0 gasPoolActor sequencerActor amount ∧
    amount ≤ maxDrainPerActionEth ∧
    Nonempty (SequencerReimbursementVerified amount)

/-- **Headline (v2 double bound).**  Every receipt-verified-admissible
    claim is BOTH within the GP.7.2 cap AND backed wei-for-wei by an
    L1-attested gas expenditure.  This is the v2 strengthening made
    precise: where v1 guarantees only `amount ≤ cap`, v2 additionally
    exhibits a verified L1 receipt whose cost is at least `amount`, so
    the effective bound is `min(cap, L1 wei cost)`.

    The proof is a two-step destructure: unpack the gate's existential,
    eliminate the `Nonempty` witness, and project its backing. -/
theorem receiptVerifiedClaim_capped_and_backed
    (maxDrainPerActionEth : Amount) {action : Action}
    (h : receiptVerifiedClaimAdmissible maxDrainPerActionEth action) :
    ∃ amount,
      action = .transfer 0 gasPoolActor sequencerActor amount ∧
      amount ≤ maxDrainPerActionEth ∧
      (∃ rbh batchId gasUsed gasPrice,
        l1GasReceiptVerifier rbh batchId gasUsed gasPrice = true ∧
        amount ≤ gasReceiptReimbursement gasUsed gasPrice) := by
  obtain ⟨amount, haction, hcap, hwit⟩ := h
  obtain ⟨w⟩ := hwit
  exact ⟨amount, haction, hcap, sequencerReimbursementVerified_backed w⟩

/-- **v2 is a pure strengthening of v1 (the narrowing direction).**
    Every receipt-verified-admissible claim is already permitted by the
    GP.7.2 `gasPoolPolicy` (for any BOLD cap).  So enabling the v2 gate
    can only ever REJECT claims `gasPoolPolicy` would have admitted,
    never admit one it would have rejected — the gate cannot widen pool
    outflow.  Discharged by the GP.7.2 happy-path lemma
    `gasPoolPolicy_permits_sequencer_transfer_eth`. -/
theorem receiptVerifiedClaimAdmissible_implies_gasPoolPolicy
    (maxDrainPerActionEth maxDrainPerActionBold : Amount) {action : Action}
    (h : receiptVerifiedClaimAdmissible maxDrainPerActionEth action) :
    (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
      gasPoolActor action := by
  obtain ⟨amount, haction, hcap, _⟩ := h
  subst haction
  exact gasPoolPolicy_permits_sequencer_transfer_eth
    maxDrainPerActionEth maxDrainPerActionBold gasPoolActor amount hcap

/-- **No unbacked claim (receipt-backing is mandatory).**  A
    receipt-verified-admissible claim of `amount` over the ETH leg
    necessarily exhibits an L1 gas expenditure `gasUsed * gasPrice`
    that the watcher attested and that covers `amount`.  The positive
    form of "v2 rejects an over-claim": there is no admissible claim
    whose amount exceeds every verified receipt's cost.  An immediate
    corollary of the headline, specialised to the canonical transfer. -/
theorem receiptVerifiedClaim_requires_backing
    (maxDrainPerActionEth amount : Amount)
    (h : receiptVerifiedClaimAdmissible maxDrainPerActionEth
          (.transfer 0 gasPoolActor sequencerActor amount)) :
    ∃ rbh batchId gasUsed gasPrice,
      l1GasReceiptVerifier rbh batchId gasUsed gasPrice = true ∧
      amount ≤ gasReceiptReimbursement gasUsed gasPrice := by
  obtain ⟨amount', haction, _, hbackq⟩ :=
    receiptVerifiedClaim_capped_and_backed maxDrainPerActionEth h
  -- The headline's existential `amount'` is pinned to `amount` by the
  -- transfer's injectivity (same action shape), after which the
  -- backing conjunct IS the goal.
  simp only [Action.transfer.injEq, true_and] at haction
  subst haction
  exact hbackq

end Bridge
end LegalKernel

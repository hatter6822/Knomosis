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

/-! ## Receipt consumption — no cross-claim reuse (PR #126 review)

`receiptVerifiedClaim_capped_and_backed` bounds EACH claim by its
receipt's wei cost.  Over a BATCH of claims that only yields the intended
`Σᵢ min(cap, costᵢ)` bound if each claim consumes a DISTINCT receipt —
otherwise a sequencer could present one L1 receipt to back `N` claims and
drain up to `N ×` the real spend.  This section adds receipt consumption:
a binding hash, once consumed, can never back another claim.  It is the
per-receipt analogue of the deposit/withdraw `consumed`-map replay
protection (`Bridge/Admissible.lean`). -/

/-- The L1 gas-receipt binding hashes already consumed by an admitted v2
    claim.  A deployment threads this through its admission so each
    receipt backs at most one reimbursement. -/
abbrev ConsumedReceipts := List ByteArray

/-- Mark a receipt's binding hash consumed. -/
def consumeReceipt (consumed : ConsumedReceipts) (rbh : ByteArray) :
    ConsumedReceipts := rbh :: consumed

/-- A receipt-verified claim that consumes a **fresh** receipt: the
    backing witness's binding hash is not already in `consumed`.  Bundles
    the backing (attestation + amount bound) with the freshness
    obligation, so a claim cannot reuse a receipt a prior claim spent. -/
structure SequencerReimbursementVerifiedFresh
    (consumed : ConsumedReceipts) (amount : Amount) where
  /-- The backing witness (L1 attestation + the `amount ≤ cost` bound). -/
  backing : SequencerReimbursementVerified amount
  /-- The receipt has NOT been consumed by a prior claim. -/
  fresh : backing.receiptBindingHash ∉ consumed

/-- **A consumed receipt can never back a fresh claim.**  After
    `consumeReceipt consumed rbh`, every `SequencerReimbursementVerifiedFresh`
    witness over the updated set has a binding hash ≠ `rbh` — so the same
    L1 receipt cannot be presented twice.  This is the per-receipt
    replay-protection guarantee (cf. `deposit_replay_blocked_by_consumed`). -/
theorem consumeReceipt_blocks_reuse
    (consumed : ConsumedReceipts) (rbh : ByteArray) {amount : Amount}
    (w : SequencerReimbursementVerifiedFresh (consumeReceipt consumed rbh) amount) :
    w.backing.receiptBindingHash ≠ rbh := by
  intro h
  apply w.fresh
  simp only [consumeReceipt, h, List.mem_cons, true_or]

/-! ## Enforced admission — closing the "unenforced gate" gap (PR #126 review)

`receiptVerifiedClaimAdmissible` is a standalone PROOF surface.  A
v2-enabled deployment ENFORCES it by REQUIRING a fresh-receipt witness
for every gas-pool → sequencer claim, composed into its admission
alongside `gasPoolPolicy` (intersection, as with `gasPoolAuthorityPolicy`
in GP.7.4).  `receiptEnforcedClaimAdmissible` is that composite: a v1
honour-system claim WITHOUT a receipt fails it, so it is not admitted
under a v2 deployment.  `…_implies_gasPoolPolicy` shows it only ever
NARROWS the admitted set (the gate can never widen pool outflow). -/

/-- The ENFORCED v2 admission predicate: the canonical ETH-leg claim,
    within cap, backed by a FRESH receipt (not previously consumed).  A
    deployment requires this for gas-pool claims; a receiptless v1 claim
    is rejected, and a receipt cannot be reused (`consumeReceipt_blocks_reuse`). -/
def receiptEnforcedClaimAdmissible
    (consumed : ConsumedReceipts) (maxDrainPerActionEth : Amount)
    (action : Action) : Prop :=
  ∃ amount,
    action = .transfer 0 gasPoolActor sequencerActor amount ∧
    amount ≤ maxDrainPerActionEth ∧
    Nonempty (SequencerReimbursementVerifiedFresh consumed amount)

/-- The enforced gate is strictly stronger than the base gate (it adds
    the freshness obligation), so it implies `receiptVerifiedClaimAdmissible`. -/
theorem receiptEnforcedClaimAdmissible_implies_base
    (consumed : ConsumedReceipts) (maxDrainPerActionEth : Amount) {action : Action}
    (h : receiptEnforcedClaimAdmissible consumed maxDrainPerActionEth action) :
    receiptVerifiedClaimAdmissible maxDrainPerActionEth action := by
  obtain ⟨amount, haction, hcap, ⟨wf⟩⟩ := h
  exact ⟨amount, haction, hcap, ⟨wf.backing⟩⟩

/-- The enforced gate only NARROWS pool outflow: every enforced-admissible
    claim is GP.7.2-admissible (it can never admit a claim `gasPoolPolicy`
    rejects). -/
theorem receiptEnforcedClaimAdmissible_implies_gasPoolPolicy
    (consumed : ConsumedReceipts)
    (maxDrainPerActionEth maxDrainPerActionBold : Amount) {action : Action}
    (h : receiptEnforcedClaimAdmissible consumed maxDrainPerActionEth action) :
    (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
      gasPoolActor action :=
  receiptVerifiedClaimAdmissible_implies_gasPoolPolicy
    maxDrainPerActionEth maxDrainPerActionBold
    (receiptEnforcedClaimAdmissible_implies_base consumed maxDrainPerActionEth h)

/-- **Enforced headline (capped, backed, AND fresh).**  An
    enforced-admissible claim is within the cap, backed wei-for-wei by an
    L1-attested expenditure, AND consumes a receipt that was not already
    spent — so a batch of enforced claims draws on DISTINCT receipts and
    the per-claim `min(cap, cost)` bound lifts to the batch. -/
theorem receiptEnforcedClaim_capped_backed_and_fresh
    (consumed : ConsumedReceipts) (maxDrainPerActionEth : Amount) {action : Action}
    (h : receiptEnforcedClaimAdmissible consumed maxDrainPerActionEth action) :
    ∃ amount rbh batchId gasUsed gasPrice,
      action = .transfer 0 gasPoolActor sequencerActor amount ∧
      amount ≤ maxDrainPerActionEth ∧
      l1GasReceiptVerifier rbh batchId gasUsed gasPrice = true ∧
      amount ≤ gasReceiptReimbursement gasUsed gasPrice ∧
      rbh ∉ consumed := by
  obtain ⟨amount, haction, hcap, ⟨wf⟩⟩ := h
  exact ⟨amount, wf.backing.receiptBindingHash, wf.backing.batchId,
         wf.backing.gasUsed, wf.backing.gasPrice, haction, hcap,
         wf.backing.l1_attestation, wf.backing.amount_backed, wf.fresh⟩

/-! ## The admission path that REQUIRES the gate (PR #126 review c4)

The theorems above characterise the enforced gate in isolation.
`receiptGatedAdmissible` is the concrete admission predicate that
*consumes* it: a v2-enabled deployment admits an action iff its base
admissibility holds AND — when the action is a gas-pool ETH-leg claim —
the enforced receipt gate holds.  It is parametric in the base
admissibility `Prop` (so it composes with whatever a deployment already
uses — `BridgeAdmissibleWith`, the GP.7.4 governance, …) and is a strict
narrowing: a receiptless v1 honour-system claim, base-admissible but
with no fresh receipt, is REJECTED, while non-claim actions defer
entirely to the base (so v1 deployments are unaffected). -/

/-- Is `action` the canonical ETH-leg gas-pool → sequencer claim? -/
def isGasPoolEthClaim (action : Action) : Prop :=
  ∃ amount, action = .transfer 0 gasPoolActor sequencerActor amount

/-- **Receipt-gated admission (the path that requires the gate).**  A
    v2 deployment admits `action` iff `baseAdmissible` holds AND, for a
    gas-pool ETH-leg claim, the enforced receipt gate
    (`receiptEnforcedClaimAdmissible`) holds.  Parametric in the base so
    it composes with any existing admission; for non-claim actions the
    gate conjunct is vacuous, so it equals the base. -/
def receiptGatedAdmissible
    (baseAdmissible : Prop) (consumed : ConsumedReceipts)
    (maxDrainPerActionEth : Amount) (action : Action) : Prop :=
  baseAdmissible ∧
    (isGasPoolEthClaim action →
      receiptEnforcedClaimAdmissible consumed maxDrainPerActionEth action)

/-- The composer only NARROWS: receipt-gated admission implies the base. -/
theorem receiptGatedAdmissible_implies_base
    {baseAdmissible : Prop} (consumed : ConsumedReceipts)
    (maxDrainPerActionEth : Amount) {action : Action}
    (h : receiptGatedAdmissible baseAdmissible consumed maxDrainPerActionEth action) :
    baseAdmissible := h.1

/-- **The gate is REQUIRED for every gas-pool claim.**  Under
    `receiptGatedAdmissible`, a gas-pool ETH-leg claim is admitted ONLY
    if the enforced receipt gate holds — so a v1 honour-system claim
    WITHOUT a fresh receipt cannot be admitted.  This is the formal
    closure of the "v2 gate is unenforced" gap: a deployment using this
    admission cannot accept the same gas-pool transfer without a receipt
    witness. -/
theorem receiptGatedAdmissible_requires_gate_for_claim
    {baseAdmissible : Prop} (consumed : ConsumedReceipts)
    (maxDrainPerActionEth : Amount) {action : Action}
    (hclaim : isGasPoolEthClaim action)
    (h : receiptGatedAdmissible baseAdmissible consumed maxDrainPerActionEth action) :
    receiptEnforcedClaimAdmissible consumed maxDrainPerActionEth action :=
  h.2 hclaim

/-- A non-claim action's receipt-gated admission is EXACTLY the base
    (the gate conjunct is vacuous), so enabling v2 does not restrict any
    non-gas-pool-claim action — v1 deployments are unaffected. -/
theorem receiptGatedAdmissible_eq_base_off_claim
    {baseAdmissible : Prop} (consumed : ConsumedReceipts)
    (maxDrainPerActionEth : Amount) {action : Action}
    (hnot : ¬ isGasPoolEthClaim action) :
    receiptGatedAdmissible baseAdmissible consumed maxDrainPerActionEth action ↔
      baseAdmissible := by
  unfold receiptGatedAdmissible
  exact ⟨fun h => h.1, fun h => ⟨h, fun hc => absurd hc hnot⟩⟩

/-- **No receipt reuse across admissions (PR #126 review c2).**  If a
    first claim was admitted and its receipt `rbh₁` consumed, then any
    SECOND enforced-admissible gas-pool claim (against the updated
    consumed set) is backed by a receipt `rbh₂ ≠ rbh₁`.  So one L1
    receipt backs at most one admitted reimbursement, and a batch of `n`
    admitted claims draws on `n` DISTINCT receipts — lifting the
    per-claim `min(cap, cost)` bound to the batch (a sequencer cannot
    present one receipt to drain `n ×` the spend). -/
theorem receiptEnforced_second_claim_distinct_receipt
    (consumed : ConsumedReceipts) (maxDrainPerActionEth : Amount)
    (rbh₁ : ByteArray) {action : Action}
    (h : receiptEnforcedClaimAdmissible (consumeReceipt consumed rbh₁)
          maxDrainPerActionEth action) :
    ∃ amount rbh₂ batchId gasUsed gasPrice,
      action = .transfer 0 gasPoolActor sequencerActor amount ∧
      l1GasReceiptVerifier rbh₂ batchId gasUsed gasPrice = true ∧
      amount ≤ gasReceiptReimbursement gasUsed gasPrice ∧
      rbh₂ ≠ rbh₁ := by
  obtain ⟨amount, rbh₂, batchId, gasUsed, gasPrice,
          haction, _hcap, hattest, hbound, hfresh⟩ :=
    receiptEnforcedClaim_capped_backed_and_fresh
      (consumeReceipt consumed rbh₁) maxDrainPerActionEth h
  refine ⟨amount, rbh₂, batchId, gasUsed, gasPrice, haction, hattest, hbound, ?_⟩
  intro heq
  exact hfresh (heq ▸ by simp [consumeReceipt])

/-! ## BOLD leg — the ETH→BOLD price oracle (OQ-GP-8b follow-on (a))

The ETH-leg gate above is *oracle-free*: the receipt attests a wei cost
(`gasUsed * gasPrice`) and the ETH leg (resource `0`) reimburses in wei,
so the bound is exact.  The BOLD leg (resource `1`) reimburses in BOLD
units, so backing a BOLD claim from a wei-denominated receipt needs the
ETH→BOLD exchange rate at the batch — a SECOND deployment-supplied trust
assumption (a price oracle).  This section ships it, mirroring the ETH
structure theorem-for-theorem, so the BOLD leg gains the same
`min(cap, verified cost)` double bound, narrowing, and no-reuse
guarantees — the only addition being the rate attestation.

**Conservatism.**  The conversion `gasUsed * gasPrice * rateNum / rateDen`
uses `Nat` floor division, so the BOLD bound is never larger than the
real-valued conversion at the attested rate — the sequencer can never be
reimbursed MORE BOLD than the wei cost justifies.  A zero denominator
yields `0` (Lean `_ / 0 = 0`), i.e. fail-closed: a malformed rate backs
nothing. -/

/-- Deployment-supplied ETH→BOLD price oracle.  Given a binding hash for
    the rate quotation, the batch id it applies to, and the rate as a
    rational `rateNum / rateDen` (BOLD base units per ETH wei), the
    deployment-side oracle confirms whether that rate is the attested
    ETH→BOLD price for the batch.  Returns `true` iff yes.

    `opaque` (not `axiom`): the SECOND trust assumption of this module,
    held to the same discipline as `l1GasReceiptVerifier` and
    `FaultProof.l1FaultProofVerifier` — it never appears in
    `#print axioms`, and until a deployment links the oracle the
    Lean-level value is unspecified, so no BOLD witness is constructible
    without an explicit attestation (fail-closed).  Like the gas
    verifier, the rate can be cross-checked across independent oracles. -/
opaque l1EthBoldRateOracle
    (rateBindingHash : ByteArray) (batchId : Nat)
    (rateNum rateDen : Nat) : Bool

/-- The maximum BOLD reimbursement a verified wei expenditure justifies at
    the attested rate: `⌊gasUsed * gasPrice * rateNum / rateDen⌋` (BOLD
    base units), the wei cost converted via `rateNum/rateDen` BOLD-per-wei
    and rounded DOWN.  Floor division makes this an upper bound that never
    exceeds the real-valued conversion; `rateDen = 0` yields `0`
    (fail-closed).  The BOLD analogue of `gasReceiptReimbursement`. -/
def boldReceiptReimbursement (gasUsed gasPrice rateNum rateDen : Nat) : Amount :=
  gasUsed * gasPrice * rateNum / rateDen

/-- A propositional witness that a sequencer reimbursement of `amount`
    BOLD base units is fully backed by an L1-verified gas expenditure
    converted at an attested ETH→BOLD rate.

    The witness exhibits a concrete L1 gas receipt AND a rate quotation,
    together with THREE obligations:
      * `gas_attestation`: the watcher confirmed a batch-publication
        receipt with exactly `(gasUsed, gasPrice)` (same `l1GasReceiptVerifier`
        as the ETH leg — the gas cost is wei regardless of leg);
      * `rate_attestation`: the oracle confirmed `rateNum/rateDen` is the
        ETH→BOLD price for that batch;
      * `amount_backed`: the claimed `amount` is within the converted
        wei cost (`boldReceiptReimbursement …`).

    Without this witness the BOLD gate is unenterable, so an unbacked
    BOLD over-claim is unconstructible — the BOLD analogue of
    `SequencerReimbursementVerified`. -/
structure SequencerReimbursementVerifiedBold (amount : Amount) where
  /-- The binding hash of the L1 batch-publication transaction receipt
      (the handle consumed by `ConsumedReceipts`; one batch receipt backs
      at most one reimbursement across BOTH legs). -/
  receiptBindingHash : ByteArray
  /-- The binding hash of the ETH→BOLD rate quotation. -/
  rateBindingHash : ByteArray
  /-- The L1 batch id this receipt settles (and the rate applies to). -/
  batchId : Nat
  /-- The gas units the L1 batch-publication transaction consumed. -/
  gasUsed : Nat
  /-- The effective gas price (wei per gas) of that transaction. -/
  gasPrice : Nat
  /-- The attested ETH→BOLD rate numerator (BOLD base units). -/
  rateNum : Nat
  /-- The attested ETH→BOLD rate denominator (ETH wei). -/
  rateDen : Nat
  /-- The L1 gas attestation (same opaque as the ETH leg). -/
  gas_attestation :
    l1GasReceiptVerifier receiptBindingHash batchId gasUsed gasPrice = true
  /-- The ETH→BOLD rate attestation (the new oracle). -/
  rate_attestation :
    l1EthBoldRateOracle rateBindingHash batchId rateNum rateDen = true
  /-- The reimbursement bound: the claimed BOLD `amount` does not exceed
      the converted wei cost the verified receipt + rate justify. -/
  amount_backed :
    amount ≤ boldReceiptReimbursement gasUsed gasPrice rateNum rateDen

/-- Construct a `SequencerReimbursementVerifiedBold` witness from a
    concrete receipt, a rate quotation, and the three discharged
    obligations.  The BOLD analogue of
    `SequencerReimbursementVerified.of_receipt`. -/
def SequencerReimbursementVerifiedBold.of_receipt
    (amount : Amount) (receiptBindingHash rateBindingHash : ByteArray)
    (batchId gasUsed gasPrice rateNum rateDen : Nat)
    (h_gas :
      l1GasReceiptVerifier receiptBindingHash batchId gasUsed gasPrice = true)
    (h_rate :
      l1EthBoldRateOracle rateBindingHash batchId rateNum rateDen = true)
    (h_backed :
      amount ≤ boldReceiptReimbursement gasUsed gasPrice rateNum rateDen) :
    SequencerReimbursementVerifiedBold amount where
  receiptBindingHash := receiptBindingHash
  rateBindingHash := rateBindingHash
  batchId := batchId
  gasUsed := gasUsed
  gasPrice := gasPrice
  rateNum := rateNum
  rateDen := rateDen
  gas_attestation := h_gas
  rate_attestation := h_rate
  amount_backed := h_backed

/-- **BOLD backing projection.**  A BOLD receipt witness for `amount`
    exhibits an L1-attested expenditure and an attested rate whose
    converted cost is at least `amount`.  The BOLD analogue of
    `sequencerReimbursementVerified_backed`. -/
theorem sequencerReimbursementVerifiedBold_backed
    {amount : Amount} (w : SequencerReimbursementVerifiedBold amount) :
    ∃ rbh rateBh batchId gasUsed gasPrice rateNum rateDen,
      l1GasReceiptVerifier rbh batchId gasUsed gasPrice = true ∧
      l1EthBoldRateOracle rateBh batchId rateNum rateDen = true ∧
      amount ≤ boldReceiptReimbursement gasUsed gasPrice rateNum rateDen :=
  ⟨w.receiptBindingHash, w.rateBindingHash, w.batchId, w.gasUsed, w.gasPrice,
   w.rateNum, w.rateDen, w.gas_attestation, w.rate_attestation, w.amount_backed⟩

/-- The v2 receipt-verified admission gate for a BOLD-leg
    sequencer-reimbursement claim.  Holds iff the action is the canonical
    capped `gasPoolActor → sequencerActor` transfer over resource `1` AND
    a BOLD receipt witness (gas + rate + bound) backs the claimed amount.
    The resource-1 analogue of `receiptVerifiedClaimAdmissible`. -/
def receiptVerifiedBoldClaimAdmissible
    (maxDrainPerActionBold : Amount) (action : Action) : Prop :=
  ∃ amount,
    action = .transfer 1 gasPoolActor sequencerActor amount ∧
    amount ≤ maxDrainPerActionBold ∧
    Nonempty (SequencerReimbursementVerifiedBold amount)

/-- **BOLD headline (v2 double bound).**  Every BOLD receipt-verified
    claim is BOTH within the GP.7.2 BOLD cap AND backed by an L1-attested
    expenditure converted at an attested ETH→BOLD rate — the effective
    bound is `min(cap, converted wei cost)`.  The BOLD analogue of
    `receiptVerifiedClaim_capped_and_backed`. -/
theorem receiptVerifiedBoldClaim_capped_and_backed
    (maxDrainPerActionBold : Amount) {action : Action}
    (h : receiptVerifiedBoldClaimAdmissible maxDrainPerActionBold action) :
    ∃ amount,
      action = .transfer 1 gasPoolActor sequencerActor amount ∧
      amount ≤ maxDrainPerActionBold ∧
      (∃ rbh rateBh batchId gasUsed gasPrice rateNum rateDen,
        l1GasReceiptVerifier rbh batchId gasUsed gasPrice = true ∧
        l1EthBoldRateOracle rateBh batchId rateNum rateDen = true ∧
        amount ≤ boldReceiptReimbursement gasUsed gasPrice rateNum rateDen) := by
  obtain ⟨amount, haction, hcap, hwit⟩ := h
  obtain ⟨w⟩ := hwit
  exact ⟨amount, haction, hcap, sequencerReimbursementVerifiedBold_backed w⟩

/-- **BOLD v2 is a pure strengthening of v1 (the narrowing direction).**
    Every BOLD receipt-verified claim is already permitted by the GP.7.2
    `gasPoolPolicy` (for any ETH cap).  So enabling the BOLD gate can only
    REJECT claims `gasPoolPolicy` would admit, never admit one it rejects.
    The BOLD analogue of `receiptVerifiedClaimAdmissible_implies_gasPoolPolicy`,
    discharged by `gasPoolPolicy_permits_sequencer_transfer_bold`. -/
theorem receiptVerifiedBoldClaimAdmissible_implies_gasPoolPolicy
    (maxDrainPerActionEth maxDrainPerActionBold : Amount) {action : Action}
    (h : receiptVerifiedBoldClaimAdmissible maxDrainPerActionBold action) :
    (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
      gasPoolActor action := by
  obtain ⟨amount, haction, hcap, _⟩ := h
  subst haction
  exact gasPoolPolicy_permits_sequencer_transfer_bold
    maxDrainPerActionEth maxDrainPerActionBold gasPoolActor amount hcap

/-- A BOLD-leg claim that consumes a **fresh** gas receipt.  The BOLD
    analogue of `SequencerReimbursementVerifiedFresh`: the gas receipt's
    binding hash is not already consumed, so one batch-publication receipt
    backs at most one reimbursement — across BOTH legs, since the consumed
    set is shared. -/
structure SequencerReimbursementVerifiedBoldFresh
    (consumed : ConsumedReceipts) (amount : Amount) where
  /-- The BOLD backing witness (gas + rate attestations + the bound). -/
  backing : SequencerReimbursementVerifiedBold amount
  /-- The gas receipt has NOT been consumed by a prior claim. -/
  fresh : backing.receiptBindingHash ∉ consumed

/-- **A consumed receipt can never back a fresh BOLD claim.**  The BOLD
    analogue of `consumeReceipt_blocks_reuse`. -/
theorem consumeReceipt_blocks_reuse_bold
    (consumed : ConsumedReceipts) (rbh : ByteArray) {amount : Amount}
    (w : SequencerReimbursementVerifiedBoldFresh (consumeReceipt consumed rbh) amount) :
    w.backing.receiptBindingHash ≠ rbh := by
  intro h
  apply w.fresh
  simp only [consumeReceipt, h, List.mem_cons, true_or]

/-- The ENFORCED BOLD-leg admission predicate: the canonical BOLD claim,
    within the BOLD cap, backed by a FRESH receipt.  The resource-1
    analogue of `receiptEnforcedClaimAdmissible`. -/
def receiptEnforcedBoldClaimAdmissible
    (consumed : ConsumedReceipts) (maxDrainPerActionBold : Amount)
    (action : Action) : Prop :=
  ∃ amount,
    action = .transfer 1 gasPoolActor sequencerActor amount ∧
    amount ≤ maxDrainPerActionBold ∧
    Nonempty (SequencerReimbursementVerifiedBoldFresh consumed amount)

/-- The enforced BOLD gate implies the base BOLD gate (it adds freshness). -/
theorem receiptEnforcedBoldClaimAdmissible_implies_base
    (consumed : ConsumedReceipts) (maxDrainPerActionBold : Amount) {action : Action}
    (h : receiptEnforcedBoldClaimAdmissible consumed maxDrainPerActionBold action) :
    receiptVerifiedBoldClaimAdmissible maxDrainPerActionBold action := by
  obtain ⟨amount, haction, hcap, ⟨wf⟩⟩ := h
  exact ⟨amount, haction, hcap, ⟨wf.backing⟩⟩

/-- The enforced BOLD gate only NARROWS pool outflow. -/
theorem receiptEnforcedBoldClaimAdmissible_implies_gasPoolPolicy
    (consumed : ConsumedReceipts)
    (maxDrainPerActionEth maxDrainPerActionBold : Amount) {action : Action}
    (h : receiptEnforcedBoldClaimAdmissible consumed maxDrainPerActionBold action) :
    (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
      gasPoolActor action :=
  receiptVerifiedBoldClaimAdmissible_implies_gasPoolPolicy
    maxDrainPerActionEth maxDrainPerActionBold
    (receiptEnforcedBoldClaimAdmissible_implies_base consumed maxDrainPerActionBold h)

/-- **Enforced BOLD headline (capped, backed, AND fresh).**  The BOLD
    analogue of `receiptEnforcedClaim_capped_backed_and_fresh`. -/
theorem receiptEnforcedBoldClaim_capped_backed_and_fresh
    (consumed : ConsumedReceipts) (maxDrainPerActionBold : Amount) {action : Action}
    (h : receiptEnforcedBoldClaimAdmissible consumed maxDrainPerActionBold action) :
    ∃ amount rbh rateBh batchId gasUsed gasPrice rateNum rateDen,
      action = .transfer 1 gasPoolActor sequencerActor amount ∧
      amount ≤ maxDrainPerActionBold ∧
      l1GasReceiptVerifier rbh batchId gasUsed gasPrice = true ∧
      l1EthBoldRateOracle rateBh batchId rateNum rateDen = true ∧
      amount ≤ boldReceiptReimbursement gasUsed gasPrice rateNum rateDen ∧
      rbh ∉ consumed := by
  obtain ⟨amount, haction, hcap, ⟨wf⟩⟩ := h
  exact ⟨amount, wf.backing.receiptBindingHash, wf.backing.rateBindingHash,
         wf.backing.batchId, wf.backing.gasUsed, wf.backing.gasPrice,
         wf.backing.rateNum, wf.backing.rateDen, haction, hcap,
         wf.backing.gas_attestation, wf.backing.rate_attestation,
         wf.backing.amount_backed, wf.fresh⟩

/-! ## Unified admission — gate BOTH legs (OQ-GP-8b closure)

`receiptGatedAdmissible` above gates only the ETH leg: under it a BOLD
gas-pool claim defers entirely to the base (ungated).  With the BOLD gate
shipped, `receiptGatedAdmissibleUnified` is the COMPLETE composer — it
requires the ETH gate for an ETH-leg claim AND the BOLD gate for a
BOLD-leg claim, so a v2 deployment receipt-gates EVERY gas-pool → sequencer
claim regardless of leg.  This is the admission-level closure of
OQ-GP-8b. -/

/-- Is `action` the canonical BOLD-leg (resource `1`) gas-pool → sequencer
    claim?  The resource-1 analogue of `isGasPoolEthClaim`. -/
def isGasPoolBoldClaim (action : Action) : Prop :=
  ∃ amount, action = .transfer 1 gasPoolActor sequencerActor amount

/-- Is `action` a canonical gas-pool → sequencer reimbursement claim on
    EITHER leg (ETH resource `0` or BOLD resource `1`)? -/
def isGasPoolClaim (action : Action) : Prop :=
  isGasPoolEthClaim action ∨ isGasPoolBoldClaim action

/-- **Unified receipt-gated admission.**  A v2 deployment admits `action`
    iff `baseAdmissible` holds AND each leg's enforced receipt gate holds
    for the matching claim shape.  For non-claim actions both conjuncts are
    vacuous, so it equals the base; for a gas-pool claim the matching leg's
    gate is REQUIRED.  The complete (both-leg) analogue of
    `receiptGatedAdmissible`. -/
def receiptGatedAdmissibleUnified
    (baseAdmissible : Prop) (consumed : ConsumedReceipts)
    (maxDrainPerActionEth maxDrainPerActionBold : Amount) (action : Action) : Prop :=
  baseAdmissible ∧
    (isGasPoolEthClaim action →
      receiptEnforcedClaimAdmissible consumed maxDrainPerActionEth action) ∧
    (isGasPoolBoldClaim action →
      receiptEnforcedBoldClaimAdmissible consumed maxDrainPerActionBold action)

/-- The unified composer only NARROWS: it implies the base. -/
theorem receiptGatedAdmissibleUnified_implies_base
    {baseAdmissible : Prop} (consumed : ConsumedReceipts)
    (maxDrainPerActionEth maxDrainPerActionBold : Amount) {action : Action}
    (h : receiptGatedAdmissibleUnified baseAdmissible consumed
          maxDrainPerActionEth maxDrainPerActionBold action) :
    baseAdmissible := h.1

/-- **The ETH gate is REQUIRED for an ETH-leg claim** under the unified
    composer (the BOLD analogue follows). -/
theorem receiptGatedAdmissibleUnified_requires_eth_gate
    {baseAdmissible : Prop} (consumed : ConsumedReceipts)
    (maxDrainPerActionEth maxDrainPerActionBold : Amount) {action : Action}
    (hclaim : isGasPoolEthClaim action)
    (h : receiptGatedAdmissibleUnified baseAdmissible consumed
          maxDrainPerActionEth maxDrainPerActionBold action) :
    receiptEnforcedClaimAdmissible consumed maxDrainPerActionEth action :=
  h.2.1 hclaim

/-- **The BOLD gate is REQUIRED for a BOLD-leg claim** under the unified
    composer — closing the "BOLD claims slip through ungated" gap that the
    ETH-only `receiptGatedAdmissible` left open. -/
theorem receiptGatedAdmissibleUnified_requires_bold_gate
    {baseAdmissible : Prop} (consumed : ConsumedReceipts)
    (maxDrainPerActionEth maxDrainPerActionBold : Amount) {action : Action}
    (hclaim : isGasPoolBoldClaim action)
    (h : receiptGatedAdmissibleUnified baseAdmissible consumed
          maxDrainPerActionEth maxDrainPerActionBold action) :
    receiptEnforcedBoldClaimAdmissible consumed maxDrainPerActionBold action :=
  h.2.2 hclaim

/-- A non-claim action's unified admission is EXACTLY the base (both gate
    conjuncts are vacuous), so enabling the unified v2 gate restricts only
    gas-pool claims — v1 deployments are unaffected. -/
theorem receiptGatedAdmissibleUnified_eq_base_off_claim
    {baseAdmissible : Prop} (consumed : ConsumedReceipts)
    (maxDrainPerActionEth maxDrainPerActionBold : Amount) {action : Action}
    (hnot : ¬ isGasPoolClaim action) :
    receiptGatedAdmissibleUnified baseAdmissible consumed
        maxDrainPerActionEth maxDrainPerActionBold action ↔ baseAdmissible := by
  unfold receiptGatedAdmissibleUnified isGasPoolClaim at *
  refine ⟨fun h => h.1, fun h => ⟨h, ?_, ?_⟩⟩
  · exact fun hc => absurd (Or.inl hc) hnot
  · exact fun hc => absurd (Or.inr hc) hnot

end Bridge
end LegalKernel

-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.BudgetRefund — Workstream GP.9.1 test suite.

Exercises the refund-on-exit kernel leg (`LegalKernel/Laws/ClaimBudgetRefund.lean`)
and its accounting layer (`LegalKernel/Bridge/BudgetRefund.lean`).  Coverage:

  * **Refundable-budget functional.**  The free-tier-and-cost
    exclusion (`89 = 100 − (1 + 10)`), the at-free-tier zero, and the
    below-reserves zero (the anti-drain guarantee).
  * **Round-trip non-profitability.**  `refundAmount (poolAmount / rate)
    rate ≤ poolAmount` on a concrete indivisible split (the residue
    stays in the pool).
  * **Kernel leg.**  Pool debit + claimant credit + per-resource
    conservation + the insolvent-pool no-op + other-actor / other-
    resource non-interference.
  * **Budget ledger.**  A concrete refund consume leaving the claimant
    at exactly the free tier; the strict `currentBudget` decrease
    (no-double-refund); refund locality on a second actor.
  * **Law ↔ ledger composite.**  `refund_pays_exact_amount_from_pool`
    at the canonical `gasPoolActor`.
  * **Term-level API stability** for every headline theorem + the law /
    accounting functionals.
-/

import LegalKernel.Bridge.BudgetRefund
import LegalKernel.Authority.SignedAction
import LegalKernel.Bridge.Admissible
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Bridge
namespace BudgetRefundTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Events
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

/-! ## Fixtures -/

/-- A regular (non-reserved) user actor — the refund claimant. -/
def claimant : ActorId := 5

/-- A second user actor, for the locality checks. -/
def other : ActorId := 6

/-- The ETH-mirror gas resource (resource 0). -/
def gasResource : ResourceId := 0

/-- A representative epoch and free tier / action cost. -/
def now : Nat := 0
/-- A representative per-epoch free-tier allowance. -/
def freeTier : Nat := 10
/-- The per-action budget cost. -/
def actionCost : Nat := 1

/-- A claimant budget ledger: 100 action-budget units at epoch 0. -/
def ledger : EpochBudgetState :=
  EpochBudgetState.empty.topUp claimant now 0 100

/-- A state in which the gas pool holds 5000 ETH and the claimant 100. -/
def fundedPool : State :=
  setBalance (setBalance genesisState gasResource gasPoolActor 5000) gasResource claimant 100

/-- A state in which the gas pool is underfunded (holds only 100). -/
def emptyPool : State :=
  setBalance (setBalance genesisState gasResource gasPoolActor 100) gasResource claimant 50

/-- The deployment's trusted refund rate: `1` wei per budget unit on
    the ETH leg, `0` (refunds disabled) elsewhere. -/
def trustedRate : ResourceId → Nat := fun r => if r = 0 then 1 else 0

/-- The genesis budget policy used by the admission-gate fixtures:
    free tier `10`, action cost `1`, epoch `0` — so an actor with
    `currentBudget = 100` has `refundableBudget = 100 − (1 + 10) = 89`. -/
def policy : BudgetPolicy := .bounded freeTier actionCost 0

/-- A funded `ExtendedState`: pool (`gasPoolActor`) holds 5000 ETH,
    claimant holds 100 ETH and 100 budget units, under `policy`. -/
def es : ExtendedState :=
  { base := fundedPool
  , nonces := NonceState.empty
  , registry := KeyRegistry.empty
  , epochBudgets := ledger
  , budgetPolicy := policy }

/-- The test deployment id. -/
def deploymentId : ByteArray := ByteArray.mk #[0x9A, 0x50]

/-- An ACTIVE refund rate: 5 wei per budget unit on the ETH leg
    (resource 0), 0 (disabled) elsewhere. -/
def refundRateActive : ResourceId → Nat := fun r => if r = 0 then 5 else 0

/-- The end-to-end admission fixture: like `es`, but with the claimant
    REGISTERED (so `AdmissibleWith` holds and a signed refund can be
    admitted through the production-style gate). -/
def esAdmit : ExtendedState :=
  { base := fundedPool
  , nonces := NonceState.empty
  , registry := KeyRegistry.empty.register claimant (mockPubKey claimant.toNat)
  , epochBudgets := ledger
  , budgetPolicy := policy }

/-- Build a mock-signed `SignedAction` for `action` by `signer` at
    `esAdmit`. -/
def mkSigned (action : Action) (signer : ActorId) : SignedAction :=
  let nonce := expectsNonce esAdmit signer
  let msg := signingInput action signer nonce deploymentId
  ⟨action, signer, nonce, mockSign (mockPubKey signer.toNat) msg⟩

/-! ## Tests -/

/-- GP.9.1 test cases. -/
def tests : List TestCase :=
  [ -- ## Refundable-budget functional (free-tier + cost exclusion)
    { name := "refundableBudget excludes the free tier and the action cost"
    , body := do
        -- currentBudget = 100; reserves = actionCost (1) + freeTier (10) = 11.
        assertEq (expected := (100 : Nat))
          (actual := ledger.currentBudget claimant now freeTier) "currentBudget"
        assertEq (expected := (89 : Nat))
          (actual := refundableBudget ledger claimant now freeTier actionCost)
          "refundableBudget = 100 - 11"
    }
  , { name := "refundableBudget is zero at the free tier (anti-drain)"
    , body := do
        -- An actor sitting at exactly the free tier has nothing
        -- purchased to refund: free-tier subsidy never leaks.
        let atFree : EpochBudgetState := EpochBudgetState.empty.topUp claimant now 0 10
        assertEq (expected := (10 : Nat))
          (actual := atFree.currentBudget claimant now freeTier) "at free tier"
        assertEq (expected := (0 : Nat))
          (actual := refundableBudget atFree claimant now freeTier actionCost)
          "refundableBudget = 0 at free tier"
    }
  , { name := "refundableBudget is zero below the reserves"
    , body := do
        let belowReserves : EpochBudgetState := EpochBudgetState.empty.topUp claimant now 0 5
        assertEq (expected := (0 : Nat))
          (actual := refundableBudget belowReserves claimant now freeTier actionCost)
          "refundableBudget = 0 below reserves"
    }
  , -- ## Round-trip non-profitability (floor division)
    { name := "refundAmount of a deposit grant never exceeds the fee"
    , body := do
        -- A deposit of poolAmount = 1_000_000 at rate 7 grants
        -- 1_000_000 / 7 = 142_857 budget units.  Refunding all of them
        -- pays 142_857 * 7 = 999_999 ≤ 1_000_000 — the residue (1) stays
        -- in the pool, so the round trip is strictly lossy.
        let poolAmount : Nat := 1000000
        let rate : Nat := 7
        let grant := poolAmount / rate
        assertEq (expected := (142857 : Nat)) (actual := grant) "floor-division grant"
        assertEq (expected := (999999 : Nat)) (actual := refundAmount grant rate)
          "refundAmount of the grant"
        assert (decide (refundAmount grant rate ≤ poolAmount)) "refund ≤ fee paid"
    }
  , -- ## Kernel leg: balance deltas + conservation
    { name := "refund credits the claimant and debits the pool by refundAmount"
    , body := do
        let s' := step_impl fundedPool (Laws.claimBudgetRefund claimant gasPoolActor gasResource 300)
        assertEq (expected := (400 : Nat)) (actual := getBalance s' gasResource claimant)
          "claimant credited 100 + 300"
        assertEq (expected := (4700 : Nat)) (actual := getBalance s' gasResource gasPoolActor)
          "pool debited 5000 - 300"
    }
  , { name := "refund conserves per-resource total supply"
    , body := do
        let s' := step_impl fundedPool (Laws.claimBudgetRefund claimant gasPoolActor gasResource 300)
        assertEq (expected := TotalSupply fundedPool gasResource)
          (actual := TotalSupply s' gasResource) "supply conserved"
    }
  , { name := "refund against an insolvent pool is a no-op"
    , body := do
        -- Pool holds only 100; a 300-unit refund fails the precondition,
        -- so `step_impl` leaves the state untouched (no silent under-credit).
        let s' := step_impl emptyPool (Laws.claimBudgetRefund claimant gasPoolActor gasResource 300)
        assertEq (expected := getBalance emptyPool gasResource claimant)
          (actual := getBalance s' gasResource claimant) "claimant unchanged"
        assertEq (expected := getBalance emptyPool gasResource gasPoolActor)
          (actual := getBalance s' gasResource gasPoolActor) "pool unchanged"
    }
  , { name := "refund leaves other actors and other resources untouched"
    , body := do
        let s := setBalance fundedPool gasResource other 777
        let s2 := setBalance s 1 claimant 999  -- a BOLD-leg balance
        let s' := step_impl s2 (Laws.claimBudgetRefund claimant gasPoolActor gasResource 300)
        assertEq (expected := (777 : Nat)) (actual := getBalance s' gasResource other)
          "other actor untouched"
        assertEq (expected := (999 : Nat)) (actual := getBalance s' 1 claimant)
          "other resource untouched"
    }
  , -- ## Budget ledger: post-refund state
    { name := "a refund consume leaves the claimant at exactly the free tier"
    , body := do
        -- budgetUnits = 89 = refundableBudget; consume 1 + 89 = 90 from 100
        -- leaves 10 = freeTier.
        match EpochBudgetState.consume ledger claimant now freeTier (actionCost + 89) with
        | some ebs' =>
            assertEq (expected := (10 : Nat))
              (actual := ebs'.currentBudget claimant now freeTier)
              "post-refund budget = free tier"
        | none => assert false "refund consume should succeed"
    }
  , { name := "a refund strictly lowers the claimant budget (no double refund)"
    , body := do
        match EpochBudgetState.consume ledger claimant now freeTier (actionCost + 89) with
        | some ebs' =>
            assert (decide (ebs'.currentBudget claimant now freeTier <
              ledger.currentBudget claimant now freeTier)) "budget strictly decreased"
        | none => assert false "refund consume should succeed"
    }
  , { name := "a refund consume leaves another actor's budget untouched"
    , body := do
        let ledger2 := ledger.topUp other now 0 50
        match EpochBudgetState.consume ledger2 claimant now freeTier (actionCost + 89) with
        | some ebs' =>
            assertEq (expected := ledger2.currentBudget other now freeTier)
              (actual := ebs'.currentBudget other now freeTier) "other budget untouched"
        | none => assert false "refund consume should succeed"
    }
  , -- ## Admission gate (the seven safety conjuncts)
    { name := "refund gate ACCEPTS a valid refund (all seven conjuncts hold)"
    , body := do
        -- claimant 5 (≠ bridge 0, ≠ pool 1), pool = gasPoolActor (1),
        -- rate 1 = trustedRate 0, 1 ≤ 89 ≤ refundableBudget (89),
        -- pool 5000 ≥ 89 × 1.
        assert (claimBudgetRefund_gate (.claimBudgetRefund gasResource 89 1 gasPoolActor)
          claimant es trustedRate) "valid refund admitted by gate"
    }
  , { name := "refund gate REJECTS a non-canonical pool (victim-drain pin)"
    , body := do
        -- poolActor = 2 ≠ gasPoolActor (1).
        assert (! claimBudgetRefund_gate (.claimBudgetRefund gasResource 89 1 2)
          claimant es trustedRate) "non-canonical pool rejected"
    }
  , { name := "refund gate REJECTS a rate mismatch (rate pin)"
    , body := do
        -- weiPerBudgetUnit = 2 ≠ trustedRate 0 (= 1).
        assert (! claimBudgetRefund_gate (.claimBudgetRefund gasResource 89 2 gasPoolActor)
          claimant es trustedRate) "inflated rate rejected"
    }
  , { name := "refund gate REJECTS over-refundable budget (free-tier bound)"
    , body := do
        -- 90 > refundableBudget (89): would dip into the free tier.
        assert (! claimBudgetRefund_gate (.claimBudgetRefund gasResource 90 1 gasPoolActor)
          claimant es trustedRate) "over-refundable rejected"
    }
  , { name := "refund gate REJECTS an insolvent pool"
    , body := do
        -- Pool holds only 100; a refund of 89 × 2 = 178 > 100.
        let esThin : ExtendedState :=
          { base := emptyPool
          , nonces := NonceState.empty
          , registry := KeyRegistry.empty
          , epochBudgets := ledger
          , budgetPolicy := BudgetPolicy.bounded freeTier actionCost 0 }
        -- rate must match for the solvency conjunct to be the binding one;
        -- use a 2-wei rate (and a matching refundRate) so 89 × 2 = 178 > 100.
        assert (! claimBudgetRefund_gate (.claimBudgetRefund gasResource 89 2 gasPoolActor)
          claimant esThin (fun r => if r = 0 then 2 else 0)) "insolvent pool rejected"
    }
  , { name := "refund gate REJECTS a zero-unit refund and a bridge / self-pool signer"
    , body := do
        assert (! claimBudgetRefund_gate (.claimBudgetRefund gasResource 0 1 gasPoolActor)
          claimant es trustedRate) "zero-unit refund rejected"
        assert (! claimBudgetRefund_gate (.claimBudgetRefund gasResource 89 1 gasPoolActor)
          Bridge.bridgeActor es trustedRate) "bridge-actor signer rejected"
        assert (! claimBudgetRefund_gate (.claimBudgetRefund gasResource 89 1 gasPoolActor)
          gasPoolActor es trustedRate) "self-pool signer rejected"
    }
  , { name := "refundConsumeExtra is budgetUnits for a refund, 0 otherwise"
    , body := do
        assertEq (expected := (89 : Nat))
          (actual := refundConsumeExtra (.claimBudgetRefund gasResource 89 1 gasPoolActor))
          "refund extra = budgetUnits"
        assertEq (expected := (0 : Nat))
          (actual := refundConsumeExtra (.transfer 0 5 6 10)) "non-refund extra = 0"
    }
  , { name := "refund gate REJECTS a rate-0 (disabled) resource — refunds genuinely off"
    , body := do
        -- Under the default `refundRate = fun _ => 0`, the rate pin
        -- forces weiPerBudgetUnit = 0, but the refund-enabled conjunct
        -- requires ≥ 1 — so the refund is REJECTED, not admitted as a
        -- budget-burning zero-payout no-op.
        assert (! claimBudgetRefund_gate (.claimBudgetRefund gasResource 89 0 gasPoolActor)
          claimant es (fun _ => 0)) "rate-0 refund rejected (not budget-burned)"
        -- A BOLD-leg refund under an ETH-only active rate (BOLD rate 0).
        assert (! claimBudgetRefund_gate (.claimBudgetRefund 1 89 0 gasPoolActor)
          claimant es refundRateActive) "BOLD-leg refund rejected when BOLD rate is 0"
    }
  , -- ## End-to-end admission (the production-style gate, mock-signed)
    { name := "END-TO-END: a signed refund is admitted, pays the claimant, retires the budget"
    , body := do
        let action : Action := .claimBudgetRefund gasResource 89 5 gasPoolActor
        let st := mkSigned action claimant
        match (inferInstance :
            Decidable (AdmissibleWith mockVerify AuthorityPolicy.unrestricted deploymentId
              esAdmit st)) with
        | .isTrue h =>
            match apply_admissible_with_budget mockVerify AuthorityPolicy.unrestricted
                    deploymentId esAdmit st h refundRateActive with
            | some es' =>
                -- payout = budgetUnits × rate = 89 × 5 = 445.
                assertEq (expected := (100 + 445 : Nat))
                  (actual := getBalance es'.base gasResource claimant)
                  "claimant credited 89 × 5"
                assertEq (expected := (5000 - 445 : Nat))
                  (actual := getBalance es'.base gasResource gasPoolActor)
                  "pool debited 89 × 5"
                -- budget = 100 − (actionCost 1 + budgetUnits 89) = 10 = freeTier.
                assertEq (expected := (10 : Nat))
                  (actual := es'.epochBudgets.currentBudget claimant now freeTier)
                  "budget retired down to the free tier (anti-drain preserved)"
            | none => assert false "refund should be admitted under the active rate"
        | .isFalse _ =>
            assert false "AdmissibleWith should hold (claimant registered + signed)"
    }
  , { name := "END-TO-END: the SAME refund is REJECTED under the default (disabled) rate"
    , body := do
        let action : Action := .claimBudgetRefund gasResource 89 5 gasPoolActor
        let st := mkSigned action claimant
        match (inferInstance :
            Decidable (AdmissibleWith mockVerify AuthorityPolicy.unrestricted deploymentId
              esAdmit st)) with
        | .isTrue h =>
            -- Same base-admissible action, but `refundRate = fun _ => 0`
            -- ⇒ rate pin forces weiPerBudgetUnit = 5 ≠ 0 ⇒ gate rejects;
            -- the budget is NOT consumed (admission returns none).
            match apply_admissible_with_budget mockVerify AuthorityPolicy.unrestricted
                    deploymentId esAdmit st h (fun _ => 0) with
            | some _ => assert false "refund must be rejected when refunds are disabled"
            | none => pure ()
        | .isFalse _ => assert false "AdmissibleWith should hold (claimant registered + signed)"
    }
  , { name := "END-TO-END: a refund emits claimant-credit + pool-debit + widened budgetConsumed"
    , body := do
        let action : Action := .claimBudgetRefund gasResource 89 5 gasPoolActor
        let st := mkSigned action claimant
        match (inferInstance :
            Decidable (AdmissibleWith mockVerify AuthorityPolicy.unrestricted deploymentId
              esAdmit st)) with
        | .isTrue h =>
            match apply_admissible_with_budget mockVerify AuthorityPolicy.unrestricted
                    deploymentId esAdmit st h refundRateActive with
            | some es' =>
                let events := extractEvents esAdmit es' st
                assert (decide (Event.balanceChanged gasResource claimant 100 545 ∈ events))
                  "claimant gas-credit event (100 → 545)"
                assert (decide (Event.balanceChanged gasResource gasPoolActor 5000 4555 ∈ events))
                  "pool gas-debit event (5000 → 4555)"
                -- the budgetConsumed amount is the WIDENED actionCost + budgetUnits = 1 + 89.
                assert (decide (Event.budgetConsumed claimant 90 ∈ events))
                  "widened budgetConsumed event (actionCost + budgetUnits)"
            | none => assert false "refund should be admitted under the active rate"
        | .isFalse _ => assert false "AdmissibleWith should hold (claimant registered + signed)"
    }
  , -- ## End-to-end admission on the PRODUCTION (bridge-aware) path.
    -- The runtime (`Runtime/Loop.lean`, `Runtime/Replay.lean`) admits via
    -- `apply_bridge_admissible_with_budget … rs.refundRate`, NOT the
    -- kernel-only gate above.  These two cases value-check the literal
    -- production entry at a NONZERO rate (the only configuration in which
    -- refunds function) and at the disabled default — the empirical
    -- counterpart to `admission_refund_{consumes_budget,preserves_free_tier}_bridge`.
    { name := "END-TO-END (bridge path): a signed refund is admitted, pays the claimant, retires the budget"
    , body := do
        let action : Action := .claimBudgetRefund gasResource 89 5 gasPoolActor
        let st := mkSigned action claimant
        match (inferInstance :
            Decidable (BridgeAdmissibleWith mockVerify AuthorityPolicy.unrestricted deploymentId
              esAdmit st)) with
        | .isTrue hb =>
            match apply_bridge_admissible_with_budget mockVerify AuthorityPolicy.unrestricted
                    deploymentId esAdmit st 0 hb refundRateActive with
            | some es' =>
                assertEq (expected := (100 + 445 : Nat))
                  (actual := getBalance es'.base gasResource claimant)
                  "claimant credited 89 × 5 (production path)"
                assertEq (expected := (5000 - 445 : Nat))
                  (actual := getBalance es'.base gasResource gasPoolActor)
                  "pool debited 89 × 5 (production path)"
                assertEq (expected := (10 : Nat))
                  (actual := es'.epochBudgets.currentBudget claimant now freeTier)
                  "budget retired to the free tier on the production path (anti-drain)"
            | none => assert false "bridge refund should be admitted under the active rate"
        | .isFalse _ =>
            assert false "BridgeAdmissibleWith should hold (refund is not bridge-only; claimant registered)"
    }
  , { name := "END-TO-END (bridge path): the SAME refund is REJECTED under the default (disabled) rate"
    , body := do
        let action : Action := .claimBudgetRefund gasResource 89 5 gasPoolActor
        let st := mkSigned action claimant
        match (inferInstance :
            Decidable (BridgeAdmissibleWith mockVerify AuthorityPolicy.unrestricted deploymentId
              esAdmit st)) with
        | .isTrue hb =>
            match apply_bridge_admissible_with_budget mockVerify AuthorityPolicy.unrestricted
                    deploymentId esAdmit st 0 hb (fun _ => 0) with
            | some _ => assert false "bridge refund must be rejected when refunds are disabled"
            | none => pure ()
        | .isFalse _ =>
            assert false "BridgeAdmissibleWith should hold (refund is not bridge-only; claimant registered)"
    }
  , -- ## Term-level API stability
    { name := "GP.9.1: term-level API stability (law + accounting)"
    , body := do
        -- Kernel leg.
        let _l0 := @Laws.claimBudgetRefund
        let _l1 := @Laws.claimBudgetRefund_apply_eq_transfer
        let _l2 := @Laws.claimBudgetRefund_conserves
        let _l3 := @Laws.claimBudgetRefund_other_resource_untouched
        let _l4 := @Laws.claimBudgetRefund_does_not_touch_other_resources
        let _l5 := @Laws.claimBudgetRefund_conserves_other_resource
        let _l6 := @Laws.claimBudgetRefund_pool_debited
        let _l7 := @Laws.claimBudgetRefund_claimant_credited
        let _l8 := @Laws.claimBudgetRefund_other_actor_untouched
        let _l9 := @Laws.claimBudgetRefund_isConservative
        let _l10 := @Laws.claimBudgetRefund_isMonotonic
        let _l11 := @Laws.claimBudgetRefund_localTo
        let _l12 := @Laws.claimBudgetRefund_freezePreserving
        -- Accounting layer.
        let _a0 := @refundableBudget
        let _a1 := @refundAmount
        let _a2 := @refundableBudget_le_currentBudget
        let _a3 := @refundableBudget_eq_zero_of_le_reserves
        let _a4 := @refundableBudget_eq_zero_at_free_tier
        let _a5 := @sufficient_of_refundableBudget_pos
        let _a6 := @refund_consume_succeeds
        let _a7 := @currentBudget_after_refund_consume
        let _a8 := @currentBudget_after_refund_ge_free_tier
        let _a9 := @currentBudget_after_refund_lt
        let _a10 := @currentBudget_after_refund_other
        let _a11 := @refundAmount_le_of_budgetUnits_le
        let _a12 := @refundAmount_le_deposit_fee
        let _a13 := @refundAmount_le_max
        let _a14 := @refund_pre_iff_pool_solvent
        let _a15 := @refund_pays_exact_amount_from_pool
        let _a16 := @refund_conserves_supply
        let _a17 := @refund_other_actor_untouched
        pure ()
    }
  , { name := "GP.9.1: term-level API stability (Action layer + admission gate)"
    , body := do
        -- Signable-action wiring.
        let _t0 := @Authority.Action.toTransition_claimBudgetRefund
        let _t1 := @Authority.claimBudgetRefund_gate
        let _t2 := @Authority.refundConsumeExtra
        let _t3 := @Authority.refundConsumeExtra_eq_zero_of_ne_refund
        let _t4 := @Authority.claimBudgetRefund_gate_true_of_ne
        -- Admission-gate soundness theorems (kernel).
        let _t5 := @Authority.claimBudgetRefund_gate_characterization
        let _t6 := @Authority.admission_refund_consumes_budget
        let _t7 := @Authority.admission_refund_preserves_free_tier
        let _t8 := @Authority.refund_rejected_when_pool_not_canonical
        let _t9 := @Authority.refund_rejected_when_rate_mismatch
        let _t10 := @Authority.refund_rejected_when_over_refundable
        let _t11 := @Authority.refund_rejected_when_pool_insolvent
        let _t11b := @Authority.refund_rejected_when_rate_disabled
        -- Production-path (bridge-aware) admission mirrors.  The two
        -- refund-specific mirrors close the GP.9.1 soundness gap: the
        -- runtime entry's refund consume + free-tier preservation are
        -- proven for an ARBITRARY deployment `refundRate`, not only the
        -- disabled default.
        let _t12 := @admission_consumes_budget_on_success_bridge
        let _t13 := @admission_refund_consumes_budget_bridge
        let _t14 := @admission_refund_preserves_free_tier_bridge
        -- The four rate-generic agreement corollaries the mirrors rest on
        -- now thread `refundRate` (the S1 generalisation).
        let _t15 := @apply_bridge_admissible_with_budget_epochBudgets_eq
        let _t16 := @apply_bridge_admissible_with_budget_none_iff
        let _t17 := @apply_bridge_admissible_with_budget_kernel_epochBudgets
        pure ()
    }
  ]

end BudgetRefundTests
end LegalKernel.Test.Bridge

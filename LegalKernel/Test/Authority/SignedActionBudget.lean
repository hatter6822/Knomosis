/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Authority.SignedActionBudget — Workstream GP §15E
(v1.0) GP.3.2 admission-gate test suite.

Pins the value-level behaviour of `apply_admissible_with_budget`
across all 11 GP.3.2 theorems:

  * `admission_consumes_budget_on_success`
  * `admission_rejected_when_budget_zero`
  * `bridgeActor_budget_exempt`
  * `depositWithFee_grants_budget`
  * `depositWithFee_budget_locality`
  * `topUpActionBudget_net_budget_change`
  * `admission_locality_in_budget`
  * `replenishment_via_epoch_advance`
  * `nonce_uniqueness_preserved`
  * `replay_impossible_preserved`

Plus term-level API stability checks ensuring the theorem
signatures survive future refactors.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Authority
namespace SignedActionBudget

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

/-! ## Test fixtures -/

/-- Test deployment id (non-empty so cross-deployment-replay tests
    are meaningful). -/
def testDeploymentId : ByteArray :=
  ByteArray.mk #[0xCA, 0xFE, 0xBA, 0xBE]

/-- Unrestricted authority policy (every signer authorised for
    every action). -/
def policy : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- Build an ExtendedState with two registered actors (10, 20) and
    a bounded budget policy `(freeTier, actionCost, currentEpoch)`.
    Actor 10 holds 100 at resource 1; actor 20 holds 50. -/
def mkExtendedState (freeTier actionCost currentEpoch : Nat) : ExtendedState :=
  let base : State := setBalance (setBalance emptyState 1 10 100) 1 20 50
  let registry := (KeyRegistry.empty.register 10 (mockPubKey 10)).register 20 (mockPubKey 20)
  { base := base
  , nonces := NonceState.empty
  , registry := registry
  , budgetPolicy := .bounded freeTier actionCost currentEpoch }

/-- Build a mockSign-valid SignedAction with the given action and
    signer (whose nonce is `expectsNonce es signer`).  Re-builds
    the SignedAction's nonce field from the live state. -/
def mkSignedAction (action : Action) (signer : ActorId) (es : ExtendedState) :
    SignedAction :=
  let nonce := expectsNonce es signer
  let msg := signingInput action signer nonce testDeploymentId
  let sig := mockSign (mockPubKey signer.toNat) msg
  ⟨action, signer, nonce, sig⟩

/-! ## GP.3.2.e — admission_consumes_budget_on_success

The signer's currentBudget after a successful admission of a
non-deposit-non-topup action is exactly `previous - actionCost`. -/

/-- Single non-deposit non-topup action consumes exactly `actionCost` budget. -/
def admissionConsumesBudget : TestCase := {
  name := "GP.3.2.e: admission_consumes_budget_on_success (transfer)"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    let st := mkSignedAction (.transfer 1 10 20 30) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        let preBudget := EpochBudgetState.currentBudget es.epochBudgets 10 1 5
        let postBudget := EpochBudgetState.currentBudget es'.epochBudgets 10 1 5
        assertEq (expected := preBudget - 1) (actual := postBudget) "budget reduced by 1"
      | none => throw <| IO.userError "admission unexpectedly failed"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected a should-be-admissible transfer"
}

/-! ## GP.3.2.f — admission_rejected_when_budget_zero

A non-bridge actor with `currentBudget < actionCost` is rejected
at the budget gate. -/

/-- With freeTier=0 (and lastSeenEpoch=0=currentEpoch), the actor's
    budget is 0; any action with actionCost > 0 is rejected. -/
def admissionRejectedWhenBudgetZero : TestCase := {
  name := "GP.3.2.f: admission_rejected_when_budget_zero"
  body := do
    -- freeTier=0, actionCost=1, currentEpoch=0: budget stays at 0.
    let es := mkExtendedState (freeTier := 0) (actionCost := 1) (currentEpoch := 0)
    let st := mkSignedAction (.transfer 1 10 20 30) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | none => pure ()  -- expected
      | some _ => throw <| IO.userError "admission unexpectedly succeeded despite zero budget"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the should-be-admissible transfer"
}

/-! ## GP.3.2.g — bridgeActor_budget_exempt

Every bridgeActor-signed action leaves bridgeActor's own budget
slot unchanged. -/

/-- A bridgeActor-signed registerIdentity action doesn't consume
    bridgeActor's budget (even if bridgeActor's slot was populated). -/
def bridgeActorBudgetExempt : TestCase := {
  name := "GP.3.2.g: bridgeActor_budget_exempt (registerIdentity)"
  body := do
    -- Construct a state where bridgeActor is registered with a real key,
    -- and even has a populated epoch budget slot.  Then run a
    -- registerIdentity action signed by bridgeActor; bridgeActor's
    -- budget should stay unchanged.
    let base : State := emptyState
    let registry := KeyRegistry.empty.register Bridge.bridgeActor (mockPubKey 0)
    let ebs0 : EpochBudgetState :=
      EpochBudgetState.topUp EpochBudgetState.empty Bridge.bridgeActor 1 5 42
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1
      , epochBudgets := ebs0 }
    let preBudget := EpochBudgetState.currentBudget es.epochBudgets Bridge.bridgeActor 1 5
    let st := mkSignedAction (.registerIdentity 99 (mockPubKey 99)) Bridge.bridgeActor es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        let postBudget := EpochBudgetState.currentBudget es'.epochBudgets Bridge.bridgeActor 1 5
        assertEq (expected := preBudget) (actual := postBudget) "bridgeActor budget unchanged"
      | none => throw <| IO.userError "bridgeActor-signed admission unexpectedly failed"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the bridgeActor-signed action"
}

/-! ## GP.3.2.h — topUpActionBudget_net_budget_change

A successful topUpActionBudget admission produces a net budget
change of `budgetIncrement - actionCost` on the signer's slot. -/

/-- Self-topup: signer 10 pays 5 gas to credit 100 budget; net change
    is `currentBudget - 1 + 100`. -/
def topUpActionBudgetNetChange : TestCase := {
  name := "GP.3.2.h: topUpActionBudget_net_budget_change"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    -- Actor 10 has 100 gas (resource 1).  topUpActionBudget converts
    -- 5 gas to 100 budget; actor 10 also pays 1 budget for the action itself.
    let preBudget := EpochBudgetState.currentBudget es.epochBudgets 10 1 5
    let st := mkSignedAction (.topUpActionBudget 1 5 100 99) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        let postBudget := EpochBudgetState.currentBudget es'.epochBudgets 10 1 5
        assertEq (expected := preBudget - 1 + 100) (actual := postBudget)
          "net budget change is +100 - 1"
      | none => throw <| IO.userError "topUpActionBudget admission unexpectedly failed"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the topUpActionBudget"
}

/-! ## GP.3.2.g — depositWithFee_grants_budget + _budget_locality

A bridgeActor-signed depositWithFee credits the recipient's budget
by exactly `budgetGrant` and doesn't change other actors' budgets. -/

/-- bridgeActor-signed depositWithFee credits recipient's budget by `budgetGrant`. -/
def depositWithFeeGrantsBudget : TestCase := {
  name := "GP.3.2.g: depositWithFee_grants_budget (recipient credited)"
  body := do
    -- Set up: bridgeActor registered; recipient=10.
    let base : State := emptyState
    let registry := (KeyRegistry.empty.register Bridge.bridgeActor
                      (mockPubKey 0)).register 10 (mockPubKey 10)
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1 }
    let preBudget := EpochBudgetState.currentBudget es.epochBudgets 10 1 5
    -- depositWithFee resource=1, recipient=10, poolActor=99, ua=50, pa=50,
    -- budgetGrant=200, depositId=42.
    let st := mkSignedAction
      (.depositWithFee 1 10 99 50 50 200 42) Bridge.bridgeActor es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        let postBudget := EpochBudgetState.currentBudget es'.epochBudgets 10 1 5
        assertEq (expected := preBudget + 200) (actual := postBudget)
          "recipient's budget credited by +200"
      | none => throw <| IO.userError "depositWithFee admission unexpectedly failed"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the depositWithFee"
}

/-- bridgeActor-signed depositWithFee preserves other actors' budgets. -/
def depositWithFeeBudgetLocality : TestCase := {
  name := "GP.3.2.g: depositWithFee_budget_locality (other actor unchanged)"
  body := do
    let base : State := emptyState
    let registry := ((KeyRegistry.empty.register Bridge.bridgeActor
                      (mockPubKey 0)).register 10 (mockPubKey 10)).register 20 (mockPubKey 20)
    let ebs0 : EpochBudgetState :=
      EpochBudgetState.topUp EpochBudgetState.empty 20 1 5 7  -- actor 20 has budget 7
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1
      , epochBudgets := ebs0 }
    let preBudget20 := EpochBudgetState.currentBudget es.epochBudgets 20 1 5
    let st := mkSignedAction
      (.depositWithFee 1 10 99 50 50 200 42) Bridge.bridgeActor es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        let postBudget20 := EpochBudgetState.currentBudget es'.epochBudgets 20 1 5
        assertEq (expected := preBudget20) (actual := postBudget20)
          "actor 20's budget unchanged"
      | none => throw <| IO.userError "depositWithFee admission unexpectedly failed"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the depositWithFee"
}

/-! ## GP.3.2.i — admission_locality_in_budget

A non-deposit non-topup admission only mutates the signer's
budget slot. -/

/-- Transfer by actor 10 doesn't change actor 20's budget. -/
def admissionLocalityInBudget : TestCase := {
  name := "GP.3.2.i: admission_locality_in_budget (other actor unchanged)"
  body := do
    let es0 := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    let ebs0 := EpochBudgetState.topUp es0.epochBudgets 20 1 5 7  -- actor 20 budget 7
    let es : ExtendedState := { es0 with epochBudgets := ebs0 }
    let preBudget20 := EpochBudgetState.currentBudget es.epochBudgets 20 1 5
    let st := mkSignedAction (.transfer 1 10 20 30) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        let postBudget20 := EpochBudgetState.currentBudget es'.epochBudgets 20 1 5
        assertEq (expected := preBudget20) (actual := postBudget20)
          "actor 20's budget unchanged"
      | none => throw <| IO.userError "transfer admission unexpectedly failed"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the transfer"
}

/-! ## GP.3.2.i — replenishment_via_epoch_advance

An actor with stale `lastSeenEpoch < currentEpoch` sees their
`currentBudget` floored at `freeTier`. -/

/-- After epoch advance, the actor's normalised budget is at least `freeTier`. -/
def replenishmentViaEpochAdvance : TestCase := {
  name := "GP.3.2.i: replenishment_via_epoch_advance (epoch boundary floors)"
  body := do
    -- Cell at epoch 0 with balance 0 (exhausted).  Query at epoch 5 with freeTier=10.
    let cell : ActorBudget := { lastSeenEpoch := 0, budgetBalance := 0 }
    let ebs : EpochBudgetState := EpochBudgetState.empty.insert 10 cell
    let cb := EpochBudgetState.currentBudget ebs 10 5 10
    assert (cb ≥ 10) s!"epoch advance floored at freeTier (got {cb}, expected ≥ 10)"
}

/-! ## GP.3.2.j — nonce_uniqueness_preserved and replay_impossible_preserved

The existing nonce-protection theorems carry through the budget gate. -/

/-- The same SignedAction cannot be admitted twice. -/
def replayImpossiblePreserved : TestCase := {
  name := "GP.3.2.j: replay_impossible_preserved (same action twice rejected)"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    let st := mkSignedAction (.transfer 1 10 20 30) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        -- Re-attempt the SAME SignedAction at es'.  Should be inadmissible
        -- (nonce mismatch).
        if AdmissibleWith mockVerify policy testDeploymentId es' st then
          throw <| IO.userError "replay was incorrectly accepted"
        else
          pure ()
      | none => throw <| IO.userError "initial admission unexpectedly failed"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the should-be-admissible transfer"
}

/-! ## Additional regression tests -/

/-- Genesis-default state (`.bounded 0 1 0`) rejects every admission.
    Uses `freezeResource` (vacuous kernel precondition) so the
    AdmissibleWith witness is unaffected by the empty base state. -/
def genesisDefaultRejects : TestCase := {
  name := "GP.3.2: ExtendedState.empty (genesis default) admits nothing"
  body := do
    let es : ExtendedState :=
      { ExtendedState.empty with
        registry := KeyRegistry.empty.register 10 (mockPubKey 10) }
    -- freezeResource has trivial precondition (True), so admissibility
    -- only fails on the budget gate.
    let st := mkSignedAction (.freezeResource 1) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | none => pure ()
      | some _ => throw <| IO.userError "genesis default unexpectedly admitted action"
    else
      throw <| IO.userError "AdmissibleWith rejected the should-be-admissible freezeResource"
}

/-- Multiple actors operate independently: actor 10's exhaustion
    doesn't affect actor 20's budget. -/
def crossActorBudgetIsolation : TestCase := {
  name := "GP.3.2: cross-actor budget isolation under bounded policy"
  body := do
    -- One-shot policy: freeTier=1, actionCost=1, so each actor gets
    -- exactly one action per epoch.
    let es := mkExtendedState (freeTier := 1) (actionCost := 1) (currentEpoch := 1)
    let st1 := mkSignedAction (.transfer 1 10 20 30) 10 es
    if h1 : AdmissibleWith mockVerify policy testDeploymentId es st1 then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st1 h1 with
      | some es' =>
        -- Actor 10's budget is now exhausted; actor 20's is still 1.
        let st2 := mkSignedAction (.transfer 1 20 10 3) 20 es'
        if h2 : AdmissibleWith mockVerify policy testDeploymentId es' st2 then
          match apply_admissible_with_budget mockVerify policy testDeploymentId es' st2 h2 with
          | some _ => pure ()
          | none => throw <| IO.userError "actor 20's action should have been admitted"
        else
          throw <| IO.userError "actor 20's AdmissibleWith unexpectedly false"
      | none => throw <| IO.userError "actor 10's first action should have been admitted"
    else
      throw <| IO.userError "actor 10's AdmissibleWith unexpectedly false"
}

/-- Self-topup chain: actor 10 tops up their budget, then can issue
    more actions in the same epoch. -/
def selfTopupChain : TestCase := {
  name := "GP.3.2: topUpActionBudget self-topup allows more actions in same epoch"
  body := do
    let es := mkExtendedState (freeTier := 1) (actionCost := 1) (currentEpoch := 1)
    -- Step 1: actor 10 tops up budget by +5 (paying 5 gas).
    let st1 := mkSignedAction (.topUpActionBudget 1 5 5 99) 10 es
    if h1 : AdmissibleWith mockVerify policy testDeploymentId es st1 then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st1 h1 with
      | some es1 =>
        -- After topup, actor 10's budget should be (1 - 1) + 5 = 5.
        let cb1 := EpochBudgetState.currentBudget es1.epochBudgets 10 1 1
        assertEq (expected := 5) (actual := cb1) "post-topup budget"
        -- Step 2: actor 10 can issue another action (budget=5, consume 1).
        let st2 := mkSignedAction (.transfer 1 10 20 10) 10 es1
        if h2 : AdmissibleWith mockVerify policy testDeploymentId es1 st2 then
          match apply_admissible_with_budget mockVerify policy testDeploymentId es1 st2 h2 with
          | some es2 =>
            let cb2 := EpochBudgetState.currentBudget es2.epochBudgets 10 1 1
            assertEq (expected := 4) (actual := cb2) "post-second-action budget"
          | none => throw <| IO.userError "second action unexpectedly rejected"
        else
          throw <| IO.userError "second action AdmissibleWith unexpectedly false"
      | none => throw <| IO.userError "topup unexpectedly rejected"
    else
      throw <| IO.userError "topup AdmissibleWith unexpectedly false"
}

/-- Insufficient gas: topUpActionBudget with `gasAmount > balance` is
    REJECTED at the admission gate.  This is the GP.3.2 safety-gate
    behaviour that prevents the "budget-without-gas" attack vector:
    without this rejection, an attacker could sign a topup with
    `gasAmount` exceeding their balance, get the kernel step
    rejected as a safe no-op (via `step_impl`'s underflow guard),
    and STILL receive the `budgetIncrement` (since the budget-grant
    arm in the admission gate runs after the kernel step).  Net
    effect: free budget accumulation without paying gas — a critical-
    severity DoS amplifier.  The GP.3.2 safety gate at the head of
    `apply_admissible_with_budget` enforces the signer-aware gas
    precondition; this test pins that enforcement at the value level. -/
def topupInsufficientGasRejected : TestCase := {
  name := "GP.3.2: topUpActionBudget with insufficient gas is rejected"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    -- Actor 10 has 100 gas at resource 1.  Try to top up using 200 gas
    -- (more than the actor's balance).  The signer-aware kernel
    -- precondition `getBalance es.base 1 10 ≥ 200` fails (100 < 200),
    -- so admission must REJECT — otherwise the attacker would get
    -- +50 budget without paying any gas.
    let st := mkSignedAction (.topUpActionBudget 1 200 50 99) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | none =>
        -- Expected: gas-check failure rejects the action.
        pure ()
      | some _ =>
        throw <| IO.userError
          "BUG: topUpActionBudget with insufficient gas accepted (budget-without-gas attack)"
    else
      throw <| IO.userError "topup AdmissibleWith unexpectedly false"
}

/-- Zero-gas attack vector: signing `topUpActionBudget gr 0 huge pa`
    must be REJECTED.  Without this rejection, an attacker could
    sign a topup with `gasAmount = 0` and a huge `budgetIncrement`,
    pass the old `getBalance ≥ 0` check trivially, no-op the
    kernel step (debit 0 / credit 0), and STILL receive
    `budgetIncrement` budget for free.  The GP.3.2 safety gate's
    `gasAmount > 0` conjunct enforces the rejection. -/
def topupZeroGasRejected : TestCase := {
  name := "GP.3.2: topUpActionBudget with gasAmount=0 is rejected (zero-gas attack)"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    -- Try to top up paying 0 gas for 1000 budget — should be rejected.
    let st := mkSignedAction (.topUpActionBudget 1 0 1000 99) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | none => pure ()  -- expected: zero-gas check fires.
      | some _ =>
        throw <| IO.userError
          "BUG: topUpActionBudget with gasAmount=0 accepted (zero-gas attack)"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the should-be-admissible topup"
}

/-- The bridge-aware mirror enforces the same zero-gas rejection. -/
def bridgeAdmissibleTopupZeroGasRejected : TestCase := {
  name := "GP.3.2: bridge-aware gate rejects topUp with gasAmount=0"
  body := do
    let base : State := setBalance emptyState 1 10 100
    let registry := (KeyRegistry.empty.register Bridge.bridgeActor
                      (mockPubKey 0)).register 10 (mockPubKey 10)
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1 }
    let st := mkSignedAction (.topUpActionBudget 1 0 1000 99) 10 es
    if h : LegalKernel.Bridge.BridgeAdmissibleWith
              mockVerify policy testDeploymentId es st then
      match LegalKernel.Bridge.apply_bridge_admissible_with_budget
              mockVerify policy testDeploymentId es st 0 h with
      | none => pure ()
      | some _ =>
        throw <| IO.userError
          "BUG: bridge-aware gate accepted zero-gas topup"
    else
      throw <| IO.userError "bridge-aware AdmissibleWith unexpectedly false"
}

/-- All-zero corner case: `topUpActionBudget 0 0 0 0` should be
    REJECTED (gasAmount=0 fails the gas check). -/
def topupAllZerosRejected : TestCase := {
  name := "GP.3.2: topUpActionBudget with all-zero args is rejected (gasAmount=0)"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    -- Pathological all-zero action.
    let st := mkSignedAction (.topUpActionBudget 0 0 0 0) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | none => pure ()  -- expected
      | some _ =>
        throw <| IO.userError "BUG: all-zero topup accepted"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the all-zero topup"
}

/-- **Self-pool attack** (round-3 audit): `topUpActionBudget` with
    `signer = poolActor` round-trips the gas (no net debit) yet
    receives `budgetIncrement` credit.  Without the
    `signer ≠ poolActor` conjunct in `topUpActionBudget_gasCheck`,
    this would allow unbounded free budget accumulation.
    `Laws.topUpActionBudget`'s `apply_impl` is the two-step
    `setBalance s gr signer (balance - ga); setBalance s' gr
    poolActor (balance' + ga)`; when `poolActor = signer`, the
    second setBalance re-credits the same gas just debited.
    The gate's `signer ≠ poolActor` conjunct rejects the action
    before the kernel step and budget grant run. -/
def topupSelfPoolRejected : TestCase := {
  name := "GP.3.2: topUpActionBudget with signer=poolActor is rejected (self-pool attack)"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    -- Actor 10 signs topUp with poolActor=10 (self).  Without the
    -- `signer ≠ poolActor` conjunct, the kernel step is a no-op
    -- (gas round-trips through actor 10) yet the budget arm credits
    -- budgetIncrement to actor 10's slot.
    let st := mkSignedAction (.topUpActionBudget 1 50 1000 10) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | none => pure ()  -- expected: gate rejects.
      | some _ =>
        throw <| IO.userError
          "BUG: topUp with signer=poolActor admitted (would grant free budget)"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the should-be-admissible topup"
}

/-- Bridge-aware mirror of `topupSelfPoolRejected`. -/
def bridgeAdmissibleTopupSelfPoolRejected : TestCase := {
  name := "GP.3.2: bridge-aware gate rejects topUp with signer=poolActor"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    let st := mkSignedAction (.topUpActionBudget 1 50 1000 10) 10 es
    if h : LegalKernel.Bridge.BridgeAdmissibleWith
              mockVerify policy testDeploymentId es st then
      match LegalKernel.Bridge.apply_bridge_admissible_with_budget
              mockVerify policy testDeploymentId es st 0 h with
      | none => pure ()
      | some _ =>
        throw <| IO.userError
          "BUG: bridge-aware gate accepted self-pool topup"
    else
      throw <| IO.userError "bridge-aware AdmissibleWith unexpectedly false"
}

/-- Defense-in-depth: `topUpActionBudget` signed by `bridgeActor`
    is REJECTED at the gate level (in addition to the production
    `bridgePolicy` rejection).  Without this, the bridgeActor's
    consume-skip exemption combined with the budget-grant arm
    would credit free budget to bridgeActor's slot — defeating
    the per-action consume cost. -/
def topupByBridgeActorRejected : TestCase := {
  name := "GP.3.2: topUpActionBudget signed by bridgeActor is rejected (defense in depth)"
  body := do
    let base : State := setBalance emptyState 1 Bridge.bridgeActor 100
    let registry := KeyRegistry.empty.register Bridge.bridgeActor (mockPubKey 0)
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1 }
    -- bridgeActor signs a topUp with valid gas and amount.  Under
    -- the old design (before the `signer ≠ bridgeActor` conjunct),
    -- this would skip consume (bridgeActor exemption) and credit
    -- bridgeActor's budget — free budget for bridgeActor.  The
    -- new gate's third conjunct rejects this combination.
    let st := mkSignedAction (.topUpActionBudget 1 50 1000 99) Bridge.bridgeActor es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | none => pure ()  -- expected: gate rejects.
      | some _ =>
        throw <| IO.userError
          "BUG: bridgeActor-signed topUp admitted (would grant free budget)"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the should-be-admissible topup"
}

/-- Bridge-aware mirror of `topupByBridgeActorRejected`. -/
def bridgeAdmissibleTopupByBridgeActorRejected : TestCase := {
  name := "GP.3.2: bridge-aware gate rejects topUp signed by bridgeActor"
  body := do
    let base : State := setBalance emptyState 1 Bridge.bridgeActor 100
    let registry := KeyRegistry.empty.register Bridge.bridgeActor (mockPubKey 0)
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1 }
    let st := mkSignedAction (.topUpActionBudget 1 50 1000 99) Bridge.bridgeActor es
    if h : LegalKernel.Bridge.BridgeAdmissibleWith
              mockVerify policy testDeploymentId es st then
      match LegalKernel.Bridge.apply_bridge_admissible_with_budget
              mockVerify policy testDeploymentId es st 0 h with
      | none => pure ()
      | some _ =>
        throw <| IO.userError
          "BUG: bridge-aware gate accepted bridgeActor-signed topup"
    else
      throw <| IO.userError "bridge-aware AdmissibleWith unexpectedly false"
}

/-- ROUND-5 ATTACK VECTOR: a non-bridgeActor signer attempts to credit
    THEMSELVES via a depositWithFee.  Under the pre-round-5 design, the
    gate's bridgeActor branch was skipped (the signer is not
    bridgeActor), the consume step succeeded (the signer's budget was
    debited by `actionCost`), AND the depositWithFee's per-action grant
    arm credited the recipient (= self) by `budgetGrant` AND
    `apply_admissible_with`'s kernel step credited the recipient's
    BALANCE by `userAmount + poolAmount`.  Net effect: free balance +
    free budget for an arbitrary actor.  The round-5 fix
    (`depositWithFee_signerCheck`) requires `signer = bridgeActor` for
    every `.depositWithFee` action.  This test pins that the attack is
    REJECTED at the gate. -/
def depositWithFeeNonBridgeSignerRejected : TestCase := {
  name := "GP.3.2: depositWithFee signed by non-bridgeActor REJECTED"
  body := do
    -- Setup: actor 10 (non-bridge) is registered with balance 100.
    let base : State := setBalance emptyState 1 10 100
    let registry :=
      (KeyRegistry.empty.register Bridge.bridgeActor (mockPubKey 0)).register 10 (mockPubKey 10)
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1 }
    -- Actor 10 signs a depositWithFee with recipient = self, granting
    -- 1000 budget and 100 balance.  Under the pre-fix design, this
    -- would succeed; under the round-5 fix, this is rejected.
    let st := mkSignedAction
      (.depositWithFee 1 10 99 50 50 1000 42) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | none => pure ()  -- expected: gate rejects.
      | some _ =>
        throw <| IO.userError
          "BUG: non-bridgeActor depositWithFee admitted (would grant free balance + budget)"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected the should-be-admissible action"
}

/-- Bridge-aware mirror of `depositWithFeeNonBridgeSignerRejected`.

    Two valid rejection points: (a) `BridgeAdmissibleWith` rejects at
    the predicate level via conjunct 8 (`Action.isBridgeOnly
    .depositWithFee = true → signer = bridgeActor`), OR (b) the gate
    rejects at admission via `depositWithFee_signerCheck`.  Either
    way the attack is blocked; this test accepts both outcomes and
    fails only if the bridge-aware path actually credits the
    recipient. -/
def bridgeAdmissibleDepositWithFeeNonBridgeSignerRejected : TestCase := {
  name := "GP.3.2: bridge-aware gate rejects non-bridgeActor depositWithFee"
  body := do
    let base : State := setBalance emptyState 1 10 100
    let registry :=
      (KeyRegistry.empty.register Bridge.bridgeActor (mockPubKey 0)).register 10 (mockPubKey 10)
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1 }
    let st := mkSignedAction
      (.depositWithFee 1 10 99 50 50 1000 42) 10 es
    if h : LegalKernel.Bridge.BridgeAdmissibleWith
              mockVerify policy testDeploymentId es st then
      match LegalKernel.Bridge.apply_bridge_admissible_with_budget
              mockVerify policy testDeploymentId es st 0 h with
      | none => pure ()  -- rejected at gate (depositWithFee_signerCheck)
      | some _ =>
        throw <| IO.userError
          "BUG: bridge-aware gate accepted non-bridgeActor depositWithFee"
    else
      -- BridgeAdmissibleWith conjunct 8 rejected at the predicate
      -- layer (Action.isBridgeOnly .depositWithFee = true requires
      -- signer = bridgeActor).  Defense in depth: the attack is
      -- blocked BEFORE the gate even runs.
      pure ()
}

/-- Companion to `topupInsufficientGasRejected`: confirm that a
    topup with EXACTLY enough gas IS admitted.  Pins the boundary
    condition of the gas-check gate. -/
def topupWithSufficientGasAdmitted : TestCase := {
  name := "GP.3.2: topUpActionBudget with sufficient gas admitted (boundary)"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    -- Actor 10 has 100 gas; spend exactly 100 → admitted; signer's
    -- balance is debited to 0, pool's balance credited to 100.
    let st := mkSignedAction (.topUpActionBudget 1 100 50 99) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        assertEq (expected := 0) (actual := getBalance es'.base 1 10)
          "signer's gas balance debited to 0"
        assertEq (expected := 100) (actual := getBalance es'.base 1 99)
          "pool's gas balance credited to 100"
        let cb := EpochBudgetState.currentBudget es'.epochBudgets 10 1 5
        assertEq (expected := 5 - 1 + 50) (actual := cb)
          "signer's budget increased by +50 - 1 (topup net change)"
      | none => throw <| IO.userError "topup with exact balance unexpectedly rejected"
    else
      throw <| IO.userError "topup AdmissibleWith unexpectedly false"
}

/-! ## Term-level API stability checks -/

/-- `admission_consumes_budget_on_success` is term-level callable. -/
def admissionConsumesBudgetAPI : TestCase := {
  name := "admission_consumes_budget_on_success API stability"
  body := do
    let _proof :
      ∀ {verify : PublicKey → ByteArray → Signature → Bool}
        {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
        {st : SignedAction} {h : AdmissibleWith verify P d es st}
        {freeTier actionCost currentEpoch : Nat},
        es.budgetPolicy = .bounded freeTier actionCost currentEpoch →
        st.signer ≠ Bridge.bridgeActor →
        (∀ r recipient poolActor ua pa bg dep,
          st.action ≠ .depositWithFee r recipient poolActor ua pa bg dep) →
        (∀ gr ga bi pa,
          st.action ≠ .topUpActionBudget gr ga bi pa) →
        ∀ {es' : ExtendedState},
        apply_admissible_with_budget verify P d es st h = some es' →
        EpochBudgetState.currentBudget es'.epochBudgets st.signer currentEpoch freeTier =
        EpochBudgetState.currentBudget es.epochBudgets st.signer currentEpoch freeTier
          - actionCost := @admission_consumes_budget_on_success
    pure ()
}

/-- `admission_rejected_when_budget_zero` is term-level callable. -/
def admissionRejectedAPI : TestCase := {
  name := "admission_rejected_when_budget_zero API stability"
  body := do
    let _proof :
      ∀ (verify : PublicKey → ByteArray → Signature → Bool)
        (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
        (st : SignedAction) (h : AdmissibleWith verify P d es st)
        (freeTier actionCost currentEpoch : Nat),
        es.budgetPolicy = .bounded freeTier actionCost currentEpoch →
        st.signer ≠ Bridge.bridgeActor →
        EpochBudgetState.currentBudget es.epochBudgets st.signer currentEpoch freeTier
          < actionCost →
        apply_admissible_with_budget verify P d es st h = none :=
      admission_rejected_when_budget_zero
    pure ()
}

/-- `bridgeActor_budget_exempt` is term-level callable. -/
def bridgeActorExemptAPI : TestCase := {
  name := "bridgeActor_budget_exempt API stability"
  body := do
    let _proof := @bridgeActor_budget_exempt
    pure ()
}

/-- `depositWithFee_grants_budget` is term-level callable. -/
def depositWithFeeGrantsBudgetAPI : TestCase := {
  name := "depositWithFee_grants_budget API stability"
  body := do
    let _proof := @depositWithFee_grants_budget
    pure ()
}

/-- `depositWithFee_budget_locality` is term-level callable. -/
def depositWithFeeBudgetLocalityAPI : TestCase := {
  name := "depositWithFee_budget_locality API stability"
  body := do
    let _proof := @depositWithFee_budget_locality
    pure ()
}

/-- `topUpActionBudget_net_budget_change` is term-level callable. -/
def topUpActionBudgetNetChangeAPI : TestCase := {
  name := "topUpActionBudget_net_budget_change API stability"
  body := do
    let _proof := @topUpActionBudget_net_budget_change
    pure ()
}

/-- `admission_locality_in_budget` is term-level callable. -/
def admissionLocalityAPI : TestCase := {
  name := "admission_locality_in_budget API stability"
  body := do
    let _proof := @admission_locality_in_budget
    pure ()
}

/-- `replenishment_via_epoch_advance` is term-level callable. -/
def replenishmentAPI : TestCase := {
  name := "replenishment_via_epoch_advance API stability"
  body := do
    let _proof := @replenishment_via_epoch_advance
    pure ()
}

/-- `nonce_uniqueness_preserved` is term-level callable. -/
def nonceUniquenessAPI : TestCase := {
  name := "nonce_uniqueness_preserved API stability"
  body := do
    let _proof := @nonce_uniqueness_preserved
    pure ()
}

/-- `replay_impossible_preserved` is term-level callable. -/
def replayImpossibleAPI : TestCase := {
  name := "replay_impossible_preserved API stability"
  body := do
    let _proof := @replay_impossible_preserved
    pure ()
}

/-! ## Bridge-aware admission gate parity (production runtime path)

The production runtime (post-RB.3) dispatches through
`apply_bridge_admissible_with_budget` (Bridge/Admissible.lean), not
the kernel-only `apply_admissible_with_budget`.  These tests pin
that the bridge-aware mirror enforces the SAME safety properties:
bridgeActor exemption, consume step, GP.3.2 gas-check gate, and
budget grant. -/

/-- The bridge-aware gate enforces the same gas check as the
    kernel-only entry: topUpActionBudget with insufficient gas is
    rejected. -/
def bridgeAdmissibleTopupInsufficientGasRejected : TestCase := {
  name := "GP.3.2: bridge-aware gate rejects topUp with insufficient gas"
  body := do
    -- Build an ExtendedState with bridgeActor + signer 10 registered.
    let base : State := setBalance emptyState 1 10 100
    let registry := (KeyRegistry.empty.register Bridge.bridgeActor
                      (mockPubKey 0)).register 10 (mockPubKey 10)
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1 }
    -- Actor 10 attempts a topup spending 200 gas (more than balance 100).
    let st := mkSignedAction (.topUpActionBudget 1 200 50 99) 10 es
    if h : LegalKernel.Bridge.BridgeAdmissibleWith
              mockVerify policy testDeploymentId es st then
      match LegalKernel.Bridge.apply_bridge_admissible_with_budget
              mockVerify policy testDeploymentId es st 0 h with
      | none => pure ()  -- expected
      | some _ =>
        throw <| IO.userError
          "BUG: bridge-aware gate accepted insufficient-gas topup"
    else
      throw <| IO.userError "bridge-aware AdmissibleWith unexpectedly false"
}

/-- The bridge-aware gate enforces the bridgeActor exemption. -/
def bridgeAdmissibleBridgeActorExempt : TestCase := {
  name := "GP.3.2: bridge-aware gate exempts bridgeActor from consume"
  body := do
    let base : State := emptyState
    let registry := KeyRegistry.empty.register Bridge.bridgeActor (mockPubKey 0)
    let ebs0 : EpochBudgetState :=
      EpochBudgetState.topUp EpochBudgetState.empty Bridge.bridgeActor 1 5 42
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1
      , epochBudgets := ebs0 }
    let preBudget := EpochBudgetState.currentBudget es.epochBudgets Bridge.bridgeActor 1 5
    let st := mkSignedAction (.registerIdentity 99 (mockPubKey 99)) Bridge.bridgeActor es
    if h : LegalKernel.Bridge.BridgeAdmissibleWith
              mockVerify policy testDeploymentId es st then
      match LegalKernel.Bridge.apply_bridge_admissible_with_budget
              mockVerify policy testDeploymentId es st 0 h with
      | some es' =>
        let postBudget :=
          EpochBudgetState.currentBudget es'.epochBudgets Bridge.bridgeActor 1 5
        assertEq (expected := preBudget) (actual := postBudget)
          "bridgeActor budget unchanged by bridge-aware gate"
      | none => throw <| IO.userError "bridge-aware admission unexpectedly failed"
    else
      throw <| IO.userError "bridge-aware AdmissibleWith unexpectedly false"
}

/-- The bridge-aware gate consumes signer budget on non-bridge
    actions, matching the kernel-only entry. -/
def bridgeAdmissibleNonBridgeConsumes : TestCase := {
  name := "GP.3.2: bridge-aware gate consumes budget on non-bridge actions"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    let st := mkSignedAction (.transfer 1 10 20 30) 10 es
    if h : LegalKernel.Bridge.BridgeAdmissibleWith
              mockVerify policy testDeploymentId es st then
      match LegalKernel.Bridge.apply_bridge_admissible_with_budget
              mockVerify policy testDeploymentId es st 0 h with
      | some es' =>
        let preBudget := EpochBudgetState.currentBudget es.epochBudgets 10 1 5
        let postBudget := EpochBudgetState.currentBudget es'.epochBudgets 10 1 5
        assertEq (expected := preBudget - 1) (actual := postBudget)
          "bridge-aware gate consumed signer's budget by 1"
      | none => throw <| IO.userError "bridge-aware admission unexpectedly failed"
    else
      throw <| IO.userError "bridge-aware AdmissibleWith unexpectedly false"
}

/-! ## Edge-case regressions for the GP.3.2 safety gate -/

/-- Zero `budgetGrant` on depositWithFee: recipient's budget is
    unchanged (boundary).  Pins that the topUp is value-preserving
    on `+0`. -/
def depositWithFeeZeroGrant : TestCase := {
  name := "GP.3.2: depositWithFee with budgetGrant=0 leaves recipient budget unchanged"
  body := do
    let base : State := emptyState
    let registry := (KeyRegistry.empty.register Bridge.bridgeActor
                      (mockPubKey 0)).register 10 (mockPubKey 10)
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1 }
    let preBudget := EpochBudgetState.currentBudget es.epochBudgets 10 1 5
    -- depositWithFee with budgetGrant=0.
    let st := mkSignedAction
      (.depositWithFee 1 10 99 50 50 0 42) Bridge.bridgeActor es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        let postBudget := EpochBudgetState.currentBudget es'.epochBudgets 10 1 5
        assertEq (expected := preBudget) (actual := postBudget)
          "recipient's budget unchanged by zero grant"
      | none => throw <| IO.userError "zero-grant depositWithFee unexpectedly rejected"
    else
      throw <| IO.userError "AdmissibleWith unexpectedly false"
}

/-- Zero `budgetIncrement` on topUpActionBudget: signer pays gas but
    receives no budget credit.  Pins that the topUp is value-preserving
    on `+0` (still consumes 1 budget for the action cost). -/
def topUpActionBudgetZeroIncrement : TestCase := {
  name := "GP.3.2: topUpActionBudget with budgetIncrement=0 charges actionCost only"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    let preBudget := EpochBudgetState.currentBudget es.epochBudgets 10 1 5
    -- 5 gas to credit 0 budget; the action itself costs 1 budget.
    let st := mkSignedAction (.topUpActionBudget 1 5 0 99) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        let postBudget := EpochBudgetState.currentBudget es'.epochBudgets 10 1 5
        -- Net change: -1 (action cost) +0 (increment) = -1.
        assertEq (expected := preBudget - 1) (actual := postBudget)
          "net budget change is -1 (actionCost only, no increment)"
        -- Gas was still debited (kernel step succeeded since 100 ≥ 5).
        assertEq (expected := 95) (actual := getBalance es'.base 1 10)
          "signer's gas balance debited by 5 (kernel step succeeded)"
      | none => throw <| IO.userError "zero-increment topup unexpectedly rejected"
    else
      throw <| IO.userError "AdmissibleWith unexpectedly false"
}

/-! ## Cross-state-field locality (regression coverage) -/

/-- Value-level proof of `nonce_uniqueness_preserved`: two distinct
    admissible SignedActions by the same signer share the same nonce
    (because both equal `expectsNonce es signer`).  Pins the theorem
    at the value level (the existing test was only term-level). -/
def nonceUniquenessAcrossBudgetGate : TestCase := {
  name := "GP.3.2.j: nonce_uniqueness_preserved (value-level)"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    -- Two distinct actions, both by actor 10, both with nonce 0.
    let st1 := mkSignedAction (.transfer 1 10 20 30) 10 es
    let st2 := mkSignedAction (.mint 1 10 50) 10 es
    -- Both should be AdmissibleWith.
    if h1 : AdmissibleWith mockVerify policy testDeploymentId es st1 then
      if h2 : AdmissibleWith mockVerify policy testDeploymentId es st2 then
        -- Term-level proof: feed the witnesses into the theorem and
        -- bind the result.  Elaboration succeeds iff the theorem's
        -- signature matches.  Value-level check: st1.nonce == st2.nonce.
        let _proof : st1.nonce = st2.nonce :=
          nonce_uniqueness_preserved mockVerify policy testDeploymentId es
            st1 st2 h1 h2 rfl
        assertEq (expected := st1.nonce) (actual := st2.nonce)
          "st1 and st2 share the same nonce (nonce_uniqueness_preserved)"
      else
        throw <| IO.userError "st2 AdmissibleWith unexpectedly false"
    else
      throw <| IO.userError "st1 AdmissibleWith unexpectedly false"
}

/-- depositWithFee with `recipient = bridgeActor` is rejected by the
    plan-level invariant.  The GP.3.2 `bridgeActor_budget_exempt`
    theorem explicitly excludes this corner case via the
    `hne_dep_to_bridge` hypothesis.  We pin that admission STILL
    succeeds (since the kernel-step + budget grant are
    well-defined), but that the test author's responsibility is to
    not construct such an action in production.  This is a "the
    function doesn't crash" smoke test for the corner case. -/
def depositWithFeeRecipientIsBridgeActor : TestCase := {
  name := "GP.3.2: depositWithFee with recipient=bridgeActor is admitted (smoke)"
  body := do
    let base : State := emptyState
    let registry := KeyRegistry.empty.register Bridge.bridgeActor (mockPubKey 0)
    let es : ExtendedState :=
      { base := base
      , nonces := NonceState.empty
      , registry := registry
      , budgetPolicy := .bounded 5 1 1 }
    let st := mkSignedAction
      (.depositWithFee 1 Bridge.bridgeActor 99 50 50 200 42) Bridge.bridgeActor es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        -- recipient = bridgeActor was credited +200 by the topup.
        -- This is by design (no separate protection against it); the
        -- `bridgeActor_budget_exempt` theorem documents the
        -- exclusion of this corner.
        let postBudget :=
          EpochBudgetState.currentBudget es'.epochBudgets Bridge.bridgeActor 1 5
        let preBudget :=
          EpochBudgetState.currentBudget es.epochBudgets Bridge.bridgeActor 1 5
        assertEq (expected := preBudget + 200) (actual := postBudget)
          "bridgeActor as recipient receives +200 budget (corner case)"
      | none =>
        throw <| IO.userError "self-recipient depositWithFee unexpectedly rejected"
    else
      throw <| IO.userError "AdmissibleWith unexpectedly false"
}

/-- Successful admission preserves the bridge field (kernel-only
    entry).  Pins that the budget gate doesn't accidentally touch
    bridge state. -/
def admissionPreservesBridge : TestCase := {
  name := "GP.3.2: admission preserves bridge field (kernel-only entry)"
  body := do
    let es := mkExtendedState (freeTier := 5) (actionCost := 1) (currentEpoch := 1)
    let st := mkSignedAction (.transfer 1 10 20 30) 10 es
    if h : AdmissibleWith mockVerify policy testDeploymentId es st then
      match apply_admissible_with_budget mockVerify policy testDeploymentId es st h with
      | some es' =>
        assertEq (expected := es.bridge.nextWdId) (actual := es'.bridge.nextWdId)
          "bridge.nextWdId unchanged"
      | none => throw <| IO.userError "admission unexpectedly failed"
    else
      throw <| IO.userError "AdmissibleWith unexpectedly false"
}

/-- All tests in the SignedActionBudget suite. -/
def tests : List TestCase :=
  [ -- Value-level coverage:
    admissionConsumesBudget
  , admissionRejectedWhenBudgetZero
  , bridgeActorBudgetExempt
  , topUpActionBudgetNetChange
  , depositWithFeeGrantsBudget
  , depositWithFeeBudgetLocality
  , admissionLocalityInBudget
  , replenishmentViaEpochAdvance
  , replayImpossiblePreserved
  , genesisDefaultRejects
  , crossActorBudgetIsolation
  , selfTopupChain
  , topupInsufficientGasRejected
  , topupZeroGasRejected
  , topupAllZerosRejected
  , topupSelfPoolRejected
  , topupByBridgeActorRejected
  , depositWithFeeNonBridgeSignerRejected
  , topupWithSufficientGasAdmitted
    -- Bridge-aware mirror parity (production runtime path):
  , bridgeAdmissibleTopupInsufficientGasRejected
  , bridgeAdmissibleTopupZeroGasRejected
  , bridgeAdmissibleTopupSelfPoolRejected
  , bridgeAdmissibleTopupByBridgeActorRejected
  , bridgeAdmissibleDepositWithFeeNonBridgeSignerRejected
  , bridgeAdmissibleBridgeActorExempt
  , bridgeAdmissibleNonBridgeConsumes
    -- Edge-case regressions:
  , depositWithFeeZeroGrant
  , topUpActionBudgetZeroIncrement
  , admissionPreservesBridge
  , nonceUniquenessAcrossBudgetGate
  , depositWithFeeRecipientIsBridgeActor
    -- API stability:
  , admissionConsumesBudgetAPI
  , admissionRejectedAPI
  , bridgeActorExemptAPI
  , depositWithFeeGrantsBudgetAPI
  , depositWithFeeBudgetLocalityAPI
  , topUpActionBudgetNetChangeAPI
  , admissionLocalityAPI
  , replenishmentAPI
  , nonceUniquenessAPI
  , replayImpossibleAPI
  ]

end SignedActionBudget
end LegalKernel.Test.Authority

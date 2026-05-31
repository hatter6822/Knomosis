-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Authority.DelegatedTopup — Workstream GP / WU GP.3.4
delegated `topUpActionBudgetFor` test suite.

Pins the value-level behaviour of the GP.3.4 delegated budget top-up
across its three layers:

  * the `allowTopUpFrom` local-policy clause + default-deny consent
    check (`delegatedTopUpConsentBool` / its iff characterisation);
  * the `Laws.topUpActionBudgetFor` kernel leg (signer debited, pool
    credited, conservation, locality, self-delegation guard);
  * the admission gate (`apply_admissible_with_budget` + the
    bridge-aware mirror): happy path, default-deny rejection,
    revocation, multi-delegate, the five gas-safety attack rejections
    (self-delegation, insufficient gas, zero gas, self-pool,
    bridgeActor), and cross-delegate isolation.

Plus encoder round-trip coverage for the new `Action` / clause and
event extraction, and term-level API-stability checks for the three
GP.3.4 headline theorems.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Authority
namespace DelegatedTopup

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding
open LegalKernel.Events
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

/-! ## Test fixtures -/

/-- Test deployment id. -/
def testDeploymentId : ByteArray := ByteArray.mk #[0xDE, 0x1E, 0x6A, 0x7E]

/-- Unrestricted authority policy. -/
def policy : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- Canonical gas resource for the suite. -/
def gasRes : ResourceId := 1

/-- Pool actor (GP.7.1 / ActorId 1). -/
def poolActor : ActorId := 1

/-- Delegate A (the funded payer in most scenarios). -/
def delegateA : ActorId := 10

/-- The recipient whose budget is delegated-funded. -/
def recipientR : ActorId := 20

/-- Delegate B (a second funded payer, for isolation tests). -/
def delegateB : ActorId := 30

/-- Build an `ExtendedState` with the bridge actor, pool actor,
    delegates A / B, and the recipient all registered.  Delegates A
    and B each hold `1000` units at `gasRes`; the recipient holds
    nothing (they only ever *receive* budget).  Bounded budget policy
    `(freeTier, actionCost, currentEpoch)`. -/
def mkBase (freeTier actionCost currentEpoch : Nat) : ExtendedState :=
  let base : State :=
    setBalance (setBalance emptyState gasRes delegateA 1000) gasRes delegateB 1000
  let registry :=
    ((((KeyRegistry.empty.register Bridge.bridgeActor (mockPubKey Bridge.bridgeActor.toNat)).register
        poolActor (mockPubKey poolActor.toNat)).register
        delegateA (mockPubKey delegateA.toNat)).register
        recipientR (mockPubKey recipientR.toNat)).register
        delegateB (mockPubKey delegateB.toNat)
  { base := base
  , nonces := NonceState.empty
  , registry := registry
  , budgetPolicy := .bounded freeTier actionCost currentEpoch }

/-- Set `recipient`'s declared local policy to a single
    `allowTopUpFrom delegates` clause (the GP.3.4 consent grant). -/
def withConsent (es : ExtendedState) (recipient : ActorId)
    (delegates : List ActorId) : ExtendedState :=
  { es with localPolicies :=
      es.localPolicies.declare recipient { clauses := [.allowTopUpFrom delegates] } }

/-- Build a mock-signed `SignedAction`. -/
def mkSignedAction (action : Action) (signer : ActorId) (es : ExtendedState) :
    SignedAction :=
  let nonce := expectsNonce es signer
  let msg := signingInput action signer nonce testDeploymentId
  let sig := mockSign (mockPubKey signer.toNat) msg
  ⟨action, signer, nonce, sig⟩

/-- Admit `st` at `es` through the kernel-only budget gate, throwing
    if the (mock-verified) `AdmissibleWith` predicate is unexpectedly
    false (which would signal a test-setup error — bad nonce, unsigned
    actor — rather than the budget-gate rejection under test). -/
def admit (es : ExtendedState) (st : SignedAction) : IO (Option ExtendedState) := do
  match (inferInstance : Decidable (AdmissibleWith mockVerify policy testDeploymentId es st)) with
  | .isTrue h => pure (apply_admissible_with_budget mockVerify policy testDeploymentId es st h)
  | .isFalse _ =>
      throw <| IO.userError "AdmissibleWith mockVerify rejected (test-setup error)"

/-- A `topUpActionBudgetFor recipient gasRes gasAmount budgetIncrement
    poolActor` signed action. -/
def delegatedTopupAction (recipient : ActorId) (gasAmount budgetIncrement : Nat) : Action :=
  .topUpActionBudgetFor recipient gasRes gasAmount budgetIncrement poolActor

/-! ## Consent data layer -/

/-- A recipient who whitelisted the signer ⇒ consent is `true`. -/
def consentTrueWhenWhitelisted : TestCase := {
  name := "GP.3.4: delegatedTopUpConsentBool true when recipient whitelists signer"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    assertEq (expected := true)
      (actual := delegatedTopUpConsentBool es recipientR delegateA)
      "whitelisted delegate consented"
}

/-- A recipient with NO `allowTopUpFrom` clause ⇒ default-deny
    (consent `false`). -/
def consentFalseByDefault : TestCase := {
  name := "GP.3.4: delegatedTopUpConsentBool false by default (no clause)"
  body := do
    let es := mkBase 5 1 1
    assertEq (expected := false)
      (actual := delegatedTopUpConsentBool es recipientR delegateA)
      "default-deny: no allowTopUpFrom clause"
}

/-- A recipient who whitelisted a *different* delegate ⇒ consent
    `false` for the non-listed signer. -/
def consentFalseForNonListed : TestCase := {
  name := "GP.3.4: delegatedTopUpConsentBool false for non-whitelisted signer"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateB]
    assertEq (expected := false)
      (actual := delegatedTopUpConsentBool es recipientR delegateA)
      "delegate A not in [delegateB]"
}

/-- A multi-delegate whitelist consents to each listed delegate. -/
def consentMultiDelegate : TestCase := {
  name := "GP.3.4: multi-delegate whitelist consents to each listed delegate"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA, delegateB]
    assertEq (expected := true)
      (actual := delegatedTopUpConsentBool es recipientR delegateA) "A consented"
    assertEq (expected := true)
      (actual := delegatedTopUpConsentBool es recipientR delegateB) "B consented"
    assertEq (expected := false)
      (actual := delegatedTopUpConsentBool es recipientR poolActor) "pool not consented"
}

/-! ## Law kernel-leg (value-level on `step_impl`) -/

/-- The signer (payer) is debited by `gasAmount`. -/
def lawSignerDebited : TestCase := {
  name := "GP.3.4 law: signer debited by gasAmount"
  body := do
    let s : State := setBalance emptyState gasRes delegateA 100
    let t := Laws.topUpActionBudgetFor recipientR delegateA gasRes 40 7 poolActor
    let s' := step_impl s t
    assertEq (expected := 60) (actual := getBalance s' gasRes delegateA) "signer 100-40"
}

/-- The pool actor is credited by `gasAmount`. -/
def lawPoolCredited : TestCase := {
  name := "GP.3.4 law: poolActor credited by gasAmount"
  body := do
    let s : State := setBalance emptyState gasRes delegateA 100
    let t := Laws.topUpActionBudgetFor recipientR delegateA gasRes 40 7 poolActor
    let s' := step_impl s t
    assertEq (expected := 40) (actual := getBalance s' gasRes poolActor) "pool 0+40"
}

/-- The recipient's *kernel balance* is untouched (only its budget is
    affected, at the admission layer). -/
def lawRecipientBalanceUntouched : TestCase := {
  name := "GP.3.4 law: recipient kernel balance untouched"
  body := do
    let s : State := setBalance (setBalance emptyState gasRes delegateA 100) gasRes recipientR 5
    let t := Laws.topUpActionBudgetFor recipientR delegateA gasRes 40 7 poolActor
    let s' := step_impl s t
    assertEq (expected := 5) (actual := getBalance s' gasRes recipientR) "recipient unchanged"
}

/-- Total supply at the gas resource is conserved. -/
def lawConserves : TestCase := {
  name := "GP.3.4 law: gas-resource total supply conserved"
  body := do
    let s : State := setBalance (setBalance emptyState gasRes delegateA 100) gasRes poolActor 30
    let t := Laws.topUpActionBudgetFor recipientR delegateA gasRes 40 7 poolActor
    let s' := step_impl s t
    assertEq (expected := TotalSupply s gasRes) (actual := TotalSupply s' gasRes)
      "supply conserved"
}

/-- Self-delegation (`recipient = signer`) fails the precondition, so
    the kernel step is a no-op. -/
def lawSelfDelegationNoop : TestCase := {
  name := "GP.3.4 law: self-delegation (recipient = signer) is a kernel no-op"
  body := do
    let s : State := setBalance emptyState gasRes delegateA 100
    -- recipient = signer = delegateA: precondition `recipient ≠ signer` fails.
    let t := Laws.topUpActionBudgetFor delegateA delegateA gasRes 40 7 poolActor
    let s' := step_impl s t
    assertEq (expected := 100) (actual := getBalance s' gasRes delegateA) "no debit on self-delegation"
    assertEq (expected := 0) (actual := getBalance s' gasRes poolActor) "no credit on self-delegation"
}

/-- Insufficient signer balance fails the precondition (no-op). -/
def lawInsufficientBalanceNoop : TestCase := {
  name := "GP.3.4 law: insufficient signer balance is a kernel no-op"
  body := do
    let s : State := setBalance emptyState gasRes delegateA 30
    -- gasAmount 40 > balance 30: precondition fails.
    let t := Laws.topUpActionBudgetFor recipientR delegateA gasRes 40 7 poolActor
    let s' := step_impl s t
    assertEq (expected := 30) (actual := getBalance s' gasRes delegateA) "no debit on underflow"
    assertEq (expected := 0) (actual := getBalance s' gasRes poolActor) "no credit on underflow"
}

/-- A different resource is untouched by the gas-resource top-up. -/
def lawOtherResourceUntouched : TestCase := {
  name := "GP.3.4 law: other resource untouched"
  body := do
    let s : State := setBalance (setBalance emptyState gasRes delegateA 100) 2 delegateA 77
    let t := Laws.topUpActionBudgetFor recipientR delegateA gasRes 40 7 poolActor
    let s' := step_impl s t
    assertEq (expected := 77) (actual := getBalance s' 2 delegateA) "resource 2 unchanged"
}

/-! ## Admission gate -/

/-- Happy path: the recipient whitelisted the signer, so admission
    succeeds and the recipient's budget is credited by
    `budgetIncrement`. -/
def admitHappyPath : TestCase := {
  name := "GP.3.4 admit: whitelisted delegate succeeds, recipient budget += increment"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | some es' =>
        let preBudget := EpochBudgetState.currentBudget es.epochBudgets recipientR 1 5
        let postBudget := EpochBudgetState.currentBudget es'.epochBudgets recipientR 1 5
        assertEq (expected := preBudget + 9) (actual := postBudget) "recipient budget += 9"
    | none => throw <| IO.userError "whitelisted delegated top-up unexpectedly rejected"
}

/-- Default-deny: with no consent clause, admission is rejected. -/
def admitUnauthorizedRejected : TestCase := {
  name := "GP.3.4 admit: unauthorized delegate rejected (default-deny)"
  body := do
    let es := mkBase 5 1 1  -- no consent declared
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | none => pure ()
    | some _ => throw <| IO.userError "unauthorized delegated top-up unexpectedly admitted"
}

/-- Revocation lifecycle: consent granted ⇒ admitted; after the
    recipient revokes their policy, the same delegate is rejected. -/
def admitRevocationLifecycle : TestCase := {
  name := "GP.3.4 admit: declare → admitted → revoke → rejected"
  body := do
    let es0 := withConsent (mkBase 5 1 1) recipientR [delegateA]
    let st1 := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es0
    match ← admit es0 st1 with
    | some _ => pure ()
    | none => throw <| IO.userError "pre-revoke delegated top-up rejected"
    -- Recipient revokes their local policy (clears the allowTopUpFrom clause).
    let esRevoked := { es0 with localPolicies := es0.localPolicies.revoke recipientR }
    let st2 := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA esRevoked
    match ← admit esRevoked st2 with
    | none => pure ()
    | some _ => throw <| IO.userError "post-revoke delegated top-up unexpectedly admitted"
}

/-- Multi-delegate: a recipient whitelisting both A and B accepts a
    top-up from either. -/
def admitMultiDelegate : TestCase := {
  name := "GP.3.4 admit: multi-delegate whitelist accepts each delegate"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA, delegateB]
    let stA := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    let stB := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateB es
    match ← admit es stA with
    | some _ => pure ()
    | none => throw <| IO.userError "delegate A rejected under multi-delegate consent"
    match ← admit es stB with
    | some _ => pure ()
    | none => throw <| IO.userError "delegate B rejected under multi-delegate consent"
}

/-- Self-delegation (`recipient = signer`) is rejected by the gate
    even if the signer "whitelisted themselves". -/
def admitSelfDelegationRejected : TestCase := {
  name := "GP.3.4 admit: self-delegation rejected by gate"
  body := do
    -- delegateA whitelists itself; still rejected (recipient ≠ signer).
    let es := withConsent (mkBase 5 1 1) delegateA [delegateA]
    let st := mkSignedAction (delegatedTopupAction delegateA 40 9) delegateA es
    match ← admit es st with
    | none => pure ()
    | some _ => throw <| IO.userError "self-delegation unexpectedly admitted"
}

/-- Insufficient gas balance is rejected by the gate. -/
def admitInsufficientGasRejected : TestCase := {
  name := "GP.3.4 admit: insufficient gas rejected"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    -- delegateA holds 1000; request 2000 > balance.
    let st := mkSignedAction (delegatedTopupAction recipientR 2000 9) delegateA es
    match ← admit es st with
    | none => pure ()
    | some _ => throw <| IO.userError "insufficient-gas delegated top-up unexpectedly admitted"
}

/-- Zero gas is rejected by the gate (defends free-budget). -/
def admitZeroGasRejected : TestCase := {
  name := "GP.3.4 admit: zero gas rejected"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    let st := mkSignedAction (delegatedTopupAction recipientR 0 9) delegateA es
    match ← admit es st with
    | none => pure ()
    | some _ => throw <| IO.userError "zero-gas delegated top-up unexpectedly admitted"
}

/-- Self-pool (`signer = poolActor`) is rejected by the gate. -/
def admitSelfPoolRejected : TestCase := {
  name := "GP.3.4 admit: self-pool (signer = poolActor) rejected"
  body := do
    -- poolActor signs; recipient whitelists poolActor.  The kernel step
    -- nets zero (debit/credit poolActor); the gate's `signer ≠ pa`
    -- conjunct rejects.  poolActor needs a gas balance to even reach
    -- the gate's balance check; give it one via a custom base.
    let base : State := setBalance emptyState gasRes poolActor 1000
    let es0 : ExtendedState :=
      { (mkBase 5 1 1) with base := base }
    let es := withConsent es0 recipientR [poolActor]
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) poolActor es
    match ← admit es st with
    | none => pure ()
    | some _ => throw <| IO.userError "self-pool delegated top-up unexpectedly admitted"
}

/-- bridgeActor as signer is rejected by the gate (defence in depth). -/
def admitBridgeActorRejected : TestCase := {
  name := "GP.3.4 admit: bridgeActor signer rejected"
  body := do
    let base : State := setBalance emptyState gasRes Bridge.bridgeActor 1000
    let es0 : ExtendedState := { (mkBase 5 1 1) with base := base }
    let es := withConsent es0 recipientR [Bridge.bridgeActor]
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) Bridge.bridgeActor es
    match ← admit es st with
    | none => pure ()
    | some _ => throw <| IO.userError "bridgeActor delegated top-up unexpectedly admitted"
}

/-- Sequential delegated top-ups accumulate the recipient's budget. -/
def admitSequentialAccumulates : TestCase := {
  name := "GP.3.4 admit: sequential delegated top-ups accumulate recipient budget"
  body := do
    let es0 := withConsent (mkBase 5 1 1) recipientR [delegateA]
    let st1 := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es0
    match ← admit es0 st1 with
    | some es1 =>
        let st2 := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es1
        match ← admit es1 st2 with
        | some es2 =>
            let preBudget := EpochBudgetState.currentBudget es0.epochBudgets recipientR 1 5
            let postBudget := EpochBudgetState.currentBudget es2.epochBudgets recipientR 1 5
            assertEq (expected := preBudget + 18) (actual := postBudget) "recipient budget += 9 + 9"
        | none => throw <| IO.userError "second sequential top-up rejected"
    | none => throw <| IO.userError "first sequential top-up rejected"
}

/-- Cross-delegate isolation: A funding R doesn't change B's budget. -/
def admitCrossDelegateIsolation : TestCase := {
  name := "GP.3.4 admit: cross-delegate isolation (A→R leaves B's budget unchanged)"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | some es' =>
        let bPre := EpochBudgetState.currentBudget es.epochBudgets delegateB 1 5
        let bPost := EpochBudgetState.currentBudget es'.epochBudgets delegateB 1 5
        assertEq (expected := bPre) (actual := bPost) "delegate B budget unchanged"
    | none => throw <| IO.userError "delegated top-up rejected"
}

/-- The signer's gas balance is debited at the kernel level under a
    successful delegated top-up admission. -/
def admitSignerBalanceDebited : TestCase := {
  name := "GP.3.4 admit: signer gas balance debited on success"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | some es' =>
        assertEq (expected := 960) (actual := getBalance es'.base gasRes delegateA)
          "signer 1000-40"
        assertEq (expected := 40) (actual := getBalance es'.base gasRes poolActor)
          "pool 0+40"
    | none => throw <| IO.userError "delegated top-up rejected"
}

/-- A successful delegated top-up does not credit the recipient's
    kernel *balance* (only its epoch budget). -/
def admitRecipientBalanceUnchanged : TestCase := {
  name := "GP.3.4 admit: recipient kernel balance unchanged on success"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | some es' =>
        assertEq (expected := 0) (actual := getBalance es'.base gasRes recipientR)
          "recipient balance still 0"
    | none => throw <| IO.userError "delegated top-up rejected"
}

/-! ## Bridge-aware mirror -/

/-- Build the bridge-aware witness for a `topUpActionBudgetFor`
    action from its kernel-level `AdmissibleWith` witness.  Every
    bridge-specific conjunct is vacuous for a non-deposit /
    non-registration / non-bridge-only action. -/
def mkBridgeWitness
    (es : ExtendedState) (recipient : ActorId) (ga bi : Nat)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : AdmissibleWith mockVerify policy testDeploymentId es
          ⟨.topUpActionBudgetFor recipient gasRes ga bi poolActor, signer, nonce, sig⟩) :
    BridgeAdmissibleWith mockVerify policy testDeploymentId es
      ⟨.topUpActionBudgetFor recipient gasRes ga bi poolActor, signer, nonce, sig⟩ :=
  ⟨h,
   fun _ _ _ _ heq => by simp at heq,
   fun _ _ _ _ _ _ _ heq => by simp at heq,
   fun _ _ heq => by simp at heq,
   fun hbo => by simp [Action.isBridgeOnly] at hbo⟩

/-- Admit through the bridge-aware budget gate, throwing on a
    test-setup `AdmissibleWith` failure. -/
def admitBridge (es : ExtendedState) (recipient : ActorId) (ga bi : Nat)
    (signer : ActorId) : IO (Option ExtendedState) := do
  let st := mkSignedAction (delegatedTopupAction recipient ga bi) signer es
  -- `st.action`/`st.signer`/etc. reduce to the literal components.
  match (inferInstance : Decidable (AdmissibleWith mockVerify policy testDeploymentId es st)) with
  | .isTrue h =>
      let hb := mkBridgeWitness es recipient ga bi signer st.nonce st.sig h
      pure (apply_bridge_admissible_with_budget mockVerify policy testDeploymentId es st 0 hb)
  | .isFalse _ =>
      throw <| IO.userError "AdmissibleWith mockVerify rejected (bridge test-setup error)"

/-- Bridge-aware happy path mirrors the kernel-only entry. -/
def bridgeAdmitHappyPath : TestCase := {
  name := "GP.3.4 bridge-admit: whitelisted delegate succeeds, recipient budget += increment"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    match ← admitBridge es recipientR 40 9 delegateA with
    | some es' =>
        let preBudget := EpochBudgetState.currentBudget es.epochBudgets recipientR 1 5
        let postBudget := EpochBudgetState.currentBudget es'.epochBudgets recipientR 1 5
        assertEq (expected := preBudget + 9) (actual := postBudget) "recipient budget += 9 (bridge path)"
    | none => throw <| IO.userError "bridge-aware delegated top-up unexpectedly rejected"
}

/-- Bridge-aware default-deny rejection mirrors the kernel-only entry. -/
def bridgeAdmitUnauthorizedRejected : TestCase := {
  name := "GP.3.4 bridge-admit: unauthorized delegate rejected (default-deny)"
  body := do
    let es := mkBase 5 1 1
    match ← admitBridge es recipientR 40 9 delegateA with
    | none => pure ()
    | some _ => throw <| IO.userError "bridge-aware unauthorized top-up unexpectedly admitted"
}

/-! ## Encoder + event coverage -/

/-- The new `Action` constructor round-trips through the CBE codec. -/
def actionRoundTrips : TestCase := {
  name := "GP.3.4: topUpActionBudgetFor Action round-trips"
  body := do
    let a : Action := .topUpActionBudgetFor recipientR gasRes 40 9 poolActor
    let bytes := Encodable.encode (T := Action) a
    match Encodable.decode (T := Action) bytes with
    | .ok (a', []) => assertEq (expected := a) (actual := a') "action round-trip"
    | .ok (_, _)   => throw <| IO.userError "action decode left residual stream"
    | .error e     => throw <| IO.userError s!"action decode failed: {repr e}"
}

/-- The action's CBE tag is the frozen index 21. -/
def actionTagIs21 : TestCase := {
  name := "GP.3.4: topUpActionBudgetFor Action.tag is 21"
  body := do
    assertEq (expected := 21)
      (actual := Action.tag (.topUpActionBudgetFor recipientR gasRes 40 9 poolActor))
      "frozen index 21"
}

/-- The new `allowTopUpFrom` clause round-trips through the CBE codec. -/
def clauseRoundTrips : TestCase := {
  name := "GP.3.4: allowTopUpFrom clause round-trips"
  body := do
    let c : LocalPolicyClause := .allowTopUpFrom [delegateA, delegateB]
    let bytes := Encodable.encode (T := LocalPolicyClause) c
    match Encodable.decode (T := LocalPolicyClause) bytes with
    | .ok (c', []) => assertEq (expected := c) (actual := c') "clause round-trip"
    | .ok (_, _)   => throw <| IO.userError "clause decode left residual stream"
    | .error e     => throw <| IO.userError s!"clause decode failed: {repr e}"
}

/-- A whole `LocalPolicy` carrying an `allowTopUpFrom` clause
    round-trips. -/
def policyRoundTrips : TestCase := {
  name := "GP.3.4: LocalPolicy with allowTopUpFrom round-trips"
  body := do
    let p : LocalPolicy := { clauses := [.allowTopUpFrom [delegateA], .denyTags [0]] }
    let bytes := Encodable.encode (T := LocalPolicy) p
    match Encodable.decode (T := LocalPolicy) bytes with
    | .ok (p', []) => assertEq (expected := p) (actual := p') "policy round-trip"
    | .ok (_, _)   => throw <| IO.userError "policy decode left residual stream"
    | .error e     => throw <| IO.userError s!"policy decode failed: {repr e}"
}

/-- `extractEvents` emits a `delegatedActionBudgetTopUp` event (plus
    the kernel-level balance changes) for an admitted delegated
    top-up. -/
def eventExtraction : TestCase := {
  name := "GP.3.4: extractEvents emits delegatedActionBudgetTopUp"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | some es' =>
        let evts := extractEvents es es' st
        let hasSemantic := evts.any (fun e =>
          match e with
          | .delegatedActionBudgetTopUp r s gr ga bi pa =>
              r == recipientR && s == delegateA && gr == gasRes &&
              ga == 40 && bi == 9 && pa == poolActor
          | _ => false)
        assert hasSemantic "delegatedActionBudgetTopUp event present"
        -- The signer's gas-balance change is also emitted.
        let hasSignerBal := evts.any (fun e =>
          match e with
          | .balanceChanged gr a _ newV => gr == gasRes && a == delegateA && newV == 960
          | _ => false)
        assert hasSignerBal "signer balanceChanged event present"
    | none => throw <| IO.userError "delegated top-up rejected"
}

/-- The `delegatedActionBudgetTopUp` event's tag is the frozen index 19. -/
def eventTagIs19 : TestCase := {
  name := "GP.3.4: delegatedActionBudgetTopUp Event.tag is 19"
  body := do
    assertEq (expected := 19)
      (actual := Event.tag (.delegatedActionBudgetTopUp recipientR delegateA gasRes 40 9 poolActor))
      "frozen event index 19"
}

/-! ## Term-level API stability -/

/-- `delegatedTopUp_grants_budget_to_recipient` is term-level callable. -/
def grantsApi : TestCase := {
  name := "GP.3.4: delegatedTopUp_grants_budget_to_recipient API stable"
  body := do
    let _ := @delegatedTopUp_grants_budget_to_recipient
    assert true "API exists"
}

/-- `delegatedTopUp_requires_allowTopUpFrom` is term-level callable. -/
def requiresApi : TestCase := {
  name := "GP.3.4: delegatedTopUp_requires_allowTopUpFrom API stable"
  body := do
    let _ := @delegatedTopUp_requires_allowTopUpFrom
    assert true "API exists"
}

/-- `delegatedTopUp_signer_balance_debited` is term-level callable. -/
def signerDebitedApi : TestCase := {
  name := "GP.3.4: delegatedTopUp_signer_balance_debited API stable"
  body := do
    let _ := @delegatedTopUp_signer_balance_debited
    assert true "API exists"
}

/-- `delegatedTopUpConsentBool_iff` is term-level callable. -/
def consentIffApi : TestCase := {
  name := "GP.3.4: delegatedTopUpConsentBool_iff API stable"
  body := do
    let _ := @delegatedTopUpConsentBool_iff
    assert true "API exists"
}

/-- The law's `IsConservative` instance resolves for the delegated
    top-up transition. -/
def lawConservativeInstance : TestCase := {
  name := "GP.3.4 law: IsConservative instance resolves"
  body := do
    let _ : IsConservative (Laws.topUpActionBudgetFor recipientR delegateA gasRes 40 9 poolActor) :=
      inferInstance
    assert true "instance resolved"
}

/-- The law's `LocalTo [gasRes]` instance resolves. -/
def lawLocalToInstance : TestCase := {
  name := "GP.3.4 law: LocalTo [gasRes] instance resolves"
  body := do
    let _ : LocalTo [gasRes] (Laws.topUpActionBudgetFor recipientR delegateA gasRes 40 9 poolActor) :=
      inferInstance
    assert true "instance resolved"
}

/-- The action's `RegistryPreserving` instance resolves. -/
def actionRegistryPreservingInstance : TestCase := {
  name := "GP.3.4: topUpActionBudgetFor RegistryPreserving instance resolves"
  body := do
    let _ : RegistryPreserving (.topUpActionBudgetFor recipientR gasRes 40 9 poolActor) :=
      inferInstance
    assert true "instance resolved"
}

/-! ## Additional coverage (audit pass) -/

/-- The signer (delegate) also pays one action-budget unit
    (`actionCost`): a successful delegated top-up consumes the
    *signer*'s budget by `actionCost`, distinct from the recipient's
    grant.  The delegate does not get a free action. -/
def admitSignerBudgetConsumed : TestCase := {
  name := "GP.3.4 admit: signer budget consumed by actionCost (delegate pays an action unit)"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | some es' =>
        let sPre := EpochBudgetState.currentBudget es.epochBudgets delegateA 1 5
        let sPost := EpochBudgetState.currentBudget es'.epochBudgets delegateA 1 5
        assertEq (expected := sPre - 1) (actual := sPost) "signer budget -= actionCost (1)"
    | none => throw <| IO.userError "delegated top-up rejected"
}

/-- Free-tier interaction (plan scenario 10): a recipient with zero
    stored budget, at a fresh epoch with `freeTier = 5`, receives the
    `freeTier` floor plus the delegated `budgetIncrement` — absolute
    value `5 + 9 = 14`. -/
def admitFreeTierInteraction : TestCase := {
  name := "GP.3.4 admit: recipient with zero stored budget gets freeTier + increment"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    -- Pre-grant: recipient has no epochBudget entry; at epoch 1 the
    -- free-tier floor gives currentBudget = 5.
    assertEq (expected := 5)
      (actual := EpochBudgetState.currentBudget es.epochBudgets recipientR 1 5)
      "recipient free-tier floor = 5 pre-grant"
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | some es' =>
        assertEq (expected := 14)
          (actual := EpochBudgetState.currentBudget es'.epochBudgets recipientR 1 5)
          "recipient budget = freeTier(5) + increment(9) = 14"
    | none => throw <| IO.userError "delegated top-up rejected"
}

/-- The delegate must be able to afford the action-budget cost: with
    `freeTier = 0` at epoch 0 the delegate's budget is exhausted (0 <
    actionCost), so even a consented, gas-funded delegated top-up is
    rejected at the consume step. -/
def admitDelegateBudgetExhaustedRejected : TestCase := {
  name := "GP.3.4 admit: delegate with exhausted budget rejected"
  body := do
    -- freeTier=0, actionCost=1, currentEpoch=0: delegateA's budget is 0.
    let es := withConsent (mkBase 0 1 0) recipientR [delegateA]
    -- Sanity: the delegate's budget is indeed below actionCost.
    assertEq (expected := 0)
      (actual := EpochBudgetState.currentBudget es.epochBudgets delegateA 0 0)
      "delegate budget exhausted"
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | none => pure ()
    | some _ => throw <| IO.userError "delegate-budget-exhausted top-up unexpectedly admitted"
}

/-- An `allowTopUpFrom []` clause (empty whitelist) consents to no
    one — the boundary of the default-deny semantics. -/
def consentEmptyWhitelist : TestCase := {
  name := "GP.3.4: empty allowTopUpFrom whitelist consents to no one"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR []
    assertEq (expected := false)
      (actual := delegatedTopUpConsentBool es recipientR delegateA)
      "empty whitelist => no consent"
    -- And admission is correspondingly rejected.
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | none => pure ()
    | some _ => throw <| IO.userError "empty-whitelist top-up unexpectedly admitted"
}

/-- Consent is found even when the `allowTopUpFrom` clause is mixed
    among unrelated restrictive clauses in the recipient's policy. -/
def consentMixedClauses : TestCase := {
  name := "GP.3.4: consent found amid mixed clauses"
  body := do
    let mixed : LocalPolicy :=
      { clauses := [.denyTags [0], .allowTopUpFrom [delegateA], .capAmount gasRes 5] }
    let es := { (mkBase 5 1 1) with
                localPolicies := (mkBase 5 1 1).localPolicies.declare recipientR mixed }
    assertEq (expected := true)
      (actual := delegatedTopUpConsentBool es recipientR delegateA)
      "consent found amid denyTags / capAmount"
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | some _ => pure ()
    | none => throw <| IO.userError "mixed-clause consented top-up unexpectedly rejected"
}

/-- **Recipient-scoping (security-critical):** consent is read from
    the *recipient's* policy, NOT the signer's.  Here the signer
    grants *itself* `allowTopUpFrom [signer]`, but the (distinct)
    recipient declares nothing — so the top-up must be rejected.  A
    signer cannot authorise top-ups *to others* by editing its own
    policy. -/
def admitRecipientScopedConsent : TestCase := {
  name := "GP.3.4 admit: consent reads the recipient's policy, not the signer's"
  body := do
    -- delegateA whitelists itself; recipientR (≠ delegateA) has no policy.
    let es := withConsent (mkBase 5 1 1) delegateA [delegateA]
    assertEq (expected := false)
      (actual := delegatedTopUpConsentBool es recipientR delegateA)
      "recipient's (empty) policy governs — signer's self-grant is irrelevant"
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | none => pure ()
    | some _ =>
        throw <| IO.userError
          "signer self-grant wrongly authorised a top-up to a non-consenting recipient"
}

/-- The signer's epoch budget is consumed by `actionCost` on a
    successful delegated top-up (delegate is not granted a free
    action); pinned absolutely (`5 → 4` at freeTier 5, actionCost 1). -/
def admitSignerBudgetAbsolute : TestCase := {
  name := "GP.3.4 admit: signer budget 5 → 4 (free-tier floor minus actionCost)"
  body := do
    let es := withConsent (mkBase 5 1 1) recipientR [delegateA]
    let st := mkSignedAction (delegatedTopupAction recipientR 40 9) delegateA es
    match ← admit es st with
    | some es' =>
        assertEq (expected := 4)
          (actual := EpochBudgetState.currentBudget es'.epochBudgets delegateA 1 5)
          "signer budget = freeTier(5) - actionCost(1) = 4"
    | none => throw <| IO.userError "delegated top-up rejected"
}

/-! ## Law `freezePreserving` for a non-empty resource set -/

/-- `topUpActionBudgetFor` at `gasRes = 1` preserves freeze for the
    non-empty set `[2]` (a resource it never touches). -/
def lawFreezePreservingNonEmpty : TestCase := {
  name := "GP.3.4 law: freezePreserving [2] resolves (gasRes ∉ [2])"
  body := do
    let _ : FreezePreserving [2]
        (Laws.topUpActionBudgetFor recipientR delegateA gasRes 40 9 poolActor) :=
      Laws.topUpActionBudgetFor_freezePreserving recipientR delegateA gasRes 40 9 poolActor
        [2] (by decide)
    assert true "non-empty freeze-set instance resolved"
}

/-! ## Term-level API stability for the audit-pass theorems -/

/-- `coherence_topUpActionBudgetFor` is term-level callable. -/
def coherenceApi : TestCase := {
  name := "GP.3.4: coherence_topUpActionBudgetFor API stable"
  body := do
    let _ := @LegalKernel.FaultProof.coherence_topUpActionBudgetFor
    assert true "API exists"
}

/-- `cellwrites_topUpActionBudgetFor` is term-level callable. -/
def cellwritesApi : TestCase := {
  name := "GP.3.4: cellwrites_topUpActionBudgetFor API stable"
  body := do
    let _ := @LegalKernel.FaultProof.cellwrites_topUpActionBudgetFor
    assert true "API exists"
}

/-- `delegatedTopUp_signer_budget_consumed` is term-level callable. -/
def signerBudgetConsumedApi : TestCase := {
  name := "GP.3.4: delegatedTopUp_signer_budget_consumed API stable"
  body := do
    let _ := @delegatedTopUp_signer_budget_consumed
    assert true "API exists"
}

/-- `delegatedTopUp_budget_locality` is term-level callable. -/
def budgetLocalityApi : TestCase := {
  name := "GP.3.4: delegatedTopUp_budget_locality API stable"
  body := do
    let _ := @delegatedTopUp_budget_locality
    assert true "API exists"
}

/-- The bridge-aware (production-path) `requires_allowTopUpFrom` is
    term-level callable. -/
def bridgeRequiresApi : TestCase := {
  name := "GP.3.4: delegatedTopUp_requires_allowTopUpFrom_bridge API stable"
  body := do
    let _ := @LegalKernel.Bridge.delegatedTopUp_requires_allowTopUpFrom_bridge
    assert true "API exists"
}

/-- The bridge-aware (production-path) `grants_budget_to_recipient` is
    term-level callable. -/
def bridgeGrantsApi : TestCase := {
  name := "GP.3.4: delegatedTopUp_grants_budget_to_recipient_bridge API stable"
  body := do
    let _ := @LegalKernel.Bridge.delegatedTopUp_grants_budget_to_recipient_bridge
    assert true "API exists"
}

/-- The bridge-aware `signer_budget_consumed` (production path) is
    term-level callable. -/
def bridgeSignerBudgetConsumedApi : TestCase := {
  name := "GP.3.4: delegatedTopUp_signer_budget_consumed_bridge API stable"
  body := do
    let _ := @LegalKernel.Bridge.delegatedTopUp_signer_budget_consumed_bridge
    assert true "API exists"
}

/-- The bridge-aware `budget_locality` (production path) is term-level
    callable. -/
def bridgeBudgetLocalityApi : TestCase := {
  name := "GP.3.4: delegatedTopUp_budget_locality_bridge API stable"
  body := do
    let _ := @LegalKernel.Bridge.delegatedTopUp_budget_locality_bridge
    assert true "API exists"
}

/-- The budget-gate bridge/kernel agreement lemma + its two
    corollaries (the DRY foundation lifting every GP.3.2 / GP.3.4
    budget property to the production path) are term-level callable. -/
def bridgeAgreementApi : TestCase := {
  name := "GP.3.2/3.4: bridge/kernel budget-gate agreement lemma + corollaries API stable"
  body := do
    let _ := @LegalKernel.Bridge.apply_bridge_admissible_with_budget_epochBudgets_eq
    let _ := @LegalKernel.Bridge.apply_bridge_admissible_with_budget_none_iff
    let _ := @LegalKernel.Bridge.apply_bridge_admissible_with_budget_kernel_epochBudgets
    assert true "API exists"
}

/-! ## Suite -/

/-- All GP.3.4 delegated-top-up test cases. -/
def tests : List TestCase :=
  [ -- Consent data layer
    consentTrueWhenWhitelisted
  , consentFalseByDefault
  , consentFalseForNonListed
  , consentMultiDelegate
  , consentEmptyWhitelist
  , consentMixedClauses
    -- Law kernel-leg
  , lawSignerDebited
  , lawPoolCredited
  , lawRecipientBalanceUntouched
  , lawConserves
  , lawSelfDelegationNoop
  , lawInsufficientBalanceNoop
  , lawOtherResourceUntouched
    -- Admission gate
  , admitHappyPath
  , admitSignerBudgetConsumed
  , admitFreeTierInteraction
  , admitDelegateBudgetExhaustedRejected
  , admitUnauthorizedRejected
  , admitRevocationLifecycle
  , admitMultiDelegate
  , admitSelfDelegationRejected
  , admitRecipientScopedConsent
  , admitInsufficientGasRejected
  , admitZeroGasRejected
  , admitSelfPoolRejected
  , admitBridgeActorRejected
  , admitSequentialAccumulates
  , admitCrossDelegateIsolation
  , admitSignerBalanceDebited
  , admitSignerBudgetAbsolute
  , admitRecipientBalanceUnchanged
    -- Bridge-aware mirror
  , bridgeAdmitHappyPath
  , bridgeAdmitUnauthorizedRejected
    -- Encoder + events
  , actionRoundTrips
  , actionTagIs21
  , clauseRoundTrips
  , policyRoundTrips
  , eventExtraction
  , eventTagIs19
    -- Law freeze-preservation (non-empty set)
  , lawFreezePreservingNonEmpty
    -- API stability + instances
  , grantsApi
  , requiresApi
  , signerDebitedApi
  , consentIffApi
  , signerBudgetConsumedApi
  , budgetLocalityApi
  , bridgeRequiresApi
  , bridgeGrantsApi
  , bridgeSignerBudgetConsumedApi
  , bridgeBudgetLocalityApi
  , bridgeAgreementApi
  , coherenceApi
  , cellwritesApi
  , lawConservativeInstance
  , lawLocalToInstance
  , actionRegistryPreservingInstance
  ]

end DelegatedTopup
end LegalKernel.Test.Authority

/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Authority.LocalPolicyAdmissibility — end-to-end
acceptance tests for Workstream LP.

Workstream LP work unit LP.11.  Twelve end-to-end scenarios using
the `mockVerify` fixture from `Test/MockCrypto.lean` to construct
value-level admissibility witnesses across the full LP pipeline:

  1. Declare → constrained → revoke → permitted (full lifecycle).
  2. Cross-actor independence (A's policy doesn't affect B).
  3. Meta-actions self-exempt (denyTags 15/16 doesn't lock out).
  4. requireRecipientIn enforcement (positive).
  5. requireRecipientIn enforcement (negative).
  6. capAmount enforcement (positive + negative + boundary).
  7. Cross-resource isolation (capAmount r doesn't affect r').
  8. Replay protection (re-applying a successful action fails).
  9. Multi-clause conjunction (every clause must permit).
  10. Re-declaration overwrites prior policy.
  11. Bridge-actor cannot declare local policies.
  12. Snapshot survival (declared policy survives encode/decode).
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Authority
namespace LocalPolicyAdmissibility

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

/-! ## Test fixtures -/

/-- Demo authority policy: every signer is authorised for every action. -/
def policy : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- Deployment id (non-empty so cross-deployment-replay tests are
    meaningful). -/
def testDeploymentId : ByteArray :=
  ByteArray.mk #[0xCA, 0xFE, 0xBA, 0xBE]

/-- Pre-state: actor 1 (alice) holds 1000 at resource 1; actor 2
    (bob) holds 500.  Both actors registered with mock pubkeys.
    The bridge actor (id 0) is also registered. -/
def setupES : ExtendedState :=
  let base0 : LegalKernel.State :=
    setBalance (setBalance emptyState 1 1 1000) 1 2 500
  let registry := ((KeyRegistry.empty.register 0 (mockPubKey 0)).register
    1 (mockPubKey 1)).register 2 (mockPubKey 2)
  { base := base0, nonces := NonceState.empty, registry := registry }

/-- Build a mock-signed `SignedAction` for the given action and signer. -/
def mkSignedAction (action : Action) (signer : ActorId) (es : ExtendedState) :
    SignedAction :=
  let nonce := expectsNonce es signer
  let msg := signingInput action signer nonce testDeploymentId
  let sig := mockSign (mockPubKey signer.toNat) msg
  ⟨action, signer, nonce, sig⟩

/-! ## LP.11 scenarios -/

/-- Scenario 1: full declare-then-revoke lifecycle.  Alice transfers
    while unrestricted; declares `denyTags [0]`; transfer fails;
    revokes; transfer succeeds again.  This is the headline LP
    walkthrough from §15 of the actor-scoped policies plan. -/
def scenario1_lifecycle : TestCase := {
  name := "scenario 1: declare → constrained → revoke → permitted"
  body := do
    let es0 := setupES

    -- Step 1: alice transfers 100 to bob (pre-policy).
    let st1 := mkSignedAction (.transfer 1 1 2 100) 1 es0
    let h1 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es0 st1) :=
      inferInstance
    let es1 ← match h1 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es0 st1 h)
      | .isFalse _ => throw <| IO.userError "step 1 transfer rejected (pre-policy)"
    assertEq (expected := 900) (actual := getBalance es1.base 1 1) "step1 alice balance"

    -- Step 2: alice declares `denyTags [0]` (= deny transfers).
    let denyPolicy : LocalPolicy := { clauses := [.denyTags [0]] }
    let st2 := mkSignedAction (.declareLocalPolicy denyPolicy) 1 es1
    let h2 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st2) :=
      inferInstance
    let es2 ← match h2 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es1 st2 h)
      | .isFalse _ => throw <| IO.userError "step 2 declare rejected"
    assertEq (expected := denyPolicy) (actual := es2.localPolicies.lookup 1)
      "step2 declared policy"

    -- Step 3: alice attempts another transfer; should be inadmissible.
    let st3 := mkSignedAction (.transfer 1 1 2 100) 1 es2
    let h3 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es2 st3) :=
      inferInstance
    match h3 with
      | .isTrue _ => throw <| IO.userError "step 3 transfer should be rejected by policy"
      | .isFalse _ => pure ()

    -- Step 4: alice revokes.
    let st4 := mkSignedAction .revokeLocalPolicy 1 es2
    let h4 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es2 st4) :=
      inferInstance
    let es4 ← match h4 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es2 st4 h)
      | .isFalse _ => throw <| IO.userError "step 4 revoke rejected"
    assertEq (expected := LocalPolicy.empty) (actual := es4.localPolicies.lookup 1)
      "step4 policy revoked"

    -- Step 5: alice transfers again — should succeed.
    let st5 := mkSignedAction (.transfer 1 1 2 100) 1 es4
    let h5 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es4 st5) :=
      inferInstance
    let es5 ← match h5 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es4 st5 h)
      | .isFalse _ => throw <| IO.userError "step 5 post-revoke transfer rejected"
    assertEq (expected := 800) (actual := getBalance es5.base 1 1) "step5 alice balance"
}

/-- Scenario 2: cross-actor independence.  Alice declares a
    restrictive policy; bob's actions are unaffected. -/
def scenario2_crossActor : TestCase := {
  name := "scenario 2: cross-actor independence"
  body := do
    let es0 := setupES
    -- Alice declares deny-all-transfers.
    let st1 := mkSignedAction
      (.declareLocalPolicy { clauses := [.denyTags [0]] }) 1 es0
    let h1 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es0 st1) :=
      inferInstance
    let es1 ← match h1 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es0 st1 h)
      | .isFalse _ => throw <| IO.userError "alice's declare rejected"
    -- Bob (actor 2) transfers — should succeed (his localPolicies is empty).
    let st2 := mkSignedAction (.transfer 1 2 1 50) 2 es1
    let h2 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st2) :=
      inferInstance
    match h2 with
      | .isTrue _ => pure ()
      | .isFalse _ => throw <| IO.userError "bob's transfer rejected — cross-actor isolation broken"
}

/-- Scenario 3: meta-actions self-exempt.  Alice declares a policy
    that bans even the meta actions (`denyTags [15, 16]`); she can
    STILL declare and revoke (the `localPolicy_meta_action_independent`
    theorem at the value level). -/
def scenario3_metaSelfExempt : TestCase := {
  name := "scenario 3: meta-actions self-exempt (lockout-prevention)"
  body := do
    let es0 := setupES
    -- Alice declares "deny everything including meta-actions".
    let denyEverything : LocalPolicy :=
      { clauses := [.denyTags [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]] }
    let st1 := mkSignedAction (.declareLocalPolicy denyEverything) 1 es0
    let h1 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es0 st1) :=
      inferInstance
    let es1 ← match h1 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es0 st1 h)
      | .isFalse _ =>
        throw <| IO.userError "step 1 declare rejected — meta-action exemption broken!"

    -- Alice declares another policy (meta-action; should still succeed).
    let st2 := mkSignedAction
      (.declareLocalPolicy { clauses := [.denyTags [0]] }) 1 es1
    let h2 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st2) :=
      inferInstance
    let es2 ← match h2 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es1 st2 h)
      | .isFalse _ =>
        throw <| IO.userError "step 2 re-declare rejected — meta-action exemption broken!"

    -- Alice revokes (meta-action; should succeed).
    let st3 := mkSignedAction .revokeLocalPolicy 1 es2
    let h3 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es2 st3) :=
      inferInstance
    match h3 with
      | .isTrue _ => pure ()
      | .isFalse _ =>
        throw <| IO.userError "step 3 revoke rejected — meta-action exemption broken!"
}

/-- Scenario 4: `requireRecipientIn` enforcement (positive). -/
def scenario4_requireRecipient_positive : TestCase := {
  name := "scenario 4: requireRecipientIn permits allowed recipient"
  body := do
    let es0 := setupES
    -- Alice declares: only allow transfers to actor 2.
    let p : LocalPolicy := { clauses := [.requireRecipientIn 1 [2]] }
    let st1 := mkSignedAction (.declareLocalPolicy p) 1 es0
    let h1 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es0 st1) :=
      inferInstance
    let es1 ← match h1 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es0 st1 h)
      | .isFalse _ => throw <| IO.userError "declare rejected"
    -- Transfer to actor 2: should succeed.
    let st2 := mkSignedAction (.transfer 1 1 2 50) 1 es1
    let h2 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st2) :=
      inferInstance
    match h2 with
      | .isTrue _ => pure ()
      | .isFalse _ => throw <| IO.userError "transfer to allowed recipient rejected"
}

/-- Scenario 5: `requireRecipientIn` enforcement (negative). -/
def scenario5_requireRecipient_negative : TestCase := {
  name := "scenario 5: requireRecipientIn rejects disallowed recipient"
  body := do
    let es0 := setupES
    -- Alice declares: only allow transfers to actor 99 (not 2).
    let p : LocalPolicy := { clauses := [.requireRecipientIn 1 [99]] }
    let st1 := mkSignedAction (.declareLocalPolicy p) 1 es0
    let h1 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es0 st1) :=
      inferInstance
    let es1 ← match h1 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es0 st1 h)
      | .isFalse _ => throw <| IO.userError "declare rejected"
    -- Transfer to actor 2: should be rejected.
    let st2 := mkSignedAction (.transfer 1 1 2 50) 1 es1
    let h2 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st2) :=
      inferInstance
    match h2 with
      | .isTrue _ => throw <| IO.userError "transfer to disallowed recipient permitted"
      | .isFalse _ => pure ()
}

/-- Scenario 6: `capAmount` enforcement (positive + negative + boundary). -/
def scenario6_capAmount : TestCase := {
  name := "scenario 6: capAmount enforces ≤ max"
  body := do
    let es0 := setupES
    -- Alice declares: cap transfers at 100.
    let p : LocalPolicy := { clauses := [.capAmount 1 100] }
    let st1 := mkSignedAction (.declareLocalPolicy p) 1 es0
    let h1 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es0 st1) :=
      inferInstance
    let es1 ← match h1 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es0 st1 h)
      | .isFalse _ => throw <| IO.userError "declare rejected"
    -- Transfer 50: under cap, should succeed.
    let st2 := mkSignedAction (.transfer 1 1 2 50) 1 es1
    let h2 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st2) :=
      inferInstance
    match h2 with
      | .isTrue _ => pure ()
      | .isFalse _ => throw <| IO.userError "under-cap transfer rejected"
    -- Transfer 200: over cap, should be rejected.
    let st3 := mkSignedAction (.transfer 1 1 2 200) 1 es1
    let h3 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st3) :=
      inferInstance
    match h3 with
      | .isTrue _ => throw <| IO.userError "over-cap transfer permitted"
      | .isFalse _ => pure ()
    -- Transfer 100 (boundary inclusive): should succeed.
    let st4 := mkSignedAction (.transfer 1 1 2 100) 1 es1
    let h4 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st4) :=
      inferInstance
    match h4 with
      | .isTrue _ => pure ()
      | .isFalse _ => throw <| IO.userError "at-cap transfer rejected (boundary)"
}

/-- Scenario 7: cross-resource isolation. -/
def scenario7_crossResource : TestCase := {
  name := "scenario 7: capAmount on r doesn't constrain r'"
  body := do
    -- Add resource 2 funding for alice.
    let es0Init := setupES
    let es0 : ExtendedState :=
      { es0Init with base := setBalance es0Init.base 2 1 500 }
    -- Alice declares: cap on resource 1 only.
    let p : LocalPolicy := { clauses := [.capAmount 1 50] }
    let st1 := mkSignedAction (.declareLocalPolicy p) 1 es0
    let h1 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es0 st1) :=
      inferInstance
    let es1 ← match h1 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es0 st1 h)
      | .isFalse _ => throw <| IO.userError "declare rejected"
    -- Transfer 200 on resource 2: cross-resource, should succeed.
    let st2 := mkSignedAction (.transfer 2 1 2 200) 1 es1
    let h2 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st2) :=
      inferInstance
    match h2 with
      | .isTrue _ => pure ()
      | .isFalse _ =>
        throw <| IO.userError "cross-resource transfer rejected — isolation broken"
}

/-- Scenario 8: replay protection survives.  After a successful
    transfer, re-applying it at the post-state should fail. -/
def scenario8_replay : TestCase := {
  name := "scenario 8: replay impossible (nonce check)"
  body := do
    let es0 := setupES
    let st1 := mkSignedAction (.transfer 1 1 2 50) 1 es0
    let h1 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es0 st1) :=
      inferInstance
    let es1 ← match h1 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es0 st1 h)
      | .isFalse _ => throw <| IO.userError "step 1 transfer rejected"
    -- Re-apply at the post-state: must fail (nonce check).
    let h2 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st1) :=
      inferInstance
    match h2 with
      | .isTrue _ => throw <| IO.userError "replay succeeded — nonce check broken"
      | .isFalse _ => pure ()
}

/-- Scenario 9: multi-clause conjunction.  A policy with two clauses
    requires BOTH to permit. -/
def scenario9_multiClause : TestCase := {
  name := "scenario 9: multi-clause policy is conjunctive"
  body := do
    let es0 := setupES
    -- Alice declares: deny mints + cap transfers at 100.
    let p : LocalPolicy := { clauses := [.denyTags [1], .capAmount 1 100] }
    let st1 := mkSignedAction (.declareLocalPolicy p) 1 es0
    let h1 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es0 st1) :=
      inferInstance
    let es1 ← match h1 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es0 st1 h)
      | .isFalse _ => throw <| IO.userError "declare rejected"
    -- Transfer 50 (under cap, not a mint): should succeed.
    let st2 := mkSignedAction (.transfer 1 1 2 50) 1 es1
    let h2 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st2) :=
      inferInstance
    match h2 with
      | .isTrue _ => pure ()
      | .isFalse _ => throw <| IO.userError "permitted transfer rejected"
    -- Mint 50 (denied by denyTags): should fail.
    let st3 := mkSignedAction (.mint 1 1 50) 1 es1
    let h3 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st3) :=
      inferInstance
    match h3 with
      | .isTrue _ => throw <| IO.userError "mint permitted despite denyTags"
      | .isFalse _ => pure ()
    -- Transfer 200 (over cap): should fail.
    let st4 := mkSignedAction (.transfer 1 1 2 200) 1 es1
    let h4 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st4) :=
      inferInstance
    match h4 with
      | .isTrue _ => throw <| IO.userError "over-cap transfer permitted"
      | .isFalse _ => pure ()
}

/-- Scenario 10: re-declaration overwrites prior policy. -/
def scenario10_overwrite : TestCase := {
  name := "scenario 10: re-declaration overwrites prior policy"
  body := do
    let es0 := setupES
    -- Alice declares deny-mints.
    let p1 : LocalPolicy := { clauses := [.denyTags [1]] }
    let st1 := mkSignedAction (.declareLocalPolicy p1) 1 es0
    let h1 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es0 st1) :=
      inferInstance
    let es1 ← match h1 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es0 st1 h)
      | .isFalse _ => throw <| IO.userError "declare 1 rejected"
    assertEq (expected := p1) (actual := es1.localPolicies.lookup 1)
      "policy 1 active"
    -- Alice re-declares with deny-burns.
    let p2 : LocalPolicy := { clauses := [.denyTags [2]] }
    let st2 := mkSignedAction (.declareLocalPolicy p2) 1 es1
    let h2 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es1 st2) :=
      inferInstance
    let es2 ← match h2 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es1 st2 h)
      | .isFalse _ => throw <| IO.userError "declare 2 rejected"
    assertEq (expected := p2) (actual := es2.localPolicies.lookup 1)
      "policy 2 overwrote"
    -- Mint should NOW succeed (p1 banned, p2 doesn't).
    let st3 := mkSignedAction (.mint 1 1 50) 1 es2
    let h3 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es2 st3) :=
      inferInstance
    match h3 with
      | .isTrue _ => pure ()
      | .isFalse _ =>
        throw <| IO.userError "mint rejected despite p2 not banning it"
    -- Burn should now FAIL (p2 bans).
    let st4 := mkSignedAction (.burn 1 1 50) 1 es2
    let h4 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es2 st4) :=
      inferInstance
    match h4 with
      | .isTrue _ => throw <| IO.userError "burn permitted despite p2 banning it"
      | .isFalse _ => pure ()
}

/-- Scenario 11: bridge actor cannot declare local policies.
    `bridgePolicy` rejects `declareLocalPolicy` for the bridge actor. -/
def scenario11_bridgeActor : TestCase := {
  name := "scenario 11: bridge actor cannot declare local policies"
  body := do
    -- bridgePolicy_rejects_declareLocalPolicy at the value level.
    let p : LocalPolicy := { clauses := [.denyTags [0]] }
    if bridgePolicy.authorized bridgeActor (.declareLocalPolicy p) then
      throw <| IO.userError "bridgePolicy permitted bridge-actor declareLocalPolicy"
    else pure ()
    -- bridgePolicy_rejects_revokeLocalPolicy.
    if bridgePolicy.authorized bridgeActor .revokeLocalPolicy then
      throw <| IO.userError "bridgePolicy permitted bridge-actor revokeLocalPolicy"
    else pure ()
}

/-- Scenario 12: declared policy survives encode/decode (LP.2 +
    LP.3 round-trip). -/
def scenario12_snapshotSurvival : TestCase := {
  name := "scenario 12: declared policy survives ExtendedState encode/decode"
  body := do
    let es0 := setupES
    -- Alice declares a policy.
    let p : LocalPolicy := { clauses := [.denyTags [0], .capAmount 1 100] }
    let st1 := mkSignedAction (.declareLocalPolicy p) 1 es0
    let h1 : Decidable (AdmissibleWith mockVerify policy testDeploymentId es0 st1) :=
      inferInstance
    let es1 ← match h1 with
      | .isTrue h => pure (apply_admissible_with mockVerify policy testDeploymentId es0 st1 h)
      | .isFalse _ => throw <| IO.userError "declare rejected"
    -- Encode + decode the ExtendedState.
    let bytes := Encoding.Encodable.encode (T := ExtendedState) es1
    match Encoding.Encodable.decode (T := ExtendedState) bytes with
    | .ok (es', _) =>
      -- The decoded state's localPolicies lookup at alice should
      -- return the declared policy.
      assertEq (expected := p) (actual := es'.localPolicies.lookup 1)
        "policy survives encode/decode"
    | .error _ =>
      throw <| IO.userError "ExtendedState decode failed"
}

/-! ## Headline LP.7 theorem API stability -/

/-- Term-level: `localPolicy_meta_action_independent` is callable. -/
def metaActionIndependentAPI : TestCase := {
  name := "localPolicy_meta_action_independent API stability"
  body := do
    let _proof :
      ∀ (es : ExtendedState) (signer : ActorId) (action : Action)
        (_h_meta : isMetaPolicyAction action = true)
        (lp lp' : LocalPolicies),
        localPolicyPermits { es with localPolicies := lp  } signer action ↔
        localPolicyPermits { es with localPolicies := lp' } signer action :=
      localPolicy_meta_action_independent
    pure ()
}

/-- Term-level: `localPolicyPermits_no_policy` is callable. -/
def noPolicyAPI : TestCase := {
  name := "localPolicyPermits_no_policy API stability"
  body := do
    let _proof :
      ∀ (es : ExtendedState) (signer : ActorId) (action : Action)
        (_h_no_policy : es.localPolicies[signer]? = none),
        localPolicyPermits es signer action :=
      localPolicyPermits_no_policy
    pure ()
}

/-! ## All LP.11 tests -/

/-- All LP.11 acceptance tests. -/
def tests : List TestCase :=
  [ scenario1_lifecycle
  , scenario2_crossActor
  , scenario3_metaSelfExempt
  , scenario4_requireRecipient_positive
  , scenario5_requireRecipient_negative
  , scenario6_capAmount
  , scenario7_crossResource
  , scenario8_replay
  , scenario9_multiClause
  , scenario10_overwrite
  , scenario11_bridgeActor
  , scenario12_snapshotSurvival
  , metaActionIndependentAPI
  , noPolicyAPI
  ]

end LocalPolicyAdmissibility
end LegalKernel.Test.Authority

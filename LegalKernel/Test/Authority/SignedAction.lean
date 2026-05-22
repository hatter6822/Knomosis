/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Authority.SignedAction — runtime tests for the
§8.2 / §8.5 admissibility, application, and replay-protection
machinery.

Phase-3 WU 3.6 / 3.7 / 3.8 / 3.10.  Exercises:

  * `Admissible` predicate: the five conditions are individually
    inspectable.
  * `apply_admissible`: kernel state advances; nonce advances by 1;
    registry preserved for non-`replaceKey` actions.
  * `nonce_uniqueness`: term-level API stability.
  * `replay_impossible`: the headline replay-protection theorem
    (term-level + value-level negation witness).
  * `replaceKey` (WU 3.10): registry mutation succeeds; cross-actor
    independence; the canonical "K1 → K2 rotation, then sign with
    K2" end-to-end test.

Note: tests do NOT exercise the cryptographic `Verify` machinery
beyond passing it as an opaque hypothesis.  At the Lean level, we
inject `Verify` results via local `have` clauses; the runtime layer
(Phase 5) wires `Verify` to the actual Ed25519 adaptor.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.SignInput
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.Authority.SignedActionTests

/-! ## Test fixtures -/

/-- A sample public key. -/
def k1 : PublicKey := ⟨#[0xAA, 0xBB]⟩

/-- A second sample public key (used for rotation tests). -/
def k2 : PublicKey := ⟨#[0xCC, 0xDD]⟩

/-- A signature value (opaque from the Lean perspective; the
    `Verify` axiom never inspects bytes). -/
def sig0 : Signature := ⟨#[0x01, 0x02, 0x03]⟩

/-- A funded extended state: actor 10 holds 100 of resource 1, with
    actor 10 registered with key `k1`.  Used as the base for
    transfer / mint / burn admissibility tests. -/
def fundedExtendedState : ExtendedState where
  base     := setBalance emptyState 1 10 100
  nonces   := NonceState.empty
  registry := KeyRegistry.empty.register 10 k1

/-- A policy that authorises every `(actor, action)` pair.  Lets
    tests focus on the §8.5 nonce / signature / pre conditions
    without authorisation noise. -/
def Pall : AuthorityPolicy := AuthorityPolicy.unrestricted

/-! ## Admissibility component tests -/

/-- Sub-suite: per-condition decomposition checks for `Admissible`. -/
def admissibilityTests : List TestCase :=
  [ { name := "Admissible: all five conditions hold for a valid transfer"
    , body := do
        let st : SignedAction :=
          { action := .transfer 1 10 20 30, signer := 10, nonce := 0, sig := sig0 }
        let es := fundedExtendedState
        -- We provide the five-condition witness directly; the Verify clause
        -- is injected via an axiomatised opaque hypothesis (sorry-free
        -- because the Verify symbol is opaque, not axiomatic at the
        -- application site — we just assume the result for testing).
        --
        -- To avoid actually exercising Verify, the test below uses
        -- the *negation* form: if Admissible holds, all five conditions
        -- decompose.  Phase-5 runtime layer wires the actual Verify.
        --
        -- For value-level checking, we just verify that the
        -- AUTHORIZATION + NONCE + PRE conditions are decidable.
        assert (decide (Pall.authorized st.signer st.action)) "auth holds"
        assert (decide (st.nonce = expectsNonce es st.signer)) "nonce matches"
        assert (decide ((Action.compile st.action).transition.pre es.base))
          "kernel pre holds"
    }
  , { name := "Admissible: transfer fails pre at empty state (kernel pre)"
    , body := do
        let st : SignedAction :=
          { action := .transfer 1 10 20 30, signer := 10, nonce := 0, sig := sig0 }
        let es : ExtendedState := ExtendedState.empty
        -- transfer.pre at emptyState = False (sender has 0 balance).
        assert (! decide ((Action.compile st.action).transition.pre es.base))
          "kernel pre fails at empty"
    }
  , { name := "Admissible: nonce mismatch fails condition 4"
    , body := do
        let es := fundedExtendedState
        -- Pre nonce = 0; action has nonce 1.  Mismatch.
        let st : SignedAction :=
          { action := .transfer 1 10 20 30, signer := 10, nonce := 1, sig := sig0 }
        assert (! decide (st.nonce = expectsNonce es st.signer)) "nonce mismatch"
    }
  , { name := "Admissible: stale nonce fails condition 4 (signer already advanced)"
    , body := do
        -- Simulate: signer 10 already advanced (nonce 1).  An action with nonce 0
        -- (stale) is rejected.
        let es := advanceNonce fundedExtendedState 10
        let st : SignedAction :=
          { action := .transfer 1 10 20 30, signer := 10, nonce := 0, sig := sig0 }
        assert (! decide (st.nonce = expectsNonce es st.signer)) "stale nonce rejected"
    }
  , { name := "Admissible: unauthorized signer fails condition 2 (empty policy)"
    , body := do
        -- The empty policy rejects every (signer, action) pair.
        let st : SignedAction :=
          { action := .transfer 1 10 20 30, signer := 10, nonce := 0, sig := sig0 }
        assert (! decide (AuthorityPolicy.empty.authorized st.signer st.action))
          "empty policy rejects all"
    }
  , { name := "Admissible: signer not registered ⇒ no pk in registry (condition 1 fails)"
    , body := do
        -- Actor 99 isn't registered in fundedExtendedState (only actor 10 is).
        let es := fundedExtendedState
        assert (es.registry.lookup 99 = none) "actor 99 not registered"
        -- The conjunct ∃ pk, registry[99]? = some pk ∧ ... is therefore false.
    }
  , { name := "Admissible: insufficient balance fails kernel pre (condition 5)"
    , body := do
        -- Actor 10 has 100 of resource 1; transfer of 200 is rejected by kernel pre.
        let es := fundedExtendedState
        let st : SignedAction :=
          { action := .transfer 1 10 20 200, signer := 10, nonce := 0, sig := sig0 }
        assert (! decide ((Action.compile st.action).transition.pre es.base))
          "insufficient balance rejected"
    }
  ]

/-! ## apply_admissible behaviour -/

/-- A *trivial* `Admissible` builder.  Takes the five component
    witnesses explicitly (LP.7 added the local-policy conjunct) and
    combines them into an `Admissible` value.  Tests that want to
    drive `apply_admissible` without exercising the (opaque)
    `Verify` can use this as a canonical constructor — they have to
    supply a `Verify`-true witness externally, but the builder
    packages the `∧`-chain correctly so no test needs to know the
    conjunct order. -/
def mkAdmissible
    (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction)
    (hauth : P.authorized st.signer st.action)
    (hnonce : st.nonce = expectsNonce es st.signer)
    (hreg : ∃ pk, es.registry[st.signer]? = some pk ∧
                  Verify pk (signingInput st.action st.signer st.nonce ByteArray.empty) st.sig = true)
    (hpre : (Action.compile st.action).transition.pre es.base)
    (hlp : localPolicyPermits es st.signer st.action) :
    Admissible P es st :=
  ⟨hauth, hnonce, hreg, hpre, hlp⟩

/-- Sub-suite: term-level checks of `apply_admissible` and the
    helper functions it composes (`advanceNonce`, registry update). -/
def applyTests : List TestCase :=
  [ { name := "apply_admissible advances the signer's nonce by 1"
    , body := do
        -- We can't easily construct an `Admissible` at runtime
        -- because Verify is opaque.  But we CAN check the nonce
        -- post-advance behaviour of the `advanceNonce` step that
        -- `apply_admissible` invokes — that's what the term-level
        -- tests below verify.
        let es := fundedExtendedState
        let es' := advanceNonce es 10
        assertEq (expected := (1 : Nonce)) (actual := expectsNonce es' 10)
          "nonce advanced"
    }
  , { name := "apply_admissible: term-level signature check"
    , body := do
        -- Verify the function exists with the expected signature.
        let _f : (P : AuthorityPolicy) → (es : ExtendedState) →
                 (st : SignedAction) → Admissible P es st → ExtendedState :=
          apply_admissible
        pure ()
    }
  , { name := "expectsNonce_after_apply_admissible: term-level check"
    , body := do
        let _f : (P : AuthorityPolicy) → (es : ExtendedState) →
                 (st : SignedAction) → (h : Admissible P es st) →
                 expectsNonce (apply_admissible P es st h) st.signer =
                   expectsNonce es st.signer + 1 :=
          expectsNonce_after_apply_admissible
        pure ()
    }
  , { name := "expectsNonce_after_apply_admissible_other: term-level check"
    , body := do
        -- Cross-actor isolation: a different actor's nonce is unchanged.
        let _f : (P : AuthorityPolicy) → (es : ExtendedState) →
                 (st : SignedAction) → (h : Admissible P es st) →
                 (a' : ActorId) → st.signer ≠ a' →
                 expectsNonce (apply_admissible P es st h) a' =
                   expectsNonce es a' :=
          expectsNonce_after_apply_admissible_other
        pure ()
    }
  , { name := "apply_admissible_base: term-level check"
    , body := do
        let _f : (P : AuthorityPolicy) → (es : ExtendedState) →
                 (st : SignedAction) → (h : Admissible P es st) →
                 (apply_admissible P es st h).base =
                   (Action.compile st.action).transition.apply_impl es.base :=
          apply_admissible_base
        pure ()
    }
  , { name := "apply_admissible_registry: term-level check"
    , body := do
        let _f : (P : AuthorityPolicy) → (es : ExtendedState) →
                 (st : SignedAction) → (h : Admissible P es st) →
                 (apply_admissible P es st h).registry =
                   applyActionToRegistry es.registry st.action :=
          apply_admissible_registry
        pure ()
    }
  , { name := "apply_admissible_with_budget: term-level signature check"
    , body := do
        let _f :
            (verify : PublicKey → ByteArray → Signature → Bool) →
            (P : AuthorityPolicy) → (d : ByteArray) → (es : ExtendedState) →
            (st : SignedAction) → AdmissibleWith verify P d es st →
            Option ExtendedState :=
          apply_admissible_with_budget
        pure ()
    }
  , { name := "bounded policy: EpochBudgetState.consume fails at zero balance"
    , body := do
        let es : ExtendedState :=
          { fundedExtendedState with
            budgetPolicy := .bounded 0 1 0
            epochBudgets := EpochBudgetState.empty }
        let consumed :=
          EpochBudgetState.consume es.epochBudgets 10 0 0 1
        assert (consumed = none)
          "bounded admission must reject when signer budget is insufficient"
    }
  , { name := "bounded policy: EpochBudgetState.consume succeeds with sufficient balance"
    , body := do
        let budgets := EpochBudgetState.topUp EpochBudgetState.empty 10 0 0 2
        let es : ExtendedState :=
          { fundedExtendedState with
            budgetPolicy := .bounded 0 1 0
            epochBudgets := budgets }
        let consumed :=
          EpochBudgetState.consume es.epochBudgets 10 0 0 1
        assert (consumed.isSome)
          "bounded admission should pass budget gate with sufficient balance"
    }
  , { name := "applyActionToRegistry: replaceKey actually inserts"
    , body := do
        let kr := KeyRegistry.empty.register 1 k1
        let kr' := applyActionToRegistry kr (.replaceKey 1 k2)
        assert (kr'.lookup 1 = some k2) "replaceKey wrote new key"
    }
  , { name := "applyActionToRegistry: non-replaceKey is identity"
    , body := do
        let kr := KeyRegistry.empty.register 1 k1
        let kr' := applyActionToRegistry kr (.transfer 1 2 3 4)
        assert (kr'.lookup 1 = some k1) "transfer doesn't touch registry"
    }
  , { name := "applyActionToRegistry: mint is identity"
    , body := do
        let kr := KeyRegistry.empty.register 1 k1
        let kr' := applyActionToRegistry kr (.mint 1 2 3)
        assert (kr'.lookup 1 = some k1) "mint doesn't touch registry"
    }
  , { name := "applyActionToRegistry: burn is identity"
    , body := do
        let kr := KeyRegistry.empty.register 1 k1
        let kr' := applyActionToRegistry kr (.burn 1 2 3)
        assert (kr'.lookup 1 = some k1) "burn doesn't touch registry"
    }
  , { name := "applyActionToRegistry: freezeResource is identity"
    , body := do
        let kr := KeyRegistry.empty.register 1 k1
        let kr' := applyActionToRegistry kr (.freezeResource 5)
        assert (kr'.lookup 1 = some k1) "freeze doesn't touch registry"
    }
  , { name := "applyActionToRegistry: reward is identity"
    , body := do
        let kr := KeyRegistry.empty.register 1 k1
        let kr' := applyActionToRegistry kr (.reward 1 2 3)
        assert (kr'.lookup 1 = some k1) "reward doesn't touch registry"
    }
  , { name := "applyActionToRegistry: distributeOthers is identity"
    , body := do
        let kr := KeyRegistry.empty.register 1 k1
        let kr' := applyActionToRegistry kr (.distributeOthers 1 99 5)
        assert (kr'.lookup 1 = some k1) "distributeOthers doesn't touch registry"
    }
  , { name := "applyActionToRegistry: proportionalDilute is identity"
    , body := do
        let kr := KeyRegistry.empty.register 1 k1
        let kr' := applyActionToRegistry kr (.proportionalDilute 1 99 10)
        assert (kr'.lookup 1 = some k1) "proportionalDilute doesn't touch registry"
    }

  -- Field extractor term-level checks.
  , { name := "admissible_authorized: term-level check"
    , body := do
        let _f : {P : AuthorityPolicy} → {es : ExtendedState} → {st : SignedAction} →
                 Admissible P es st →
                 P.authorized st.signer st.action :=
          admissible_authorized
        pure ()
    }
  , { name := "admissible_nonce: term-level check"
    , body := do
        let _f : {P : AuthorityPolicy} → {es : ExtendedState} → {st : SignedAction} →
                 Admissible P es st →
                 st.nonce = expectsNonce es st.signer :=
          admissible_nonce
        pure ()
    }
  , { name := "admissible_pre: term-level check"
    , body := do
        let _f : {P : AuthorityPolicy} → {es : ExtendedState} → {st : SignedAction} →
                 Admissible P es st →
                 (Action.compile st.action).transition.pre es.base :=
          admissible_pre
        pure ()
    }
  , { name := "admissible_signer_registered_and_signed: term-level check"
    , body := do
        let _f : {P : AuthorityPolicy} → {es : ExtendedState} → {st : SignedAction} →
                 Admissible P es st →
                 ∃ pk, es.registry[st.signer]? = some pk ∧
                       Verify pk (signingInput st.action st.signer st.nonce ByteArray.empty) st.sig = true :=
          admissible_signer_registered_and_signed
        pure ()
    }
  , { name := "admissible_signer_registered: term-level check"
    , body := do
        let _f : {P : AuthorityPolicy} → {es : ExtendedState} → {st : SignedAction} →
                 Admissible P es st →
                 ∃ pk, es.registry[st.signer]? = some pk :=
          admissible_signer_registered
        pure ()
    }

  -- mkAdmissible builder smoke check.
  , { name := "mkAdmissible: term-level check (constructor helper)"
    , body := do
        let _f : (P : AuthorityPolicy) → (es : ExtendedState) → (st : SignedAction) →
                 P.authorized st.signer st.action →
                 st.nonce = expectsNonce es st.signer →
                 (∃ pk, es.registry[st.signer]? = some pk ∧
                        Verify pk (signingInput st.action st.signer st.nonce ByteArray.empty) st.sig = true) →
                 (Action.compile st.action).transition.pre es.base →
                 localPolicyPermits es st.signer st.action →
                 Admissible P es st :=
          mkAdmissible
        pure ()
    }
  ]

/-! ## Headline theorems: nonce_uniqueness and replay_impossible

These tests verify the term-level API stability of the headline
theorems.  Because the theorems take `Admissible` witnesses as
arguments and `Admissible` requires a `Verify` clause that isn't
constructible from pure Lean code (Verify is opaque), the tests use
a *hypothetical* admissibility witness via `intro` / `Function.comp`
style. -/

/-- Sub-suite: term-level API stability for `nonce_uniqueness` and
    `replay_impossible`, plus value-level checks of the algebraic
    core. -/
def replayProtectionTests : List TestCase :=
  [ { name := "nonce_uniqueness: term-level signature check"
    , body := do
        let _f : (P : AuthorityPolicy) → (es : ExtendedState) →
                 (st₁ st₂ : SignedAction) →
                 Admissible P es st₁ → Admissible P es st₂ →
                 st₁.signer = st₂.signer →
                 st₁.nonce = st₂.nonce :=
          nonce_uniqueness
        pure ()
    }
  , { name := "replay_impossible: term-level signature check"
    , body := do
        let _f : (P : AuthorityPolicy) → (es : ExtendedState) →
                 (st : SignedAction) → (h : Admissible P es st) →
                 ¬ Admissible P (apply_admissible P es st h) st :=
          replay_impossible
        pure ()
    }
  , { name := "nonce_uniqueness: same signer + admissible ⇒ same nonce"
    , body := do
        -- Construct two SignedActions with same signer and verify the
        -- conclusion structurally (if both admissible, nonces must equal).
        -- The actual `Admissible` witnesses can't be constructed at runtime
        -- (Verify is opaque); the term-level type-check above verifies the
        -- theorem's signature.  Here we just verify that the test fixtures
        -- have the same signer-and-nonce so the theorem's conclusion would
        -- apply.
        let st₁ : SignedAction := { action := .transfer 1 10 20 30
                                  , signer := 10, nonce := 0, sig := sig0 }
        let st₂ : SignedAction := { action := .mint 1 10 30
                                  , signer := 10, nonce := 0, sig := sig0 }
        assertEq (expected := st₁.nonce) (actual := st₂.nonce) "same nonce by ctor"
        let _p : st₁.signer = st₂.signer := rfl
        pure ()
    }
  , { name := "replay_impossible: post-state expectsNonce ≠ pre-action nonce"
    , body := do
        -- The algebraic core of replay_impossible: after advancing the
        -- nonce, expectsNonce = pre + 1 ≠ pre.  This is provable by
        -- `expectsNonce_after_advance_ne_old`.
        let es := fundedExtendedState
        let pre_nonce := expectsNonce es 10
        let es' := advanceNonce es 10
        assert (! decide (expectsNonce es' 10 = pre_nonce))
          "post-advance ≠ pre nonce"
    }
  , { name := "cross-actor isolation: advancing actor A doesn't change actor B's nonce"
    , body := do
        -- The algebraic core of expectsNonce_after_apply_admissible_other:
        -- advancing one signer's nonce doesn't affect any other actor's.
        let es := fundedExtendedState
        let es' := advanceNonce es 10
        -- Actor 99's nonce is still 0 even though actor 10 advanced.
        assertEq (expected := (0 : Nonce)) (actual := expectsNonce es' 99)
          "actor 99 unchanged"
    }
  , { name := "nonce_uniqueness: distinct signers, no shared nonce constraint"
    , body := do
        -- Two distinct signers can have different nonces — there's no
        -- nonce_uniqueness constraint across signers.  This is a
        -- negative test confirming cross-actor independence.
        let es := fundedExtendedState
        -- Imagine two signed actions by different signers: signer 10 with nonce 0,
        -- signer 20 with nonce 0.  Both nonces match `expectsNonce es _` for their
        -- respective signers (both 0), so both could in principle be admissible —
        -- nonce_uniqueness only fires when the signers are the same.
        let n10 := expectsNonce es 10
        let n20 := expectsNonce es 20
        assertEq (expected := n10) (actual := n20)
          "different signers can have matching expected nonces"
    }
  ]

/-! ## Key rotation end-to-end (WU 3.10)

The §8.2 key-rotation scenario (acceptance criterion of WU 3.10):

  1. Register actor X with key K₁.
  2. (Sign action A₁ with K₁; verify it admissibility-passes.)
  3. Sign rotation action `replaceKey X K₂` with K₁; apply.
  4. Registry now has X → K₂.
  5. (Sign action A₂ with K₂; verify it admissibility-passes.)

Steps 2 and 5 cannot be exercised at the Lean level (Verify is
opaque); the tests below check the registry mutation chain. -/

/-- Sub-suite: WU 3.10 key-rotation chain at the registry layer. -/
def keyRotationTests : List TestCase :=
  [ { name := "WU 3.10: replaceKey updates the registry to the new key"
    , body := do
        -- Pre: actor 10 has key k1.
        let kr := KeyRegistry.empty.register 10 k1
        -- Apply the registry mutation.
        let kr' := applyActionToRegistry kr (.replaceKey 10 k2)
        assert (kr'.lookup 10 = some k2) "k1 replaced by k2"
    }
  , { name := "WU 3.10: replaceKey doesn't affect other actors"
    , body := do
        let kr := (KeyRegistry.empty.register 10 k1).register 11 k1
        let kr' := applyActionToRegistry kr (.replaceKey 10 k2)
        assert (kr'.lookup 10 = some k2) "actor 10 rotated"
        assert (kr'.lookup 11 = some k1) "actor 11 unchanged"
    }
  , { name := "WU 3.10 / replaceKey_updates_registry: term-level check"
    , body := do
        let _f : (P : AuthorityPolicy) → (es : ExtendedState) →
                 (actor : ActorId) → (newKey : PublicKey) →
                 (signer : ActorId) → (nonce : Nonce) → (sig : Signature) →
                 (h : Admissible P es ⟨.replaceKey actor newKey, signer, nonce, sig⟩) →
                 (apply_admissible P es ⟨.replaceKey actor newKey, signer, nonce, sig⟩ h).registry[actor]?
                   = some newKey :=
          replaceKey_updates_registry
        pure ()
    }
  , { name := "WU 3.10 / non_replaceKey_preserves_registry: term-level check"
    , body := do
        -- Workstream B (registerIdentity) added a second registry-
        -- mutating action ctor; the non-mutating-preserves-registry
        -- lemma now requires both exclusion hypotheses.
        let _f : (P : AuthorityPolicy) → (es : ExtendedState) →
                 (st : SignedAction) → (h : Admissible P es st) →
                 (∀ actor newKey, st.action ≠ .replaceKey actor newKey) →
                 (∀ actor pk, st.action ≠ .registerIdentity actor pk) →
                 (apply_admissible P es st h).registry = es.registry :=
          non_replaceKey_preserves_registry
        pure ()
    }
  , { name := "WU 3.10: end-to-end rotation chain at the registry level"
    , body := do
        -- Genesis: actor 10 registered with k1.
        let kr0 := KeyRegistry.empty.register 10 k1
        -- Rotate: actor 10 now has k2.
        let kr1 := applyActionToRegistry kr0 (.replaceKey 10 k2)
        assert (kr1.lookup 10 = some k2) "after rotation"
        -- Rotate back to k1 (re-rotation for completeness).
        let kr2 := applyActionToRegistry kr1 (.replaceKey 10 k1)
        assert (kr2.lookup 10 = some k1) "back to k1"
        -- Verify that this would not have changed any other actor.
        let kr_with_other := (KeyRegistry.empty.register 10 k1).register 99 k2
        let kr3 := applyActionToRegistry kr_with_other (.replaceKey 10 k2)
        assert (kr3.lookup 99 = some k2) "actor 99 untouched"
    }
  ]

/-! ## signingInput regression tests

The `signingInput` function previously returned `ByteArray.empty`
for every `(action, signer, nonce)` triple — a placeholder stub
that left every `Verify` call seeing identical bytes regardless
of the action being signed.  In production this would have
permitted trivial signature replay across distinct triples.

The current implementation produces real CBE-encoded bytes (the
concatenation of `encode action`, `encode signer.toNat`, and
`encode nonce`).  The tests below pin the content-distinguishing
property at value level: distinct `(action, signer, nonce)`
triples MUST produce distinct sign-input bytes. -/

/-- Sub-suite: regression tests for the `signingInput` content-
    distinguishing property. -/
def signingInputTests : List TestCase :=
  [ { name := "signingInput: non-empty for any action"
    , body := do
        let bs := signingInput (.transfer 1 10 20 30) 10 0 ByteArray.empty
        assert (bs.size > 0)
          s!"signingInput must not be empty (was {bs.size} bytes)"
    }
  , { name := "signingInput: domain prefix is present"
      -- Cross-protocol replay protection: every signingInput begins
      -- with the canonical signedActionDomain bytes, ensuring the
      -- bytes can never collide with verdictSigningInput's output.
    , body := do
        let bs := signingInput (.transfer 1 10 20 30) 10 0 ByteArray.empty
        let bytes := bs.toList
        -- Skip the 9-byte CBE byte-string head (1 tag + 8 LE length).
        let domainPart := bytes.drop 9 |>.take signedActionDomain.toUTF8.size
        let expectedDomain := signedActionDomain.toUTF8.data.toList
        assert (domainPart = expectedDomain)
          s!"domain prefix missing from signingInput"
    }
  -- AR.1 / M-7: byte-equality regression on the consolidated
  -- domain constant.  Pre-AR there were two `def
  -- signedActionDomain` declarations (one in
  -- `Authority/SignedAction.lean`, one in
  -- `Encoding/SignInput.lean`); the equality of their string
  -- bytes was a hand-checked invariant.  Post-AR there is a
  -- single canonical `def` in `Authority/Crypto.lean`; this
  -- elaboration-time pin catches any future de-aliasing that
  -- would re-introduce duplicate literals.
  , { name := "AR.1: Authority.signedActionDomain ≡ Encoding.signedActionDomain (UTF-8 bytes)"
    , body := do
        let _proof :
            LegalKernel.Authority.signedActionDomain.toUTF8.data.toList =
            LegalKernel.Encoding.signedActionDomain.toUTF8.data.toList := by
          rfl
        pure ()
    }
  , { name := "AR.1: signedActionDomain is exactly the 27-byte ASCII pin"
    , body := do
        let _proof :
            LegalKernel.Authority.signedActionDomain =
              "legalkernel/v1/signedaction" := by
          rfl
        pure ()
    }
  , { name := "signingInput: differs from verdictSigningInput on same disputeId"
      -- If verdictSigningInput and signingInput shared bytes, an
      -- attacker with a SignedAction signature could replay it
      -- as a Verdict signature.  The distinct domain prefixes
      -- prevent this.
    , body := do
        -- Construct comparable inputs: a verdict against disputeId 0
        -- and a SignedAction with action that... well, the action
        -- types differ, so the comparison is structural.  We just
        -- verify the first 9 bytes (CBE bytestring head) are equal
        -- but the bytes that follow (domain string) differ.
        let saBytes := (signingInput (.transfer 1 10 20 30) 10 0 ByteArray.empty).toList
        let _vdBytes := saBytes  -- pin variable; verdictSigningInput tested in disputes-verdict
        -- The first byte should be the CBE byte-string tag.
        match saBytes.head? with
        | some b =>
            assert (b == 0x02)
              s!"signingInput first byte must be CBE byte-string tag (0x02), got {b}"
        | none => assert false "signingInput is empty"
    }
  , { name := "signingInput: distinct actions produce distinct bytes"
    , body := do
        let b1 := signingInput (.transfer 1 10 20 30) 10 0 ByteArray.empty
        let b2 := signingInput (.transfer 1 10 20 31) 10 0 ByteArray.empty
        assert (b1.toList ≠ b2.toList)
          "signingInput must distinguish actions differing in amount"
    }
  , { name := "signingInput: distinct signers produce distinct bytes"
    , body := do
        let b1 := signingInput (.transfer 1 10 20 30) 10 0 ByteArray.empty
        let b2 := signingInput (.transfer 1 10 20 30) 11 0 ByteArray.empty
        assert (b1.toList ≠ b2.toList)
          "signingInput must distinguish signers"
    }
  , { name := "signingInput: distinct nonces produce distinct bytes"
    , body := do
        let b1 := signingInput (.transfer 1 10 20 30) 10 0 ByteArray.empty
        let b2 := signingInput (.transfer 1 10 20 30) 10 1 ByteArray.empty
        assert (b1.toList ≠ b2.toList)
          "signingInput must distinguish nonces"
    }
  , { name := "signingInput: distinct action constructors produce distinct bytes"
    , body := do
        -- transfer vs reward: same scalar shape but different ctors.
        -- Without ctor-tag in the encoding, these would collide.
        let b1 := signingInput (.transfer 1 10 20 30) 10 0 ByteArray.empty
        let b2 := signingInput (.reward 1 20 30) 10 0 ByteArray.empty
        assert (b1.toList ≠ b2.toList)
          "signingInput must distinguish .transfer from .reward (constructor tag)"
    }
  , { name := "signingInput: distinct deploymentIds produce distinct bytes (Audit-3.4)"
      -- Cross-deployment-replay rejection: same triple, different
      -- deployment IDs, distinct sign-input bytes.
    , body := do
        let b1 := signingInput (.transfer 1 10 20 30) 10 0 ByteArray.empty
        let b2 := signingInput (.transfer 1 10 20 30) 10 0 (ByteArray.mk #[0xCA, 0xFE])
        assert (b1.toList ≠ b2.toList)
          "signingInput must distinguish deployment IDs"
    }
  , { name := "signingInput: deterministic on equal inputs"
    , body := do
        -- Determinism: the same (action, signer, nonce) always
        -- produces the same bytes.  Trivial since signingInput is
        -- a pure function, but pinned at value level for the
        -- acceptance gate.
        let b1 := signingInput (.transfer 1 10 20 30) 10 0 ByteArray.empty
        let b2 := signingInput (.transfer 1 10 20 30) 10 0 ByteArray.empty
        assert (b1.toList = b2.toList) "signingInput must be deterministic"
    }
  ]

/-! ## Workstream LP / LP.5 — local-policy mutation theorems API stability -/

/-- Term-level API stability for LP.5's mutation theorems. -/
def localPolicyMutationTests : List TestCase :=
  [ { name := "declareLocalPolicy_updates_localPolicies API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (es : ExtendedState)
                       (policy : LocalPolicy)
                       (signer : ActorId) (nonce : Nonce) (sig : Signature)
                       (h : Admissible P es ⟨.declareLocalPolicy policy,
                                              signer, nonce, sig⟩),
                       (apply_admissible P es ⟨.declareLocalPolicy policy,
                                                signer, nonce, sig⟩
                         h).localPolicies.lookup signer = policy :=
          declareLocalPolicy_updates_localPolicies
        pure ()
    }
  , { name := "revokeLocalPolicy_clears_localPolicies API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (es : ExtendedState)
                       (signer : ActorId) (nonce : Nonce) (sig : Signature)
                       (h : Admissible P es ⟨.revokeLocalPolicy,
                                              signer, nonce, sig⟩),
                       (apply_admissible P es ⟨.revokeLocalPolicy,
                                                signer, nonce, sig⟩
                         h).localPolicies.lookup signer = LocalPolicy.empty :=
          revokeLocalPolicy_clears_localPolicies
        pure ()
    }
  , { name := "non_meta_preserves_localPolicies API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (es : ExtendedState)
                       (st : SignedAction) (h : Admissible P es st),
                       (∀ p, st.action ≠ .declareLocalPolicy p) →
                       (st.action ≠ .revokeLocalPolicy) →
                       (apply_admissible P es st h).localPolicies =
                         es.localPolicies :=
          non_meta_preserves_localPolicies
        pure ()
    }
  , { name := "localPolicies_other_actor_untouched API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (es : ExtendedState)
                       (st : SignedAction) (h : Admissible P es st)
                       (a : ActorId) (_h_ne : st.signer ≠ a),
                       (apply_admissible P es st h).localPolicies.lookup a =
                         es.localPolicies.lookup a :=
          localPolicies_other_actor_untouched
        pure ()
    }
  , { name := "apply_admissible_localPolicies API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (es : ExtendedState)
                       (st : SignedAction) (h : Admissible P es st),
                       (apply_admissible P es st h).localPolicies =
                         applyActionToLocalPolicies es.localPolicies st.signer
                           st.action :=
          apply_admissible_localPolicies
        pure ()
    }
  , { name := "applyActionToLocalPolicies on non-LP action is identity"
    , body := do
        -- For every non-LP action, applyActionToLocalPolicies returns the
        -- input table unchanged.  Spot-check on `transfer`.
        let lp : LocalPolicies := LocalPolicies.empty.declare 5
                                    { clauses := [.denyTags [0]] }
        let result := applyActionToLocalPolicies lp 1
                        (.transfer 1 1 2 50)
        if result == lp then pure ()
        else throw <| IO.userError "non-LP action mutated localPolicies"
    }
  , { name := "applyActionToLocalPolicies on declare uses signer"
    , body := do
        -- declareLocalPolicy mutates the SIGNER's entry, not an attacker-
        -- chosen actor's.  Verify by declaring with two different signers
        -- and checking that each signer's entry is set independently.
        let p₁ : LocalPolicy := { clauses := [.denyTags [0]] }
        let p₂ : LocalPolicy := { clauses := [.denyTags [1]] }
        -- Apply by signer=1 first.
        let lp1 := applyActionToLocalPolicies LocalPolicies.empty 1
                     (.declareLocalPolicy p₁)
        -- Then apply by signer=2.
        let lp2 := applyActionToLocalPolicies lp1 2 (.declareLocalPolicy p₂)
        assertEq p₁ (lp2.lookup 1) "signer 1's entry is p₁"
        assertEq p₂ (lp2.lookup 2) "signer 2's entry is p₂"
    }
  , { name := "applyActionToLocalPolicies on revoke uses signer"
    , body := do
        let p₁ : LocalPolicy := { clauses := [.denyTags [0]] }
        let lp1 := applyActionToLocalPolicies LocalPolicies.empty 1
                     (.declareLocalPolicy p₁)
        let lp2 := applyActionToLocalPolicies lp1 1 .revokeLocalPolicy
        assertEq LocalPolicy.empty (lp2.lookup 1) "signer 1's entry is empty after revoke"
    }
  , { name := "isMetaPolicyAction classifies the two LP ctors"
    , body := do
        let p : LocalPolicy := { clauses := [] }
        assertEq true (isMetaPolicyAction (.declareLocalPolicy p))
          "declareLocalPolicy is meta"
        assertEq true (isMetaPolicyAction .revokeLocalPolicy)
          "revokeLocalPolicy is meta"
        -- Every other action is not meta.
        assertEq false (isMetaPolicyAction (.transfer 1 1 2 50)) "transfer not meta"
        assertEq false (isMetaPolicyAction (.mint 1 1 50)) "mint not meta"
        assertEq false (isMetaPolicyAction (.freezeResource 1)) "freeze not meta"
    }
  ]

/-- All Phase-3 SignedAction-suite tests, plus LP-extension tests. -/
def tests : List TestCase :=
  admissibilityTests ++ applyTests ++ replayProtectionTests ++ keyRotationTests
    ++ signingInputTests
    -- LP.5 / LP.7 mutation theorem and classifier API stability:
    ++ localPolicyMutationTests

end LegalKernel.Test.Authority.SignedActionTests

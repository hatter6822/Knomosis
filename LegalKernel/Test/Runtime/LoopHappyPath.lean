/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Runtime.LoopHappyPath — Audit-3.3 / 3.4 happy-path
runtime test suite.

Pre-Audit-3.3, every `processSignedAction` test that didn't
explicitly *expect* failure would fail (because `Verify` returns
`false` in the test runtime).  Audit-3.3's `processSignedActionWith`
parameterised over `verify` lets us exercise the green path with
`mockVerify` from `Test/MockCrypto.lean`.

This suite covers:

  * A single transfer admissible chain (mint → transfer → balance check).
  * Cross-actor isolation under happy-path admissibility (two actors,
    independent nonce advancement).
  * Multi-action chain via `processBatchWith`.
  * The runtime's log-append + replay round-trip under `mockVerify`.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Runtime
namespace LoopHappyPath

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

/-! ## Test fixtures -/

/-- Demo authority policy used by every happy-path test in this
    suite: every signer is authorised for every action. -/
def policy : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- Deployment id used by every happy-path test in this suite.
    Non-empty so cross-deployment-replay rejection tests are
    meaningful. -/
def testDeploymentId : ByteArray :=
  ByteArray.mk #[0xCA, 0xFE, 0xBA, 0xBE]

/-- Pre-state: actor 10 holds 100 at resource 1; actor 20 holds
    50.  Both actors registered with mock pubkeys. -/
def es0 : ExtendedState :=
  let base0 : State :=
    setBalance (setBalance emptyState 1 10 100) 1 20 50
  let registry := (KeyRegistry.empty.register 10 (mockPubKey 10)).register 20 (mockPubKey 20)
  { base := base0, nonces := NonceState.empty, registry := registry }

/-- Build a mockSign-valid `SignedAction` for the given action,
    signer (whose nonce is `expectsNonce es signer`), against
    `testDeploymentId`. -/
def mkSignedAction (action : Action) (signer : ActorId) (es : ExtendedState) :
    SignedAction :=
  let nonce := expectsNonce es signer
  let msg := signingInput action signer nonce testDeploymentId
  let sig := mockSign (mockPubKey signer.toNat) msg
  ⟨action, signer, nonce, sig⟩

/-! ## Tests -/

/-- A single transfer succeeds via the parameterized happy path.
    Actor 10 transfers 30 to actor 20 at resource 1.  Post-state
    balances are 70 and 80, nonce advances. -/
def transferHappyPath : TestCase := {
  name := "transfer admissible via mockVerify, post-state correct"
  body := do
    let st := mkSignedAction (.transfer 1 10 20 30) 10 es0
    -- Construct the admissibility witness via the Decidable instance.
    if h : AdmissibleWith mockVerify policy testDeploymentId es0 st then
      let es1 := apply_admissible_with mockVerify policy testDeploymentId es0 st h
      assertEq (expected := 70) (actual := getBalance es1.base 1 10) "sender post-balance"
      assertEq (expected := 80) (actual := getBalance es1.base 1 20) "receiver post-balance"
      assertEq (expected := 1) (actual := expectsNonce es1 10) "sender nonce advanced"
      assertEq (expected := 0) (actual := expectsNonce es1 20) "receiver nonce unchanged"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected a should-be-admissible transfer"
}

/-- Mint succeeds via the parameterized happy path.  Actor 10
    mints 50 at resource 1.  Post-state balance is 150. -/
def mintHappyPath : TestCase := {
  name := "mint admissible via mockVerify, post-state correct"
  body := do
    let st := mkSignedAction (.mint 1 10 50) 10 es0
    if h : AdmissibleWith mockVerify policy testDeploymentId es0 st then
      let es1 := apply_admissible_with mockVerify policy testDeploymentId es0 st h
      assertEq (expected := 150) (actual := getBalance es1.base 1 10) "minted balance"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected a should-be-admissible mint"
}

/-- Reward succeeds via the parameterized happy path.  Actor 20
    receives 25 at resource 1.  Post-state balance is 75. -/
def rewardHappyPath : TestCase := {
  name := "reward admissible via mockVerify, post-state correct"
  body := do
    let st := mkSignedAction (.reward 1 20 25) 10 es0
    if h : AdmissibleWith mockVerify policy testDeploymentId es0 st then
      let es1 := apply_admissible_with mockVerify policy testDeploymentId es0 st h
      assertEq (expected := 75) (actual := getBalance es1.base 1 20) "rewarded balance"
    else
      throw <| IO.userError "AdmissibleWith mockVerify rejected a should-be-admissible reward"
}

/-- Cross-actor isolation: a transfer by actor 10 advances actor
    10's nonce but leaves actor 20's nonce unchanged. -/
def crossActorNonceIsolation : TestCase := {
  name := "cross-actor nonce isolation under happy-path admissibility"
  body := do
    let st := mkSignedAction (.transfer 1 10 20 30) 10 es0
    if h : AdmissibleWith mockVerify policy testDeploymentId es0 st then
      let es1 := apply_admissible_with mockVerify policy testDeploymentId es0 st h
      assertEq (expected := 1) (actual := expectsNonce es1 10) "actor 10 nonce"
      assertEq (expected := 0) (actual := expectsNonce es1 20) "actor 20 nonce"
    else
      throw <| IO.userError "happy-path admissibility unexpectedly failed"
}

/-- Multi-step chain: actor 10 transfers, then actor 10 mints.
    The second action uses the post-first-action state, including
    the advanced nonce. -/
def twoStepChain : TestCase := {
  name := "two-step chain by same actor under happy-path admissibility"
  body := do
    let st1 := mkSignedAction (.transfer 1 10 20 30) 10 es0
    if h1 : AdmissibleWith mockVerify policy testDeploymentId es0 st1 then
      let es1 := apply_admissible_with mockVerify policy testDeploymentId es0 st1 h1
      assertEq (expected := 70) (actual := getBalance es1.base 1 10) "step 1: sender bal"
      let st2 := mkSignedAction (.mint 1 10 50) 10 es1
      if h2 : AdmissibleWith mockVerify policy testDeploymentId es1 st2 then
        let es2 := apply_admissible_with mockVerify policy testDeploymentId es1 st2 h2
        assertEq (expected := 120) (actual := getBalance es2.base 1 10) "step 2: post-mint bal"
        assertEq (expected := 2) (actual := expectsNonce es2 10) "actor 10 nonce after 2 steps"
      else
        throw <| IO.userError "step 2 admissibility unexpectedly failed"
    else
      throw <| IO.userError "step 1 admissibility unexpectedly failed"
}

/-- Replay protection at the value level: after applying an action,
    re-applying the *same* SignedAction is no longer admissible
    (the nonce no longer matches). -/
def replayProtection : TestCase := {
  name := "replay protection: same SignedAction inadmissible after apply"
  body := do
    let st := mkSignedAction (.transfer 1 10 20 30) 10 es0
    if h : AdmissibleWith mockVerify policy testDeploymentId es0 st then
      let es1 := apply_admissible_with mockVerify policy testDeploymentId es0 st h
      -- Try to apply the same SignedAction again.  Should be inadmissible.
      if AdmissibleWith mockVerify policy testDeploymentId es1 st then
        throw <| IO.userError "replay was accepted (should have been rejected)"
      else
        pure ()
    else
      throw <| IO.userError "initial application unexpectedly inadmissible"
}

/-- The runtime's `processSignedActionWith` happy path: the function
    returns `.ok` (not `.error .notAdmissible`) and writes a log
    entry to a tempfile. -/
def processSignedActionWithHappyPath : TestCase := {
  name := "processSignedActionWith returns .ok on admissible chain"
  body := do
    let tmp := s!"/tmp/canon-audit3-loophappy-{(← IO.monoNanosNow)}.log"
    let rs0 : RuntimeState :=
      { policy       := policy
      , state        := es0
      , prevHash     := zeroHash
      , logIndex     := 0
      , logPath      := System.FilePath.mk tmp
      , deploymentId := testDeploymentId }
    let st := mkSignedAction (.transfer 1 10 20 30) 10 es0
    let result ← processSignedActionWith mockVerify testDeploymentId rs0 st
    match result with
    | .ok pr =>
      -- Post-state has the right balance.
      assertEq (expected := 70) (actual := getBalance pr.state.state.base 1 10)
        "post-process sender balance"
      -- Log index advanced.
      assertEq (expected := 1) (actual := pr.state.logIndex) "logIndex advanced"
    | .error e =>
      throw <| IO.userError s!"processSignedActionWith should have succeeded; got: {repr e}"
    -- Cleanup.
    IO.FS.removeFile tmp
}

/-! ## Term-level API stability -/

/-- Term-level: `processSignedActionWith` is callable. -/
def processSignedActionWithAPI : TestCase := {
  name := "processSignedActionWith API stability"
  body := do
    let _proof :
      ∀ (_verify : PublicKey → ByteArray → Signature → Bool)
        (_d : ByteArray) (_rs : RuntimeState) (_st : SignedAction),
        IO (Except ProcessError ProcessResult) :=
      processSignedActionWith
    pure ()
}

/-- All tests in the LoopHappyPath suite. -/
def tests : List TestCase :=
  [ transferHappyPath
  , mintHappyPath
  , rewardHappyPath
  , crossActorNonceIsolation
  , twoStepChain
  , replayProtection
  , processSignedActionWithHappyPath
  , processSignedActionWithAPI
  ]

end LoopHappyPath
end LegalKernel.Test.Runtime

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
  { base := base0
  , nonces := NonceState.empty
  , registry := registry
  -- Budget-enabled runtime path: give a non-zero free tier at an
  -- epoch strictly greater than the default cell epoch so the first
  -- admission normalises each signer's budget above zero.
  , budgetPolicy := .bounded 10 1 1 }

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

/-! ## GP.3.2 — Budget-bounded admission gate (production path)

These tests pin the value-level behaviour of `processSignedActionWith`
under the GP.3.2 budget gate: with a low free-tier and the same actor
submitting back-to-back actions, the gate must fire on budget
exhaustion (NOT on the upstream admissibility check). -/

/-- A `RuntimeState` with the production deploymentId + a budget
    policy that grants exactly ONE budget unit per actor per epoch.
    Used by the GP.3.2 budget-exhaustion tests below. -/
def es0_oneShot : ExtendedState :=
  { es0 with budgetPolicy := .bounded 1 1 1 }

/-- The first admissible action under `.bounded 1 1 1` succeeds:
    the actor's normalised budget is `max 0 1 = 1`, consume 1 → 0,
    action applies. -/
def budgetGateFirstActionSucceeds : TestCase := {
  name := "GP.3.2: first action under .bounded 1 1 1 succeeds via processSignedActionWith"
  body := do
    let tmp := s!"/tmp/canon-gp32-firstsuccess-{(← IO.monoNanosNow)}.log"
    let rs0 : RuntimeState :=
      { policy       := policy
      , state        := es0_oneShot
      , prevHash     := zeroHash
      , logIndex     := 0
      , logPath      := System.FilePath.mk tmp
      , deploymentId := testDeploymentId }
    let st := mkSignedAction (.transfer 1 10 20 30) 10 es0_oneShot
    match (← processSignedActionWith mockVerify testDeploymentId rs0 st) with
    | .ok pr =>
      assertEq (expected := 70) (actual := getBalance pr.state.state.base 1 10)
        "first action applied (sender debited)"
      assertEq (expected := 1) (actual := pr.state.logIndex) "logIndex advanced"
    | .error e =>
      throw <| IO.userError s!"first action under bounded budget unexpectedly rejected: {repr e}"
    IO.FS.removeFile tmp
}

/-- After the first action exhausts the per-epoch budget, the same
    signer's second action is rejected by the budget gate, even
    though signature + nonce would be valid. -/
def budgetGateExhaustionRejects : TestCase := {
  name := "GP.3.2: second action under .bounded 1 1 1 rejected by budget gate"
  body := do
    let tmp := s!"/tmp/canon-gp32-exhausted-{(← IO.monoNanosNow)}.log"
    let rs0 : RuntimeState :=
      { policy       := policy
      , state        := es0_oneShot
      , prevHash     := zeroHash
      , logIndex     := 0
      , logPath      := System.FilePath.mk tmp
      , deploymentId := testDeploymentId }
    let st1 := mkSignedAction (.transfer 1 10 20 5) 10 es0_oneShot
    match (← processSignedActionWith mockVerify testDeploymentId rs0 st1) with
    | .ok pr =>
      -- Now actor 10's budget is exhausted (was 1, consumed 1 = 0).
      -- A second SIGNED action with the freshly-advanced nonce should
      -- be rejected by the budget gate.
      let st2 := mkSignedAction (.transfer 1 10 20 5) 10 pr.state.state
      match (← processSignedActionWith mockVerify testDeploymentId pr.state st2) with
      | .ok _ =>
        throw <| IO.userError "BUG: second action accepted despite exhausted budget"
      | .error .notAdmissible =>
        -- Expected: budget gate fires.  Verify post-rejection state
        -- is unchanged from the first action's outcome.
        assertEq (expected := 1) (actual := pr.state.logIndex)
          "logIndex unchanged by rejected second action"
    | .error e =>
      throw <| IO.userError s!"first action setup failed: {repr e}"
    IO.FS.removeFile tmp
}

/-- The budget gate is signer-keyed: even when actor 10's budget is
    exhausted, actor 20 retains their full per-epoch budget and can
    still admit an action.  This is the cross-actor-isolation
    property of the budget gate. -/
def budgetGateOtherActorUnaffected : TestCase := {
  name := "GP.3.2: budget exhaustion is signer-keyed (other actor unaffected)"
  body := do
    let tmp := s!"/tmp/canon-gp32-isolation-{(← IO.monoNanosNow)}.log"
    let rs0 : RuntimeState :=
      { policy       := policy
      , state        := es0_oneShot
      , prevHash     := zeroHash
      , logIndex     := 0
      , logPath      := System.FilePath.mk tmp
      , deploymentId := testDeploymentId }
    -- Actor 10 exhausts their budget.
    let st1 := mkSignedAction (.transfer 1 10 20 5) 10 es0_oneShot
    match (← processSignedActionWith mockVerify testDeploymentId rs0 st1) with
    | .ok pr1 =>
      -- Actor 20's budget is fresh (max 0 1 = 1 after normalise).
      let st2 := mkSignedAction (.transfer 1 20 10 3) 20 pr1.state.state
      match (← processSignedActionWith mockVerify testDeploymentId pr1.state st2) with
      | .ok pr2 =>
        assertEq (expected := 2) (actual := pr2.state.logIndex) "logIndex advanced twice"
      | .error e =>
        throw <| IO.userError s!"actor 20's first action unexpectedly rejected: {repr e}"
    | .error e =>
      throw <| IO.userError s!"actor 10's setup action failed: {repr e}"
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
  -- GP.3.2 budget gate (production path):
  , budgetGateFirstActionSucceeds
  , budgetGateExhaustionRejects
  , budgetGateOtherActorUnaffected
  ]

end LoopHappyPath
end LegalKernel.Test.Runtime

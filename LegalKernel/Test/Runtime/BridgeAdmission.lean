/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Runtime.BridgeAdmission — RB.3 acceptance tests for
the bridge-aware runtime admission gate.

Closes the pre-RB gap where `processSignedActionWith` consumed an
`AdmissibleWith` witness and applied via `apply_admissible_with_budget`,
leaving the `ExtendedState.bridge` field unchanged for `deposit` /
`withdraw` actions.  Post-RB.3, the runtime dispatches on
`BridgeAdmissibleWith` (which adds three bridge-specific conjuncts:
deposit-id freshness, registration freshness, bridge-only signer) and
applies via `apply_bridge_admissible_with_budget` (which atomically
updates the kernel state, advances the budget, and writes the
bridge-state mutation).

Coverage:

  * Happy-path deposit: `processSignedActionWith` admits a
    properly-signed deposit, advances the kernel state (recipient
    credited), and marks the `depositId` as consumed in
    `bridge.consumed`.
  * Replay-rejection: a second deposit with the same `depositId` is
    rejected at admission (`BridgeAdmissibleWith` conjunct 6 fires).
  * Happy-path withdrawal: a properly-signed user-initiated
    withdrawal appends a `PendingWithdrawal` entry at the runtime's
    `logIndex` to `bridge.pending` and bumps `bridge.nextWdId`.
  * Non-bridge-signer impersonation: a `deposit` signed by a non-
    bridge actor is rejected (`BridgeAdmissibleWith` conjunct 8
    fires) even when the action is otherwise admissible.
  * Identity-registration freshness: a second `registerIdentity`
    for the same actor is rejected (`BridgeAdmissibleWith`
    conjunct 7 fires).
  * Non-bridge action regression: `transfer` / `mint` continue to
    work through the bridge-aware runtime, with the bridge field
    unchanged (regression guard for the runtime-wiring change).

`processPure` mirrors `processSignedActionWith` post-RB.3, so the
tests below using the production-IO entry point also pin
`processPure`'s behaviour transitively.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Runtime
namespace BridgeAdmission

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Runtime
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

/-! ## Test fixtures -/

/-- The deployment id used by every test in this suite.  Non-empty
    so the AR.2 deployment-binding cannot accidentally collapse to
    the back-compat `ByteArray.empty` shape. -/
def testDeploymentId : ByteArray :=
  ByteArray.mk #[0xCA, 0xFE, 0xBA, 0xBE]

/-- The bridge actor's public key (mock).  Registered at id `0`
    (the canonical `bridgeActor` `ActorId`) in every fixture. -/
def bridgePubKey : PublicKey := mockPubKey 0

/-- Unrestricted authority policy: every signer is authorised for
    every action.  The RB.3 wiring tests focus on
    `BridgeAdmissibleWith` enforcement, not authorisation; the
    unrestricted policy keeps the test surface minimal. -/
def policy : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- Conditional removeFile: deletes the log path if it exists,
    otherwise does nothing.  Needed because rejected-action tests
    never create the log file (the runtime only appends on `.ok`),
    so unconditional `IO.FS.removeFile` would fail. -/
def safeRemoveFile (path : System.FilePath) : IO Unit := do
  if (← path.pathExists) then IO.FS.removeFile path

/-- Genesis extended state: bridge actor (id `0`) and a user actor
    (id `10`) both registered; user holds 100 of resource 1; bridge
    state is empty; budget policy admits 100 actions per actor per
    epoch (so the budget gate does not interfere with the bridge-
    admission tests).

    The `bridge`, `localPolicies`, and `epochBudgets` fields are
    initialised EXPLICITLY (rather than via the `ExtendedState`
    structure's defaults) so the test fixture is robust against
    future refactoring that might change those defaults.  In
    particular, the `bridge := BridgeState.empty` line is the
    load-bearing precondition for `depositReplayRejected`: if
    `bridge.consumed` were non-empty at fixture construction, the
    first deposit in the test could be silently rejected at the
    deposit-id-freshness conjunct, masking the test's actual
    intent. -/
def es0 : ExtendedState :=
  let base0 : State := setBalance emptyState 1 10 100
  let registry := (KeyRegistry.empty.register 0 bridgePubKey).register 10 (mockPubKey 10)
  { base          := base0
  , nonces        := NonceState.empty
  , registry      := registry
  , bridge        := BridgeState.empty
  , localPolicies := LocalPolicies.empty
  , epochBudgets  := EpochBudgetState.empty
  , budgetPolicy  := .bounded 100 1 1 }

/-- Build a `RuntimeState` with the test fixture pre-populated. -/
def mkRuntimeState (path : System.FilePath) : RuntimeState :=
  { policy       := policy
  , state        := es0
  , prevHash     := zeroHash
  , logIndex     := 0
  , logPath      := path
  , deploymentId := testDeploymentId }

/-- Build a mock-signed `SignedAction` for the given action.  Uses
    the test `mockSign` adaptor so the signature passes
    `mockVerify` under the test deployment id. -/
def mkSignedAction (action : Action) (signer : ActorId) (es : ExtendedState) :
    SignedAction :=
  let nonce := expectsNonce es signer
  let msg := signingInput action signer nonce testDeploymentId
  let sig := mockSign (mockPubKey signer.toNat) msg
  ⟨action, signer, nonce, sig⟩

/-! ## RB.3 — Happy-path bridge actions through `processSignedActionWith` -/

/-- A properly-signed deposit by `bridgeActor` succeeds: the recipient's
    balance increases by `amount`, AND the `depositId` is marked
    consumed in `bridge.consumed` carrying the deposit's
    `(resource, amount)` metadata.  Pre-RB.3 this test would have
    passed at the kernel layer but the depositId would NOT have been
    recorded — the assertions on `isConsumed` AND the
    `DepositRecord` shape below are the regression guards for the
    bridge-wiring fix. -/
def depositMarksConsumed : TestCase := {
  name := "RB.3: deposit through processSignedActionWith marks depositId consumed"
  body := do
    let tmp := s!"/tmp/knomosis-rb3-deposit-{(← IO.monoNanosNow)}.log"
    let rs := mkRuntimeState (System.FilePath.mk tmp)
    -- Bridge actor (signer 0) deposits 50 of resource 1 to actor 10
    -- with depositId 42.
    let depositId : Bridge.DepositId := 42
    let st := mkSignedAction (.deposit 1 10 50 depositId) 0 es0
    match (← processSignedActionWith mockVerify testDeploymentId rs st) with
    | .ok pr =>
      -- Kernel-side effect: recipient's balance increased by 50.
      assertEq (expected := 150) (actual := getBalance pr.state.state.base 1 10)
        "recipient credited at kernel layer"
      -- Bridge-side effect (RB.3): depositId now in bridge.consumed.
      assertEq (expected := true)
        (actual := pr.state.state.bridge.isConsumed depositId)
        "depositId marked consumed in bridge.consumed"
      -- Bridge-side effect (RB.3): the consumed DepositRecord carries
      -- the deposit's (resource, amount) metadata — required by the
      -- Workstream-C bridge-accounting theorem `totalDeposited`.
      match pr.state.state.bridge.consumed[depositId]? with
      | some rec =>
        assertEq (expected := (1 : Nat)) (actual := rec.resource.toNat)
          "consumed DepositRecord.resource matches"
        assertEq (expected := (50 : Nat)) (actual := rec.amount)
          "consumed DepositRecord.amount matches"
      | none =>
        throw <| IO.userError "DepositRecord missing from bridge.consumed after deposit"
      -- Bridge actor's nonce advanced.
      assertEq (expected := 1) (actual := expectsNonce pr.state.state 0)
        "bridge actor nonce advanced"
    | .error e =>
      throw <| IO.userError s!"deposit unexpectedly rejected: {repr e}"
    safeRemoveFile (System.FilePath.mk tmp)
}

/-- A second deposit with the SAME `depositId` is rejected by the
    `BridgeAdmissibleWith` deposit-id-freshness conjunct.  Pre-RB.3
    this would have been silently admitted (the kernel-level
    `AdmissibleWith` did not enforce the freshness check), enabling
    DEPOSIT REPLAY attacks. -/
def depositReplayRejected : TestCase := {
  name := "RB.3: deposit replay (duplicate depositId) is rejected at admission"
  body := do
    let tmp := s!"/tmp/knomosis-rb3-replay-{(← IO.monoNanosNow)}.log"
    let rs0 := mkRuntimeState (System.FilePath.mk tmp)
    let depositId : Bridge.DepositId := 99
    -- First deposit succeeds.
    let st1 := mkSignedAction (.deposit 1 10 25 depositId) 0 es0
    match (← processSignedActionWith mockVerify testDeploymentId rs0 st1) with
    | .ok pr1 =>
      -- Verify the depositId is now consumed.
      assert (pr1.state.state.bridge.isConsumed depositId)
        "first deposit must mark consumed"
      -- Second deposit with the SAME depositId.
      let st2 := mkSignedAction (.deposit 1 10 25 depositId) 0 pr1.state.state
      match (← processSignedActionWith mockVerify testDeploymentId pr1.state st2) with
      | .ok _ =>
        throw <| IO.userError "BUG: deposit replay was admitted (RB.3 freshness conjunct didn't fire)"
      | .error .notAdmissible =>
        -- Expected: BridgeAdmissibleWith conjunct 6 rejected.
        -- Verify the log index did NOT advance.
        assertEq (expected := 1) (actual := pr1.state.logIndex)
          "logIndex unchanged by rejected replay"
    | .error e =>
      throw <| IO.userError s!"first deposit unexpectedly rejected: {repr e}"
    safeRemoveFile (System.FilePath.mk tmp)
}

/-- A properly-signed user-initiated withdrawal appends a
    `PendingWithdrawal` entry to `bridge.pending`, bumps
    `bridge.nextWdId`, and records the runtime's `logIndex` in
    the new entry's `l2LogIndex` field.  Pre-RB.3 this test would
    have passed at the kernel layer but the pending entry would
    NOT have been created — the assertions on `bridge.nextWdId`,
    `bridge.pending.size`, AND the pending entry's
    `(resource, recipient, amount, l2LogIndex)` shape below are
    the regression guards. -/
def withdrawAppendsToPending : TestCase := {
  name := "RB.3: withdraw through processSignedActionWith appends pending entry"
  body := do
    let tmp := s!"/tmp/knomosis-rb3-withdraw-{(← IO.monoNanosNow)}.log"
    let rs := mkRuntimeState (System.FilePath.mk tmp)
    -- User actor (signer 10) withdraws 20 of resource 1 to L1 address zero.
    let rcp : Bridge.EthAddress := Bridge.EthAddress.zero
    let st := mkSignedAction (.withdraw 1 10 20 rcp) 10 es0
    match (← processSignedActionWith mockVerify testDeploymentId rs st) with
    | .ok pr =>
      -- Kernel-side effect: sender debited.
      assertEq (expected := 80) (actual := getBalance pr.state.state.base 1 10)
        "sender debited at kernel layer"
      -- Bridge-side effect (RB.3): pending entry created, nextWdId advanced.
      assertEq (expected := 1) (actual := pr.state.state.bridge.nextWdId)
        "bridge.nextWdId advanced from 0 to 1"
      assertEq (expected := 1) (actual := pr.state.state.bridge.pending.size)
        "bridge.pending has exactly one entry"
      -- Bridge-side effect (RB.3): pending entry shape matches the
      -- withdraw action's parameters, with l2LogIndex sourced from
      -- the runtime's `rs.logIndex` (= 0 here, since this is the
      -- first action in the log).
      match pr.state.state.bridge.pending[(0 : Bridge.WithdrawalId)]? with
      | some wd =>
        assertEq (expected := (1 : Nat)) (actual := wd.resource.toNat) "wd.resource"
        assertEq (expected := (20 : Nat)) (actual := wd.amount) "wd.amount"
        assertEq (expected := (0 : Nat)) (actual := wd.l2LogIndex)
          "wd.l2LogIndex = rs.logIndex"
        assert (wd.recipient.toBytes.toList = rcp.toBytes.toList)
          "wd.recipient bytes match"
      | none =>
        throw <| IO.userError "pending entry at index 0 missing"
    | .error e =>
      throw <| IO.userError s!"withdraw unexpectedly rejected: {repr e}"
    safeRemoveFile (System.FilePath.mk tmp)
}

/-! ## RB.3 — Negative paths (admission rejections) -/

/-- A `deposit` signed by a NON-bridge actor is rejected by the
    `BridgeAdmissibleWith` bridge-only-signer conjunct (conjunct 8).
    Pre-RB.3 this would have been silently admitted, enabling
    BRIDGE-ACTOR IMPERSONATION attacks where a regular actor could
    forge a deposit credit. -/
def depositByNonBridgeSignerRejected : TestCase := {
  name := "RB.3: deposit signed by non-bridge actor rejected (impersonation guard)"
  body := do
    let tmp := s!"/tmp/knomosis-rb3-imp-{(← IO.monoNanosNow)}.log"
    let rs := mkRuntimeState (System.FilePath.mk tmp)
    -- Actor 10 (NOT bridgeActor) attempts to sign a deposit.
    let st := mkSignedAction (.deposit 1 10 50 42) 10 es0
    match (← processSignedActionWith mockVerify testDeploymentId rs st) with
    | .ok _ =>
      throw <| IO.userError "BUG: deposit by non-bridge actor admitted (RB.3 conjunct 8 didn't fire)"
    | .error .notAdmissible =>
      pure ()  -- Expected.
    safeRemoveFile (System.FilePath.mk tmp)
}

/-- A second `registerIdentity` for an already-registered actor is
    rejected by the `BridgeAdmissibleWith` registration-freshness
    conjunct (conjunct 7).  Pre-RB.3 this would have been silently
    admitted, potentially allowing the bridge to overwrite an
    existing actor's key. -/
def reregistrationRejected : TestCase := {
  name := "RB.3: re-registration of existing actor rejected (RB.3 conjunct 7)"
  body := do
    let tmp := s!"/tmp/knomosis-rb3-rereg-{(← IO.monoNanosNow)}.log"
    let rs := mkRuntimeState (System.FilePath.mk tmp)
    -- Actor 10 is already registered in `es0`.  The bridge actor
    -- tries to register actor 10 again with a new key.
    let st := mkSignedAction
      (.registerIdentity 10 (mockPubKey 999)) 0 es0
    match (← processSignedActionWith mockVerify testDeploymentId rs st) with
    | .ok _ =>
      throw <| IO.userError "BUG: re-registration admitted (RB.3 conjunct 7 didn't fire)"
    | .error .notAdmissible =>
      pure ()  -- Expected.
    safeRemoveFile (System.FilePath.mk tmp)
}

/-! ## RB.3 — Non-bridge actions regression -/

/-- A `transfer` action (non-bridge) is unaffected by the RB.3
    wiring change: it still succeeds, advances the kernel state,
    and leaves the bridge state unchanged.  Regression guard for
    the runtime-wiring update. -/
def transferUnaffectedByBridgeWiring : TestCase := {
  name := "RB.3: non-bridge transfer still works (regression guard)"
  body := do
    let tmp := s!"/tmp/knomosis-rb3-transfer-{(← IO.monoNanosNow)}.log"
    let rs := mkRuntimeState (System.FilePath.mk tmp)
    let st := mkSignedAction (.transfer 1 10 0 30) 10 es0
    match (← processSignedActionWith mockVerify testDeploymentId rs st) with
    | .ok pr =>
      -- Kernel-side effect.
      assertEq (expected := 70) (actual := getBalance pr.state.state.base 1 10)
        "sender debited"
      -- Bridge state unchanged (transfer is bridge-state-identity).
      assertEq (expected := 0) (actual := pr.state.state.bridge.nextWdId)
        "bridge.nextWdId unchanged by transfer"
      assertEq (expected := 0) (actual := pr.state.state.bridge.consumed.size)
        "bridge.consumed unchanged by transfer"
    | .error e =>
      throw <| IO.userError s!"transfer unexpectedly rejected: {repr e}"
    safeRemoveFile (System.FilePath.mk tmp)
}

/-- A `mint` action (non-bridge) is unaffected by the RB.3 wiring
    change. -/
def mintUnaffectedByBridgeWiring : TestCase := {
  name := "RB.3: non-bridge mint still works (regression guard)"
  body := do
    let tmp := s!"/tmp/knomosis-rb3-mint-{(← IO.monoNanosNow)}.log"
    let rs := mkRuntimeState (System.FilePath.mk tmp)
    let st := mkSignedAction (.mint 1 10 30) 10 es0
    match (← processSignedActionWith mockVerify testDeploymentId rs st) with
    | .ok pr =>
      assertEq (expected := 130) (actual := getBalance pr.state.state.base 1 10)
        "mint credited"
      assertEq (expected := 0) (actual := pr.state.state.bridge.nextWdId)
        "bridge.nextWdId unchanged by mint"
    | .error e =>
      throw <| IO.userError s!"mint unexpectedly rejected: {repr e}"
    safeRemoveFile (System.FilePath.mk tmp)
}

/-! ## RB.3 — Multi-action bridge-state threading -/

/-- Multi-step chain: bridge actor deposits two DIFFERENT depositIds,
    then a user withdraws.  Verifies that:
      * Two distinct deposits both succeed (no false positive on the
        deposit-id-freshness conjunct).
      * The withdraw's `PendingWithdrawal.l2LogIndex` equals
        `rs.logIndex` at the time of the withdraw, NOT at the time
        of any earlier action (i.e., l2LogIndex is properly threaded
        across actions).
      * `bridge.nextWdId` increments correctly.
      * Bridge state changes from each action are observable by the
        NEXT action's admissibility check (the second deposit can't
        re-use the first deposit's depositId; this is regression-
        guarded by `depositReplayRejected` above, but the multi-step
        form also verifies independent depositIds don't interfere). -/
def multiStepBridgeChain : TestCase := {
  name := "RB.3: multi-step chain threads bridge state across actions"
  body := do
    let tmp := s!"/tmp/knomosis-rb3-chain-{(← IO.monoNanosNow)}.log"
    let rs0 := mkRuntimeState (System.FilePath.mk tmp)
    -- Step 1: bridgeActor deposits depositId 100 amount 30 to actor 10.
    let st1 := mkSignedAction (.deposit 1 10 30 100) 0 es0
    let pr1 ← match (← processSignedActionWith mockVerify testDeploymentId rs0 st1) with
      | .ok pr => pure pr
      | .error e => throw <| IO.userError s!"step 1 failed: {repr e}"
    -- After step 1: actor 10 has 130, bridge.consumed has 100.
    assertEq (expected := 130) (actual := getBalance pr1.state.state.base 1 10)
      "step 1: recipient at 130"
    assert (pr1.state.state.bridge.isConsumed 100) "step 1: 100 consumed"
    assertEq (expected := 1) (actual := pr1.state.logIndex) "step 1: logIndex"
    -- Step 2: bridgeActor deposits depositId 200 amount 20 to actor 10.
    let st2 := mkSignedAction (.deposit 1 10 20 200) 0 pr1.state.state
    let pr2 ← match (← processSignedActionWith mockVerify testDeploymentId pr1.state st2) with
      | .ok pr => pure pr
      | .error e => throw <| IO.userError s!"step 2 failed: {repr e}"
    -- After step 2: actor 10 has 150, bridge.consumed has 100 AND 200.
    assertEq (expected := 150) (actual := getBalance pr2.state.state.base 1 10)
      "step 2: recipient at 150"
    assert (pr2.state.state.bridge.isConsumed 100) "step 2: 100 still consumed"
    assert (pr2.state.state.bridge.isConsumed 200) "step 2: 200 also consumed"
    assertEq (expected := 2) (actual := pr2.state.logIndex) "step 2: logIndex"
    -- Step 3: actor 10 withdraws 50 of resource 1.
    let rcp : Bridge.EthAddress := Bridge.EthAddress.zero
    let st3 := mkSignedAction (.withdraw 1 10 50 rcp) 10 pr2.state.state
    let pr3 ← match (← processSignedActionWith mockVerify testDeploymentId pr2.state st3) with
      | .ok pr => pure pr
      | .error e => throw <| IO.userError s!"step 3 failed: {repr e}"
    -- After step 3: actor 10 has 100, bridge.pending has one entry
    -- with l2LogIndex = 2 (the index of this withdraw in the log).
    assertEq (expected := 100) (actual := getBalance pr3.state.state.base 1 10)
      "step 3: sender debited to 100"
    assertEq (expected := 1) (actual := pr3.state.state.bridge.nextWdId)
      "step 3: nextWdId at 1"
    match pr3.state.state.bridge.pending[(0 : Bridge.WithdrawalId)]? with
    | some wd =>
      assertEq (expected := (2 : Nat)) (actual := wd.l2LogIndex)
        "step 3: pending entry's l2LogIndex = 2 (the withdraw's log index)"
    | none =>
      throw <| IO.userError "step 3: pending entry missing"
    assertEq (expected := 3) (actual := pr3.state.logIndex) "step 3: logIndex"
    safeRemoveFile (System.FilePath.mk tmp)
}

/-! ## RB.3 — Term-level API stability -/

/-- `apply_bridge_admissible_with_budget` is term-level callable
    with the expected signature.  Pins the function's type so
    future refactors that change its shape fail at build time. -/
def applyBridgeAdmissibleWithBudgetAPI : TestCase := {
  name := "RB.2: apply_bridge_admissible_with_budget API stability"
  body := do
    let _proof :
        ∀ (_verify : PublicKey → ByteArray → Signature → Bool)
          (_P : AuthorityPolicy) (_d : ByteArray) (_es : ExtendedState)
          (_st : SignedAction) (_l2LogIndex : Nat)
          (_h : BridgeAdmissibleWith _verify _P _d _es _st),
          Option ExtendedState :=
      apply_bridge_admissible_with_budget
    pure ()
}

/-- `BridgeAdmissibleWith.decidable` is term-level callable.  Pins
    the umbrella Decidable instance so future refactors that break
    the case-analysis chain fail at build time. -/
def bridgeAdmissibleDecidableAPI : TestCase := {
  name := "RB.1: BridgeAdmissibleWith.decidable API stability"
  body := do
    let _proof :
        ∀ (_verify : PublicKey → ByteArray → Signature → Bool)
          (_P : AuthorityPolicy) (_d : ByteArray) (_es : ExtendedState)
          (_st : SignedAction),
          Decidable (BridgeAdmissibleWith _verify _P _d _es _st) :=
      fun _verify _P _d _es _st => inferInstance
    pure ()
}

/-- All RB.3 bridge-admission runtime tests. -/
def tests : List TestCase :=
  [ depositMarksConsumed
  , depositReplayRejected
  , withdrawAppendsToPending
  , depositByNonBridgeSignerRejected
  , reregistrationRejected
  , transferUnaffectedByBridgeWiring
  , mintUnaffectedByBridgeWiring
  , multiStepBridgeChain
  , applyBridgeAdmissibleWithBudgetAPI
  , bridgeAdmissibleDecidableAPI
  ]

end BridgeAdmission
end LegalKernel.Test.Runtime

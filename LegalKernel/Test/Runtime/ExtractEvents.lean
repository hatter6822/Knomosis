/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Runtime.ExtractEvents — RH-D / WU GP.6.3.

Tests the per-frame event-extraction core
(`LegalKernel.Runtime.extractEventsStepWith`) that backs the
`knomosis extract-events` subcommand.  The load-bearing property:
replaying a log entry through `extractEventsStepWith` reconstructs
the EXACT `(post-state, events)` the production runtime
(`processSignedActionWith`) produced when it wrote that entry — so
the events `extract-events` streams to subscribers are byte-identical
to the runtime's.

Uses `mockVerify` / `mockSign` (the Lean-level `Verify` opaque
returns `false`, so signed frames can only be exercised with the
test adaptor — exactly as the `replay-up-to` / bridge-admission
suites do).
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Runtime
namespace ExtractEvents

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding
open LegalKernel.Events
open LegalKernel.Runtime
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

/-- Non-empty deployment id (mirrors the bridge-admission suite). -/
def testDeploymentId : ByteArray := ByteArray.mk #[0xCA, 0xFE, 0xBA, 0xBE]

/-- Unrestricted authority policy. -/
def policy : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- Genesis: bridge actor (id 0) + user (id 10) registered; user
    holds 100 of resource 1; budget admits 100 actions/epoch. -/
def es0 : ExtendedState :=
  let base0 : State := setBalance emptyState 1 10 100
  let registry := (KeyRegistry.empty.register 0 (mockPubKey 0)).register 10 (mockPubKey 10)
  { base          := base0
  , nonces        := NonceState.empty
  , registry      := registry
  , bridge        := BridgeState.empty
  , localPolicies := LocalPolicies.empty
  , epochBudgets  := EpochBudgetState.empty
  , budgetPolicy  := .bounded 100 1 1 }

/-- A `RuntimeState` over `es0`. -/
def mkRuntimeState (path : System.FilePath) : RuntimeState :=
  { policy       := policy
  , state        := es0
  , prevHash     := zeroHash
  , logIndex     := 0
  , logPath      := path
  , deploymentId := testDeploymentId }

/-- Build a mock-signed `SignedAction` accepted by `mockVerify`. -/
def mkSignedAction (action : Action) (signer : ActorId) (es : ExtendedState) : SignedAction :=
  let nonce := expectsNonce es signer
  let msg := signingInput action signer nonce testDeploymentId
  let sig := mockSign (mockPubKey signer.toNat) msg
  ⟨action, signer, nonce, sig⟩

/-- The headline property: for a transfer, `extractEventsStepWith`
    reconstructs exactly the runtime's `(state, events)`. -/
def transferStepMatchesRuntime : TestCase := {
  name := "GP.6.3: extractEventsStepWith reconstructs the runtime's transfer events"
  body := do
    let tmp := s!"/tmp/knomosis-extract-transfer-{(← IO.monoNanosNow)}.log"
    let rs := mkRuntimeState (System.FilePath.mk tmp)
    -- User 10 transfers 30 of resource 1 to actor 0.
    let st := mkSignedAction (.transfer 1 10 0 30) 10 es0
    match (← processSignedActionWith mockVerify testDeploymentId rs st) with
    | .error e => throw <| IO.userError s!"runtime rejected transfer: {repr e}"
    | .ok pr =>
      -- Replay the SAME entry through the extract-events step.
      match extractEventsStepWith mockVerify testDeploymentId policy
              rs.state rs.prevHash pr.entry rs.logIndex 0 with
      | .error err => throw <| IO.userError s!"extractEventsStepWith failed: {repr err}"
      | .ok (newState, events) =>
        -- (1) Events are byte-identical to the runtime's.
        assertEq pr.events events "extracted events match runtime events"
        -- (2) Events are non-empty and contain the nonce advance + both
        --     balance changes (sender 10, receiver 0).
        assert (events.length ≥ 2) s!"expected ≥2 events, got {events.length}"
        -- (3) Post-state agrees with the runtime's (same encoding).
        assertEq
          (Encodable.encode (T := ExtendedState) pr.state.state)
          (Encodable.encode (T := ExtendedState) newState)
          "extracted post-state matches runtime post-state"
    safeRemove (System.FilePath.mk tmp)
}
where
  safeRemove (p : System.FilePath) : IO Unit := do
    if (← p.pathExists) then IO.FS.removeFile p

/-- A bridge `deposit` emits a `depositCredited` event — proving the
    step uses the FULL admission path (`apply_bridge_admissible_with_budget`),
    not `kernelOnlyApply` (which would skip the bridge sub-state and
    drop the bridge event). -/
def depositEmitsBridgeEvent : TestCase := {
  name := "GP.6.3: extractEventsStepWith emits the bridge depositCredited event"
  body := do
    let tmp := s!"/tmp/knomosis-extract-deposit-{(← IO.monoNanosNow)}.log"
    let rs := mkRuntimeState (System.FilePath.mk tmp)
    -- Bridge actor (0) deposits 50 of resource 1 to actor 10, depositId 42.
    let st := mkSignedAction (.deposit 1 10 50 42) 0 es0
    match (← processSignedActionWith mockVerify testDeploymentId rs st) with
    | .error e => throw <| IO.userError s!"runtime rejected deposit: {repr e}"
    | .ok pr =>
      match extractEventsStepWith mockVerify testDeploymentId policy
              rs.state rs.prevHash pr.entry rs.logIndex 0 with
      | .error err => throw <| IO.userError s!"extractEventsStepWith failed: {repr err}"
      | .ok (_, events) =>
        assertEq pr.events events "deposit: extracted events match runtime"
        let hasDeposit := events.any (fun e => e.tag == 10)
        assert hasDeposit "expected a depositCredited (tag 10) event from the bridge step"
    safeRemove (System.FilePath.mk tmp)
}
where
  safeRemove (p : System.FilePath) : IO Unit := do
    if (← p.pathExists) then IO.FS.removeFile p

/-- A two-entry sequence: each step's extracted events match the
    runtime's, and the chain threads correctly. -/
def twoStepChainMatchesRuntime : TestCase := {
  name := "GP.6.3: two-step chain extracts the runtime's events at each step"
  body := do
    let tmp := s!"/tmp/knomosis-extract-chain-{(← IO.monoNanosNow)}.log"
    let rs0 := mkRuntimeState (System.FilePath.mk tmp)
    let st1 := mkSignedAction (.transfer 1 10 0 30) 10 es0
    match (← processSignedActionWith mockVerify testDeploymentId rs0 st1) with
    | .error e => throw <| IO.userError s!"step 1 rejected: {repr e}"
    | .ok pr1 =>
      -- Extract step 1.
      match extractEventsStepWith mockVerify testDeploymentId policy
              rs0.state rs0.prevHash pr1.entry 0 0 with
      | .error err => throw <| IO.userError s!"extract step 1 failed: {repr err}"
      | .ok (state1, ev1) =>
        assertEq pr1.events ev1 "step-1 events match runtime"
        -- Step 2: another transfer from the post-state-1 runtime state.
        let st2 := mkSignedAction (.transfer 1 0 10 5) 0 pr1.state.state
        match (← processSignedActionWith mockVerify testDeploymentId pr1.state st2) with
        | .error e => throw <| IO.userError s!"step 2 rejected: {repr e}"
        | .ok pr2 =>
          match extractEventsStepWith mockVerify testDeploymentId policy
                  state1 (LogEntry.hash pr1.entry) pr2.entry 1 0 with
          | .error err => throw <| IO.userError s!"extract step 2 failed: {repr err}"
          | .ok (_, ev2) =>
            assertEq pr2.events ev2 "step-2 events match runtime"
    safeRemove (System.FilePath.mk tmp)
}
where
  safeRemove (p : System.FilePath) : IO Unit := do
    if (← p.pathExists) then IO.FS.removeFile p

/-- A tampered predecessor hash is rejected with `chainBroken`
    (the chain check runs before admissibility). -/
def chainBrokenRejected : TestCase := {
  name := "GP.6.3: extractEventsStepWith rejects a broken hash chain"
  body := do
    let tmp := s!"/tmp/knomosis-extract-chain-broken-{(← IO.monoNanosNow)}.log"
    let rs := mkRuntimeState (System.FilePath.mk tmp)
    let st := mkSignedAction (.transfer 1 10 0 30) 10 es0
    match (← processSignedActionWith mockVerify testDeploymentId rs st) with
    | .error e => throw <| IO.userError s!"runtime rejected transfer: {repr e}"
    | .ok pr =>
      -- Replay with a WRONG prevHash (a non-zero hash where zeroHash
      -- is expected): the chain check must fire.
      let wrongPrev : ContentHash := hashStream [0xDE, 0xAD, 0xBE, 0xEF]
      match extractEventsStepWith mockVerify testDeploymentId policy
              rs.state wrongPrev pr.entry 0 0 with
      | .error (.chainBroken i) => assertEq (0 : Nat) i "chainBroken at idx 0"
      | .error other => throw <| IO.userError s!"expected chainBroken, got {repr other}"
      | .ok _ => throw <| IO.userError "expected chainBroken, but step succeeded"
    safeRemove (System.FilePath.mk tmp)
}
where
  safeRemove (p : System.FilePath) : IO Unit := do
    if (← p.pathExists) then IO.FS.removeFile p

/-- API stability: `extractEventsStepWith` keeps its call signature
    (applied form, since `epochLength` is a defaulted parameter). -/
def extractStepApiStable : TestCase := {
  name := "GP.6.3: extractEventsStepWith API stable"
  body := do
    let entry : LogEntry :=
      ⟨zeroHash, mkSignedAction (.transfer 1 10 0 0) 10 es0, zeroHash⟩
    let _result : Except ReplayError (ExtendedState × List Event) :=
      extractEventsStepWith mockVerify ByteArray.empty policy es0 zeroHash entry 0 0
    pure ()
}

/-- API stability: the state-agreement theorem keeps its signature. -/
def stateAgreementApiStable : TestCase := {
  name := "GP.6.3: extractEventsStepWith_state_eq_replayStepWith API stable"
  body := do
    let _proof : ∀ (verify : PublicKey → ByteArray → Signature → Bool)
        (d : ByteArray) (P : AuthorityPolicy) (state : ExtendedState)
        (prevHash : ContentHash) (e : LogEntry) (idx : Nat) (epochLength : Nat),
        (extractEventsStepWith verify d P state prevHash e idx epochLength).map Prod.fst =
        replayStepWith verify d P state prevHash e idx epochLength :=
      extractEventsStepWith_state_eq_replayStepWith
    pure ()
}

/-! ## Wire-framing helpers (`docs/abi.md` §11.10)

The `extract-events` stdin/stdout protocol's pure byte helpers
(`beU64` / `beU32` / `beToNat` / `encodeExtractResponse`) live in
`EventStream` so they are unit-testable independent of the IO driver.
The big-endian convention MUST match the Rust `SubprocessExtractor`
(`u64::from_be_bytes` / `u32::from_be_bytes`). -/

/-- `beU64` / `beU32` produce the documented big-endian widths +
    byte order (hand-spelled, non-circular). -/
def beWidthsAndOrder : TestCase := {
  name := "GP.6.3: beU64/beU32 are 8/4 big-endian bytes"
  body := do
    assertEq (8 : Nat) (beU64 0).size "beU64 width"
    assertEq (4 : Nat) (beU32 0).size "beU32 width"
    -- 0x0102030405060708 big-endian.
    assertEq #[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
      (beU64 0x0102030405060708).data "beU64 BE bytes"
    -- 0x0A0B0C0D big-endian.
    assertEq #[0x0A, 0x0B, 0x0C, 0x0D] (beU32 0x0A0B0C0D).data "beU32 BE bytes"
    -- Truncation: only the low 8 bytes survive (matches the Rust
    -- `seq: u64` field width).
    assertEq #[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2a]
      (beU64 42).data "beU64 small value"
}

/-- `beToNat` inverts `beU64` / `beU32` (round-trip on the wire
    integer widths), matching the Rust `from_be_bytes` reader. -/
def beRoundTrip : TestCase := {
  name := "GP.6.3: beToNat inverts beU64/beU32"
  body := do
    for n in [0, 1, 42, 255, 256, 65535, 1700000000, 18446744073709551615] do
      assertEq n (beToNat (beU64 n) 0 8) s!"beU64 round-trip {n}"
    for n in [0, 1, 255, 256, 65535, 16777216, 4294967295] do
      assertEq n (beToNat (beU32 n) 0 4) s!"beU32 round-trip {n}"
    -- Reading at an offset (the header's `len` field sits at byte 8).
    let header := beU64 7 ++ beU32 100
    assertEq 7 (beToNat header 0 8) "seq at offset 0"
    assertEq 100 (beToNat header 8 4) "len at offset 8"
}

/-- `encodeExtractResponse` lays out `seq ‖ count ‖ K×(len ‖ bytes)`
    exactly, for 0, 1, and 2 events — the response frame the Rust
    `SubprocessExtractor::extract_via` parses. -/
def encodeResponseLayout : TestCase := {
  name := "GP.6.3: encodeExtractResponse byte layout"
  body := do
    -- Empty event list: just the 12-byte header (seq + count 0).
    let empty := encodeExtractResponse 5 []
    assertEq (12 : Nat) empty.size "empty response is header-only"
    assertEq 5 (beToNat empty 0 8) "empty response seq"
    assertEq 0 (beToNat empty 8 4) "empty response count 0"
    -- One event: header + (4-byte len + Event.encode bytes).
    let ev : Event := .gasPoolClaim 0 2 250
    let evBytes := ByteArray.mk (Encodable.encode (T := Event) ev).toArray
    let one := encodeExtractResponse 9 [ev]
    assertEq 9 (beToNat one 0 8) "one-event seq"
    assertEq 1 (beToNat one 8 4) "one-event count"
    assertEq evBytes.size (beToNat one 12 4) "one-event payload length prefix"
    assertEq (12 + 4 + evBytes.size) one.size "one-event total size"
    -- The payload bytes after the 4-byte length prefix equal Event.encode.
    assertEq evBytes.data ((one.extract 16 one.size)).data "one-event payload bytes"
    -- Two events: count 2, and the total size accounts for both
    -- (len-prefix + bytes) records.
    let ev2 : Event := .balanceChanged 7 42 100 250
    let ev2Bytes := ByteArray.mk (Encodable.encode (T := Event) ev2).toArray
    let two := encodeExtractResponse 1 [ev, ev2]
    assertEq 2 (beToNat two 8 4) "two-event count"
    assertEq (12 + 4 + evBytes.size + 4 + ev2Bytes.size) two.size "two-event total size"
}

/-- All tests. -/
def tests : List TestCase :=
  [ transferStepMatchesRuntime
  , depositEmitsBridgeEvent
  , twoStepChainMatchesRuntime
  , chainBrokenRejected
  , beWidthsAndOrder
  , beRoundTrip
  , encodeResponseLayout
  , extractStepApiStable
  , stateAgreementApiStable ]

end ExtractEvents
end LegalKernel.Test.Runtime

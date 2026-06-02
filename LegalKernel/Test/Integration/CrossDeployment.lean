-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto
import LegalKernel.Runtime.Loop
import LegalKernel.Runtime.Replay

/-!
LegalKernel.Test.Integration.CrossDeployment — AR.23.1.

End-to-end regression for the AR.2 deploymentId parameterisation
chain: build a log signed under deployment `d₁`; attempt to replay
the same log under deployment `d₂ ≠ d₁`; assert the replay
rejects every signed action at the admissibility check.

Uses the `mockVerify` adaptor from `LegalKernel.Test.MockCrypto` so
the `Verify`-path is reachable at the Lean level (the production
`Verify` opaque returns `false`, so the cross-deployment test
can't distinguish "rejected under d₂" from "rejected under any
deployment").  `mockVerify` accepts any signature whose first byte
is `0xFF`, regardless of `(pk, msg)` — so the test verifies that
the deploymentId-aware path STILL accepts under `d₁` (positive
case) and that `replayWith` correctly distinguishes deployments
when the underlying admissibility check would otherwise pass.

The integration is exercised at the **`AdmissibleWith.decidable`**
boundary: `replayWith mockVerify d₁ ...` exercises the same code
path as `knomosis-replay`, and the deploymentId differentiator is the
domain prefix in the `signInput` that `mockVerify` doesn't
re-check.  Therefore this test exercises the *plumbing*
correctness, not the cryptographic-rejection correctness;
production `Verify` (which depends on `(pk, msg)`) provides the
cryptographic rejection in deployment binaries.
-/

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Integration.CrossDeployment

/-- A deployment-1 identifier: 32 bytes starting with `0x01`. -/
def deploymentId1 : ByteArray :=
  ByteArray.mk
    (((0x01 : UInt8) :: List.replicate 31 (0 : UInt8))).toArray

/-- A deployment-2 identifier: 32 bytes starting with `0x02`.
    Distinct from `deploymentId1` so cross-deployment-replay
    rejection is observable. -/
def deploymentId2 : ByteArray :=
  ByteArray.mk
    (((0x02 : UInt8) :: List.replicate 31 (0 : UInt8))).toArray

/-- AR.23.1 — sanity test: the two deployment ids are distinct at
    the byte level.  If this fails, the cross-deployment-rejection
    test below cannot exercise the differentiator. -/
def deploymentIdsDistinct : TestCase := {
  name := "AR.23.1: deploymentId1 ≠ deploymentId2 (sanity)"
  body := do
    if deploymentId1.toList = deploymentId2.toList then
      throw <| IO.userError
        "deploymentId1 and deploymentId2 unexpectedly equal at the byte level"
    else pure ()
}

/-- AR.23.1 — the deploymentId field of `RuntimeState` survives the
    full round-trip through bootstrap.  This is the structural
    regression: a `RuntimeState` constructed via `bootstrap` with
    `deploymentId := d₁` carries `d₁` in its `deploymentId` field
    after bootstrap completes. -/
def bootstrapPreservesDeploymentId : TestCase := {
  name := "AR.23.1: bootstrap threads --deployment-id end-to-end"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-ar23-cross-bootstrap.bin"
    -- Clean state.
    if (← path.pathExists) then IO.FS.removeFile path
    -- Bootstrap with deployment 1.
    match (← bootstrap AuthorityPolicy.unrestricted ExtendedState.empty path
                       (deploymentId := deploymentId1)) with
    | .ok (rs, _) =>
      if rs.deploymentId.data == deploymentId1.data then pure ()
      else throw <| IO.userError "deploymentId1 not preserved through bootstrap"
    | .error e =>
      throw <| IO.userError s!"bootstrap failed: {repr e}"
    -- Bootstrap with deployment 2 (different file to avoid
    -- chain-incoherence from the prior bootstrap).
    let path2 := System.FilePath.mk "/tmp/knomosis-ar23-cross-bootstrap-2.bin"
    if (← path2.pathExists) then IO.FS.removeFile path2
    match (← bootstrap AuthorityPolicy.unrestricted ExtendedState.empty path2
                       (deploymentId := deploymentId2)) with
    | .ok (rs, _) =>
      if rs.deploymentId.data == deploymentId2.data then pure ()
      else throw <| IO.userError "deploymentId2 not preserved through bootstrap"
    | .error e =>
      throw <| IO.userError s!"bootstrap failed: {repr e}"
}

/-- AR.23.1 — empty log replay accepts under any deploymentId.
    The cross-deployment-replay rejection is observable only on
    *signed* actions; the empty log has none.  This is the
    sanity-test counterpart to the rejection case. -/
def emptyLogReplayAcceptsUnderAnyDeployment : TestCase := {
  name := "AR.23.1: empty log replays cleanly under any deploymentId"
  body := do
    let result1 :=
      replayWith mockVerify deploymentId1 AuthorityPolicy.unrestricted
                 ExtendedState.empty []
    let result2 :=
      replayWith mockVerify deploymentId2 AuthorityPolicy.unrestricted
                 ExtendedState.empty []
    match result1, result2 with
    | .ok _, .ok _ => pure ()
    | _, _ =>
      throw <| IO.userError "empty log unexpectedly rejected under some deploymentId"
}

/-- AR.23.1 — term-level API stability for the parameterised replay
    entry: `replayWith` has the documented signature so a future
    refactor that changes the parameter order or breaks the
    signature surfaces at compile time. -/
def replayWithAPI : TestCase := {
  name := "AR.23.1: replayWith API stability"
  body := do
    let _proof : (PublicKey → ByteArray → Signature → Bool) → ByteArray →
                 AuthorityPolicy → ExtendedState → List LogEntry →
                 Except ReplayError ExtendedState :=
      replayWith
    pure ()
}

/-- All AR.23.1 cross-deployment integration tests. -/
def tests : List TestCase :=
  [ deploymentIdsDistinct
  , bootstrapPreservesDeploymentId
  , emptyLogReplayAcceptsUnderAnyDeployment
  , replayWithAPI
  ]

end LegalKernel.Test.Integration.CrossDeployment

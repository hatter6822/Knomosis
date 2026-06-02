-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Runtime.GasPoolSidecar — Workstream GP.7.4 gas-pool
config sidecar + config-driven genesis-wiring tests.

Covers the pure `encode` / `decode` round-trip (the value-level
stand-in for the closed-form theorem, à la `BudgetSidecar`), the IO
`checkConsistent` / `writeSidecarIfAbsent` orchestration (including the
opt-out `none` ↔ no-sidecar discipline + the "log had the gas pool but
this run disables it" rejection), and the `*OfConfig` opt-in genesis
builders (`Bridge.gasPoolGenesisStateOfConfig` / `…PolicyOfConfig`).
-/

import LegalKernel.Test.Framework
import LegalKernel.Runtime.GasPoolSidecar
import LegalKernel.Bridge.GasPoolPolicy

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Runtime
open LegalKernel.Runtime.GasPoolSidecar
open LegalKernel.Test

namespace LegalKernel.Test.Runtime.GasPoolSidecarTests

/-- A representative spread of gas-pool configs (round, asymmetric,
    `u64`-max boundary). -/
def sampleConfigs : List GasPoolConfig :=
  [ { maxDrainPerActionEth := 0, maxDrainPerActionBold := 0 }
  , { maxDrainPerActionEth := 1000, maxDrainPerActionBold := 3000 }
  , { maxDrainPerActionEth := 1, maxDrainPerActionBold := 18446744073709551615 }
  , { maxDrainPerActionEth := 4294967296, maxDrainPerActionBold := 1000000 } ]

/-- `decode (encode c) = some c` across the sample spread (value-level
    stand-in for the round-trip theorem). -/
def gasPoolSidecarRoundTrip : TestCase := {
  name := "GasPoolSidecar.decode (encode c) = some c (round-trip)"
  body := do
    for c in sampleConfigs do
      match decode (encode c) with
      | some c' => assertEq c c' s!"round-trip for {repr c}"
      | none => throw <| IO.userError s!"decode failed for encode {repr c}"
}

/-- A trailing newline + CRLF + extra spaces decode cleanly. -/
def gasPoolSidecarTolerantDecode : TestCase := {
  name := "GasPoolSidecar.decode tolerates whitespace / CRLF"
  body := do
    let expected : GasPoolConfig := { maxDrainPerActionEth := 1000, maxDrainPerActionBold := 3000 }
    assertEq (some expected) (decode s!"{magic} 1000 3000\n") "trailing newline"
    assertEq (some expected) (decode s!"{magic} 1000 3000\r\n") "CRLF"
    assertEq (some expected) (decode s!"{magic}  1000   3000  ") "extra spaces"
}

/-- `decode` rejects a wrong magic, wrong field count, and non-Nat. -/
def gasPoolSidecarDecodeRejects : TestCase := {
  name := "GasPoolSidecar.decode rejects malformed lines"
  body := do
    assert (decode "wrong/magic 1 1" |>.isNone) "wrong magic rejected"
    assert (decode s!"{magic} 1" |>.isNone) "too few fields rejected"
    assert (decode s!"{magic} 1 1 1" |>.isNone) "too many fields rejected"
    assert (decode s!"{magic} 1 x" |>.isNone) "non-Nat field rejected"
    assert (decode "" |>.isNone) "empty rejected"
}

/-- A unique temp path under `/tmp` for IO tests. -/
def tmpLog : IO System.FilePath := do
  pure (System.FilePath.mk s!"/tmp/knomosis-gaspoolsidecar-{(← IO.monoNanosNow)}.log")

/-- `checkConsistent` is OK when no sidecar exists, whether the gas pool
    is enabled (`some`, the writer creates it later) or disabled
    (`none`). -/
def gasPoolSidecarCheckAbsentOk : TestCase := {
  name := "GasPoolSidecar.checkConsistent: absent sidecar is OK (enabled or disabled)"
  body := do
    let log ← tmpLog
    match (← checkConsistent log (some { maxDrainPerActionEth := 1000, maxDrainPerActionBold := 3000 })) with
    | .ok () => pure ()
    | .error m => throw <| IO.userError s!"absent sidecar (enabled) should be OK, got: {m}"
    match (← checkConsistent log none) with
    | .ok () => pure ()
    | .error m => throw <| IO.userError s!"absent sidecar (disabled) should be OK, got: {m}"
}

/-- A disabled gas pool (`none`) writes NO sidecar (preserving the
    pre-GP.7.4 on-disk footprint); an enabled config writes one, a
    matching check passes, a mismatched check fails, and a
    gas-pool-DISABLED run against an enabled log is rejected. -/
def gasPoolSidecarWriteAndCheck : TestCase := {
  name := "GasPoolSidecar.write/check: disabled skipped, enabled enforced"
  body := do
    -- Disabled: no sidecar written.
    let logD ← tmpLog
    writeSidecarIfAbsent logD none
    assert (! (← (sidecarPath logD).pathExists)) "disabled gas pool must not create a sidecar"
    -- Enabled: sidecar written; matching check OK.
    let log ← tmpLog
    let cfg : GasPoolConfig := { maxDrainPerActionEth := 1000, maxDrainPerActionBold := 3000 }
    writeSidecarIfAbsent log (some cfg)
    assert (← (sidecarPath log).pathExists) "enabled gas pool must create a sidecar"
    match (← checkConsistent log (some cfg)) with
    | .ok () => pure ()
    | .error m => throw <| IO.userError s!"matching config should pass, got: {m}"
    -- A DIFFERENT config (forgot/changed a cap) is rejected.
    match (← checkConsistent log (some { maxDrainPerActionEth := 999, maxDrainPerActionBold := 3000 })) with
    | .ok () => throw <| IO.userError "BUG: mismatched gas-pool config accepted"
    | .error _ => pure ()
    -- Disabling the gas pool on an enabled log is rejected.
    match (← checkConsistent log none) with
    | .ok () => throw <| IO.userError "BUG: gas-pool-disabled run accepted against an enabled log"
    | .error _ => pure ()
    IO.FS.removeFile (sidecarPath log)
}

/-- `writeSidecarIfAbsent` never clobbers an existing sidecar. -/
def gasPoolSidecarWriteIsIdempotent : TestCase := {
  name := "GasPoolSidecar.writeSidecarIfAbsent does not clobber"
  body := do
    let log ← tmpLog
    let cfg : GasPoolConfig := { maxDrainPerActionEth := 1000, maxDrainPerActionBold := 3000 }
    writeSidecarIfAbsent log (some cfg)
    -- A second write with a DIFFERENT config must not overwrite.
    writeSidecarIfAbsent log (some { maxDrainPerActionEth := 99, maxDrainPerActionBold := 99 })
    let contents ← IO.FS.readFile (sidecarPath log)
    match decode contents with
    | some persisted => assertEq cfg persisted "original config preserved (no clobber)"
    | none => throw <| IO.userError "sidecar became unreadable"
    IO.FS.removeFile (sidecarPath log)
}

/-- A corrupt sidecar is rejected with an error (not silently ignored). -/
def gasPoolSidecarCorruptRejected : TestCase := {
  name := "GasPoolSidecar.checkConsistent: corrupt sidecar is rejected"
  body := do
    let log ← tmpLog
    IO.FS.writeFile (sidecarPath log) "garbage not a gas-pool config\n"
    match (← checkConsistent log (some { maxDrainPerActionEth := 1000, maxDrainPerActionBold := 3000 })) with
    | .ok () => throw <| IO.userError "BUG: corrupt sidecar accepted"
    | .error _ => pure ()
    IO.FS.removeFile (sidecarPath log)
}

/-! ## Config-driven genesis-wiring builders (`*OfConfig`) -/

/-- Opt-OUT (`none`) is a no-op on both the state and the policy. -/
def gasPoolOfConfigNoneIsNoOp : TestCase := {
  name := "GasPool *OfConfig none: genesis + policy unchanged (opt-out)"
  body := do
    let es : ExtendedState := ExtendedState.empty
    assertEq es.localPolicies.size
      (gasPoolGenesisStateOfConfig es none).localPolicies.size
      "opt-out leaves localPolicies untouched"
    -- The policy half is `rfl`-equal; check it authorises like the base
    -- (unrestricted authorises everything).
    assert ((gasPoolGenesisPolicyOfConfig AuthorityPolicy.unrestricted none).authorized
              gasPoolActor (.transfer 0 gasPoolActor sequencerActor 5))
      "opt-out policy = base (unrestricted authorises the pool transfer)"
}

/-- Opt-IN (`some cfg`) declares the pool policy and bars pool
    meta-actions. -/
def gasPoolOfConfigSomeWiresBoth : TestCase := {
  name := "GasPool *OfConfig some: declares gasPoolPolicy + bars pool meta-actions"
  body := do
    let es : ExtendedState := ExtendedState.empty
    let cfg : GasPoolConfig := { maxDrainPerActionEth := 1000, maxDrainPerActionBold := 3000 }
    -- State half: gasPoolPolicy is declared for gasPoolActor.
    assertEq
      (expected := gasPoolPolicy 1000 3000)
      (actual := (gasPoolGenesisStateOfConfig es (some cfg)).localPolicies.lookup gasPoolActor)
      "opt-in declares gasPoolPolicy"
    -- Policy half: the pool may NOT revoke its own policy.
    if (gasPoolGenesisPolicyOfConfig AuthorityPolicy.unrestricted (some cfg)).authorized
         gasPoolActor .revokeLocalPolicy then
      throw <| IO.userError "opt-in policy admitted a pool revokeLocalPolicy"
    else pure ()
    -- … and the capped sequencer claim IS authorised (base unrestricted).
    assert ((gasPoolGenesisPolicyOfConfig AuthorityPolicy.unrestricted (some cfg)).authorized
              gasPoolActor (.transfer 0 gasPoolActor sequencerActor 1000))
      "opt-in policy authorises the capped sequencer claim"
}

/-- The full GP.7.4 sidecar + config-builder suite. -/
def tests : List TestCase :=
  [ gasPoolSidecarRoundTrip
  , gasPoolSidecarTolerantDecode
  , gasPoolSidecarDecodeRejects
  , gasPoolSidecarCheckAbsentOk
  , gasPoolSidecarWriteAndCheck
  , gasPoolSidecarWriteIsIdempotent
  , gasPoolSidecarCorruptRejected
  , gasPoolOfConfigNoneIsNoOp
  , gasPoolOfConfigSomeWiresBoth ]

end LegalKernel.Test.Runtime.GasPoolSidecarTests

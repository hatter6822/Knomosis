-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
-/

/-
LegalKernel.Test.Runtime.BudgetSidecar — GP.6.2 budget-config sidecar
tests.  Covers the pure `encode` / `decode` round-trip (standing in
for the closed-form theorem, which the string/Nat rendering makes
disproportionately painful), the `isDefault` predicate, and the IO
`checkConsistent` / `writeSidecarIfAbsent` orchestration.
-/

import LegalKernel.Test.Framework
import LegalKernel.Runtime.BudgetSidecar

open LegalKernel.Runtime
open LegalKernel.Runtime.BudgetSidecar
open LegalKernel.Test

namespace LegalKernel.Test.Runtime.BudgetSidecarTests

/-- A representative spread of configs (default, single-field, multi-byte). -/
def sampleConfigs : List BudgetConfig :=
  [ { freeTier := 0, actionCost := 1, currentEpoch := 0, epochLength := 0 }
  , { freeTier := 10, actionCost := 1, currentEpoch := 1, epochLength := 0 }
  , { freeTier := 5, actionCost := 3, currentEpoch := 7, epochLength := 100 }
  , { freeTier := 1000000, actionCost := 2, currentEpoch := 4294967296, epochLength := 64 }
  , { freeTier := 18446744073709551615, actionCost := 1, currentEpoch := 0, epochLength := 1 } ]

/-- `decode (encode c) = some c` across the sample spread (value-level
    stand-in for the round-trip theorem). -/
def budgetSidecarRoundTrip : TestCase := {
  name := "BudgetSidecar.decode (encode c) = some c (round-trip)"
  body := do
    for c in sampleConfigs do
      match decode (encode c) with
      | some c' => assertEq c c' s!"round-trip for {repr c}"
      | none => throw <| IO.userError s!"decode failed for encode {repr c}"
}

/-- A trailing newline + CRLF + extra spaces decode cleanly. -/
def budgetSidecarTolerantDecode : TestCase := {
  name := "BudgetSidecar.decode tolerates whitespace / CRLF"
  body := do
    let expected : BudgetConfig := { freeTier := 5, actionCost := 3, currentEpoch := 7, epochLength := 9 }
    assertEq (some expected) (decode s!"{magic} 5 3 7 9\n") "trailing newline"
    assertEq (some expected) (decode s!"{magic} 5 3 7 9\r\n") "CRLF"
    assertEq (some expected) (decode s!"{magic}  5   3 7   9  ") "extra spaces"
}

/-- `decode` rejects a wrong magic, wrong field count, and non-Nat. -/
def budgetSidecarDecodeRejects : TestCase := {
  name := "BudgetSidecar.decode rejects malformed lines"
  body := do
    assert (decode "wrong/magic 1 1 1 0" |>.isNone) "wrong magic rejected"
    assert (decode s!"{magic} 1 1 1" |>.isNone) "too few fields rejected"
    assert (decode s!"{magic} 1 1 1 0 0" |>.isNone) "too many fields rejected"
    assert (decode s!"{magic} 1 x 1 0" |>.isNone) "non-Nat field rejected"
    assert (decode "" |>.isNone) "empty rejected"
}

/-- `isDefault` is true only for `bounded 0 1 0` + no advancement. -/
def budgetSidecarIsDefault : TestCase := {
  name := "BudgetSidecar.isDefault detects the genesis-default config"
  body := do
    assert (isDefault { freeTier := 0, actionCost := 1, currentEpoch := 0, epochLength := 0 })
      "default config"
    assert (! isDefault { freeTier := 1, actionCost := 1, currentEpoch := 0, epochLength := 0 })
      "non-default freeTier"
    assert (! isDefault { freeTier := 0, actionCost := 1, currentEpoch := 0, epochLength := 5 })
      "non-default epochLength"
}

/-- A unique temp path under `/tmp` for IO tests. -/
def tmpLog : IO System.FilePath := do
  pure (System.FilePath.mk s!"/tmp/knomosis-budgetsidecar-{(← IO.monoNanosNow)}.log")

/-- `checkConsistent` is OK when no sidecar exists (the writer creates
    it later); `ofPolicy` builds the config from a policy. -/
def budgetSidecarCheckAbsentOk : TestCase := {
  name := "BudgetSidecar.checkConsistent: absent sidecar is OK"
  body := do
    let log ← tmpLog
    let cfg := ofPolicy (.bounded 10 1 1) 5
    match (← checkConsistent log cfg) with
    | .ok () => pure ()
    | .error m => throw <| IO.userError s!"absent sidecar should be OK, got: {m}"
}

/-- A default config writes NO sidecar (preserving the pre-GP.6.2
    on-disk footprint); a non-default config writes one, and a
    subsequent matching check passes while a mismatched check fails. -/
def budgetSidecarWriteAndCheck : TestCase := {
  name := "BudgetSidecar.write/check: default skipped, non-default enforced"
  body := do
    -- Default config: no sidecar written.
    let logD ← tmpLog
    let defCfg := ofPolicy (.bounded 0 1 0) 0
    writeSidecarIfAbsent logD defCfg
    assert (! (← (sidecarPath logD).pathExists)) "default config must not create a sidecar"
    -- Non-default config: sidecar written; matching check OK.
    let log ← tmpLog
    let cfg := ofPolicy (.bounded 10 1 1) 3
    writeSidecarIfAbsent log cfg
    assert (← (sidecarPath log).pathExists) "non-default config must create a sidecar"
    match (← checkConsistent log cfg) with
    | .ok () => pure ()
    | .error m => throw <| IO.userError s!"matching config should pass, got: {m}"
    -- A DIFFERENT config (forgot a flag) is rejected with an error.
    let wrong := ofPolicy (.bounded 99 1 1) 3
    match (← checkConsistent log wrong) with
    | .ok () => throw <| IO.userError "BUG: mismatched config accepted"
    | .error _ => pure ()
    -- A different epoch length is also rejected.
    let wrongEpoch := ofPolicy (.bounded 10 1 1) 7
    match (← checkConsistent log wrongEpoch) with
    | .ok () => throw <| IO.userError "BUG: mismatched epoch length accepted"
    | .error _ => pure ()
    -- Cleanup.
    IO.FS.removeFile (sidecarPath log)
}

/-- `writeSidecarIfAbsent` never clobbers an existing sidecar. -/
def budgetSidecarWriteIsIdempotent : TestCase := {
  name := "BudgetSidecar.writeSidecarIfAbsent does not clobber"
  body := do
    let log ← tmpLog
    let cfg := ofPolicy (.bounded 10 1 1) 3
    writeSidecarIfAbsent log cfg
    -- A second write with a DIFFERENT config must not overwrite.
    writeSidecarIfAbsent log (ofPolicy (.bounded 99 9 9) 9)
    let contents ← IO.FS.readFile (sidecarPath log)
    match decode contents with
    | some persisted => assertEq cfg persisted "original config preserved (no clobber)"
    | none => throw <| IO.userError "sidecar became unreadable"
    IO.FS.removeFile (sidecarPath log)
}

/-- A corrupt sidecar is rejected with an error (not silently ignored). -/
def budgetSidecarCorruptRejected : TestCase := {
  name := "BudgetSidecar.checkConsistent: corrupt sidecar is rejected"
  body := do
    let log ← tmpLog
    IO.FS.writeFile (sidecarPath log) "garbage not a budget config\n"
    match (← checkConsistent log (ofPolicy (.bounded 10 1 1) 3)) with
    | .ok () => throw <| IO.userError "BUG: corrupt sidecar accepted"
    | .error _ => pure ()
    IO.FS.removeFile (sidecarPath log)
}

/-- `load` RECONSTRUCTS the config from disk (the `knomosis-replay`
    auditor path, which has no budget flags and must re-derive the genesis
    budget policy + epoch length): absent → `ok none` (default config),
    present + valid → `ok (some cfg)`, present + corrupt → `error` (fail
    loudly rather than silently audit under the wrong policy). -/
def budgetSidecarLoad : TestCase := {
  name := "BudgetSidecar.load: absent → none, present → some, corrupt → error"
  body := do
    let logA ← tmpLog
    match (← load logA) with
    | .ok none => pure ()
    | .ok (some c) => throw <| IO.userError s!"absent sidecar should load as none, got {repr c}"
    | .error m => throw <| IO.userError s!"absent sidecar should be ok none, got error: {m}"
    let log ← tmpLog
    let cfg := ofPolicy (.bounded 10 1 1) 5
    writeSidecarIfAbsent log cfg
    match (← load log) with
    | .ok (some c) => assertEq cfg c "load recovers the persisted config"
    | .ok none => throw <| IO.userError "present sidecar should load as some"
    | .error m => throw <| IO.userError s!"present sidecar should load, got error: {m}"
    IO.FS.removeFile (sidecarPath log)
    let logC ← tmpLog
    IO.FS.writeFile (sidecarPath logC) "garbage not a budget config\n"
    match (← load logC) with
    | .ok _ => throw <| IO.userError "BUG: corrupt sidecar loaded without error"
    | .error _ => pure ()
    IO.FS.removeFile (sidecarPath logC)
}

/-- The full GP.6.2 sidecar suite. -/
def tests : List TestCase :=
  [ budgetSidecarRoundTrip
  , budgetSidecarTolerantDecode
  , budgetSidecarDecodeRejects
  , budgetSidecarIsDefault
  , budgetSidecarCheckAbsentOk
  , budgetSidecarWriteAndCheck
  , budgetSidecarWriteIsIdempotent
  , budgetSidecarCorruptRejected
  , budgetSidecarLoad ]

end LegalKernel.Test.Runtime.BudgetSidecarTests

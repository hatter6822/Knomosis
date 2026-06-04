-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
-/

/-
LegalKernel.Test.Runtime.RefundRateSidecar — GP.9.1 refund-rate sidecar
tests.  Covers the pure `encode` / `decode` round-trip (standing in for
the closed-form theorem, which the string/Nat rendering makes
disproportionately painful), the `toRefundRate` per-resource function,
the `isDefault` predicate, and the IO `checkConsistent` /
`writeSidecarIfAbsent` orchestration that turns a forgotten / changed
`--wei-per-budget-unit-*` flag into a clear error instead of a silently
rejected (and dropped) refund on replay.
-/

import LegalKernel.Test.Framework
import LegalKernel.Runtime.RefundRateSidecar

open LegalKernel.Runtime
open LegalKernel.Runtime.RefundRateSidecar
open LegalKernel.Runtime.RefundRateSidecar.RefundRateConfig
open LegalKernel.Test

namespace LegalKernel.Test.Runtime.RefundRateSidecarTests

/-- A representative spread of configs (disabled, single-leg, both
    legs, large / u64-boundary values). -/
def sampleConfigs : List RefundRateConfig :=
  [ { ethRate := 0, boldRate := 0 }
  , { ethRate := 5, boldRate := 0 }
  , { ethRate := 0, boldRate := 3000 }
  , { ethRate := 1000000000000, boldRate := 3000000000000000 }
  , { ethRate := 18446744073709551615, boldRate := 1 } ]

/-- `decode (encode c) = some c` across the sample spread (value-level
    stand-in for the round-trip theorem). -/
def refundRateSidecarRoundTrip : TestCase := {
  name := "RefundRateSidecar.decode (encode c) = some c (round-trip)"
  body := do
    for c in sampleConfigs do
      match decode (encode c) with
      | some c' => assertEq c c' s!"round-trip for {repr c}"
      | none => throw <| IO.userError s!"decode failed for encode {repr c}"
}

/-- A trailing newline + CRLF + extra spaces decode cleanly. -/
def refundRateSidecarTolerantDecode : TestCase := {
  name := "RefundRateSidecar.decode tolerates whitespace / CRLF"
  body := do
    let expected : RefundRateConfig := { ethRate := 5, boldRate := 3000 }
    assertEq (some expected) (decode s!"{magic} 5 3000\n") "trailing newline"
    assertEq (some expected) (decode s!"{magic} 5 3000\r\n") "CRLF"
    assertEq (some expected) (decode s!"{magic}  5   3000  ") "extra spaces"
}

/-- `decode` rejects a wrong magic, wrong field count, and non-Nat. -/
def refundRateSidecarDecodeRejects : TestCase := {
  name := "RefundRateSidecar.decode rejects malformed lines"
  body := do
    assert (decode "wrong/magic 1 1" |>.isNone) "wrong magic rejected"
    assert (decode s!"{magic} 1" |>.isNone) "too few fields rejected"
    assert (decode s!"{magic} 1 1 1" |>.isNone) "too many fields rejected"
    assert (decode s!"{magic} 1 x" |>.isNone) "non-Nat field rejected"
    assert (decode "" |>.isNone) "empty rejected"
}

/-- `toRefundRate` maps resource 0 → ethRate, resource 1 → boldRate, and
    every other resource → 0 (refunds disabled off the two gas legs, so
    a refund at an off-leg resource fails the gate's rate pin). -/
def refundRateToRefundRate : TestCase := {
  name := "RefundRateSidecar.toRefundRate maps ETH/BOLD legs, disables off-leg"
  body := do
    let c : RefundRateConfig := { ethRate := 5, boldRate := 3000 }
    assertEq (expected := 5) (actual := c.toRefundRate 0) "resource 0 → ethRate"
    assertEq (expected := 3000) (actual := c.toRefundRate 1) "resource 1 → boldRate"
    assertEq (expected := 0) (actual := c.toRefundRate 2) "resource 2 → 0 (off-leg)"
    assertEq (expected := 0) (actual := c.toRefundRate 7) "resource 7 → 0 (off-leg)"
    -- `ofFlags` and `disabled` agree with the literal forms.
    assertEq c (ofFlags 5 3000) "ofFlags"
    assert (disabled.isDefault) "disabled isDefault"
    assertEq (expected := 0) (actual := disabled.toRefundRate 0) "disabled ETH rate = 0"
}

/-- `isDefault` is true only for both rates 0. -/
def refundRateSidecarIsDefault : TestCase := {
  name := "RefundRateSidecar.isDefault detects the refunds-disabled config"
  body := do
    assert (isDefault { ethRate := 0, boldRate := 0 }) "disabled config"
    assert (! isDefault { ethRate := 1, boldRate := 0 }) "non-default ethRate"
    assert (! isDefault { ethRate := 0, boldRate := 1 }) "non-default boldRate"
}

/-- A unique temp path under `/tmp` for IO tests. -/
def tmpLog : IO System.FilePath := do
  pure (System.FilePath.mk s!"/tmp/knomosis-refundratesidecar-{(← IO.monoNanosNow)}.log")

/-- `checkConsistent` is OK when no sidecar exists (the writer creates
    it later). -/
def refundRateSidecarCheckAbsentOk : TestCase := {
  name := "RefundRateSidecar.checkConsistent: absent sidecar is OK"
  body := do
    let log ← tmpLog
    match (← checkConsistent log (ofFlags 5 3000)) with
    | .ok () => pure ()
    | .error m => throw <| IO.userError s!"absent sidecar should be OK, got: {m}"
}

/-- A default (refunds-disabled) config writes NO sidecar (preserving
    the pre-GP.9.1 on-disk footprint); a non-default config writes one,
    and a subsequent matching check passes while a mismatched check
    fails (the operator forgot / changed the rate on restart). -/
def refundRateSidecarWriteAndCheck : TestCase := {
  name := "RefundRateSidecar.write/check: default skipped, non-default enforced"
  body := do
    -- Disabled config: no sidecar written.
    let logD ← tmpLog
    writeSidecarIfAbsent logD disabled
    assert (! (← (sidecarPath logD).pathExists)) "disabled config must not create a sidecar"
    -- Non-default config: sidecar written; matching check OK.
    let log ← tmpLog
    let cfg := ofFlags 5 3000
    writeSidecarIfAbsent log cfg
    assert (← (sidecarPath log).pathExists) "non-default config must create a sidecar"
    match (← checkConsistent log cfg) with
    | .ok () => pure ()
    | .error m => throw <| IO.userError s!"matching config should pass, got: {m}"
    -- A DIFFERENT rate (forgot / changed a flag) is rejected.
    match (← checkConsistent log (ofFlags 7 3000)) with
    | .ok () => throw <| IO.userError "BUG: mismatched ETH rate accepted"
    | .error _ => pure ()
    -- A different BOLD rate is also rejected.
    match (← checkConsistent log (ofFlags 5 2999)) with
    | .ok () => throw <| IO.userError "BUG: mismatched BOLD rate accepted"
    | .error _ => pure ()
    -- The disabled default against an enabled log is rejected (the
    -- restart-forgot-the-flag case — a refund-containing log would
    -- otherwise drop its refunds silently).
    match (← checkConsistent log disabled) with
    | .ok () => throw <| IO.userError "BUG: disabled rate accepted against an enabled log"
    | .error _ => pure ()
    IO.FS.removeFile (sidecarPath log)
}

/-- `writeSidecarIfAbsent` never clobbers an existing sidecar. -/
def refundRateSidecarWriteIsIdempotent : TestCase := {
  name := "RefundRateSidecar.writeSidecarIfAbsent does not clobber"
  body := do
    let log ← tmpLog
    let cfg := ofFlags 5 3000
    writeSidecarIfAbsent log cfg
    -- A second write with a DIFFERENT config must not overwrite.
    writeSidecarIfAbsent log (ofFlags 99 99)
    let contents ← IO.FS.readFile (sidecarPath log)
    match decode contents with
    | some persisted => assertEq cfg persisted "original config preserved (no clobber)"
    | none => throw <| IO.userError "sidecar became unreadable"
    IO.FS.removeFile (sidecarPath log)
}

/-- A corrupt sidecar is rejected with an error (not silently ignored). -/
def refundRateSidecarCorruptRejected : TestCase := {
  name := "RefundRateSidecar.checkConsistent: corrupt sidecar is rejected"
  body := do
    let log ← tmpLog
    IO.FS.writeFile (sidecarPath log) "garbage not a refund-rate config\n"
    match (← checkConsistent log (ofFlags 5 3000)) with
    | .ok () => throw <| IO.userError "BUG: corrupt sidecar accepted"
    | .error _ => pure ()
    IO.FS.removeFile (sidecarPath log)
}

/-- `load` RECONSTRUCTS the config from disk (the `knomosis-replay`
    auditor path, which has no `--wei-per-budget-unit-*` flags): absent →
    `ok none` (refunds disabled, the default), present + valid → `ok (some
    cfg)`, present + corrupt → `error` (the auditor fails loudly rather
    than silently auditing under the wrong rate). -/
def refundRateSidecarLoad : TestCase := {
  name := "RefundRateSidecar.load: absent → none, present → some, corrupt → error"
  body := do
    -- Absent: ok none (refunds were disabled, the default).
    let logA ← tmpLog
    match (← load logA) with
    | .ok none => pure ()
    | .ok (some c) => throw <| IO.userError s!"absent sidecar should load as none, got {repr c}"
    | .error m => throw <| IO.userError s!"absent sidecar should be ok none, got error: {m}"
    -- Present + valid: ok (some cfg) recovering the persisted config.
    let log ← tmpLog
    let cfg := ofFlags 5 3000
    writeSidecarIfAbsent log cfg
    match (← load log) with
    | .ok (some c) => assertEq cfg c "load recovers the persisted config"
    | .ok none => throw <| IO.userError "present sidecar should load as some"
    | .error m => throw <| IO.userError s!"present sidecar should load, got error: {m}"
    IO.FS.removeFile (sidecarPath log)
    -- Present + corrupt: error (the auditor must fail loudly).
    let logC ← tmpLog
    IO.FS.writeFile (sidecarPath logC) "garbage not a refund-rate config\n"
    match (← load logC) with
    | .ok _ => throw <| IO.userError "BUG: corrupt sidecar loaded without error"
    | .error _ => pure ()
    IO.FS.removeFile (sidecarPath logC)
}

/-- The full GP.9.1 refund-rate sidecar suite. -/
def tests : List TestCase :=
  [ refundRateSidecarRoundTrip
  , refundRateSidecarTolerantDecode
  , refundRateSidecarDecodeRejects
  , refundRateToRefundRate
  , refundRateSidecarIsDefault
  , refundRateSidecarCheckAbsentOk
  , refundRateSidecarWriteAndCheck
  , refundRateSidecarWriteIsIdempotent
  , refundRateSidecarCorruptRejected
  , refundRateSidecarLoad ]

end LegalKernel.Test.Runtime.RefundRateSidecarTests
